{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- |
The @shapes@ submodule: every protocol slot of section 5.12 of the design, a
frozen class, a class that extends another, a subclassable class, and a
class-owned buffer.

* 'Vec2' is frozen: its slots and methods receive the payload by value.
* 'Stack' has the container protocols, iteration through 'HsIterator', a call
  slot, a context manager, comparisons, and the number protocol in place.
* 'Samples' exports its own storage through the buffer protocol.
* 'Named' is subclassable from Python and extended by 'Child' from Haskell.

A slot body may answer its result plain or in a 'PyResult', as a method may:
'stackGet' and 'stackCompare' use the 'PyResult' form, since they can fail,
while 'stackNext', 'stackExit', 'samplesCompare', 'samplesIMul' and
'samplesExit' use the plain form.
-}
module H2Py.Examples.Shapes (
  Vec2 (..),
  Stack (..),
  Samples (..),
  Named (..),
  Child (..),
  h2py_class_Vec2,
  h2py_class_Stack,
  h2py_class_Samples,
  h2py_class_Named,
  h2py_class_Child,
) where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.Pure
import Data.List qualified as L
import Data.Proxy (Proxy (..))
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Data.Ref.Linear.Borrow qualified as RefB
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector.Generic.Mutable.Linear.Borrow.Unrestricted qualified as UV
import H2Py
import Prelude.Linear
import Prelude qualified as P

-- * Vec2: a frozen class with the number protocol

-- | An immutable vector, moved into GC ownership at construction.
data Vec2 = Vec2 Double Double

instance Consumable Vec2 where
  consume v = case move v of
    Ur _ -> ()

instance Dupable Vec2 where
  dup2 v = case move v of
    Ur (Vec2 x y) -> (Vec2 x y, Vec2 x y)

instance Movable Vec2 where
  move (Vec2 x y) = case (move x, move y) of
    (Ur x', Ur y') -> Ur (Vec2 x' y')

pyclassWith (defaultClassSpec & frozen & classDoc "A frozen two-dimensional vector.") ''Vec2

newVec2 :: Double -> Double -> Py π π (PyResult (Bound π Vec2))
newVec2 x y = newFrozenObject (Vec2 x y)

vecX :: Vec2 -> Py π π Double
vecX (Vec2 x _) = Control.pure x

vecY :: Vec2 -> Py π π Double
vecY (Vec2 _ y) = Control.pure y

vecRepr :: Vec2 -> Py π π Text
vecRepr (Vec2 x y) = Control.pure (Text.pack ("Vec2(" <> show x <> ", " <> show y <> ")"))

vecHash :: Vec2 -> Py π π Int
vecHash (Vec2 x y) = Control.pure (P.truncate (x * 1000003) + 31 * P.truncate y)

-- | Scale by a factor: @v(k)@, a by-value receiver on a @__call__@ slot.
vecCall :: Vec2 -> Double -> Py π π (PyResult (Bound π Vec2))
vecCall (Vec2 x y) k = newFrozenObject (Vec2 (x * k) (y * k))

-- | Read a frozen result by value.
moved :: (Movable a) => PyResult a %1 -> PyResult (Ur a)
moved (Left e) = Left e
moved (Right a) = Right (move a)

-- | Continue with the other operand when it is a 'Vec2', else @NotImplemented@.
withVec :: Borrowed π PyAny -> (Vec2 -> Py π π (PyResult (Maybe (Bound π PyAny)))) -> Py π π (PyResult (Maybe (Bound π PyAny)))
withVec other k = Control.do
  Ur mo <- downcast @Vec2 other
  case mo of
    Nothing -> Control.pure (Right Nothing)
    Just o -> Control.do
      r <- readFrozen o
      continueVec (moved r) k

continueVec :: PyResult (Ur Vec2) %1 -> (Vec2 -> Py π π (PyResult (Maybe (Bound π PyAny)))) -> Py π π (PyResult (Maybe (Bound π PyAny)))
continueVec (Left e) _ = Control.pure (Left e)
continueVec (Right (Ur w)) k = k w

newVec :: Vec2 -> Py π π (PyResult (Maybe (Bound π PyAny)))
newVec v = Control.fmap (mapResult (\b -> Just (asAnyMut b))) (newFrozenObject v)

