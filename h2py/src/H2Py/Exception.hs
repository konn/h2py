{- |
Errors in both directions: Python errors as values, Haskell exceptions as the
exceptional path.
See section 5.5 of the design.
-}
module H2Py.Exception (
  PyErr,
  PyResult,
  PyExceptionClass (..),
  pyErr,
  pyFail,
  orFail,
  orThrow,
  throwPy,
  PyErrException (..),
  toObject,
  fromObject,
  errorMessage,
  errorMatches,
  ToPyErr (..),

  -- * Lazy errors with built-in classes
  typeError,
  valueError,
  runtimeError,
  overflowError,
  bufferError,

  -- * Built-in exception tags
  BaseException,
  ExceptionTag,
  TypeError,
  ValueError,
  RuntimeError,
  OverflowError,
  KeyError,
  IndexError,
  AttributeError,
  StopIteration,
  NotImplementedError,
  ZeroDivisionError,
  ArithmeticError,
  MemoryError,
  OSError,
  KeyboardInterrupt,
  BufferError,
  LookupError,
  ImportError,
  AssertionError,
  SystemError,
) where

import H2Py.Exception.Internal
import H2Py.Object.Internal (PyErr, PyResult, bufferError, overflowError, runtimeError, typeError, valueError)
