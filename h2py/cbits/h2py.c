/*
 * The H2Py shim.  See include/h2py/h2py.h for the contract of each function
 * and docs/H2Py-DESIGN.md, sections 5.1 to 5.4 and 5.7, for the design.
 */
/* This translation unit holds the table of weak CPython references that
 * h2py_check_cpython_symbols walks; see weakapi.h. */
#define H2PY_WEAKAPI_TABLE
#include <h2py/h2py.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Provided by rts_init.c. */
int h2py_hs_init(const char *module_opts);
void h2py_free_stable_ptr(void *sp);

/* Exception classes by index; see h2py_exception_type below. */
#define H2PY_EXC_TYPE_ERROR h2py_exception_type(2)
#define H2PY_EXC_RUNTIME_ERROR h2py_exception_type(4)
#define H2PY_EXC_BUFFER_ERROR h2py_exception_type(16)

/* ------------------------------------------------------------------------
 * Process-wide state
 * --------------------------------------------------------------------- */

static atomic_int h2py_finalizing_flag = 0;
static atomic_int h2py_forked_flag = 0;

static _Thread_local int h2py_tls_attached = 0;
static _Thread_local h2py_arena *h2py_tls_arena = NULL;

int h2py_is_finalizing(void)
{
    if (atomic_load_explicit(&h2py_finalizing_flag, memory_order_acquire)) {
        return 1;
    }
#if !defined(Py_LIMITED_API) || Py_LIMITED_API >= 0x030D0000
    return Py_IsFinalizing();
#else
    return 0;
#endif
}

int h2py_is_forked_child(void)
{
    return atomic_load_explicit(&h2py_forked_flag, memory_order_acquire);
}

int h2py_is_attached(void)
{
    return h2py_tls_attached && PyGILState_GetThisThreadState() != NULL;
}

/* ------------------------------------------------------------------------
 * Deferred release pool
 * --------------------------------------------------------------------- */

static pthread_mutex_t h2py_pool_mutex = PTHREAD_MUTEX_INITIALIZER;
static PyObject **h2py_pool_items = NULL;
static size_t h2py_pool_count = 0;
static size_t h2py_pool_cap = 0;

/* Never touches CPython: a finaliser on the RTS finaliser thread calls this
 * through an unsafe foreign call. */
void h2py_pool_push(PyObject *object)
{
    if (object == NULL) {
        return;
    }
    pthread_mutex_lock(&h2py_pool_mutex);
    if (h2py_pool_count == h2py_pool_cap) {
        size_t cap = h2py_pool_cap ? h2py_pool_cap * 2 : 64;
        PyObject **items = realloc(h2py_pool_items, cap * sizeof *items);
        if (items == NULL) {
            /* Out of memory: leak the reference rather than abort. */
            pthread_mutex_unlock(&h2py_pool_mutex);
            return;
        }
        h2py_pool_items = items;
        h2py_pool_cap = cap;
    }
    h2py_pool_items[h2py_pool_count++] = object;
    pthread_mutex_unlock(&h2py_pool_mutex);
}

/* Swap the vector out under the lock, decref outside it: a decref may run
 * tp_dealloc, which re-enters Haskell and may wait for a GC that the
 * finaliser thread, blocked on the mutex inside an unsafe call, would
 * otherwise never let complete. */
void h2py_pool_drain(void)
{
    pthread_mutex_lock(&h2py_pool_mutex);
    PyObject **items = h2py_pool_items;
    size_t count = h2py_pool_count;
    h2py_pool_items = NULL;
    h2py_pool_count = 0;
    h2py_pool_cap = 0;
    pthread_mutex_unlock(&h2py_pool_mutex);
    for (size_t i = 0; i < count; i++) {
        Py_DecRef(items[i]);
    }
    free(items);
}

/* ------------------------------------------------------------------------
 * Arenas
 * --------------------------------------------------------------------- */

struct h2py_hold {
    PyObject *object;
    PyTypeObject *type;
    int mut;
};

struct h2py_arena {
    struct h2py_arena *parent;
    int prev_attached;
    int kind; /* 0 call, 1 attach, 2 scope */
    PyGILState_STATE gil_state;
    /* The type being constructed by a running tp_new, and the class whose
     * tp_new it is; consumed once by that class's first allocation. */
    PyTypeObject *ctor_type;
    PyTypeObject *ctor_class;
    PyObject **slots;
    size_t nslots, cap_slots;
    struct h2py_hold *holds;
    size_t nholds, cap_holds;
    h2py_bufview **views;
    size_t nviews, cap_views;
};

static h2py_arena *h2py_arena_push(int kind)
{
    h2py_arena *arena = calloc(1, sizeof *arena);
    if (arena == NULL) {
        return NULL;
    }
    arena->kind = kind;
    arena->prev_attached = h2py_tls_attached;
    arena->parent = h2py_tls_arena;
    h2py_tls_arena = arena;
    return arena;
}

static void h2py_cell_release_hold(struct h2py_hold *hold, int poison);
static void h2py_bufview_release(h2py_bufview *view);
static void h2py_arena_abandon(h2py_arena *arena);

/* Sweep order: holds first, since a decref may free the object whose type
 * data the hold lives in; then buffer views; then the +1s.  A __del__ reached
 * from the decref loop may re-enter through a nested trampoline whose arena is
 * a child of this one, which is harmless because the holds are already gone. */
static void h2py_arena_sweep(h2py_arena *arena, int poison)
{
    for (size_t i = 0; i < arena->nholds; i++) {
        h2py_cell_release_hold(&arena->holds[i], poison);
    }
    free(arena->holds);
    arena->holds = NULL;
    arena->nholds = arena->cap_holds = 0;

    for (size_t i = 0; i < arena->nviews; i++) {
        if (arena->views[i] != NULL) {
            h2py_bufview_release(arena->views[i]);
        }
    }
    free(arena->views);
    arena->views = NULL;
    arena->nviews = arena->cap_views = 0;

    PyObject **slots = arena->slots;
    size_t nslots = arena->nslots;
    arena->slots = NULL;
    arena->nslots = arena->cap_slots = 0;
    for (size_t i = 0; i < nslots; i++) {
        Py_DecRef(slots[i]);
    }
    free(slots);
}

