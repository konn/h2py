"""Deep Python -> Haskell -> Python recursion ends in RecursionError, not a crash.

Every trampoline entry re-enters the Haskell runtime on the calling thread,
which costs far more C stack per level than CPython's own recursion
accounting assumes, so the shim refuses a call when the thread's C stack is
nearly exhausted, with a RecursionError.
The recursion runs in a subprocess with the Python limit raised far beyond
what the C stack can hold, so that the guard, and not Python's counter, is
what stops it, and so that a crash would fail the test instead of the suite.
"""

import subprocess
import sys

CHILD = r"""
import sys
sys.path[:0] = {path!r}
import h2py_examples as m
ops = m.ops
sys.setrecursionlimit(1_000_000)
depth = 0

def rec():
    global depth
    depth += 1
    return ops.call(rec, [])

try:
    rec()
    print("no error")
except RecursionError as e:
    print("RecursionError:", e)
print("depth", depth)
# The interpreter and the module are still usable afterwards.
print("after", ops.call(len, [[1, 2, 3]]), ops.roundtrip_int(7))
"""


def test_deep_recursion_through_the_module_raises_recursion_error():
    script = CHILD.format(path=sys.path)
    proc = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert proc.returncode == 0, (proc.returncode, proc.stderr[-2000:])
    lines = proc.stdout.splitlines()
    assert any(ln.startswith("RecursionError:") and "through a Haskell call" in ln for ln in lines), proc.stdout
    depth = int(next(ln for ln in lines if ln.startswith("depth ")).split()[1])
    assert depth > 10, depth
    assert "after 3 7" in lines


CHILD_THREADS = r"""
import sys
import threading
sys.path[:0] = {path!r}
import h2py_examples as m
ops = m.ops
sys.setrecursionlimit(1_000_000)

def run(results):
    depth = 0
    def rec():
        nonlocal depth
        depth += 1
        return ops.call(rec, [])
    try:
        rec()
        results.append(("no-error", depth, ""))
    except RecursionError as e:
        results.append(("RecursionError", depth, str(e)))

# The shim finds each thread's stack bounds once, at the thread's first call.
# The second thread runs on a 64 MiB stack, which cannot be the first one's,
# so a bound wrongly shared between threads would cut it short (or let it
# overflow); the main thread runs last, after both.
for size in (0, 64 << 20):
    threading.stack_size(size)
    results = []
    t = threading.Thread(target=run, args=(results,))
    t.start()
    t.join()
    print("thread", size >> 20, *results[0][:2], results[0][2])
threading.stack_size(0)
results = []
run(results)
print("main", 0, *results[0][:2], results[0][2])
print("after", ops.call(len, [[1, 2, 3]]), ops.roundtrip_int(7))
"""


def test_deep_recursion_on_other_threads_raises_recursion_error():
    script = CHILD_THREADS.format(path=sys.path)
    proc = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert proc.returncode == 0, (proc.returncode, proc.stderr[-2000:])
    lines = proc.stdout.splitlines()
    outcomes = [ln.split(maxsplit=4) for ln in lines if ln.startswith(("thread ", "main "))]
    assert len(outcomes) == 3, proc.stdout
    for _, _, outcome, depth, message in outcomes:
        # The shim's own guard stopped each recursion, deep enough to show that
        # it did not refuse a thread's first call.
        assert outcome == "RecursionError", proc.stdout
        assert "through a Haskell call" in message, proc.stdout
        assert int(depth) > 10, proc.stdout
    # The larger stack was measured as its own.
    assert int(outcomes[1][3]) > 1.5 * int(outcomes[0][3]), proc.stdout
    assert "after 3 7" in lines
