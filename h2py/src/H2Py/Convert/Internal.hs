{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveLift #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# OPTIONS_HADDOCK hide #-}

{- |
Conversions between Haskell values and Python objects, and the type hints
that the stub renders for them.
See sections 5.6 and 5.11 of the design.

Both classes are over /value/ types; reference-typed arguments and results are
the trampoline's business.
'fromPy' answers 'Left' with a @TypeError@ on mismatch, and 'toPy' is linear
because moving a linearly owned Haskell value into Python is a consumption.
-}
module H2Py.Convert.Internal (
  module H2Py.Convert.Internal,
) where

import Control.Functor.Linear qualified as Control
import Control.Monad qualified as NonLinear
import Control.Monad.Borrow.BO (share, type (>=))
import Control.Monad.Borrow.Lifetime.Internal (Lifetime (..))
import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Foreign qualified as TF
import Data.Vector qualified as V
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr, nullPtr)
import H2Py.Object.Internal
import H2Py.Py.Internal
import H2Py.Runtime.Internal
import Language.Haskell.TH.Syntax (Lift)
import Prelude.Linear (Consumable (..), Ur (..), lseq)
import Unsafe.Linear qualified as Unsafe

-- * Type hints

-- | A Python type hint, as the stub renders it.
data TypeHint
  = -- | @int@, @str@, @Counter@, @numpy.typing.NDArray[numpy.float64]@.
    TName Text
  | -- | @list[int]@, @dict[str, float]@.
    TApply Text [TypeHint]
  | -- | @int | str@.
    TUnion [TypeHint]
  | -- | @T | None@.
    TOptional TypeHint
  | -- | @tuple[int, str]@.
    TTuple [TypeHint]
  | -- | @None@.
    TNone
  | -- | @Any@.
    TAny
  deriving stock (Show, Eq, Lift)

-- | Render a hint as Python source.
renderHint :: TypeHint -> Text
renderHint = \case
  TName n -> n
  TApply n args -> n <> "[" <> T.intercalate ", " (map renderHint args) <> "]"
  TUnion [] -> "Any"
  TUnion ts -> T.intercalate " | " (map renderHint ts)
  TOptional t -> renderHint t <> " | None"
  TTuple [] -> "tuple[()]"
  TTuple ts -> "tuple[" <> T.intercalate ", " (map renderHint ts) <> "]"
  TNone -> "None"
  TAny -> "Any"

{- | Every convertible type has a hint, so a stub can never be partial.
A superclass of both conversion classes.
-}
class PyTypeHint (a :: Type) where
  pyTypeHint :: Proxy a -> TypeHint

-- | @Any@, for a type its author does not want to describe.
newtype AsAny a = AsAny a

instance PyTypeHint (AsAny a) where
  pyTypeHint _ = TAny

instance PyTypeHint Int where pyTypeHint _ = TName "int"

instance PyTypeHint Integer where pyTypeHint _ = TName "int"

instance PyTypeHint Word where pyTypeHint _ = TName "int"

instance PyTypeHint Double where pyTypeHint _ = TName "float"

instance PyTypeHint Float where pyTypeHint _ = TName "float"

instance PyTypeHint Bool where pyTypeHint _ = TName "bool"

instance PyTypeHint Char where pyTypeHint _ = TName "str"

instance PyTypeHint Text where pyTypeHint _ = TName "str"

instance PyTypeHint ByteString where pyTypeHint _ = TName "bytes"

instance PyTypeHint () where pyTypeHint _ = TNone

instance (PyTypeHint a) => PyTypeHint (Maybe a) where
  pyTypeHint _ = TOptional (pyTypeHint (Proxy @a))

instance (PyTypeHint a, PyTypeHint b) => PyTypeHint (Either a b) where
  pyTypeHint _ = TUnion [pyTypeHint (Proxy @a), pyTypeHint (Proxy @b)]