static void h2py_arena_pop(h2py_arena *arena)
{
    h2py_tls_arena = arena->parent;
    free(arena);
}

/* The lowest address of this thread's stack, found on the thread's first
 * call and kept, since a thread's stack does not move.  Asking every time was
 * the dominant cost of a call on Linux: glibc answers pthread_getattr_np for
 * the initial thread by reading /proc/self/maps and querying the stack
 * rlimit, a few hundred microseconds against about one for the rest of the
 * call.  The state is 0 while the bound is unknown, 1 once it is known, and
 * -1 where the platform has no way to tell, which disables the check.
 * A failed lookup (glibc's needs a file descriptor for the initial thread) is
 * not remembered, so the next call asks again, as every call did before.
 * The initial thread's stack grows up to the stack rlimit, which glibc reads
 * at the lookup: h2py_call_begin looks again before refusing a call for lack
 * of room, so a limit raised after the first call is honoured, while one
 * lowered after it is not seen, as CPython 3.14 does not see it for its own
 * stack check either; seeing it would cost a system call per call. */
static _Thread_local char *h2py_tls_stack_low = NULL;
static _Thread_local int h2py_tls_stack_state = 0;

static void h2py_stack_find_low(void)
{
#if defined(__APPLE__)
    pthread_t self = pthread_self();
    char *top = (char *) pthread_get_stackaddr_np(self);
    size_t size = pthread_get_stacksize_np(self);
    h2py_tls_stack_low = top - size;
    h2py_tls_stack_state = 1;
#elif defined(__linux__)
    pthread_attr_t attr;
    void *base = NULL;
    size_t size = 0;
    if (pthread_getattr_np(pthread_self(), &attr) != 0) {
        return;
    }
    int rc = pthread_attr_getstack(&attr, &base, &size);
    pthread_attr_destroy(&attr);
    if (rc == 0 && base != NULL) {
        h2py_tls_stack_low = (char *) base;
        h2py_tls_stack_state = 1;
    }
#else
    h2py_tls_stack_state = -1;
#endif
}

/* The C stack left below the current frame on this thread, or -1 if it cannot
 * be determined.  Every trampoline entry re-enters the RTS on the calling OS
 * thread with a stack reservation of its own, so a Python recursion that
 * passes through H2Py costs far more C stack per level than CPython's own
 * recursion accounting assumes. */
static long h2py_stack_headroom(void)
{
    if (h2py_tls_stack_state == 0) {
        h2py_stack_find_low();
    }
    if (h2py_tls_stack_state != 1) {
        return -1;
    }
    return (long) ((char *) __builtin_frame_address(0) - h2py_tls_stack_low);
}

/* What a call needs below its entry: the RTS reservation, the scheduler and
 * libffi frames, and the Haskell code's own use of the C stack for safe calls. */
#define H2PY_STACK_MIN (256L * 1024L)

h2py_arena *h2py_call_begin(void)
{
    if (h2py_is_forked_child()) {
        PyErr_SetString(H2PY_EXC_RUNTIME_ERROR,
                        "H2Py: the Haskell runtime cannot be used in the child of os.fork(); "
                        "use the 'spawn' start method");
        return NULL;
    }
    long room = h2py_stack_headroom();
    if (room >= 0 && room < H2PY_STACK_MIN && h2py_tls_stack_state == 1) {
        /* Look again before refusing: the stack rlimit may have been raised
         * since the bound was found.  If the lookup fails, the bound already
         * found stands, and the call is refused. */
        char *known = h2py_tls_stack_low;
        h2py_tls_stack_state = 0;
        long again = h2py_stack_headroom();
        if (h2py_tls_stack_state == 1) {
            room = again;
        } else {
            h2py_tls_stack_low = known;
            h2py_tls_stack_state = 1;
        }
    }
    if (room >= 0 && room < H2PY_STACK_MIN) {
        PyErr_SetString(h2py_exception_type(24),
                        "maximum recursion depth exceeded through a Haskell call");
        return NULL;
    }
    h2py_arena *arena = h2py_arena_push(0);
    if (arena == NULL) {
        PyErr_NoMemory();
        return NULL;
    }
    h2py_tls_attached = 1;
    h2py_pool_drain();
    return arena;
}

void h2py_call_end(h2py_arena *arena, int poison)
{
    if (h2py_tls_attached) {
        h2py_arena_sweep(arena, poison);
        h2py_pool_drain();
    } else {
        h2py_arena_abandon(arena);
    }
    h2py_tls_attached = arena->prev_attached;
    h2py_arena_pop(arena);
}

h2py_arena *h2py_attach_begin(void)
{
    if (h2py_is_finalizing() || h2py_is_forked_child()) {
        return NULL;
    }
    PyGILState_STATE state = PyGILState_Ensure();
    h2py_arena *arena = h2py_arena_push(1);
    if (arena == NULL) {
        PyGILState_Release(state);
        return NULL;
    }
    arena->gil_state = state;
    h2py_tls_attached = 1;
    h2py_pool_drain();
    return arena;
}

/* Release the Haskell-side state of an arena that lost the interpreter
 * (finalisation on the restore path of a detach): nothing may touch CPython,
 * so the +1s and the holds leak. */
static void h2py_arena_abandon(h2py_arena *arena)
{
    for (size_t i = 0; i < arena->nviews; i++) {
        free(arena->views[i]);
    }
    free(arena->holds);
    free(arena->views);
    free(arena->slots);
}

void h2py_attach_end(h2py_arena *arena, int poison)
{
    PyGILState_STATE state = arena->gil_state;
    if (h2py_tls_attached) {
        h2py_arena_sweep(arena, poison);
        h2py_pool_drain();
        h2py_tls_attached = arena->prev_attached;
        h2py_arena_pop(arena);
        PyGILState_Release(state);
    } else {
        h2py_arena_abandon(arena);
        h2py_tls_attached = arena->prev_attached;
        h2py_arena_pop(arena);
    }
}

