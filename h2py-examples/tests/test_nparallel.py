import sys
import threading

import numpy as np
import pytest

import h2py_examples as m

np_ = m.nparallel


@pytest.mark.parametrize("n", [0, 1, 2, 3, 17, 4096, 10_000, 1_000_003])
def test_sort_in_place_matches_numpy(n):
    rng = np.random.default_rng(n)
    arr = rng.standard_normal(n)
    expected = np.sort(arr)
    assert np_.sort_in_place(arr) is None
    np.testing.assert_array_equal(arr, expected)


def test_sort_in_place_keyword():
    arr = np.array([3.0, 1.0, 2.0])
    np_.sort_in_place(arr=arr)
    assert arr.tolist() == [1.0, 2.0, 3.0]


@pytest.mark.parametrize("n", [0, 1, 2, 1000, 1_000_003])
def test_sum_matches_numpy(n):
    rng = np.random.default_rng(n + 7)
    arr = rng.standard_normal(n)
    assert np_.sum(arr) == pytest.approx(float(np.sum(arr)), rel=1e-9, abs=1e-9)


def test_sum_of_readonly_array_is_allowed():
    arr = np.arange(10.0)
    arr.setflags(write=False)
    assert np_.sum(arr) == 45.0


@pytest.mark.parametrize("n", [0, 1, 2, 999, 100_001])
def test_scale_in_place(n):
    rng = np.random.default_rng(n + 3)
    arr = rng.standard_normal(n)
    expected = arr * 2.5
    assert np_.scale_in_place(arr, 2.5) is None
    np.testing.assert_array_equal(arr, expected)
    np_.scale_in_place(arr, k=0.0)
    assert not arr.any()


def assert_fft_close(actual, expected):
    # pure-borrow's butterfly advances the twiddle by repeated multiplication,
    # so its error grows about linearly with n (2-norm relative error near
    # 2.6e-12 * n measured on Apple Silicon, against pocketfft's 1e-15);
    # the bound below leaves a factor of ten over that.
    n = expected.size
    scale = max(float(np.linalg.norm(expected)), 1e-300)
    assert float(np.linalg.norm(actual - expected)) / scale <= max(4e-11 * n, 1e-14)


@pytest.mark.parametrize("log2n", [0, 1, 2, 3, 4, 10, 12, 13, 16, 20])
def test_fft_matches_numpy(log2n):
    n = 1 << log2n
    rng = np.random.default_rng(log2n)
    arr = rng.standard_normal(n) + 1j * rng.standard_normal(n)
    expected = np.fft.fft(arr)
    assert np_.fft(arr) is None
    assert arr.dtype == np.complex128
    assert_fft_close(arr, expected)
    if n <= 4096:
        np.testing.assert_allclose(arr, expected, rtol=1e-8, atol=1e-8)


def test_fft_of_real_signal_and_inverse():
    n = 1 << 14
    t = np.arange(n) / n
    signal = np.cos(2 * np.pi * 50 * t) + 0.5 * np.sin(2 * np.pi * 300 * t)
    arr = signal.astype(np.complex128)
    np_.fft(arr)
    spectrum = np.abs(arr)
    assert set(np.flatnonzero(spectrum > 1.0)) == {50, n - 50, 300, n - 300}
    np.testing.assert_allclose(np.fft.ifft(arr).real, signal, atol=1e-7)


def test_fft_keyword_and_two_d():
    arr = np.array([[1.0, 2.0], [3.0, 4.0]], dtype=np.complex128)
    expected = np.fft.fft(arr.ravel())
    np_.fft(arr=arr)
    np.testing.assert_allclose(arr.ravel(), expected)


@pytest.mark.parametrize("n", [3, 5, 6, 12, 1000, 4097])
def test_fft_non_power_of_two_raises_value_error(n):
    arr = np.arange(n, dtype=np.complex128)
    before = arr.copy()
    with pytest.raises(ValueError, match="power of two"):
        np_.fft(arr)
    np.testing.assert_array_equal(arr, before)


def test_fft_empty_raises_value_error():
    with pytest.raises(ValueError, match="power of two"):
        np_.fft(np.zeros(0, dtype=np.complex128))


def test_fft_rejects_other_dtypes_and_readonly():
    with pytest.raises(BufferError, match="format"):
        np_.fft(np.arange(8.0))
    with pytest.raises(BufferError, match="format"):
        np_.fft(np.arange(8, dtype=np.complex64))
    ro = np.arange(8, dtype=np.complex128)
    ro.setflags(write=False)
    with pytest.raises(BufferError):
        np_.fft(ro)
    with pytest.raises(BufferError):
        np_.fft(np.arange(16, dtype=np.complex128)[::2])
    with pytest.raises(TypeError):
        np_.fft([1.0, 2.0])


def numpy_stencil(arr):
    # The zero-padded three-point average, which numpy.convolve(arr,
    # numpy.ones(3) / 3, mode="same") also computes for n >= 3.
    padded = np.concatenate([[0.0], arr, [0.0]])
    return (padded[:-2] + padded[1:-1] + padded[2:]) / 3


