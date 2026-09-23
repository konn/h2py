"""Reference-count deltas of arguments and results, on every path of the ops functions.

Every check is a delta of ``sys.getrefcount`` around the call: arguments come
back to their count on success, on a Left and on a Haskell-exception path,
and a fresh result carries exactly the one reference its local holds.
Fresh, non-immortal objects are used throughout, since small integers, None
and interned strings have no observable count.
"""

import sys

import pytest

import h2py_examples as m

ops = m.ops


# sys.getrefcount itself, not a wrapper: a Python wrapper's parameter would
# add one reference of its own to every count.
rc = sys.getrefcount


def drain_until(released, attempts=10):
    """Run Haskell collections and trampoline entries until ``released()`` holds.

    A handle dropped on the Haskell side is released by a finaliser that
    pushes it onto the pool, which the next call drains; ``released`` is a
    closure so that it counts in the frame that measured the baseline.
    """
    for _ in range(attempts):
        ops.haskell_gc()
        ops.noop()
        if released():
            return True
    return False


def stable(fn, *args, expect=None):
    """Call fn(*args); every argument's count is unchanged afterwards.

    ``expect`` is an exception class the call must raise, or None for success.
    A materialised exception may reference an argument (an AttributeError
    holds its object, a KeyError its key) and is itself held by a Haskell
    handle until the finaliser and the next drain release it, so on a Left
    path the counts are compared after a drain.
    Returns the result on success.
    """
    before = [rc(a) for a in args]
    result = None
    if expect is None:
        result = fn(*args)
    else:
        with pytest.raises(expect):
            fn(*args)
        drain_until(lambda: [rc(a) for a in args] == before)
    after = [rc(a) for a in args]
    assert after == before, f"{fn.__name__}: refcounts {before} -> {after}"
    return result


def fresh_result(fn, *args):
    """The result of fn is a fresh object referenced only by the local that holds it."""
    r = fn(*args)
    assert rc(r) == 2
    return r


class Thing:
    pass


# --- success paths -----------------------------------------------------------


def test_get_attr_success_and_left():
    t = Thing()
    value = object()
    t.x = value
    before = rc(value)
    r = stable(ops.get_attr, t, "x")
    assert r is value
    assert rc(value) == before + 1
    del r
    assert rc(value) == before
    stable(ops.get_attr, t, "missing", expect=AttributeError)


def test_set_attr_success_and_left():
    t = Thing()
    value = object()
    before_t, before_value = rc(t), rc(value)
    assert ops.set_attr(t, "y", value) is None
    # The object now holds the value, and nothing else does.
    assert (rc(t), rc(value)) == (before_t, before_value + 1)
    del t.y
    assert (rc(t), rc(value)) == (before_t, before_value)
    stable(ops.set_attr, object(), "y", value, expect=AttributeError)
    assert rc(value) == before_value


def test_items():
    d = {}
    key = "".join(["fresh", "key"])
    value = object()
    before_d, before_key, before_value = rc(d), rc(key), rc(value)
    assert ops.set_item(d, key, value) is None
    # The dict now holds the key and the value, and nothing else does.
    assert (rc(d), rc(key), rc(value)) == (before_d, before_key + 1, before_value + 1)
    r = stable(ops.get_item, d, key)
    assert r is value
    del r
    # Deleting the item releases the dict's references and nothing else.
    assert ops.del_item(d, key) is None
    assert d == {}
    assert (rc(d), rc(key), rc(value)) == (before_d, before_key, before_value)
    stable(ops.get_item, d, key, expect=KeyError)
    stable(ops.del_item, d, key, expect=KeyError)
    stable(ops.set_item, (1,), key, value, expect=TypeError)


def test_length_repr_str_hash_equals():
    lst = [object(), object()]
    stable(ops.length, lst)
    stable(ops.length, object(), expect=TypeError)
    fresh_result(ops.repr_, lst)
    fresh_result(ops.str_, lst)
    stable(ops.repr_, lst)
    s = "".join(["a", "b", "c"])
    stable(ops.hash_, s)
    stable(ops.hash_, lst, expect=TypeError)
    stable(ops.equals, lst, lst)
    stable(ops.equals, lst, s)

    class Loud:
        def __eq__(self, other):
            raise RuntimeError("no")

    stable(ops.equals, Loud(), lst, expect=RuntimeError)


def test_call_and_iterate():
    args = [object(), object()]
    stable(ops.call, max, [3, 1, 2])
    r = stable(ops.call, (lambda *a: a), args)
    assert r[0] is args[0]
    del r
    stable(ops.call, (lambda: 1 / 0), [], expect=ZeroDivisionError)
    stable(ops.call, object(), [], expect=TypeError)
    nums = [10**30, 10**31]
    stable(ops.iterate_sum, nums, expect=OverflowError)
    nums = [1, "".join(["no", "t an int"])]
    stable(ops.iterate_sum, nums, expect=TypeError)
    items = list(range(50, 60))
    stable(ops.iterate_sum, items)
    stable(ops.downcast_int, items)


