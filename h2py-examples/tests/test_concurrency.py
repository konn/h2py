import _thread
import concurrent.futures
import os
import random
import resource
import signal
import subprocess
import sys
import threading
import time
import tracemalloc

import pytest

import h2py_examples as m

c = m.concurrency


def test_submodule_is_registered():
    import sys

    assert sys.modules["h2py_examples.concurrency"] is c
    assert "concurrency story" in c.__doc__


def test_sleep_detached_lets_other_threads_progress():
    counter = 0
    stop = threading.Event()

    def spin():
        nonlocal counter
        while not stop.is_set():
            counter += 1

    t = threading.Thread(target=spin)
    t.start()
    try:
        t0 = time.perf_counter()
        c.sleep_detached(0.5)
        elapsed = time.perf_counter() - t0
    finally:
        stop.set()
        t.join()
    assert elapsed >= 0.45
    # A Python thread starved by a held GIL would advance by a handful of
    # switch intervals at most; with the interpreter released it spins freely.
    assert counter > 10_000, counter


def test_par_sum_matches_builtin_sum():
    rng = random.Random(1234)
    for n in [0, 1, 2, 3, 7, 100, 1001, 10_000]:
        xs = [rng.randint(-1_000_000, 1_000_000) for _ in range(n)]
        assert c.par_sum(xs) == sum(xs)


def test_par_sum_rejects_non_integers():
    with pytest.raises(TypeError):
        c.par_sum([1, "two"])


def test_par_call_runs_both_callables():
    seen = []

    def f():
        seen.append("f")
        return 1

    def g():
        seen.append("g")
        return "two"

    assert c.par_call(f, g) == (1, "two")
    assert sorted(seen) == ["f", "g"]


def test_par_call_from_other_threads_too():
    assert c.par_call(threading.get_ident, threading.get_ident)