@pytest.mark.parametrize("n", [0, 1, 2, 3, 4, 5, 1000, 1001, 100_001])
def test_stencil_matches_numpy(n):
    rng = np.random.default_rng(n + 11)
    arr = rng.standard_normal(n)
    expected = numpy_stencil(arr)
    assert np_.stencil(arr) is None
    np.testing.assert_allclose(arr, expected, rtol=1e-12, atol=1e-12)


def test_stencil_boundary_between_halves():
    # Each half must see the original edge of the other, not the value the
    # other thread has already written.
    arr = np.array([1.0, 2.0, 4.0, 8.0, 16.0, 32.0])
    np_.stencil(arr)
    expected = np.array([3.0, 7.0, 14.0, 28.0, 56.0, 48.0]) / 3
    np.testing.assert_allclose(arr, expected)


def test_stencil_keyword_and_two_d():
    arr = np.arange(6.0).reshape(2, 3)
    expected = numpy_stencil(np.arange(6.0)).reshape(2, 3)
    np_.stencil(arr=arr)
    np.testing.assert_allclose(arr, expected)


def test_stencil_errors():
    ro = np.arange(10.0)
    ro.setflags(write=False)
    with pytest.raises(BufferError):
        np_.stencil(ro)
    with pytest.raises(BufferError, match="format"):
        np_.stencil(np.arange(10, dtype=np.float32))
    with pytest.raises(BufferError):
        np_.stencil(np.arange(20.0)[::2])
    with pytest.raises(TypeError):
        np_.stencil(None)
    np.testing.assert_array_equal(ro, np.arange(10.0))


def test_fft_and_stencil_refcounts_are_stable():
    rng = np.random.default_rng(5)
    carr = rng.standard_normal(1024) + 0j
    odd = np.arange(3, dtype=np.complex128)
    empty = np.zeros(0, dtype=np.complex128)
    real = rng.standard_normal(1000)
    ro = np.arange(10.0)
    ro.setflags(write=False)
    f32 = np.arange(10, dtype=np.float32)
    before = [sys.getrefcount(x) for x in (carr, odd, empty, real, ro, f32)]
    for _ in range(50):
        np_.fft(carr)
        np_.stencil(real)
        with pytest.raises(ValueError):
            np_.fft(odd)
        with pytest.raises(ValueError):
            np_.fft(empty)
        with pytest.raises(BufferError):
            np_.fft(real)
        with pytest.raises(BufferError):
            np_.stencil(ro)
        with pytest.raises(BufferError):
            np_.stencil(f32)
    assert [sys.getrefcount(x) for x in (carr, odd, empty, real, ro, f32)] == before