vecAdd :: Vec2 -> Borrowed π PyAny -> Py π π (PyResult (Maybe (Bound π PyAny)))
vecAdd (Vec2 x y) other = withVec other \(Vec2 x' y') -> newVec (Vec2 (x + x') (y + y'))

vecSub :: Vec2 -> Borrowed π PyAny -> Py π π (PyResult (Maybe (Bound π PyAny)))
vecSub (Vec2 x y) other = withVec other \(Vec2 x' y') -> newVec (Vec2 (x - x') (y - y'))

-- | Multiplication by a scalar, on either side; a non-numeric operand yields @NotImplemented@.
vecMul :: Vec2 -> Borrowed π PyAny -> Py π π (PyResult (Maybe (Bound π PyAny)))
vecMul v other = Control.do
  rk <- fromPy @(Ur Double) other
  scaleVec v rk

scaleVec :: Vec2 -> PyResult (Ur Double) %1 -> Py π π (PyResult (Maybe (Bound π PyAny)))
scaleVec _ (Left e) = consume e `lseq` Control.pure (Right Nothing)
scaleVec (Vec2 x y) (Right (Ur k)) = newVec (Vec2 (x * k) (y * k))

vecNeg :: Vec2 -> Py π π (PyResult (Bound π PyAny))
vecNeg (Vec2 x y) = Control.fmap (mapResult asAnyMut) (newFrozenObject (Vec2 (negate x) (negate y)))

vecAbs :: Vec2 -> Py π π (PyResult (Bound π PyAny))
vecAbs (Vec2 x y) = toPy (sqrt (x * x + y * y))

vecOps :: NumberOps Vec2
vecOps =
  noNumberOps
    { nbAdd = Just (BinaryOp vecAdd)
    , nbSub = Just (BinaryOp vecSub)
    , nbMul = Just (BinaryOp vecMul)
    , nbRMul = Just (BinaryOp vecMul)
    , nbNeg = Just (UnaryOp vecNeg)
    , nbAbs = Just (UnaryOp vecAbs)
    }

vecCompare :: Vec2 -> Borrowed π PyAny -> CompareOp -> Py π π (PyResult (Maybe Bool))
vecCompare v other op = Control.do
  Ur mo <- downcast @Vec2 other
  case mo of
    Nothing -> Control.pure (Right Nothing)
    Just o -> Control.do
      r <- readFrozen o
      Control.pure (compareVec v op (moved r))

compareVec :: Vec2 -> CompareOp -> PyResult (Ur Vec2) %1 -> PyResult (Maybe Bool)
compareVec _ _ (Left e) = Left e
compareVec (Vec2 x y) op (Right (Ur (Vec2 x' y'))) = case op of
  Eq -> Right (Just (x == x' && y == y'))
  Ne -> Right (Just (x /= x' || y /= y'))
  _ -> Right Nothing

pymethods
  ''Vec2
  [ constructor 'newVec2 & param 0 "x" & param 1 "y"
  , method "x" 'vecX
  , method "y" 'vecY
  , slot 'Repr 'vecRepr
  , slot 'Hash 'vecHash
  , slot 'Compare 'vecCompare
  , slot 'Number 'vecOps
  , slot 'Call 'vecCall & param 0 "k" & doc "Scale the vector."
  ]

-- * Stack: containers, iteration, calls, context managers

-- | A stack of integers whose state lives in the Haskell heap.
newtype Stack = Stack (Ref (Ur [Int]))
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & abc "collections.abc.Sized" & classDoc "A stack of integers.") ''Stack

newStack :: [Int] -> Py π π (PyResult (Bound π Stack))
newStack xs = Control.do
  ref <- asksLinearly (Ref.new (Ur xs))
  newObject (Stack ref)

-- | The items, top first.
items :: Share π Stack -> Py π π (Ur [Int])
items s = RefB.copyRef (coerceShare @(Ref (Ur [Int])) s)

-- | Replace the items in place.
modifyItems :: forall π. ([Int] -> [Int]) -> Mut π Stack %1 -> Py π π ()
modifyItems f st = Control.do
  ref <- RefB.modify (\(Ur xs) -> Ur (f xs)) (upcast st :: Mut π (Ref (Ur [Int])))
  Control.pure (consume ref)

