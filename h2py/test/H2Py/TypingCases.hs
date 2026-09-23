{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeAbstractions #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -O0 #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors -Wno-deferred-out-of-scope-variables #-}

{- |
The escape attempts of section 8 of the design that GHC defers, one binding
per refusal, and the positive shapes of item 19 that must compile.

Every @bad*@ binding is ill-typed on purpose and compiled with deferred type
errors; "H2Py.TypingSpec" forces each one and inspects the diagnostic.
Every @allowed*@ binding is well-typed and only ever typechecked.
No binding here runs a @Py@ computation: a computation is a value, and the
deferred thunks throw before anything could reach the interpreter.
See Note [Forcing a deferred refusal].
-}
module H2Py.TypingCases (
  module H2Py.TypingCases,
) where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.BO (BIO, BO, Mut, Share, Static, borrow, borrowM, parBO, pureAfter, reborrowing, reborrowing_, share, sharing, splitPair, upcast, type (/\), type (>=))
import Control.Monad.Borrow.Clone (Clone (..))
import Control.Monad.Borrow.Copyable (Copyable (..), copyMut)
import Control.Monad.Borrow.IO (MonadIO (..), liftBO, runBIO_)
import Control.Monad.Borrow.Lifetime.Internal (type (<=) (..))
import Control.Monad.Borrow.Pure (After (..), asksLinearly, linearly, runBO_)
import Control.Monad.Borrow.Unsafe (unsafeLiftBIO)
import Data.Coerce (coerce)
import Data.Ref.Linear (Ref)
import Data.Ref.Linear.Borrow qualified as RefB
import Foreign.Ptr (nullPtr)
import H2Py.Buffer (BufferMut, BufferShare, SVector, withBufferMut)
import H2Py.Class.Internal (PyClass (..), TypeCell, derefMut, derefShare)
import H2Py.Exception (PyResult)
import H2Py.Module.Internal (PyCallable (..), ToResult (..), unsafeNewTypeCell)
import H2Py.Object
import H2Py.Object.Internal (unsafeBorrowedFromPtr, unsafeBoundFromPtr, unsafeRetagMut, unsafeRetagShare)
import H2Py.Py.Internal
import Prelude.Linear (Consumable (..), Ur (..), dup2, lseq, move)
import Prelude.Linear qualified as Linear
import System.IO.Linear qualified as LinearIO

{- Note [Forcing a deferred refusal]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A deferred type error is a thunk placed where the ill-typed expression was
checked, and 'evaluate' observes it only if evaluation reaches that thunk.
Three shapes need help.

An error inside a rank-2 body, as an escaping attachment is, sits inside the
body a delimiter receives, and the delimiters run nothing until the scope is
entered, which needs an interpreter.
The @*Forced@ variants below have the delimiters' types and evaluate the body
to weak head normal form before handing it over, so the thunk is reached and
nothing runs; the rank-2 type is the whole point, and it is unchanged.

An unsolved outlives constraint is a dictionary, and no operation of H2Py
ever looks inside one, so an operation refused for @π >= γ@ would evaluate
fine.
'forceOutlives' demands the same dictionary and shows its witness, whose leaf
is the deferred thunk; @op `demanding` forceOutlives@ keeps the operation's
own constraint first in the diagnostic.

A refusal that never reaches a runtime value at all, the 'Unsatisfiable'
@Forkable@ of @parBO@ and a 'Coercible' behind 'upcast', is checked at
compile time under @test/typing-fail@ instead.
-}

-- * Fixtures

-- | A payload class for the cases; a hand-written instance, so it carries the closedness obligation.
newtype Payload = Payload (Ref Int)
  deriving newtype (Consumable)

instance PyClass Payload where
  pyClassName _ = "Payload"
  pyClassTypeCell _ = payloadCell

payloadCell :: TypeCell
payloadCell = unsafeNewTypeCell
{-# NOINLINE payloadCell #-}

-- | A payload holding two independent parts, for the split-borrow shapes.
newtype Pair = Pair (Ref Int, Ref Int)
  deriving newtype (Consumable)

instance PyClass Pair where
  pyClassName _ = "Pair"
  pyClassTypeCell _ = pairCell

pairCell :: TypeCell
pairCell = unsafeNewTypeCell
{-# NOINLINE pairCell #-}

-- | A view that no operation ever reaches: the cases are only typechecked.
staleView :: forall π t. Borrowed π t
staleView = unsafeBorrowedFromPtr nullPtr

-- | The handle form of 'staleView'.
staleHandle :: forall π t. Bound π t
staleHandle = unsafeBoundFromPtr nullPtr

-- | Force the outlives evidence a refused operation needed; see Note [Forcing a deferred refusal].
forceOutlives :: forall α β. (α >= β) => ()
forceOutlives = length (show (witness @β @α)) `seq` ()

-- | @op `demanding` evidence@: the operation, evaluated only after the evidence.
demanding :: a -> () -> a
demanding a evidence = evidence `seq` a

-- ** Forced delimiters

-- | 'attach_' on a body forced first.
attachForced_ :: forall γ a. (forall π. Py π (π /\ γ) a) -> BIO γ a
attachForced_ body = body @Static `seq` attach_ body

-- | 'attach'' on a body forced first.
attachForced' :: forall π γ a. (forall π'. Py (π' /\ π) (π' /\ γ) (After π' a)) -> Py π γ a
attachForced' body = body @Static `seq` attach' body

-- | 'attach'_' on a body forced first.
attachForced'_ :: forall π γ a. (forall π'. Py (π' /\ π) (π' /\ γ) a) -> Py π γ a
attachForced'_ body = body @Static `seq` attach'_ body

-- | 'detach' on a body forced first.
detachForced :: forall π γ r. (forall δ. BIO (δ /\ γ) r) -> Py π γ r
detachForced body = body @Static `seq` detach body

-- | 'parPy' on branches forced first.
parPyForced :: forall π γ a b. (forall δ π'. Py π' (π' /\ (δ /\ γ)) a) -> (forall δ π'. Py π' (π' /\ (δ /\ γ)) b) -> Py π γ (a, b)
parPyForced f g = f @Static @Static `seq` g @Static @Static `seq` parPy f g

-- | 'runBIO_' on a body forced first.
runBIOForced_ :: forall a. (forall α. BIO α a) -> LinearIO.IO a
runBIOForced_ body = body @Static `seq` runBIO_ body

-- | 'sharing' on a body forced first.
sharingForced :: forall π π' γ a r. Bound π a -> (forall β. Borrowed (β /\ π) a -> Py π' (β /\ γ) r) -> Py π' γ (r, Bound π a)
sharingForced b k = k @Static `seq` sharing b k

-- | 'reborrowing' on a body forced first.
reborrowingForced :: forall π π' γ a r. Bound π a -> (forall β. Bound (β /\ π) a %1 -> Py π' (β /\ γ) r) -> Py π' γ (r, Bound π a)
reborrowingForced b k = k @Static `seq` reborrowing b k

-- * Item 1: the pure world cannot lift IO

badPureLift :: Int
badPureLift =
  Linear.unur
    ( linearly \lin ->
        runBO_ lin (liftSystemIOU (pure 7))
    )

-- * Item 2: runBIO does not accept a Py computation

badRunBIO :: LinearIO.IO (PyResult (Bound Static PyAny))
badRunBIO = runBIOForced_ (getAttr (staleView @Static @PyAny) "x")

-- * Item 3: nominal roles refuse coerce on every index-carrying type

badCoerceWorldPure :: forall α a. BIO α a -> BO α a
badCoerceWorldPure = coerce

badCoerceWorldPy :: forall π γ a. Py π γ a -> BIO γ a
badCoerceWorldPy = coerce

badCoerceHandleTag :: forall π. Bound π PyLong -> Bound π PyStr
badCoerceHandleTag = coerce

badCoerceViewTag :: forall π. Borrowed π PyLong -> Borrowed π PyStr
badCoerceViewTag = coerce

badCoerceAttachment :: forall π π' t. Bound π t -> Bound π' t
badCoerceAttachment = coerce

badCoerceViewAttachment :: forall π π' t. Borrowed π t -> Borrowed π' t
badCoerceViewAttachment = coerce

badCoercePyHandleTag :: PyHandle PyLong -> PyHandle PyStr
badCoercePyHandleTag = coerce

badCoerceBufferMutScope :: forall π π' e. BufferMut π e -> BufferMut π' e
badCoerceBufferMutScope = coerce

badCoerceBufferMutElement :: forall π. BufferMut π Double -> BufferMut π Float
badCoerceBufferMutElement = coerce

badCoerceBufferShareScope :: forall π π' e. BufferShare π e -> BufferShare π' e
badCoerceBufferShareScope = coerce

badCoerceBufferShareElement :: forall π. BufferShare π Double -> BufferShare π Float
badCoerceBufferShareElement = coerce

-- * Item 4: a reference cannot leave the attachment that created it

badEscapeAttach :: forall γ π0. BIO γ (Bound π0 PyNone)
badEscapeAttach = attachForced_ none

badEscapeScope :: forall π π0. Py π π (Bound (π0 /\ π) PyNone)
badEscapeScope = attachForced'_ none

-- | The body is well-typed on its own; only returning it through attach' is refused.
badEscapeScopeAfter :: forall π π0. Py π π (Bound (π0 /\ π) PyNone)
badEscapeScopeAfter = attachForced' body
  where
    body :: forall π'. Py (π' /\ π) (π' /\ π) (After π' (Bound (π' /\ π) PyNone))
    body = Control.do
      b <- none
      Control.pure (After b)

-- * Item 5: a result at a longer attachment is refused by ToResult

badResultAtLongerAttachment :: forall π π'. Borrowed π PyAny -> Py π' π' (PyResult (Bound π' PyAny))
badResultAtLongerAttachment v = toResult @π' v `demanding` forceOutlives @π @π'

badResultThroughCallable :: forall π π'. Borrowed π PyAny -> Py π' π' (PyResult (Bound π' PyAny))
badResultThroughCallable v = callWith @π' (Control.pure v :: Py π' π' (Borrowed π PyAny)) [] `demanding` forceOutlives @π @π'