h2py_arena *h2py_scope_begin(void)
{
    if (!h2py_is_attached()) {
        return NULL;
    }
    return h2py_arena_push(2);
}

void h2py_scope_end(h2py_arena *arena, int poison)
{
    if (h2py_tls_attached) {
        h2py_arena_sweep(arena, poison);
    } else {
        h2py_arena_abandon(arena);
    }
    h2py_arena_pop(arena);
}

void *h2py_detach_begin(void)
{
    h2py_tls_attached = 0;
    return PyEval_SaveThread();
}

int h2py_detach_end(void *thread_state)
{
    if (h2py_is_finalizing()) {
        return -1;
    }
    PyEval_RestoreThread((PyThreadState *) thread_state);
    h2py_tls_attached = 1;
    return 0;
}

h2py_arena *h2py_arena_current(void)
{
    return h2py_tls_arena;
}

void h2py_arena_register(h2py_arena *arena, PyObject *object)
{
    if (arena->nslots == arena->cap_slots) {
        size_t cap = arena->cap_slots ? arena->cap_slots * 2 : 32;
        PyObject **slots = realloc(arena->slots, cap * sizeof *slots);
        if (slots == NULL) {
            /* Out of memory: leak the +1 rather than abort. */
            return;
        }
        arena->slots = slots;
        arena->cap_slots = cap;
    }
    arena->slots[arena->nslots++] = object;
}

void h2py_arena_set_ctor(h2py_arena *arena, PyTypeObject *type, PyTypeObject *cls)
{
    arena->ctor_type = type;
    arena->ctor_class = cls;
}

/* The type recorded for a tp_new of `cls`, searched from the innermost arena
 * outwards through the nested scopes of the same call, and cleared so that
 * only the first allocation of that class in the constructor uses it; NULL
 * for any other class, so that a helper object built inside a constructor is
 * allocated with its own type. */
PyTypeObject *h2py_arena_take_ctor_type(h2py_arena *arena, PyTypeObject *cls)
{
    for (h2py_arena *a = arena; a != NULL; a = a->parent) {
        if (a->ctor_class == cls && a->ctor_type != NULL) {
            PyTypeObject *type = a->ctor_type;
            a->ctor_type = NULL;
            a->ctor_class = NULL;
            return type;
        }
        if (a->kind != 2) {
            break;
        }
    }
    return NULL;
}

static int h2py_arena_add_hold(h2py_arena *arena, PyObject *object, PyTypeObject *type, int mut)
{
    if (arena->nholds == arena->cap_holds) {
        size_t cap = arena->cap_holds ? arena->cap_holds * 2 : 8;
        struct h2py_hold *holds = realloc(arena->holds, cap * sizeof *holds);
        if (holds == NULL) {
            return -1;
        }
        arena->holds = holds;
        arena->cap_holds = cap;
    }
    struct h2py_hold *hold = &arena->holds[arena->nholds++];
    hold->object = object;
    hold->type = type;
    hold->mut = mut;
    return 0;
}

static int h2py_arena_add_view(h2py_arena *arena, h2py_bufview *view)
{
    if (arena->nviews == arena->cap_views) {
        size_t cap = arena->cap_views ? arena->cap_views * 2 : 4;
        h2py_bufview **views = realloc(arena->views, cap * sizeof *views);
        if (views == NULL) {
            return -1;
        }
        arena->views = views;
        arena->cap_views = cap;
    }
    arena->views[arena->nviews++] = view;
    return 0;
}

/* ------------------------------------------------------------------------
 * Cells: payload, lend state, export count
 * --------------------------------------------------------------------- */

struct h2py_cell {
    void *payload;
    _Atomic(intptr_t) lend;
    _Atomic(intptr_t) exports;
};

Py_ssize_t h2py_cell_basicsize(void)
{
    return -(Py_ssize_t) sizeof(struct h2py_cell);
}

h2py_cell *h2py_cell_of(PyObject *object, PyTypeObject *type)
{
    return (h2py_cell *) PyObject_GetTypeData(object, type);
}

void *h2py_cell_payload(h2py_cell *cell)
{
    return cell->payload;
}

void h2py_cell_set_payload(h2py_cell *cell, void *stable_ptr)
{
    cell->payload = stable_ptr;
}

intptr_t h2py_cell_lend(h2py_cell *cell)
{
    return atomic_load_explicit(&cell->lend, memory_order_acquire);
}

intptr_t h2py_cell_exports(h2py_cell *cell)
{
    return atomic_load_explicit(&cell->exports, memory_order_acquire);
}

int h2py_cell_claim_mut(h2py_arena *arena, PyObject *object, PyTypeObject *type)
{
    h2py_cell *cell = h2py_cell_of(object, type);
    intptr_t expected = H2PY_LEND_FREE;
    if (!atomic_compare_exchange_strong_explicit(&cell->lend, &expected, H2PY_LEND_MUT,
                                                 memory_order_acq_rel, memory_order_acquire)) {
        return expected == H2PY_LEND_POISONED ? H2PY_CLAIM_POISONED : H2PY_CLAIM_BUSY;
    }
    if (atomic_load_explicit(&cell->exports, memory_order_acquire) > 0) {
        atomic_store_explicit(&cell->lend, H2PY_LEND_FREE, memory_order_release);
        return H2PY_CLAIM_EXPORTED;
    }
    if (h2py_arena_add_hold(arena, object, type, 1) < 0) {
        atomic_store_explicit(&cell->lend, H2PY_LEND_FREE, memory_order_release);
        return H2PY_CLAIM_BUSY;
    }
    return H2PY_CLAIM_OK;
}

