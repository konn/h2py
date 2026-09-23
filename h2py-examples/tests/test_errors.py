"""Errors in both directions: Left values, Haskell exceptions, orThrow, poisoning."""

import gc
import sys
import threading
import time

import pytest

import h2py_examples as m

ops = m.ops


def test_left_raises_the_class_and_message():
    with pytest.raises(ValueError) as info:
        ops.fail_value_error()
    assert str(info.value) == "bad value"
    assert type(info.value) is ValueError
    with pytest.raises(TypeError) as info:
        ops.fail_type_error()
    assert str(info.value) == "bad type"


def test_haskell_error_is_a_runtime_error_with_the_message():
    with pytest.raises(RuntimeError) as info:
        ops.haskell_error()
    assert str(info.value) == "boom from haskell"


def test_or_throw_raises_its_error():
    with pytest.raises(ValueError) as info:
        ops.throw_on_left()
    assert str(info.value) == "thrown by orThrow"


def test_key_error_through_to_object_and_from_object():
    with pytest.raises(KeyError) as info:
        ops.key_error_roundtrip()
    assert info.value.args == ("missing",)


def test_a_python_error_from_a_call_is_the_same_exception_object():
    sentinel = ZeroDivisionError("mine")

    def raiser():
        raise sentinel

    with pytest.raises(ZeroDivisionError) as info:
        ops.call(raiser, [])
    assert info.value is sentinel


def test_python_errors_are_values_the_module_can_keep_working_after():
    for _ in range(10):
        with pytest.raises(AttributeError):
            ops.get_attr(object(), "nothing")
    assert ops.get_attr("s", "upper")() == "S"


def test_left_inside_a_mut_method_leaves_the_object_usable():
    c = ops.Cell(1)
    before = sys.getrefcount(c)
    for i in range(5):
        with pytest.raises(ValueError) as info:
            c.incr_then_fail(10)
        assert str(info.value) == "failed after mutating"
        # The mutation before the Left stays: no rollback, no poison.
        assert c.get() == 1 + 10 * (i + 1)
    c.incr(1)
    assert c.get() == 52
    assert c.sum_with(c) == 104
    assert c.identity() is c
    assert sys.getrefcount(c) == before


def test_haskell_error_in_a_mut_method_poisons_the_object():
    c = ops.Cell(1)
    with pytest.raises(RuntimeError) as info:
        c.poison()
    assert str(info.value) == "poisoning the cell"
    for call in (c.get, lambda: c.incr(1), lambda: c.sum_with(ops.Cell(1)), lambda: c.incr_then_fail(1)):
        with pytest.raises(RuntimeError) as info:
            call()
        assert "poisoned" in str(info.value)
    # A healthy object cannot read through a poisoned one either.
    other = ops.Cell(3)
    with pytest.raises(RuntimeError) as info:
        other.sum_with(c)
    assert "poisoned" in str(info.value)
    # The explicit receiver does not dereference, so it still answers.
    assert c.identity() is c
    # Deallocating a poisoned object leaks its payload and does not raise.
    del c


def test_poison_is_per_object():
    a = ops.Cell(1)
    b = ops.Cell(2)
    with pytest.raises(RuntimeError):
        a.poison()
    assert b.get() == 2
    b.incr(1)
    assert b.get() == 3
    assert b.sum_with(b) == 6


def test_two_shared_holds_on_two_objects_and_on_one():
    a = ops.Cell(1)
    b = ops.Cell(2)
    assert a.sum_with(b) == 3
    assert b.sum_with(a) == 3
    assert a.sum_with(a) == 2


def test_argument_conversion_errors_are_type_errors():
    c = ops.Cell(1)
    with pytest.raises(TypeError):
        c.incr("x")
    with pytest.raises(TypeError):
        c.sum_with("x")
    with pytest.raises(TypeError):
        ops.get_attr(object(), 5)
    assert c.get() == 1


def test_errors_carry_no_traceback_frames_from_haskell():
    try:
        ops.fail_value_error()
    except ValueError as e:
        tb = e.__traceback__
        depth = 0
        while tb is not None:
            depth += 1
            tb = tb.tb_next
        assert depth == 1


def test_key_error_object_survives_the_call():
    with pytest.raises(KeyError) as info:
        ops.key_error_roundtrip()
    e = info.value
    assert isinstance(e, KeyError)
    assert repr(e) == "KeyError('missing')"


# --- The Phase 3 gate: contention, poisoning, scoped holds ---------------------


def test_callback_reaching_the_held_payload_is_busy():
    c = ops.Cell(1)
    seen = []
    # Every receiver form that dereferences the payload answers busy from
    # inside the callback; the Python exception is the call's result.
    for reach in (c.get, lambda: c.incr(1), lambda: c.sum_with(ops.Cell(1)), lambda: c.incr_then_fail(1)):
        with pytest.raises(RuntimeError, match="busy") as info:
            c.call_while_held(reach)
        seen.append(str(info.value))
    assert all("Cell" in s for s in seen)
    # The busy answer is a value, not a poison: the cell is still usable.
    assert c.get() == 1
    # A callback that does not reach the payload runs, and the increment after it stays.
    assert c.call_while_held(lambda: "done") == "done"
    assert c.get() == 2
    # The explicit receiver does not dereference, so it works under the hold.
    assert c.call_while_held(c.identity) is c
    assert c.get() == 3
    # A Python error from the callback is the call's error, and nothing is poisoned.
    with pytest.raises(ZeroDivisionError):
        c.call_while_held(lambda: 1 / 0)
    assert c.get() == 3