@pytest.mark.parametrize(
    "fn, value",
    [
        (ops.roundtrip_int, 10**15),
        (ops.roundtrip_integer, 10**40),
        (ops.roundtrip_word, 10**15),
        (ops.roundtrip_double, 2.5),
        (ops.roundtrip_float, 2.5),
        (ops.roundtrip_char, "".join(["z"])),
        (ops.roundtrip_text, "".join(["fresh", "text"])),
        (ops.roundtrip_string, "".join(["fresh", "string"])),
        (ops.roundtrip_bytes, bytes(range(3))),
        (ops.roundtrip_maybe_int, 10**15),
        (ops.roundtrip_either_int_text, "".join(["fresh", "either"])),
        (ops.roundtrip_int_list, [10**15, 10**16]),
        (ops.roundtrip_double_vector, [2.5, 3.5]),
        (ops.map_items, {"".join(["k", "1"]): 10**15}),
        (ops.set_items, {10**15, 10**16}),
        (ops.roundtrip_tuple2, (10**15, "".join(["t", "2"]))),
        (ops.roundtrip_tuple3, (10**15, "".join(["t", "3"]), 2.5)),
        (ops.roundtrip_tuple4, (10**15, "".join(["t", "4"]), 2.5, True)),
        (ops.roundtrip_tuple5, (10**15, "".join(["t", "5"]), 2.5, True, [10**15])),
    ],
)
def test_roundtrip_arguments_and_results(fn, value):
    r = stable(fn, value)
    # A one-character str is a CPython singleton and has no observable count.
    if not (isinstance(r, str) and len(r) == 1):
        assert rc(r) == 2
    # The items of a container argument are not retained either.
    if isinstance(value, (list, tuple)):
        for item in value:
            before = rc(item)
            stable(fn, value)
            assert rc(item) == before


def test_roundtrip_left_paths():
    big = 10**30
    stable(ops.roundtrip_int, big, expect=OverflowError)
    stable(ops.roundtrip_word, big, expect=OverflowError)
    s = "".join(["a", " string"])
    stable(ops.roundtrip_bytes, s, expect=TypeError)
    stable(ops.roundtrip_int_list, s, expect=TypeError)
    stable(ops.roundtrip_int, s, expect=TypeError)
    stable(ops.roundtrip_bool, big, expect=TypeError)
    lst = [10**15, s, 10**16]
    stable(ops.roundtrip_int_list, lst, expect=TypeError)
    tpl = (10**15, s, 2.5)
    stable(ops.roundtrip_tuple2, tpl, expect=ValueError)
    stable(ops.roundtrip_tuple3, [10**15, s, 2.5], expect=TypeError)
    d = {s: s}
    stable(ops.map_items, d, expect=TypeError)
    stable(ops.map_items, lst, expect=TypeError)


# --- Left, orThrow and Haskell-exception paths ------------------------------


def test_left_and_haskell_exception_paths_without_arguments():
    for _ in range(3):
        with pytest.raises(ValueError):
            ops.fail_value_error()
        with pytest.raises(RuntimeError):
            ops.haskell_error()
        with pytest.raises(ValueError):
            ops.throw_on_left()
        with pytest.raises(KeyError):
            ops.key_error_roundtrip()


# --- every remaining operation of H2Py.Object, on every path ------------------


class Fresh:
    """A fresh object per test, with attributes to read, set and delete."""

    def __init__(self):
        self.x = object()

    def method(self, *args):
        return args

    def fail(self, *args):
        raise KeyError("nope")


def fresh_str():
    return "".join(["fresh", " string"])


def test_has_attr_and_del_attr():
    t = Fresh()
    name = fresh_str()
    assert stable(ops.has_attr, t, "x") is True
    assert stable(ops.has_attr, t, name) is False
    setattr(t, "y", object())
    assert stable(ops.del_attr, t, "y") is None
    assert not hasattr(t, "y")
    stable(ops.del_attr, t, "y", expect=AttributeError)
    stable(ops.del_attr, object(), "y", expect=AttributeError)


def test_get_index():
    items = [object(), object()]
    r = stable(ops.get_index, items, 1)
    assert r is items[1]
    del r
    stable(ops.get_index, items, 5, expect=IndexError)
    stable(ops.get_index, object(), 0, expect=TypeError)


def test_is_true():
    lst = [object()]
    assert stable(ops.is_true, lst) is True
    assert stable(ops.is_true, []) is False

    class Loud:
        def __bool__(self):
            raise ValueError("no bool")

    stable(ops.is_true, Loud(), expect=ValueError)