static int h2py_cell_add_shared(h2py_cell *cell)
{
    for (;;) {
        intptr_t v = atomic_load_explicit(&cell->lend, memory_order_acquire);
        if (v == H2PY_LEND_MUT) {
            return H2PY_CLAIM_BUSY;
        }
        if (v == H2PY_LEND_POISONED) {
            return H2PY_CLAIM_POISONED;
        }
        if (atomic_compare_exchange_weak_explicit(&cell->lend, &v, v + 1,
                                                  memory_order_acq_rel, memory_order_acquire)) {
            break;
        }
    }
    if (atomic_load_explicit(&cell->exports, memory_order_acquire) > 0) {
        atomic_fetch_sub_explicit(&cell->lend, 1, memory_order_acq_rel);
        return H2PY_CLAIM_EXPORTED;
    }
    return H2PY_CLAIM_OK;
}

int h2py_cell_claim_shared(h2py_arena *arena, PyObject *object, PyTypeObject *type)
{
    h2py_cell *cell = h2py_cell_of(object, type);
    int r = h2py_cell_add_shared(cell);
    if (r != H2PY_CLAIM_OK) {
        return r;
    }
    if (h2py_arena_add_hold(arena, object, type, 0) < 0) {
        atomic_fetch_sub_explicit(&cell->lend, 1, memory_order_acq_rel);
        return H2PY_CLAIM_BUSY;
    }
    return H2PY_CLAIM_OK;
}

int h2py_cell_copy_begin(h2py_cell *cell)
{
    return h2py_cell_add_shared(cell);
}

void h2py_cell_copy_end(h2py_cell *cell)
{
    atomic_fetch_sub_explicit(&cell->lend, 1, memory_order_acq_rel);
}

int h2py_cell_export_begin(h2py_cell *cell)
{
    intptr_t expected = H2PY_LEND_FREE;
    if (!atomic_compare_exchange_strong_explicit(&cell->lend, &expected, H2PY_LEND_MUT,
                                                 memory_order_acq_rel, memory_order_acquire)) {
        return expected == H2PY_LEND_POISONED ? H2PY_CLAIM_POISONED : H2PY_CLAIM_BUSY;
    }
    atomic_fetch_add_explicit(&cell->exports, 1, memory_order_acq_rel);
    atomic_store_explicit(&cell->lend, H2PY_LEND_FREE, memory_order_release);
    return H2PY_CLAIM_OK;
}

void h2py_cell_export_end(h2py_cell *cell)
{
    atomic_fetch_sub_explicit(&cell->exports, 1, memory_order_release);
}

/* A hold is released only by the arena that took it: a mutable hold goes back
 * to Free, or to Poisoned on an exceptional exit; a shared hold subtracts the
 * one it added, leaving the other readers' holds untouched. */
static void h2py_cell_release_hold(struct h2py_hold *hold, int poison)
{
    h2py_cell *cell = h2py_cell_of(hold->object, hold->type);
    if (hold->mut) {
        atomic_store_explicit(&cell->lend, poison ? H2PY_LEND_POISONED : H2PY_LEND_FREE,
                              memory_order_release);
    } else {
        atomic_fetch_sub_explicit(&cell->lend, 1, memory_order_acq_rel);
    }
}

PyObject *h2py_alloc_instance(PyTypeObject *type)
{
    allocfunc alloc = (allocfunc) PyType_GetSlot(type, Py_tp_alloc);
    if (alloc == NULL) {
        alloc = PyType_GenericAlloc;
    }
    return alloc(type, 0);
}

void h2py_finish_dealloc(PyObject *self)
{
    PyObject *type = PyObject_Type(self);
    freefunc free_slot = (freefunc) PyType_GetSlot((PyTypeObject *) type, Py_tp_free);
    if (free_slot == NULL) {
        free_slot = PyObject_Free;
    }
    free_slot(self);
    Py_DecRef(type); /* the instance's own reference to its heap type */
    Py_DecRef(type); /* the one PyObject_Type gave us */
}

/* ------------------------------------------------------------------------
 * Types, methods, argument binding
 * --------------------------------------------------------------------- */

PyObject *h2py_make_type(PyObject *module, const char *name, const char *doc,
                         Py_ssize_t basicsize, unsigned long flags,
                         const int *slot_ids, void *const *slot_funcs, int nslots,
                         PyObject *bases)
{
    PyType_Slot *slots = calloc((size_t) nslots + 2, sizeof *slots);
    if (slots == NULL) {
        PyErr_NoMemory();
        return NULL;
    }
    int n = 0;
    for (int i = 0; i < nslots; i++) {
        slots[n].slot = slot_ids[i];
        slots[n].pfunc = slot_funcs[i];
        n++;
    }
    if (doc != NULL) {
        slots[n].slot = Py_tp_doc;
        slots[n].pfunc = (void *) doc;
        n++;
    }
    PyType_Spec spec;
    memset(&spec, 0, sizeof spec);
    spec.name = strdup(name); /* the type keeps pointing at it */
    spec.basicsize = (int) basicsize;
    spec.itemsize = 0;
    spec.flags = (unsigned int) flags;
    spec.slots = slots;
    PyObject *type = PyType_FromModuleAndSpec(module, &spec, bases);
    free(slots);
    return type;
}

PyMethodDef *h2py_methoddefs_new(int count)
{
    return calloc((size_t) count + 1, sizeof(PyMethodDef));
}

void h2py_methoddef_set(PyMethodDef *defs, int index, const char *name, void *func,
                        int flags, const char *doc)
{
    defs[index].ml_name = strdup(name);
    defs[index].ml_meth = (PyCFunction) func;
    defs[index].ml_flags = flags;
    defs[index].ml_doc = doc ? strdup(doc) : NULL;
}

