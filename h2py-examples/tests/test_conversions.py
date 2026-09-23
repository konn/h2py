"""Round trips through every FromPy and ToPy instance, with their edge cases."""

import collections
import collections.abc
import math
import types

import pytest

import h2py_examples as m

ops = m.ops


def test_submodule_is_registered():
    import sys

    assert sys.modules["h2py_examples.ops"] is ops
    assert ops.__name__ == "h2py_examples.ops"


# --- integers --------------------------------------------------------------


@pytest.mark.parametrize("n", [0, 1, -1, 2**62, -(2**63), 2**63 - 1])
def test_int_roundtrip(n):
    r = ops.roundtrip_int(n)
    assert r == n and type(r) is int


@pytest.mark.parametrize("n", [2**63, -(2**63) - 1, 2**100])
def test_int_overflow(n):
    with pytest.raises(OverflowError):
        ops.roundtrip_int(n)


def test_int_accepts_bool_as_int_subclass():
    assert ops.roundtrip_int(True) == 1
    assert ops.roundtrip_int(False) == 0


def test_int_rejects_float_with_pyo3_style_message():
    with pytest.raises(TypeError) as info:
        ops.roundtrip_int(1.5)
    assert str(info.value) == "'float' object cannot be converted to 'int'"


@pytest.mark.parametrize("bad", ["1", None, [1]])
def test_int_rejects_non_int(bad):
    # Everything but a float is refused by CPython's own __index__ path.
    with pytest.raises(TypeError) as info:
        ops.roundtrip_int(bad)
    assert "cannot be interpreted as an integer" in str(info.value)


@pytest.mark.parametrize("n", [0, 2**100, -(2**100), 2**63, 12345])
def test_integer_roundtrip(n):
    assert ops.roundtrip_integer(n) == n


def test_integer_rejects_float():
    with pytest.raises(TypeError):
        ops.roundtrip_integer(1.5)


def test_big_integer_result():
    assert ops.big_integer() == 2**100


@pytest.mark.parametrize("n", [0, 1, 2**64 - 1])
def test_word_roundtrip(n):
    assert ops.roundtrip_word(n) == n


def test_word_rejects_negative():
    with pytest.raises(OverflowError) as info:
        ops.roundtrip_word(-1)
    assert "negative" in str(info.value)


def test_word_rejects_too_big():
    with pytest.raises(OverflowError):
        ops.roundtrip_word(2**64)


# --- floats ----------------------------------------------------------------


@pytest.mark.parametrize("d", [0.0, -1.5, 1e300, math.pi])
def test_double_roundtrip(d):
    assert ops.roundtrip_double(d) == d


def test_double_nan_and_inf():
    assert math.isnan(ops.roundtrip_double(float("nan")))
    assert ops.roundtrip_double(float("inf")) == float("inf")


def test_double_accepts_int():
    r = ops.roundtrip_double(3)
    assert r == 3.0 and type(r) is float


def test_double_rejects_str():
    with pytest.raises(TypeError):
        ops.roundtrip_double("1.0")


def test_float_roundtrip_is_single_precision():
    assert ops.roundtrip_float(0.5) == 0.5
    r = ops.roundtrip_float(0.1)
    assert r != 0.1 and abs(r - 0.1) < 1e-7


# --- booleans, characters, text, bytes, None --------------------------------


def test_bool_roundtrip():
    assert ops.roundtrip_bool(True) is True
    assert ops.roundtrip_bool(False) is False


@pytest.mark.parametrize("bad", [1, 0, "True", None])
def test_bool_rejects_non_bool(bad):
    with pytest.raises(TypeError) as info:
        ops.roundtrip_bool(bad)
    assert "cannot be converted to 'bool'" in str(info.value)


def test_char_roundtrip():
    assert ops.roundtrip_char("z") == "z"
    assert ops.roundtrip_char("😀") == "😀"


def test_char_rejects_other_lengths():
    with pytest.raises(ValueError):
        ops.roundtrip_char("ab")
    with pytest.raises(ValueError):
        ops.roundtrip_char("")
    with pytest.raises(TypeError):
        ops.roundtrip_char(1)


@pytest.mark.parametrize("s", ["", "héllo", "😀 wide", "a\0b", "x" * 10000])
def test_text_roundtrip(s):
    assert ops.roundtrip_text(s) == s
    assert ops.roundtrip_string(s) == s


def test_text_rejects_bytes():
    with pytest.raises(TypeError) as info:
        ops.roundtrip_text(b"s")
    assert str(info.value) == "'bytes' object cannot be converted to 'str'"


@pytest.mark.parametrize("b", [b"", b"xy", bytes(range(256)), b"a\0b"])
def test_bytes_roundtrip(b):
    assert ops.roundtrip_bytes(b) == b