-- | Replace the items in place and answer something about them.
updateItems :: forall π r. ([Int] -> (r, [Int])) -> Mut π Stack %1 -> Py π π r
updateItems f st = Control.do
  (r, ref) <- RefB.update (\(Ur xs) -> case f xs of (r, ys) -> Control.pure (r, Ur ys)) (upcast st :: Mut π (Ref (Ur [Int])))
  Control.pure (consume ref `lseq` r)

indexError :: Text -> PyErr
indexError = pyErr (Proxy @IndexError)

-- | Normalise a Python index, negative from the end.
normalise :: Int -> Int -> Maybe Int
normalise n i
  | i < 0 && i + n >= 0 = Just (i + n)
  | i >= 0 && i < n = Just i
  | P.otherwise = Nothing

stackPush :: Mut π Stack %1 -> Int -> Py π π ()
stackPush st x = modifyItems (x :) st

stackPop :: Mut π Stack %1 -> Py π π (PyResult Int)
stackPop = updateItems \case
  [] -> (Left (indexError "pop from an empty Stack"), [])
  (x : xs) -> (Right x, xs)

stackLen :: Share π Stack -> Py π π Int
stackLen s = Control.fmap (\(Ur xs) -> L.length xs) (items s)

stackBool :: Share π Stack -> Py π π Bool
stackBool s = Control.fmap (\(Ur xs) -> P.not (L.null xs)) (items s)

stackGet :: Share π Stack -> Int -> Py π π (PyResult Int)
stackGet s i = Control.fmap (\(Ur xs) -> P.maybe (Left (indexError "Stack index out of range")) (\j -> Right (xs L.!! j)) (normalise (L.length xs) i)) (items s)

stackSet :: Mut π Stack %1 -> Int -> Int -> Py π π (PyResult ())
stackSet st i v =
  updateItems
    ( \xs -> case normalise (L.length xs) i of
        Nothing -> (Left (indexError "Stack assignment index out of range"), xs)
        Just j -> (Right (), L.take j xs <> [v] <> L.drop (j + 1) xs)
    )
    st

stackDel :: Mut π Stack %1 -> Int -> Py π π (PyResult ())
stackDel st i =
  updateItems
    ( \xs -> case normalise (L.length xs) i of
        Nothing -> (Left (indexError "Stack deletion index out of range"), xs)
        Just j -> (Right (), L.take j xs <> L.drop (j + 1) xs)
    )
    st

stackContains :: Share π Stack -> Int -> Py π π Bool
stackContains s x = Control.fmap (\(Ur xs) -> L.elem x xs) (items s)

-- | Iterate over a snapshot of the items.
stackIter :: Share π Stack -> Py π π (PyResult (Bound π HsIterator))
stackIter s = Control.do
  Ur xs <- items s
  iterFromList xs

{- | Iterate over the live object: the iterator holds a handle, and each step
dereferences it afresh, so a push between two steps is seen.
-}
stackLive :: Borrowed π Stack -> Py π π (PyResult (Bound π HsIterator))
stackLive self = Control.do
  Ur h <- toHandle self
  iterFromStep (Ur (h, 0 :: Int)) liveStep

liveStep :: forall π. Ur (PyHandle Stack, Int) %1 -> Py π π (PyResult (Maybe (Bound π PyAny)), Ur (PyHandle Stack, Int))
liveStep (Ur (h, i)) = Control.do
  Ur v <- fromHandleShare h
  r <- derefShare v
  liveRead h i r

liveRead :: forall π. PyHandle Stack -> Int -> PyResult (Ur (Share π Stack)) %1 -> Py π π (PyResult (Maybe (Bound π PyAny)), Ur (PyHandle Stack, Int))
liveRead h i (Left e) = Control.pure (Left e, Ur (h, i))
liveRead h i (Right (Ur s)) = Control.do
  Ur xs <- items s
  case L.drop i xs of
    [] -> Control.pure (Right Nothing, Ur (h, i))
    (x : _) -> Control.do
      r <- toPy x
      Control.pure (mapResult Just r, Ur (h, i + 1))