def test_par_call_propagates_python_errors_without_hanging():
    def boom():
        raise ValueError("boom")

    def fine():
        return 42

    t0 = time.perf_counter()
    with pytest.raises(ValueError, match="boom"):
        c.par_call(boom, fine)
    with pytest.raises(ValueError, match="boom"):
        c.par_call(fine, boom)
    with pytest.raises(ZeroDivisionError):
        c.par_call(lambda: 1 // 0, boom)
    assert time.perf_counter() - t0 < 5
    # The interpreter is still usable after the errors.
    assert c.par_call(fine, fine) == (42, 42)


def test_par_call_type_error_on_non_callable():
    with pytest.raises(TypeError):
        c.par_call(1, 2)


def test_call_from_unattached_thread_raises_not_attached():
    assert c.call_from_unattached_thread(object()) is True
    assert c.call_from_unattached_thread("a string") is True


def test_loop_with_scopes_returns_n():
    assert c.loop_with_scopes(0) == 0
    assert c.loop_with_scopes(10) == 10
    assert c.loop_with_scopes(100_000) == 100_000


def test_loop_with_scopes_does_not_grow_the_arena():
    # Every iteration creates one str inside its own attach'_ scope, whose
    # arena is swept at the end of the iteration; the call's own arena never
    # sees them, so neither the interpreter's heap nor the process grows.
    n = 200_000
    tracemalloc.start()
    try:
        c.loop_with_scopes(n)
        traced_before, _ = tracemalloc.get_traced_memory()
        c.loop_with_scopes(n)
        traced_after, _ = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    # A leaked str per iteration would add well over 10 MB here.
    assert traced_after - traced_before < 1024 * 1024, (traced_before, traced_after)

    rss_before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    c.loop_with_scopes(n)
    rss_after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    unit = 1 if sys.platform == "darwin" else 1024  # bytes on macOS, KiB elsewhere
    assert (rss_after - rss_before) * unit < 16 * 1024 * 1024, (rss_before, rss_after)


def test_interruptible_loop_completes_without_signals():
    assert c.interruptible_loop(0) == 0
    assert c.interruptible_loop(1000) == 1000


def test_interruptible_loop_is_interrupted_promptly_by_sigint():
    # An attached loop holds the interpreter, so no Python thread can run to
    # deliver anything; the signal has to come from outside, as a real SIGINT
    # does.  PyErr_CheckSignals inside the loop runs the default handler,
    # the KeyboardInterrupt is the call's result, and the loop stops early.
    previous = signal.signal(signal.SIGINT, signal.default_int_handler)
    killer = subprocess.Popen(["sh", "-c", f"sleep 0.2; kill -INT {os.getpid()}"])
    t0 = time.perf_counter()
    try:
        with pytest.raises(KeyboardInterrupt):
            c.interruptible_loop(400_000_000)
        elapsed = time.perf_counter() - t0
    finally:
        killer.wait()
        signal.signal(signal.SIGINT, previous)
    assert elapsed < 1.5, elapsed


def test_interrupt_main_from_a_thread_cannot_reach_an_attached_loop():
    # The other half of the rule: _thread.interrupt_main() from a Python
    # thread needs the interpreter, which the attached loop holds, so the loop
    # runs to completion and the interrupt is seen only afterwards, by the
    # eval loop.  Consume it there so it does not leak into the next test.
    seen = []
    previous = signal.signal(signal.SIGINT, lambda *_: seen.append(time.perf_counter()))
    timer = threading.Timer(0.1, _thread.interrupt_main)
    try:
        timer.start()
        t0 = time.perf_counter()
        assert c.interruptible_loop(5_000_000) == 5_000_000
        t1 = time.perf_counter()
        time.sleep(0.05)
    finally:
        timer.cancel()
        signal.signal(signal.SIGINT, previous)
    assert seen, "the interrupt was never delivered"
    assert seen[0] >= t1 - 1e-3, (seen, t0, t1)


def test_sleep_then_check_reports_interrupt_main_as_a_value():
    # A detached window lets the timer thread run interrupt_main; the first
    # checkSignals after re-attaching reports the KeyboardInterrupt as a Left,
    # which the function consumes, so nothing escapes to the eval loop.
    previous = signal.signal(signal.SIGINT, signal.default_int_handler)
    timer = threading.Timer(0.1, _thread.interrupt_main)
    try:
        timer.start()
        assert c.sleep_then_check(0.4) is True
        time.sleep(0.05)
    finally:
        timer.cancel()
        signal.signal(signal.SIGINT, previous)
    assert c.sleep_then_check(0.0) is False


def test_nested_attach_in_method():
    assert c.nested_attach_in_method() == len("hello, nested")
    assert c.SharedCounter(0).nested_attach_in_method() == len("hello, nested")


def test_shared_counter_basics():
    s = c.SharedCounter(5)
    s.incr(2)
    assert s.get() == 7
    assert s.hold_mut(0.0) == 8
    assert s.hold_share(0.0) == 8


def _run_in_thread(fn):
    result = {}

    def target():
        try:
            result["value"] = fn()
        except BaseException as e:  # noqa: BLE001
            result["error"] = e

    t = threading.Thread(target=target)
    t.start()
    return t, result


def test_writer_is_busy_against_a_detached_writer():
    s = c.SharedCounter(0)
    t, result = _run_in_thread(lambda: s.hold_mut(0.6))
    time.sleep(0.15)
    with pytest.raises(RuntimeError, match="busy"):
        s.incr(1)
    with pytest.raises(RuntimeError, match="busy"):
        s.get()
    with pytest.raises(RuntimeError, match="busy"):
        s.hold_share(0.0)
    t.join()
    assert "error" not in result, result
    assert result["value"] == 1
    # Usable again once the hold has ended.
    s.incr(1)
    assert s.get() == 2


def test_readers_proceed_together_and_a_writer_is_busy():
    s = c.SharedCounter(3)
    t, result = _run_in_thread(lambda: s.hold_share(0.6))
    time.sleep(0.15)
    assert s.get() == 3
    assert s.hold_share(0.0) == 3
    with pytest.raises(RuntimeError, match="busy"):
        s.incr(1)
    with pytest.raises(RuntimeError, match="busy"):
        s.hold_mut(0.0)
    t.join()
    assert "error" not in result, result
    assert result["value"] == 3
    s.incr(1)
    assert s.get() == 4


def test_two_detached_readers_from_two_threads():
    s = c.SharedCounter(9)
    t1, r1 = _run_in_thread(lambda: s.hold_share(0.4))
    t2, r2 = _run_in_thread(lambda: s.hold_share(0.4))
    t0 = time.perf_counter()
    t1.join()
    t2.join()
    assert time.perf_counter() - t0 < 0.8
    assert r1 == {"value": 9} and r2 == {"value": 9}


def test_thread_pool_mix_does_not_deadlock():
    shared = c.SharedCounter(0)
    deadline = time.perf_counter() + 2.0
    rng_seed = 42

    def work(worker):
        rng = random.Random(rng_seed + worker)
        done = 0
        busy = 0
        while time.perf_counter() < deadline:
            choice = rng.randrange(8)
            if choice == 0:
                c.sleep_detached(0.005)
            elif choice == 1:
                xs = [rng.randint(-100, 100) for _ in range(rng.randrange(50))]
                assert c.par_sum(xs) == sum(xs)
            elif choice == 2:
                assert c.par_call(lambda: worker, lambda: "g") == (worker, "g")
            elif choice == 3:
                assert c.loop_with_scopes(200) == 200
            elif choice == 4:
                assert c.nested_attach_in_method() == 13
            elif choice == 5:
                assert c.interruptible_loop(200) == 200
            elif choice == 6:
                try:
                    shared.hold_share(0.002)
                except RuntimeError as e:
                    assert "busy" in str(e)
                    busy += 1
            else:
                try:
                    shared.hold_mut(0.002)
                except RuntimeError as e:
                    assert "busy" in str(e)
                    busy += 1
            done += 1
        return done, busy

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(work, i) for i in range(8)]
        results = [f.result(timeout=60) for f in futures]
    assert all(done > 0 for done, _ in results), results
    assert shared.get() >= 0


