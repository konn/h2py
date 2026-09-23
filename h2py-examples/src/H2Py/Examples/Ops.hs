{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}
-- The Unsealed class below deliberately omits pyClassSealed; see its note.
{-# OPTIONS_GHC -Wno-missing-methods #-}

{- |
The @ops@ submodule: one function per protocol operation and conversion
path, the error paths in both directions, a stashed 'PyHandle', and the
@Cell@ class with a payload in a Haskell 'Ref'.
The Python suites @test_conversions.py@, @test_errors.py@ and
@test_refcounts.py@ exercise it.

It also carries the fixtures of the Phase 3 gate of section 7 of the design:
contention through a callback, through a second handle and across threads,
poisoning by an asynchronous exit, a hold scoped by @attach'_@, a class that
no module registers (@Ghost@), a hand-written class instance without the
sealed witness (@Unsealed@), and a subclassable class whose constructor makes
objects of another class (@Base@ and @Helper@).
-}
module H2Py.Examples.Ops (
  -- * The submodule
  opsModule,
  Cell (..),
  h2py_class_Cell,
  Ghost (..),
  h2py_class_Ghost,
  Unsealed (..),
  Helper (..),
  h2py_class_Helper,
  Base (..),
  h2py_class_Base,

  -- * Protocol operations
  getAttrOp,
  hasAttrOp,
  setAttrOp,
  delAttrOp,
  getItemOp,
  getIndexOp,
  setItemOp,
  delItemOp,
  lengthOp,
  reprOp,
  strOp,
  isTrueOp,
  callOp,
  call0Op,
  callMethodOp,
  callMethod0Op,
  iterateSum,
  hashOp,
  richCompareOp,
  equalsOp,
  typeOfOp,
  downcastInt,
  downcastMutInt,
  listAppendOp,
  setAddOp,

  -- * Constructors and copies
  toStrOp,
  toBytesOp,
  toIntOp,
  toIntegerOp,
  toFloatOp,
  toBoolOp,
  noneOp,
  toListOp,
  toTupleOp,
  emptyTupleOp,
  toDictOp,
  toSetOp,
  newDictOp,
  newListOp,
  copyOutInt,
  copyOutFloat,
  copyOutBool,
  copyOutStr,
  copyOutBytes,
  copyOutNone,
  handleRoundtrip,

  -- * Round trips
  roundtripInt,
  roundtripInteger,
  roundtripWord,
  roundtripDouble,
  roundtripFloat,
  roundtripBool,
  roundtripChar,
  roundtripText,
  roundtripString,
  roundtripBytes,
  roundtripUnit,
  roundtripMaybeInt,
  roundtripEitherIntText,
  roundtripIntList,
  roundtripDoubleVector,
  mapItems,
  setItems,
  roundtripTuple2,
  roundtripTuple3,
  roundtripTuple4,
  roundtripTuple5,
  bigInteger,

  -- * Handles
  stash,
  stashed,
  unstash,
  haskellGc,
  noop,

  -- * Errors
  failValueError,
  failTypeError,
  haskellError,
  useThenError,
  useMutThenError,
  throwOnLeft,
  keyErrorRoundtrip,

  -- * The Cell class
  newCell,
  cellGet,
  cellIncr,
  cellIncrThenFail,
  cellPoison,
  cellSumWith,
  cellIdentity,
  cellCallWhileHeld,
  cellDerefSecond,
  cellHoldUntilTimeout,
  cellHoldUntilKilled,
  cellScopedHold,

  -- * Classes outside the registration
  ghostArg,
  makeGhost,
  makeUnsealed,

  -- * A constructor that constructs
  newBase,
  baseHelper,
  baseScopedHelper,
) where

import Control.Concurrent (forkIO, myThreadId, threadDelay, throwTo)
import Control.Exception (ErrorCall (..))
import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.IO (BIO, MonadIO (..))
import Control.Monad.Borrow.Pure
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Data.Ref.Linear.Borrow qualified as RefB
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Vector qualified as V
import H2Py
import H2Py.Module.Internal (unsafeNewTypeCell)
import Prelude.Linear hiding (iterate)
import System.IO.Unsafe (unsafePerformIO)
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Prelude qualified as P

-- * Protocol operations

-- | @getattr(o, name)@.
getAttrOp :: Borrowed π PyAny -> Text -> Py π π (PyResult (Bound π PyAny))
getAttrOp = getAttr

-- | @setattr(o, name, v)@.
setAttrOp :: Bound π PyAny %1 -> Text -> Borrowed π PyAny -> Py π π (PyResult ())
setAttrOp o name v = Control.do
  (r, o') <- setAttr o name v
  Control.pure (consume o' `lseq` r)

-- | @o[k]@.
getItemOp :: Borrowed π PyAny -> Borrowed π PyAny -> Py π π (PyResult (Bound π PyAny))
getItemOp = getItem

-- | @o[k] = v@.
setItemOp :: Bound π PyAny %1 -> Borrowed π PyAny -> Borrowed π PyAny -> Py π π (PyResult ())
setItemOp o k v = Control.do
  (r, o') <- setItem o k v
  Control.pure (consume o' `lseq` r)

-- | @del o[k]@.
delItemOp :: Bound π PyAny %1 -> Borrowed π PyAny -> Py π π (PyResult ())
delItemOp o k = Control.do
  (r, o') <- delItem o k
  Control.pure (consume o' `lseq` r)

-- | @len(o)@.
lengthOp :: Borrowed π PyAny -> Py π π (PyResult Int)
lengthOp = len

-- | @repr(o)@.
reprOp :: Borrowed π PyAny -> Py π π (PyResult Text)
reprOp = repr

-- | @str(o)@.
strOp :: Borrowed π PyAny -> Py π π (PyResult Text)
strOp = str

-- | @f(*args)@ for a list of arguments.
callOp :: Borrowed π PyAny -> Borrowed π PyList -> Py π π (PyResult (Bound π PyAny))
callOp f args = Control.do
  Ur items <- Control.fmap move (collectItems (asAny args))
  case items of
    Left e -> Control.pure (Left e)
    Right views -> call f views

-- | The items of an iterable, as views in the current arena.
collectItems :: Borrowed π PyAny -> Py π π (PyResult [Borrowed π PyAny])
collectItems o = Control.do
  rit <- iterate o
  startCollect rit

startCollect :: PyResult (Bound π PyAny) %1 -> Py π π (PyResult [Borrowed π PyAny])
startCollect (Left e) = Control.pure (Left e)
startCollect (Right it) = case share it of
  Ur v -> collectFrom v []

collectFrom :: Borrowed π PyAny -> [Borrowed π PyAny] -> Py π π (PyResult [Borrowed π PyAny])
collectFrom it acc = Control.do
  r <- next it
  stepCollect it acc r

stepCollect :: Borrowed π PyAny -> [Borrowed π PyAny] -> PyResult (Maybe (Bound π PyAny)) %1 -> Py π π (PyResult [Borrowed π PyAny])
stepCollect _ _ (Left e) = Control.pure (Left e)
stepCollect _ acc (Right Nothing) = Control.pure (Right (P.reverse acc))
stepCollect it acc (Right (Just b)) = case share b of
  Ur v -> collectFrom it (v : acc)

-- | The sum of an iterable of @int@, through @iter@ and @next@.
iterateSum :: Borrowed π PyAny -> Py π π (PyResult Int)
iterateSum o = Control.do
  rit <- iterate o
  startSum rit

startSum :: PyResult (Bound π PyAny) %1 -> Py π π (PyResult Int)
startSum (Left e) = Control.pure (Left e)
startSum (Right it) = case share it of
  Ur v -> sumFrom v 0

sumFrom :: Borrowed π PyAny -> Int -> Py π π (PyResult Int)
sumFrom it acc = Control.do
  r <- next it
  stepSum it acc r

stepSum :: Borrowed π PyAny -> Int -> PyResult (Maybe (Bound π PyAny)) %1 -> Py π π (PyResult Int)
stepSum _ _ (Left e) = Control.pure (Left e)
stepSum _ acc (Right Nothing) = Control.pure (Right acc)
stepSum it acc (Right (Just b)) = case share b of
  Ur v -> Control.do
    Ur rn <- Control.fmap move (fromPy @Int v)
    case rn of
      Left e -> Control.pure (Left e)
      Right n -> sumFrom it (acc + n)

-- | @hash(o)@.
hashOp :: Borrowed π PyAny -> Py π π (PyResult Int)
hashOp = hash

-- | @a == b@.
equalsOp :: Borrowed π PyAny -> Borrowed π PyAny -> Py π π (PyResult Bool)
equalsOp = equals

-- | Whether @downcast@ to @int@ succeeds.
downcastInt :: Borrowed π PyAny -> Py π π Bool
downcastInt o = Control.do
  Ur m <- downcast @PyLong o
  Control.pure (isJustView m)

isJustView :: Maybe (Borrowed π PyLong) -> Bool
isJustView Nothing = False
isJustView (Just _) = True

-- | @hasattr(o, name)@.
hasAttrOp :: Borrowed π PyAny -> Text -> Py π π Bool
hasAttrOp o name = Control.do
  Ur b <- hasAttr o name
  Control.pure b

-- | @delattr(o, name)@.
delAttrOp :: Bound π PyAny %1 -> Text -> Py π π (PyResult ())
delAttrOp o name = Control.do
  (r, o') <- delAttr o name
  Control.pure (consume o' `lseq` r)

-- | @o[i]@ through the sequence protocol.
getIndexOp :: Borrowed π PyAny -> Int -> Py π π (PyResult (Bound π PyAny))
getIndexOp = getIndex

-- | @bool(o)@.
isTrueOp :: Borrowed π PyAny -> Py π π (PyResult Bool)
isTrueOp = isTrue

-- | @f()@.
call0Op :: Borrowed π PyAny -> Py π π (PyResult (Bound π PyAny))
call0Op = call0

-- | @o.name(*args)@ for a list of arguments.
callMethodOp :: Borrowed π PyAny -> Text -> Borrowed π PyList -> Py π π (PyResult (Bound π PyAny))
callMethodOp o name args = Control.do
  Ur items <- Control.fmap move (collectItems (asAny args))
  case items of
    Left e -> Control.pure (Left e)
    Right views -> callMethod o name views

-- | @o.name()@.
callMethod0Op :: Borrowed π PyAny -> Text -> Py π π (PyResult (Bound π PyAny))
callMethod0Op = callMethod0

-- | @a op b@, the operator given as its @tp_richcompare@ code, 0 for @<@ to 5 for @>=@.
richCompareOp :: Borrowed π PyAny -> Int -> Borrowed π PyAny -> Py π π (PyResult Bool)
richCompareOp a op b =
  if op >= 0 && op <= 5
    then richCompareBool a (P.toEnum op) b
    else pyFail (pyErr (Proxy @ValueError) "unknown comparison operator")

-- | @type(o)@.
typeOfOp :: Borrowed π PyAny -> Py π π (Bound π PyType)
typeOfOp = typeOf

-- | 'downcastMut' to @int@: the handle itself when it is one, @TypeError@ otherwise.
downcastMutInt :: Bound π PyAny %1 -> Py π π (PyResult (Bound π PyLong))
downcastMutInt b = Control.do
  r <- downcastMut @PyLong b
  Control.pure (intOrFail r)

intOrFail :: Either (Bound π PyAny) (Bound π PyLong) %1 -> PyResult (Bound π PyLong)
intOrFail (Left b) = consume b `lseq` Left (pyErr (Proxy @TypeError) "not an int")
intOrFail (Right i) = Right i

-- | @lst.append(v)@.
listAppendOp :: Bound π PyList %1 -> Borrowed π PyAny -> Py π π (PyResult ())
listAppendOp lst v = Control.do
  (r, lst') <- listAppend lst v
  Control.pure (consume lst' `lseq` r)

-- | @s.add(v)@.
setAddOp :: Bound π PySet %1 -> Borrowed π PyAny -> Py π π (PyResult ())
setAddOp s v = Control.do
  (r, s') <- setAdd s v
  Control.pure (consume s' `lseq` r)

-- * Constructors, and values copied out

-- | A new @str@.
toStrOp :: Text -> Py π π (PyResult (Bound π PyStr))
toStrOp = toStr

-- | A new @bytes@.
toBytesOp :: ByteString -> Py π π (PyResult (Bound π PyBytes))
toBytesOp = toBytes

-- | A new @int@ from a machine integer.
toIntOp :: Int -> Py π π (PyResult (Bound π PyLong))
toIntOp = toInt

-- | A new @int@ from an 'Integer' of any size.
toIntegerOp :: Integer -> Py π π (PyResult (Bound π PyLong))
toIntegerOp = toInteger'

-- | A new @float@.
toFloatOp :: Double -> Py π π (PyResult (Bound π PyFloat))
toFloatOp = toFloat

-- | @True@ or @False@.
toBoolOp :: Bool -> Py π π (PyResult (Bound π PyBool))
toBoolOp = toBool

-- | @None@, as a reference rather than through the @()@ result.
noneOp :: Py π π (Bound π PyNone)
noneOp = none

-- | A new @list@ of the items of an iterable.
toListOp :: Borrowed π PyAny -> Py π π (PyResult (Bound π PyList))
toListOp o = Control.do
  Ur items <- Control.fmap move (collectItems o)
  case items of
    Left e -> Control.pure (Left e)
    Right views -> toList views

-- | A new @tuple@ of the items of an iterable.
toTupleOp :: Borrowed π PyAny -> Py π π (PyResult (Bound π PyTuple))
toTupleOp o = Control.do
  Ur items <- Control.fmap move (collectItems o)
  case items of
    Left e -> Control.pure (Left e)
    Right views -> toTuple views

-- | @()@.
emptyTupleOp :: Py π π (PyResult (Bound π PyTuple))
emptyTupleOp = emptyTuple

-- | A new @set@ of the items of an iterable.
toSetOp :: Borrowed π PyAny -> Py π π (PyResult (Bound π PySet))
toSetOp o = Control.do
  Ur items <- Control.fmap move (collectItems o)
  case items of
    Left e -> Control.pure (Left e)
    Right views -> toSet views

-- | A new @dict@ from an iterable of @(key, value)@ pairs, each read through 'getIndex'.
toDictOp :: Borrowed π PyAny -> Py π π (PyResult (Bound π PyDict))
toDictOp pairs = Control.do
  Ur items <- Control.fmap move (collectItems pairs)
  case items of
    Left e -> Control.pure (Left e)
    Right views -> Control.do
      Ur kvs <- Control.fmap move (collectPairs views [])
      case kvs of
        Left e -> Control.pure (Left e)
        Right entries -> toDict entries

collectPairs :: [Borrowed π PyAny] -> [(Borrowed π PyAny, Borrowed π PyAny)] -> Py π π (PyResult [(Borrowed π PyAny, Borrowed π PyAny)])
collectPairs [] acc = Control.pure (Right (P.reverse acc))
collectPairs (v : vs) acc = Control.do
  rk <- getIndex v 0
  rv <- getIndex v 1
  stepPairs vs acc rk rv

stepPairs :: [Borrowed π PyAny] -> [(Borrowed π PyAny, Borrowed π PyAny)] -> PyResult (Bound π PyAny) %1 -> PyResult (Bound π PyAny) %1 -> Py π π (PyResult [(Borrowed π PyAny, Borrowed π PyAny)])
stepPairs _ _ (Left e) rv = consume rv `lseq` Control.pure (Left e)
stepPairs _ _ (Right k) (Left e) = consume k `lseq` Control.pure (Left e)
stepPairs vs acc (Right k) (Right v) = case share k of
  Ur kv -> case share v of
    Ur vv -> collectPairs vs ((kv, vv) : acc)

-- | An empty @dict@.
newDictOp :: Py π π (PyResult (Bound π PyDict))
newDictOp = newDict

-- | An empty @list@.
newListOp :: Py π π (PyResult (Bound π PyList))
newListOp = newList

-- | The 'Integer' behind an @int@.
copyOutInt :: Borrowed π PyLong -> Py π π Integer
copyOutInt o = Control.do
  Ur n <- copyOut o
  Control.pure n

-- | The 'Double' behind a @float@.
copyOutFloat :: Borrowed π PyFloat -> Py π π Double
copyOutFloat o = Control.do
  Ur d <- copyOut o
  Control.pure d

-- | The 'Bool' behind a @bool@.
copyOutBool :: Borrowed π PyBool -> Py π π Bool
copyOutBool o = Control.do
  Ur b <- copyOut o
  Control.pure b

-- | The 'Text' behind a @str@.
copyOutStr :: Borrowed π PyStr -> Py π π Text
copyOutStr o = Control.do
  Ur t <- copyOut o
  Control.pure t

-- | The 'ByteString' behind a @bytes@.
copyOutBytes :: Borrowed π PyBytes -> Py π π ByteString
copyOutBytes o = Control.do
  Ur b <- copyOut o
  Control.pure b

-- | @()@ behind @None@.
copyOutNone :: Borrowed π PyNone -> Py π π ()
copyOutNone o = Control.do
  Ur u <- copyOut o
  Control.pure u

-- | 'toHandle', then 'fromHandleShare' and 'fromHandle' in the same call: the object itself comes back.
handleRoundtrip :: Borrowed π PyAny -> Py π π (PyResult (Bound π PyAny))
handleRoundtrip o = Control.do
  Ur h <- toHandle o
  Ur v <- fromHandleShare h
  Ur same <- Control.fmap move (equals v o)
  case same of
    Left e -> Control.pure (Left e)
    Right False -> pyFail (pyErr (Proxy @RuntimeError) "the handle's view is not the object")
    Right True -> Control.fmap Right (fromHandle h)

-- * Round trips, one per FromPy and ToPy instance

roundtripInt :: Int -> Py π π Int
roundtripInt n = Control.pure n

roundtripInteger :: Integer -> Py π π Integer
roundtripInteger n = Control.pure n

roundtripWord :: Word -> Py π π Word
roundtripWord n = Control.pure n

roundtripDouble :: Double -> Py π π Double
roundtripDouble d = Control.pure d

roundtripFloat :: Float -> Py π π Float
roundtripFloat d = Control.pure d

roundtripBool :: Bool -> Py π π Bool
roundtripBool b = Control.pure b

roundtripChar :: Char -> Py π π Char
roundtripChar c = Control.pure c

roundtripText :: Text -> Py π π Text
roundtripText t = Control.pure t

roundtripString :: String -> Py π π String
roundtripString s = Control.pure s

roundtripBytes :: ByteString -> Py π π ByteString
roundtripBytes b = Control.pure b

roundtripUnit :: () -> Py π π ()
roundtripUnit u = Control.pure u

roundtripMaybeInt :: Maybe Int -> Py π π (Maybe Int)
roundtripMaybeInt m = Control.pure m

roundtripEitherIntText :: Either Int Text -> Py π π (Either Int Text)
roundtripEitherIntText e = Control.pure e

roundtripIntList :: [Int] -> Py π π [Int]
roundtripIntList xs = Control.pure xs

roundtripDoubleVector :: V.Vector Double -> Py π π (V.Vector Double)
roundtripDoubleVector v = Control.pure v

-- | A mapping in, its sorted items out: 'Map' has no 'ToPy' instance.
mapItems :: Map Text Int -> Py π π [(Text, Int)]
mapItems m = Control.pure (Map.toList m)

-- | A set in, its sorted elements out: 'Set' has no 'ToPy' instance.
setItems :: Set Int -> Py π π [Int]
setItems s = Control.pure (Set.toList s)

roundtripTuple2 :: (Int, Text) -> Py π π (Int, Text)
roundtripTuple2 t = Control.pure t

roundtripTuple3 :: (Int, Text, Double) -> Py π π (Int, Text, Double)
roundtripTuple3 t = Control.pure t

roundtripTuple4 :: (Int, Text, Double, Bool) -> Py π π (Int, Text, Double, Bool)
roundtripTuple4 t = Control.pure t

roundtripTuple5 :: (Int, Text, Double, Bool, [Int]) -> Py π π (Int, Text, Double, Bool, [Int])
roundtripTuple5 t = Control.pure t

-- | @2 ** 100@, through the arbitrary-precision path of 'Integer'.
bigInteger :: Py π π Integer
bigInteger = Control.pure (2 P.^ (100 :: Int))

-- * A handle stored across calls

-- | The stash: a Haskell structure holding a strong reference across calls.
stashRef :: IORef (Maybe (PyHandle PyAny))
stashRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE stashRef #-}

-- | Keep a strong reference to the object until 'unstash'.
stash :: PyHandle PyAny -> Py π π ()
stash h = Control.do
  Ur () <- liftSystemIOU (writeIORef stashRef (Just h))
  Control.pure ()

-- | The stashed object, if any.
stashed :: Py π π (Maybe (PyHandle PyAny))
stashed = Control.do
  Ur m <- liftSystemIOU (readIORef stashRef)
  Control.pure m

-- | Drop the stashed handle; its +1 goes through the deferred release pool.
unstash :: Py π π ()
unstash = Control.do
  Ur () <- liftSystemIOU (writeIORef stashRef Nothing)
  Control.pure ()

{- | Run a major Haskell collection and let the finaliser thread push dead
handles onto the pool; the next call drains it.
-}
haskellGc :: Py π π ()
haskellGc = Control.do
  Ur () <- liftSystemIOU (performMajorGC P.>> threadDelay 20000 P.>> performMajorGC P.>> threadDelay 20000)
  Control.pure ()

-- | A call that does nothing: one trampoline entry, one pool drain.
noop :: Py π π ()
noop = Control.pure ()

-- * Errors in both directions

-- | A @Left@ with @ValueError@.
failValueError :: Py π π (PyResult ())
failValueError = pyFail (pyErr (Proxy @ValueError) "bad value")

-- | A @Left@ with @TypeError@.
failTypeError :: Py π π (PyResult Int)
failTypeError = pyFail (pyErr (Proxy @TypeError) "bad type")

-- | A Haskell 'error': @RuntimeError@ in Python.
haskellError :: Py π π Int
haskellError = P.error "boom from haskell"

-- | Use the argument, then raise a Haskell error: the argument's count is unchanged afterwards.
useThenError :: Borrowed π PyAny -> Py π π Int
useThenError o = Control.do
  r <- repr o
  failAfter r

failAfter :: PyResult Text %1 -> Py π π Int
failAfter r = consume r `lseq` P.error "boom after using the argument"

-- | Mutate the argument through its handle, then raise a Haskell error: the mutation stays, the count does not change.
useMutThenError :: Bound π PyAny %1 -> Text -> Borrowed π PyAny -> Py π π Int
useMutThenError o name v = Control.do
  (r, o') <- setAttr o name v
  failAfterMut o' r

failAfterMut :: Bound π PyAny %1 -> PyResult () %1 -> Py π π Int
failAfterMut o r = consume o `lseq` consume r `lseq` P.error "boom after mutating the argument"

-- | 'orThrow' on a @Left@: an abort that Python sees as the error.
throwOnLeft :: Py π π Int
throwOnLeft = orThrow (Left (pyErr (Proxy @ValueError) "thrown by orThrow"))

-- | A @KeyError@ materialised with 'toObject', read back with 'fromObject', and returned as a @Left@.
keyErrorRoundtrip :: Py π π (PyResult ())
keyErrorRoundtrip = Control.do
  robj <- toObject (pyErr (Proxy @KeyError) "missing")
  raiseMaterialised robj

raiseMaterialised :: PyResult (Bound π PyBaseException) %1 -> Py π π (PyResult ())
raiseMaterialised (Left e) = Control.pure (Left e)
raiseMaterialised (Right obj) = case share obj of
  Ur v -> Control.do
    Ur e <- Control.fmap move (fromObject v)
    pyFail e

-- * The Cell class

newtype Cell = Cell (Ref Int)
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & classDoc "A cell whose integer lives in a Haskell Ref.") ''Cell

newCell :: Int -> Py π π (PyResult (Bound π Cell))
newCell n = Control.do
  ref <- asksLinearly (Ref.new n)
  newObject (Cell ref)

cellGet :: Share π Cell -> Py π π Int
cellGet c = RefB.copyRef (coerceShare @(Ref Int) c)

cellIncr :: forall π. Mut π Cell %1 -> Int -> Py π π ()
cellIncr c k = Control.do
  ref <- RefB.modify (+ k) (upcast c :: Mut π (Ref Int))
  Control.pure (consume ref)

-- | Mutate, then answer @Left@: the object stays usable, and the mutation stays.
cellIncrThenFail :: forall π. Mut π Cell %1 -> Int -> Py π π (PyResult ())
cellIncrThenFail c k = Control.do
  ref <- RefB.modify (+ k) (upcast c :: Mut π (Ref Int))
  Control.pure (consume ref `lseq` Left (pyErr (Proxy @ValueError) "failed after mutating"))

-- | A Haskell error while the payload is held mutably: the object is poisoned.
cellPoison :: Mut π Cell %1 -> Py π π ()
cellPoison c = consume c `lseq` P.error "poisoning the cell"

-- | Read two payloads at once: two shared holds, on the same object or on two.
cellSumWith :: forall π. Share π Cell -> Borrowed π Cell -> Py π π (PyResult Int)
cellSumWith self other = Control.do
  Ur a <- Control.fmap move (RefB.copyRef (coerceShare @(Ref Int) self))
  rother <- derefShare other
  sumOther a rother

sumOther :: forall π. Int -> PyResult (Ur (Share π Cell)) %1 -> Py π π (PyResult Int)
sumOther _ (Left e) = Control.pure (Left e)
sumOther a (Right (Ur o)) = Control.do
  Ur b <- Control.fmap move (RefB.copyRef (coerceShare @(Ref Int) o))
  Control.pure (Right (a + b))

-- | An explicit Bound receiver, returned as the result.
cellIdentity :: Bound π Cell %1 -> Py π π (Bound π Cell)
cellIdentity = Control.pure

{- | Call @f()@ while the payload is held mutably, then add one.
A callback that reaches this cell's payload again, through any of its
methods, gets @busy@: the lend state doing PyO3's @BorrowMutError@ job.
-}
cellCallWhileHeld :: forall π. Mut π Cell %1 -> Borrowed π PyAny -> Py π π (PyResult (Bound π PyAny))
cellCallWhileHeld c f = Control.do
  r <- call0 f
  afterCallback c r

afterCallback :: forall π. Mut π Cell %1 -> PyResult (Bound π PyAny) %1 -> Py π π (PyResult (Bound π PyAny))
afterCallback c (Left e) = Control.pure (consume c `lseq` Left e)
afterCallback c (Right o) = Control.do
  ref <- RefB.modify (+ 1) (upcast c :: Mut π (Ref Int))
  Control.pure (consume ref `lseq` Right o)

{- | Dereference a second handle mutably while the receiver is held: @busy@
when it is the same object, the sum of both values when it is another.
-}
cellDerefSecond :: forall π. Mut π Cell %1 -> Bound π Cell %1 -> Py π π (PyResult Int)
cellDerefSecond self other = Control.do
  r <- derefMut other
  sumMut self r

sumMut :: forall π. Mut π Cell %1 -> PyResult (Mut π Cell) %1 -> Py π π (PyResult Int)
sumMut self (Left e) = Control.pure (consume self `lseq` Left e)
sumMut self (Right o) = Control.do
  Ur a <- Control.fmap move (RefB.copyRef (upcast self :: Mut π (Ref Int)))
  Ur b <- Control.fmap move (RefB.copyRef (upcast o :: Mut π (Ref Int)))
  Control.pure (Right (a + b))

{- | Hold the payload mutably in a detached body that 'timeout' interrupts
after the given number of seconds: the asynchronous @Timeout@ cuts the wait
short, and the Haskell error that follows leaves the call as an exception,
which poisons the cell.
-}
cellHoldUntilTimeout :: forall π. Mut π Cell %1 -> Double -> BIO π Int
cellHoldUntilTimeout c seconds = Control.do
  Ur r <- liftSystemIOU (timeout (micros seconds) (threadDelay 5000000))
  finishHold c r

finishHold :: Mut π Cell %1 -> Maybe () -> BIO π Int
finishHold c Nothing = consume c `lseq` P.error "the hold was interrupted by a timeout"
finishHold c (Just ()) = Control.pure (consume c `lseq` 0)

{- | Hold the payload mutably in a detached body while another Haskell thread
delivers an asynchronous exception to this one after the given number of
seconds: the exit is asynchronous all the way to the trampoline, and the cell
is poisoned.
-}
cellHoldUntilKilled :: forall π. Mut π Cell %1 -> Double -> BIO π Int
cellHoldUntilKilled c seconds = Control.do
  Ur () <- liftSystemIOU (killMeAfter (micros seconds))
  Control.pure (consume c `lseq` 0)

killMeAfter :: Int -> P.IO ()
killMeAfter delay = do
  me <- myThreadId
  _ <- forkIO (threadDelay delay P.>> throwTo me (ErrorCall "killed while holding the payload"))
  threadDelay 5000000

micros :: Double -> Int
micros seconds = max 0 (round (seconds * 1e6))

{- | Dereference the cell mutably through a fresh handle inside @attach'_@,
add one there, and dereference the receiver itself once the scope has ended:
the inner hold belongs to the inner arena and is released with it, so the
second dereference succeeds and answers the new value.
-}
cellScopedHold :: forall π. Bound π Cell %1 -> Py π π (PyResult Int)
cellScopedHold self = Control.do
  (r, self') <- sharing self scopedBump
  afterScope self' r

scopedBump :: forall β π. Borrowed (β /\ π) Cell -> Py π (β /\ π) (PyResult ())
scopedBump v = Control.do
  Ur h <- toHandle v
  attach'_ (bumpThrough h)

-- | Take a fresh handle in the current arena and add one through it.
bumpThrough :: forall π γ. (π >= γ) => PyHandle Cell -> Py π γ (PyResult ())
bumpThrough h = Control.do
  b <- fromHandle h
  r <- derefMut b
  bump r

bump :: forall π γ. PyResult (Mut γ Cell) %1 -> Py π γ (PyResult ())
bump (Left e) = Control.pure (Left e)
bump (Right m) = Control.do
  m' <- RefB.modify (+ 1) (upcast m :: Mut γ (Ref Int))
  Control.pure (consume m' `lseq` Right ())

afterScope :: forall π. Bound π Cell %1 -> PyResult () %1 -> Py π π (PyResult Int)
afterScope self (Left e) = Control.pure (consume self `lseq` Left e)
afterScope self (Right ()) = Control.do
  r <- derefMut self
  readMut r

readMut :: forall π. PyResult (Mut π Cell) %1 -> Py π π (PyResult Int)
readMut (Left e) = Control.pure (Left e)
readMut (Right m) = Control.fmap Right (RefB.copyRef (upcast m :: Mut π (Ref Int)))

pymethods
  ''Cell
  [ constructor 'newCell & param 0 "n"
  , method "get" 'cellGet & doc "The current value."
  , method "incr" 'cellIncr & param 0 "k" & doc "Add k."
  , method "incr_then_fail" 'cellIncrThenFail & param 0 "k" & doc "Add k, then fail with ValueError; the cell stays usable."
  , method "poison" 'cellPoison & doc "Raise a Haskell error while the payload is held mutably: poisons the cell."
  , method "sum_with" 'cellSumWith & param 0 "other" & doc "The sum of this cell and another."
  , method "identity" 'cellIdentity & doc "Return self."
  , method "call_while_held" 'cellCallWhileHeld & param 0 "f" & doc "Call f() while the payload is held mutably, then add one."
  , method "deref_second" 'cellDerefSecond & param 0 "other" & doc "Dereference another handle mutably while this payload is held."
  , method "hold_until_timeout" 'cellHoldUntilTimeout & param 0 "seconds" & doc "Hold the payload detached until a timeout interrupts the wait: poisons the cell."
  , method "hold_until_killed" 'cellHoldUntilKilled & param 0 "seconds" & doc "Hold the payload detached until an asynchronous exception arrives: poisons the cell."
  , method "scoped_hold" 'cellScopedHold & doc "Add one inside an attach'_ scope, then read through the receiver after it."
  ]

-- * A class that no module registers

-- | Declared with @pyclass@ and @pymethods@, but listed in no @pymodule@.
newtype Ghost = Ghost (Ref Int)
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & classDoc "A class that no module registers.") ''Ghost

pymethods ''Ghost []

-- | An argument typed by an unregistered class: the type check cannot run, and says so.
ghostArg :: Bound π Ghost %1 -> Py π π ()
ghostArg g = Control.pure (consume g)

-- | An instance of an unregistered class: 'newObject' answers the error as a value.
makeGhost :: Py π π (PyResult (Bound π Ghost))
makeGhost = Control.do
  ref <- asksLinearly (Ref.new 0)
  newObject (Ghost ref)

-- * A hand-written instance without the sealed witness

{- | A payload whose 'PyClass' instance is written by hand, outside the
trusted modules, so that @pyClassSealed@ has no definition: GHC accepts the
instance with a warning, and the first operation that trusts it fails with
@No instance nor default method@ rather than treating the class as sealed.
-}
newtype Unsealed = Unsealed (Ref Int)
  deriving newtype (Consumable)

instance PyClass Unsealed where
  pyClassName _ = "Unsealed"
  pyClassTypeCell _ = unsealedCell

unsealedCell :: TypeCell
unsealedCell = unsafeNewTypeCell
{-# NOINLINE unsealedCell #-}

-- | Construct an 'Unsealed': the missing witness is forced before anything else.
makeUnsealed :: Py π π ()
makeUnsealed = Control.do
  ref <- asksLinearly (Ref.new 0)
  r <- newObject (Unsealed ref)
  Control.pure (dropResult r)

-- | Drop a reference or an error: both are affine.
dropResult :: PyResult (Bound π t) %1 -> ()
dropResult (Left e) = consume e
dropResult (Right b) = consume b

-- * A subclassable class whose constructor constructs

-- | A helper object made inside another class's constructor.
newtype Helper = Helper (Ref Int)
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & classDoc "A helper made inside another constructor.") ''Helper

helperValue :: Share π Helper -> Py π π Int
helperValue h = RefB.copyRef (coerceShare @(Ref Int) h)

pymethods
  ''Helper
  [method "value" 'helperValue & doc "The value the helper was made with."]

{- | A subclassable class whose constructor makes two 'Helper' objects, one in
the call's arena and one inside an @attach'_@ scope, and keeps their handles.
The type being constructed, recorded in the arena for a Python subclass,
applies to the 'Base' allocation alone: each helper is a 'Helper'.
-}
newtype Base = Base (Ref (Ur (PyHandle Helper, PyHandle Helper)))
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & subclassable & classDoc "A subclassable class whose constructor makes helpers.") ''Base

newBase :: forall π. Py π π (PyResult (Bound π Base))
newBase = Control.do
  r1 <- newHelper 1
  r2 <- attach'_ (newHelper 2)
  buildBase r1 r2

-- | A new 'Helper' in the current arena, handed out as a handle.
newHelper :: forall π. Int -> Py π π (PyResult (Ur (PyHandle Helper)))
newHelper n = Control.do
  ref <- asksLinearly (Ref.new n)
  r <- newObject (Helper ref)
  handleOfHelper r

handleOfHelper :: PyResult (Bound π Helper) %1 -> Py π π (PyResult (Ur (PyHandle Helper)))
handleOfHelper (Left e) = Control.pure (Left e)
handleOfHelper (Right b) = case share b of
  Ur v -> Control.fmap Right (toHandle v)

buildBase :: PyResult (Ur (PyHandle Helper)) %1 -> PyResult (Ur (PyHandle Helper)) %1 -> Py π π (PyResult (Bound π Base))
buildBase (Left e) r2 = Control.pure (consume r2 `lseq` Left e)
buildBase (Right (Ur _)) (Left e) = Control.pure (Left e)
buildBase (Right (Ur h1)) (Right (Ur h2)) = Control.do
  ref <- asksLinearly (Ref.new (Ur (h1, h2)))
  newObject (Base ref)

-- | The helper made in the constructor's own arena.
baseHelper :: Share π Base -> Py π π (PyHandle Helper)
baseHelper b = Control.fmap (\(Ur (h, _)) -> h) (RefB.copyRef (coerceShare @(Ref (Ur (PyHandle Helper, PyHandle Helper))) b))

-- | The helper made inside the constructor's @attach'_@ scope.
baseScopedHelper :: Share π Base -> Py π π (PyHandle Helper)
baseScopedHelper b = Control.fmap (\(Ur (_, h)) -> h) (RefB.copyRef (coerceShare @(Ref (Ur (PyHandle Helper, PyHandle Helper))) b))

pymethods
  ''Base
  [ constructor 'newBase
  , method "helper" 'baseHelper & doc "The helper made in the constructor's arena."
  , method "scoped_helper" 'baseScopedHelper & doc "The helper made inside an attach'_ scope of the constructor."
  ]

-- | The @ops@ submodule.
opsModule :: ModuleSpec
opsModule =
  submodule
    "ops"
    [ fn "get_attr" 'getAttrOp & param 0 "o" & param 1 "name"
    , fn "set_attr" 'setAttrOp & param 0 "o" & param 1 "name" & param 2 "v"
    , fn "get_item" 'getItemOp & param 0 "o" & param 1 "k"
    , fn "set_item" 'setItemOp & param 0 "o" & param 1 "k" & param 2 "v"
    , fn "del_item" 'delItemOp & param 0 "o" & param 1 "k"
    , fn "length" 'lengthOp & param 0 "o"
    , fn "repr_" 'reprOp & param 0 "o"
    , fn "str_" 'strOp & param 0 "o"
    , fn "call" 'callOp & param 0 "f" & param 1 "args"
    , fn "iterate_sum" 'iterateSum & param 0 "iterable"
    , fn "hash_" 'hashOp & param 0 "o"
    , fn "equals" 'equalsOp & param 0 "a" & param 1 "b"
    , fn "downcast_int" 'downcastInt & param 0 "o"
    , fn "roundtrip_int" 'roundtripInt
    , fn "roundtrip_integer" 'roundtripInteger
    , fn "roundtrip_word" 'roundtripWord
    , fn "roundtrip_double" 'roundtripDouble
    , fn "roundtrip_float" 'roundtripFloat
    , fn "roundtrip_bool" 'roundtripBool
    , fn "roundtrip_char" 'roundtripChar
    , fn "roundtrip_text" 'roundtripText
    , fn "roundtrip_string" 'roundtripString
    , fn "roundtrip_bytes" 'roundtripBytes
    , fn "roundtrip_unit" 'roundtripUnit
    , fn "roundtrip_maybe_int" 'roundtripMaybeInt
    , fn "roundtrip_either_int_text" 'roundtripEitherIntText
    , fn "roundtrip_int_list" 'roundtripIntList
    , fn "roundtrip_double_vector" 'roundtripDoubleVector
    , fn "map_items" 'mapItems
    , fn "set_items" 'setItems
    , fn "roundtrip_tuple2" 'roundtripTuple2
    , fn "roundtrip_tuple3" 'roundtripTuple3
    , fn "roundtrip_tuple4" 'roundtripTuple4
    , fn "roundtrip_tuple5" 'roundtripTuple5
    , fn "big_integer" 'bigInteger
    , fn "stash" 'stash & param 0 "o"
    , fn "stashed" 'stashed
    , fn "unstash" 'unstash
    , fn "haskell_gc" 'haskellGc
    , fn "noop" 'noop
    , fn "fail_value_error" 'failValueError
    , fn "fail_type_error" 'failTypeError
    , fn "haskell_error" 'haskellError
    , fn "use_then_error" 'useThenError & param 0 "o"
    , fn "use_mut_then_error" 'useMutThenError & param 0 "o" & param 1 "name" & param 2 "v"
    , fn "throw_on_left" 'throwOnLeft
    , fn "key_error_roundtrip" 'keyErrorRoundtrip
    , fn "has_attr" 'hasAttrOp & param 0 "o" & param 1 "name"
    , fn "del_attr" 'delAttrOp & param 0 "o" & param 1 "name"
    , fn "get_index" 'getIndexOp & param 0 "o" & param 1 "i"
    , fn "is_true" 'isTrueOp & param 0 "o"
    , fn "call0" 'call0Op & param 0 "f"
    , fn "call_method" 'callMethodOp & param 0 "o" & param 1 "name" & param 2 "args"
    , fn "call_method0" 'callMethod0Op & param 0 "o" & param 1 "name"
    , fn "rich_compare" 'richCompareOp & param 0 "a" & param 1 "op" & param 2 "b"
    , fn "type_of" 'typeOfOp & param 0 "o"
    , fn "downcast_mut_int" 'downcastMutInt & param 0 "o"
    , fn "list_append" 'listAppendOp & param 0 "lst" & param 1 "v"
    , fn "set_add" 'setAddOp & param 0 "s" & param 1 "v"
    , fn "to_str" 'toStrOp
    , fn "to_bytes" 'toBytesOp
    , fn "to_int" 'toIntOp
    , fn "to_integer" 'toIntegerOp
    , fn "to_float" 'toFloatOp
    , fn "to_bool" 'toBoolOp
    , fn "none_" 'noneOp
    , fn "to_list" 'toListOp & param 0 "iterable"
    , fn "to_tuple" 'toTupleOp & param 0 "iterable"
    , fn "empty_tuple" 'emptyTupleOp
    , fn "to_dict" 'toDictOp & param 0 "pairs"
    , fn "to_set" 'toSetOp & param 0 "iterable"
    , fn "new_dict" 'newDictOp
    , fn "new_list" 'newListOp
    , fn "copy_out_int" 'copyOutInt
    , fn "copy_out_float" 'copyOutFloat
    , fn "copy_out_bool" 'copyOutBool
    , fn "copy_out_str" 'copyOutStr
    , fn "copy_out_bytes" 'copyOutBytes
    , fn "copy_out_none" 'copyOutNone
    , fn "handle_roundtrip" 'handleRoundtrip & param 0 "o"
    , fn "ghost_arg" 'ghostArg & param 0 "g" & hint 0 "Any" & doc "Takes an instance of the unregistered Ghost class."
    , fn "make_ghost" 'makeGhost & resultAs "Any" & doc "Construct an instance of the unregistered Ghost class."
    , fn "make_unsealed" 'makeUnsealed & doc "Construct an instance of a class whose hand-written instance lacks the sealed witness."
    ]
    [''Cell, ''Helper, ''Base]
