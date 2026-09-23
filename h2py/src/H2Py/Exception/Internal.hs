{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# OPTIONS_HADDOCK hide #-}

{- |
Errors in both directions.

Python errors are values: every fallible operation returns @'PyResult' a@ and
nothing unwinds for one.
Haskell exceptions are the exceptional path: they unwind to the trampoline,
which converts them with 'ToPyErr', sweeps, and poisons what the arena holds
mutably.
See section 5.5 of the design.
-}
module H2Py.Exception.Internal (
  module H2Py.Exception.Internal,
) where

import Control.Exception (ArithException (..), ArrayException (..), ErrorCall (..), Exception (..), IOException, SomeException, throwIO)
import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.BO (type (>=))
import Control.Monad.Borrow.Unsafe (unsafeSystemIOToBO)
import Data.Kind (Type)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (Ptr)
import H2Py.Object.Internal
import H2Py.Py.Internal
import H2Py.Runtime.Internal
import Prelude.Linear (Consumable (..), lseq)
import Unsafe.Linear qualified as Unsafe

{- | The built-in exception tags, and every class made by @newException@.
'pyErr' builds a lazy error from one.
-}
class PyExceptionClass (e :: Type) where
  -- | The exception type object; static for the built-ins, module-owned for the rest.
  exceptionTypeOf :: Proxy e -> Ptr PyObject

  -- | The Python name, for stubs and messages.
  exceptionName :: Proxy e -> Text

  -- | The witness that the instance is trusted; see Note [Sealed classes] in "H2Py.Object.Internal".
  exceptionSealed :: Proxy e -> Sealed

-- | A lazy error: the class and a message; needs no attachment.
pyErr :: forall e. (PyExceptionClass e) => Proxy e -> Text -> PyErr
pyErr p = case exceptionSealed p of
  UnsafeSealed -> PyErrLazy (exceptionTypeOf p)

-- | @pure . Left@; it raises nothing.
pyFail :: forall π γ a. PyErr -> Py π γ (PyResult a)
pyFail e = Control.pure (Left e)

{- | Consume the scope's linear values on a 'Left', thread them through on a
'Right', so that a method's @Left@ branch is one line.
-}
orFail :: forall s a. (Consumable s) => s %1 -> PyResult a %1 -> Either PyErr (s, a)
orFail s = \case
  Left e -> consume s `lseq` Left e
  Right a -> Right (s, a)

{- | An exception carrying a 'PyErr' through Haskell's exception mechanism.
Thrown by 'orThrow' and 'throwPy'; caught only by the trampoline, which raises
it in Python after poisoning what the arena holds mutably.
-}
newtype PyErrException = PyErrException PyErr
  deriving stock (Show)

instance Exception PyErrException where
  displayException (PyErrException e) = "H2Py: aborted with a Python error: " <> show e

{- | An abort, not PyO3's @?@: turn a 'Left' into a Haskell exception that
nothing below the trampoline can catch.
The linear values in scope are abandoned, which the semantics permit, and the
sweep poisons what the scope holds mutably.
In a @Mut@-receiver method this is a poor substitute for @?@, since it poisons
the object; 'orFail' is the tool there.
-}
orThrow :: forall π γ a. PyResult a %1 -> Py π γ a
orThrow = \case
  Left e -> unsafeSystemIOToBO (Unsafe.toLinear throwPyErr e)
  Right a -> Control.pure a

throwPyErr :: PyErr -> IO a
throwPyErr e = throwIO (PyErrException e)

-- | @orThrow . Left@.
throwPy :: forall π γ a. PyErr -> Py π γ a
throwPy e = unsafeSystemIOToBO (throwIO (PyErrException e))

-- | Materialise an error: the exception object, in the current arena.
toObject :: forall π γ. PyErr -> Py π γ (PyResult (Bound π PyBaseException))
toObject = \case
  PyErrObject h -> Control.fmap Right (fromHandle h)
  e@(PyErrLazy _ _) -> newRefOp \_ -> do
    raiseErr e
    c_takeError

-- | Incref an exception object into a 'PyErr'.
fromObject :: forall π π' γ. (π >= γ) => Borrowed π PyBaseException -> Py π' γ PyErr
fromObject ref = unsafePyIO (PyErrObject <$> handleFromBorrowed (refPtr ref))

-- | The message of a lazy error, or @str(e)@ of a materialised one.
errorMessage :: forall π γ. PyErr -> Py π γ (PyResult Text)
errorMessage = \case
  PyErrLazy _ msg -> Control.pure (Right msg)
  PyErrObject (PyHandle fp) -> unsafePyIO (withForeignPtr fp (strLike c_objectStr))

-- | Whether an error is an instance of the given class.
errorMatches :: forall e π γ. (PyExceptionClass e) => Proxy e -> PyErr -> Py π γ Bool
errorMatches p = \case
  PyErrLazy cls _ -> unsafePyIO ((> 0) <$> c_isSubclass cls (exceptionTypeOf p))
  PyErrObject (PyHandle fp) -> unsafePyIO (withForeignPtr fp \o -> (> 0) <$> c_isInstance o (exceptionTypeOf p))

{- | Haskell exceptions crossing the boundary.
The default is @RuntimeError@ with the 'displayException' text; 'ArithException',
'ArrayException', 'IOException' and 'ErrorCall' map to their nearest Python
class, and 'PyErrException' carries its error through unchanged.
-}
class (Exception e) => ToPyErr e where
  toPyErr :: e -> PyErr

instance ToPyErr PyErrException where
  toPyErr (PyErrException e) = e

instance ToPyErr ArithException where
  toPyErr = \case
    DivideByZero -> builtinErr ExcZeroDivisionError "division by zero"
    e -> builtinErr ExcArithmeticError (T.pack (displayException e))

instance ToPyErr ArrayException where
  toPyErr e = builtinErr ExcIndexError (T.pack (displayException e))

instance ToPyErr IOException where
  toPyErr e = builtinErr ExcOSError (T.pack (displayException e))

instance ToPyErr ErrorCall where
  toPyErr (ErrorCall msg) = builtinErr ExcRuntimeError (T.pack msg)

instance ToPyErr NotAttached where
  toPyErr e = builtinErr ExcRuntimeError (T.pack (displayException e))

instance ToPyErr AttachRefused where
  toPyErr e = builtinErr ExcRuntimeError (T.pack (displayException e))

-- | Convert any Haskell exception through the 'ToPyErr' instances above, else @RuntimeError@.
someExceptionToPyErr :: SomeException -> PyErr
someExceptionToPyErr e
  | Just x <- fromException e = toPyErr (x :: PyErrException)
  | Just x <- fromException e = toPyErr (x :: ArithException)
  | Just x <- fromException e = toPyErr (x :: ArrayException)
  | Just x <- fromException e = toPyErr (x :: IOException)
  | Just x <- fromException e = toPyErr (x :: ErrorCall)
  | Just x <- fromException e = toPyErr (x :: NotAttached)
  | Just x <- fromException e = toPyErr (x :: AttachRefused)
  | Just x <- fromException e = builtinErr ExcRuntimeError (T.pack (displayException (x :: ClassNotRegistered)))
  | otherwise = builtinErr ExcRuntimeError (T.pack (displayException e))

-- * Built-in exception tags

data BaseException

data ExceptionTag

data TypeError

data ValueError

data RuntimeError

data OverflowError

data KeyError

data IndexError

data AttributeError

data StopIteration

data NotImplementedError

data ZeroDivisionError

data ArithmeticError

data MemoryError

data OSError

data KeyboardInterrupt

data BufferError

data LookupError

data ImportError

data AssertionError

data SystemError

instance PyExceptionClass BaseException where
  exceptionTypeOf _ = builtinExceptionType ExcBaseException
  exceptionName _ = "BaseException"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass ExceptionTag where
  exceptionTypeOf _ = builtinExceptionType ExcException
  exceptionName _ = "Exception"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass TypeError where
  exceptionTypeOf _ = builtinExceptionType ExcTypeError
  exceptionName _ = "TypeError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass ValueError where
  exceptionTypeOf _ = builtinExceptionType ExcValueError
  exceptionName _ = "ValueError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass RuntimeError where
  exceptionTypeOf _ = builtinExceptionType ExcRuntimeError
  exceptionName _ = "RuntimeError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass OverflowError where
  exceptionTypeOf _ = builtinExceptionType ExcOverflowError
  exceptionName _ = "OverflowError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass KeyError where
  exceptionTypeOf _ = builtinExceptionType ExcKeyError
  exceptionName _ = "KeyError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass IndexError where
  exceptionTypeOf _ = builtinExceptionType ExcIndexError
  exceptionName _ = "IndexError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass AttributeError where
  exceptionTypeOf _ = builtinExceptionType ExcAttributeError
  exceptionName _ = "AttributeError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass StopIteration where
  exceptionTypeOf _ = builtinExceptionType ExcStopIteration
  exceptionName _ = "StopIteration"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass NotImplementedError where
  exceptionTypeOf _ = builtinExceptionType ExcNotImplementedError
  exceptionName _ = "NotImplementedError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass ZeroDivisionError where
  exceptionTypeOf _ = builtinExceptionType ExcZeroDivisionError
  exceptionName _ = "ZeroDivisionError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass ArithmeticError where
  exceptionTypeOf _ = builtinExceptionType ExcArithmeticError
  exceptionName _ = "ArithmeticError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass MemoryError where
  exceptionTypeOf _ = builtinExceptionType ExcMemoryError
  exceptionName _ = "MemoryError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass OSError where
  exceptionTypeOf _ = builtinExceptionType ExcOSError
  exceptionName _ = "OSError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass KeyboardInterrupt where
  exceptionTypeOf _ = builtinExceptionType ExcKeyboardInterrupt
  exceptionName _ = "KeyboardInterrupt"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass BufferError where
  exceptionTypeOf _ = builtinExceptionType ExcBufferError
  exceptionName _ = "BufferError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass LookupError where
  exceptionTypeOf _ = builtinExceptionType ExcLookupError
  exceptionName _ = "LookupError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass ImportError where
  exceptionTypeOf _ = builtinExceptionType ExcImportError
  exceptionName _ = "ImportError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass AssertionError where
  exceptionTypeOf _ = builtinExceptionType ExcAssertionError
  exceptionName _ = "AssertionError"
  exceptionSealed _ = UnsafeSealed

instance PyExceptionClass SystemError where
  exceptionTypeOf _ = builtinExceptionType ExcSystemError
  exceptionName _ = "SystemError"
  exceptionSealed _ = UnsafeSealed
