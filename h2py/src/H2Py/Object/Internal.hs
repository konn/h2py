{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# OPTIONS_HADDOCK hide #-}

{- |
Python object references as pure-borrow borrows of arena-owned slots, the
GC-managed handle, Python errors as values, and the protocol operations.
See sections 5.2 and 5.5 of the design.

The principle: a shared borrow may not mutate; a unique borrow may mutate, even
destructively, but may not /invalidate/ the resource, because release belongs
to the owner.
For a Python reference the resource is the slot holding a +1, the owner is the
scope's arena, and so there is no @decref@: a handle can mutate the object, a
view can read it, and the +1 goes away when the arena is swept at the end of
@π@.
-}
module H2Py.Object.Internal (
  module H2Py.Object.Internal,
) where

import Control.Exception (Exception (..))
import Control.Functor.Linear qualified as Control
import Control.Monad qualified as NonLinear
import Control.Monad.Borrow.BO (Mut, Share, share, type (>=))
import Control.Monad.Borrow.Clone (Clone (..))
import Control.Monad.Borrow.Copyable (Copyable (..))
import Control.Monad.Borrow.Unsafe (Alias (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BSU
import Data.Kind (Type)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Foreign qualified as TF
import Foreign.C.String (withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Concurrent qualified as Concurrent
import Foreign.ForeignPtr (ForeignPtr, withForeignPtr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, pokeArray)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)
import GHC.TypeError (ErrorMessage (..))
import H2Py.Py.Internal
import H2Py.Runtime.Internal
import Prelude.Linear (Consumable (..), Dupable (..), Movable (..), Ur (..))
import Prelude.Linear.Unsatisfiable (Unsatisfiable, unsatisfiable)
import Unsafe.Linear qualified as Unsafe

-- * References

{- | The raw slot of a Python reference: a pointer whose +1 is owned by the
scope's arena, or by Python's frame for an argument.
Never exposed bare: it is only ever reached through 'Bound' and 'Borrowed'.
-}
newtype PyRef (t :: Type) = PyRef (Ptr PyObject)

type role PyRef nominal

{- | The unique handle to an arena-owned Python reference: linear, the only
handle through which the object may be mutated from Haskell.
It is a 'Mut' borrow, so it is 'Consumable' through the affine no-op, and
neither 'Dupable' nor 'Movable'.
-}
type Bound π t = Mut π (PyRef t)

{- | A view of a Python reference: unrestricted, freely copied, read-only by
protocol.
It is a 'Share' borrow, so it is 'Dupable' and 'Movable', with 'subShare' as
its shortening.
-}
type Borrowed π t = Share π (PyRef t)

instance (Unsatisfiable ('Text "A Python reference cannot be copied out of its borrow: use toHandle, or copyOut for a value type")) => Copyable (PyRef t) where
  copy = unsatisfiable

instance (Unsatisfiable ('Text "A Python reference cannot be cloned in the pure world: use toHandle")) => Clone (PyRef t) where
  clone = unsatisfiable

{- | An unrestricted, GC-managed strong reference: PyO3's @Py<T>@.
Released by a finaliser that pushes the pointer onto the deferred release pool,
which attached threads drain.
-}
newtype PyHandle (t :: Type) = PyHandle (ForeignPtr PyObject)

type role PyHandle nominal

-- ** Tags

-- | Any object.
data PyAny

-- | @int@.
data PyLong

-- | @float@.
data PyFloat

-- | @bool@.
data PyBool

-- | @str@.
data PyStr

-- | @bytes@.
data PyBytes

-- | @tuple@.
data PyTuple

-- | @list@.
data PyList

-- | @dict@.
data PyDict

-- | @set@.
data PySet

-- | @None@.
data PyNone

-- | @BaseException@.
data PyBaseException

-- | @type@.
data PyType

-- | A module object.
data PyModule

{-
Note [Sealed classes]
~~~~~~~~~~~~~~~~~~~~~
Several classes describe facts the type checker cannot verify: which Python
type object a tag stands for (PyTypeOf), that a payload type is closed and
its cell is its own (PyClass, PyFrozenClass), that one class really extends
another (PyExtends), which exception class a tag names (PyExceptionClass).
A hand-written instance of any of them is a retag the safe API would then
trust: `downcast` to a tag whose instance points at another type object,
`superMut` along an extension that does not exist, `newObject` into a cell
of another class.
So every such class carries a method returning 'Sealed', whose only
constructor lives here and is exported by the ".Unsafe" modules alone; the
splices produce it by its original name, a user cannot without importing a
trusted module, and, by Note [Forged capability instances] of pure-borrow, a
bodiless instance must fail before anything trusts it: every operation that
relies on the instance pattern-matches the witness first.
-}

-- | The witness of a trusted instance; see Note [Sealed classes].
data Sealed = UnsafeSealed

{- | Tags whose Python type object can be looked up, for 'downcast' and the
argument checks of the trampoline.
Instances for user classes are generated by @pyclass@; a hand-written one is
trusted code and needs the witness from "H2Py.Object.Unsafe".
-}
class PyTypeOf t where
  -- | The type object, attached.  A borrowed pointer that lives as long as the interpreter.
  pyTypeOf :: Proxy t -> IO (Ptr PyObject)

  -- | The name the stub renders for this tag.
  pyTypeName :: Proxy t -> Text

  -- | The witness that the instance is trusted; see Note [Sealed classes].
  pyTypeSealed :: Proxy t -> Sealed

-- | 'pyTypeOf' after forcing the instance's witness; what every trusting operation calls.
sealedTypeOf :: forall t. (PyTypeOf t) => Proxy t -> IO (Ptr PyObject)
sealedTypeOf p = case pyTypeSealed p of
  UnsafeSealed -> pyTypeOf p

-- | Raised when a class is used before the module that registers it was initialised.
newtype ClassNotRegistered = ClassNotRegistered Text
  deriving stock (Show)

instance Exception ClassNotRegistered where
  displayException (ClassNotRegistered name) = "H2Py: the class " <> T.unpack name <> " has not been registered by a module"

instance PyTypeOf PyAny where
  pyTypeOf _ = c_builtinType 0
  pyTypeName _ = "Any"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyLong where
  pyTypeOf _ = c_builtinType 1
  pyTypeName _ = "int"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyFloat where
  pyTypeOf _ = c_builtinType 2
  pyTypeName _ = "float"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyBool where
  pyTypeOf _ = c_builtinType 3
  pyTypeName _ = "bool"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyStr where
  pyTypeOf _ = c_builtinType 4
  pyTypeName _ = "str"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyBytes where
  pyTypeOf _ = c_builtinType 5
  pyTypeName _ = "bytes"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyTuple where
  pyTypeOf _ = c_builtinType 6
  pyTypeName _ = "tuple"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyList where
  pyTypeOf _ = c_builtinType 7
  pyTypeName _ = "list"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyDict where
  pyTypeOf _ = c_builtinType 8
  pyTypeName _ = "dict"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyBaseException where
  pyTypeOf _ = c_builtinType 9
  pyTypeName _ = "BaseException"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PySet where
  pyTypeOf _ = c_builtinType 10
  pyTypeName _ = "set"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyType where
  pyTypeOf _ = c_builtinType 13
  pyTypeName _ = "type"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyModule where
  pyTypeOf _ = c_builtinType 14
  pyTypeName _ = "types.ModuleType"
  pyTypeSealed _ = UnsafeSealed

instance PyTypeOf PyNone where
  pyTypeOf _ = do
    noneObj <- c_none
    t <- c_objectType noneObj
    c_decref t -- the type of None is immortal
    pure t
  pyTypeName _ = "None"
  pyTypeSealed _ = UnsafeSealed

-- ** The subtype relation between tags

{- | The CPython hierarchy of the built-in tags, as seen from Haskell:
@bool@ under @int@, every tag under 'PyAny', the exception tags under
'PyBaseException'.
'upcastRef' is free; 'downcast' is a runtime type check.
-}
class t :<: u

instance t :<: PyAny

instance PyBool :<: PyLong

instance PyBaseException :<: PyBaseException

-- | Widen a view along the tag hierarchy: free.
upcastRef :: forall u t π. (t :<: u) => Borrowed π t -> Borrowed π u
{-# INLINE upcastRef #-}
upcastRef = unsafeRetagShare

-- | Widen a handle along the tag hierarchy: free.
upcastMut :: forall u t π. (t :<: u) => Bound π t %1 -> Bound π u
{-# INLINE upcastMut #-}
upcastMut = unsafeRetagMut

-- | Every view is a view of some object.
asAny :: Borrowed π t -> Borrowed π PyAny
{-# INLINE asAny #-}
asAny = unsafeRetagShare

-- | Every handle is a handle to some object.
asAnyMut :: Bound π t %1 -> Bound π PyAny
{-# INLINE asAnyMut #-}
asAnyMut = unsafeRetagMut

-- * Trusted access to the pointer

{- | The pointer behind a view.
Trusted: the pointer is valid for @π@ and the caller is attached.
-}
refPtr :: Borrowed π t -> Ptr PyObject
{-# INLINE refPtr #-}
refPtr (UnsafeAlias (PyRef p)) = p

{- | The pointer behind a handle, without consuming the handle.
Trusted: as 'refPtr'; the handle is handed back to the caller unchanged.
-}
mutPtr :: Bound π t %1 -> (Ptr PyObject, Bound π t)
{-# INLINE mutPtr #-}
mutPtr = Unsafe.toLinear \b@(UnsafeAlias (PyRef p)) -> (p, b)

{- | Retag a view.
Trusted: the object must really be of the new tag, or the tag must be a
supertype of the old one.
-}
unsafeRetagShare :: Borrowed π t -> Borrowed π u
{-# INLINE unsafeRetagShare #-}
unsafeRetagShare (UnsafeAlias (PyRef p)) = UnsafeAlias (PyRef p)

-- | Retag a handle; see 'unsafeRetagShare'.
unsafeRetagMut :: Bound π t %1 -> Bound π u
{-# INLINE unsafeRetagMut #-}
unsafeRetagMut = Unsafe.toLinear \(UnsafeAlias (PyRef p)) -> UnsafeAlias (PyRef p)

{- | Wrap a pointer that the current arena, or the caller's frame, keeps alive
for @π@, without touching its reference count.
Trusted: exactly that.
-}
unsafeBoundFromPtr :: Ptr PyObject -> Bound π t
{-# INLINE unsafeBoundFromPtr #-}
unsafeBoundFromPtr p = UnsafeAlias (PyRef p)

-- | The view form of 'unsafeBoundFromPtr'.
unsafeBorrowedFromPtr :: Ptr PyObject -> Borrowed π t
{-# INLINE unsafeBorrowedFromPtr #-}
unsafeBorrowedFromPtr p = UnsafeAlias (PyRef p)

-- * Errors as values

{- | A Python exception as an unrestricted value: a materialised exception
object held through a 'PyHandle', or a lazy class-and-message pair that costs
nothing on the path that does not raise it.
-}
data PyErr
  = -- | The exception class, kept alive by the interpreter or by the module, and the message.
    PyErrLazy !(Ptr PyObject) !Text
  | -- | A materialised exception object.
    PyErrObject !(PyHandle PyBaseException)

instance Show PyErr where
  showsPrec d (PyErrLazy _ msg) = showParen (d > 10) (showString "PyErrLazy " . showsPrec 11 msg)
  showsPrec d (PyErrObject _) = showParen (d > 10) (showString "PyErrObject <exception>")

-- | The result of every fallible Python operation.
type PyResult a = Either PyErr a

instance Consumable (PyHandle t) where
  consume = Unsafe.toLinear \_ -> ()

-- | A handle may be duplicated freely: the finaliser runs once, when the last copy dies.
instance Dupable (PyHandle t) where
  dup2 = Unsafe.toLinear \h -> (h, h)

instance Movable (PyHandle t) where
  move = Unsafe.toLinear Ur

{- | A handle is unrestricted, so the copy out of a borrow is the handle
itself: a payload holding a 'PyHandle', or a 'Maybe' of one, can be read with
@copyRef@.
-}
instance Copyable (PyHandle t) where
  copy = Unsafe.toLinear \(UnsafeAlias h) -> case h of
    PyHandle fp -> PyHandle fp

instance Consumable PyErr where
  consume = Unsafe.toLinear \_ -> ()

instance Dupable PyErr where
  dup2 = Unsafe.toLinear \e -> (e, e)

instance Movable PyErr where
  move = Unsafe.toLinear Ur

-- | The exception classes the shim knows by index; see @h2py_exception_type@.
data BuiltinException
  = ExcBaseException
  | ExcException
  | ExcTypeError
  | ExcValueError
  | ExcRuntimeError
  | ExcOverflowError
  | ExcKeyError
  | ExcIndexError
  | ExcAttributeError
  | ExcStopIteration
  | ExcNotImplementedError
  | ExcZeroDivisionError
  | ExcArithmeticError
  | ExcMemoryError
  | ExcOSError
  | ExcKeyboardInterrupt
  | ExcBufferError
  | ExcLookupError
  | ExcUnicodeDecodeError
  | ExcImportError
  | ExcAssertionError
  | ExcSystemError
  | ExcIOError
  | ExcFloatingPointError
  | ExcRecursionError
  | ExcStopAsyncIteration
  | ExcEOFError
  | ExcNameError
  | ExcUnicodeEncodeError
  | ExcUnicodeError
  | ExcPermissionError
  | ExcFileNotFoundError
  | ExcTimeoutError
  deriving stock (Show, Eq, Ord, Enum, Bounded)

{- | The type object of a built-in exception class.
Needs no attachment: the address of a static type object of the interpreter,
read through a pure foreign import of a function that touches no state.
-}
builtinExceptionType :: BuiltinException -> Ptr PyObject
builtinExceptionType e = c_exceptionTypeStatic (fromIntegral (fromEnum e))

foreign import ccall unsafe "h2py_exception_type" c_exceptionTypeStatic :: CInt -> Ptr PyObject

-- | A lazy error with a built-in class.
builtinErr :: BuiltinException -> Text -> PyErr
builtinErr e = PyErrLazy (c_exceptionTypeStatic (fromIntegral (fromEnum e)))

-- | @TypeError@.
typeError :: Text -> PyErr
typeError = builtinErr ExcTypeError

-- | @RuntimeError@.
runtimeError :: Text -> PyErr
runtimeError = builtinErr ExcRuntimeError

-- | @ValueError@.
valueError :: Text -> PyErr
valueError = builtinErr ExcValueError

-- | @OverflowError@.
overflowError :: Text -> PyErr
overflowError = builtinErr ExcOverflowError

-- | @BufferError@.
bufferError :: Text -> PyErr
bufferError = builtinErr ExcBufferError

-- | @SystemError@.
systemError :: Text -> PyErr
systemError = builtinErr ExcSystemError

{- | Fetch the raised exception into a 'PyErr'.
Attached.  If nothing is raised, which is a bug in the operation that reported
failure, a @SystemError@ is answered instead.
-}
takeError :: IO PyErr
takeError = do
  p <- c_takeError
  if p == nullPtr
    then pure (systemError "H2Py: an operation failed without setting an exception")
    else PyErrObject <$> handleFromNew p

{- | Set a 'PyErr' as the raised exception.  Attached.
A materialised error is set with @PyErr_SetRaisedException@ after an incref; a
lazy one with @PyErr_SetString@.
-}
raiseErr :: PyErr -> IO ()
raiseErr (PyErrLazy cls msg) = TF.withCString msg (c_setError cls)
raiseErr (PyErrObject (PyHandle fp)) = withForeignPtr fp \p -> do
  c_incref p
  c_setRaisedException p

-- * Handles

{- | Wrap a fresh +1 into a GC-managed handle.
Trusted: the pointer carries a reference the handle now owns.
-}
handleFromNew :: Ptr PyObject -> IO (PyHandle t)
handleFromNew p = PyHandle <$> Concurrent.newForeignPtr p (c_poolPush p)

-- | Wrap a borrowed pointer into a handle, taking a +1 for it.  Attached.
handleFromBorrowed :: Ptr PyObject -> IO (PyHandle t)
handleFromBorrowed p = do
  c_incref p
  handleFromNew p

-- | Incref a view into a GC-managed handle.
toHandle :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (Ur (PyHandle t))
toHandle ref = unsafePyIO (Ur <$> handleFromBorrowed (refPtr ref))

-- | Incref a handle into the current arena.
fromHandle :: forall t π γ. PyHandle t -> Py π γ (Bound π t)
fromHandle (PyHandle fp) = unsafePyArena \arena -> withForeignPtr fp \p -> do
  c_incref p
  c_arenaRegister arena p
  pure (unsafeBoundFromPtr p)

-- | The view form of 'fromHandle'.
fromHandleShare :: forall t π γ. PyHandle t -> Py π γ (Ur (Borrowed π t))
fromHandleShare h = Control.fmap share (fromHandle h)

-- * Registering fresh references

{- | Register a pointer that a CPython call returned as a new reference, or
answer the raised exception if it is @NULL@.
-}
newResult :: Ptr Arena -> Ptr PyObject -> IO (PyResult (Bound π t))
newResult arena p
  | p == nullPtr = Left <$> takeError
  | otherwise = do
      c_arenaRegister arena p
      pure (Right (unsafeBoundFromPtr p))

-- | The status form of 'newResult': @-1@ is failure.
statusResult :: CInt -> IO (PyResult ())
statusResult rc
  | rc < 0 = Left <$> takeError
  | otherwise = pure (Right ())

-- | Run a new-reference operation on the current arena.
newRefOp :: forall t π γ. (Ptr Arena -> IO (Ptr PyObject)) -> Py π γ (PyResult (Bound π t))
{-# INLINE newRefOp #-}
newRefOp k = unsafePyArena \arena -> k arena >>= newResult arena

-- | Run a status operation.
statusOp :: forall π γ. IO CInt -> Py π γ (PyResult ())
{-# INLINE statusOp #-}
statusOp io = unsafePyIO (io >>= statusResult)

-- * Text and bytes marshalling

-- | Read a @str@ as 'Text'.  Attached; the object must be a @str@.
peekPyText :: Ptr PyObject -> IO (PyResult Text)
peekPyText p = alloca \lenPtr -> do
  s <- c_unicodeAsUTF8AndSize p lenPtr
  if s == nullPtr
    then Left <$> takeError
    else do
      n <- peek lenPtr
      Right <$> TF.peekCStringLen (s, fromIntegral n)

-- | Build a @str@ from 'Text' as a new reference.
newPyText :: Text -> IO (Ptr PyObject)
newPyText t = TF.withCStringLen t \(s, n) -> c_unicodeFromStringAndSize s (fromIntegral n)

-- | Read @bytes@ as a 'ByteString' copy.
peekPyBytes :: Ptr PyObject -> IO (PyResult ByteString)
peekPyBytes p = alloca \bufPtr -> alloca \lenPtr -> do
  rc <- c_bytesAsStringAndSize p bufPtr lenPtr
  if rc < 0
    then Left <$> takeError
    else do
      buf <- peek bufPtr
      n <- peek lenPtr
      Right <$> BS.packCStringLen (buf, fromIntegral n)

-- | Build @bytes@ from a 'ByteString' as a new reference.
newPyBytes :: ByteString -> IO (Ptr PyObject)
newPyBytes bs = BSU.unsafeUseAsCStringLen bs \(s, n) -> c_bytesFromStringAndSize s (fromIntegral n)

-- * Reading operations, on views

-- | @getattr(o, name)@.
getAttr :: forall t π π' γ. (π >= γ) => Borrowed π t -> Text -> Py π' γ (PyResult (Bound π' PyAny))
getAttr ref name = newRefOp \_ -> TF.withCString name (c_getAttrString (refPtr ref))

-- | @hasattr(o, name)@; never fails.
hasAttr :: forall t π π' γ. (π >= γ) => Borrowed π t -> Text -> Py π' γ (Ur Bool)
hasAttr ref name = unsafePyIO (Ur . (/= 0) <$> TF.withCString name (c_hasAttrString (refPtr ref)))

-- | @o[key]@.
getItem :: forall t k π π'' π' γ. (π >= γ, π'' >= γ) => Borrowed π t -> Borrowed π'' k -> Py π' γ (PyResult (Bound π' PyAny))
getItem ref key = newRefOp \_ -> c_getItem (refPtr ref) (refPtr key)

-- | @o[i]@ for an integer index, through the sequence protocol.
getIndex :: forall t π π' γ. (π >= γ) => Borrowed π t -> Int -> Py π' γ (PyResult (Bound π' PyAny))
getIndex ref i = newRefOp \_ -> c_sequenceGetItem (refPtr ref) (fromIntegral i)

-- | @len(o)@.
len :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (PyResult Int)
len ref = unsafePyIO do
  n <- c_length (refPtr ref)
  if n < 0 then Left <$> takeError else pure (Right (fromIntegral n))

-- | @repr(o)@ as 'Text'.
repr :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (PyResult Text)
repr ref = unsafePyIO (strLike c_objectRepr (refPtr ref))

-- | @str(o)@ as 'Text'.
str :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (PyResult Text)
str ref = unsafePyIO (strLike c_objectStr (refPtr ref))

strLike :: (Ptr PyObject -> IO (Ptr PyObject)) -> Ptr PyObject -> IO (PyResult Text)
strLike f p = do
  s <- f p
  if s == nullPtr
    then Left <$> takeError
    else do
      r <- peekPyText s
      c_decref s
      pure r

-- | @bool(o)@.
isTrue :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (PyResult Bool)
isTrue ref = unsafePyIO do
  rc <- c_isTrue (refPtr ref)
  if rc < 0 then Left <$> takeError else pure (Right (rc /= 0))

-- | @hash(o)@.
hash :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (PyResult Int)
hash ref = unsafePyIO do
  h <- c_hash (refPtr ref)
  if h == -1
    then do
      occurred <- c_errOccurred
      if occurred /= 0 then Left <$> takeError else pure (Right (-1))
    else pure (Right (fromIntegral h))

-- | The comparison operators of @tp_richcompare@.
data CompareOp = Lt | Le | Eq | Ne | Gt | Ge
  deriving stock (Show, Eq, Ord, Enum, Bounded)

compareOpCode :: CompareOp -> CInt
compareOpCode = \case
  Lt -> 0
  Le -> 1
  Eq -> 2
  Ne -> 3
  Gt -> 4
  Ge -> 5

-- | @a op b@ as a Python boolean.
richCompareBool :: forall t u π π'' π' γ. (π >= γ, π'' >= γ) => Borrowed π t -> CompareOp -> Borrowed π'' u -> Py π' γ (PyResult Bool)
richCompareBool a op b = unsafePyIO do
  rc <- c_richCompareBool (refPtr a) (refPtr b) (compareOpCode op)
  if rc < 0 then Left <$> takeError else pure (Right (rc /= 0))

-- | @a == b@.
equals :: forall t u π π'' π' γ. (π >= γ, π'' >= γ) => Borrowed π t -> Borrowed π'' u -> Py π' γ (PyResult Bool)
equals a b = richCompareBool a Eq b

-- | Call an object with positional arguments.
call :: forall t π π'' π' γ. (π >= γ, π'' >= γ) => Borrowed π t -> [Borrowed π'' PyAny] -> Py π' γ (PyResult (Bound π' PyAny))
call f args = newRefOp \_ -> vectorcall (refPtr f) (fmap refPtr args)

-- | Call an object with no arguments: the common shape, with nothing left to infer.
call0 :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (PyResult (Bound π' PyAny))
call0 f = newRefOp \_ -> c_callNoArgs (refPtr f)

-- | Call a method by name with no arguments.
callMethod0 :: forall t π π' γ. (π >= γ) => Borrowed π t -> Text -> Py π' γ (PyResult (Bound π' PyAny))
callMethod0 o name = newRefOp \_ -> do
  m <- TF.withCString name (c_getAttrString (refPtr o))
  if m == nullPtr
    then pure nullPtr
    else do
      r <- c_callNoArgs m
      c_decref m
      pure r

-- | Call a method by name with positional arguments.
callMethod :: forall t π π'' π' γ. (π >= γ, π'' >= γ) => Borrowed π t -> Text -> [Borrowed π'' PyAny] -> Py π' γ (PyResult (Bound π' PyAny))
callMethod o name args = newRefOp \_ -> do
  m <- TF.withCString name (c_getAttrString (refPtr o))
  if m == nullPtr
    then pure nullPtr
    else do
      r <- vectorcall m (fmap refPtr args)
      c_decref m
      pure r

vectorcall :: Ptr PyObject -> [Ptr PyObject] -> IO (Ptr PyObject)
vectorcall f args = allocaArray (max 1 (length args)) \arr -> do
  pokeArray arr args
  c_vectorcall f arr (fromIntegral (length args)) nullPtr

-- | @iter(o)@.
iterate :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (PyResult (Bound π' PyAny))
iterate ref = newRefOp \_ -> c_getIter (refPtr ref)

-- | @next(it)@: 'Nothing' when exhausted.
next :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (PyResult (Maybe (Bound π' PyAny)))
next it = unsafePyArena \arena -> do
  p <- c_iterNext (refPtr it)
  if p == nullPtr
    then do
      occurred <- c_errOccurred
      if occurred /= 0 then Left <$> takeError else pure (Right Nothing)
    else do
      c_arenaRegister arena p
      pure (Right (Just (unsafeBoundFromPtr p)))

-- | @isinstance(o, T)@ for the tag @t@; 'Nothing' if the check fails.
downcast :: forall t u π π' γ. (PyTypeOf t, π >= γ) => Borrowed π u -> Py π' γ (Ur (Maybe (Borrowed π t)))
downcast ref = unsafePyIO do
  ty <- sealedTypeOf (Proxy @t)
  rc <- c_isInstance (refPtr ref) ty
  pure (Ur (if rc > 0 then Just (unsafeRetagShare ref) else Nothing))

-- | 'downcast' for a handle: the handle comes back untouched on the 'Left'.
downcastMut :: forall t u π π' γ. (PyTypeOf t, π >= γ) => Bound π u %1 -> Py π' γ (Either (Bound π u) (Bound π t))
downcastMut = Unsafe.toLinear \b -> case mutPtr b of
  (p, b') -> unsafePyIO do
    ty <- sealedTypeOf (Proxy @t)
    rc <- c_isInstance p ty
    pure (if rc > 0 then Right (unsafeRetagMut b') else Left b')

-- | @type(o)@.
typeOf :: forall t π π' γ. (π >= γ) => Borrowed π t -> Py π' γ (Bound π' PyType)
typeOf ref = unsafePyArena \arena -> do
  p <- c_objectType (refPtr ref)
  c_arenaRegister arena p
  pure (unsafeBoundFromPtr p)

-- * Mutating operations, on handles

{- | Run a status operation on the object behind a handle, and hand the handle
back beside the result so that it survives a failure.
-}
withHandle :: forall t π π' γ. Bound π t %1 -> (Ptr PyObject -> IO CInt) -> Py π' γ (PyResult (), Bound π t)
{-# INLINE withHandle #-}
withHandle = Unsafe.toLinear \b k -> case mutPtr b of
  (p, b') -> unsafePyIO do
    r <- k p >>= statusResult
    pure (r, b')

-- | @setattr(o, name, v)@; the handle survives a failure.
setAttr :: forall t u π π'' π' γ. (π >= γ, π'' >= γ) => Bound π t %1 -> Text -> Borrowed π'' u -> Py π' γ (PyResult (), Bound π t)
setAttr b name v = withHandle b \p -> TF.withCString name \cname -> c_setAttrString p cname (refPtr v)

-- | @o[key] = v@.
setItem :: forall t k u π πk πv π' γ. (π >= γ, πk >= γ, πv >= γ) => Bound π t %1 -> Borrowed πk k -> Borrowed πv u -> Py π' γ (PyResult (), Bound π t)
setItem b key v = withHandle b \p -> c_setItem p (refPtr key) (refPtr v)

-- | @del o[key]@.
delItem :: forall t k π πk π' γ. (π >= γ, πk >= γ) => Bound π t %1 -> Borrowed πk k -> Py π' γ (PyResult (), Bound π t)
delItem b key = withHandle b \p -> c_delItem p (refPtr key)

-- | @delattr(o, name)@.
delAttr :: forall t π π' γ. (π >= γ) => Bound π t %1 -> Text -> Py π' γ (PyResult (), Bound π t)
delAttr b name = withHandle b \p -> TF.withCString name \cname -> c_setAttrString p cname nullPtr

-- | @list.append(v)@.
listAppend :: forall u π πv π' γ. (π >= γ, πv >= γ) => Bound π PyList %1 -> Borrowed πv u -> Py π' γ (PyResult (), Bound π PyList)
listAppend b v = withHandle b \p -> c_listAppend p (refPtr v)

-- | @set.add(v)@.
setAdd :: forall u π πv π' γ. (π >= γ, πv >= γ) => Bound π PySet %1 -> Borrowed πv u -> Py π' γ (PyResult (), Bound π PySet)
setAdd b v = withHandle b \p -> c_setAdd p (refPtr v)

-- * Constructors

-- | A new @str@.
toStr :: forall π γ. Text -> Py π γ (PyResult (Bound π PyStr))
toStr t = newRefOp \_ -> newPyText t

-- | A new @bytes@.
toBytes :: forall π γ. ByteString -> Py π γ (PyResult (Bound π PyBytes))
toBytes bs = newRefOp \_ -> newPyBytes bs

-- | A new @int@ from a machine integer.
toInt :: forall π γ. Int -> Py π γ (PyResult (Bound π PyLong))
toInt n = newRefOp \_ -> c_longFromLongLong (fromIntegral n)

-- | A new @int@ from an 'Integer' of any size.
toInteger' :: forall π γ. Integer -> Py π γ (PyResult (Bound π PyLong))
toInteger' n
  | n >= fromIntegral (minBound :: Int) && n <= fromIntegral (maxBound :: Int) = newRefOp \_ -> c_longFromLongLong (fromIntegral n)
  | otherwise = newRefOp \_ -> withCString (show n) \s -> c_longFromString s nullPtr 10

-- | A new @float@.
toFloat :: forall π γ. Double -> Py π γ (PyResult (Bound π PyFloat))
toFloat d = newRefOp \_ -> c_floatFromDouble (realToFrac d)

-- | A new @bool@.
toBool :: forall π γ. Bool -> Py π γ (PyResult (Bound π PyBool))
toBool b = newRefOp \_ -> c_boolFromLong (if b then 1 else 0)

-- | @None@, registered in the arena like any other reference.
none :: forall π γ. Py π γ (Bound π PyNone)
none = unsafePyArena \arena -> do
  p <- c_none
  c_incref p
  c_arenaRegister arena p
  pure (unsafeBoundFromPtr p)

-- | A new @list@ of views.
toList :: forall π π'' γ. (π'' >= γ) => [Borrowed π'' PyAny] -> Py π γ (PyResult (Bound π PyList))
toList items = newRefOp \_ -> do
  l <- c_listNew (fromIntegral (length items))
  if l == nullPtr
    then pure nullPtr
    else do
      NonLinear.forM_ (zip [0 ..] items) \(i, item) -> do
        let p = refPtr item
        c_incref p
        _ <- c_listSetItem l i p
        pure ()
      pure l

-- | A new @tuple@ of views.
toTuple :: forall π π'' γ. (π'' >= γ) => [Borrowed π'' PyAny] -> Py π γ (PyResult (Bound π PyTuple))
toTuple items = newRefOp \_ -> do
  t <- c_tupleNew (fromIntegral (length items))
  if t == nullPtr
    then pure nullPtr
    else do
      NonLinear.forM_ (zip [0 ..] items) \(i, item) -> do
        let p = refPtr item
        c_incref p
        _ <- c_tupleSetItem t i p
        pure ()
      pure t

-- | The empty tuple.
emptyTuple :: forall π γ. Py π γ (PyResult (Bound π PyTuple))
emptyTuple = newRefOp \_ -> c_tupleNew 0

-- | A new @dict@ of views.
toDict :: forall π πk πv γ. (πk >= γ, πv >= γ) => [(Borrowed πk PyAny, Borrowed πv PyAny)] -> Py π γ (PyResult (Bound π PyDict))
toDict items = newRefOp \_ -> do
  d <- c_dictNew
  if d == nullPtr
    then pure nullPtr
    else do
      ok <- NonLinear.foldM (\ok (k, v) -> if not ok then pure False else (>= 0) <$> c_dictSetItem d (refPtr k) (refPtr v)) True items
      if ok then pure d else c_decref d >> pure nullPtr

-- | An empty new @dict@.
newDict :: forall π γ. Py π γ (PyResult (Bound π PyDict))
newDict = newRefOp \_ -> c_dictNew

-- | An empty new @list@.
newList :: forall π γ. Py π γ (PyResult (Bound π PyList))
newList = newRefOp \_ -> c_listNew 0

-- | A new @set@ of views.
toSet :: forall π π'' γ. (π'' >= γ) => [Borrowed π'' PyAny] -> Py π γ (PyResult (Bound π PySet))
toSet items = newRefOp \_ -> do
  s <- c_setNew nullPtr
  if s == nullPtr
    then pure nullPtr
    else do
      ok <- NonLinear.foldM (\ok v -> if not ok then pure False else (>= 0) <$> c_setAdd s (refPtr v)) True items
      if ok then pure s else c_decref s >> pure nullPtr

-- * Copying values out

{- | The Haskell type a value tag copies out to: 'PyLong' to 'Integer',
'PyFloat' to 'Double', 'PyBool' to 'Bool', 'PyStr' to 'Text', 'PyBytes' to
'ByteString', 'PyNone' to @()@.
-}
type family HsOf (t :: Type) :: Type where
  HsOf PyLong = Integer
  HsOf PyFloat = Double
  HsOf PyBool = Bool
  HsOf PyStr = Text
  HsOf PyBytes = ByteString
  HsOf PyNone = ()

{- | Value tags: reading the Haskell value cannot fail once the tag is known.
Trusted per instance: the pointer really is of the tag.
-}
class PyValue t where
  readValue :: Ptr PyObject -> IO (HsOf t)

instance PyValue PyLong where
  readValue = readInteger

instance PyValue PyFloat where
  readValue p = realToFrac <$> c_floatAsDouble p

instance PyValue PyBool where
  readValue p = (/= 0) <$> c_isTrue p

instance PyValue PyStr where
  readValue p = peekPyText p >>= either (const (pure T.empty)) pure

instance PyValue PyBytes where
  readValue p = peekPyBytes p >>= either (const (pure BS.empty)) pure

instance PyValue PyNone where
  readValue _ = pure ()

-- | Read any @int@ into an 'Integer', through the machine path when it fits.
readInteger :: Ptr PyObject -> IO Integer
readInteger p = do
  n <- c_longAsLongLong p
  occurred <- c_errOccurred
  if occurred == 0
    then pure (fromIntegral n)
    else do
      _ <- c_takeError >>= \e -> NonLinear.unless (e == nullPtr) (c_decref e)
      s <- c_numberToBase p 16
      if s == nullPtr
        then c_takeError >>= \e -> NonLinear.unless (e == nullPtr) (c_decref e) >> pure 0
        else do
          r <- peekPyText s
          c_decref s
          pure (either (const 0) parseHex r)

parseHex :: Text -> Integer
parseHex t = case T.unpack t of
  '-' : rest -> negate (parseHex (T.pack rest))
  '0' : 'x' : digits -> foldl (\acc c -> acc * 16 + fromIntegral (hexDigit c)) 0 digits
  digits -> foldl (\acc c -> acc * 16 + fromIntegral (hexDigit c)) 0 digits
  where
    hexDigit :: Char -> Int
    hexDigit c
      | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
      | c >= 'a' && c <= 'f' = fromEnum c - fromEnum 'a' + 10
      | c >= 'A' && c <= 'F' = fromEnum c - fromEnum 'A' + 10
      | otherwise = 0

{- | Copy a value out of a reference whose tag fixes its Haskell type; cannot
fail.  The analogue of 'copyMut': the value is materialised eagerly, while the
reference is valid and the thread attached, and returned in 'Ur'.
-}
copyOut :: forall t π π' γ. (PyValue t, π >= γ) => Borrowed π t -> Py π' γ (Ur (HsOf t))
copyOut ref = unsafePyIO (Ur <$> readValue @t (refPtr ref))

-- * Signals

{- | @PyErr_CheckSignals@: runs Python signal handlers, on the main thread only,
and reports a pending @KeyboardInterrupt@ as a 'Left'.
-}
checkSignals :: forall π γ. Py π γ (PyResult ())
checkSignals = statusOp c_checkSignals
