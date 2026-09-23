import collections.abc
import gc
import sys

import numpy as np
import pytest

import h2py_examples as m

sh = m.shapes


# --- Vec2: a frozen class with the number protocol ---------------------------


def test_vec2_repr_and_accessors():
    v = sh.Vec2(1.0, 2.0)
    assert repr(v) == "Vec2(1.0, 2.0)"
    assert str(v) == "Vec2(1.0, 2.0)"
    assert v.x() == 1.0
    assert v.y() == 2.0


def test_vec2_arithmetic():
    v = sh.Vec2(1.0, 2.0)
    w = sh.Vec2(10.0, 20.0)
    assert repr(v + w) == "Vec2(11.0, 22.0)"
    assert repr(w - v) == "Vec2(9.0, 18.0)"
    assert repr(v * 2) == "Vec2(2.0, 4.0)"
    assert repr(v * 2.5) == "Vec2(2.5, 5.0)"
    assert repr(3 * v) == "Vec2(3.0, 6.0)"
    assert repr(-v) == "Vec2(-1.0, -2.0)"
    assert abs(sh.Vec2(3.0, 4.0)) == 5.0


def test_vec2_not_implemented_fallbacks():
    v = sh.Vec2(1.0, 2.0)
    with pytest.raises(TypeError):
        v + 1
    # 1 + v takes the reflected path: int.__add__ answers NotImplemented, then
    # Vec2's slot is entered with self=1, which is not a Vec2, and there is no
    # reflected addition.
    with pytest.raises(TypeError):
        1 + v
    with pytest.raises(TypeError):
        v * "x"
    with pytest.raises(TypeError):
        "x" * v
    with pytest.raises(TypeError):
        v / 2
    with pytest.raises(TypeError):
        v < v
    assert v.__add__(1) is NotImplemented


def test_vec2_compare_and_hash():
    v = sh.Vec2(1.0, 2.0)
    w = sh.Vec2(1.0, 2.0)
    u = sh.Vec2(2.0, 1.0)
    assert v == w
    assert not (v != w)
    assert v != u
    assert v == v
    assert v != 3
    assert hash(v) == hash(w)
    assert len({v, w, u}) == 2


def test_vec2_call_by_value_receiver():
    v = sh.Vec2(1.0, 2.0)
    assert repr(v(3)) == "Vec2(3.0, 6.0)"
    assert repr(v(k=0.5)) == "Vec2(0.5, 1.0)"
    with pytest.raises(TypeError):
        v("x")


def test_vec2_is_frozen_and_hashable_class_without_hash_slot_would_be_unhashable():
    # Vec2 registers Hash next to Compare, so it stays hashable.
    assert sh.Vec2.__hash__ is not None


def test_vec2_refcounts():
    v = sh.Vec2(1.0, 2.0)
    w = sh.Vec2(3.0, 4.0)
    before_v, before_w = sys.getrefcount(v), sys.getrefcount(w)
    for _ in range(100):
        v + w
        w - v
        v * 2
        2 * v
        -v
        abs(v)
        v == w
        v != w
        hash(v)
        repr(v)
        v(2.0)
        with pytest.raises(TypeError):
            v + 1
        with pytest.raises(TypeError):
            1 + v
    assert sys.getrefcount(v) == before_v
    assert sys.getrefcount(w) == before_w


# --- Stack: containers, iteration, calls, context managers -------------------


def test_stack_container_protocol():
    s = sh.Stack([1, 2, 3])
    assert len(s) == 3
    assert bool(s)
    assert not sh.Stack([])
    assert s[0] == 1
    assert s[-1] == 3
    assert 2 in s
    assert 9 not in s
    with pytest.raises(IndexError):
        s[3]
    with pytest.raises(IndexError):
        s[-4]
    with pytest.raises(TypeError):
        s["a"]
    s[1] = 20
    assert s[1] == 20
    del s[0]
    assert list(s) == [20, 3]
    with pytest.raises(IndexError):
        s[5] = 1
    with pytest.raises(IndexError):
        del s[5]
    assert repr(s) == "Stack([20,3])"


def test_stack_push_pop_and_call():
    s = sh.Stack([])
    s.push(1)
    assert s(2) == 2
    assert s(x=3) == 3
    assert s.pop() == 3
    assert s.pop() == 2
    assert s.pop() == 1
    with pytest.raises(IndexError):
        s.pop()


