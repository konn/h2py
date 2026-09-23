/*
 * H2Py shim: the C side of H2Py, compiled once into the h2py library.
 *
 * Everything here uses only the CPython limited API at the 3.12 floor
 * (Py_LIMITED_API = 0x030C0000), or the free-threaded stable ABI of PEP 803
 * when H2PY_ABI3T is defined.  Object layouts are never computed: class
 * payloads live in type data reached through PyObject_GetTypeData (PEP 697),
 * and the type of an object is fetched with PyObject_Type.
 *
 * The Haskell side of the boundary is H2Py.Runtime.Internal, which imports
 * every function declared below.  A call that can run Python code, block, or
 * call back into Haskell is imported as a `safe` foreign call; the rest are
 * `unsafe`.  See docs/H2Py-DESIGN.md, sections 5.1 to 5.4.
 */
#ifndef H2PY_H2PY_H
#define H2PY_H2PY_H

#ifndef Py_LIMITED_API
#  ifdef H2PY_ABI3T
     /* PEP 803: the free-threaded stable ABI, final for CPython 3.15. */
#    define Py_TARGET_ABI3T 0x030F0000
#    define Py_LIMITED_API 0x030F0000
#  else
#    define Py_LIMITED_API 0x030C0000
#  endif
#endif

#include <Python.h>
#include <stddef.h>
#include <stdint.h>

#include <h2py/weakapi.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------
 * Runtime
 * --------------------------------------------------------------------- */

/* Initialise the GHC RTS once per process; idempotent.  Returns 0, or -1 with
 * a Python exception set. */
int h2py_runtime_init(void);

/* Register the module-level hooks (atexit flag, after-fork guard).  Called by
 * the generated module exec slot; returns 0, or -1 with an exception set. */
int h2py_runtime_register_hooks(PyObject *module);

/* Non-zero once the interpreter is finalising (Py_IsFinalizing where the
 * limited API has it, and always the atexit flag), or after an os.fork() in
 * the child, where the RTS is unusable. */
int h2py_is_finalizing(void);
int h2py_is_forked_child(void);

/* ------------------------------------------------------------------------
 * Attachment
 *
 * The shim keeps a thread-local flag that says whether the current thread
 * holds the interpreter for H2Py: set by the trampoline on entry, by
 * PyGILState_Ensure and PyEval_RestoreThread; cleared on exit, by
 * PyGILState_Release and PyEval_SaveThread.  PyGILState_Check is not in the
 * limited API, which is why the flag exists.
 * --------------------------------------------------------------------- */

/* The flag, plus PyGILState_GetThisThreadState() != NULL as a second check
 * that catches a Haskell worker thread which never attached. */
int h2py_is_attached(void);

/* ------------------------------------------------------------------------
 * Arenas
 *
 * Every attachment owns an arena: the sole owner of every +1 created during
 * it, a list of the holds it took on class payloads, and the buffer views it
 * opened.  Arenas are stacked per thread; the current one is the innermost.
 * --------------------------------------------------------------------- */

typedef struct h2py_arena h2py_arena;

/* Trampoline entry from Python, which holds the interpreter for the call:
 * mark the thread attached, drain the release pool, push a fresh arena.
 * Answers NULL with an exception set in the child of os.fork(), when the C
 * stack of the thread is nearly exhausted (RecursionError), or on
 * allocation failure. */
h2py_arena *h2py_call_begin(void);
/* Trampoline exit: sweep and pop the arena (poison != 0 on an exceptional
 * exit), drain the pool, restore the attachment flag. */
void h2py_call_end(h2py_arena *arena, int poison);

/* Attachment from Haskell (H2Py.Py.attach): refuse (NULL) when finalising or
 * in a forked child, else PyGILState_Ensure, mark attached, drain, push. */
h2py_arena *h2py_attach_begin(void);
/* Sweep and pop, drain, PyGILState_Release, restore the flag. */
void h2py_attach_end(h2py_arena *arena, int poison);

/* A nested scope on the same attached thread (H2Py.Py.attach'): push a child
 * arena.  Returns NULL if the thread is not attached. */
