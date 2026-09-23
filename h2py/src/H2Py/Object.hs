{- |
Python object references as borrows of arena-owned slots, and the protocol
operations on them.
See section 5.2 of the design.
-}
module H2Py.Object (
  -- * References
  PyRef,
  Bound,
  Borrowed,
  PyHandle,
  toHandle,
  fromHandle,
  fromHandleShare,

  -- * Tags
  PyAny,
  PyLong,
  PyFloat,
  PyBool,
  PyStr,
  PyBytes,
  PyTuple,
  PyList,
  PyDict,
  PySet,
  PyNone,
  PyBaseException,
  PyType,
  PyModule,
  PyTypeOf (..),
  type (:<:),
  upcastRef,
  upcastMut,
  asAny,
  asAnyMut,
  downcast,
  downcastMut,
  typeOf,

  -- * Reading operations, on views
  getAttr,
  hasAttr,
  getItem,
  getIndex,
  len,
  repr,
  str,
  isTrue,
  hash,
  CompareOp (..),
  richCompareBool,
  equals,
  call,
  call0,
  callMethod,
  callMethod0,
  iterate,
  next,

  -- * Mutating operations, on handles
  setAttr,
  setItem,
  delItem,
  delAttr,
  listAppend,
  setAdd,

  -- * Constructors
  toStr,
  toBytes,
  toInt,
  toInteger',
  toFloat,
  toBool,
  none,
  toList,
  toTuple,
  emptyTuple,
  toDict,
  toSet,
  newDict,
  newList,

  -- * Copying values out
  HsOf,
  PyValue,
  copyOut,

  -- * Signals
  checkSignals,
) where

import H2Py.Object.Internal
import Prelude ()