def test_stack_iteration_protocol():
    s = sh.Stack([1, 2, 3])
    it = iter(s)
    assert isinstance(it, m.HsIterator)
    assert iter(it) is it
    assert next(it) == 1
    assert next(it) == 2
    assert next(it) == 3
    with pytest.raises(StopIteration):
        next(it)
    with pytest.raises(StopIteration):
        next(it)
    # A second iteration is a fresh iterator over the current contents.
    s.push(0)
    assert list(s) == [0, 1, 2, 3]
    assert [x * 2 for x in s] == [0, 2, 4, 6]
    assert isinstance(it, collections.abc.Iterator)
    with pytest.raises(TypeError):
        m.HsIterator()


def test_stack_next_pops_in_plain_form():
    # __next__ is written in the plain form (Maybe Int, no PyResult): it pops
    # the top item and raises StopIteration once the stack is empty, while
    # iter(s) still answers a snapshot iterator.
    s = sh.Stack([1, 2])
    assert next(s) == 1
    assert next(s) == 2
    with pytest.raises(StopIteration):
        next(s)
    with pytest.raises(StopIteration):
        next(s)
    s.push(5)
    assert next(s) == 5
    assert len(s) == 0
    s.push(7)
    s.push(8)
    assert list(s) == [8, 7]
    assert len(s) == 2
    assert next(s) == 8


def test_stack_live_iterator_sees_mutation():
    s = sh.Stack([1, 2])
    it = s.live()
    assert next(it) == 1
    s.push(0)
    # The live iterator reads index 1 of the current contents.
    assert next(it) == 1
    assert next(it) == 2
    with pytest.raises(StopIteration):
        next(it)
    del s
    gc.collect()
    with pytest.raises(StopIteration):
        next(it)


def test_stack_context_manager():
    # __exit__ is written in the plain form (Bool, no PyResult).
    s = sh.Stack([1, 2])
    with s as t:
        assert t is s
        s.push(3)
    assert len(s) == 0
    with s:
        raise ValueError("suppressed")
    with pytest.raises(KeyError):
        with s:
            raise KeyError("propagated")
    assert s.__exit__(None, None, None) is False
    assert s.__exit__(ValueError, ValueError("x"), None) is True


def test_stack_compare_reuses_shared_hold():
    s = sh.Stack([1, 2])
    t = sh.Stack([1, 2])
    u = sh.Stack([2, 1])
    assert s == s
    assert s == t
    assert s != u
    assert not (s != t)
    assert s != 3
    with pytest.raises(TypeError):
        s < t
    # Compare without Hash: __hash__ is None, as CPython's rule says.
    assert sh.Stack.__hash__ is None
    with pytest.raises(TypeError):
        hash(s)


def test_stack_number_protocol():
    s = sh.Stack([1])
    t = sh.Stack([2])
    u = s + t
    assert list(u) == [1, 2]
    assert s + s == sh.Stack([1, 1])
    with pytest.raises(TypeError):
        s + 1
    with pytest.raises(TypeError):
        1 + s
    s += t
    assert list(s) == [1, 2]
    with pytest.raises(TypeError):
        s += 1
    with pytest.raises(RuntimeError, match="busy"):
        s += s
    assert list(s) == [1, 2]


def test_stack_abc_registration():
    s = sh.Stack([1])
    assert isinstance(s, collections.abc.Sized)
    assert issubclass(sh.Stack, collections.abc.Sized)
    assert not isinstance(sh.Vec2(1.0, 2.0), collections.abc.Sized)


def test_stack_refcounts():
    s = sh.Stack([1, 2, 3])
    t = sh.Stack([4])
    before_s, before_t = sys.getrefcount(s), sys.getrefcount(t)
    for _ in range(100):
        len(s)
        bool(s)
        s[0]
        s[1] = 2
        1 in s
        list(s)
        repr(s)
        s(9)
        s.pop()
        s == t
        s != t
        s + t
        s += t
        s.pop()
        with s:
            pass
        s.push(1)
        s.push(2)
        s.push(3)
        next(s)
        with pytest.raises(IndexError):
            s[10]
        with pytest.raises(RuntimeError):
            s += s
        with pytest.raises(TypeError):
            s + 1
        s.push(3)
    assert sys.getrefcount(s) == before_s
    assert sys.getrefcount(t) == before_t


