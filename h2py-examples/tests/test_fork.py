"""The forked-child guard: the Haskell runtime is unusable after os.fork().

The module registers an ``after_in_child`` hook with ``os.register_at_fork``
that marks the child, and every trampoline entry refuses with a RuntimeError
naming the ``spawn`` start method instead of touching the runtime.
The fork happens in a subprocess with a timeout, so that a hang in the child
cannot take the suite down.
"""

import os
import subprocess
import sys

import pytest

CHILD = r"""
import os, sys, warnings
sys.path[:0] = {path!r}
warnings.simplefilter("ignore", DeprecationWarning)
import h2py_examples as m
assert m.add(1, 2) == 3
r, w = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(r)
    out = []
    for name, call in [("add", lambda: m.add(1, 2)), ("detach", lambda: m.concurrency.sleep_detached(0.0)), ("method", lambda: m.Counter(1).get())]:
        try:
            call()
            out.append(name + ": no error")
        except RuntimeError as e:
            out.append(name + ": RuntimeError: " + str(e))
        except BaseException as e:
            out.append(name + ": " + type(e).__name__ + ": " + str(e))
    os.write(w, "\n".join(out).encode())
    os.close(w)
    os._exit(0)
os.close(w)
chunks = []
while True:
    chunk = os.read(r, 65536)
    if not chunk:
        break
    chunks.append(chunk)
_, status = os.waitpid(pid, 0)
print(b"".join(chunks).decode())
print("child status", status)
# The parent is unaffected by the fork.
print("parent add", m.add(2, 3))
"""


@pytest.mark.skipif(not hasattr(os, "fork"), reason="os.fork is not available")
def test_calls_in_a_forked_child_raise_runtime_error_naming_spawn():
    script = CHILD.format(path=sys.path)
    proc = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.splitlines()
    for name in ("add", "detach", "method"):
        line = next(ln for ln in lines if ln.startswith(name + ":"))
        assert "RuntimeError" in line, line
        assert "spawn" in line, line
        assert "os.fork" in line, line
    assert "child status 0" in lines
    assert "parent add 5" in lines
