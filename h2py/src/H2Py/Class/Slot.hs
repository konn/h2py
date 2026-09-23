{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

{- |
Python protocols on a Haskell class, as type slots whose Haskell signatures
the 'Slot' GADT fixes.
See section 5.12 of the design.

Slots are registered next to methods:
@pymethods ''Counter [method "incr" 'incr, slot 'Repr 'showCounter]@.
Each receiver follows the method rule: a 'Receiver'-form slot runs on
@derefShare@ of the handle, or on the value for a frozen class, and a 'Mut'
receiver on @derefMut@.
A slot body, like a method body, may return its result @r@ plain or as
@PyResult r@: a constructor whose result does not mention the call's scope
('Compare', 'GetItem', 'SetItem', 'DelItem', 'Next', 'Exit', 'InplaceOp')
accepts either form through 'SlotResult', and a constructor whose result is
a reference at the call's scope ('Iter', 'NextObject', 'Enter', 'BinaryOp',
'UnaryOp') takes the @PyResult@ form, which is the more general of the two;
see the note on 'SlotResult'.
A binary slot receives its operand as @'Borrowed' π 'PyAny'@; an operand of
the same class is 'H2Py.Object.downcast' and then dereferenced, which succeeds
when the operand /is/ the receiver of a shared slot, since a shared hold is
reused within the scope, and answers @busy@ under a 'Mut' receiver.
-}
module H2Py.Class.Slot (
  Slot (..),
  SlotResult (..),
  CompareOp (..),
  NumberOps (..),
  noNumberOps,
  BinaryOp (..),
  UnaryOp (..),
  InplaceOp (..),
  enterSelf,
  slotEntries,

  -- * Buffer formats
  -- $buffer
  SVector,
  BufferFormat (..),
) where

import Control.Exception (SomeException, try)
import Control.Functor.Linear qualified as Control
import Control.Monad qualified as NonLinear
import Control.Monad.Borrow.BO (Borrow, Mut, Share, share)
import Control.Monad.Borrow.Lifetime.Internal (Lifetime (..))
import Control.Monad.Borrow.Unsafe (Alias (..))
import Data.Int (Int32, Int64)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector.Generic.Mutable.Linear.Borrow.Unrestricted.Internal qualified as UV
import Data.Vector.Storable qualified as SV
import Data.Vector.Storable.Mutable qualified as SVM
import Data.Word (Word8)
import Foreign.C.String (CString, newCString)
import Foreign.C.Types (CInt (..))
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Ptr (FunPtr, Ptr, castFunPtrToPtr, castPtr, nullPtr)
import Foreign.Storable (Storable, sizeOf)
import H2Py.Buffer.Internal (BufferFormat (..), SVector)
import H2Py.Class.Internal
import H2Py.Convert.Internal
import H2Py.Exception.Internal (someExceptionToPyErr)
import H2Py.Module.Internal
import H2Py.Object.Internal
import H2Py.Py.Internal
import H2Py.Runtime.Internal
import Prelude.Linear (Consumable (..), Ur (..), lseq)
import Unsafe.Linear qualified as Unsafe

{- | The result of a slot body, plain or wrapped in 'PyResult': @r@ is what
the body returns and @a@ what the slot needs, so that a body may answer
@Py π π Bool@ or @Py π π (PyResult Bool)@ to the same constructor.
A 'PyResult' is always read as the wrapped form; every other type is the
plain form.

This works only for a result that does not mention the call's scope @π@,
since @r@ is chosen once for the whole scope-polymorphic body: a result such
as @'Bound' π it@ would have to be a type-level function of @π@, which GHC
cannot infer from a body's type, so the constructors whose result is a
reference at the call's scope take the @PyResult@ form alone.
-}
class SlotResult r a | r -> a where
  -- | The body's result as the slot's.
  slotResult :: r %1 -> PyResult a

instance {-# OVERLAPPING #-} SlotResult (Either PyErr a) a where
  slotResult r = r

instance {-# OVERLAPPABLE #-} (a ~ a') => SlotResult a a' where
  slotResult = Right

-- | A protocol slot of the class @a@; every receiver at the call's lifetime, as methods are.
data Slot a where
  -- | @__repr__@.
  Repr :: (PyReceiver a k) => (forall π. Receiver k a π -> Py π π Text) -> Slot a
  -- | @__str__@.
  Str :: (PyReceiver a k) => (forall π. Receiver k a π -> Py π π Text) -> Slot a
  -- | @__hash__@.
  Hash :: (PyReceiver a k) => (forall π. Receiver k a π -> Py π π Int) -> Slot a
  -- | @__eq__@ and the other five, answering @Maybe Bool@ plain or in a 'PyResult'; 'Nothing' is @NotImplemented@.  Without a 'Hash' slot, @__hash__@ is @None@.
  Compare :: (PyReceiver a k, SlotResult r (Maybe Bool)) => (forall π. Receiver k a π -> Borrowed π PyAny -> CompareOp -> Py π π r) -> Slot a
  -- | @__bool__@.
  Bool :: (PyReceiver a k) => (forall π. Receiver k a π -> Py π π Bool) -> Slot a
  -- | @__len__@.
  Len :: (PyReceiver a k) => (forall π. Receiver k a π -> Py π π Int) -> Slot a
  -- | @__contains__@.
  Contains :: (PyReceiver a rk, FromPy k) => (forall π. Receiver rk a π -> k -> Py π π Bool) -> Slot a
  -- | @__getitem__@, answering the value plain or in a 'PyResult'.
  GetItem :: (PyReceiver a rk, FromPy k, ToPy v, SlotResult r v) => (forall π. Receiver rk a π -> k -> Py π π r) -> Slot a
  -- | @__setitem__@, answering @()@ plain or in a 'PyResult'.
  SetItem :: (PyClass a, FromPy k, FromPy v, SlotResult r ()) => (forall π. Mut π a %1 -> k -> v -> Py π π r) -> Slot a
  -- | @__delitem__@, answering @()@ plain or in a 'PyResult'.
  DelItem :: (PyClass a, FromPy k, SlotResult r ()) => (forall π. Mut π a %1 -> k -> Py π π r) -> Slot a
  -- | @__iter__@: the iterator, a class instance such as 'H2Py.Class.Iterator.HsIterator'.  Defaults to @self@ when 'Next' is registered.
  Iter :: (PyReceiver a k, PyTypeOf it) => (forall π. Receiver k a π -> Py π π (PyResult (Bound π it))) -> Slot a
  -- | @__next__@ yielding a value, plain or in a 'PyResult': 'Nothing' raises @StopIteration@.
  Next :: (PyClass a, ToPy v, SlotResult r (Maybe v)) => (forall π. Mut π a %1 -> Py π π r) -> Slot a
  -- | @__next__@ yielding a Python object: 'Nothing' raises @StopIteration@.
  NextObject :: (PyClass a) => (forall π. Mut π a %1 -> Py π π (PyResult (Maybe (Bound π PyAny)))) -> Slot a
  -- | @__call__@: a method body in any receiver form, instantiated by @slot 'Call 'f@, which is the only way to build this constructor.
  Call :: FunctionOptions -> ([TypeHint], TypeHint) -> (forall π. Proxy π -> Bound π a %1 -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))) -> Slot a
  -- | @__enter__@, with an explicit receiver; 'enterSelf' is the default, and it is registered for you when only 'Exit' is given.
  Enter :: (forall π. Bound π a %1 -> Py π π (PyResult (Bound π a))) -> Slot a
  -- | @__exit__@: the exception being handled, if any; 'True', plain or in a 'PyResult', suppresses it.
  Exit :: (PyClass a, SlotResult r Bool) => (forall π. Mut π a %1 -> Maybe (Borrowed π PyBaseException) -> Py π π r) -> Slot a
  -- | The @__add__@ family; see 'NumberOps'.
  Number :: NumberOps a -> Slot a
  -- | The buffer protocol over the payload's own storage; see the section on buffer formats.
  Buffer :: (PyClass a, Storable e, BufferFormat e) => (forall bk α. Borrow bk α a %1 -> Borrow bk α (SVector e)) -> Slot a

-- | @__enter__@ that returns @self@.
enterSelf :: forall a π. Bound π a %1 -> Py π π (PyResult (Bound π a))
enterSelf self = Control.pure (Right self)

-- * Number protocol

{- | A binary operation: the operand is any object, and 'Nothing' yields
@NotImplemented@ so that Python tries the reflected form.
-}
data BinaryOp a where
  BinaryOp :: (PyReceiver a k) => (forall π. Receiver k a π -> Borrowed π PyAny -> Py π π (PyResult (Maybe (Bound π PyAny)))) -> BinaryOp a

-- | A unary operation.
data UnaryOp a where
  UnaryOp :: (PyReceiver a k) => (forall π. Receiver k a π -> Py π π (PyResult (Bound π PyAny))) -> UnaryOp a

{- | An in-place operation on a 'Mut' receiver, answering @Maybe ()@ plain or
in a 'PyResult': @Just ()@ answers @self@, 'Nothing' yields @NotImplemented@
so that Python falls back to the binary form.
-}
data InplaceOp a where
  InplaceOp :: (PyClass a, SlotResult r (Maybe ())) => (forall π. Mut π a %1 -> Borrowed π PyAny -> Py π π r) -> InplaceOp a

{- | The optional operations of the number protocol.
The binary slots receive @(self, other)@ where @self@ may be the /other/
operand for a reflected call, so each forward operation has a reflected
partner: @x + y@ tries @nbAdd@ when @x@ is an instance of the class, and
@nbRAdd@ when only @y@ is.
-}
data NumberOps a = NumberOps
  { nbAdd, nbRAdd :: Maybe (BinaryOp a)
  , nbSub, nbRSub :: Maybe (BinaryOp a)
  , nbMul, nbRMul :: Maybe (BinaryOp a)
  , nbTrueDiv, nbRTrueDiv :: Maybe (BinaryOp a)
  , nbFloorDiv, nbRFloorDiv :: Maybe (BinaryOp a)
  , nbMod, nbRMod :: Maybe (BinaryOp a)
  , nbPow, nbRPow :: Maybe (BinaryOp a)
  -- ^ The modulus of the ternary @pow@ is not supported: a non-@None@ modulus yields @NotImplemented@.
  , nbNeg, nbPos, nbAbs, nbInvert :: Maybe (UnaryOp a)
  , nbIAdd, nbISub, nbIMul :: Maybe (InplaceOp a)
  }

-- | No operations; set the fields you implement.
noNumberOps :: NumberOps a
noNumberOps = NumberOps Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- * Buffer formats

-- The formats and 'SVector' are those of "H2Py.Buffer.Internal".

-- * Registration

-- | Build the registration of a slot; every adjustor it creates is never freed.
slotEntries :: forall a. (PyTypeOf a) => Slot a -> IO SlotRegistration
slotEntries = \case
  Repr f -> unaryText slotTpRepr "__repr__" f
  Str f -> unaryText slotTpStr "__str__" f
  Hash f -> do
    ptr <- mkLenFunc \self -> runPyCallScalar (-1) \p -> withReceiver @a p self \s -> Control.do
      h <- f s
      Control.pure (Right (Unsafe.toLinear hashValue h))
    pure (slotOnly slotTpHash ptr [desc "__hash__" [] (TName "int")])
  Compare f -> do
    ptr <- mkRichCmpFunc \self other op -> runPyCall \p -> withReceiver @a p self \s -> Control.do
      r <- f s (borrowedAt p other) (decodeOp op)
      compareResult (slotResult r)
    pure (slotOnly slotTpRichCompare ptr [desc d [ParamDesc (Just "other") TAny] (TName "bool") | d <- ["__eq__", "__ne__", "__lt__", "__le__", "__gt__", "__ge__"]])
  Bool f -> do
    ptr <- mkInquiry1 \self -> runPyCallScalar (-1) \p -> withReceiver @a p self \s -> Control.do
      b <- f s
      Control.pure (Right (Unsafe.toLinear fromBool b))
    pure (slotOnly slotNbBool ptr [desc "__bool__" [] (TName "bool")])
  Len f -> do
    ptr <- mkLenFunc \self -> runPyCallScalar (-1) \p -> withReceiver @a p self \s -> Control.do
      n <- f s
      Control.pure (Right (Unsafe.toLinear fromIntegral n))
    pure (slotsOnly [SlotEntry slotSqLength (castFunPtrToPtr ptr), SlotEntry slotMpLength (castFunPtrToPtr ptr)] [desc "__len__" [] (TName "int")])
  Contains f -> containsEntry f
  GetItem f -> getItemEntry f
  SetItem (f :: forall π. Mut π a %1 -> k -> v -> Py π π r) -> do
    let proc self key value = runPyCallScalar (-1) \p -> withMut p self \m -> Control.do
          rk <- fromPy @k (borrowedAt p key)
          rv <- fromPy @v (borrowedAt p value)
          withValue2 m rk rv \m' k v -> Control.do
            r <- f m' k v
            Control.pure (Unsafe.toLinear (fmap (const 0)) (slotResult r))
    pure mempty {srSetItem = Just proc, srDescs = [desc "__setitem__" [ParamDesc (Just "key") (pyTypeHint (Proxy @k)), ParamDesc (Just "value") (pyTypeHint (Proxy @v))] TNone]}
  DelItem (f :: forall π. Mut π a %1 -> k -> Py π π r) -> do
    let proc self key _ = runPyCallScalar (-1) \p -> withMut p self \m -> Control.do
          rk <- fromPy @k (borrowedAt p key)
          withValue1 m rk \m' k -> Control.do
            r <- f m' k
            Control.pure (Unsafe.toLinear (fmap (const 0)) (slotResult r))
    pure mempty {srDelItem = Just proc, srDescs = [desc "__delitem__" [ParamDesc (Just "key") (pyTypeHint (Proxy @k))] TNone]}
  Iter f -> iterEntry f
  Next f -> nextEntry f
  NextObject f -> do
    ptr <- mkUnaryFunc \self -> runPyCall \p -> withMut p self \m -> Control.do
      r <- f m
      nextObjectResult r
    pure (slotOnly slotTpIterNext ptr [desc "__next__" [] TAny])
  Call opts hints body -> do
    let d = describe "__call__" True False hints opts
    entry <- makeCallSlot d \p self args -> body p (unsafeRetagMut self) args
    pure (slotsOnly [entry] [d])
  Enter f -> do
    let d = desc "__enter__" [] (TName (pyTypeName (Proxy @a)))
    fun <- makeMethod d \_ self args -> enterBody f (unsafeRetagMut self) args
    pure mempty {srMethods = [fun]}
  Exit f -> do
    let d = desc "__exit__" [ParamDesc (Just "exc_type") TAny, ParamDesc (Just "exc_value") TAny, ParamDesc (Just "traceback") TAny] (TName "bool")
    fun <- makeMethod d \p self args -> exitBody @a f p self args
    pure mempty {srMethods = [fun]}
  Number ops ->
    fmap mconcat $
      sequence
        [ binaryEntry slotNbAdd "__add__" "__radd__" (nbAdd ops) (nbRAdd ops)
        , binaryEntry slotNbSubtract "__sub__" "__rsub__" (nbSub ops) (nbRSub ops)
        , binaryEntry slotNbMultiply "__mul__" "__rmul__" (nbMul ops) (nbRMul ops)
        , binaryEntry slotNbTrueDivide "__truediv__" "__rtruediv__" (nbTrueDiv ops) (nbRTrueDiv ops)
        , binaryEntry slotNbFloorDivide "__floordiv__" "__rfloordiv__" (nbFloorDiv ops) (nbRFloorDiv ops)
        , binaryEntry slotNbRemainder "__mod__" "__rmod__" (nbMod ops) (nbRMod ops)
        , powerEntry (nbPow ops) (nbRPow ops)
        , unaryEntry slotNbNegative "__neg__" (nbNeg ops)
        , unaryEntry slotNbPositive "__pos__" (nbPos ops)
        , unaryEntry slotNbAbsolute "__abs__" (nbAbs ops)
        , unaryEntry slotNbInvert "__invert__" (nbInvert ops)
        , inplaceEntry slotNbInplaceAdd "__iadd__" (nbIAdd ops)
        , inplaceEntry slotNbInplaceSubtract "__isub__" (nbISub ops)
        , inplaceEntry slotNbInplaceMultiply "__imul__" (nbIMul ops)
        ]
  Buffer (proj :: forall bk α. Borrow bk α a %1 -> Borrow bk α (SVector e)) -> do
    fmt <- newCString (T.unpack (bufferExportFormat (Proxy @e)))
    getPtr <- mkGetBufferProc (bufferGetter @a @e proj fmt)
    releasePtr <- mkReleaseBufferProc (bufferReleaser @a)
    pure
      ( slotsOnly
          [SlotEntry slotBfGetBuffer (castFunPtrToPtr getPtr), SlotEntry slotBfReleaseBuffer (castFunPtrToPtr releasePtr)]
          [desc "__buffer__" [ParamDesc (Just "flags") (TName "int")] (TName "memoryview"), desc "__release_buffer__" [ParamDesc (Just "view") (TName "memoryview")] TNone]
      )
  where
    unaryText :: forall k. (PyReceiver a k) => CInt -> Text -> (forall π. Receiver k a π -> Py π π Text) -> IO SlotRegistration
    unaryText slotIdent name f = do
      ptr <- mkUnaryFunc \self -> runPyCall \p -> withReceiver @a p self \s -> Control.do
        t <- f s
        toResult t
      pure (slotOnly slotIdent ptr [desc name [] (TName "str")])
    containsEntry :: forall rk k. (PyReceiver a rk, FromPy k) => (forall π. Receiver rk a π -> k -> Py π π Bool) -> IO SlotRegistration
    containsEntry f = do
      ptr <- mkInquiry \self key -> runPyCallScalar (-1) \p -> withReceiver @a p self \s -> Control.do
        rk <- fromPy @k (borrowedAt p key)
        withValue rk \k -> Control.do
          b <- f s k
          Control.pure (Right (Unsafe.toLinear fromBool b))
      -- @__contains__@ may be asked about any object, so the stub says so, whatever the slot converts.
      pure (slotOnly slotSqContains ptr [desc "__contains__" [ParamDesc (Just "key") (TName "object")] (TName "bool")])
    getItemEntry :: forall rk k v r. (PyReceiver a rk, FromPy k, ToPy v, SlotResult r v) => (forall π. Receiver rk a π -> k -> Py π π r) -> IO SlotRegistration
    getItemEntry f = do
      ptr <- mkBinaryFunc \self key -> runPyCall \p -> withReceiver @a p self \s -> Control.do
        rk <- fromPy @k (borrowedAt p key)
        withValue rk \k -> Control.do
          rv <- f s k
          toPyResult (slotResult rv)
      pure (slotOnly slotMpSubscript ptr [desc "__getitem__" [ParamDesc (Just "key") (pyTypeHint (Proxy @k))] (pyTypeHint (Proxy @v))])
    nextEntry :: forall v r. (PyClass a, ToPy v, SlotResult r (Maybe v)) => (forall π. Mut π a %1 -> Py π π r) -> IO SlotRegistration
    nextEntry f = do
      ptr <- mkUnaryFunc \self -> runPyCall \p -> withMut p self \m -> Control.do
        r <- f m
        nextResult (slotResult r)
      pure (slotOnly slotTpIterNext ptr [desc "__next__" [] (pyTypeHint (Proxy @v))])
    iterEntry :: forall rk it. (PyReceiver a rk, PyTypeOf it) => (forall π. Receiver rk a π -> Py π π (PyResult (Bound π it))) -> IO SlotRegistration
    iterEntry f = do
      ptr <- mkUnaryFunc \self -> runPyCall \p -> withReceiver @a p self \s -> Control.fmap (mapResult asAnyMut) (f s)
      pure (slotOnly slotTpIter ptr [desc "__iter__" [] (TApply "Iterator" [TAny])])
    binaryEntry :: CInt -> Text -> Text -> Maybe (BinaryOp a) -> Maybe (BinaryOp a) -> IO SlotRegistration
    binaryEntry _ _ _ Nothing Nothing = pure mempty
    binaryEntry slotIdent name rname forward reflected = do
      ptr <- mkBinaryFunc \self other -> runPyCall \p -> dispatchBinary @a p forward reflected self other
      pure (slotOnly slotIdent ptr (binaryDescs name rname forward reflected))
    powerEntry :: Maybe (BinaryOp a) -> Maybe (BinaryOp a) -> IO SlotRegistration
    powerEntry Nothing Nothing = pure mempty
    powerEntry forward reflected = do
      ptr <- mkTernaryFunc \self other modulus -> runPyCall \p -> Control.do
        Ur plain <- unsafePyIO (Ur . (\n -> modulus == nullPtr || modulus == n) <$> c_none)
        if plain then dispatchBinary @a p forward reflected self other else notImplemented
      pure (slotOnly slotNbPower ptr (binaryDescs "__pow__" "__rpow__" forward reflected))
    unaryEntry :: CInt -> Text -> Maybe (UnaryOp a) -> IO SlotRegistration
    unaryEntry _ _ Nothing = pure mempty
    unaryEntry slotIdent name (Just (UnaryOp f)) = do
      ptr <- mkUnaryFunc \self -> runPyCall \p -> withReceiver @a p self \s -> f s
      pure (slotOnly slotIdent ptr [desc name [] TAny])
    inplaceEntry :: CInt -> Text -> Maybe (InplaceOp a) -> IO SlotRegistration
    inplaceEntry _ _ Nothing = pure mempty
    inplaceEntry slotIdent name (Just (InplaceOp f)) = do
      ptr <- mkBinaryFunc \self other -> runPyCall \p -> withMut p self \m -> Control.do
        r <- f m (borrowedAt p other)
        inplaceResult self (slotResult r)
      pure (slotOnly slotIdent ptr [desc name [ParamDesc (Just "other") TAny] (TName (pyTypeName (Proxy @a)))])
    binaryDescs name rname forward reflected =
      [desc name [ParamDesc (Just "other") TAny] TAny | Just _ <- [forward]]
        <> [desc rname [ParamDesc (Just "other") TAny] TAny | Just _ <- [reflected]]

desc :: Text -> [ParamDesc] -> TypeHint -> FunctionDesc
desc name params res = FunctionDesc name params res "" True False

slotOnly :: CInt -> FunPtr f -> [FunctionDesc] -> SlotRegistration
slotOnly ident ptr descs = slotsOnly [SlotEntry ident (castFunPtrToPtr ptr)] descs

fromBool :: Bool -> CInt
fromBool b = if b then 1 else 0

-- | CPython reserves @-1@ for failure.
hashValue :: Int -> PySSize
hashValue n = if n == -1 then -2 else fromIntegral n

-- | A lent pointer as a view at the call's attachment.
borrowedAt :: Proxy π -> Ptr PyObject -> Borrowed π PyAny
borrowedAt _ = unsafeBorrowedFromPtr

-- | Dereference the receiver mutably and continue.
withMut :: forall a π r. (PyClass a) => Proxy π -> Ptr PyObject -> (Mut π a %1 -> Py π π (PyResult r)) -> Py π π (PyResult r)
withMut _ self k = Control.do
  r <- derefMut (unsafeBoundFromPtr self :: Bound π a)
  continueMut r k

continueMut :: forall a π r. PyResult (Mut π a) %1 -> (Mut π a %1 -> Py π π (PyResult r)) -> Py π π (PyResult r)
continueMut (Left e) _ = Control.pure (Left e)
continueMut (Right m) k = k m

-- | Continue with a converted value, or answer its error.
withValue :: forall k π r. PyResult k %1 -> (k -> Py π π (PyResult r)) -> Py π π (PyResult r)
withValue = Unsafe.toLinear \r k -> case r of
  Left e -> Control.pure (Left e)
  Right v -> k v

withValue1 :: forall k m π r. (Consumable m) => m %1 -> PyResult k %1 -> (m %1 -> k -> Py π π (PyResult r)) -> Py π π (PyResult r)
withValue1 m = Unsafe.toLinear \r k -> case r of
  Left e -> consume m `lseq` Control.pure (Left e)
  Right v -> k m v

withValue2 :: forall k v m π r. (Consumable m) => m %1 -> PyResult k %1 -> PyResult v %1 -> (m %1 -> k -> v -> Py π π (PyResult r)) -> Py π π (PyResult r)
withValue2 m = Unsafe.toLinear \rk -> Unsafe.toLinear \rv k -> case (rk, rv) of
  (Left e, _) -> consume m `lseq` Control.pure (Left e)
  (_, Left e) -> consume m `lseq` Control.pure (Left e)
  (Right kv, Right vv) -> k m kv vv

-- | Convert a value result, or answer its error.
toPyResult :: forall v π. (ToPy v) => PyResult v %1 -> Py π π (PyResult (Bound π PyAny))
toPyResult (Left e) = Control.pure (Left e)
toPyResult (Right v) = toPy v

-- | 'Nothing' is exhaustion: @NULL@ with no error set raises @StopIteration@.
nextResult :: forall v π. (ToPy v) => PyResult (Maybe v) %1 -> Py π π (PyResult (Bound π PyAny))
nextResult (Left e) = Control.pure (Left e)
nextResult (Right Nothing) = exhausted
nextResult (Right (Just v)) = toPy v

nextObjectResult :: forall π. PyResult (Maybe (Bound π PyAny)) %1 -> Py π π (PyResult (Bound π PyAny))
nextObjectResult (Left e) = Control.pure (Left e)
nextObjectResult (Right Nothing) = exhausted
nextObjectResult (Right (Just b)) = Control.pure (Right b)

-- | The @NULL@ result the trampoline hands back without an error, which CPython reads as @StopIteration@.
exhausted :: forall π. Py π π (PyResult (Bound π PyAny))
exhausted = unsafePyIO (pure (Right (unsafeBoundFromPtr nullPtr)))

-- | The singleton a comparison answers, registered in the arena like any other reference.
compareResult :: forall π. PyResult (Maybe Bool) %1 -> Py π π (PyResult (Bound π PyAny))
compareResult (Left e) = Control.pure (Left e)
compareResult (Right Nothing) = notImplemented
compareResult (Right (Just True)) = singleton c_true
compareResult (Right (Just False)) = singleton c_false

-- | @NotImplemented@, registered in the arena.
notImplemented :: forall π. Py π π (PyResult (Bound π PyAny))
notImplemented = singleton c_notImplemented

singleton :: forall π. IO (Ptr PyObject) -> Py π π (PyResult (Bound π PyAny))
singleton get = unsafePyArena \arena -> do
  obj <- get
  c_incref obj
  c_arenaRegister arena obj
  pure (Right (unsafeBoundFromPtr obj))

decodeOp :: CInt -> CompareOp
decodeOp = \case
  0 -> Lt
  1 -> Le
  2 -> Eq
  3 -> Ne
  4 -> Gt
  _ -> Ge

-- ** Context managers

enterBody :: forall a π. (PyTypeOf a) => (forall π'. Bound π' a %1 -> Py π' π' (PyResult (Bound π' a))) -> Bound π a %1 -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))
enterBody f self args = case args of
  [] -> Control.do
    r <- f self
    toResult @π @(PyResult (Bound π a)) r
  other -> consumeAll other `lseq` consume self `lseq` Control.pure (Left (typeError "__enter__ takes no arguments"))

exitBody :: forall a r π. (PyClass a, SlotResult r Bool) => (forall π'. Mut π' a %1 -> Maybe (Borrowed π' PyBaseException) -> Py π' π' r) -> Proxy π -> Bound π PyAny -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))
exitBody f p self args = case mutPtr self of
  (selfPtr, _) -> exitArgs args \value -> Control.do
    Ur isNone <- unsafePyIO (Ur . (== refPtr value) <$> c_none)
    withMut p selfPtr \m -> Control.do
      r <- f m (if isNone then Nothing else Just (unsafeRetagShare value))
      toResult @π @(PyResult Bool) (slotResult r)

-- | The three arguments of @__exit__@; only the exception value is looked at.
exitArgs :: forall π r. [Bound π PyAny] %1 -> (Borrowed π PyAny -> Py π π (PyResult r)) -> Py π π (PyResult r)
exitArgs [excType, value, traceback] k =
  consume excType `lseq` consume traceback `lseq` case share value of
    Ur v -> k v
exitArgs other _ = consumeAll other `lseq` Control.pure (Left (typeError "__exit__ takes three arguments"))

-- ** Numbers

{- | Dispatch a binary slot: the forward operation when @self@ is an instance
of the class, the reflected one when only @other@ is, else @NotImplemented@.
-}
dispatchBinary :: forall a π. (PyTypeOf a) => Proxy π -> Maybe (BinaryOp a) -> Maybe (BinaryOp a) -> Ptr PyObject -> Ptr PyObject -> Py π π (PyResult (Bound π PyAny))
dispatchBinary p forward reflected self other = Control.do
  Ur selfIs <- isInstanceOf @a self
  if selfIs
    then applyBinary @a p forward self other
    else Control.do
      Ur otherIs <- isInstanceOf @a other
      if otherIs then applyBinary @a p reflected other self else notImplemented

applyBinary :: forall a π. Proxy π -> Maybe (BinaryOp a) -> Ptr PyObject -> Ptr PyObject -> Py π π (PyResult (Bound π PyAny))
applyBinary _ Nothing _ _ = notImplemented
applyBinary p (Just (BinaryOp f)) receiver operand = withReceiver @a p receiver \s -> Control.do
  r <- f s (borrowedAt p operand)
  numberResult r

isInstanceOf :: forall a π. (PyTypeOf a) => Ptr PyObject -> Py π π (Ur Bool)
isInstanceOf ptr = unsafePyIO do
  ty <- sealedTypeOf (Proxy @a)
  rc <- c_isInstance ptr ty
  pure (Ur (rc > 0))

numberResult :: forall π. PyResult (Maybe (Bound π PyAny)) %1 -> Py π π (PyResult (Bound π PyAny))
numberResult (Left e) = Control.pure (Left e)
numberResult (Right Nothing) = notImplemented
numberResult (Right (Just b)) = Control.pure (Right b)

inplaceResult :: forall π. Ptr PyObject -> PyResult (Maybe ()) %1 -> Py π π (PyResult (Bound π PyAny))
inplaceResult _ (Left e) = Control.pure (Left e)
inplaceResult _ (Right Nothing) = notImplemented
inplaceResult self (Right (Just ())) = singleton (pure self)

-- ** Buffers

{- | @bf_getbuffer@: claim the word, count the export, release, and fill the
view over the payload's own storage; a held word answers @BufferError@.
Entered from CPython, so no exception may leave.
-}
bufferGetter :: forall a e. (PyClass a, Storable e) => (forall bk α. Borrow bk α a %1 -> Borrow bk α (SVector e)) -> CString -> Ptr PyObject -> Ptr () -> CInt -> IO CInt
bufferGetter proj fmt self view flags = do
  r <- try do
    ety <- classType @a
    case ety of
      Left e -> refuse e
      Right ty -> do
        cell <- c_cellOf self ty
        rc <- claimResult <$> c_cellExportBegin cell
        case rc of
          ClaimOk -> do
            payload <- readPayload @a self ty
            let (fptr, n) = SVM.unsafeToForeignPtr0 (projectStorage proj payload)
                itemSize = sizeOf (undefined :: e)
            status <- c_fillBuffer view self (castPtr (unsafeForeignPtrToPtr fptr)) (fromIntegral (n * itemSize)) (fromIntegral itemSize) fmt flags
            NonLinear.when (status < 0) (c_cellExportEnd cell)
            pure status
          ClaimBusy -> refuse (bufferError (pyClassName (Proxy @a) <> " is borrowed by a Haskell scope and cannot be exported"))
          other -> refuse (claimError (pyClassName (Proxy @a)) other)
  case r of
    Left (e :: SomeException) -> refuse (someExceptionToPyErr e)
    Right status -> pure status
  where
    refuse e = do
      c_bufferFail view
      raiseErr e
      pure (-1)

-- | @bf_releasebuffer@: uncount the export, without a claim.
bufferReleaser :: forall a. (PyClass a) => Ptr PyObject -> Ptr () -> IO ()
bufferReleaser self view = do
  r <- try do
    ety <- classType @a
    case ety of
      Left _ -> pure ()
      Right ty -> do
        cell <- c_cellOf self ty
        c_cellExportEnd cell
    c_bufferFreeInternal view
  case r of
    Left (_ :: SomeException) -> pure ()
    Right () -> pure ()

{- | The storage behind the payload, through the projection at a shared borrow.
Trusted: the export count keeps every dereference away while the view lives.
-}
projectStorage :: forall a e. (forall bk α. Borrow bk α a %1 -> Borrow bk α (SVector e)) -> a -> SVM.IOVector e
projectStorage proj payload = case proj (UnsafeAlias payload :: Share ('Al 0) a) of
  UnsafeAlias (UV.Vector mv) -> mv
