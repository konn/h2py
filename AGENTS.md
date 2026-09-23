# AGENTS.md

This file is the source of truth for coding-agent guidance in this repository.
`CLAUDE.md` is a symlink to it, so Claude Code and Codex read the same policy.

## Overview

**H2Py** lets one write CPython extension modules in Haskell in the spirit of [PyO3](https://pyo3.rs), on top of [pure-borrow](https://github.com/SoftwareFoundationGroupAtKyotoU/pure-borrow)'s Rust-style borrowing.
The design document is `docs/H2Py-DESIGN.md`; read it before changing the object model, the attachment discipline, the arena, or the lend state.
Two decisions carry everything: a Python object reference is a `pure-borrow` borrow of an arena-owned slot (`Bound π t = Mut π (PyRef t)`, `Borrowed π t = Share π (PyRef t)`), and the code that may touch CPython is `Py π γ = BO' (Python π) γ`, a world of pure-borrow's impure `BO'` that carries the attachment scope `π` separately from the borrow lifetime `γ`.

Packages:

- `h2py/` — the library: `H2Py` (prelude and tutorial), `H2Py.Py` (the world and its delimiters), `H2Py.Object` (references and protocol operations), `H2Py.Class` (payload classes, `H2Py.Class.Slot` for the protocol slots, `H2Py.Class.Iterator` for `HsIterator`), `H2Py.Convert`, `H2Py.Exception`, `H2Py.Module` (registration, trampolines, stubs), `H2Py.TH` (the splices), `H2Py.Buffer` (NumPy buffers), `H2Py.Runtime`, each with `.Internal` and, where there are trusted hatches, `.Unsafe` siblings on pure-borrow's suffix convention; the C shim `cbits/h2py.c`, the wrappers `cbits/api.c`, the RTS initialisation `cbits/rts_init.c`, and the headers under `include/h2py/`.
- `h2py-examples/` — the one example extension module, `h2py_examples`, with its submodules `nparallel`, `shapes`, `concurrency`, `ops` and `tutorial` (one Haskell module each under `src/H2Py/Examples/`, registered in `Module.hs`), its `pytest` suite under `tests/`, the committed stub package under `stubs/`, and the Python packaging under `python/`.
- `docs/` — the design (`H2Py-DESIGN.md`), the amendments taken while implementing it (`IMPLEMENTATION-NOTES.md`) and the tutorial (`tutorial.md`).

## Toolchain

- GHC 9.12.4 pinned through `cabal.project.local`, which `scripts/configure-python.sh` writes; it also records the include directory of the target CPython, taken from `sysconfig`.
  Run it once per interpreter: `scripts/configure-python.sh /path/to/python3.13`.
- `pure-borrow` comes from a `source-repository-package` stanza in `cabal.project`, pinned to the head of its `konn/impure-pure-borrow-tagged` branch; H2Py needs the world-indexed `BO'` that only that branch has.
- Cabal nix-style builds only; `cabal.project` is the source of truth.
  No `package.yaml`.
- Python: `uv venv --python python3.13 .venv && uv pip install numpy pytest mypy`.
  CPython 3.12 and later for `abi3`; the `abi3t` flag needs CPython 3.15.

## Build / test

```bash
cabal build all                                  # library, tests, and the extension module
cabal test all                                   # h2py-test (tasty), h2py-inspection (Core of qsortDC at Storable), h2py-weakcheck
scripts/check-typing-fail.sh                     # fixtures under h2py/test/typing-fail must fail to compile
scripts/install-module.sh                        # copies the built .dylib/.so to build/h2py_examples.abi3.so
PYTHONPATH=build .venv/bin/python -m pytest h2py-examples/tests   # Python suite against build/
scripts/gen-weakapi.sh --check                   # macOS: every CPython reference of the library is weak
scripts/build-wheel.sh                           # a repaired wheel, installed and imported in a fresh venv
```

`scripts/test-all.sh` runs everything but the wheel in order, including the stub package's regeneration, `mypy --strict` on it and its comparison with the committed copy under `h2py-examples/stubs/` (regenerate with `scripts/h2py-stubs.py --path build --output h2py-examples/stubs h2py_examples` after a change to a registration).
A stale `~/.local/bin/c2hs` on this machine hangs cabal's configure probe in uninterruptible sleep; run cabal with that directory dropped from `PATH` until it is removed.
`fourmolu` cannot read the `default-extensions` of a `foreign-library` stanza, so the sources of `h2py-examples` are formatted with the stanza's extensions passed explicitly (`fourmolu -o -XLinearTypes -o -XQualifiedDo … -i file.hs`; the CI job has the full list); the library's sources need no flags.
A change under `h2py/src`, `h2py/cbits`, `h2py/include` or `h2py-examples/` must pass all of them before it is committed.
Never invoke a bare `python3` in this repository; use `.venv/bin/python`.

## The macOS rule for CPython references

GHC loads `libHSh2py` into its own process, with no interpreter, to run the Template Haskell splices of any module that uses `pyclass`, `pymethods` or `pymodule`, and dyld on current macOS binds every symbol of a library at load time.
So the library may reference the interpreter only through weak imports, and Cabal passes neither `ld-options` nor `ghc-shared-options` to the library's dylib link, which rules out a linker flag.
Three rules follow, all mechanical:

- No CPython *data* symbol is referenced anywhere (`PyExc_*`, `Py_None`, `Py_True`, `&PyLong_Type`); `h2py.c` fetches such constants through `builtins` at first use and caches them (`h2py_exception_type`, `h2py_builtin_type`, `h2py_none`).
- Every CPython function the Haskell side calls goes through a one-line wrapper in `h2py/cbits/api.c`; a `foreign import` never names a `Py*` symbol directly.
- `h2py/include/h2py/weakapi.h`, included by `h2py.h` after `Python.h`, holds a `#pragma weak` for every referenced symbol; after adding a CPython call, build the library and run `scripts/gen-weakapi.sh`, then rebuild; `--check` is what CI runs.

## Conventions

- Follow pure-borrow's `AGENTS.md` for everything about linear ownership, lifetimes, `Copyable` versus `Movable`, `NOINLINE` on anything reaching `unsafePerformIO`, and the module-suffix boundary (`.Internal` real definitions, `.Unsafe` trusted hatches, `Utils` private).
- `(<>)` over `(++)`.
- One sentence per line in prose, including Haddock and commit bodies.
- `Note [...]` blocks are dev notes in plain block comments, cited as `See Note [...]`, never Haddock.
- Lifetime variables are `α`, `β`, `γ`, with `π` reserved for the Python attachment scope and `δ` for a detach window.
- Every CPython call that can run Python code, block, or call back into Haskell is a `safe` foreign import; only `Py_IncRef` and exact-type leaf reads are `unsafe`.
- Every Python operation begins with the shim's attachment check; a `NotAttached` exception, not undefined behaviour, is the outcome of calling from the wrong thread.
- Python errors are values (`PyResult a = Either PyErr a`); Haskell exceptions are the exceptional path and poison what the arena holds mutably.
- `PyClass`, `PyFrozenClass`, `PyTypeOf`, `PyExtends` and `PyExceptionClass` are sealed: their witness constructor `UnsafeSealed` lives in `H2Py.Object.Internal` and is exported by `.Unsafe` only, the splices generate it, and every operation that trusts an instance forces it first (`Note [Sealed classes]`); a hand-written instance of any of them is trusted code.
- Format before compiling: fourmolu (`fourmolu.yaml`) for Haskell, cabal-gild for cabal files; the hooks in `.agents/hooks/` do it on every edit.
- Commits follow Conventional Commits with a `Co-authored-by:` trailer and no session metadata.

## Adversarial review

The review discipline of pure-borrow's `AGENTS.md` applies to every change that touches the object model, the arena, the lend state, the attachment discipline, the trampoline, or any `unsafe` use: a plan review before implementation and an implementation review before commit, by subagents that did not write the change, one lens each (linear ownership, soundness, runtime/FFI/concurrency, ergonomics), each instructed to refute.
Findings are fixed or rebutted in writing; a soundness or ownership finding is never dropped.

## Test discipline

- "Must not typecheck" cases live in `TypingCases` modules compiled with `-fdefer-type-errors -Wno-deferred-type-errors` and are forced at runtime; multiplicity errors, which GHC does not defer, live under `h2py/test/typing-fail/` and are checked by `scripts/check-typing-fail.sh`.
- Refcount deltas are asserted from Python with `sys.getrefcount`, including on `Left` and Haskell-exception paths.
- `expectFailBecause` only for properties we want and do not yet have.
