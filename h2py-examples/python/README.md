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
Wheels are built for macOS 11 and later (arm64 and x86_64) and for Linux with glibc 2.28 or later (`manylinux_2_28`, x86_64 and aarch64).
It ships its type stubs as the stub-only package `h2py_examples-stubs`, with a `py.typed` marker.

## Building the wheel

The wheel can only be built from a checkout of the repository, because building it means building the Haskell extension with `cabal`.
From the repository root:

```bash
scripts/build-wheel.sh            # macOS: builds, repairs with delocate-wheel, checks the wheel in a fresh venv
scripts/manylinux-wheel.sh        # Linux, inside quay.io/pypa/manylinux_2_28_<arch>: the same with auditwheel
```

See `hatch_build.py` for what the build hook does, and the repository README for the toolchain.
