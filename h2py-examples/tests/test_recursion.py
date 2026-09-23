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
    assert any(ln.startswith("RecursionError:") for ln in lines), proc.stdout
    depth = int(next(ln for ln in lines if ln.startswith("depth ")).split()[1])
    assert depth > 10, depth
    assert "after 3 7" in lines