def test_two_handles_to_one_object_in_one_scope_are_busy():
    c = ops.Cell(4)
    other = ops.Cell(6)
    assert c.deref_second(other) == 10
    with pytest.raises(RuntimeError, match="busy") as info:
        c.deref_second(c)
    assert "Cell" in str(info.value)
    assert c.get() == 4
    assert other.get() == 6
    with pytest.raises(TypeError):
        c.deref_second(5)


def test_timeout_interrupting_a_detached_hold_poisons_the_object():
    c = ops.Cell(1)
    t0 = time.perf_counter()
    with pytest.raises(RuntimeError, match="interrupted by a timeout"):
        c.hold_until_timeout(0.05)
    assert time.perf_counter() - t0 < 3
    for call in (c.get, lambda: c.incr(1), lambda: c.hold_until_timeout(0.01)):
        with pytest.raises(RuntimeError, match="poisoned"):
            call()
    # Nothing else is affected.
    assert ops.Cell(2).get() == 2


def test_asynchronous_exception_in_a_detached_hold_poisons_the_object():
    c = ops.Cell(1)
    t0 = time.perf_counter()
    with pytest.raises(RuntimeError, match="killed while holding the payload"):
        c.hold_until_killed(0.05)
    assert time.perf_counter() - t0 < 3
    for call in (c.get, lambda: c.incr(1), lambda: c.sum_with(c)):
        with pytest.raises(RuntimeError, match="poisoned"):
            call()
    other = ops.Cell(3)
    assert other.get() == 3


def test_hold_scoped_by_attach_is_released_at_its_end():
    c = ops.Cell(10)
    # Inside the scope a fresh handle dereferences the cell mutably; after
    # the scope the receiver dereferences it again, which would be busy if
    # the inner hold had outlived its arena.
    assert c.scoped_hold() == 11
    assert c.scoped_hold() == 12
    assert c.get() == 12


def test_detached_holds_from_another_thread_are_busy():
    c = ops.Cell(0)
    result = {}

    def target():
        try:
            result["value"] = c.hold_until_timeout(0.5)
        except BaseException as e:  # noqa: BLE001
            result["error"] = e

    t = threading.Thread(target=target)
    t.start()
    # The hold may begin late on a loaded machine: read until it is seen.
    while True:
        try:
            c.get()
        except RuntimeError as e:
            assert "busy" in str(e), e
            break
        assert t.is_alive(), "the hold ended before it was seen"
        time.sleep(0.001)
    with pytest.raises(RuntimeError, match="busy"):
        c.get()
    with pytest.raises(RuntimeError, match="busy"):
        c.incr(1)
    t.join()
    assert isinstance(result.get("error"), RuntimeError)
    with pytest.raises(RuntimeError, match="poisoned"):
        c.get()


# --- Classes outside the registration ------------------------------------------


def test_unregistered_class_as_an_argument_is_a_runtime_error():
    with pytest.raises(RuntimeError) as info:
        ops.ghost_arg(object())
    assert "Ghost" in str(info.value)
    assert "has not been registered" in str(info.value)
    assert not hasattr(ops, "Ghost")
    # The module is still healthy.
    assert ops.roundtrip_int(3) == 3


def test_unregistered_class_cannot_be_constructed():
    with pytest.raises(RuntimeError) as info:
        ops.make_ghost()
    assert "Ghost" in str(info.value)
    assert "has not been registered" in str(info.value)


def test_hand_written_instance_without_the_sealed_witness_fails_at_first_use():
    for _ in range(3):
        with pytest.raises(RuntimeError) as info:
            ops.make_unsealed()
        assert "No instance nor default method" in str(info.value)
        assert "pyClassSealed" in str(info.value)
    assert ops.roundtrip_int(3) == 3


# --- A constructor that constructs, under a Python subclass ----------------------


def test_nested_constructor_makes_helpers_of_their_own_type():
    b = ops.Base()
    assert type(b) is ops.Base
    h = b.helper()
    s = b.scoped_helper()
    assert type(h) is ops.Helper
    assert type(s) is ops.Helper
    assert h.value() == 1
    assert s.value() == 2
    assert b.helper() is h

    class Sub(ops.Base):
        def __init__(self):
            self.tag = "sub"

    x = Sub()
    assert type(x) is Sub
    assert isinstance(x, ops.Base)
    assert x.tag == "sub"
    assert type(x.helper()) is ops.Helper
    assert type(x.scoped_helper()) is ops.Helper
    assert x.helper().value() == 1
    assert x.scoped_helper().value() == 2
    before = sys.getrefcount(x)
    for _ in range(50):
        x.helper()
        x.scoped_helper()
    assert sys.getrefcount(x) == before
    del x
    gc.collect()