-- * Item 6: a detached body has no Python operation

badViewInDetach :: forall π. Borrowed π PyAny -> Py π π (PyResult Int)
badViewInDetach v = detachForced (len v)

-- * Item 7: a payload borrow cannot leave the scope that dereferenced it

badPayloadEscapesScope :: forall π. Bound π Payload -> Py π π (PyResult (Mut π Payload))
badPayloadEscapesScope b = attachForced'_ (derefMut b)

badPayloadEscapesSharing :: forall π. Bound π Payload -> Py π π (PyResult (Ur (Share π Payload)), Bound π Payload)
badPayloadEscapesSharing b = sharingForced b \v -> derefShare v

badPayloadEscapesReborrowing :: forall π. Bound π Payload -> Py π π (PyResult (Mut π Payload), Bound π Payload)
badPayloadEscapesReborrowing b = reborrowingForced b \b' -> derefMut b'

-- | 'withBufferMut' on a body forced first.
withBufferMutForced :: forall e π π' γ r. (π >= γ) => BufferMut π e -> (forall α. Mut (α /\ γ) (SVector e) %1 -> BIO (α /\ γ) r) -> Py π' γ (r, BufferMut π e)
withBufferMutForced buf k = k @Static `seq` withBufferMut buf k

-- | The vector borrow handed to a 'withBufferMut' body is well-typed inside the body and nowhere else.
keepVector :: forall e γ α. Mut (α /\ γ) (SVector e) %1 -> BIO (α /\ γ) (Mut (α /\ γ) (SVector e))
keepVector = Control.pure

