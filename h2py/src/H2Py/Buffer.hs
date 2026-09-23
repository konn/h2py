{- |
Buffers: NumPy arrays and every other exporter of the buffer protocol as
pure-borrow vectors over memory that Python owns, and Haskell-owned vectors
handed to Python without a copy.
See section 5.7 of the design.

Acquisition is the fallible step and takes no continuation; the scopes over an
acquired view cannot fail, run detached from the interpreter, and hand the
view back.

@
sortInPlace :: Bound π PyAny %1 -> Py π π (PyResult ())
sortInPlace array = Control.do
  r <- requestBufferMut \@Double array
  case r of
    Left e -> Control.pure (Left e)
    Right buf -> Control.do
      ((), buf) <- withBufferMut buf \\vec -> Control.do
        Ur gen <- liftSystemIOU newStdGen
        Ur workers <- liftSystemIOU getNumCapabilities
        vec <- qsortDC gen workers 4096 vec
        Control.pure (consume vec)
      Control.pure (Right (consume buf))
@

The honest residual, shared with rust-numpy: the buffer protocol does not lock
the array, so Python code, or a view H2Py did not create, can still write to
it while a view is held.
The disjointness pure-borrow proves is among Haskell borrows; two H2Py scopes
on any threads are refused a second exclusive view of overlapping memory by
the shim's borrow registry.
-}
module H2Py.Buffer (
  -- * Vectors over foreign memory
  SVector,

  -- * Views
  BufferMut,
  BufferShare,
  BufferFormat (..),
  requestBufferMut,
  requestBufferShare,
  withBufferMut,
  withBufferShare,
  releaseBuffer,
  bufferMutLength,
  bufferShareLength,

  -- * Exporting Haskell memory
  newArray,
) where

import H2Py.Buffer.Internal
