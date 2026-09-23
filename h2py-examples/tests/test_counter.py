import sys

import pytest

import h2py_examples as m


def test_add():
    assert m.add(1, 2) == 3
    assert m.add(x=1, y=2) == 3
    assert m.add(40, y=2) == 42


def test_add_type_error():
    with pytest.raises(TypeError):
        m.add("a", 1)
    with pytest.raises(TypeError):
        m.add(1)
    with pytest.raises(TypeError):
        m.add(1, 2, 3)
    with pytest.raises(TypeError):
        m.add(1, z=2)


def test_counter():
    c = m.Counter(40)
    c.incr(2)
    assert c.get() == 42
    assert c.label() == "Counter(42)"
    c.incr(k=-2)
    assert c.get() == 40


def test_counter_doc():
    assert "Haskell heap" in m.Counter.__doc__
    assert "Add k" in m.Counter.incr.__doc__


def test_counter_wrong_receiver_arg():
    c = m.Counter(1)
    with pytest.raises(TypeError):
        c.incr("x")


def test_refcounts_are_stable():
    c = m.Counter(3)
    before = sys.getrefcount(c)
    for _ in range(100):
        c.incr(1)
        c.get()
        c.label()
    assert sys.getrefcount(c) == before


def test_many_objects_are_collected():
    for i in range(1000):
        c = m.Counter(i)
        assert c.get() == i
    del c


def test_stub():
    stub = m.__h2py_stub__()
    assert "class Counter" in stub
    assert "def add(x: int, y: int) -> int" in stub
