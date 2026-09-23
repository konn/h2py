# Changelog for `h2py-examples`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

### Added

- The `h2py_examples` extension module: the `Counter` class of the tutorial and the `add` function, built as a Cabal `foreign-library` against the limited API at 3.12.
- The `pytest` suite under `tests/`: behaviour, docstrings, reference-count deltas on success and error paths, calls from many threads, the stub, and a bound on the call overhead.
- `H2Py.Examples.Tutorial`, the two snippets of `docs/tutorial.md` compiled as part of the package.
- Python packaging under `python/`: a `pyproject.toml` with a hatchling build hook that runs `cabal build`, ships `h2py_examples.abi3.so` with its stub and `py.typed`, and tags the wheel `cp312-abi3`; `scripts/build-wheel.sh` repairs it with `delocate-wheel` or `auditwheel` and verifies it in a fresh venv.

## 0.1.0.0 - YYYY-MM-DD