h2py_arena *h2py_scope_begin(void);
void h2py_scope_end(h2py_arena *arena, int poison);

/* Release the interpreter for a window (H2Py.Py.detach): PyEval_SaveThread,
 * clear the flag.  Returns the thread state to restore. */
void *h2py_detach_begin(void);
/* Restore it.  Returns 0, or -1 without restoring when the interpreter is
 * finalising, in which case the caller must never touch CPython again. */
int h2py_detach_end(void *thread_state);

/* The innermost arena of the current thread, or NULL. */
h2py_arena *h2py_arena_current(void);

/* Record a +1 the arena now owns.  Steals the reference. */
void h2py_arena_register(h2py_arena *arena, PyObject *object);

/* The type an object being constructed should be allocated with, recorded by
 * the tp_new trampoline of the class `cls` for the duration of a constructor
 * call.  `take` answers it for the first allocation of `cls` in that call,
 * searching outwards through nested scopes, and NULL for any other class. */
void h2py_arena_set_ctor(h2py_arena *arena, PyTypeObject *type, PyTypeObject *cls);
PyTypeObject *h2py_arena_take_ctor_type(h2py_arena *arena, PyTypeObject *cls);

/* ------------------------------------------------------------------------
 * Deferred release pool
 *
 * A PyHandle finaliser runs on the RTS finaliser thread, unattached, so it
 * only pushes; attached threads drain, swapping the vector out under the lock
 * and decref'ing outside it.
 * --------------------------------------------------------------------- */

void h2py_pool_push(PyObject *object);
void h2py_pool_drain(void);

/* ------------------------------------------------------------------------
 * Class payloads and the lend state
 *
 * A class instance carries, in its type data, a stable pointer to the Haskell
 * payload, one word of lend state, and the count of live buffer exports.
 * --------------------------------------------------------------------- */

#define H2PY_LEND_FREE     0
#define H2PY_LEND_MUT      (-1)
#define H2PY_LEND_POISONED (-2)

#define H2PY_CLAIM_OK       0
#define H2PY_CLAIM_BUSY     1
#define H2PY_CLAIM_EXPORTED 2
#define H2PY_CLAIM_POISONED 3

typedef struct h2py_cell h2py_cell;

/* The negative basicsize a payload-carrying type declares (PEP 697). */
Py_ssize_t h2py_cell_basicsize(void);

/* The cell of an instance of `type` (or of a subtype of it). */
h2py_cell *h2py_cell_of(PyObject *object, PyTypeObject *type);

void *h2py_cell_payload(h2py_cell *cell);
void h2py_cell_set_payload(h2py_cell *cell, void *stable_ptr);
intptr_t h2py_cell_lend(h2py_cell *cell);
intptr_t h2py_cell_exports(h2py_cell *cell);

/* Claim the object for this arena: Free -> Mut, then read the export count
 * under the claim.  The hold is recorded in the arena in the same call so that
 * an asynchronous exception cannot separate the two. */
int h2py_cell_claim_mut(h2py_arena *arena, PyObject *object, PyTypeObject *type);
/* Free -> Shared 1, or Shared n -> Shared n+1; refused against Mut. */
int h2py_cell_claim_shared(h2py_arena *arena, PyObject *object, PyTypeObject *type);
/* A transient shared claim with no arena record, for copyPayload. */
int h2py_cell_copy_begin(h2py_cell *cell);
void h2py_cell_copy_end(h2py_cell *cell);

/* Buffer exports on a class instance (the Buffer slot): claim the word first,
 * bump the count, release; refuse if the word is held. */
int h2py_cell_export_begin(h2py_cell *cell);
void h2py_cell_export_end(h2py_cell *cell);

/* Allocate an instance of `type` through its tp_alloc and zero its cell.
 * Returns a new reference, or NULL with an exception set. */
PyObject *h2py_alloc_instance(PyTypeObject *type);
/* The tail of tp_dealloc after the payload is gone: tp_free through the
 * actual type's slot, then the two decrefs the heap type needs. */
void h2py_finish_dealloc(PyObject *self);

/* ------------------------------------------------------------------------
 * Types, methods, modules
 * --------------------------------------------------------------------- */