def test_call0_and_call_method():
    sentinel = object()
    r = stable(ops.call0, lambda: sentinel)
    assert r is sentinel
    del r
    stable(ops.call0, lambda: 1 / 0, expect=ZeroDivisionError)
    stable(ops.call0, object(), expect=TypeError)
    t = Fresh()
    args = [object(), object()]
    r = stable(ops.call_method, t, "method", args)
    assert r == tuple(args)
    del r
    r = stable(ops.call_method0, t, "method")
    assert r == ()
    del r
    stable(ops.call_method, t, "fail", args, expect=KeyError)
    stable(ops.call_method0, t, "fail", expect=KeyError)
    stable(ops.call_method, t, "missing", args, expect=AttributeError)
    stable(ops.call_method0, t, "missing", expect=AttributeError)
    stable(ops.call_method, t, "method", object(), expect=TypeError)


def test_rich_compare():
    a = [10**15]
    b = [10**16]
    assert stable(ops.rich_compare, a, 0, b) is True
    assert stable(ops.rich_compare, a, 4, b) is False
    assert stable(ops.rich_compare, a, 2, a) is True
    stable(ops.rich_compare, a, 7, b, expect=ValueError)
    stable(ops.rich_compare, a, 0, object(), expect=TypeError)

    class Loud:
        def __lt__(self, other):
            raise RuntimeError("no")

    stable(ops.rich_compare, Loud(), 0, a, expect=RuntimeError)


def test_type_of():
    t = Fresh()
    assert stable(ops.type_of, t) is Fresh
    assert stable(ops.type_of, fresh_str()) is str


def test_downcast_mut():
    n = 10**15
    before = rc(n)
    # The result is the argument itself, so it gains the one reference the local holds.
    r = ops.downcast_mut_int(n)
    assert r is n
    assert rc(n) == before + 1
    del r
    assert rc(n) == before
    stable(ops.downcast_mut_int, fresh_str(), expect=TypeError)


def test_list_append_and_set_add():
    lst = []
    value = object()
    before_lst, before = rc(lst), rc(value)
    # The list now holds the value, and nothing else does.
    assert ops.list_append(lst, value) is None
    assert lst == [value]
    assert (rc(lst), rc(value)) == (before_lst, before + 1)
    lst.clear()
    assert rc(value) == before
    stable(ops.list_append, (), value, expect=TypeError)
    s = set()
    key = fresh_str()
    before_s, before_key = rc(s), rc(key)
    assert ops.set_add(s, key) is None
    assert s == {key}
    assert (rc(s), rc(key)) == (before_s, before_key + 1)
    s.clear()
    assert rc(key) == before_key
    stable(ops.set_add, s, [1], expect=TypeError)
    stable(ops.set_add, [], key, expect=TypeError)


@pytest.mark.parametrize(
    "fn, value, expected",
    [
        (ops.to_str, fresh_str(), "fresh string"),
        (ops.to_bytes, bytes(range(5)), bytes(range(5))),
        (ops.to_int, 10**15, 10**15),
        (ops.to_integer, 10**40, 10**40),
        (ops.to_float, 2.5, 2.5),
        (ops.to_bool, True, True),
    ],
)
def test_constructors(fn, value, expected):
    r = stable(fn, value)
    assert r == expected
    assert type(r) is type(expected)
    if r is not True:
        assert rc(r) == 2


def test_none_and_empty_tuple():
    assert ops.none_() is None
    assert ops.empty_tuple() == ()
    assert ops.new_dict() == {}
    assert ops.new_list() == []
    r = ops.new_list()
    assert rc(r) == 2


def test_containers_from_iterables():
    items = [object(), object()]
    counts = [rc(i) for i in items]
    r = stable(ops.to_list, items)
    assert r == items and r is not items
    assert [rc(i) for i in items] == [c + 1 for c in counts]
    del r
    assert [rc(i) for i in items] == counts
    r = stable(ops.to_tuple, items)
    assert r == tuple(items)
    del r
    assert [rc(i) for i in items] == counts
    r = stable(ops.to_set, items)
    assert r == set(items)
    del r
    assert [rc(i) for i in items] == counts
    key, value = fresh_str(), object()
    pairs = [(key, value)]
    before = (rc(key), rc(value))
    r = stable(ops.to_dict, pairs)
    assert r == {key: value}
    assert (rc(key), rc(value)) == (before[0] + 1, before[1] + 1)
    del r
    assert (rc(key), rc(value)) == before
    stable(ops.to_list, object(), expect=TypeError)
    stable(ops.to_tuple, 5, expect=TypeError)
    stable(ops.to_set, [[1]], expect=TypeError)
    stable(ops.to_dict, [(key,)], expect=IndexError)
    stable(ops.to_dict, [[[1], value]], expect=TypeError)
    stable(ops.to_dict, object(), expect=TypeError)