stackRepr :: Share π Stack -> Py π π Text
stackRepr s = Control.fmap (\(Ur xs) -> Text.pack ("Stack(" <> show xs <> ")")) (items s)

-- | @s(x)@ pushes @x@ and answers the new size.
stackCall :: Mut π Stack %1 -> Int -> Py π π Int
stackCall st x = updateItems (\xs -> (L.length xs + 1, x : xs)) st

stackEnter :: Bound π Stack %1 -> Py π π (PyResult (Bound π Stack))
stackEnter self = Control.pure (Right self)

-- | Leaving the block empties the stack, and a @ValueError@ raised inside is suppressed; a plain-form body.
stackExit :: Mut π Stack %1 -> Maybe (Borrowed π PyBaseException) -> Py π π Bool
stackExit st exc = Control.do
  modifyItems (P.const []) st
  case exc of
    Nothing -> Control.pure False
    Just e -> Control.do
      Ur err <- Control.fmap move (fromObject e)
      errorMatches (Proxy @ValueError) err

{- | @next(s)@ pops the top item, so a stack drains through the iterator
protocol as a queue of work does, and @StopIteration@ is raised once it is
empty; @iter(s)@ still answers a snapshot iterator through 'stackIter'.
A plain-form body: @Maybe Int@ without a 'PyResult'.
-}
stackNext :: Mut π Stack %1 -> Py π π (Maybe Int)
stackNext = updateItems \case
  [] -> (Nothing, [])
  (x : xs) -> (Just x, xs)

-- | Continue with the other operand's items when it is a 'Stack', else @NotImplemented@.
withStack :: Borrowed π PyAny -> ([Int] -> Py π π (PyResult (Maybe r))) -> Py π π (PyResult (Maybe r))
withStack other k = Control.do
  Ur mo <- downcast @Stack other
  case mo of
    Nothing -> Control.pure (Right Nothing)
    Just o -> Control.do
      r <- derefShare o
      continueStack r k

continueStack :: PyResult (Ur (Share π Stack)) %1 -> ([Int] -> Py π π (PyResult (Maybe r))) -> Py π π (PyResult (Maybe r))
continueStack (Left e) _ = Control.pure (Left e)
continueStack (Right (Ur s)) k = Control.do
  Ur xs <- items s
  k xs

stackCompare :: Share π Stack -> Borrowed π PyAny -> CompareOp -> Py π π (PyResult (Maybe Bool))
stackCompare s other op = Control.do
  Ur xs <- items s
  withStack other \ys -> Control.pure case op of
    Eq -> Right (Just (xs == ys))
    Ne -> Right (Just (xs /= ys))
    _ -> Right Nothing

-- | @s + t@: a new stack with the items of both.
stackAdd :: Share π Stack -> Borrowed π PyAny -> Py π π (PyResult (Maybe (Bound π PyAny)))
stackAdd s other = Control.do
  Ur xs <- items s
  withStack other \ys -> Control.fmap (mapResult (\b -> Just (asAnyMut b))) (newStack (xs <> ys))

-- | @s += t@: extend in place; @s += s@ answers @busy@, since the receiver is held mutably.
stackIAdd :: Mut π Stack %1 -> Borrowed π PyAny -> Py π π (PyResult (Maybe ()))
stackIAdd st other = Control.do
  Ur mo <- downcast @Stack other
  case mo of
    Nothing -> Control.pure (consume st `lseq` Right Nothing)
    Just o -> Control.do
      r <- derefShare o
      extendWith st r

extendWith :: forall π. Mut π Stack %1 -> PyResult (Ur (Share π Stack)) %1 -> Py π π (PyResult (Maybe ()))
extendWith st (Left e) = Control.pure (consume st `lseq` Left e)
extendWith st (Right (Ur o)) = Control.do
  Ur ys <- items o
  modifyItems (\xs -> xs <> ys) st
  Control.pure (Right (Just ()))

stackOps :: NumberOps Stack
stackOps = noNumberOps {nbAdd = Just (BinaryOp stackAdd), nbIAdd = Just (InplaceOp stackIAdd)}