int h2py_bind_args(PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames,
                   const char *const *names, Py_ssize_t nparams, PyObject **out)
{
    Py_ssize_t nkw = kwnames ? PyTuple_Size(kwnames) : 0;
    if (nargs > nparams) {
        PyErr_Format(H2PY_EXC_TYPE_ERROR, "takes at most %zd positional argument%s (%zd given)",
                     nparams, nparams == 1 ? "" : "s", nargs);
        return -1;
    }
    for (Py_ssize_t i = 0; i < nparams; i++) {
        out[i] = i < nargs ? args[i] : NULL;
    }
    for (Py_ssize_t k = 0; k < nkw; k++) {
        PyObject *key = PyTuple_GetItem(kwnames, k);
        const char *s = key ? PyUnicode_AsUTF8AndSize(key, NULL) : NULL;
        if (s == NULL) {
            return -1;
        }
        Py_ssize_t j = 0;
        for (; j < nparams; j++) {
            if (names[j] != NULL && strcmp(names[j], s) == 0) {
                break;
            }
        }
        if (j == nparams) {
            PyErr_Format(H2PY_EXC_TYPE_ERROR, "got an unexpected keyword argument '%s'", s);
            return -1;
        }
        if (out[j] != NULL) {
            PyErr_Format(H2PY_EXC_TYPE_ERROR, "got multiple values for argument '%s'", s);
            return -1;
        }
        out[j] = args[nargs + k];
    }
    for (Py_ssize_t j = 0; j < nparams; j++) {
        if (out[j] == NULL) {
            if (names[j] != NULL) {
                PyErr_Format(H2PY_EXC_TYPE_ERROR, "missing required argument '%s' (pos %zd)",
                             names[j], j + 1);
            } else {
                PyErr_Format(H2PY_EXC_TYPE_ERROR, "missing required positional argument %zd", j + 1);
            }
            return -1;
        }
    }
    return 0;
}

PyObject **h2py_unpack_call(PyObject *args, PyObject *kwargs, Py_ssize_t *nargs, PyObject **kwnames)
{
    Py_ssize_t n = args ? PyTuple_Size(args) : 0;
    Py_ssize_t nk = kwargs ? PyDict_Size(kwargs) : 0;
    if (n < 0 || nk < 0) {
        return NULL;
    }
    PyObject **vec = malloc(((size_t) n + (size_t) nk + 1) * sizeof *vec);
    if (vec == NULL) {
        PyErr_NoMemory();
        return NULL;
    }
    for (Py_ssize_t i = 0; i < n; i++) {
        vec[i] = PyTuple_GetItem(args, i); /* borrowed from the frame's tuple */
    }
    *kwnames = NULL;
    if (nk > 0) {
        PyObject *names = PyTuple_New(nk);
        if (names == NULL) {
            free(vec);
            return NULL;
        }
        Py_ssize_t pos = 0, k = 0;
        PyObject *key, *value;
        while (PyDict_Next(kwargs, &pos, &key, &value)) {
            Py_IncRef(key);
            PyTuple_SetItem(names, k, key);
            vec[n + k] = value; /* borrowed from the dict for the call */
            k++;
        }
        *kwnames = names;
    }
    *nargs = n;
    return vec;
}

void h2py_free(void *p)
{
    free(p);
}

/*
 * Constants of the interpreter are fetched through functions, never through
 * data symbols: a data symbol such as PyLong_Type must be bound when the
 * shared object is loaded, and GHC loads this library into its own process,
 * with no interpreter, to run Template Haskell splices.  Function symbols bind
 * lazily and are never called there.  The lookups are cached for the process.
 */
static PyObject *h2py_module_attr(PyObject **module_cache, const char *module, const char *attr)
{
    if (*module_cache == NULL) {
        *module_cache = PyImport_ImportModule(module);
        if (*module_cache == NULL) {
            return NULL;
        }
    }
    return PyObject_GetAttrString(*module_cache, attr);
}

static PyObject *h2py_builtins_cache = NULL;
static PyObject *h2py_types_cache = NULL;

static PyObject *h2py_builtin(const char *name)
{
    return h2py_module_attr(&h2py_builtins_cache, "builtins", name);
}

#define H2PY_CACHED(var, expr)               \
    do {                                     \
        static PyObject *var = NULL;         \
        if (var == NULL) {                   \
            var = (expr);                    \
        }                                    \
        return var;                          \
    } while (0)

PyObject *h2py_builtin_type(int which)
{
    switch (which) {
    case 0: H2PY_CACHED(t0, h2py_builtin("object"));
    case 1: H2PY_CACHED(t1, h2py_builtin("int"));
    case 2: H2PY_CACHED(t2, h2py_builtin("float"));
    case 3: H2PY_CACHED(t3, h2py_builtin("bool"));
    case 4: H2PY_CACHED(t4, h2py_builtin("str"));
    case 5: H2PY_CACHED(t5, h2py_builtin("bytes"));
    case 6: H2PY_CACHED(t6, h2py_builtin("tuple"));
    case 7: H2PY_CACHED(t7, h2py_builtin("list"));
    case 8: H2PY_CACHED(t8, h2py_builtin("dict"));
    case 9: H2PY_CACHED(t9, h2py_builtin("BaseException"));
    case 10: H2PY_CACHED(t10, h2py_builtin("set"));
    case 11: H2PY_CACHED(t11, h2py_builtin("bytearray"));
    case 12: H2PY_CACHED(t12, h2py_builtin("memoryview"));
    case 13: H2PY_CACHED(t13, h2py_builtin("type"));
    case 14: H2PY_CACHED(t14, h2py_module_attr(&h2py_types_cache, "types", "ModuleType"));
    default: return NULL;
    }
}

static const char *const h2py_exception_names[] = {
    "BaseException", "Exception", "TypeError", "ValueError", "RuntimeError",
    "OverflowError", "KeyError", "IndexError", "AttributeError", "StopIteration",
    "NotImplementedError", "ZeroDivisionError", "ArithmeticError", "MemoryError",
    "OSError", "KeyboardInterrupt", "BufferError", "LookupError", "UnicodeDecodeError",
    "ImportError", "AssertionError", "SystemError", "IOError", "FloatingPointError",
    "RecursionError", "StopAsyncIteration", "EOFError", "NameError", "UnicodeEncodeError",
    "UnicodeError", "PermissionError", "FileNotFoundError", "TimeoutError",
};