/* PyType_FromModuleAndSpec over parallel slot arrays. */
PyObject *h2py_make_type(PyObject *module, const char *name, const char *doc,
                         Py_ssize_t basicsize, unsigned long flags,
                         const int *slot_ids, void *const *slot_funcs, int nslots,
                         PyObject *bases);

/* A malloc'ed, never freed, NULL-terminated PyMethodDef table. */
PyMethodDef *h2py_methoddefs_new(int count);
void h2py_methoddef_set(PyMethodDef *defs, int index, const char *name, void *func,
                        int flags, const char *doc);

/* Bind a fastcall argument vector against parameter names: positional
 * arguments fill from the left, keywords fill named parameters, and the rest
 * are errors.  `out` receives borrowed references.  Returns 0, or -1 with
 * TypeError set. */
int h2py_bind_args(PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames,
                   const char *const *names, Py_ssize_t nparams,
                   PyObject **out);

/* Unpack a tp_new / tp_call style (args, kwargs) pair into fastcall form.  The
 * returned vector is malloc'ed and freed with h2py_free; *kwnames is a new
 * reference or NULL. */
PyObject **h2py_unpack_call(PyObject *args, PyObject *kwargs, Py_ssize_t *nargs,
                            PyObject **kwnames);
void h2py_free(void *p);

/* Built-in type objects and constants, by index; see H2Py.Runtime.Internal. */
PyObject *h2py_builtin_type(int which);
PyObject *h2py_exception_type(int which);
PyObject *h2py_none(void);
PyObject *h2py_true(void);
PyObject *h2py_false(void);
PyObject *h2py_not_implemented(void);

/* Exceptions. */
void h2py_set_error(PyObject *type, const char *utf8);
int h2py_err_occurred(void);
PyObject *h2py_take_error(void);
void h2py_write_unraisable(PyObject *context);

/* Signals, on the main thread only. */
int h2py_check_signals(void);

/* ------------------------------------------------------------------------
 * Buffers
 * --------------------------------------------------------------------- */

typedef struct h2py_bufview h2py_bufview;

/* Request a C-contiguous buffer with format information; writable != 0 asks
 * for PyBUF_WRITABLE.  The view is recorded in the arena and released by the
 * sweep unless h2py_buffer_release is called first.  Returns NULL with an
 * exception set on failure, including a registry conflict. */
h2py_bufview *h2py_buffer_request(h2py_arena *arena, PyObject *object, int writable);
void *h2py_buffer_data(h2py_bufview *view);
Py_ssize_t h2py_buffer_len(h2py_bufview *view);
Py_ssize_t h2py_buffer_itemsize(h2py_bufview *view);
const char *h2py_buffer_format(h2py_bufview *view);
int h2py_buffer_readonly(h2py_bufview *view);
/* Give the exporter its buffer back early; idempotent.  The view struct lives
 * until the arena that recorded it is swept. */
void h2py_buffer_release(h2py_bufview *view);
int h2py_buffer_released(h2py_bufview *view);

/* The Buffer slot of a class: fill a Py_buffer over the payload's own storage
 * (a new reference to self is taken; shape and strides live in view->internal
 * until h2py_buffer_free_internal), mark a refused export, and free the
 * internal storage at release. */
int h2py_fill_buffer(Py_buffer *view, PyObject *self, void *data, Py_ssize_t len,
                     Py_ssize_t itemsize, const char *format, int flags);
void h2py_buffer_fail(Py_buffer *view);
void h2py_buffer_free_internal(Py_buffer *view);

/* The address of PyObject_HashNotImplemented, for Py_tp_hash of a class with
 * comparisons and no hash, so that its __hash__ is None as CPython's rule says. */
void *h2py_hash_not_implemented(void);

/* The exporter of Haskell-owned memory: a heap type whose instances hold a
 * stable pointer to the owner and a data pointer with a length. */
PyObject *h2py_hsbuffer_type(void);
PyObject *h2py_hsbuffer_new(void *stable_ptr, void *data, Py_ssize_t len,
                            Py_ssize_t itemsize, const char *format);

#ifdef __cplusplus
}
#endif

#endif /* H2PY_H2PY_H */