pymethods
  ''Stack
  [ constructor 'newStack & param 0 "items"
  , method "push" 'stackPush & param 0 "x" & doc "Push an item."
  , method "pop" 'stackPop & doc "Pop the top item; IndexError when empty."
  , method "live" 'stackLive & doc "An iterator over the live stack."
  , slot 'Len 'stackLen
  , slot 'Bool 'stackBool
  , slot 'GetItem 'stackGet
  , slot 'SetItem 'stackSet
  , slot 'DelItem 'stackDel
  , slot 'Contains 'stackContains
  , slot 'Iter 'stackIter
  , slot 'Next 'stackNext
  , slot 'Repr 'stackRepr
  , slot 'Call 'stackCall & param 0 "x"
  , slot 'Enter 'stackEnter
  , slot 'Exit 'stackExit
  , slot 'Compare 'stackCompare
  , slot 'Number 'stackOps
  ]

-- * Samples: a class-owned buffer

-- | Samples in a storable vector the class owns and exports through the buffer protocol.
newtype Samples = Samples (SVector Double)
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & classDoc "Samples exported through the buffer protocol.") ''Samples

newSamples :: [Double] -> Py π π (PyResult (Bound π Samples))
newSamples xs = Control.do
  v <- asksLinearly (UV.fromList xs)
  newObject (Samples v)

samplesBuffer :: Borrow bk α Samples %1 -> Borrow bk α (SVector Double)
samplesBuffer = upcast

-- | Multiply every sample in place; refused with @BufferError@ while a view is exported.
samplesScale :: forall π. Mut π Samples %1 -> Double -> Py π π ()
samplesScale s k = Control.do
  v <- scaleLoop 0 k (upcast s :: Mut π (SVector Double))
  Control.pure (consume v)

scaleLoop :: forall π. Int -> Double -> Mut π (SVector Double) %1 -> Py π π (Mut π (SVector Double))
scaleLoop i k v = case UV.size v of
  (Ur n, v') ->
    if i >= n
      then Control.pure v'
      else Control.do
        (Ur x, v'') <- UV.get i v'
        v''' <- UV.write i (x * k) v''
        scaleLoop (i + 1) k v'''

samplesTotal :: forall π. Share π Samples -> Py π π Double
samplesTotal s = sumLoop 0 0 (coerceShare @(SVector Double) s)

sumLoop :: forall π. Int -> Double -> Share π (SVector Double) %1 -> Py π π Double
sumLoop i acc v = case UV.size v of
  (Ur n, v') ->
    if i >= n
      then consume v' `lseq` Control.pure acc
      else Control.do
        (Ur x, v'') <- UV.get i v'
        sumLoop (i + 1) (acc + x) v''

samplesLen :: Share π Samples -> Py π π Int
samplesLen s = case UV.size (coerceShare @(SVector Double) s) of
  (Ur n, _) -> Control.pure n

-- | Only @__exit__@ is registered: @__enter__@ defaults to returning @self@; a plain-form body.
samplesExit :: Mut π Samples %1 -> Maybe (Borrowed π PyBaseException) -> Py π π Bool
samplesExit s _ = Control.pure (consume s `lseq` False)

{- | Order the total against a number, in the plain form: @Maybe Bool@
without a 'PyResult', where 'Nothing' for a non-numeric operand yields
@NotImplemented@.
Registering a comparison without a hash makes the class unhashable.
-}
samplesCompare :: Share π Samples -> Borrowed π PyAny -> CompareOp -> Py π π (Maybe Bool)
samplesCompare s other op = Control.do
  Ur total <- Control.fmap move (samplesTotal s)
  rk <- fromPy @(Ur Double) other
  Control.pure (compareTotal total op rk)

compareTotal :: Double -> CompareOp -> PyResult (Ur Double) %1 -> Maybe Bool
compareTotal _ _ (Left e) = consume e `lseq` Nothing
compareTotal t op (Right (Ur k)) = Just case op of
  Lt -> t < k
  Le -> t <= k
  Eq -> t == k
  Ne -> t /= k
  Gt -> t > k
  Ge -> t >= k

-- | @s *= k@ scales in place, in the plain form: 'Nothing' for a non-numeric operand yields @NotImplemented@.
samplesIMul :: forall π. Mut π Samples %1 -> Borrowed π PyAny -> Py π π (Maybe ())
samplesIMul s other = Control.do
  rk <- fromPy @(Ur Double) other
  scaleBy s rk

scaleBy :: forall π. Mut π Samples %1 -> PyResult (Ur Double) %1 -> Py π π (Maybe ())
scaleBy s (Left e) = consume e `lseq` Control.pure (consume s `lseq` Nothing)
scaleBy s (Right (Ur k)) = Control.do
  samplesScale s k
  Control.pure (Just ())

samplesOps :: NumberOps Samples
samplesOps = noNumberOps {nbIMul = Just (InplaceOp samplesIMul)}

pymethods
  ''Samples
  [ constructor 'newSamples & param 0 "values"
  , method "scale" 'samplesScale & param 0 "k" & doc "Multiply every sample in place."
  , method "total" 'samplesTotal
  , slot 'Len 'samplesLen
  , slot 'Buffer 'samplesBuffer
  , slot 'Exit 'samplesExit
  , slot 'Compare 'samplesCompare
  , slot 'Number 'samplesOps
  ]

-- * Named and Child: inheritance in both directions

-- | A named thing; subclassable from Python and extended by 'Child' from Haskell.
newtype Named = Named (Ref (Ur Text))
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & subclassable & classDoc "Something with a name.") ''Named

newNamed :: Text -> Py π π (PyResult (Bound π Named))
newNamed name = Control.do
  ref <- asksLinearly (Ref.new (Ur name))
  newObject (Named ref)

namedName :: Share π Named -> Py π π Text
namedName n = Control.fmap (\(Ur t) -> t) (RefB.copyRef (coerceShare @(Ref (Ur Text)) n))

namedRename :: forall π. Mut π Named %1 -> Text -> Py π π ()
namedRename n new = Control.do
  ref <- RefB.modify (\(Ur _) -> Ur new) (upcast n :: Mut π (Ref (Ur Text)))
  Control.pure (consume ref)

pymethods
  ''Named
  [ constructor 'newNamed & param 0 "name"
  , method "name" 'namedName
  , method "rename" 'namedRename & param 0 "name"
  ]

-- | A 'Named' with an age: the parent's payload and its own, each in its own cell.
newtype Child = Child (Ref (Ur Int))
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & extends ''Named & subclassable & classDoc "A named thing with an age.") ''Child

