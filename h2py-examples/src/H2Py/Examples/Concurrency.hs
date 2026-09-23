{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- |
The @concurrency@ submodule: the delimiters of section 5.1 of the design, and
the contention rules of section 5.3, exercised from Python.

Every function here is written at @'Py' π π@, and the shapes it shows are the
ones the tutorial names: 'detach' around a wait, @detach (parBO …)@ over a split
borrow, 'parPy' for branches that need Python, @attach'_@ as the loop tool,
and 'checkSignals' inside a long attached loop.
-}
module H2Py.Examples.Concurrency (
  concurrencySpec,
  SharedCounter (..),
  h2py_class_SharedCounter,
  Series (..),
  h2py_class_Series,
  sleepDetached,
  parSum,
  parCall,
  parBIOError,
  lazyErrorDetached,
  callFromUnattachedThread,
  loopWithScopes,
  interruptibleLoop,
  sleepThenCheck,
  nestedAttachInMethod,
) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, evaluate, fromException, try)
import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.BO (BO', borrow)
import Control.Monad.Borrow.IO (BIO)
import Control.Monad.Borrow.Pure
import Control.Monad.IO.Class.Linear (liftSystemIOU)
import Data.Proxy (Proxy (..))
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Data.Ref.Linear.Borrow qualified as RefB
import Data.Text qualified as Text
import Data.Vector qualified as V
import Data.Vector.Generic.Mutable.Linear.Borrow.Unrestricted qualified as VL
import Foreign.Ptr (Ptr)
import H2Py
import H2Py.Object.Internal (refPtr, unsafeBorrowedFromPtr)
import H2Py.Py.Internal (unsafeRunPy, withFreshScope)
import H2Py.Runtime.Internal (PyObject)
import Prelude.Linear
import Prelude qualified as P

-- * Waiting with the interpreter released

-- | Sleep for the given number of seconds with the interpreter released, so that other Python threads run meanwhile.
sleepDetached :: forall π. Double -> Py π π ()
sleepDetached seconds = Control.do
  Ur () <- detach (liftSystemIOU (threadDelay (micros seconds)))
  Control.pure ()

micros :: Double -> Int
micros seconds = max 0 (round (seconds * 1e6))

-- * @detach (parBO …)@ over a split borrow

{- | Sum a list by converting it into a Haskell-owned vector, borrowing it,
splitting the borrow in two, and summing the halves in parallel with the
interpreter released.
-}
parSum :: forall π. [Int] -> Py π π Int
parSum xs = srunBO (parSumScope xs)

-- | The body of 'parSum' at a fresh sublifetime @α@, which the borrow of the vector takes.
parSumScope :: forall α π. [Int] -> Py π (α /\ π) (After α Int)
parSumScope xs = Control.do
  (mvec, lend) <- asksLinearly \lin -> case dup2 lin of
    (lin1, lin2) -> borrow @α (VL.fromList @V.Vector xs lin1) lin2
  let !(Ur svec) = share mvec
      !(left, right) = VL.splitAt (P.length xs `div` 2) svec
  (a, b) <- detach (parBO (sumShare left) (sumShare right))
  Control.pure (After (consume (reclaim lend) `lseq` (a + b)))

-- | Sum one half through its shared borrow, in a body with no @π@.
sumShare :: forall α β. (α >= β) => Share α (VL.Vector V.Vector Int) -> BIO β Int
sumShare v = Control.do
  (Ur snapshot, v') <- VL.copyToVector v
  Control.pure (consume v' `lseq` V.sum snapshot)

-- * 'parPy'

{- | Call two Python callables, each in its own 'parPy' branch with a fresh
attachment, and answer the pair of their results as a tuple.
Under the GIL the two calls serialise; an exception raised by either callable
is the call's result, as a value, and never a hang.
-}
parCall :: forall π. Borrowed π PyAny -> Borrowed π PyAny -> Py π π (PyResult (Bound π PyTuple))
parCall f g = Control.do
  (Ur ra, Ur rb) <- parPy (callToHandle f) (callToHandle g)
  pairUp ra rb
  where
    pairUp :: PyResult (PyHandle PyAny) -> PyResult (PyHandle PyAny) -> Py π π (PyResult (Bound π PyTuple))
    pairUp (Left e) _ = Control.pure (Left e)
    pairUp _ (Left e) = Control.pure (Left e)
    pairUp (Right ha) (Right hb) = Control.do
      a <- fromHandle ha
      b <- fromHandle hb
      tupleOfHandles a b
    tupleOfHandles :: Bound π PyAny %1 -> Bound π PyAny %1 -> Py π π (PyResult (Bound π PyTuple))
    tupleOfHandles a b = case share a of
      Ur va -> case share b of
        Ur vb -> toTuple [va, vb]

{- | Call a callable of the parent scope inside a branch and hand its result
out as a GC-managed handle, which is what may leave the branch's attachment;
the handle is unrestricted, so the whole result travels in 'Ur'.
-}
callToHandle :: forall π δ π'. Borrowed π PyAny -> Py π' (π' /\ (δ /\ π)) (Ur (PyResult (PyHandle PyAny)))
callToHandle f = Control.do
  r <- call @PyAny @π @π' f []
  handleOf r
  where
    handleOf :: PyResult (Bound π' PyAny) %1 -> Py π' (π' /\ (δ /\ π)) (Ur (PyResult (PyHandle PyAny)))
    handleOf (Left e) = case move e of
      Ur e' -> Control.pure (Ur (Left e'))
    handleOf (Right b) = case share b of
      Ur v -> Control.fmap (\(Ur h) -> Ur (Right h)) (toHandle v)

-- * Exceptions in detached branches

{- | @detach (parBIO …)@ with a branch that calls 'error': the guard around
each branch turns the failure into the call's exception, a @RuntimeError@ in
Python, instead of leaving the parent waiting forever on the branch's result.
-}
parBIOError :: forall π. Py π π Int
parBIOError = Control.do
  (Ur a, Ur b) <- detach (parBIO (liftSystemIOU (P.pure 1)) boomBranch)
  Control.pure (a + b)

-- | A branch that reads something first, so that the error is raised while it runs.
boomBranch :: forall γ. BIO γ (Ur Int)
boomBranch = Control.do
  Ur n <- liftSystemIOU (P.pure (41 :: Int))
  if n > 0
    then P.error "boom in a parBIO branch"
    else Control.pure (Ur n)

{- | A lazy error built and forced on a detached thread, then answered as a
@Left@: the class behind a built-in error is a static address the shim
caches, so forcing it needs no attachment.
-}
lazyErrorDetached :: forall π. BIO π (PyResult Int)
lazyErrorDetached = Control.do
  Ur e <- liftSystemIOU (evaluate (pyErr (Proxy @ValueError) "x"))
  Control.pure (Left e)

-- * The wrong thread

{- | Fork an unbound Haskell thread that tries a Python operation on a raw
view of the argument, and answer whether it raised 'NotAttached'.
The runtime spec of item 12 of section 8 of the design: a Python operation
reached from an unattached thread ends in an exception, never in undefined
behaviour.
-}
callFromUnattachedThread :: forall π. Borrowed π PyAny -> Py π π Bool
callFromUnattachedThread o = Control.do
  Ur raised <- liftSystemIOU (probeUnattached (refPtr o))
  Control.pure raised

probeUnattached :: Ptr PyObject -> P.IO Bool
probeUnattached p = do
  box <- newEmptyMVar
  _ <- forkIO do
    r <- try (withFreshScope \(Proxy :: Proxy π) -> unsafeRunPy (probe @π p))
    putMVar box (isNotAttached r)
  takeMVar box
  where
    isNotAttached :: Either SomeException (PyResult Text.Text) -> Bool
    isNotAttached (Right _) = False
    isNotAttached (Left e) = case fromException e of
      Just NotAttached -> True
      Nothing -> False

-- | @repr@ of a raw pointer view, which must be refused before it touches CPython.
probe :: forall π. Ptr PyObject -> Py π π (PyResult Text.Text)
probe p = repr (unsafeBorrowedFromPtr p :: Borrowed π PyAny)

-- * The loop tool

{- | Create @n@ strings in a loop, one per iteration, each iteration inside
@attach'_@, so that the child arena is swept every time and the call's arena
does not grow.
-}
loopWithScopes :: forall π. Int -> Py π π Int
loopWithScopes n = go 0
  where
    go :: Int -> Py π π Int
    go i
      | i >= n = Control.pure n
      | otherwise = Control.do
          attach'_ (oneString i)
          go (i + 1)
    oneString :: forall π'. Int -> Py (π' /\ π) (π' /\ π) ()
    oneString i = Control.do
      r <- toStr (Text.pack (show i))
      Control.pure (dropResult r)

-- | Drop a reference or an error: both are affine.
dropResult :: PyResult (Bound π t) %1 -> ()
dropResult (Left e) = consume e
dropResult (Right b) = consume b

-- * Signals

{- | Loop @n@ times, checking for signals every iteration; a pending
@KeyboardInterrupt@ is the call's result, as a @Left@, and is raised in Python.
-}
interruptibleLoop :: forall π. Int -> Py π π (PyResult Int)
interruptibleLoop n = go 0
  where
    go :: Int -> Py π π (PyResult Int)
    go i
      | i >= n = Control.pure (Right i)
      | otherwise = Control.do
          r <- checkSignals
          continueFrom i r
    continueFrom :: Int -> PyResult () %1 -> Py π π (PyResult Int)
    continueFrom _ (Left e) = Control.pure (Left e)
    continueFrom i (Right ()) = go (i + 1)

{- | Sleep with the interpreter released, then check for signals once
attached again, and answer whether a @KeyboardInterrupt@ was pending.
This is the shape section 5.1 of the design prescribes for a kernel: a
detached kernel cannot check signals, and the first check after it returns
reports the pending interrupt as a value, which this function consumes rather
than raises.
Under the GIL it is also the only way a Python thread's
@_thread.interrupt_main()@ can reach a call, since that thread needs the
interpreter to run at all.
-}
sleepThenCheck :: forall π. Double -> Py π π Bool
sleepThenCheck seconds = Control.do
  Ur () <- detach (liftSystemIOU (threadDelay (micros seconds)))
  r <- checkSignals
  pendingInterrupt r
  where
    pendingInterrupt :: PyResult () %1 -> Py π π Bool
    pendingInterrupt (Right ()) = Control.pure False
    pendingInterrupt (Left e) = case move e of
      Ur e' -> errorMatches (Proxy @KeyboardInterrupt) e'

-- * A nested attachment on the calling thread

{- | Inside a call, release the interpreter and attach afresh on the same
thread, build a Python string in the inner scope, and answer its length.
-}
nestedAttachInMethod :: forall π. Py π π (PyResult Int)
nestedAttachInMethod = detach (attach_ inner)
  where
    inner :: forall π' δ. Py π' (π' /\ (δ /\ π)) (PyResult Int)
    inner = Control.do
      r <- toStr "hello, nested"
      lengthOf r
    lengthOf :: forall π' δ. PyResult (Bound π' PyStr) %1 -> Py π' (π' /\ (δ /\ π)) (PyResult Int)
    lengthOf (Left e) = Control.pure (Left e)
    lengthOf (Right s) = case share s of
      Ur v -> len v

-- * Contention on a payload across threads

-- | A counter whose methods hold their payload across a detached wait.
newtype SharedCounter = SharedCounter (Ref Int)
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & classDoc "A counter whose methods can hold their payload across a detached wait.") ''SharedCounter

newShared :: Int -> Py π π (PyResult (Bound π SharedCounter))
newShared n = Control.do
  ref <- asksLinearly (Ref.new n)
  newObject (SharedCounter ref)

sharedIncr :: forall π. Mut π SharedCounter %1 -> Int -> Py π π ()
sharedIncr counter k = Control.do
  ref <- RefB.modify (+ k) (upcast counter :: Mut π (Ref Int))
  Control.pure (consume ref)

sharedGet :: Share π SharedCounter -> Py π π Int
sharedGet counter = RefB.copyRef (coerceShare @(Ref Int) counter)

{- | Hold the payload mutably while the interpreter is released for the given
number of seconds, then add one and answer the new value.
A second thread dereferencing the object meanwhile, mutably or shared, gets
@RuntimeError("busy")@.
-}
holdMut :: forall π. Mut π SharedCounter %1 -> Double -> Py π π Int
holdMut counter seconds = Control.do
  Ur () <- detach (liftSystemIOU (threadDelay (micros seconds)))
  ref <- RefB.modify (+ 1) (upcast counter :: Mut π (Ref Int))
  RefB.copyRef ref

{- | Hold the payload shared while the interpreter is released for the given
number of seconds, then answer the value.
Other readers proceed together with this one; a writer gets @busy@.
-}
holdShare :: forall π. Share π SharedCounter -> Double -> Py π π Int
holdShare counter seconds = Control.do
  Ur () <- detach (liftSystemIOU (threadDelay (micros seconds)))
  RefB.copyRef (coerceShare @(Ref Int) counter)

-- | 'nestedAttachInMethod' as a method with a shared receiver.
nestedInMethod :: forall π. Share π SharedCounter -> Py π π (PyResult Int)
nestedInMethod _ = nestedAttachInMethod

pymethods
  ''SharedCounter
  [ constructor 'newShared & param 0 "n"
  , method "incr" 'sharedIncr & param 0 "k" & doc "Add k to the counter."
  , method "get" 'sharedGet & doc "The current value."
  , method "hold_mut" 'holdMut & param 0 "seconds" & doc "Hold the payload mutably across a detached sleep, then add one."
  , method "hold_share" 'holdShare & param 0 "seconds" & doc "Hold the payload shared across a detached sleep."
  , method "nested_attach_in_method" 'nestedInMethod & doc "Detach and attach afresh inside a method."
  ]

-- * The receiver bodies of section 5.4

{- | A vector payload whose methods show the three registered body shapes of
section 5.4 of the design: a @BIO@ body on a @Share@ receiver and one on a
@Mut@ receiver, both run under 'detach' by the registration, and a @BO@ body
registered with @detached@.
-}
newtype Series = Series (VL.Vector V.Vector Int)
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & classDoc "A vector of integers whose long methods run with the interpreter released.") ''Series

type SeriesVector = VL.Vector V.Vector Int

newSeries :: [Int] -> Py π π (PyResult (Bound π Series))
newSeries xs = Control.do
  v <- asksLinearly (VL.fromList xs)
  newObject (Series v)

-- | The sum of the elements, attached: the probe for @busy@ while a detached writer runs.
seriesTotal :: forall π. Share π Series -> Py π π Int
seriesTotal s = sumOnce (coerceShare @SeriesVector s)

-- | Multiply every element in place, attached: the probe for @busy@ while a detached reader runs.
seriesScale :: forall π. Mut π Series %1 -> Int -> Py π π ()
seriesScale s k = Control.do
  v <- scaleAll 0 k (upcast s :: Mut π SeriesVector)
  Control.pure (consume v)

{- | A @Share@ receiver with a @BIO@ body: the registration runs it under
'detach', so the wait releases the interpreter and the payload stays held
shared across it.
-}
seriesHoldShareBIO :: forall π. Share π Series -> Double -> BIO π Int
seriesHoldShareBIO s seconds = Control.do
  Ur () <- liftSystemIOU (threadDelay (micros seconds))
  sumOnce (coerceShare @SeriesVector s)

{- | A @Mut@ receiver with a @BIO@ body that mutates the vector: run under
'detach', with the payload held mutably for the whole window.
-}
seriesScaleBIO :: forall π. Mut π Series %1 -> Int -> Double -> BIO π ()
seriesScaleBIO s k seconds = Control.do
  Ur () <- liftSystemIOU (threadDelay (micros seconds))
  v <- scaleAll 0 k (upcast s :: Mut π SeriesVector)
  Control.pure (consume v)

{- | A @Share@ receiver with a pure @BO@ body, registered @detached@: the sum
of the elements taken @reps@ times, a long pure kernel that runs with the
interpreter released.
-}
seriesTotalDetached :: forall π. Share π Series -> Int -> BO π Int
seriesTotalDetached s reps = sumReps reps 0 (coerceShare @SeriesVector s)

sumReps :: forall π w. Int -> Int -> Share π SeriesVector %1 -> BO' w π Int
sumReps n acc v
  | n <= 0 = consume v `lseq` Control.pure acc
  | otherwise = Control.do
      (Ur snapshot, v') <- VL.copyToVector v
      sumReps (n - 1) (acc + V.sum snapshot) v'

sumOnce :: forall π w. Share π SeriesVector %1 -> BO' w π Int
sumOnce = sumReps 1 0

scaleAll :: forall π w. Int -> Int -> Mut π SeriesVector %1 -> BO' w π (Mut π SeriesVector)
scaleAll i k v = case VL.size v of
  (Ur n, v') ->
    if i >= n
      then Control.pure v'
      else Control.do
        v'' <- VL.modify i (\x -> x * k) v'
        scaleAll (i + 1) k v''

pymethods
  ''Series
  [ constructor 'newSeries & param 0 "xs"
  , method "total" 'seriesTotal & doc "The sum of the elements, attached."
  , method "scale" 'seriesScale & param 0 "k" & doc "Multiply every element by k, attached."
  , method "hold_share_bio" 'seriesHoldShareBIO & param 0 "seconds" & doc "A BIO body on a Share receiver: sleep detached, then sum."
  , method "scale_bio" 'seriesScaleBIO & param 0 "k" & param 1 "seconds" & doc "A BIO body on a Mut receiver: sleep detached, then multiply in place."
  , method "total_detached" 'seriesTotalDetached & param 0 "reps" & doc "A BO body registered detached: the sum taken reps times." & detached
  ]

-- | The @concurrency@ submodule.
concurrencySpec :: ModuleSpec
concurrencySpec =
  ( submodule
      "concurrency"
      [ fn "sleep_detached" 'sleepDetached & param 0 "seconds" & doc "Sleep with the interpreter released."
      , fn "par_sum" 'parSum & param 0 "xs" & doc "Sum a list, the two halves in parallel with the interpreter released."
      , fn "par_call" 'parCall & param 0 "f" & param 1 "g" & doc "Call f and g in parPy branches and return (f(), g())."
      , fn "par_bio_error" 'parBIOError & doc "detach (parBIO ...) with a branch that calls error: raises RuntimeError."
      , fn "lazy_error_detached" 'lazyErrorDetached & detached & doc "Force a lazy ValueError on a detached thread and raise it."
      , fn "call_from_unattached_thread" 'callFromUnattachedThread & param 0 "o" & doc "True when a Python operation from an unbound Haskell thread raised NotAttached."
      , fn "loop_with_scopes" 'loopWithScopes & param 0 "n" & doc "Create n strings, one per attach'_ scope; returns n."
      , fn "interruptible_loop" 'interruptibleLoop & param 0 "n" & doc "Loop n times checking signals; raises KeyboardInterrupt when one is pending."
      , fn "sleep_then_check" 'sleepThenCheck & param 0 "seconds" & doc "Sleep detached, then check signals; True when a KeyboardInterrupt was pending."
      , fn "nested_attach_in_method" 'nestedAttachInMethod & doc "Detach and attach afresh on the calling thread; the length of a string built inside."
      ]
      [''SharedCounter, ''Series]
  )
    { msDoc = "The delimiters and the concurrency story of H2Py, from Python."
    }
