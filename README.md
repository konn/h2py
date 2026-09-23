<p align="center"><img src="images/logo.svg" alt="H2Py" width="240"></p>

# H2Py

H2Py lets you write CPython extension modules in Haskell in the spirit of [PyO3](https://pyo3.rs): module-level functions, classes whose state lives in the Haskell heap, errors in both directions, conversions for the usual scalar and container types, and a call may release the interpreter to run multi-core Haskell kernels.
It is built on [pure-borrow](https://github.com/SoftwareFoundationGroupAtKyotoU/pure-borrow)'s Rust-style borrowing for Linear Haskell: a Python object reference is a borrow of an arena-owned slot, a method receives its payload as a `Mut` or `Share` borrow, and the code that may touch the interpreter runs in `Py π γ`, a world of pure-borrow's impure `BO'` monad that carries the attachment scope `π` next to the borrow lifetime `γ`.
The type checker refuses a reference that outlives its call, a payload mutated through two handles at once, and a Python operation from a thread that is not attached.

## A counter

```haskell
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}
module Counter where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.Pure
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Data.Ref.Linear.Borrow qualified as RefB
import Data.Text qualified as Text
import H2Py
import Prelude.Linear

newtype Counter = Counter (Ref Int)
  deriving newtype (Consumable)

pyclass ''Counter

new :: Int -> Py π π (PyResult (Bound π Counter))
new n = Control.do
  ref <- asksLinearly (Ref.new n)
  newObject (Counter ref)

incr :: forall π. Mut π Counter %1 -> Int -> Py π π ()
incr counter k = Control.do
  ref <- RefB.modify (+ k) (upcast counter :: Mut π (Ref Int))
  Control.pure (consume ref)

get :: Share π Counter -> Py π π Int
get counter = RefB.copyRef (coerceShare @(Ref Int) counter)

-- A Python object built while the payload is borrowed, returned from the method.
label :: Share π Counter -> Py π π (PyResult (Bound π PyStr))
label counter = Control.do
  Ur n <- Control.fmap move (RefB.copyRef (coerceShare @(Ref Int) counter))
  toStr (Text.pack ("Counter(" <> show n <> ")"))

pymethods ''Counter [constructor 'new, method "incr" 'incr, method "get" 'get, method "label" 'label]
pymodule "counter" [] [''Counter]
```

The C side of the module is two lines:

```c
#define H2PY_MODULE counter
#include <h2py/init.h>
```

```python
>>> import counter
>>> c = counter.Counter(40)
>>> c.incr(2); c.get()
42
>>> c.label()
'Counter(42)'
```

`incr` takes the payload as `Mut π Counter`, PyO3's `&mut self`, and `get` as `Share π Counter`, its `&self`; the lend state on the object refuses a second writer at runtime, the types refuse a second one in the same scope at compile time.
[`docs/tutorial.md`](docs/tutorial.md) walks through the example line by line, with the linearity mistakes a first module runs into and the GHC error text each one produces.

## Repository

- [`h2py/`](h2py/): the library, `H2Py` and its submodules, the C shim `cbits/h2py.c` and the headers under `include/h2py/`.
- [`h2py-examples/`](h2py-examples/): the example extension module `h2py_examples`, its `pytest` suite, and the Python packaging (`python/`).
- [`docs/tutorial.md`](docs/tutorial.md): the tutorial.
- [`scripts/`](scripts/): the build helpers described below.

## Building and testing

Toolchain: GHC 9.12.4 and cabal-install (through [ghcup](https://www.haskell.org/ghcup/)), CPython 3.12 or later with its headers, and [uv](https://docs.astral.sh/uv/) for the virtual environment.
On macOS the Xcode command line tools; on Linux a C toolchain and `libgmp`.

```bash
uv venv --python python3.13 .venv
uv pip install --python .venv/bin/python numpy pytest mypy
scripts/configure-python.sh .venv/bin/python   # writes cabal.project.local: compiler and Python.h
cabal build all                                # library, Haskell suite, extension module (2 to 4 minutes at -O2 the first time)
cabal test all                                 # Haskell suite
scripts/install-module.sh                      # copies the foreign library to build/h2py_examples.abi3.so
PYTHONPATH=build .venv/bin/python -m pytest h2py-examples/tests
```

`scripts/test-all.sh` runs the last four in order.
`pure-borrow` is pinned by a `source-repository-package` stanza in `cabal.project` to the branch that has the world-indexed `BO'`; the first build clones it.

The type stubs of a module are rendered by the module itself, from the same description the initialiser registers, and `scripts/h2py-stubs.py` writes them next to the extension: a module with submodules, such as `h2py_examples`, gets the stub-only package `h2py_examples-stubs/` (`__init__.pyi`, one `.pyi` per submodule and `py.typed`), which is the layout PEP 561 gives it.
`--check DIR` compares the rendered files with those under `DIR` instead of writing; the committed copy under `h2py-examples/stubs/` is what CI checks, so a change to the example's registration is regenerated with `--output h2py-examples/stubs`:

```bash
.venv/bin/python scripts/h2py-stubs.py --path build h2py_examples                          # build/h2py_examples-stubs/
.venv/bin/python -m mypy --strict build/h2py_examples-stubs
.venv/bin/python scripts/h2py-stubs.py --path build --check h2py-examples/stubs h2py_examples   # against the committed copy
```

Wheels are built by `scripts/build-wheel.sh` on macOS, and on Linux by `scripts/manylinux-wheel.sh` inside the PyPA `manylinux_2_28` image (with Docker, when run locally).
The hatchling hook in `h2py-examples/python/hatch_build.py` runs `cabal build`, renames the foreign library to `h2py_examples.abi3.so`, writes the same stub package with `scripts/h2py-stubs.py`, and tags the wheel `cp312-abi3`; `delocate-wheel` or `auditwheel` then bundles the Haskell runtime libraries with their load paths rewritten, and the script installs the result into a throwaway venv and checks it.
The wheels install on CPython 3.12 and later, on macOS 11 and later (arm64 and x86_64) and on Linux with glibc 2.28 or later (x86_64 and aarch64), and carry the licences of the Haskell libraries, GMP and libffi they bundle; CI builds all four and runs the test suite against each.

## Limitations

These features are not implemented yet:

- Subclassing a Python class from Haskell, `__slots__`, metaclasses, `async`/`await`.
  (`subclassable` on a `pyclass` lets Python code subclass a Haskell class.)
- Cycle-GC integration (`tp_traverse`) for payloads that hold Python references; a cycle through a payload leaks, as it did in early PyO3.
- Windows.
- More than one Haskell-built extension module per process.
- Embedding Python into a Haskell program; `inline-python` covers that direction.

Constraints of a GHC runtime inside a process it does not own:

- The runtime starts on first import, with `-threaded`, `--install-signal-handlers=no` so that `SIGINT` stays Python's, the options of the module's `H2PY_RTS_OPTS` define, and those of the `H2PY_RTS_OPTS` environment variable.
- `hs_exit` is never called: Python never unloads extension modules, and process exit reclaims everything.
  So `stdout` and `stderr` are not flushed by the runtime at exit, and no Haskell finaliser runs then.
- The process is multithreaded from the import on, so CPython warns on `os.fork()`, and a forked child cannot use the module: every call there raises `RuntimeError` naming the `spawn` start method.
- One runtime per process: two H2Py wheels each bundle their own `libHSrts` and cannot be imported together.
- Never block, while attached, on a Haskell thread that must itself attach; release the interpreter with `detach` first.

## Template Haskell and CPython symbols

The registration splices (`pyclass`, `pymethods`, `pymodule`) make GHC load `libHSh2py` into the compiler process, which has no Python interpreter in it.
Every CPython function the library calls therefore goes through a wrapper in `h2py/cbits/api.c`, and every CPython symbol referenced from C is marked `#pragma weak` in `h2py/include/h2py/weakapi.h`, so that the library loads with those symbols unresolved and binds them once an extension module is imported.
This is needed on macOS, where dyld binds every symbol when it loads a library, and on Linux, where the functions whose addresses the library keeps must be found when GHC loads it.
`scripts/gen-weakapi.sh` regenerates the header from the undefined symbols of the built library, and `--check` (run in CI on macOS and Linux) fails if a reference is missing or not weak; no CPython data symbol (`PyExc_*`, `Py_None`, `&PyLong_Type`) may be referenced, which is why constants are fetched through `h2py_exception_type`, `h2py_builtin_type` and `h2py_none`.
An interpreter that lacks one of those functions gets an `ImportError` naming it when the module is imported.

## Copyright

(c) Hiromi ISHII 2026- present, BSD-3-Clause.