instance {-# OVERLAPPING #-} PyTypeHint String where pyTypeHint _ = TName "str"

instance {-# OVERLAPPABLE #-} (PyTypeHint a) => PyTypeHint [a] where
  pyTypeHint _ = TApply "list" [pyTypeHint (Proxy @a)]

instance (PyTypeHint a) => PyTypeHint (V.Vector a) where
  pyTypeHint _ = TApply "list" [pyTypeHint (Proxy @a)]

instance (PyTypeHint k, PyTypeHint v) => PyTypeHint (Map k v) where
  pyTypeHint _ = TApply "dict" [pyTypeHint (Proxy @k), pyTypeHint (Proxy @v)]

instance (PyTypeHint a) => PyTypeHint (Set a) where
  pyTypeHint _ = TApply "set" [pyTypeHint (Proxy @a)]

instance (PyTypeHint a, PyTypeHint b) => PyTypeHint (a, b) where
  pyTypeHint _ = TTuple [pyTypeHint (Proxy @a), pyTypeHint (Proxy @b)]

instance (PyTypeHint a, PyTypeHint b, PyTypeHint c) => PyTypeHint (a, b, c) where
  pyTypeHint _ = TTuple [pyTypeHint (Proxy @a), pyTypeHint (Proxy @b), pyTypeHint (Proxy @c)]

instance (PyTypeHint a, PyTypeHint b, PyTypeHint c, PyTypeHint d) => PyTypeHint (a, b, c, d) where
  pyTypeHint _ = TTuple [pyTypeHint (Proxy @a), pyTypeHint (Proxy @b), pyTypeHint (Proxy @c), pyTypeHint (Proxy @d)]

instance (PyTypeHint a, PyTypeHint b, PyTypeHint c, PyTypeHint d, PyTypeHint e) => PyTypeHint (a, b, c, d, e) where
  pyTypeHint _ = TTuple [pyTypeHint (Proxy @a), pyTypeHint (Proxy @b), pyTypeHint (Proxy @c), pyTypeHint (Proxy @d), pyTypeHint (Proxy @e)]

instance (PyTypeHint a) => PyTypeHint (Ur a) where
  pyTypeHint _ = pyTypeHint (Proxy @a)

instance (PyTypeOf t) => PyTypeHint (PyHandle t) where
  pyTypeHint _ = TName (pyTypeName (Proxy @t))

-- * Result helpers

-- | Map a linear function over a result.
mapResult :: (a %1 -> b) -> PyResult a %1 -> PyResult b
mapResult f = \case
  Left e -> Left e
  Right a -> Right (f a)

{- | Map an unrestricted function over a linearly bound result of value type.
Trusted at each use: the value is an ordinary Haskell value, not a linear
resource, so treating it as unrestricted creates no alias.
-}
mapU :: forall a b π γ. (Either PyErr a -> Either PyErr b) -> Py π γ (PyResult a) %1 -> Py π γ (PyResult b)
mapU f = Control.fmap (Unsafe.toLinear f)

-- | Widen a fresh handle into the result type.
rightAny :: Bound π t %1 -> PyResult (Bound π PyAny)
rightAny b = Right (asAnyMut b)

-- * FromPy

-- | Conversion from a Python object to a Haskell value.
class (PyTypeHint a) => FromPy a where
  fromPy :: forall π π' γ. (π >= γ) => Borrowed π PyAny -> Py π' γ (PyResult a)

-- | The @TypeError@ of a failed conversion, PyO3-style.
conversionError :: Text -> Ptr PyObject -> IO PyErr
conversionError expected p = do
  tyName <- typeNameOf p
  pure (typeError ("'" <> tyName <> "' object cannot be converted to '" <> expected <> "'"))

-- | @type(o).__name__@, best effort.
typeNameOf :: Ptr PyObject -> IO Text
typeNameOf p = do
  ty <- c_objectType p
  if ty == nullPtr
    then pure "?"
    else do
      nameObj <- TF.withCString "__name__" (c_getAttrString ty)
      c_decref ty
      if nameObj == nullPtr
        then do
          e <- c_takeError
          NonLinear.unless (e == nullPtr) (c_decref e)
          pure "?"
        else do
          r <- peekPyText nameObj
          c_decref nameObj
          pure (either (const "?") id r)

-- | Whether the object is an instance of the built-in type with the given shim index.
isInstanceOfBuiltin :: Ptr PyObject -> CInt -> IO Bool
isInstanceOfBuiltin p which = do
  ty <- c_builtinType which
  (> 0) <$> c_isInstance p ty

-- | Clear a raised exception without looking at it.
clearError :: IO ()
clearError = do
  e <- c_takeError
  NonLinear.unless (e == nullPtr) (c_decref e)

instance FromPy Int where
  fromPy ref = unsafePyIO do
    let p = refPtr ref
    isFloat <- isInstanceOfBuiltin p 2
    if isFloat
      then Left <$> conversionError "int" p
      else do
        n <- c_longAsLongLong p
        occurred <- c_errOccurred
        if occurred /= 0 then Left <$> takeError else pure (Right (fromIntegral n))

instance FromPy Integer where
  fromPy ref = unsafePyIO do
    let p = refPtr ref
    idx <- c_numberIndex p
    if idx == nullPtr
      then Left <$> takeError
      else do
        n <- readInteger idx
        c_decref idx
        pure (Right n)

instance FromPy Word where
  fromPy ref = mapU check (fromPy @Integer ref)
    where
      check = \case
        Left e -> Left e
        Right n
          | n < 0 -> Left (overflowError "can't convert negative int to unsigned")
          | n > fromIntegral (maxBound :: Word) -> Left (overflowError "int too big to convert")
          | otherwise -> Right (fromIntegral n)

instance FromPy Double where
  fromPy ref = unsafePyIO do
    let p = refPtr ref
    d <- c_floatAsDouble p
    occurred <- c_errOccurred
    if occurred /= 0 then Left <$> takeError else pure (Right (realToFrac d))

instance FromPy Float where
  fromPy ref = mapU (fmap (realToFrac :: Double -> Float)) (fromPy ref)

instance FromPy Bool where
  fromPy ref = unsafePyIO do
    let p = refPtr ref
    isBool <- isInstanceOfBuiltin p 3
    if isBool then Right . (/= 0) <$> c_isTrue p else Left <$> conversionError "bool" p

instance FromPy Text where
  fromPy ref = unsafePyIO do
    let p = refPtr ref
    isStr <- isInstanceOfBuiltin p 4
    if isStr then peekPyText p else Left <$> conversionError "str" p

instance {-# OVERLAPPING #-} FromPy String where
  fromPy ref = mapU (fmap T.unpack) (fromPy ref)

instance FromPy Char where
  fromPy ref = mapU check (fromPy @Text ref)
    where
      check = \case
        Left e -> Left e
        Right t
          | T.length t == 1 -> Right (T.head t)
          | otherwise -> Left (valueError "expected a string of length 1")

instance FromPy ByteString where
  fromPy ref = unsafePyIO do
    let p = refPtr ref
    isBytes <- isInstanceOfBuiltin p 5
    if isBytes then peekPyBytes p else Left <$> conversionError "bytes" p

instance FromPy () where
  fromPy ref = unsafePyIO do
    let p = refPtr ref
    noneObj <- c_none
    if p == noneObj then pure (Right ()) else Left <$> conversionError "None" p

instance (FromPy a) => FromPy (Maybe a) where
  fromPy ref = Control.do
    Ur isNone <- unsafePyIO (Ur . (== refPtr ref) <$> c_none)
    if isNone
      then Control.pure (Right Nothing)
      else mapU (fmap Just) (fromPy ref)

instance (FromPy a, FromPy b) => FromPy (Either a b) where
  fromPy ref = Control.do
    ra <- fromPy @a ref
    Unsafe.toLinear
      ( \case
          Right a -> Control.pure (Right (Left a))
          Left _ -> mapU (fmap Right) (fromPy @b ref)
      )
      ra

instance {-# OVERLAPPABLE #-} (FromPy a) => FromPy [a] where
  fromPy ref = unsafePyIO (iterateItems (refPtr ref) (fromPyPtr @a))

instance (FromPy a) => FromPy (V.Vector a) where
  fromPy ref = mapU (fmap V.fromList) (fromPy ref)

instance (FromPy a, Ord a) => FromPy (Set a) where
  fromPy ref = mapU (fmap Set.fromList) (fromPy ref)

instance (FromPy k, FromPy v, Ord k) => FromPy (Map k v) where
  fromPy ref = unsafePyIO do
    let p = refPtr ref
    isMapping <- c_mappingCheck p
    if isMapping == 0
      then Left <$> conversionError "dict" p
      else do
        items <- c_mappingItems p
        if items == nullPtr
          then do
            -- PyMapping_Check is true for every sequence, so a failed
            -- PyMapping_Items is what tells a list from a mapping: a mismatch,
            -- reported as a TypeError like every other.
            clearError
            Left <$> conversionError "dict" p
          else do
            r <- iterateItems items (fromPyPtr @(k, v))
            c_decref items
            pure (fmap Map.fromList r)

instance (FromPy a, FromPy b) => FromPy (a, b) where
  fromPy ref = unsafePyIO do
    r <- tupleItems (refPtr ref) 2
    case r of
      Left e -> pure (Left e)
      Right [pa, pb] -> do
        ra <- fromPyPtr @a pa
        rb <- fromPyPtr @b pb
        pure ((,) <$> ra <*> rb)
      Right _ -> pure (Left (systemError "tuple arity"))

instance (FromPy a, FromPy b, FromPy c) => FromPy (a, b, c) where
  fromPy ref = unsafePyIO do
    r <- tupleItems (refPtr ref) 3
    case r of
      Left e -> pure (Left e)
      Right [pa, pb, pc] -> do
        ra <- fromPyPtr @a pa
        rb <- fromPyPtr @b pb
        rc <- fromPyPtr @c pc
        pure ((,,) <$> ra <*> rb <*> rc)
      Right _ -> pure (Left (systemError "tuple arity"))

instance (FromPy a, FromPy b, FromPy c, FromPy d) => FromPy (a, b, c, d) where
  fromPy ref = unsafePyIO do
    r <- tupleItems (refPtr ref) 4
    case r of
      Left e -> pure (Left e)
      Right [pa, pb, pc, pd] -> do
        ra <- fromPyPtr @a pa
        rb <- fromPyPtr @b pb
        rc <- fromPyPtr @c pc
        rd <- fromPyPtr @d pd
        pure ((,,,) <$> ra <*> rb <*> rc <*> rd)
      Right _ -> pure (Left (systemError "tuple arity"))

instance (FromPy a, FromPy b, FromPy c, FromPy d, FromPy e) => FromPy (a, b, c, d, e) where
  fromPy ref = unsafePyIO do
    r <- tupleItems (refPtr ref) 5
    case r of
      Left err -> pure (Left err)
      Right [pa, pb, pc, pd, pe] -> do
        ra <- fromPyPtr @a pa
        rb <- fromPyPtr @b pb
        rc <- fromPyPtr @c pc
        rd <- fromPyPtr @d pd
        re <- fromPyPtr @e pe
        pure ((,,,,) <$> ra <*> rb <*> rc <*> rd <*> re)
      Right _ -> pure (Left (systemError "tuple arity"))

instance (FromPy a) => FromPy (Ur a) where
  fromPy ref = mapU (fmap Ur) (fromPy ref)

instance (PyTypeOf t) => FromPy (PyHandle t) where
  fromPy ref = unsafePyIO do
    let p = refPtr ref
    ty <- sealedTypeOf (Proxy @t)
    ok <- c_isInstance p ty
    if ok > 0
      then Right <$> handleFromBorrowed p
      else Left <$> conversionError (pyTypeName (Proxy @t)) p

{- | Convert an object we hold a pointer to, from inside a trusted IO loop.
The pointer is valid for the call, and the thread is attached, so the
re-entry into the @Py@ world is the same scope continuing.
-}
fromPyPtr :: forall a. (FromPy a) => Ptr PyObject -> IO (PyResult a)
fromPyPtr p = unsafeRunPy (fromPy @a (unsafeBorrowedFromPtr p :: Borrowed ('Al 0) PyAny) :: Py ('Al 0) ('Al 0) (PyResult a))

-- | The items of a tuple of the given size, as borrowed pointers.
tupleItems :: Ptr PyObject -> Int -> IO (PyResult [Ptr PyObject])
tupleItems p n = do
  isTuple <- isInstanceOfBuiltin p 6
  if not isTuple
    then Left <$> conversionError ("tuple of length " <> T.pack (show n)) p
    else do
      size <- c_tupleSize p
      if fromIntegral size /= n
        then pure (Left (valueError ("expected a tuple of length " <> T.pack (show n) <> ", got " <> T.pack (show size))))
        else Right <$> NonLinear.mapM (c_tupleGetItem p . fromIntegral) [0 .. n - 1]

{- | Iterate an iterable, converting each item; @str@ and @bytes@ are refused,
as PyO3 refuses them.
Each item's reference is released as soon as it is converted, so the arena
does not grow with the length.
-}
iterateItems :: Ptr PyObject -> (Ptr PyObject -> IO (PyResult a)) -> IO (PyResult [a])
iterateItems p convert = do
  isStr <- isInstanceOfBuiltin p 4
  isBytes <- isInstanceOfBuiltin p 5
  if isStr || isBytes
    then Left <$> conversionError "list" p
    else do
      it <- c_getIter p
      if it == nullPtr
        then Left <$> takeError
        else do
          r <- loop it []
          c_decref it
          pure r
  where
    loop it acc = do
      item <- c_iterNext it
      if item == nullPtr
        then do
          occurred <- c_errOccurred
          if occurred /= 0 then Left <$> takeError else pure (Right (reverse acc))
        else do
          r <- convert item
          c_decref item
          case r of
            Left e -> pure (Left e)
            Right a -> loop it (a : acc)

-- * ToPy

{- | Conversion from a Haskell value to a new Python object, in the current arena.
Linear: moving a linearly owned value into Python consumes it.
The 'Consumable' superclass is what a 'Left' in the middle of a composite
conversion needs, to consume the components not yet converted.
-}
class (PyTypeHint a, Consumable a) => ToPy a where
  toPy :: forall π γ. (π >= γ) => a %1 -> Py π γ (PyResult (Bound π PyAny))

-- | Convert an unrestricted value; the linear entry point for value types.
toPyU :: forall a π γ. (ToPy a, π >= γ) => a -> Py π γ (PyResult (Bound π PyAny))
toPyU a = toPy a

instance ToPy Int where
  toPy = Unsafe.toLinear \n -> Control.fmap (mapResult asAnyMut) (toInt n)

instance ToPy Integer where
  toPy = Unsafe.toLinear \n -> Control.fmap (mapResult asAnyMut) (toInteger' n)

instance ToPy Word where
  toPy = Unsafe.toLinear \n -> Control.fmap (mapResult asAnyMut) (toInteger' (fromIntegral n))

instance ToPy Double where
  toPy = Unsafe.toLinear \d -> Control.fmap (mapResult asAnyMut) (toFloat d)

instance ToPy Float where
  toPy = Unsafe.toLinear \d -> Control.fmap (mapResult asAnyMut) (toFloat (realToFrac d))

instance ToPy Bool where
  toPy = Unsafe.toLinear \b -> Control.fmap (mapResult asAnyMut) (toBool b)

instance ToPy Text where
  toPy = Unsafe.toLinear \t -> Control.fmap (mapResult asAnyMut) (toStr t)

instance {-# OVERLAPPING #-} ToPy String where
  toPy = Unsafe.toLinear \s -> Control.fmap (mapResult asAnyMut) (toStr (T.pack s))

instance ToPy Char where
  toPy = Unsafe.toLinear \c -> Control.fmap (mapResult asAnyMut) (toStr (T.singleton c))

instance ToPy ByteString where
  toPy = Unsafe.toLinear \bs -> Control.fmap (mapResult asAnyMut) (toBytes bs)

instance ToPy () where
  toPy () = Control.fmap rightAny none

instance (ToPy a) => ToPy (Maybe a) where
  toPy = \case
    Nothing -> Control.fmap rightAny none
    Just a -> toPy a

instance (ToPy a, ToPy b) => ToPy (Either a b) where
  toPy = \case
    Left a -> toPy a
    Right b -> toPy b

instance {-# OVERLAPPABLE #-} (ToPy a) => ToPy [a] where
  toPy = Unsafe.toLinear \xs -> Control.do
    r <- newList
    startList r xs

startList :: forall a π γ. (ToPy a, π >= γ) => PyResult (Bound π PyList) %1 -> [a] -> Py π γ (PyResult (Bound π PyAny))
startList (Left e) _ = Control.pure (Left e)
startList (Right l) xs = appendAll l xs

appendAll :: forall a π γ. (ToPy a, π >= γ) => Bound π PyList %1 -> [a] -> Py π γ (PyResult (Bound π PyAny))
appendAll l [] = Control.pure (Right (asAnyMut l))
appendAll l (y : ys) = Control.do
  ry <- toPy y
  appendOne l ry ys

appendOne :: forall a π γ. (ToPy a, π >= γ) => Bound π PyList %1 -> PyResult (Bound π PyAny) %1 -> [a] -> Py π γ (PyResult (Bound π PyAny))
appendOne l (Left e) ys = Control.pure (consume l `lseq` consume ys `lseq` Left e)
appendOne l (Right item) ys = case share item of
  Ur v -> Control.do
    (rc, l') <- listAppend l v
    afterAppend l' rc ys

afterAppend :: forall a π γ. (ToPy a, π >= γ) => Bound π PyList %1 -> PyResult () %1 -> [a] -> Py π γ (PyResult (Bound π PyAny))
afterAppend l (Left e) ys = Control.pure (consume l `lseq` consume ys `lseq` Left e)
afterAppend l (Right ()) ys = appendAll l ys

instance (ToPy a) => ToPy (V.Vector a) where
  toPy = Unsafe.toLinear \v -> toPy (V.toList v)

instance (ToPy a, ToPy b) => ToPy (a, b) where
  toPy = Unsafe.toLinear \(a, b) -> tupleOf [SomePy a, SomePy b]

instance (ToPy a, ToPy b, ToPy c) => ToPy (a, b, c) where
  toPy = Unsafe.toLinear \(a, b, c) -> tupleOf [SomePy a, SomePy b, SomePy c]

instance (ToPy a, ToPy b, ToPy c, ToPy d) => ToPy (a, b, c, d) where
  toPy = Unsafe.toLinear \(a, b, c, d) -> tupleOf [SomePy a, SomePy b, SomePy c, SomePy d]

instance (ToPy a, ToPy b, ToPy c, ToPy d, ToPy e) => ToPy (a, b, c, d, e) where
  toPy = Unsafe.toLinear \(a, b, c, d, e) -> tupleOf [SomePy a, SomePy b, SomePy c, SomePy d, SomePy e]

instance (ToPy a) => ToPy (Ur a) where
  toPy (Ur a) = toPy a

instance (PyTypeOf t) => ToPy (PyHandle t) where
  toPy = Unsafe.toLinear \h -> Control.fmap rightAny (fromHandle h)

-- | A component of a tuple conversion, kept as a value so that a 'Left' can consume the ones not yet converted.
data SomePy where
  SomePy :: (ToPy x) => x -> SomePy

instance Consumable SomePy where
  consume = Unsafe.toLinear \(SomePy x) -> consume x

-- | Build a tuple from components, consuming the rest when one fails.
tupleOf :: forall π γ. (π >= γ) => [SomePy] -> Py π γ (PyResult (Bound π PyAny))
tupleOf parts = go parts []
  where
    go :: [SomePy] -> [Borrowed π PyAny] -> Py π γ (PyResult (Bound π PyAny))
    go [] acc = Control.fmap (mapResult asAnyMut) (toTuple (reverse acc))
    go (SomePy x : rest) acc = Control.do
      r <- toPy x
      step r rest acc
    step :: PyResult (Bound π PyAny) %1 -> [SomePy] -> [Borrowed π PyAny] -> Py π γ (PyResult (Bound π PyAny))
    step (Left e) rest _ = Control.pure (consume rest `lseq` Left e)
    step (Right b) rest acc = case share b of
      Ur v -> go rest (v : acc)
