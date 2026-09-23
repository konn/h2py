{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeAbstractions #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# OPTIONS_HADDOCK hide #-}

{- |
The @Py@ world: the code that may touch CPython, and the delimiters that run it.

@'Py' π γ a = 'BO'' ('Python' π) γ a@ is a 'BIO' computation with one more index
and one invariant that is held per scope and checked per operation: @π@ is the
scope of its Python references and of the arena that owns their +1s, @γ@ is the
ordinary borrow lifetime, and the thread that runs it is attached to the
interpreter for the whole scope, on a bound thread.
See section 5.1 of the design.
-}
module H2Py.Py.Internal (
  module H2Py.Py.Internal,
) where

import Control.Concurrent (runInBoundThread)
import Control.Exception (Exception (..), SomeException, evaluate, mask, throwIO, try)
import Control.Functor.Linear qualified as Control
import Control.Monad qualified as NonLinear
import Control.Monad.Borrow.BO (After, BO', Forkable, Impure (..), parBO, withEnd, type (/\))
import Control.Monad.Borrow.IO (BIO)
import Control.Monad.Borrow.Lifetime.Internal (Lifetime (..))
import Control.Monad.Borrow.Lifetime.Token.Unsafe (EndToken (..))
import Control.Monad.Borrow.Unsafe (unsafeBOToSystemIO, unsafeLinIOToBO, unsafeSystemIOToBO)
import Data.Proxy (Proxy (..))
import Foreign.Ptr (Ptr, nullPtr)
import GHC.TypeError (ErrorMessage (..))
import H2Py.Runtime.Internal
import Prelude.Linear.Unsatisfiable (Unsatisfiable)
import Unsafe.Linear qualified as Unsafe

{- | The world of code attached to the interpreter for the scope @π@.

@π@ indexes every Python reference created in the scope and the arena that owns
their +1s; it is fresh in every trampoline call and in every 'attach', and
nested through 'attach'' by intersection.
-}
data Python (π :: Lifetime)

{- | Every 'BIO' and 'BO' computation lifts into the Python world, so every
container operation of pure-borrow is usable directly inside a method body.
H2Py is a trusted library: the lift is the same coercion as @RealWorld@'s.
-}
instance Impure (Python π) where
  liftLinIO = unsafeLinIOToBO
  {-# INLINE liftLinIO #-}

{- | Attachment is bound to the thread, so a @Py@ computation cannot be moved to
a worker unchanged; the world's own fork-join is 'parPy'.
-}
instance
  ( Unsatisfiable
      ( 'Text "parBO cannot run inside Py: the attachment is bound to the thread."
          ':$$: 'Text "Use parPy for branches that need Python, detach (parBO ...) for BIO branches,"
          ':$$: 'Text "or liftBO (parBO ...) for pure ones."
      )
  ) =>
  Forkable (Python π)

{- | Code that may touch CPython: Python references scoped by @π@, Haskell
borrows by @γ@.
-}
type Py π = BO' (Python π)

-- | Raised by every Python operation reached from a thread that is not attached.
data NotAttached = NotAttached
  deriving stock (Show)

instance Exception NotAttached where
  displayException _ = "H2Py: a Python operation was reached from a thread that is not attached to the interpreter"

{- | Raised by 'attach' when the interpreter is finalising, or in the child of
an @os.fork()@, where the Haskell runtime is unusable; by 'attach'' when the
thread that opens the nested scope is not attached; and by either when the
shim cannot allocate the scope's arena.
-}
data AttachRefused = AttachRefusedFinalizing | AttachRefusedForked | AttachRefusedNested | AttachRefusedNoMemory
  deriving stock (Show)

instance Exception AttachRefused where
  displayException AttachRefusedFinalizing = "H2Py: cannot attach to the interpreter while it is finalising"
  displayException AttachRefusedForked = "H2Py: the Haskell runtime cannot be used in the child of os.fork(); use the 'spawn' start method"
  displayException AttachRefusedNested = "H2Py: a nested scope was opened from a thread that is not attached"
  displayException AttachRefusedNoMemory = "H2Py: the shim could not allocate an arena for the scope"

-- | Raised on the restore path of 'detach' when the interpreter has begun finalising in the window.
data DetachRestoreRefused = DetachRestoreRefused
  deriving stock (Show)

instance Exception DetachRestoreRefused where
  displayException _ = "H2Py: the interpreter began finalising while this thread was detached"

-- * Trusted runners

{- | Run an 'IO' action as a Python operation: check the shim's attachment flag,
then run.
Trusted: the action must only touch CPython through calls that are correct on
an attached thread, and must not release the attachment.
-}
unsafePyIO :: forall π γ a. IO a -> Py π γ a
{-# INLINE unsafePyIO #-}
unsafePyIO io = unsafeSystemIOToBO (checkAttached >> io)

-- | 'unsafePyIO' with the innermost arena of the thread.
unsafePyArena :: forall π γ a. (Ptr Arena -> IO a) -> Py π γ a
{-# INLINE unsafePyArena #-}
unsafePyArena k = unsafeSystemIOToBO do
  checkAttached
  arena <- currentArena
  NonLinear.when (arena == nullPtr) (throwIO NotAttached)
  k arena

checkAttached :: IO ()
{-# INLINE checkAttached #-}
checkAttached = do
  attached <- isAttached
  NonLinear.unless attached (throwIO NotAttached)

{- | Eliminate a @Py@ computation into 'IO'.
Trusted: the world protocol, attachment and an arena established before and
swept after, is the caller's obligation; this is the generic eliminator of
"Control.Monad.Borrow.Unsafe".
-}
unsafeRunPy :: forall π γ a. Py π γ a -> IO a
{-# INLINE unsafeRunPy #-}
unsafeRunPy py = unsafeBOToSystemIO py

{- | Bind a rank-2 Python scope to a fresh, abstract lifetime.
Lifetimes are erased, so any index will do; the rank-2 binder is what keeps
the body from assuming anything about it.
-}
withFreshScope :: (forall (π :: Lifetime). Proxy π -> r) -> r
{-# INLINE withFreshScope #-}
withFreshScope k = k (Proxy @('Al 0))

-- * Delimiters

{- | Attach the current Haskell thread to the interpreter for a scope.

The body runs at @'Py' π (π '/\' γ)@ on a bound thread, with the attachment held
under 'mask' for the whole scope, an arena that owns every reference created
inside it, and a sweep at the end, normal or exceptional.
Its 'After' is applied once the scope has ended, as 'runBO' does.

Refuses with 'AttachRefused' while the interpreter is finalising or after an
@os.fork()@.
Never block, while attached, on another Haskell thread that must attach; use
'detach' first.
-}
attach :: forall γ a. (forall π. Py π (π /\ γ) (After π a)) %1 -> BIO γ a
attach = Unsafe.toLinear \body -> unsafeSystemIOToBO (attachIO body)

-- | 'attach' for a body that has nothing to finalise.
attach_ :: forall γ a. (forall π. Py π (π /\ γ) a) %1 -> BIO γ a
attach_ = Unsafe.toLinear \body -> unsafeSystemIOToBO (attachIO_ body)

attachIO :: forall γ a. (forall π. Py π (π /\ γ) (After π a)) -> IO a
attachIO body = withFreshScope \(Proxy @π) -> runInBoundThread $ mask \restore -> do
  arena <- beginAttach
  r <- try (restore (unsafeRunPy (body @π)))
  case r of
    Left (e :: SomeException) -> do
      c_attachEnd arena 1
      throwIO e
    Right after -> do
      c_attachEnd arena 0
      evaluate (withEnd (UnsafeEnd @π) after)

attachIO_ :: forall γ a. (forall π. Py π (π /\ γ) a) -> IO a
attachIO_ body = withFreshScope \(Proxy @π) -> runInBoundThread $ mask \restore -> do
  arena <- beginAttach
  r <- try (restore (unsafeRunPy (body @π) >>= evaluate))
  case r of
    Left (e :: SomeException) -> do
      c_attachEnd arena 1
      throwIO e
    Right a -> do
      c_attachEnd arena 0
      pure a

beginAttach :: IO (Ptr Arena)
beginAttach = do
  arena <- c_attachBegin
  NonLinear.when (arena == nullPtr) do
    finalizing <- c_isFinalizing
    forked <- c_isForkedChild
    throwIO
      if forked /= 0
        then AttachRefusedForked
        else
          if finalizing /= 0
            then AttachRefusedFinalizing
            else AttachRefusedNoMemory
  pure arena

{- | A nested scope on the same attached thread, with an arena of its own that
is swept when the scope ends.

This is the loop tool: a reference created inside it is @'Bound' (π' '/\' π) t@
and cannot escape, so the early sweep is sound, and a loop that creates one
reference per iteration stays bounded by wrapping the iteration in it.
Every reference of the enclosing scope stays usable inside.
-}
attach' :: forall π γ a. (forall π'. Py (π' /\ π) (π' /\ γ) (After π' a)) %1 -> Py π γ a
attach' = Unsafe.toLinear \body -> unsafeSystemIOToBO (scopeIO body)

-- | 'attach'' for a body with no finaliser: the @srunBO_@ shape.
attach'_ :: forall π γ a. (forall π'. Py (π' /\ π) (π' /\ γ) a) %1 -> Py π γ a
attach'_ = Unsafe.toLinear \body -> unsafeSystemIOToBO (scopeIO_ body)

scopeIO :: forall π γ a. (forall π'. Py (π' /\ π) (π' /\ γ) (After π' a)) -> IO a
scopeIO body = withFreshScope \(Proxy @π') -> mask \restore -> do
  arena <- beginScope
  r <- try (restore (unsafeRunPy (body @π')))
  case r of
    Left (e :: SomeException) -> do
      c_scopeEnd arena 1
      throwIO e
    Right after -> do
      c_scopeEnd arena 0
      evaluate (withEnd (UnsafeEnd @π') after)

scopeIO_ :: forall π γ a. (forall π'. Py (π' /\ π) (π' /\ γ) a) -> IO a
scopeIO_ body = withFreshScope \(Proxy @π') -> mask \restore -> do
  arena <- beginScope
  r <- try (restore (unsafeRunPy (body @π') >>= evaluate))
  case r of
    Left (e :: SomeException) -> do
      c_scopeEnd arena 1
      throwIO e
    Right a -> do
      c_scopeEnd arena 0
      pure a

{- | Push the child arena.
The shim answers @NULL@ when the thread is not attached, which is the one way
to reach a nested scope wrongly, or when it is out of memory; the attachment
check distinguishes the two.
-}
beginScope :: IO (Ptr Arena)
beginScope = do
  arena <- c_scopeBegin
  NonLinear.when (arena == nullPtr) do
    attached <- isAttached
    throwIO (if attached then AttachRefusedNoMemory else AttachRefusedNested)
  pure arena

{- | Release the scope's hold on the interpreter for a window, run a 'BIO'
body, and restore it.

The body has no @π@, so it cannot express a Python operation; it keeps every
Haskell borrow that outlives the window, which includes a payload borrow from
@derefMut@ and a buffer borrow from @withBufferMut@, and it may run 'parBO' and
the scheduler on them.
Releasing is required before any wait on another thread that must attach,
before a long kernel under the GIL, and before any long attached stretch under
free-threading.
-}
detach :: forall π γ r. (forall δ. BIO (δ /\ γ) r) %1 -> Py π γ r
detach = Unsafe.toLinear \body -> unsafeSystemIOToBO (detachIO body)

detachIO :: forall γ r. (forall δ. BIO (δ /\ γ) r) -> IO r
detachIO body = withFreshScope \(Proxy @δ) -> mask \restore -> do
  checkAttached
  ts <- c_detachBegin
  r <- try (restore (unsafeBOToSystemIO (body @δ) >>= evaluate))
  ok <- c_detachEnd ts
  NonLinear.when (ok /= 0) (throwIO DetachRestoreRefused)
  case r of
    Left (e :: SomeException) -> throwIO e
    Right a -> pure a

{- | The world's own fork-join: release, fork, attach afresh in each branch.

Each branch runs on its own thread with its own attachment and arena, and every
reference of the parent scope is usable inside it, the call's arguments
included, because the parent's arena is alive while it waits.
Under the GIL the two attachments serialise and the Haskell work overlaps;
under free-threading both overlap.

@parPy f g@ is @'detach' ('parBO' ('attach_' f) ('attach_' g))@ with one guard
around each branch, see below; a branch that needs neither Python nor a fresh
attachment is better off in @detach (parBO …)@ directly.

=== Exceptions in a branch

pure-borrow's 'parBO' at this version is two @forkIO@s and two @takeMVar@s
with no @try@: a Haskell exception in a branch is printed by the RTS and the
parent blocks forever on the branch's result, which inside a Python process is
a hang with the interpreter attached (section 4.4 of the design; the
structured, propagating version is a later upstream change).
'parPy' therefore runs each branch under 'try' after its own 'attach_' has
released its arena and attachment, so that both branches always complete and
fill their results, and rethrows the first exception once both have: the
exception reaches the trampoline like any other Haskell exception, is raised
in Python, and poisons what the call's arena holds mutably.
What the guard cannot cover is an asynchronous exception delivered to the
parent while it waits, which unwinds the parent and leaves the branches
running to completion on their own; nothing they hold outlives the parent's
arena, because a branch's @π'@ is its own and the parent's references are only
read through it, but their Haskell effects continue.
That residue is the reason the upstream change is still wanted.
-}
parPy ::
  forall π γ a b.
  (forall δ π'. Py π' (π' /\ (δ /\ γ)) a) %1 ->
  (forall δ π'. Py π' (π' /\ (δ /\ γ)) b) %1 ->
  Py π γ (a, b)
parPy = Unsafe.toLinear2 \f g ->
  detach Control.do
    (ra, rb) <- parBO (guarded (attach_ f)) (guarded (attach_ g))
    rethrowBranches ra rb

{- | Run a branch under 'try', so that its exception is reported as a value
rather than left with the RTS while the parent waits.
The result is forced inside the branch, as 'parBO' itself does.
-}

{- | __Interim.__ 'parBO' at 'BIO' with each branch guarded: a Haskell
exception in a branch is caught there, both branches run to completion, and
the first exception is rethrown by the parent, so a failing kernel reaches the
trampoline as a Python exception instead of leaving the parent blocked.

This combinator exists only until pure-borrow's structured 'parBO' lands
(design section 4.4, Phase 0.5), which makes 'parBO' itself behave this way and
also cancels and joins the branches when the parent is interrupted; it is then
removed, and @detach (parBO …)@ is the one shape.
Until then, an asynchronous exception delivered to the waiting parent still
leaves the branches running to completion.
-}
parBIO :: forall γ a b. BIO γ a %1 -> BIO γ b %1 -> BIO γ (a, b)
parBIO = Unsafe.toLinear2 \f g -> Control.do
  (ra, rb) <- parBO (guarded f) (guarded g)
  rethrowBranches ra rb

guarded :: forall γ a. BIO γ a %1 -> BIO γ (Either SomeException a)
guarded = Unsafe.toLinear \body -> unsafeSystemIOToBO (try (unsafeBOToSystemIO body >>= evaluate))

{- | Rethrow the first branch's exception, else the second's, else answer both
results; runs once both branches have completed.
-}
rethrowBranches :: forall γ a b. Either SomeException a %1 -> Either SomeException b %1 -> BIO γ (a, b)
rethrowBranches = Unsafe.toLinear2 \ra rb -> case (ra, rb) of
  (Left e, _) -> unsafeSystemIOToBO (throwIO e)
  (_, Left e) -> unsafeSystemIOToBO (throwIO e)
  (Right a, Right b) -> Control.pure (a, b)
