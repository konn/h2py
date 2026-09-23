# h2py-examples

The example extension module of H2Py, `h2py_examples`, and its Python packaging.

- `src/H2Py/Examples/Counter.hs`: the `Counter` class of the tutorial, with `add` as a module-level function.
- `src/H2Py/Examples/Module.hs`: the `pymodule` splice that declares `h2py_examples`.
- `src/H2Py/Examples/Tutorial.hs`: the two snippets of `docs/tutorial.md`, compiled here so that the tutorial cannot drift from the API; nothing in it is registered in the module.
- `cbits/init.c`: the C side, two lines (`H2PY_MODULE` and `<h2py/init.h>`), plus `H2PY_RTS_OPTS "-N"`.
- `tests/`: the `pytest` suite, which also asserts reference-count deltas with `sys.getrefcount`, calls from many threads, and the call overhead.
- `python/`: the `pyproject.toml` and hatchling build hook that package the module as a wheel.

```python
>>> import h2py_examples
>>> c = h2py_examples.Counter(40)
>>> c.incr(2); c.get()
42
>>> h2py_examples.add(1, 2)
3
```

## Building and testing

From the repository root, after `scripts/configure-python.sh` (see the root README):

```bash
cabal build h2py-examples
scripts/install-module.sh                                       # build/h2py_examples.abi3.so
PYTHONPATH=build .venv/bin/python -m pytest h2py-examples/tests
```

The module is a Cabal `foreign-library` of type `native-shared`, built with `-threaded` (mandatory: several Python threads may enter at once) and, on macOS, `-undefined dynamic_lookup`, because an extension module resolves the interpreter's symbols at load time rather than linking `libpython`.
It targets the limited API at 3.12, so the same file imports into CPython 3.12 and later.

## Wheel

```bash
scripts/build-wheel.sh   # build/wheelhouse/h2py_examples-0.1.0-cp312-abi3-<platform>.whl
```

The hook in `python/hatch_build.py` runs `cabal build`, copies the foreign library into the wheel as `h2py_examples.abi3.so`, imports it once to write `h2py_examples.pyi` from `__h2py_stub__()` next to a `py.typed` marker, and tags the wheel `cp312-abi3`.
`delocate-wheel` or `auditwheel` then bundles the Haskell runtime libraries, and the script verifies the wheel in a fresh venv.
The wheel can only be built from a checkout, since the Haskell sources live outside `python/`; the sdist is the packaging directory alone.

## Copyright

(c) Hiromi ISHII 2026- present, BSD-3-Clause.
