{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

{- |
The parallel showcase: the @nparallel@ submodule, whose functions run
pure-borrow's kernels over NumPy arrays in place, detached from the
interpreter, on every core.
See section 5.7 of the design.

Every kernel validates its input attached and answers 'Left' before the
scheduler runs, so that no branch of a detached body ever throws on an input
the kernel rejects (design 5.7, 7 Phase 4).
-}
module H2Py.Examples.NParallel (
  sortInPlace,
  fft,
  stencil,
  sum_,
  scaleInPlace,
  iota,
  nparallelSpec,
) where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.DivideConquer.Linear (fftDC, qsortDC)
import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.BO (Mut, Share, asksLinearly, parBO, reborrowing_, type (/\), type (>=))
import Control.Monad.Borrow.IO (BIO, MonadIO (..))
import Data.Bits (popCount)
import Data.Complex (Complex, conjugate)
import Data.Text qualified as T
import Data.Vector.Generic.Mutable.Linear.Borrow.Unrestricted qualified as Vector
import Data.Vector.Storable qualified as SV
import H2Py
import H2Py.Buffer
import Prelude.Linear
import System.Random (newStdGen)

-- | The hint every @float64@ array parameter renders.
ndarray :: String
ndarray = "numpy.typing.NDArray[numpy.float64]"

-- | The hint of a @complex128@ array parameter.
cndarray :: String
cndarray = "numpy.typing.NDArray[numpy.complex128]"

-- | Subvectors no longer than this are sorted or transformed sequentially.
threshold :: Int
threshold = 4096

-- * sort_in_place

-- | Sort a @float64@ array in place with pure-borrow's parallel quicksort.
sortInPlace :: Bound π PyAny %1 -> Py π π (PyResult ())
sortInPlace array = Control.do
  r <- requestBufferMut @Double array
  sortAcquired r

sortAcquired :: PyResult (BufferMut π Double) %1 -> Py π π (PyResult ())
sortAcquired (Left e) = Control.pure (Left e)
sortAcquired (Right buf) = Control.do
  ((), buf) <- withBufferMut buf sortBody
  buf `lseq` Control.pure (Right ())

-- | The body runs detached: 'BIO' is 'Forkable', so the scheduler needs no lift.
sortBody :: forall α γ. Mut (α /\ γ) (SVector Double) %1 -> BIO (α /\ γ) ()
sortBody vec = Control.do
  Ur gen <- liftSystemIOU newStdGen
  Ur workers <- liftSystemIOU getNumCapabilities
  vec <- qsortDC gen workers threshold vec
  Control.pure (consume vec)

-- * fft

{- | The discrete Fourier transform of a @complex128@ array in place, with
pure-borrow's parallel 'fftDC', in the sign convention of @numpy.fft.fft@.

The length must be a power of two; any other length, the empty array
included, answers @ValueError@ before the view is opened, since 'fftDC'
itself would throw from inside the detached body.
'fftDC' evaluates the kernel @exp(+2πi jk/n)@, the unnormalised inverse in
NumPy's terms, so the body conjugates the input before and the output after,
each pass over two halves in parallel.
-}
fft :: Bound π PyAny %1 -> Py π π (PyResult ())
fft array = Control.do
  r <- requestBufferMut @(Complex Double) array
  fftAcquired r

fftAcquired :: PyResult (BufferMut π (Complex Double)) %1 -> Py π π (PyResult ())
fftAcquired (Left e) = Control.pure (Left e)
fftAcquired (Right buf) = case bufferMutLength buf of
  (Ur n, buf)
    | popCount n /= 1 ->
        buf
          `lseq` Control.pure
            (Left (valueError (T.pack ("fft: the length " <> show n <> " is not a power of two"))))
    | otherwise -> Control.do
        ((), buf) <- withBufferMut buf fftBody
        buf `lseq` Control.pure (Right ())

fftBody :: forall α γ. Mut (α /\ γ) (SVector (Complex Double)) %1 -> BIO (α /\ γ) ()
fftBody vec = Control.do
  Ur gen <- liftSystemIOU newStdGen
  Ur workers <- liftSystemIOU getNumCapabilities
  vec <- conjugateHalves vec
  vec <- fftDC gen workers threshold vec
  vec <- conjugateHalves vec
  Control.pure (consume vec)

{- | Conjugate every element, the two halves on their own threads through
'parBIO', and hand the vector back through a reborrow.
The scope is the borrow's own, which is what the reborrow's outlives
obligation resolves at.
-}
conjugateHalves :: forall α. Mut α (SVector (Complex Double)) %1 -> BIO α (Mut α (SVector (Complex Double)))
conjugateHalves vec = reborrowing_ vec \shorter -> case Vector.size shorter of
  (Ur n, shorter) -> case Vector.splitAt (n `div` 2) shorter of
    (left, right) -> Control.do
      (left, right) <- parBIO (mapLoop conjugate left) (mapLoop conjugate right)
      Control.pure (left `lseq` right `lseq` ())

-- * stencil

{- | A three-point moving average in place over a @float64@ array,
@y[i] = (x[i-1] + x[i] + x[i+1]) / 3@ with the missing neighbours at the ends
taken as zero, which is @numpy.convolve(x, numpy.ones(3) / 3, mode="same")@.

The array is split in two halves that run on their own threads through
'parBIO'; the original values on either side of the split are read before the
split, so that each half sees its neighbour's edge as it was, not as the
other thread has already rewritten it.
-}
stencil :: Bound π PyAny %1 -> Py π π (PyResult ())
stencil array = Control.do
  r <- requestBufferMut @Double array
  stencilAcquired r

stencilAcquired :: PyResult (BufferMut π Double) %1 -> Py π π (PyResult ())
stencilAcquired (Left e) = Control.pure (Left e)
stencilAcquired (Right buf) = Control.do
  ((), buf) <- withBufferMut buf stencilBody
  buf `lseq` Control.pure (Right ())

stencilBody :: forall α γ. Mut (α /\ γ) (SVector Double) %1 -> BIO (α /\ γ) ()
stencilBody vec = case Vector.size vec of
  (Ur n, vec)
    | n < 2 -> Control.do
        vec <- stencilLoop 0 0 vec
        Control.pure (consume vec)
    | otherwise -> Control.do
        let half = n `div` 2
        (Ur leftEdge, vec) <- Vector.unsafeGet (half - 1) vec
        (Ur rightEdge, vec) <- Vector.unsafeGet half vec
        stencilSplit half leftEdge rightEdge vec

-- | The two halves, each with the original value just beyond its own edge.
stencilSplit :: forall α γ. Int -> Double -> Double -> Mut (α /\ γ) (SVector Double) %1 -> BIO (α /\ γ) ()
stencilSplit half leftEdge rightEdge vec = case Vector.splitAt half vec of
  (left, right) -> Control.do
    (left, right) <- parBIO (stencilLoop 0 rightEdge left) (stencilLoop leftEdge 0 right)
    Control.pure (left `lseq` right `lseq` ())

{- | One half: @before@ and @after@ are the original neighbours beyond the
ends, and the loop carries the original value of the element it just
overwrote as the next element's left neighbour.
-}
stencilLoop :: forall α β. (α >= β) => Double -> Double -> Mut α (SVector Double) %1 -> BIO β (Mut α (SVector Double))
stencilLoop before after vec = case Vector.size vec of
  (Ur n, vec) -> go before 0 n vec
  where
    go :: Double -> Int -> Int -> Mut α (SVector Double) %1 -> BIO β (Mut α (SVector Double))
    go !prev i n v
      | i >= n = Control.pure v
      | otherwise = Control.do
          (Ur cur, v) <- Vector.unsafeGet i v
          (Ur next, v) <- if i + 1 < n then Vector.unsafeGet (i + 1) v else Control.pure (Ur after, v)
          v <- Vector.unsafeWrite i ((prev + cur + next) / 3) v
          go cur (i + 1) n v

-- * sum

-- | The sum of a @float64@ array, read through a shared view, halves in parallel.
sum_ :: Borrowed π PyAny -> Py π π (PyResult Double)
sum_ array = Control.do
  Ur r <- Control.fmap move (requestBufferShare @Double array)
  sumAcquired r

-- | A read-only view is unrestricted, so the acquired result is moved out of the linear bind.
sumAcquired :: PyResult (BufferShare π Double) -> Py π π (PyResult Double)
sumAcquired (Left e) = Control.pure (Left e)
sumAcquired (Right buf) = Control.do
  s <- withBufferShare buf sumBody
  Control.pure (Right s)

sumBody :: forall α γ. Share (α /\ γ) (SVector Double) -> BIO (α /\ γ) Double
sumBody vec = case Vector.size vec of
  (Ur n, vec) -> case Vector.splitAt (n `div` 2) vec of
    (left, right) -> Control.do
      (Ur a, Ur b) <- parBO (sumHalf left) (sumHalf right)
      Control.pure (a + b)

{- | A strict left fold over a shared view, element by element through
'Vector.unsafeGet': the unrestricted vector API of pure-borrow has no fold,
and this loop is what replaces the copy of each half that an earlier version
made.
-}
sumHalf :: forall α β. (α >= β) => Share α (SVector Double) -> BIO β (Ur Double)
sumHalf vec = case Vector.size vec of
  (Ur n, vec) -> go 0 0 n vec
  where
    go :: Double -> Int -> Int -> Share α (SVector Double) %1 -> BIO β (Ur Double)
    go !acc i n v
      | i >= n = v `lseq` Control.pure (Ur acc)
      | otherwise = Control.do
          (Ur x, v) <- Vector.unsafeGet i v
          go (acc + x) (i + 1) n v

-- * scale_in_place

-- | Multiply every element of a @float64@ array by @k@ in place, halves in parallel.
scaleInPlace :: Bound π PyAny %1 -> Double -> Py π π (PyResult ())
scaleInPlace array k = Control.do
  r <- requestBufferMut @Double array
  scaleAcquired k r

scaleAcquired :: Double -> PyResult (BufferMut π Double) %1 -> Py π π (PyResult ())
scaleAcquired _ (Left e) = Control.pure (Left e)
scaleAcquired k (Right buf) = Control.do
  ((), buf) <- withBufferMut buf (scaleBody k)
  buf `lseq` Control.pure (Right ())

-- | Two disjoint halves of one 'Mut', each scaled on its own thread.
scaleBody :: forall α γ. Double -> Mut (α /\ γ) (SVector Double) %1 -> BIO (α /\ γ) ()
scaleBody k vec = case Vector.size vec of
  (Ur n, vec) -> case Vector.splitAt (n `div` 2) vec of
    (left, right) -> Control.do
      (left, right) <- parBO (mapLoop (\x -> x * k) left) (mapLoop (\x -> x * k) right)
      Control.pure (left `lseq` right `lseq` ())

-- | Apply a function to every element of a borrowed vector in place.
mapLoop :: forall e α β. (SV.Storable e, α >= β) => (e -> e) -> Mut α (SVector e) %1 -> BIO β (Mut α (SVector e))
mapLoop f vec = case Vector.size vec of
  (Ur n, vec) -> go 0 n vec
  where
    go :: Int -> Int -> Mut α (SVector e) %1 -> BIO β (Mut α (SVector e))
    go i n v
      | i >= n = Control.pure v
      | otherwise = Control.do
          (Ur x, v) <- Vector.unsafeGet i v
          v <- Vector.unsafeWrite i (f x) v
          go (i + 1) n v

-- * iota

-- | A fresh Haskell-owned @float64@ array @[0, 1, ..., n - 1]@, exported without a copy.
iota :: Int -> Py π π (PyResult (Bound π PyAny))
iota n
  | n < 0 = Control.pure (Left (valueError "iota: n must be non-negative"))
  | otherwise = Control.do
      vec <- asksLinearly (Vector.fromVector (SV.generate n fromIntegral))
      newArray @Double vec

-- * Registration

-- | The @nparallel@ submodule; the module lists it under @msSubmodules@.
nparallelSpec :: ModuleSpec
nparallelSpec =
  submodule
    "nparallel"
    [ fn "sort_in_place" 'sortInPlace
        & param 0 "arr"
        & hint 0 ndarray
        & doc "Sort a float64 array in place with a parallel quicksort, the interpreter released."
    , fn "fft" 'fft
        & param 0 "arr"
        & hint 0 cndarray
        & doc "The discrete Fourier transform of a complex128 array in place, as numpy.fft.fft computes it, with a parallel radix-2 FFT; the length must be a power of two (ValueError otherwise)."
    , fn "stencil" 'stencil
        & param 0 "arr"
        & hint 0 ndarray
        & doc "A three-point moving average of a float64 array in place, zero beyond the ends, the two halves in parallel: numpy.convolve(arr, numpy.ones(3) / 3, mode='same')."
    , fn "sum" 'sum_
        & param 0 "arr"
        & hint 0 ndarray
        & doc "The sum of a float64 array, read through a shared buffer view, two halves in parallel."
    , fn "scale_in_place" 'scaleInPlace
        & param 0 "arr"
        & hint 0 ndarray
        & param 1 "k"
        & doc "Multiply every element of a float64 array by k in place, two halves in parallel."
    , fn "iota" 'iota
        & param 0 "n"
        & resultAs "collections.abc.Buffer"
        & doc "A Haskell-owned float64 array [0, 1, ..., n - 1] that numpy.asarray wraps without a copy."
    ]
    []