def test_fft_two_threads_on_one_array_is_refused_or_serialised():
    # Both calls detach for the transform, so an overlapping second request
    # finds the range held exclusively and answers BufferError; without an
    # overlap the two transforms run one after the other.
    rng = np.random.default_rng(9)
    n = 1 << 21
    for _ in range(8):
        base = rng.standard_normal(n) + 1j * rng.standard_normal(n)
        arr = base.copy()
        errors = []
        barrier = threading.Barrier(2)

        def work():
            barrier.wait()
            try:
                np_.fft(arr)
            except BufferError as e:
                errors.append(e)

        threads = [threading.Thread(target=work) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert len(errors) <= 1
        expected = np.fft.fft(base) if errors else np.fft.fft(np.fft.fft(base))
        assert_fft_close(arr, expected)
        if errors:
            assert "borrowed" in str(errors[0])
            return
    pytest.skip("the two calls never overlapped in 8 attempts")


def test_iota_equals_arange():
    buf = np_.iota(10)
    assert type(buf).__name__ == "HsBuffer"
    np.testing.assert_array_equal(np.asarray(buf), np.arange(10.0))
    assert np.asarray(np_.iota(0)).shape == (0,)
    with pytest.raises(ValueError):
        np_.iota(-1)


def test_iota_is_not_copied():
    buf = np_.iota(1000)
    a = np.asarray(buf)
    assert a.dtype == np.float64
    assert a.flags.writeable
    # The array is a view of the exporter's memory, not a copy.
    assert a.base is not None
    assert not a.flags.owndata
    mv = memoryview(buf)
    assert mv.format == "d"
    assert mv.nbytes == 8000
    a[5] = -1.0
    assert np.asarray(buf)[5] == -1.0
    assert mv[5] == -1.0
    # Haskell kernels run on it too.
    np_.scale_in_place(a, 2.0)
    assert np.asarray(buf)[5] == -2.0
    assert np.asarray(buf)[6] == 12.0
    np_.sort_in_place(a)
    assert np.asarray(buf)[0] == -2.0
    del a, mv
    # The memory is alive as long as the exporter is.
    assert np.asarray(buf)[0] == -2.0


def test_iota_large_and_collected():
    for _ in range(20):
        a = np.asarray(np_.iota(100_000))
        assert a[-1] == 99_999.0
    del a


def test_readonly_array_raises_buffer_error():
    arr = np.arange(10.0)
    arr.setflags(write=False)
    with pytest.raises(BufferError):
        np_.sort_in_place(arr)
    with pytest.raises(BufferError):
        np_.scale_in_place(arr, 2.0)
    np.testing.assert_array_equal(arr, np.arange(10.0))


def test_float32_array_raises_buffer_error():
    arr = np.arange(10, dtype=np.float32)
    with pytest.raises(BufferError, match="format"):
        np_.sort_in_place(arr)
    with pytest.raises(BufferError, match="format"):
        np_.sum(arr)


def test_int64_array_raises_buffer_error():
    arr = np.arange(10, dtype=np.int64)
    with pytest.raises(BufferError):
        np_.sort_in_place(arr)


def test_non_contiguous_view_raises_buffer_error():
    arr = np.arange(20.0)
    view = arr[::2]
    with pytest.raises(BufferError):
        np_.sort_in_place(view)
    with pytest.raises(BufferError):
        np_.sum(view)
    # A transposed 2-D array is not C-contiguous either.
    two_d = np.arange(12.0).reshape(3, 4).T
    with pytest.raises(BufferError):
        np_.sort_in_place(two_d)


def test_two_d_array_is_flattened():
    arr = np.ascontiguousarray(np.arange(12.0)[::-1]).reshape(3, 4)
    assert arr.flags.c_contiguous
    np_.sort_in_place(arr)
    np.testing.assert_array_equal(arr.ravel(), np.arange(12.0))
    assert np_.sum(arr) == 66.0


def test_non_buffer_raises_type_error():
    with pytest.raises(TypeError):
        np_.sort_in_place([3.0, 1.0])
    with pytest.raises(TypeError):
        np_.sum(1)


def test_refcounts_are_stable():
    rng = np.random.default_rng(0)
    arr = rng.standard_normal(1000)
    ro = np.arange(10.0)
    ro.setflags(write=False)
    f32 = np.arange(10, dtype=np.float32)
    strided = np.arange(20.0)[::2]
    before = sys.getrefcount(arr)
    before_ro = sys.getrefcount(ro)
    before_f32 = sys.getrefcount(f32)
    before_strided = sys.getrefcount(strided)
    for _ in range(50):
        np_.sort_in_place(arr)
        np_.sum(arr)
        np_.scale_in_place(arr, 1.0)
        with pytest.raises(BufferError):
            np_.sort_in_place(ro)
        with pytest.raises(BufferError):
            np_.sort_in_place(f32)
        with pytest.raises(BufferError):
            np_.sum(f32)
        with pytest.raises(BufferError):
            np_.sort_in_place(strided)
    assert sys.getrefcount(arr) == before
    assert sys.getrefcount(ro) == before_ro
    assert sys.getrefcount(f32) == before_f32
    assert sys.getrefcount(strided) == before_strided


def test_result_refcount_of_new_array():
    buf = np_.iota(5)
    assert sys.getrefcount(buf) == 2


def test_two_threads_sorting_one_array_is_refused():
    # Both calls detach for the sort, so the second request finds the range
    # held exclusively in the borrow registry and answers BufferError.
    rng = np.random.default_rng(42)
    observed = False
    for attempt in range(8):
        arr = rng.standard_normal(4_000_000)
        expected = np.sort(arr)
        errors = []
        barrier = threading.Barrier(2)

        def work():
            barrier.wait()
            try:
                np_.sort_in_place(arr)
            except BufferError as e:
                errors.append(e)

        threads = [threading.Thread(target=work) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert len(errors) <= 1
        np.testing.assert_array_equal(arr, expected)
        if len(errors) == 1:
            observed = True
            assert "borrowed" in str(errors[0])
            break
    assert observed, "the two calls never overlapped in 8 attempts"


def test_readers_may_overlap():
    arr = np.random.default_rng(1).standard_normal(2_000_000)
    expected = float(np.sum(arr))
    results = []
    barrier = threading.Barrier(4)

    def work():
        barrier.wait()
        results.append(np_.sum(arr))

    threads = [threading.Thread(target=work) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(results) == 4
    for r in results:
        assert r == pytest.approx(expected, rel=1e-9)


def test_stub_mentions_nparallel():
    stub = m.__h2py_stub__()
    assert "nparallel" in stub
    sub_stub = np_.__h2py_stub__()
    assert "def sort_in_place(arr: numpy.typing.NDArray[numpy.float64]) -> None" in sub_stub
    assert "def fft(arr: numpy.typing.NDArray[numpy.complex128]) -> None" in sub_stub
    assert "def stencil(arr: numpy.typing.NDArray[numpy.float64]) -> None" in sub_stub
    assert "def sum(arr: numpy.typing.NDArray[numpy.float64]) -> float" in sub_stub
    assert "def scale_in_place(arr: numpy.typing.NDArray[numpy.float64], k: float) -> None" in sub_stub
    assert "def iota(n: int) -> collections.abc.Buffer" in sub_stub
    assert sys.modules["h2py_examples.nparallel"] is np_
