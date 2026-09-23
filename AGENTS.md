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
- cabal-install 3.14.2.0, in CI and in the manylinux bindists alike.
- `cabal.project` pins the Hackage `index-state`, so every build of a commit resolves the same versions and the committed licence notices keep matching the wheels.
  Bump it deliberately: then run `scripts/wheel-licenses.py --write` (see Wheels) and commit what it changes.
- On macOS, `cabal.project` passes `-mmacosx-version-min=11.0` to GHC's C and C++ compilers, assembler and linker for every package, so everything built targets macOS 11; as `ghc-options` it is part of every store package's hash, which `MACOSX_DEPLOYMENT_TARGET` is not.
  GHC does not recompile a module when only those options change, so remove `dist-newstyle/build` after changing the target.
- Python: `uv venv --python python3.13 .venv && uv pip install numpy pytest mypy`.
  CPython 3.12 and later for `abi3`; the `abi3t` flag needs CPython 3.15.

## Build / test

```bash
cabal build all                                  # library, tests, and the extension module
cabal test all                                   # h2py-test (tasty), h2py-inspection (Core of qsortDC at Storable), h2py-weakcheck
scripts/check-typing-fail.sh                     # fixtures under h2py/test/typing-fail must fail to compile
scripts/install-module.sh                        # copies the built .dylib/.so to build/h2py_examples.abi3.so
PYTHONPATH=build .venv/bin/python -m pytest h2py-examples/tests   # Python suite against build/
scripts/gen-weakapi.sh --check                   # every CPython reference of the library is weak
scripts/build-wheel.sh                           # a repaired macOS wheel, installed and checked in a fresh venv
scripts/test-wheel.sh .venv/bin/python macosx_11_0_arm64 build/wheelhouse   # the whole suite against the installed wheel
```

The manylinux wheel builds in the pinned PyPA image; named volumes keep GHC and the cabal store between runs, and the tree is mounted read-only:

```bash
docker run --rm -v "$PWD":/src:ro -v "$PWD/build/wheelhouse-linux":/out \
  -v h2py-ghc:/opt/ghc -v h2py-cabal:/opt/cabal -e CABAL_DIR=/opt/cabal -e H2PY_WHEEL_DIR=/out \
  quay.io/pypa/manylinux_2_28_aarch64:2026.09.14-1 /src/scripts/manylinux-wheel.sh
```

`scripts/test-all.sh` runs everything but the wheel in order, including the licence check of the wheel, the stub package's regeneration, `mypy --strict` on it and its comparison with the committed copy under `h2py-examples/stubs/` (regenerate with `scripts/h2py-stubs.py --path build --output h2py-examples/stubs h2py_examples` after a change to a registration).
A stale `~/.local/bin/c2hs` on this machine hangs cabal's configure probe in uninterruptible sleep; run cabal with that directory dropped from `PATH` until it is removed.
cabal decides what to recompile from the content of each source file, not of the headers it includes: after changing a header under `h2py/include`, remove the build directories of `h2py` and `h2py-examples` under `dist-newstyle/build` (touching the `.c` file is not enough).
`fourmolu` cannot read the `default-extensions` of a `foreign-library` stanza, so the sources of `h2py-examples` are formatted with the stanza's extensions passed explicitly (`fourmolu -o -XLinearTypes -o -XQualifiedDo … -i file.hs`; the CI job has the full list, `-XBangPatterns` included); the library's sources need no flags.
CI pins fourmolu 0.20.0.0, the version the editor hooks use; a newer one orders some imports differently.
A change under `h2py/src`, `h2py/cbits`, `h2py/include` or `h2py-examples/` must pass all of them before it is committed.
Never invoke a bare `python3` in this repository; use `.venv/bin/python`.

## The rule for CPython references

