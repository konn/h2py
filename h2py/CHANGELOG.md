# Changelog for `h2py`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

### Added

- The `Py π γ` world on pure-borrow's world-indexed `BO'`, with the delimiters `attach`, `attach_`, `attach'`, `attach'_`, `detach` and `parPy`.
- Python object references as borrows of arena-owned slots, `Bound π t` and `Borrowed π t`, the GC-managed `PyHandle`, the built-in tags and the tag relation `:<:`, the protocol operations, constructors and `copyOut`.
- Classes with Haskell payloads: `pyclass`, `newObject`, `derefMut`, `derefShare`, `copyPayload`, frozen classes, the counted lend state with poisoning, and the `Slot` GADT for `__repr__`, `__hash__`, comparisons, the sequence and mapping protocols and iteration.
- Errors as values: `PyErr`, `PyResult`, `orFail`, `orThrow`, `throwPy`, the built-in exception tags, `newException`, and `ToPyErr` for Haskell exceptions crossing the boundary.
- Conversions `FromPy`, `ToPy` and the type hints `PyTypeHint`; the call boundary classes `FromArg`, `ToResult`, `PyCallable`, `PyMethod`, and `Detached` bodies that run with the interpreter released.
- Registration splices `pymethods` and `pymodule`, with `param`, `hint`, `resultAs`, `doc`, submodules and exceptions; `ModuleDesc`, `renderStubs`, `checkStubs`, and the hidden `__h2py_stub__()` every module exposes.
- The C shim (`cbits/h2py.c`), the wrapper layer `cbits/api.c` with the generated `include/h2py/weakapi.h` for Template Haskell on macOS, `cbits/rts_init.c`, and `include/h2py/init.h`, which makes the C side of a module two lines.
- Runtime hooks: the after-fork child hook that turns every call in a forked child into a `RuntimeError`, and the finalisation guard.
- The `abi3t` flag for the free-threaded stable ABI of PEP 803 (not yet exercised: it needs a released CPython 3.15).

## 0.1.0.0 - YYYY-MM-DD