def test_bytes_rejects_str_with_pyo3_style_message():
    with pytest.raises(TypeError) as info:
        ops.roundtrip_bytes("s")
    assert str(info.value) == "'str' object cannot be converted to 'bytes'"


def test_bytes_rejects_bytearray():
    with pytest.raises(TypeError):
        ops.roundtrip_bytes(bytearray(b"xy"))


def test_unit_roundtrip():
    assert ops.roundtrip_unit(None) is None


def test_unit_rejects_other_values():
    with pytest.raises(TypeError) as info:
        ops.roundtrip_unit(0)
    assert "cannot be converted to 'None'" in str(info.value)


# --- Maybe and Either --------------------------------------------------------


def test_maybe_roundtrip():
    assert ops.roundtrip_maybe_int(None) is None
    assert ops.roundtrip_maybe_int(3) == 3


def test_maybe_rejects_wrong_inner_type():
    with pytest.raises(TypeError):
        ops.roundtrip_maybe_int("3")


def test_either_roundtrip_tries_left_then_right():
    assert ops.roundtrip_either_int_text(4) == 4
    assert ops.roundtrip_either_int_text("s") == "s"


def test_either_rejects_neither():
    with pytest.raises(TypeError):
        ops.roundtrip_either_int_text(1.5)


# --- lists, vectors, maps, sets ----------------------------------------------


@pytest.mark.parametrize(
    "iterable",
    [[1, 2, 3], (1, 2, 3), range(1, 4), iter([1, 2, 3]), {1, 2, 3}, (x for x in [1, 2, 3])],
)
def test_list_from_any_iterable(iterable):
    assert sorted(ops.roundtrip_int_list(iterable)) == [1, 2, 3]


def test_list_result_is_a_list():
    r = ops.roundtrip_int_list((1, 2))
    assert r == [1, 2] and type(r) is list


def test_list_is_not_built_from_str_or_bytes():
    with pytest.raises(TypeError) as info:
        ops.roundtrip_int_list("abc")
    assert str(info.value) == "'str' object cannot be converted to 'list'"
    with pytest.raises(TypeError):
        ops.roundtrip_int_list(b"abc")


def test_list_rejects_a_bad_item():
    with pytest.raises(TypeError):
        ops.roundtrip_int_list([1, "a", 3])
    with pytest.raises(OverflowError):
        ops.roundtrip_int_list([1, 2**100])


def test_list_rejects_non_iterable():
    with pytest.raises(TypeError):
        ops.roundtrip_int_list(5)


def test_vector_roundtrip():
    assert ops.roundtrip_double_vector([1.0, 2.5]) == [1.0, 2.5]
    assert ops.roundtrip_double_vector(range(3)) == [0.0, 1.0, 2.0]
    assert ops.roundtrip_double_vector([]) == []


class OwnMapping(collections.abc.Mapping):
    def __init__(self, items):
        self._items = dict(items)

    def __getitem__(self, key):
        return self._items[key]

    def __iter__(self):
        return iter(self._items)

    def __len__(self):
        return len(self._items)


@pytest.mark.parametrize(
    "mapping",
    [
        {"b": 2, "a": 1},
        collections.OrderedDict([("b", 2), ("a", 1)]),
        types.MappingProxyType({"b": 2, "a": 1}),
        OwnMapping({"b": 2, "a": 1}),
        collections.defaultdict(int, {"b": 2, "a": 1}),
    ],
)
def test_dict_from_any_mapping(mapping):
    assert ops.map_items(mapping) == [("a", 1), ("b", 2)]


def test_dict_rejects_non_mappings():
    for bad in ([("a", 1)], "ab", 3, {"a", "b"}):
        with pytest.raises(TypeError) as info:
            ops.map_items(bad)
        assert "cannot be converted to 'dict'" in str(info.value)


def test_dict_rejects_bad_keys_or_values():
    with pytest.raises(TypeError):
        ops.map_items({1: 1})
    with pytest.raises(TypeError):
        ops.map_items({"a": "x"})


def test_set_from_any_iterable():
    assert ops.set_items({3, 1, 2}) == [1, 2, 3]
    assert ops.set_items(frozenset([2, 2, 1])) == [1, 2]
    assert ops.set_items([3, 1, 1]) == [1, 3]
    assert ops.set_items(()) == []


def test_set_rejects_str():
    with pytest.raises(TypeError):
        ops.set_items("ab")


# --- tuples ------------------------------------------------------------------


def test_tuple_roundtrips():
    assert ops.roundtrip_tuple2((1, "a")) == (1, "a")
    assert ops.roundtrip_tuple3((1, "a", 2.0)) == (1, "a", 2.0)
    assert ops.roundtrip_tuple4((1, "a", 2.0, False)) == (1, "a", 2.0, False)
    assert ops.roundtrip_tuple5((1, "a", 2.0, True, [1, 2])) == (1, "a", 2.0, True, [1, 2])