def test_live_iterator_releases_its_handle_eventually():
    # The live iterator keeps a PyHandle to the stack; a handle is released by a
    # Haskell finaliser through the deferred release pool, which the next call
    # drains, so the +1 goes away once the Haskell heap has been collected.
    s = sh.Stack([1, 2, 3])
    before = sys.getrefcount(s)
    for _ in range(200):
        for _ in s.live():
            pass
        it = s.live()
        next(it)
        del it
    gc.collect()
    assert sys.getrefcount(s) > before
    for _ in range(200):
        # Allocation-heavy calls make the Haskell heap collect its garbage.
        list(sh.Stack(list(range(20000))))
        gc.collect()
        len(s)
        if sys.getrefcount(s) == before:
            break
    assert sys.getrefcount(s) == before


# --- Samples: the buffer protocol over class-owned storage -------------------


def test_samples_buffer():
    s = sh.Samples([1.0, 2.0, 3.0])
    assert len(s) == 3
    assert s.total() == 6.0
    mv = memoryview(s)
    assert mv.format == "d"
    assert mv.itemsize == 8
    assert mv.shape == (3,)
    assert mv.tolist() == [1.0, 2.0, 3.0]
    mv[0] = 10.0
    # Any live view excludes any dereference, shared or mutable.
    with pytest.raises(BufferError):
        s.total()
    with pytest.raises(BufferError):
        s.scale(2.0)
    mv.release()
    assert s.total() == 15.0
    arr = np.asarray(s)
    assert arr.dtype == np.float64
    arr[1] = 20.0
    with pytest.raises(BufferError):
        s.scale(2.0)
    del arr
    assert s.total() == 33.0
    s.scale(2.0)
    assert s.total() == 66.0
    with s as t:
        assert t is s


def test_samples_compare_in_plain_form():
    # __eq__ and friends are written in the plain form (Maybe Bool, no
    # PyResult): the total is ordered against a number, and a non-numeric
    # operand answers NotImplemented.
    s = sh.Samples([1.0, 2.0, 3.0])
    assert s == 6.0
    assert s == 6
    assert not (s != 6.0)
    assert s != 5.0
    assert s < 7.0
    assert s <= 6.0
    assert s > 5
    assert s >= 6
    assert not (s < 6.0)
    assert 7.0 > s
    assert (s == "x") is False
    assert (s != "x") is True
    assert s.__eq__("x") is NotImplemented
    with pytest.raises(TypeError):
        s < "x"
    with pytest.raises(TypeError):
        s < sh.Samples([1.0])
    # Compare without Hash: the class is unhashable.
    assert sh.Samples.__hash__ is None
    with pytest.raises(TypeError):
        hash(s)
    # The receiver is dereferenced outside the body: a live view refuses it.
    mv = memoryview(s)
    with pytest.raises(BufferError):
        s == 6.0
    mv.release()
    assert s == 6.0


def test_samples_imul_in_plain_form():
    # __imul__ is written in the plain form (Maybe (), no PyResult): Just ()
    # answers self, Nothing answers NotImplemented.
    s = sh.Samples([1.0, 2.0])
    t = s
    s *= 2
    assert s is t
    assert s.total() == 6.0
    s *= 0.5
    assert s.total() == 3.0
    with pytest.raises(TypeError):
        s *= "x"
    with pytest.raises(TypeError):
        s *= sh.Samples([1.0])
    assert s.total() == 3.0
    mv = memoryview(s)
    with pytest.raises(BufferError):
        s *= 2
    mv.release()
    assert s.total() == 3.0


def test_samples_refcounts():
    s = sh.Samples([1.0, 2.0])
    before = sys.getrefcount(s)
    for _ in range(100):
        mv = memoryview(s)
        mv.tolist()
        with pytest.raises(BufferError):
            s.scale(1.0)
        with pytest.raises(BufferError):
            s.total()
        with pytest.raises(BufferError):
            s == 3.0
        with pytest.raises(BufferError):
            s *= 1.0
        mv.release()
        s.scale(1.0)
        s.total()
        len(s)
        with s:
            pass
        s == 3.0
        s != 3.0
        s < 4.0
        s == "x"
        with pytest.raises(TypeError):
            s < "x"
        s *= 1.0
        with pytest.raises(TypeError):
            s *= "x"
    assert sys.getrefcount(s) == before