@pytest.mark.parametrize(
    "fn, value",
    [
        (ops.copy_out_int, 10**40),
        (ops.copy_out_float, 2.5),
        (ops.copy_out_bool, True),
        (ops.copy_out_str, fresh_str()),
        (ops.copy_out_bytes, bytes(range(5))),
        (ops.copy_out_none, None),
    ],
)
def test_copy_out(fn, value):
    assert stable(fn, value) == value
    stable(fn, object(), expect=TypeError)


def test_handle_roundtrip():
    t = Fresh()
    before = rc(t)
    r = ops.handle_roundtrip(t)
    assert r is t
    # The local holds one reference; the handle taken inside the call holds
    # another until the Haskell collector finalises it.
    assert before + 1 <= rc(t) <= before + 2
    del r
    # The handle's +1 goes through the pool once the finaliser has run.
    assert drain_until(lambda: rc(t) == before)
    for _ in range(5):
        ops.handle_roundtrip(t)
    assert drain_until(lambda: rc(t) == before)


def test_haskell_error_after_using_the_argument():
    t = Fresh()
    value = object()
    before_t, before_value = rc(t), rc(value)
    for _ in range(3):
        stable(ops.use_then_error, t, expect=RuntimeError)
        with pytest.raises(RuntimeError):
            ops.use_mut_then_error(t, "z", value)
        # The mutation before the error stays: the object holds the value,
        # and nothing else does.
        assert t.z is value
        assert (rc(t), rc(value)) == (before_t, before_value + 1)
        del t.z
        assert (rc(t), rc(value)) == (before_t, before_value)
    with pytest.raises(RuntimeError) as info:
        ops.use_then_error(t)
    assert str(info.value) == "boom after using the argument"
    with pytest.raises(RuntimeError) as info:
        ops.use_mut_then_error(t, "z", value)
    assert str(info.value) == "boom after mutating the argument"
    del t.z
    assert (rc(t), rc(value)) == (before_t, before_value)


def test_cell_paths():
    c = ops.Cell(5)
    other = ops.Cell(7)
    stable(c.get)
    stable(c.incr, 10**15)
    stable(c.sum_with, other)
    stable(c.sum_with, c)
    r = stable(c.identity)
    assert r is c
    del r
    stable(c.incr_then_fail, 1, expect=ValueError)
    stable(c.incr, "".join(["no", "t an int"]), expect=TypeError)
    stable(c.sum_with, other.get, expect=TypeError)
    before_c, before_other = rc(c), rc(other)
    with pytest.raises(RuntimeError):
        c.poison()
    assert rc(c) == before_c
    with pytest.raises(RuntimeError):
        c.get()
    with pytest.raises(RuntimeError):
        other.sum_with(c)
    assert (rc(c), rc(other)) == (before_c, before_other)


def test_a_result_that_is_an_argument_gains_one_reference():
    c = ops.Cell(1)
    before = rc(c)
    r = c.identity()
    assert r is c
    assert rc(c) == before + 1
    del r
    assert rc(c) == before


# --- PyHandle through a Haskell structure --------------------------------------


def test_stashed_handle_holds_exactly_one_reference_and_releases_it():
    x = object()
    base = rc(x)
    ops.stash(x)
    assert rc(x) == base + 1
    for _ in range(3):
        r = ops.stashed()
        assert r is x
        assert rc(x) == base + 2
        del r
        assert rc(x) == base + 1
    ops.unstash()
    assert ops.stashed() is None
    # The handle is released by the finaliser through the pool, which the
    # next call drains.
    assert drain_until(lambda: rc(x) == base)
    assert rc(x) == base


def test_restashing_releases_the_previous_handle():
    a, b = object(), object()
    base_a, base_b = rc(a), rc(b)
    ops.stash(a)
    ops.stash(b)
    assert rc(b) == base_b + 1
    assert drain_until(lambda: rc(a) == base_a)
    ops.unstash()
    assert drain_until(lambda: rc(b) == base_b)


def test_stash_argument_and_result_counts_are_stable_per_call():
    x = object()
    ops.stash(x)
    held = rc(x)
    for _ in range(20):
        assert ops.stashed() is x
    assert rc(x) == held
    ops.unstash()
    assert drain_until(lambda: rc(x) == held - 1)


def test_restash_of_the_same_object_keeps_one_handle():
    x = object()
    base = rc(x)
    ops.stash(x)
    ops.stash(x)
    # The second handle replaces the first, whose +1 goes through the pool.
    assert drain_until(lambda: rc(x) == base + 1)
    ops.unstash()
    assert drain_until(lambda: rc(x) == base)