#define H2PY_NEXCEPTIONS ((int) (sizeof h2py_exception_names / sizeof h2py_exception_names[0]))

static PyObject *h2py_exception_cache[H2PY_NEXCEPTIONS];

PyObject *h2py_exception_type(int which)
{
    if (which < 0 || which >= H2PY_NEXCEPTIONS) {
        return NULL;
    }
    if (h2py_exception_cache[which] == NULL) {
        h2py_exception_cache[which] = h2py_builtin(h2py_exception_names[which]);
    }
    return h2py_exception_cache[which];
}

/* Every CPython function the library references is a weak reference (see
 * weakapi.h), so on an interpreter that lacks one the first use would call
 * address 0.  The module's exec slot calls this first, and a missing function
 * fails the import with an ImportError that names it.  If even the functions
 * that raise it are missing, it returns -1 with no exception set, which
 * CPython reports as a SystemError. */
int h2py_check_cpython_symbols(void)
{
    char missing[512] = "";
    size_t used = 0;
    int count = 0;
    int truncated = 0;
    for (size_t i = 0; i < sizeof h2py_weakapi_table / sizeof h2py_weakapi_table[0]; i++) {
        if (h2py_weakapi_table[i].address != NULL) {
            continue;
        }
        count++;
        if (truncated) {
            continue;
        }
        /* Keep room for ", ..." should a later name not fit. */
        int n = snprintf(missing + used, sizeof missing - used - 5, "%s%s", count > 1 ? ", " : "",
                         h2py_weakapi_table[i].name);
        if (n > 0 && (size_t) n < sizeof missing - used - 5) {
            used += (size_t) n;
        } else {
            missing[used] = '\0';
            strcat(missing, ", ...");
            truncated = 1;
        }
    }
    if (count == 0) {
        return 0;
    }
    const void *raise_with[] = {(const void *) &PyErr_SetString, (const void *) &PyImport_ImportModule,
                                (const void *) &PyObject_GetAttrString};
    for (size_t i = 0; i < sizeof raise_with / sizeof raise_with[0]; i++) {
        if (raise_with[i] == NULL) {
            return -1;
        }
    }
    PyObject *import_error = h2py_exception_type(19);
    if (import_error != NULL) {
        char message[640];
        snprintf(message, sizeof message,
                 "H2Py: this interpreter lacks CPython functions the module needs (%s); "
                 "H2Py modules need CPython 3.12 or later",
                 missing);
        PyErr_SetString(import_error, message);
    }
    return -1;
}

PyObject *h2py_none(void) { H2PY_CACHED(c, h2py_builtin("None")); }
PyObject *h2py_true(void) { H2PY_CACHED(c, h2py_builtin("True")); }
PyObject *h2py_false(void) { H2PY_CACHED(c, h2py_builtin("False")); }
PyObject *h2py_not_implemented(void) { H2PY_CACHED(c, h2py_builtin("NotImplemented")); }

void h2py_set_error(PyObject *type, const char *utf8)
{
    PyErr_SetString(type, utf8);
}

int h2py_err_occurred(void)
{
    return PyErr_Occurred() != NULL;
}

PyObject *h2py_take_error(void)
{
    return PyErr_GetRaisedException();
}

void h2py_write_unraisable(PyObject *context)
{
    PyErr_WriteUnraisable(context);
}

int h2py_check_signals(void)
{
    return PyErr_CheckSignals();
}

/* ------------------------------------------------------------------------
 * Buffers and the borrow registry
 * --------------------------------------------------------------------- */

struct h2py_reg_entry {
    char *start;
    char *end;
    int mut;
};

static pthread_mutex_t h2py_reg_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct h2py_reg_entry *h2py_reg_entries = NULL;
static size_t h2py_reg_count = 0;
static size_t h2py_reg_cap = 0;

struct h2py_bufview {
    Py_buffer view;
    h2py_arena *arena;
    size_t arena_index;
    int registered;
    /* The registry flag of the request: a shared request on a writable
     * exporter gets a view with readonly == 0, so the flag cannot be
     * recovered from the view at release time. */
    int mut;
    /* Set once the exporter's buffer has been released; the struct itself
     * lives until the arena that recorded it is swept, so that a release
     * through an unrestricted view can never free it twice. */
    int released;
};

/* Register [start, end) as held: exclusively if mut, else shared.  Returns -1
 * on a conflict: any overlap with an exclusive entry, or, for an exclusive
 * request, any overlap at all. */
static int h2py_registry_add(char *start, char *end, int mut)
{
    pthread_mutex_lock(&h2py_reg_mutex);
    for (size_t i = 0; i < h2py_reg_count; i++) {
        struct h2py_reg_entry *e = &h2py_reg_entries[i];
        if (e->start < end && start < e->end && (mut || e->mut)) {
            pthread_mutex_unlock(&h2py_reg_mutex);
            return -1;
        }
    }
    if (h2py_reg_count == h2py_reg_cap) {
        size_t cap = h2py_reg_cap ? h2py_reg_cap * 2 : 8;
        struct h2py_reg_entry *entries = realloc(h2py_reg_entries, cap * sizeof *entries);
        if (entries == NULL) {
            pthread_mutex_unlock(&h2py_reg_mutex);
            return -1;
        }
        h2py_reg_entries = entries;
        h2py_reg_cap = cap;
    }
    h2py_reg_entries[h2py_reg_count].start = start;
    h2py_reg_entries[h2py_reg_count].end = end;
    h2py_reg_entries[h2py_reg_count].mut = mut;
    h2py_reg_count++;
    pthread_mutex_unlock(&h2py_reg_mutex);
    return 0;
}

static void h2py_registry_remove(char *start, char *end, int mut)
{
    pthread_mutex_lock(&h2py_reg_mutex);
    for (size_t i = 0; i < h2py_reg_count; i++) {
        struct h2py_reg_entry *e = &h2py_reg_entries[i];
        if (e->start == start && e->end == end && e->mut == mut) {
            h2py_reg_entries[i] = h2py_reg_entries[h2py_reg_count - 1];
            h2py_reg_count--;
            break;
        }
    }
    pthread_mutex_unlock(&h2py_reg_mutex);
}