# --- Named and Child: inheritance in both directions -------------------------


def test_child_extends_named():
    c = sh.Child("Ada", 36)
    assert isinstance(c, sh.Named)
    assert isinstance(c, sh.Child)
    assert issubclass(sh.Child, sh.Named)
    assert sh.Child.__mro__[1] is sh.Named
    assert c.name() == "Ada"
    assert c.age() == 36
    assert c.describe() == "Ada (36)"
    c.rename("Grace")
    assert c.name() == "Grace"
    c.rename_via_super("Linus")
    assert c.describe() == "Linus (36)"
    n = sh.Named("plain")
    assert n.name() == "plain"
    with pytest.raises(TypeError):
        sh.Child("x")


def test_child_dealloc_chain():
    for i in range(500):
        c = sh.Child(str(i), i)
        assert c.age() == i
    del c
    gc.collect()


def test_python_subclass_of_haskell_class():
    class Pet(sh.Named):
        def __init__(self, name):
            self.sound = "woof"

        def speak(self):
            return f"{self.name()} says {self.sound}"

    p = Pet("Rex")
    assert isinstance(p, sh.Named)
    assert type(p) is Pet
    assert p.name() == "Rex"
    assert p.speak() == "Rex says woof"
    p.extra = 1
    assert p.__dict__["extra"] == 1
    p.rename("Max")
    assert p.speak() == "Max says woof"
    before = sys.getrefcount(p)
    for _ in range(100):
        p.name()
        p.rename("Max")
    assert sys.getrefcount(p) == before
    del p
    gc.collect()

    class Kid(sh.Child):
        def __new__(cls, name, age, nick):
            return super().__new__(cls, name, age)

        def __init__(self, name, age, nick):
            self.nick = nick

    k = Kid("Ada", 9, "A")
    assert k.describe() == "Ada (9)"
    assert k.nick == "A"
    del k
    gc.collect()


def test_frozen_and_plain_classes_are_not_subclassable():
    with pytest.raises(TypeError):

        class V(sh.Vec2):
            pass

    with pytest.raises(TypeError):

        class S(sh.Stack):
            pass


# --- Stubs -------------------------------------------------------------------


def test_shapes_stub():
    stub = sh.__h2py_stub__()
    assert "import collections.abc" in stub
    assert "from h2py_examples import HsIterator" in stub
    assert "def live(self) -> HsIterator:" in stub
    assert "class Vec2:" in stub
    assert "class Stack(collections.abc.Sized):" in stub
    assert "class Child(Named):" in stub
    for dunder in [
        "__repr__",
        "__hash__",
        "__eq__",
        "__ne__",
        "__lt__",
        "__le__",
        "__gt__",
        "__ge__",
        "__add__",
        "__sub__",
        "__mul__",
        "__rmul__",
        "__neg__",
        "__abs__",
        "__call__",
        "__len__",
        "__bool__",
        "__getitem__",
        "__setitem__",
        "__delitem__",
        "__contains__",
        "__iter__",
        "__enter__",
        "__exit__",
        "__iadd__",
        "__buffer__",
    ]:
        assert f"def {dunder}(self" in stub, dunder
    assert "def __call__(self, k: float) -> Vec2:" in stub
    assert "def __getitem__(self, key: int) -> int:" in stub
    assert "def __iter__(self) -> Iterator[Any]:" in stub
    assert stub.count("def __enter__(self) -> Samples:") == 1
    assert "def __enter__(self) -> Stack:" in stub
    # Plain-form bodies render the same hints as PyResult ones.
    assert "def __next__(self) -> int:" in stub
    assert "def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> bool:" in stub
    assert "def __imul__(self, other: Any) -> Samples:" in stub
    assert stub.count("def __eq__(self, other: Any) -> bool:") == 3
    top = m.__h2py_stub__()
    assert "class HsIterator:" in top
    assert "def __next__(self) -> Any:" in top
    assert "def __iter__(self) -> HsIterator:" in top