def test_tuple_results_are_tuples():
    assert type(ops.roundtrip_tuple2((1, "a"))) is tuple


def test_tuple_arity_errors():
    with pytest.raises(ValueError) as info:
        ops.roundtrip_tuple2((1, "a", 3))
    assert str(info.value) == "expected a tuple of length 2, got 3"
    with pytest.raises(ValueError):
        ops.roundtrip_tuple3((1, "a"))
    with pytest.raises(ValueError):
        ops.roundtrip_tuple5(())


def test_tuple_rejects_non_tuples():
    with pytest.raises(TypeError) as info:
        ops.roundtrip_tuple2([1, "a"])
    assert "cannot be converted to 'tuple of length 2'" in str(info.value)


def test_tuple_rejects_bad_component():
    with pytest.raises(TypeError):
        ops.roundtrip_tuple2(("a", 1))


# --- protocol operations ----------------------------------------------------


class Thing:
    pass


def test_get_and_set_attr():
    t = Thing()
    t.x = 5
    assert ops.get_attr(t, "x") == 5
    assert ops.set_attr(t, "y", [1]) is None
    assert t.y == [1]
    with pytest.raises(AttributeError):
        ops.get_attr(t, "missing")
    with pytest.raises(AttributeError):
        ops.set_attr(object(), "y", 1)


def test_items():
    d = {"a": 1}
    assert ops.get_item(d, "a") == 1
    assert ops.set_item(d, "b", 2) is None
    assert d == {"a": 1, "b": 2}
    assert ops.del_item(d, "a") is None
    assert d == {"b": 2}
    with pytest.raises(KeyError):
        ops.get_item(d, "zzz")
    with pytest.raises(KeyError):
        ops.del_item(d, "zzz")
    with pytest.raises(TypeError):
        ops.set_item((1,), 0, 1)


def test_length_repr_str():
    assert ops.length([1, 2, 3]) == 3
    assert ops.length("héllo") == 5
    with pytest.raises(TypeError):
        ops.length(5)
    assert ops.repr_("s") == "'s'"
    assert ops.str_(3) == "3"
    assert ops.repr_([1, "a"]) == "[1, 'a']"


def test_call():
    assert ops.call(max, [1, 9, 3]) == 9
    assert ops.call(len, ["abc"]) == 3
    assert ops.call(dict, []) == {}
    assert ops.call(lambda *a: a, [1, 2]) == (1, 2)
    # The argument list is checked as a list, not any iterable.
    with pytest.raises(TypeError):
        ops.call(lambda *a: a, (1, 2))
    with pytest.raises(TypeError):
        ops.call(5, [])
    with pytest.raises(ZeroDivisionError):
        ops.call(lambda: 1 / 0, [])
    with pytest.raises(TypeError):
        ops.call(max, 5)


def test_iterate_sum():
    assert ops.iterate_sum(range(5)) == 10
    assert ops.iterate_sum([]) == 0
    assert ops.iterate_sum(x * x for x in range(4)) == 14
    with pytest.raises(TypeError):
        ops.iterate_sum(5)
    with pytest.raises(TypeError):
        ops.iterate_sum([1, "a"])
    with pytest.raises(OverflowError):
        ops.iterate_sum([1, 2**100])


def test_hash_and_equals():
    assert ops.hash_(12345) == hash(12345)
    assert ops.hash_("s") == hash("s")
    assert ops.hash_(-1) == hash(-1)
    with pytest.raises(TypeError):
        ops.hash_([])
    assert ops.equals(1, 1.0) is True
    assert ops.equals(1, 2) is False
    assert ops.equals([1], [1]) is True

    class Loud:
        def __eq__(self, other):
            raise RuntimeError("no comparing")

    with pytest.raises(RuntimeError):
        ops.equals(Loud(), 1)


def test_downcast():
    assert ops.downcast_int(1) is True
    assert ops.downcast_int(True) is True
    assert ops.downcast_int("x") is False
    assert ops.downcast_int(1.0) is False


def test_argument_type_checks_on_references():
    with pytest.raises(TypeError):
        ops.call(max, {1: 2})
    with pytest.raises(TypeError):
        ops.Cell(1).sum_with(5)


def test_stub_mentions_ops():
    stub = ops.__h2py_stub__()
    assert "def roundtrip_tuple5(arg0: tuple[int, str, float, bool, list[int]], /) -> tuple[int, str, float, bool, list[int]]" in stub
    assert "def map_items(arg0: dict[str, int], /) -> list[tuple[str, int]]" in stub
    assert "def roundtrip_maybe_int(arg0: int | None, /) -> int | None" in stub
    assert "def roundtrip_either_int_text(arg0: int | str, /) -> int | str" in stub
    assert "class Cell:" in stub
    assert "def sum_with(self, other: Cell) -> int" in stub
    assert "def identity(self) -> Cell" in stub
