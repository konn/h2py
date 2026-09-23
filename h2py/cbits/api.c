/*
 * Thin wrappers over the CPython limited API for the Haskell side.
 *
 * H2Py.Runtime.Internal imports these instead of the CPython functions
 * themselves, so that every reference to the interpreter from the h2py
 * library is made in C, where <h2py/weakapi.h> marks it weak.  A weak
 * reference lets GHC dlopen the library with no interpreter in its process,
 * to run Template Haskell splices, and binds to the interpreter as usual once
 * the extension module is imported.
 *
 * Each wrapper has exactly the signature of the function it wraps; the
 * safe/unsafe distinction is made on the Haskell side.
 */
#include <h2py/h2py.h>

#define H2PY_WRAP(ret, name, params, args) \
    ret h2py_api_##name params { return name args; }
#define H2PY_WRAP_VOID(name, params, args) \
    void h2py_api_##name params { name args; }

H2PY_WRAP_VOID(Py_IncRef, (PyObject *o), (o))
H2PY_WRAP_VOID(Py_DecRef, (PyObject *o), (o))

H2PY_WRAP_VOID(PyErr_SetRaisedException, (PyObject *e), (e))
H2PY_WRAP_VOID(PyErr_SetObject, (PyObject *t, PyObject *v), (t, v))
H2PY_WRAP(PyObject *, PyErr_NewException, (const char *name, PyObject *base, PyObject *dict), (name, base, dict))

H2PY_WRAP(PyObject *, PyObject_Str, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyObject_Repr, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyObject_Type, (PyObject *o), (o))
H2PY_WRAP(int, PyObject_IsInstance, (PyObject *o, PyObject *t), (o, t))
H2PY_WRAP(int, PyObject_IsSubclass, (PyObject *o, PyObject *t), (o, t))
H2PY_WRAP(int, PyObject_IsTrue, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyObject_GetAttr, (PyObject *o, PyObject *n), (o, n))
H2PY_WRAP(PyObject *, PyObject_GetAttrString, (PyObject *o, const char *n), (o, n))
H2PY_WRAP(int, PyObject_SetAttrString, (PyObject *o, const char *n, PyObject *v), (o, n, v))
H2PY_WRAP(int, PyObject_HasAttrString, (PyObject *o, const char *n), (o, n))
H2PY_WRAP(PyObject *, PyObject_GetItem, (PyObject *o, PyObject *k), (o, k))
H2PY_WRAP(int, PyObject_SetItem, (PyObject *o, PyObject *k, PyObject *v), (o, k, v))
H2PY_WRAP(int, PyObject_DelItem, (PyObject *o, PyObject *k), (o, k))
H2PY_WRAP(Py_ssize_t, PyObject_Length, (PyObject *o), (o))
H2PY_WRAP(Py_hash_t, PyObject_Hash, (PyObject *o), (o))
H2PY_WRAP(int, PyObject_RichCompareBool, (PyObject *a, PyObject *b, int op), (a, b, op))
H2PY_WRAP(PyObject *, PyObject_RichCompare, (PyObject *a, PyObject *b, int op), (a, b, op))
H2PY_WRAP(PyObject *, PyObject_Vectorcall, (PyObject *f, PyObject *const *args, size_t n, PyObject *kw), (f, args, n, kw))
H2PY_WRAP(PyObject *, PyObject_Call, (PyObject *f, PyObject *args, PyObject *kw), (f, args, kw))
H2PY_WRAP(PyObject *, PyObject_CallNoArgs, (PyObject *f), (f))
H2PY_WRAP(PyObject *, PyObject_GetIter, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyIter_Next, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PySequence_GetItem, (PyObject *o, Py_ssize_t i), (o, i))
H2PY_WRAP(Py_ssize_t, PySequence_Size, (PyObject *o), (o))
H2PY_WRAP(int, PySequence_Check, (PyObject *o), (o))
H2PY_WRAP(int, PyMapping_Check, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyMapping_Items, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyDict_New, (void), ())
H2PY_WRAP(int, PyDict_SetItem, (PyObject *d, PyObject *k, PyObject *v), (d, k, v))
H2PY_WRAP(int, PyDict_SetItemString, (PyObject *d, const char *k, PyObject *v), (d, k, v))
H2PY_WRAP(PyObject *, PyList_New, (Py_ssize_t n), (n))
H2PY_WRAP(int, PyList_SetItem, (PyObject *l, Py_ssize_t i, PyObject *v), (l, i, v))
H2PY_WRAP(int, PyList_Append, (PyObject *l, PyObject *v), (l, v))
H2PY_WRAP(PyObject *, PyTuple_New, (Py_ssize_t n), (n))
H2PY_WRAP(int, PyTuple_SetItem, (PyObject *t, Py_ssize_t i, PyObject *v), (t, i, v))
H2PY_WRAP(Py_ssize_t, PyTuple_Size, (PyObject *t), (t))
H2PY_WRAP(PyObject *, PyTuple_GetItem, (PyObject *t, Py_ssize_t i), (t, i))
H2PY_WRAP(PyObject *, PySet_New, (PyObject *it), (it))
H2PY_WRAP(int, PySet_Add, (PyObject *s, PyObject *v), (s, v))
H2PY_WRAP(PyObject *, PyLong_FromLongLong, (long long n), (n))
H2PY_WRAP(long long, PyLong_AsLongLong, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyLong_FromString, (const char *s, char **end, int base), (s, end, base))
H2PY_WRAP(PyObject *, PyNumber_ToBase, (PyObject *o, int base), (o, base))
H2PY_WRAP(PyObject *, PyNumber_Long, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyNumber_Index, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyFloat_FromDouble, (double d), (d))
H2PY_WRAP(double, PyFloat_AsDouble, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyBool_FromLong, (long v), (v))
H2PY_WRAP(PyObject *, PyUnicode_FromStringAndSize, (const char *s, Py_ssize_t n), (s, n))
H2PY_WRAP(const char *, PyUnicode_AsUTF8AndSize, (PyObject *o, Py_ssize_t *n), (o, n))
H2PY_WRAP(PyObject *, PyBytes_FromStringAndSize, (const char *s, Py_ssize_t n), (s, n))
H2PY_WRAP(int, PyBytes_AsStringAndSize, (PyObject *o, char **s, Py_ssize_t *n), (o, s, n))
H2PY_WRAP(int, PyModule_AddFunctions, (PyObject *m, PyMethodDef *defs), (m, defs))
H2PY_WRAP(int, PyModule_AddObjectRef, (PyObject *m, const char *n, PyObject *v), (m, n, v))
H2PY_WRAP(PyObject *, PyModule_New, (const char *n), (n))
H2PY_WRAP(PyObject *, PyModule_GetNameObject, (PyObject *m), (m))
H2PY_WRAP(PyObject *, PyImport_ImportModule, (const char *n), (n))
H2PY_WRAP(PyObject *, PyImport_GetModuleDict, (void), ())
H2PY_WRAP(void *, PyType_GetSlot, (PyTypeObject *t, int slot), (t, slot))
H2PY_WRAP(int, PyType_IsSubtype, (PyTypeObject *a, PyTypeObject *b), (a, b))
H2PY_WRAP(int, PyCallable_Check, (PyObject *o), (o))
H2PY_WRAP(PyObject *, PyMemoryView_FromObject, (PyObject *o), (o))
