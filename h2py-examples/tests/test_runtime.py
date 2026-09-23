import concurrent.futures
import sys
import threading
import time

import pytest

import h2py_examples as m


def test_module_metadata():
    assert m.Counter.__module__ == "h2py_examples"
    assert m.Counter.__name__ == "Counter"
    assert m.__doc__ == "H2Py's example module."


def test_calls_from_many_threads():
    counters = [m.Counter(0) for _ in range(8)]

    def work(c, n):
        for _ in range(n):
            c.incr(1)
        return c.get()

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda c: work(c, 2000), counters))
    assert results == [2000] * 8


def test_shared_object_from_many_threads_serialises():
    # Under the GIL each call is atomic with respect to the others; the lend
    # state refuses a concurrent writer, which never happens here because
    # every call holds the interpreter for its whole duration.
    c = m.Counter(0)

    def work(n):
        for _ in range(n):
            c.incr(1)

    threads = [threading.Thread(target=work, args=(1000,)) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert c.get() == 4000


def test_refcount_on_error_paths():
    c = m.Counter(1)
    before = sys.getrefcount(c)
    for _ in range(50):
        with pytest.raises(TypeError):
            c.incr("no")
    assert sys.getrefcount(c) == before
    x = "an argument"
    before_x = sys.getrefcount(x)
    for _ in range(50):
        with pytest.raises(TypeError):
            m.add(x, 1)
    assert sys.getrefcount(x) == before_x


def test_result_refcount():
    c = m.Counter(7)
    s = c.label()
    # Only the local holds the result, so it counts as a fresh object held by
    # one local does: 2 up to CPython 3.13 and 1 from 3.14, which passes a
    # local to a call without a new reference.
    fresh = object()
    assert sys.getrefcount(s) == sys.getrefcount(fresh)


def test_call_overhead_is_bounded():
    n = 20000
    t0 = time.perf_counter()
    for _ in range(n):
        m.add(1, 2)
    per_call = (time.perf_counter() - t0) / n
    # A generous bound: the design targets coarse-grained calls, but a call
    # must not cost more than a few tens of microseconds.
    assert per_call < 50e-6, f"{per_call * 1e6:.1f} us per call"
