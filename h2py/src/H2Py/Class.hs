{- |
Python classes with Haskell payloads.
See section 5.3 of the design.
-}
module H2Py.Class (
  PyClass (..),
  PyFrozenClass (..),
  PyReceiver (..),
  Receiver,
  Lent,
  Frozen,
  PyExtends,
  TypeCell,
  newObject,
  newObjectWith,
  newFrozenObject,
  derefMut,
  derefShare,
  copyPayload,
  readFrozen,
  super,
  superMut,
  module H2Py.Class.Slot,
  module H2Py.Class.Iterator,
) where

import H2Py.Class.Internal
import H2Py.Class.Iterator
import H2Py.Class.Slot
