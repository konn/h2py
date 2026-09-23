{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Forces every deferred refusal of "H2Py.TypingCases" and inspects its
diagnostic, as pure-borrow's own suite does: a case that stopped throwing
would be a soundness bug, so no expected-failure wrapper is used.
Nothing here needs an interpreter.
-}
module H2Py.TypingSpec (
  module H2Py.TypingSpec,
) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.BO (Static)
import Control.Monad.Borrow.Pure (Mut, linearly)
import Control.Monad.Borrow.Unsafe (Alias (..))
import Data.List (isInfixOf)
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Foreign.ForeignPtr (newForeignPtr_)
import Foreign.Ptr (nullPtr)
import H2Py.Buffer (BufferMut, BufferShare)
import H2Py.Object.Internal (PyAny, PyHandle (..), PyLong)
import H2Py.TypingCases
import Prelude.Linear (Ur (..))
import Prelude.Linear qualified as Linear
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)
import Unsafe.Linear qualified as Unsafe

{- | The fixtures built through constructors live here and not in
"H2Py.TypingCases": with a newtype's constructor in scope, 'Data.Coerce.coerce'
unwraps it and the nominal roles of item 3 would never be reached.
-}

-- | A GC-managed handle to nothing: only a value to retag.
stalePyHandle :: forall t. PyHandle t
stalePyHandle = PyHandle (unsafePerformIO (newForeignPtr_ nullPtr))
{-# NOINLINE stalePyHandle #-}

-- | A reference cell that nothing ever reads: only a value to pack.
staleRef :: Ref Int
staleRef = Linear.unur (linearly \lin -> Unsafe.toLinear Ur (Ref.new 1 lin))
{-# NOINLINE staleRef #-}

-- | A payload borrow that nothing ever dereferences: the value the packed cases are applied to.
stalePayloadBorrow :: forall γ. Mut γ Payload
stalePayloadBorrow = UnsafeAlias (Payload staleRef)

{- | A refusal test: forcing the value must throw a deferred type error whose
text contains, for every group, at least one of its alternatives.
-}
expectDeferred :: String -> [[String]] -> a -> TestTree
expectDeferred description groups value = testCase description do
  result <- try @SomeException (evaluate value)
  case result of
    Left exception -> do
      let text = displayException exception
      assertBool ("unexpected diagnostic: " <> text) (all (any (`isInfixOf` text)) groups)
    Right _ -> assertFailure "the type checker did not refuse this escape"

-- | A positive case: the value is well-typed, and forcing it throws nothing.
expectCompiles :: String -> a -> TestTree
expectCompiles description value = testCase description do
  result <- try @SomeException (evaluate value)
  case result of
    Left exception -> assertFailure ("a positive case threw: " <> displayException exception)
    Right _ -> pure ()

couldNotDeduce :: [String]
couldNotDeduce = ["Could not deduce", "No instance"]

couldNotMatch :: [String]
couldNotMatch = ["Couldn't match"]

outlives :: [String]
outlives = ["<=!!"]

test_worlds :: TestTree
test_worlds =
  testGroup
    "worlds (items 1, 2, 13, 15)"
    [ expectDeferred "1: Pure rejects IO lifting" [["Impure"], ["Pure"]] badPureLift
    , expectDeferred "2: runBIO does not accept a Py computation" [couldNotMatch, ["Python"], ["RealWorld"]] badRunBIO
    , expectDeferred "13: attach_ inside Py is a world mismatch" [couldNotMatch, ["RealWorld"], ["Python"]] (badAttachInPy @Static @Static)
    , expectDeferred "15: no liftBIO in the safe API" [["not in scope"], ["liftBIO"]] (badLiftBIO @Static @Static @() (Control.pure ()))
    , expectDeferred "15: unsafeLiftBIO needs an impure destination" [["Impure"], ["Pure"]] badUnsafeLiftBIOIntoBO
    ]

test_roles :: TestTree
test_roles =
  testGroup
    "nominal roles (item 3)"
    [ expectDeferred "coerce between worlds, BIO to BO" [couldNotMatch, ["RealWorld"], ["Pure"]] (badCoerceWorldPure @Static @() (Control.pure ()))
    , expectDeferred "coerce between worlds, Py to BIO" [couldNotMatch, ["Python"], ["RealWorld"]] (badCoerceWorldPy @Static @Static @() (Control.pure ()))
    , expectDeferred "coerce between PyRef tags on a handle" [couldNotMatch, ["PyLong"], ["PyStr"]] (badCoerceHandleTag (staleHandle @Static @PyLong))
    , expectDeferred "coerce between PyRef tags on a view" [couldNotMatch, ["PyLong"], ["PyStr"]] (badCoerceViewTag (staleView @Static @PyLong))
    , expectDeferred "coerce between attachment lifetimes on a handle" [couldNotMatch, ["coerce"]] (badCoerceAttachment @Static @Static @PyAny (staleHandle @Static @PyAny))
    , expectDeferred "coerce between attachment lifetimes on a view" [couldNotMatch, ["coerce"]] (badCoerceViewAttachment @Static @Static @PyAny (staleView @Static @PyAny))
    , expectDeferred "coerce between PyHandle tags" [couldNotMatch, ["PyLong"], ["PyStr"]] (badCoercePyHandleTag (stalePyHandle @PyLong))
    , expectDeferred "coerce between scopes on BufferMut" [couldNotMatch, ["coerce"]] (badCoerceBufferMutScope @Static @Static @Double staleBufferMut)
    , expectDeferred "coerce between element types on BufferMut" [couldNotMatch, ["Double"], ["Float"]] (badCoerceBufferMutElement @Static staleBufferMut)
    , expectDeferred "coerce between scopes on BufferShare" [couldNotMatch, ["coerce"]] (badCoerceBufferShareScope @Static @Static @Double staleBufferShare)
    , expectDeferred "coerce between element types on BufferShare" [couldNotMatch, ["Double"], ["Float"]] (badCoerceBufferShareElement @Static staleBufferShare)
    ]

{- | A buffer view that nothing ever reads: the refusals above force the
missing evidence before the argument, so the value itself is never demanded.
-}
staleBufferMut :: forall π e. BufferMut π e
staleBufferMut = error "staleBufferMut: a buffer view that is never read"

-- | The shared form of 'staleBufferMut'.
staleBufferShare :: forall π e. BufferShare π e
staleBufferShare = error "staleBufferShare: a buffer view that is never read"

test_escapes :: TestTree
test_escapes =
  testGroup
    "escaping attachments and payload borrows (items 4, 7, 14, 19)"
    [ expectDeferred "4: a Bound cannot leave attach_" [couldNotMatch, ["PyNone"]] (badEscapeAttach @Static @Static)
    , expectDeferred "4: a Bound cannot leave attach'_" [couldNotMatch, ["PyNone"]] (badEscapeScope @Static @Static)
    , expectDeferred "4: a Bound cannot leave attach' through After" [couldNotMatch, ["PyNone"]] (badEscapeScopeAfter @Static @Static)
    , expectDeferred "7: a payload borrow cannot leave attach'_" [couldNotMatch, ["Payload"]] (badPayloadEscapesScope @Static staleHandle)
    , expectDeferred "7: a payload borrow cannot leave sharing" [couldNotMatch, ["Payload"]] (badPayloadEscapesSharing @Static staleHandle)
    , expectDeferred "7: a payload borrow cannot leave reborrowing" [couldNotMatch, ["Payload"]] (badPayloadEscapesReborrowing @Static staleHandle)
    , expectDeferred "7: a vector borrow cannot leave withBufferMut" [couldNotMatch, ["/\\"]] (badVectorEscapesWithBufferMut @Static staleBufferMut)
    , expectDeferred "14: a branch's Bound cannot leave parPy" [couldNotMatch, ["PyNone"]] (badEscapeParPy @Static @Static @Static)
    , expectDeferred "19: borrowM at the ambient cannot leave attach" [couldNotMatch, ["Ur"]] (badBorrowMLeavesAttach @Static)
    ]

test_results :: TestTree
test_results =
  testGroup
    "results at a longer attachment (item 5)"
    [ expectDeferred "ToResult refuses a view of another attachment" [couldNotDeduce, outlives] (badResultAtLongerAttachment @Static @Static staleView)
    , expectDeferred "PyCallable refuses it through ToResult" [couldNotDeduce, outlives] (badResultThroughCallable @Static @Static staleView)
    ]

test_detach :: TestTree
test_detach =
  testGroup
    "detached bodies (item 6)"
    [ expectDeferred "a view is unusable inside detach" [couldNotMatch, ["RealWorld"], ["Python"]] (badViewInDetach @Static staleView)
    ]

test_views :: TestTree
test_views =
  testGroup
    "views never mutate (item 8)"
    [ expectDeferred "derefMut on a view" [couldNotMatch, ["Mut"], ["Share"]] (badDerefMutOnView @Static staleView)
    , expectDeferred "setAttr on a view" [couldNotMatch, ["Mut"], ["Share"]] (badSetAttrOnView @Static staleView)
    ]

test_instances :: TestTree
test_instances =
  testGroup
    "copy, clone, move and dup (items 10, 11)"
    [ expectDeferred "10: copyMut on a handle is Unsatisfiable" [["cannot be copied out of its borrow"]] (badCopyMut @Static @PyAny staleHandle)
    , expectDeferred "10: copy on a view is Unsatisfiable" [["cannot be copied out of its borrow"]] (badCopy @Static @PyAny staleView)
    , expectDeferred "10: clone on a view is Unsatisfiable" [["cannot be cloned in the pure world"]] (badClone @Static @Static @PyAny staleView)
    , expectDeferred "11: move on a handle has no instance" [couldNotMatch, ["Mut"], ["Share"]] (badMove @Static @PyAny staleHandle)
    , expectDeferred "11: dup2 on a handle has no instance" [couldNotMatch, ["Mut"], ["Share"]] (badDup2 @Static @PyAny staleHandle)
    ]

test_inert :: TestTree
test_inert =
  testGroup
    "packed forms are inert (item 17)"
    [ expectCompiles "packing a handle compiles and consumes" (allowedPackAndConsume @Static @PyAny staleHandle)
    , expectCompiles "packing a view compiles" (allowedPackAndShare @Static @PyAny staleHandle)
    , expectDeferred "getAttr on the unpacked view" [couldNotDeduce, outlives] (badUnpackedGetAttr @Static @Static (SomeView (staleView @Static @PyAny)))
    , expectDeferred "toHandle on the unpacked view" [couldNotDeduce, outlives] (badUnpackedToHandle @Static @Static (SomeView (staleView @Static @PyAny)))
    , expectDeferred "setAttr on the unpacked handle" [couldNotDeduce, outlives] (badUnpackedSetAttr @Static @Static (SomeHandle (staleHandle @Static @PyAny)))
    , expectDeferred "derefMut on the unpacked handle" [couldNotDeduce, outlives] (badUnpackedDerefMut @Static @Static (SomeHandle (staleHandle @Static @PyAny)))
    , expectDeferred "derefShare on the unpacked view" [couldNotDeduce, outlives] (badUnpackedDerefShare @Static @Static (SomeView (staleView @Static @PyAny)))
    , expectDeferred "a container operation on the unpacked payload borrow" [couldNotDeduce, outlives] (badUnpackedRefModify @Static @Static (SomePayload stalePayloadBorrow))
    , expectDeferred "a view stashed in a payload and read in a later call" [couldNotDeduce, outlives] (badReadStashed @Static (SomeView (staleView @Static @PyAny)))
    , expectCompiles "the later call that performs the refused read" (stashedViewLater @Static)
    ]

test_receivers :: TestTree
test_receivers =
  testGroup
    "receivers at a separate lifetime (item 21)"
    [ expectDeferred "without the constraint" [couldNotDeduce, outlives] (badSeparateReceiver @Static @Static stalePayloadBorrow staleView)
    , expectDeferred "not through a given" [couldNotDeduce, outlives] (badReceiverThroughGiven @Static @Static @Static stalePayloadBorrow staleView)
    , expectCompiles "with the constraint" (allowedConstrainedReceiver @Static @Static)
    , expectCompiles "on a meet" (allowedReceiverOnMeet @Static @Static)
    ]

test_positive :: TestTree
test_positive =
  testGroup
    "the shapes the two axes exist for compile (item 19)"
    [ expectCompiles "a reference created inside sharing returns" (allowedRefFromSharing @Static)
    , expectCompiles "a reference created inside reborrowing returns" (allowedRefFromReborrowing @Static)
    , expectCompiles "a reference created while a payload is live returns" (allowedRefWhilePayloadLive @Static)
    , expectCompiles "a borrow at the caller's lifetime leaves attach" (allowedBorrowLeavesAttach @Static)
    , expectCompiles "attach' returns through After" (allowedAttachPrime @Static)
    , expectCompiles "attach'_ is the loop tool" (allowedLoopScope @Static 3)
    , expectCompiles "derefMut on the narrowed handle inside reborrowing_" (allowedDerefInReborrowing @Static)
    , expectCompiles "liftBO (parBO …) over a split payload" (allowedLiftBOParOverSplit @Static)
    , expectCompiles "detach (parBO …) over a split payload" (allowedDetachParOverSplit @Static)
    ]