badVectorEscapesWithBufferMut :: forall π. BufferMut π Double -> Py π π (Mut π (SVector Double), BufferMut π Double)
badVectorEscapesWithBufferMut buf = withBufferMutForced buf keepVector

-- * Item 8: a view never yields a Mut, and never mutates

badDerefMutOnView :: forall π. Borrowed π Payload -> Py π π (PyResult (Mut π Payload))
badDerefMutOnView v = derefMut v

badSetAttrOnView :: forall π. Borrowed π PyAny -> Py π π (PyResult (), Bound π PyAny)
badSetAttrOnView v = setAttr v "x" v

-- * Item 10: no pure copy and no clone of a reference

badCopyMut :: forall π t. Bound π t %1 -> Ur (PyRef t)
badCopyMut = copyMut

badCopy :: forall π t. Borrowed π t %1 -> PyRef t
badCopy = copy

badClone :: forall π π' t. Borrowed π t %1 -> Py π' π (PyRef t)
badClone = clone

-- * Item 11: a handle is neither Movable nor Dupable

badMove :: forall π t. Bound π t %1 -> Ur (Bound π t)
badMove = move

badDup2 :: forall π t. Bound π t %1 -> (Bound π t, Bound π t)
badDup2 = dup2

-- * Item 13: attach_ needs a released parent, and there is no lift of BIO into Py