GHC loads `libHSh2py` into its own process, with no interpreter, to run the Template Haskell splices of any module that uses `pyclass`, `pymethods` or `pymodule`.
dyld on current macOS binds every symbol of a library at load time, and on Linux GHC's loader binds calls lazily but resolves the address of a function the shim stores in a slot table when it loads the library.
So the library may reference the interpreter only through weak imports, on both platforms, and Cabal passes neither `ld-options` nor `ghc-shared-options` to the library's shared link, which rules out a linker flag.
Three rules follow, all mechanical:

- No CPython *data* symbol is referenced anywhere (`PyExc_*`, `Py_None`, `Py_True`, `&PyLong_Type`); `h2py.c` fetches such constants through `builtins` at first use and caches them (`h2py_exception_type`, `h2py_builtin_type`, `h2py_none`).
- Every CPython function the Haskell side calls goes through a one-line wrapper in `h2py/cbits/api.c`; a `foreign import` never names a `Py*` symbol directly.
- `h2py/include/h2py/weakapi.h`, included by `h2py.h` after `Python.h`, holds a `#pragma weak` for every referenced symbol; after adding a CPython call, build the library and run `scripts/gen-weakapi.sh`, then rebuild; `--check` is what CI runs on macOS and Linux.

## Wheels

Only wheels are distributed: `cp312-abi3` for macOS 11 and later on arm64 and x86_64, and `manylinux_2_28` on x86_64 and aarch64.
There is no sdist upload and no musllinux wheel.

- `scripts/build-wheel.sh` builds, repairs (delocate) and checks the macOS wheel; `scripts/manylinux-wheel.sh` does the same inside the pinned PyPA `manylinux_2_28` image with pinned, checksummed GHC and cabal-install bindists built on glibc 2.28, and auditwheel bundles the Haskell libraries, libgmp and GHC's libffi.
  The build and repair tools and all their dependencies are locked with hashes in `h2py-examples/python/build-requirements.txt`, generated from `build-requirements.in` by the `uv pip compile` command written there.
- `h2py-examples/python/hatch_build.py` tags a macOS wheel from the deployment target in `cabal.project` and the built library's architecture, never from the interpreter, whose python.org builds report universal2.
- The licence files a wheel carries are committed under `h2py-examples/python/`: `LICENSE` and `third-party-licenses/` (its `README.txt` says what each file covers), because hatchling reads `project.license-files` before any build hook runs.
  `scripts/wheel-licenses.py --check` compares them with the build plan in the hook, in `scripts/test-all.sh` and in CI, and `--check-wheel` compares every library the repaired wheel bundles with them.
  After a dependency change, run it with `--write --ghc-source <unpacked ghc-9.12.4-src.tar.xz>`, since a GHC installation puts GHC's own licence in every boot library's documentation directory, and update the licence expression in `pyproject.toml` if it asks.
  Code of other origin compiled into a package (xxHash, LLVM's relocation tables, GMP) has its own notice, listed in the script's `EXTRA_NOTICES`; search a new dependency's C sources for third-party copyright notices before adding it.
  `scripts/manylinux-wheel.sh` refuses an image whose gmp package is not the one `GMP-NOTICE.txt` names, so bumping the image tag means updating the notice and its source links.
- CI runs the build-and-test job on all four platforms (x86_64 and aarch64 Linux, Apple silicon and Intel macOS), builds each wheel on its platform, then `scripts/test-wheel.sh` installs it into clean interpreters, the oldest and newest CPython it claims from the runner and from uv's managed builds, and runs the whole test suite against it, the Linux wheels also in AlmaLinux 8, the oldest glibc their tag admits, and in Debian 13, whose glibc 2.41 refuses executable stacks; one build leg checks the boot libraries' licence texts against GHC's source release.
  `scripts/check-installed-wheel.py` checks that the module and every Haskell library come from the wheel and that the licences and stubs are installed; the `Wheels` job collects the tested wheels and their checksums into one artifact, and the `CI` job, the one to require in branch protection, fails unless every other job succeeded.

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