h2py_bufview *h2py_buffer_request(h2py_arena *arena, PyObject *object, int writable)
{
    h2py_bufview *view = calloc(1, sizeof *view);
    if (view == NULL) {
        PyErr_NoMemory();
        return NULL;
    }
    int flags = PyBUF_FORMAT | PyBUF_ND | PyBUF_C_CONTIGUOUS;
    if (writable) {
        flags |= PyBUF_WRITABLE;
    }
    if (PyObject_GetBuffer(object, &view->view, flags) < 0) {
        free(view);
        return NULL;
    }
    char *start = (char *) view->view.buf;
    char *end = start + view->view.len;
    if (h2py_registry_add(start, end, writable) < 0) {
        PyBuffer_Release(&view->view);
        free(view);
        PyErr_SetString(H2PY_EXC_BUFFER_ERROR,
                        writable ? "buffer is already borrowed by another H2Py scope"
                                 : "buffer is already mutably borrowed by another H2Py scope");
        return NULL;
    }
    view->registered = 1;
    view->mut = writable;
    view->arena = arena;
    view->arena_index = arena->nviews;
    if (h2py_arena_add_view(arena, view) < 0) {
        h2py_registry_remove(start, end, writable);
        PyBuffer_Release(&view->view);
        free(view);
        PyErr_NoMemory();
        return NULL;
    }
    return view;
}

void *h2py_buffer_data(h2py_bufview *view) { return view->view.buf; }
Py_ssize_t h2py_buffer_len(h2py_bufview *view) { return view->view.len; }
Py_ssize_t h2py_buffer_itemsize(h2py_bufview *view) { return view->view.itemsize; }
const char *h2py_buffer_format(h2py_bufview *view) { return view->view.format; }
int h2py_buffer_readonly(h2py_bufview *view) { return view->view.readonly; }

/* Give the exporter its buffer back and drop the registry entry; idempotent. */
static void h2py_bufview_drop(h2py_bufview *view)
{
    if (view->released) {
        return;
    }
    if (view->registered) {
        char *start = (char *) view->view.buf;
        h2py_registry_remove(start, start + view->view.len, view->mut);
        view->registered = 0;
    }
    view->released = 1;
    PyBuffer_Release(&view->view);
}

/* At the sweep: drop, then free the struct. */
static void h2py_bufview_release(h2py_bufview *view)
{
    h2py_bufview_drop(view);
    free(view);
}

void h2py_buffer_release(h2py_bufview *view)
{
    h2py_bufview_drop(view);
}

int h2py_buffer_released(h2py_bufview *view)
{
    return view->released;
}

/* ------------------------------------------------------------------------
 * HsBuffer: the exporter of Haskell-owned memory
 * --------------------------------------------------------------------- */

struct h2py_hsbuffer {
    void *stable_ptr;
    void *data;
    Py_ssize_t len;
    Py_ssize_t itemsize;
    Py_ssize_t shape;
    char format[16];
};

static PyObject *h2py_hsbuffer_type_object = NULL;

static int h2py_hsbuffer_getbuffer(PyObject *self, Py_buffer *view, int flags)
{
    struct h2py_hsbuffer *hb = PyObject_GetTypeData(self, (PyTypeObject *) h2py_hsbuffer_type_object);
    view->obj = self;
    Py_IncRef(self);
    view->buf = hb->data;
    view->len = hb->len;
    view->readonly = 0;
    view->itemsize = hb->itemsize;
    view->format = (flags & PyBUF_FORMAT) ? hb->format : NULL;
    view->ndim = 1;
    view->shape = (flags & PyBUF_ND) ? &hb->shape : NULL;
    view->strides = (flags & PyBUF_STRIDES) ? &hb->itemsize : NULL;
    view->suboffsets = NULL;
    view->internal = NULL;
    return 0;
}

static void h2py_hsbuffer_releasebuffer(PyObject *self, Py_buffer *view)
{
    (void) self;
    (void) view;
}

static void h2py_hsbuffer_dealloc(PyObject *self)
{
    struct h2py_hsbuffer *hb = PyObject_GetTypeData(self, (PyTypeObject *) h2py_hsbuffer_type_object);
    if (hb->stable_ptr != NULL) {
        /* Callable from a thread that never entered Haskell. */
        h2py_free_stable_ptr(hb->stable_ptr);
        hb->stable_ptr = NULL;
    }
    h2py_finish_dealloc(self);
}

PyObject *h2py_hsbuffer_type(void)
{
    if (h2py_hsbuffer_type_object == NULL) {
        PyType_Slot slots[] = {
            {Py_bf_getbuffer, (void *) h2py_hsbuffer_getbuffer},
            {Py_bf_releasebuffer, (void *) h2py_hsbuffer_releasebuffer},
            {Py_tp_dealloc, (void *) h2py_hsbuffer_dealloc},
            {0, NULL},
        };
        PyType_Spec spec = {
            "h2py.HsBuffer",
            -(int) sizeof(struct h2py_hsbuffer),
            0,
            Py_TPFLAGS_DEFAULT | Py_TPFLAGS_DISALLOW_INSTANTIATION,
            slots,
        };
        h2py_hsbuffer_type_object = PyType_FromSpec(&spec);
    }
    return h2py_hsbuffer_type_object;
}

PyObject *h2py_hsbuffer_new(void *stable_ptr, void *data, Py_ssize_t len,
                            Py_ssize_t itemsize, const char *format)
{
    PyObject *type = h2py_hsbuffer_type();
    if (type == NULL) {
        return NULL;
    }
    PyObject *self = h2py_alloc_instance((PyTypeObject *) type);
    if (self == NULL) {
        return NULL;
    }
    struct h2py_hsbuffer *hb = PyObject_GetTypeData(self, (PyTypeObject *) type);
    hb->stable_ptr = stable_ptr;
    hb->data = data;
    hb->len = len;
    hb->itemsize = itemsize;
    hb->shape = itemsize ? len / itemsize : 0;
    strncpy(hb->format, format, sizeof hb->format - 1);
    hb->format[sizeof hb->format - 1] = '\0';
    return self;
}

