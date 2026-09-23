{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
The iterator class the library ships: a monomorphic class holding an
existential step state and a step function, so that an @__iter__@ slot can
answer a Python iterator without a class of its own.
See section 5.12 of the design.

A state that is a @'Bound' π t@ may be moved into an iterator; it is inert
there, since the step function is polymorphic in the ambient lifetime and can
therefore never use it.
An iterator over a class instance holds a 'H2Py.Object.PyHandle' to it, and
each step does 'H2Py.Object.fromHandleShare' and @derefShare@ afresh, so the
hold lasts one call and a mutation between calls is refused by the word, not by
a stale borrow.
-}
module H2Py.Class.Iterator (
  HsIterator,
  iterFromList,
  iterFromStep,
  hsIteratorRegistration,
) where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.BO (Mut, asksLinearly, upcast)
import Data.Proxy (Proxy (..))
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Data.Ref.Linear.Borrow qualified as RefB
import Data.Text (Text)
import H2Py.Class.Internal
import H2Py.Class.Slot
import H2Py.Convert.Internal
import H2Py.Module.Internal
import H2Py.Object.Internal
import H2Py.Py.Internal
import Prelude.Linear (Consumable (..), lseq)
import System.IO.Unsafe (unsafePerformIO)

-- | A step state with its step function; the state is consumed at exhaustion.
data IterStep where
  IterStep :: (Consumable s) => s %1 -> (forall π. s %1 -> Py π π (PyResult (Maybe (Bound π PyAny)), s)) -> IterStep

instance Consumable IterStep where
  consume (IterStep s _) = consume s

-- | The iterator class: its state is replaced in place at every @__next__@, and dropped once exhausted.
newtype HsIterator = HsIterator (Ref (Maybe IterStep))
  deriving newtype (Consumable)

hsIteratorCell :: TypeCell
hsIteratorCell = unsafePerformIO newTypeCell
{-# NOINLINE hsIteratorCell #-}

hsIteratorName :: Proxy HsIterator -> Text
hsIteratorName _ = "HsIterator"

-- The class is closed, which is the obligation of a hand-written instance.
instance PyClass HsIterator where
  pyClassName = hsIteratorName
  pyClassDoc _ = "An iterator whose state lives in the Haskell heap."
  pyClassTypeCell _ = hsIteratorCell
  pyClassSealed _ = UnsafeSealed

instance PyReceiver HsIterator Lent where
  receiverName = hsIteratorName
  receiverDoc = pyClassDoc
  receiverTypeCell = pyClassTypeCell
  withReceiver = withSharedPayload
  receiverDealloc _ = deallocPayload @HsIterator

instance PyTypeOf HsIterator where
  pyTypeOf _ = readTypeCell hsIteratorCell
  pyTypeName = hsIteratorName
  pyTypeSealed _ = UnsafeSealed

instance PyTypeHint HsIterator where
  pyTypeHint _ = TApply "Iterator" [TAny]

{- | An iterator from a state and a step, which answers the next object and
the state to continue from, or 'Nothing' at exhaustion, when the state is
consumed.
-}
iterFromStep :: forall s π γ. (Consumable s) => s %1 -> (forall π'. s %1 -> Py π' π' (PyResult (Maybe (Bound π' PyAny)), s)) -> Py π γ (PyResult (Bound π HsIterator))
iterFromStep s step = Control.do
  ref <- asksLinearly (Ref.new (Just (IterStep s step)))
  newObject (HsIterator ref)

-- | An iterator over a list of values, converted one at a time.
iterFromList :: forall v π γ. (ToPy v) => [v] -> Py π γ (PyResult (Bound π HsIterator))
iterFromList xs = iterFromStep xs stepList

stepList :: forall v π. (ToPy v) => [v] %1 -> Py π π (PyResult (Maybe (Bound π PyAny)), [v])
stepList [] = Control.pure (Right Nothing, [])
stepList (x : xs) = Control.do
  r <- toPy x
  Control.pure (mapResult Just r, xs)

-- | @__next__@: run the step on the stored state and store what it answers.
hsNext :: forall π. Mut π HsIterator %1 -> Py π π (PyResult (Maybe (Bound π PyAny)))
hsNext it = Control.do
  (r, it') <- RefB.update stepOnce (upcast it :: Mut π (Ref (Maybe IterStep)))
  Control.pure (consume it' `lseq` r)

stepOnce :: forall π. Maybe IterStep %1 -> Py π π (PyResult (Maybe (Bound π PyAny)), Maybe IterStep)
stepOnce Nothing = Control.pure (Right Nothing, Nothing)
stepOnce (Just (IterStep s step)) = Control.do
  (r, s') <- step s
  Control.pure (continueStep r s' step)

continueStep :: forall s π. (Consumable s) => PyResult (Maybe (Bound π PyAny)) %1 -> s %1 -> (forall π'. s %1 -> Py π' π' (PyResult (Maybe (Bound π' PyAny)), s)) -> (PyResult (Maybe (Bound π PyAny)), Maybe IterStep)
continueStep (Right Nothing) s' _ = consume s' `lseq` (Right Nothing, Nothing)
continueStep r s' step = (r, Just (IterStep s' step))

-- | The registration of the class, which @pymodule@ adds to every module.
hsIteratorRegistration :: IO ClassRegistration
hsIteratorRegistration = do
  next <- slotEntries (NextObject hsNext)
  finishClassRegistration
    ClassRegistration
      { classRegName = pyClassName (Proxy @HsIterator)
      , classRegDoc = pyClassDoc (Proxy @HsIterator)
      , classRegTypeCell = hsIteratorCell
      , classRegDealloc = deallocPayload @HsIterator
      , classRegConstructor = Nothing
      , classRegMethods = srMethods next
      , classRegSlots = srSlots next
      , classRegSlotDescs = srDescs next
      , classRegSubclassable = False
      , classRegBases = []
      , classRegAbcs = []
      , classRegBase = Nothing
      , classRegSetItem = Nothing
      , classRegDelItem = Nothing
      }
