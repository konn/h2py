"""The snippets of docs/tutorial.md, run as the ``tutorial`` submodule."""

import gc
import sys

import pytest

import h2py_examples as m

t = m.tutorial


def test_submodule_is_registered():
    assert sys.modules["h2py_examples.tutorial"] is t
    assert t.Counter.__module__ == "h2py_examples.tutorial"
    assert t.Counter is not m.Counter
    assert "tutorial.md" in t.__doc__


def test_snippet_1_counter():
    c = t.Counter(40)
    c.incr(2)
    assert c.get() == 42
    assert c.label() == "Counter(42)"


def test_snippet_2_errors_callbacks_and_a_detached_body():
    c = t.Counter(1)
    c.set(5)
    assert c.get() == 5
    with pytest.raises(TypeError):
        c.set("five")
    assert c.get() == 5
    assert c.apply(lambda n: n * 3) is None
    assert c.get() == 15
    # The callback runs while the payload is held: reaching it again is busy.
    with pytest.raises(RuntimeError, match="busy"):
        c.apply(lambda n: c.get())
    assert c.get() == 15
    # A callback answering a non-int is a Left, and the value is kept.
    with pytest.raises(TypeError):
        c.apply(lambda n: "x")
    assert c.get() == 15
    assert c.square() == 225


def test_snippet_3_holding_a_python_object_across_calls():
    h = t.Holder()
    assert h.held() is None
    with pytest.raises(ValueError, match="nothing is held"):
        h.held_repr()
    obj = ["held", "list"]
    base = sys.getrefcount(obj)
    h.hold(obj)
    assert sys.getrefcount(obj) == base + 1
    assert h.held() is obj
    assert h.held_repr() == repr(obj)
    for _ in range(20):
        assert h.held() is obj
    assert sys.getrefcount(obj) == base + 1
    other = object()
    h.hold(other)
    assert h.held() is other
    h.release()
    assert h.held() is None
    del h
    gc.collect()
    # The handles die with the payload; their references go through the pool.
    for _ in range(10):
        m.ops.haskell_gc()
        m.ops.noop()
        if sys.getrefcount(obj) == base:
            break
    assert sys.getrefcount(obj) == base


def test_glossary_zero_argument_call():
    assert t.call_zero(lambda: "zero") == "zero"
    with pytest.raises(TypeError):
        t.call_zero(len)
    with pytest.raises(ZeroDivisionError):
        t.call_zero(lambda: 1 / 0)


def test_stub_mentions_the_tutorial():
    stub = t.__h2py_stub__()
    assert "class Counter" in stub
    assert "class Holder" in stub
    assert "def call_zero(f: Any) -> Any" in stub
