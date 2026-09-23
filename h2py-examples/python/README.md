# h2py-examples

The example CPython extension module of [H2Py](https://github.com/konn/h2py), a library for writing extension modules in Haskell in the spirit of PyO3.

```python
>>> import h2py_examples
>>> c = h2py_examples.Counter(40)
>>> c.incr(2); c.get()
42
>>> h2py_examples.add(1, 2)
3
```

The module is built against the CPython limited API at 3.12, so one wheel per platform serves CPython 3.12 and later.
It ships its own type stub (`h2py_examples.pyi`) and a `py.typed` marker.

## Building the wheel

The wheel can only be built from a checkout of the repository, because building it means building the Haskell extension with `cabal`.
From the repository root:

```bash
scripts/build-wheel.sh            # builds, repairs with delocate-wheel or auditwheel, verifies in a fresh venv
```

See `hatch_build.py` for what the build hook does, and the repository README for the toolchain.
