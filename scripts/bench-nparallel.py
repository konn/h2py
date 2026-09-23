#!/usr/bin/env python
"""Time h2py_examples.nparallel against NumPy across core counts.

Usage: PYTHONPATH=build .venv/bin/python scripts/bench-nparallel.py [repeats] [--cores 1,2,4,8]

The RTS reads H2PY_RTS_OPTS once, at the module's first import, so the sweep
re-runs this script in one subprocess per core count with H2PY_RTS_OPTS=-N<k>
(the module's own "-N" comes first and the environment's setting wins).
Each child measures the Haskell kernels, best of `repeats`, and prints them as
JSON; the parent measures NumPy once and prints one table.

sort_in_place and sum run at 1e6 and 1e7 elements; fft needs a power of two,
so it runs at 2**20 and 2**23, the powers nearest to those.
"""
import json
import os
import subprocess
import sys
import time

import numpy as np

SORT_SIZES = (1_000_000, 10_000_000)
FFT_SIZES = (1 << 20, 1 << 23)
DEFAULT_CORES = (1, 2, 4, 8)


def best_of(repeats, prepare, run):
    best = float("inf")
    for _ in range(repeats):
        arg = prepare()
        t0 = time.perf_counter()
        run(arg)
        best = min(best, time.perf_counter() - t0)
    return best


def inputs():
    rng = np.random.default_rng(0)
    real = {n: rng.standard_normal(n) for n in SORT_SIZES}
    cplx = {n: rng.standard_normal(n) + 1j * rng.standard_normal(n) for n in FFT_SIZES}
    return real, cplx


def measure_h2py(repeats):
    import h2py_examples

    np_ = h2py_examples.nparallel
    real, cplx = inputs()
    out = {}
    for n, base in real.items():
        out[f"sort/{n}"] = best_of(repeats, lambda: base.copy(), np_.sort_in_place)
        check = base.copy()
        np_.sort_in_place(check)
        assert np.array_equal(check, np.sort(base))
        out[f"sum/{n}"] = best_of(repeats, lambda: base, np_.sum)
        assert abs(np_.sum(base) - float(np.sum(base))) < 1e-6 * max(1.0, abs(float(np.sum(base))))
        out[f"stencil/{n}"] = best_of(repeats, lambda: base.copy(), np_.stencil)
    for n, base in cplx.items():
        out[f"fft/{n}"] = best_of(repeats, lambda: base.copy(), np_.fft)
        check = base.copy()
        np_.fft(check)
        expected = np.fft.fft(base)
        # The twiddle recurrence of pure-borrow's butterfly drifts about
        # linearly with n; see assert_fft_close in tests/test_nparallel.py.
        assert np.linalg.norm(check - expected) / np.linalg.norm(expected) <= 4e-11 * n
    return out


def measure_numpy(repeats):
    real, cplx = inputs()
    out = {}
    for n, base in real.items():
        out[f"sort/{n}"] = best_of(repeats, lambda: base.copy(), np.sort)
        out[f"sum/{n}"] = best_of(repeats, lambda: base, np.sum)
        kernel = np.ones(3) / 3
        out[f"stencil/{n}"] = best_of(repeats, lambda: base, lambda a: np.convolve(a, kernel, mode="same"))
    for n, base in cplx.items():
        out[f"fft/{n}"] = best_of(repeats, lambda: base, np.fft.fft)
    return out


def run_child(repeats, cores):
    env = dict(os.environ, H2PY_RTS_OPTS=f"-N{cores}")
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__), "--child", str(repeats)],
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(proc.stdout.strip().splitlines()[-1])


def main():
    args = sys.argv[1:]
    if args and args[0] == "--child":
        print(json.dumps(measure_h2py(int(args[1]))))
        return
    cores = DEFAULT_CORES
    if "--cores" in args:
        i = args.index("--cores")
        cores = tuple(int(c) for c in args[i + 1].split(","))
        del args[i : i + 2]
    repeats = int(args[0]) if args else 3
    numpy_times = measure_numpy(repeats)
    h2py_times = {k: run_child(repeats, k) for k in cores}
    rows = [
        ("sort_in_place", "np.sort", "sort", n) for n in SORT_SIZES
    ] + [
        ("fft", "np.fft.fft", "fft", n) for n in FFT_SIZES
    ] + [
        ("sum", "np.sum", "sum", n) for n in SORT_SIZES
    ] + [
        ("stencil", "np.convolve", "stencil", n) for n in SORT_SIZES
    ]
    print(
        f"best of {repeats}, milliseconds; {os.cpu_count()} logical cores; "
        f"CPython {sys.version.split()[0]}, NumPy {np.__version__}"
    )
    header = f"{'kernel':<14} {'n':>11} {'numpy':>9}" + "".join(f"{'-N' + str(k):>9}" for k in cores)
    print(header)
    for name, np_name, key, n in rows:
        base = numpy_times[f"{key}/{n}"]
        cells = "".join(f"{1e3 * h2py_times[k][f'{key}/{n}']:>9.1f}" for k in cores)
        print(f"{name:<14} {n:>11,} {1e3 * base:>9.1f}{cells}   ({np_name})")


if __name__ == "__main__":
    main()