# --- The receiver bodies of section 5.4 ------------------------------------------


class Spinner:
    """A Python thread that counts as fast as the interpreter lets it."""

    def __init__(self):
        self.count = 0
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._spin)

    def _spin(self):
        while not self.stop.is_set():
            self.count += 1

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop.set()
        self.thread.join()


def _advances_during(call, min_seconds=0.3):
    """Run call() while a spinner spins; the spinner must advance far more than a starved thread could."""
    with Spinner() as spinner:
        time.sleep(0.05)
        spinner.count = 0
        t0 = time.perf_counter()
        result = call()
        elapsed = time.perf_counter() - t0
    assert elapsed >= min_seconds * 0.8, elapsed
    assert spinner.count > 10_000, spinner.count
    return result


def _busy_during(start, probe, seconds=0.5):
    """probe() answers busy while start() runs on another thread."""
    t, result = _run_in_thread(start)
    time.sleep(seconds / 4)
    with pytest.raises(RuntimeError, match="busy"):
        probe()
    t.join()
    assert "error" not in result, result
    return result["value"]


def test_series_basics():
    s = c.Series([1, 2, 3])
    assert s.total() == 6
    s.scale(2)
    assert s.total() == 12
    assert s.hold_share_bio(0.0) == 12
    assert s.scale_bio(2, 0.0) is None
    assert s.total() == 24
    assert s.total_detached(3) == 72
    with pytest.raises(TypeError):
        c.Series(["x"])


def test_share_receiver_bio_body_releases_the_interpreter():
    s = c.Series([1, 2, 3])
    assert _advances_during(lambda: s.hold_share_bio(0.3)) == 6
    # A writer is busy while the shared hold lasts; readers proceed.
    assert _busy_during(lambda: s.hold_share_bio(0.5), lambda: s.scale(2)) == 6
    t, result = _run_in_thread(lambda: s.hold_share_bio(0.4))
    time.sleep(0.1)
    assert s.total() == 6
    t.join()
    assert result == {"value": 6}


def test_mut_receiver_bio_body_mutates_the_vector_detached():
    s = c.Series([1, 2, 3])
    assert _advances_during(lambda: s.scale_bio(2, 0.3)) is None
    assert s.total() == 12
    # Both a writer and a reader are busy while the mutable hold lasts.
    _busy_during(lambda: s.scale_bio(2, 0.5), lambda: s.total())
    assert s.total() == 24
    _busy_during(lambda: s.scale_bio(2, 0.5), lambda: s.scale(3))
    assert s.total() == 48


def test_bo_body_registered_detached_releases_the_interpreter():
    s = c.Series(list(range(2000)))
    expected = sum(range(2000))
    # Calibrate the pure kernel so that it runs for a few tenths of a second.
    t0 = time.perf_counter()
    assert s.total_detached(200) == expected * 200
    per_rep = (time.perf_counter() - t0) / 200
    reps = max(1, int(0.4 / per_rep))
    assert _advances_during(lambda: s.total_detached(reps), min_seconds=0.0) == expected * reps
    assert _busy_during(lambda: s.total_detached(reps), lambda: s.scale(2), seconds=0.4) == expected * reps
    assert s.total() == expected


# --- Exceptions in detached branches, and lazy errors off the interpreter --------


def test_par_bio_error_raises_instead_of_hanging():
    t0 = time.perf_counter()
    for _ in range(3):
        with pytest.raises(RuntimeError, match="boom in a parBIO branch"):
            c.par_bio_error()
    assert time.perf_counter() - t0 < 5
    assert c.par_sum([1, 2, 3]) == 6


def test_lazy_error_forced_on_a_detached_thread():
    for _ in range(3):
        with pytest.raises(ValueError) as info:
            c.lazy_error_detached()
        assert str(info.value) == "x"
    assert c.par_sum([1, 2]) == 3