badAttachInPy :: forall π γ. Py π γ ()
badAttachInPy = attach_ (Control.pure ())

-- * Item 14: a branch's reference cannot leave parPy

badEscapeParPy :: forall π γ π0. Py π γ (Bound π0 PyNone, ())
badEscapeParPy = parPyForced none (Control.pure ())

-- * Item 15: no liftBIO in the safe API, and unsafeLiftBIO needs an impure destination

badLiftBIO :: forall π γ a. BIO γ a -> Py π γ a
badLiftBIO = liftBIO

badUnsafeLiftBIOIntoBO :: Int
badUnsafeLiftBIOIntoBO =
  Linear.unur
    ( linearly \lin ->
        runBO_ lin (unsafeLiftBIO (Control.pure (Ur 7)))
    )

-- * Item 17: packed references are legal and inert

-- | A handle packed with its attachment.
data SomeHandle where
  SomeHandle :: Bound π t %1 -> SomeHandle

-- | A view packed with its attachment.
data SomeView where
  SomeView :: Borrowed π t -> SomeView

instance Consumable SomeView where
  consume (SomeView v) = consume v

-- | A payload borrow packed with its lifetime.
data SomePayload where
  SomePayload :: Mut γ Payload %1 -> SomePayload

-- | A payload that stores a packed view, to be taken out in a later call.
newtype Stash = Stash (Ref SomeView)
  deriving newtype (Consumable)

instance PyClass Stash where
  pyClassName _ = "Stash"
  pyClassTypeCell _ = stashCell