newChild :: Text -> Int -> Py π π (PyResult (Bound π Child))
newChild name age = Control.do
  nref <- asksLinearly (Ref.new (Ur name))
  aref <- asksLinearly (Ref.new (Ur age))
  newObjectWith (Named nref) (Child aref)

childAge :: Share π Child -> Py π π Int
childAge c = Control.fmap (\(Ur n) -> n) (RefB.copyRef (coerceShare @(Ref (Ur Int)) c))

-- | Both payloads at once: the parent's through 'super', the child's directly.
childDescribe :: Borrowed π Child -> Py π π (PyResult Text)
childDescribe self = Control.do
  rn <- derefShare (super self)
  rc <- derefShare self
  describeWith rn rc

describeWith :: PyResult (Ur (Share π Named)) %1 -> PyResult (Ur (Share π Child)) %1 -> Py π π (PyResult Text)
describeWith (Left e) rc = Control.pure (consume rc `lseq` Left e)
describeWith (Right (Ur _)) (Left e) = Control.pure (Left e)
describeWith (Right (Ur n)) (Right (Ur c)) = Control.do
  Ur name <- Control.fmap move (namedName n)
  Ur age <- Control.fmap move (childAge c)
  Control.pure (Right (Text.concat [name, " (", Text.pack (show age), ")"]))

-- | Rename through the parent's handle: 'superMut' and the parent's own method.
childRename :: Bound π Child %1 -> Text -> Py π π (PyResult ())
childRename self new = Control.do
  r <- derefMut (superMut self)
  renameWith r new

renameWith :: PyResult (Mut π Named) %1 -> Text -> Py π π (PyResult ())
renameWith (Left e) _ = Control.pure (Left e)
renameWith (Right n) new = Control.fmap Right (namedRename n new)

pymethods
  ''Child
  [ constructor 'newChild & param 0 "name" & param 1 "age"
  , method "age" 'childAge
  , method "describe" 'childDescribe
  , method "rename_via_super" 'childRename & param 0 "name"
  ]
