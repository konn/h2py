{- |
Trusted escape hatches of the object model.

'PyRef' is exposed with its constructor here and nowhere else; the pointer
behind a reference is valid only for the scope that indexes it and only on an
attached thread.
-}
module H2Py.Object.Unsafe (
  PyRef (..),
  Sealed (..),
  sealedTypeOf,
  refPtr,
  mutPtr,
  unsafeRetagShare,
  unsafeRetagMut,
  unsafeBoundFromPtr,
  unsafeBorrowedFromPtr,
  handleFromNew,
  handleFromBorrowed,
  newResult,
  statusResult,
  newRefOp,
  statusOp,
  takeError,
  raiseErr,
) where

import H2Py.Object.Internal