stashCell :: TypeCell
stashCell = unsafeNewTypeCell
{-# NOINLINE stashCell #-}

-- | Packing compiles, and the pure operations that touch no memory still apply.
allowedPackAndConsume :: forall π t. Bound π t %1 -> ()
allowedPackAndConsume b = case SomeHandle b of
  SomeHandle h -> consume h

allowedPackAndShare :: forall π t. Bound π t %1 -> SomeView
allowedPackAndShare b = case share b of
  Ur v -> SomeView v

badUnpackedGetAttr :: forall π' γ. SomeView -> Py π' γ (PyResult (Bound π' PyAny))
badUnpackedGetAttr (SomeView (v :: Borrowed π t)) = getAttr v "x" `demanding` forceOutlives @π @γ

badUnpackedToHandle :: forall π' γ. SomeView -> Py π' γ (Ur (PyHandle PyAny))
badUnpackedToHandle (SomeView (v :: Borrowed π t)) = toHandle (asAny v) `demanding` forceOutlives @π @γ

badUnpackedSetAttr :: forall π' γ. SomeHandle -> Py π' γ (PyResult ())
badUnpackedSetAttr (SomeHandle (b :: Bound π t)) =
  Control.fmap (\(r, b') -> consume b' `lseq` r) (setAttr b "x" (staleView @Static @PyAny)) `demanding` forceOutlives @π @γ

badUnpackedDerefMut :: forall π' γ. SomeHandle -> Py π' γ (PyResult (Mut γ Payload))
badUnpackedDerefMut (SomeHandle (b :: Bound π t)) = derefMut (unsafeRetagMut b :: Bound π Payload) `demanding` forceOutlives @π @γ

badUnpackedDerefShare :: forall π' γ. SomeView -> Py π' γ (PyResult (Ur (Share γ Payload)))
badUnpackedDerefShare (SomeView (v :: Borrowed π t)) = derefShare (unsafeRetagShare v :: Borrowed π Payload) `demanding` forceOutlives @π @γ

badUnpackedRefModify :: forall π' γ. SomePayload -> Py π' γ ()
badUnpackedRefModify (SomePayload (m :: Mut γ0 Payload)) =
  Control.fmap consume (RefB.modify (Linear.+ 1) (upcast m :: Mut γ0 (Ref Int))) `demanding` forceOutlives @γ0 @γ

{- | Reading a view stashed by an earlier call: its attachment is gone, and
nothing can lengthen it.
This is the step of 'stashedViewLater' that the type checker refuses.
-}
badReadStashed :: forall π. SomeView %1 -> Py π π (PyResult (Bound π PyAny), SomeView)
badReadStashed (SomeView (v :: Borrowed π0 t)) =
  Control.fmap (\r -> (r, SomeView v)) (getAttr v "x") `demanding` forceOutlives @π0 @π

-- | The later call itself: a Mut-receiver method that updates the stash through the refused read.
stashedViewLater :: forall π. Mut π Stash %1 -> Py π π (PyResult (Bound π PyAny))
stashedViewLater s = Control.do
  (r, ref) <- RefB.update badReadStashed (upcast s :: Mut π (Ref SomeView))
  Control.pure (consume ref `lseq` r)

-- * Item 19: the shapes the two axes exist for

-- | A reference created inside a sharing body returns from it.
allowedRefFromSharing :: forall π. Bound π PyAny %1 -> Py π π (PyResult (Bound π PyAny), Bound π PyAny)
allowedRefFromSharing b = sharing b \v -> getAttr v "x"

-- | A reference created inside a reborrowing body returns from it.
allowedRefFromReborrowing :: forall π. Bound π PyAny %1 -> Py π π (PyResult (Bound π PyAny), Bound π PyAny)
allowedRefFromReborrowing b = reborrowing b \b' -> case share b' of
  Ur v -> getAttr v "x"

-- | A reference created while a dereferenced payload is live returns from the method.
allowedRefWhilePayloadLive :: forall π. Bound π Payload %1 -> Py π π (PyResult (Bound π PyStr))
allowedRefWhilePayloadLive b = Control.do
  r <- derefMut b
  withPayload r
  where
    withPayload :: PyResult (Mut π Payload) %1 -> Py π π (PyResult (Bound π PyStr))
    withPayload (Left e) = Control.pure (Left e)
    withPayload (Right m) = Control.do
      m' <- RefB.modify (Linear.+ 1) (upcast m :: Mut π (Ref Int))
      consume m' `lseq` toStr "x"

-- | A borrow at the caller's lifetime leaves attach.
allowedBorrowLeavesAttach :: forall γ. BIO γ (Mut γ (Ur Int))
allowedBorrowLeavesAttach = attach Control.do
  (m, l) <- asksLinearly (borrow (Ur 1))
  consume l `lseq` Control.pure (After m)

-- | A borrow at the ambient cannot: it is the mirror of the case above.
badBorrowMLeavesAttach :: forall γ. BIO γ (Mut γ (Ur Int))
badBorrowMLeavesAttach = attachForced_ Control.do
  (m, l) <- borrowM (Ur 1)
  consume l `lseq` Control.pure m

-- | attach' returns through After, shortened the safe way.
allowedAttachPrime :: forall π. Py π π Int
allowedAttachPrime = attach' Control.do
  b <- none
  consume b `lseq` Control.fmap upcast (pureAfter (1 :: Int))

-- | attach'_ is the loop tool: one reference per iteration, swept each time.
allowedLoopScope :: forall π. Int -> Py π π ()
allowedLoopScope 0 = Control.pure ()
allowedLoopScope n = Control.do
  attach'_ (Control.fmap consume none)
  allowedLoopScope (n - 1)

-- | A dereference on the narrowed handle inside reborrowing_, which restores the handle.
allowedDerefInReborrowing :: forall π. Bound π Payload %1 -> Py π π (Bound π Payload)
allowedDerefInReborrowing b = reborrowing_ b \b' -> Control.do
  r <- derefMut b'
  bump r
  where
    bump :: forall β. PyResult (Mut (β /\ π) Payload) %1 -> Py π (β /\ π) ()
    bump (Left e) = consume e `lseq` Control.pure ()
    bump (Right m) = Control.do
      m' <- RefB.modify (Linear.+ 1) (upcast m :: Mut (β /\ π) (Ref Int))
      Control.pure (consume m')

-- | liftBO (parBO …) over a split dereferenced payload.
allowedLiftBOParOverSplit :: forall π. Mut π Pair %1 -> Py π π ()
allowedLiftBOParOverSplit p = case splitPair (upcast p :: Mut π (Ref Int, Ref Int)) of
  (l, r) -> Control.do
    (l', r') <- liftBO (parBO (RefB.modify (Linear.+ 1) l) (RefB.modify (Linear.+ 1) r))
    Control.pure (consume (l', r'))

-- | detach (parBO …) over a split dereferenced payload.
allowedDetachParOverSplit :: forall π. Mut π Pair %1 -> Py π π ()
allowedDetachParOverSplit p = case splitPair (upcast p :: Mut π (Ref Int, Ref Int)) of
  (l, r) -> Control.do
    (l', r') <- detach (parBO (RefB.modify (Linear.+ 1) l) (RefB.modify (Linear.+ 1) r))
    Control.pure (consume (l', r'))

-- * Item 21: a receiver at a separate lifetime, both directions

-- | Without the constraint, a Python operand is unusable: the ambient α is not known to be outlived by π.
badSeparateReceiver :: forall π α. Mut α Payload -> Borrowed π PyAny -> Py π α (PyResult Int)
badSeparateReceiver m v = (consume m `lseq` len v) `demanding` forceOutlives @π @α

-- | With the constraint, it compiles.
allowedConstrainedReceiver :: forall π α. (π >= α) => Mut α Payload -> Borrowed π PyAny -> Py π α (PyResult Int)
allowedConstrainedReceiver m v = consume m `lseq` len v

-- | The constrained form composes on a meet.
allowedReceiverOnMeet :: forall π β. Mut (β /\ π) Payload -> Borrowed π PyAny -> Py π (β /\ π) (PyResult Int)
allowedReceiverOnMeet = allowedConstrainedReceiver

-- | It does not compose through a given: transitivity of the outlives relation is not derived.
badReceiverThroughGiven :: forall π α β. (π >= α) => Mut (β /\ α) Payload -> Borrowed π PyAny -> Py π (β /\ α) (PyResult Int)
badReceiverThroughGiven m v = allowedConstrainedReceiver m v `demanding` forceOutlives @π @(β /\ α)