/* ------------------------------------------------------------------------
 * Class-owned buffer exports (the Buffer slot) and slot constants
 * --------------------------------------------------------------------- */

int h2py_fill_buffer(Py_buffer *view, PyObject *self, void *data, Py_ssize_t len,
                     Py_ssize_t itemsize, const char *format, int flags)
{
    Py_ssize_t *shape = malloc(2 * sizeof *shape);
    if (shape == NULL) {
        view->obj = NULL;
        PyErr_NoMemory();
        return -1;
    }
    shape[0] = itemsize ? len / itemsize : 0;
    shape[1] = itemsize;
    view->obj = self;
    Py_IncRef(self);
    view->buf = data;
    view->len = len;
    view->readonly = 0;
    view->itemsize = itemsize;
    view->format = (flags & PyBUF_FORMAT) ? (char *) format : NULL;
    view->ndim = 1;
    view->shape = (flags & PyBUF_ND) ? &shape[0] : NULL;
    view->strides = (flags & PyBUF_STRIDES) ? &shape[1] : NULL;
    view->suboffsets = NULL;
    view->internal = shape;
    return 0;
}

void h2py_buffer_fail(Py_buffer *view)
{
    view->obj = NULL;
}

void h2py_buffer_free_internal(Py_buffer *view)
{
    free(view->internal);
    view->internal = NULL;
}

void *h2py_hash_not_implemented(void)
{
    return (void *) PyObject_HashNotImplemented;
}

/* ------------------------------------------------------------------------
 * Runtime hooks
 * --------------------------------------------------------------------- */

static PyObject *h2py_atexit_hook(PyObject *self, PyObject *unused)
{
    (void) self;
    (void) unused;
    atomic_store_explicit(&h2py_finalizing_flag, 1, memory_order_release);
    PyObject *none = h2py_none();
    Py_IncRef(none);
    return none;
}

static PyObject *h2py_afterfork_hook(PyObject *self, PyObject *unused)
{
    (void) self;
    (void) unused;
    atomic_store_explicit(&h2py_forked_flag, 1, memory_order_release);
    PyObject *none = h2py_none();
    Py_IncRef(none);
    return none;
}

static PyMethodDef h2py_hook_methods[] = {
    {"_h2py_atexit", (PyCFunction) h2py_atexit_hook, METH_NOARGS,
     "Marks the interpreter as finalising for H2Py's attachment guard."},
    {"_h2py_after_fork", (PyCFunction) h2py_afterfork_hook, METH_NOARGS,
     "Marks the process as a forked child, where the Haskell runtime is unusable."},
    {NULL, NULL, 0, NULL},
};

int h2py_runtime_init(void)
{
    if (h2py_hs_init(NULL) < 0) {
        PyErr_SetString(H2PY_EXC_RUNTIME_ERROR, "H2Py: could not initialise the GHC runtime");
        return -1;
    }
    return 0;
}

static int h2py_call_kw(PyObject *callable, const char *kwname, PyObject *arg)
{
    PyObject *args = PyTuple_New(0);
    PyObject *kwargs = PyDict_New();
    if (args == NULL || kwargs == NULL) {
        Py_DecRef(args);
        Py_DecRef(kwargs);
        return -1;
    }
    int rc = PyDict_SetItemString(kwargs, kwname, arg);
    PyObject *r = rc < 0 ? NULL : PyObject_Call(callable, args, kwargs);
    Py_DecRef(args);
    Py_DecRef(kwargs);
    if (r == NULL) {
        return -1;
    }
    Py_DecRef(r);
    return 0;
}

/* Fill every constant cache while attached at module exec, so that the
 * accessors are plain table reads afterwards and a lazy error value forced on
 * a detached thread never imports anything. */
static void h2py_runtime_warm(void)
{
    for (int i = 0; i < H2PY_NEXCEPTIONS; i++) {
        h2py_exception_type(i);
    }
    for (int i = 0; i < 15; i++) {
        h2py_builtin_type(i);
    }
    h2py_none();
    h2py_true();
    h2py_false();
    h2py_not_implemented();
    PyErr_Clear();
}

int h2py_runtime_register_hooks(PyObject *module)
{
    h2py_runtime_warm();
    if (PyModule_AddFunctions(module, h2py_hook_methods) < 0) {
        return -1;
    }
    int rc = -1;
    PyObject *atexit = NULL, *os = NULL, *register_fn = NULL, *at_fork = NULL;
    PyObject *on_exit = NULL, *on_fork = NULL, *r = NULL;

    atexit = PyImport_ImportModule("atexit");
    if (atexit == NULL) goto done;
    on_exit = PyObject_GetAttrString(module, "_h2py_atexit");
    if (on_exit == NULL) goto done;
    r = PyObject_CallMethod(atexit, "register", "O", on_exit);
    if (r == NULL) goto done;
    Py_DecRef(r);
    r = NULL;

    os = PyImport_ImportModule("os");
    if (os == NULL) goto done;
    if (PyObject_HasAttrString(os, "register_at_fork")) {
        at_fork = PyObject_GetAttrString(os, "register_at_fork");
        if (at_fork == NULL) goto done;
        on_fork = PyObject_GetAttrString(module, "_h2py_after_fork");
        if (on_fork == NULL) goto done;
        if (h2py_call_kw(at_fork, "after_in_child", on_fork) < 0) goto done;
    }
    rc = 0;
done:
    Py_DecRef(atexit);
    Py_DecRef(os);
    Py_DecRef(register_fn);
    Py_DecRef(at_fork);
    Py_DecRef(on_exit);
    Py_DecRef(on_fork);
    return rc;
}

/* See include/h2py/weakapi.h for why every CPython reference here is weak on macOS. */


