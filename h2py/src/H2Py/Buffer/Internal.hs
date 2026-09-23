{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# OPTIONS_HADDOCK hide #-}

{- |
Buffers: NumPy arrays and every other exporter of the buffer protocol, as
pure-borrow vectors over memory that Python owns, and Haskell-owned vectors
handed to Python without a copy.
See section 5.7 of the design.

A view is acquired attached and released attached, by 'releaseBuffer' or by
the sweep of the arena that recorded it; the body that runs over it is 'BIO',
detached from the interpreter, so it cannot call back into Python and
invalidate its own view, and it is free to run on every core.
-}
module H2Py.Buffer.Internal (
  module H2Py.Buffer.Internal,
) where

import Control.Functor.Linear qualified as Control
import Control.Monad qualified as NonLinear
import Control.Monad.Borrow.BO (Mut, Share, type (/\), type (>=))
import Control.Monad.Borrow.IO (BIO)
import Control.Monad.Borrow.Lifetime.Internal (Lifetime)
import Control.Monad.Borrow.Unsafe (Alias (..))
import Data.Complex (Complex)
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Foreign qualified as TF
import Data.Vector.Generic.Mutable.Linear.Borrow.Unrestricted qualified as Vector
import Data.Vector.Generic.Mutable.Linear.Borrow.Unrestricted.Internal (Vector (..))
import Data.Vector.Storable qualified as SV
import Data.Vector.Storable.Mutable qualified as SVM
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.C.String (peekCString)
import Foreign.C.Types (CBool)
import Foreign.ForeignPtr (newForeignPtr_, withForeignPtr)
import Foreign.Ptr (Ptr, castPtr, nullPtr, ptrToWordPtr)
import Foreign.StablePtr (castStablePtrToPtr, freeStablePtr, newStablePtr)
import Foreign.Storable (Storable (..))
import GHC.Exts (RealWorld)
import H2Py.Object.Internal
import H2Py.Py.Internal
import H2Py.Runtime.Internal
import Prelude.Linear (Consumable (..), Dupable (..), Movable (..), Ur (..))
import Unsafe.Linear qualified as Unsafe

-- * Vectors over foreign memory

{- | A pure-borrow vector with a 'Storable' backend: the shape every buffer
takes, and the shape the divide-and-conquer kernels of pure-borrow accept
unchanged.
-}
type SVector e = Vector.Vector SV.Vector e

-- * Views

{- | A writable view of a Python buffer, requested through @PyBUF_WRITABLE@.

Linear and affine: dropping it releases nothing, the sweep of the arena that
recorded it does, and 'releaseBuffer' does so early.
It holds the handle it was requested from, since a writable view is a
mutation of the object by protocol, and hands it back on release.

Both parameters are nominal: without the annotation, @coerce@ and the safe
upcast could retag the view's scope or its element type.
-}
data BufferMut (π :: Lifetime) e = BufferMut !(Ptr BufView) !(Ptr PyObject) !(SVM.MVector RealWorld e)

type role BufferMut nominal nominal

-- | The affine no-op: the arena sweep releases the view.
instance Consumable (BufferMut π e) where
  consume = Unsafe.toLinear \_ -> ()

{- | A read-only view of a Python buffer: unrestricted, so any number of
scopes over it may be opened.
-}
data BufferShare (π :: Lifetime) e = BufferShare !(Ptr BufView) !(SVM.MVector RealWorld e)

type role BufferShare nominal nominal

instance Consumable (BufferShare π e) where
  consume = Unsafe.toLinear \_ -> ()

instance Dupable (BufferShare π e) where
  dup2 = Unsafe.toLinear \b -> (b, b)

instance Movable (BufferShare π e) where
  move = Unsafe.toLinear Ur

-- * Element formats

{- | Element types that a buffer may hold: the @struct@-module format
characters accepted for @e@, in native byte order, and the item size the
buffer must report.

Both @l@ and @q@ are accepted for 64-bit integers, since NumPy reports
@int64@ as either depending on the platform's @long@.
-}
class BufferFormat e where
  -- | The accepted format strings, without a byte-order prefix.
  bufferFormats :: Proxy e -> [Text]

  -- | The item size in bytes; a buffer reporting another is refused.
  bufferItemSize :: Proxy e -> Int

  -- | The format 'newArray' exports: the first accepted one.
  bufferExportFormat :: Proxy e -> Text
  bufferExportFormat p = case bufferFormats p of
    (f : _) -> f
    [] -> "B"

instance BufferFormat Double where
  bufferFormats _ = ["d"]
  bufferItemSize _ = 8

instance BufferFormat Float where
  bufferFormats _ = ["f"]
  bufferItemSize _ = 4

instance BufferFormat Int64 where
  bufferFormats _ = ["q", "l"]
  bufferItemSize _ = 8

instance BufferFormat Int32 where
  bufferFormats _ = ["i"]
  bufferItemSize _ = 4

instance BufferFormat Int16 where
  bufferFormats _ = ["h"]
  bufferItemSize _ = 2

instance BufferFormat Int8 where
  bufferFormats _ = ["b"]
  bufferItemSize _ = 1

-- | The machine integer: @q@ or @l@ on a 64-bit platform, @i@ on a 32-bit one.
instance BufferFormat Int where
  bufferFormats _ = if sizeOf (0 :: Int) == 8 then ["q", "l"] else ["i", "l"]
  bufferItemSize _ = sizeOf (0 :: Int)

instance BufferFormat Word64 where
  bufferFormats _ = ["Q", "L"]
  bufferItemSize _ = 8

instance BufferFormat Word32 where
  bufferFormats _ = ["I"]
  bufferItemSize _ = 4

instance BufferFormat Word16 where
  bufferFormats _ = ["H"]
  bufferItemSize _ = 2

instance BufferFormat Word8 where
  bufferFormats _ = ["B"]
  bufferItemSize _ = 1

{- | @Zd@, NumPy's @complex128@: two native doubles, real part first, which
is the layout of base's 'Storable' instance for @Complex Double@.
-}
instance BufferFormat (Complex Double) where
  bufferFormats _ = ["Zd"]
  bufferItemSize _ = 16

{- | @?@ as the one-byte C @bool@, which is what NumPy's @bool_@ and the
@struct@ module export.
-}
instance BufferFormat CBool where
  bufferFormats _ = ["?"]
  bufferItemSize _ = 1

{- | @?@ at the size of Haskell's 'Storable' 'Bool', which is that of a C
@int@; a NumPy @bool_@ buffer reports one byte per item and is therefore
refused with @BufferError@.
Use 'CBool' for those.
-}
instance BufferFormat Bool where
  bufferFormats _ = ["?"]
  bufferItemSize _ = sizeOf (False :: Bool)

-- * Requesting views

{- Note [Buffer views are scoped by the requesting arena]

The shim records a view in the innermost arena of the thread and releases it
when that arena is swept, so a view is valid exactly for the scope that
requested it.
'requestBufferMut' therefore requests at @Py π γ@ and answers @BufferMut π e@:
the view and the handle it keeps share the scope, and a handle of an enclosing
scope is shortened with @upcast@ first.
A request at a general @Py π' γ@ answering @BufferMut π e@ would let the view
outlive the arena that releases it whenever @π'@ ends before @π@.
'requestBufferShare' takes a view of any scope that outlives the borrow and
answers a share indexed by the requesting scope, for the same reason.
-}

{- | Request a writable, C-contiguous view with format information.

The element format is checked against 'BufferFormat', the data pointer's
alignment against 'Storable', and the address range is registered in the
shim's borrow registry as held exclusively; a read-only or non-contiguous
array, a format or item-size mismatch, a misaligned pointer, or a range that
another H2Py scope already holds answers 'Left' with @BufferError@, and the
view is released first.
A multi-dimensional array is presented flattened.

The view is recorded in the arena of @π@, which releases it at its sweep
unless 'releaseBuffer' did so earlier; see Note [Buffer views are scoped by
the requesting arena] in the source.

The honest residual, shared with rust-numpy: the buffer protocol does not
lock the array, so Python code, or a view H2Py did not create, can still
write to it while the view is held.
The disjointness pure-borrow proves is among Haskell borrows.
-}
requestBufferMut :: forall e π γ. (Storable e, BufferFormat e, π >= γ) => Bound π PyAny %1 -> Py π γ (PyResult (BufferMut π e))
requestBufferMut = Unsafe.toLinear \b -> case mutPtr b of
  (p, _) -> unsafePyArena \arena -> do
    view <- c_bufferRequest arena p 1
    if view == nullPtr
      then Left <$> requestFailed
      else do
        r <- checkView @e view
        case r of
          Left e -> do
            c_bufferRelease view
            pure (Left e)
          Right mv -> pure (Right (BufferMut view p mv))

{- | Request a read-only, C-contiguous view with format information, checked
as 'requestBufferMut' checks its view, and registered shared: it is refused
while another H2Py scope holds the range exclusively, and it refuses a later
exclusive request.
-}
requestBufferShare :: forall e π π' γ. (Storable e, BufferFormat e, π >= γ) => Borrowed π PyAny -> Py π' γ (PyResult (BufferShare π' e))
requestBufferShare ref = unsafePyArena \arena -> do
  view <- c_bufferRequest arena (refPtr ref) 0
  if view == nullPtr
    then Left <$> requestFailed
    else do
      r <- checkView @e view
      case r of
        Left e -> do
          c_bufferRelease view
          pure (Left e)
        Right mv -> pure (Right (BufferShare view mv))

{- | The error of a refused request.
NumPy reports a read-only or non-contiguous array as @ValueError@; the
buffer API of this module answers @BufferError@ for every refused request, so
a @ValueError@ is rewritten with its message kept, and any other class, a
@TypeError@ for an object without the protocol or the registry's own
@BufferError@, passes through.
-}
requestFailed :: IO PyErr
requestFailed = do
  e <- takeError
  case e of
    PyErrObject (PyHandle fp) -> withForeignPtr fp \p -> do
      isValueError <- c_isInstance p (builtinExceptionType ExcValueError)
      if isValueError > 0
        then do
          msg <- strLike c_objectStr p
          pure (bufferError (either (const "buffer request refused") id msg))
        else pure e
    PyErrLazy _ _ -> pure e

{- | Check a view's format, item size and alignment, and wrap its data as a
mutable 'Storable' vector over a 'ForeignPtr' with no finaliser: the memory
belongs to the exporter for as long as the view is held.
-}
checkView :: forall e. (Storable e, BufferFormat e) => Ptr BufView -> IO (PyResult (SVM.MVector RealWorld e))
checkView view = do
  fmtPtr <- c_bufferFormat view
  fmt <- if fmtPtr == nullPtr then pure "B" else T.pack <$> peekCString fmtPtr
  itemSize <- c_bufferItemSize view
  nbytes <- c_bufferLen view
  dat <- c_bufferData view
  let accepted = bufferFormats (Proxy @e)
      expectedSize = bufferItemSize (Proxy @e)
      native = maybe fmt id (T.stripPrefix "@" fmt)
      align = alignment (undefined :: e)
  if native `notElem` accepted
    then pure (Left (bufferError ("buffer format '" <> fmt <> "' does not match the requested element type (expected " <> T.intercalate " or " (map (\f -> "'" <> f <> "'") accepted) <> ")")))
    else
      if fromIntegral itemSize /= expectedSize
        then pure (Left (bufferError ("buffer item size " <> T.pack (show itemSize) <> " does not match the requested element size " <> T.pack (show expectedSize))))
        else
          if itemSize <= 0 || nbytes `rem` itemSize /= 0
            then pure (Left (bufferError "buffer length is not a multiple of its item size"))
            else
              if align > 0 && ptrToWordPtr dat `rem` fromIntegral align /= 0
                then pure (Left (bufferError ("buffer data is not aligned to " <> T.pack (show align) <> " bytes")))
                else do
                  -- No finaliser: the exporter owns the memory for as long as the view is held.
                  fp <- newForeignPtr_ (castPtr dat)
                  pure (Right (SVM.unsafeFromForeignPtr0 fp (fromIntegral (nbytes `quot` itemSize))))

-- * Scopes over views

{- | Open a scope over a writable view: the body receives the memory as a
'Mut' borrow of an 'SVector' at a fresh lifetime, runs detached from the
interpreter, and the view comes back so that a second kernel can run on it
without a second request.

The body is 'BIO', not @Py@: it cannot touch Python, which is what makes
exclusive access to the buffer safe from the one way a method could
invalidate its own view, and what lets it run on every core through @parBO@
and the scheduler.
A Haskell exception in the body propagates through the detach window; the
view is then released by the sweep, as any other.
-}
withBufferMut :: forall e π π' γ r. (π >= γ) => BufferMut π e %1 -> (forall α. Mut (α /\ γ) (SVector e) %1 -> BIO (α /\ γ) r) %1 -> Py π' γ (r, BufferMut π e)
withBufferMut = Unsafe.toLinear2 \buf@(BufferMut _ _ mv) body -> Control.do
  r <- detach (runMutBody @e @γ body mv)
  Control.pure (r, buf)

{- | Run the body at the detach window's lifetime.
Trusted: the 'Mut' is the only alias of the vector, the owner never exists
outside this borrow, and the rank-2 @α@ keeps the borrow from escaping into
@r@.
-}
runMutBody :: forall e γ r δ. (forall α. Mut (α /\ γ) (SVector e) %1 -> BIO (α /\ γ) r) %1 -> SVM.MVector RealWorld e -> BIO (δ /\ γ) r
runMutBody body mv = body (UnsafeAlias (Vector mv))

-- | Open a scope over a read-only view; the body receives a 'Share' borrow and runs detached.
withBufferShare :: forall e π π' γ r. (π >= γ) => BufferShare π e -> (forall α. Share (α /\ γ) (SVector e) -> BIO (α /\ γ) r) %1 -> Py π' γ r
withBufferShare (BufferShare _ mv) = Unsafe.toLinear \body -> detach (runShareBody @e @γ body mv)

runShareBody :: forall e γ r δ. (forall α. Share (α /\ γ) (SVector e) -> BIO (α /\ γ) r) -> SVM.MVector RealWorld e -> BIO (δ /\ γ) r
runShareBody body mv = body (UnsafeAlias (Vector mv))

{- | Release a writable view early, with @PyBuffer_Release@ and its registry
entry, and hand the handle back.
Attached; a view that is not released here is released by the sweep of the
arena that recorded it.
-}
releaseBuffer :: forall e π π' γ. BufferMut π e %1 -> Py π' γ (Bound π PyAny)
releaseBuffer = Unsafe.toLinear \(BufferMut view p _) -> unsafePyIO do
  c_bufferRelease view
  pure (unsafeBoundFromPtr p)

{- | Release a shared view early.
Not part of the safe API: a 'BufferShare' is unrestricted, so nothing could
stop a use after the release; the sweep of the arena that recorded the view
releases it, and @attach'@ scopes it tighter.
The shim's release is idempotent and the view's memory lives until the sweep,
so a second call is harmless, but a 'withBufferShare' after it reads memory
the exporter may have reclaimed.
-}
releaseBufferShare :: forall e π π' γ. BufferShare π e -> Py π' γ ()
releaseBufferShare (BufferShare view _) = unsafePyIO (c_bufferRelease view)

-- | The number of elements a writable view holds, without opening a scope.
bufferMutLength :: forall e π. (Storable e) => BufferMut π e %1 -> (Ur Int, BufferMut π e)
bufferMutLength = Unsafe.toLinear \buf@(BufferMut _ _ mv) -> (Ur (SVM.length mv), buf)

-- | The number of elements a read-only view holds.
bufferShareLength :: forall e π. (Storable e) => BufferShare π e -> Int
bufferShareLength (BufferShare _ mv) = SVM.length mv

-- * Exporting Haskell memory

{- | Hand a Haskell-owned vector to Python without a copy.

The result is an @h2py.HsBuffer@, a heap type whose instances export the
vector's pinned memory through the buffer protocol, so @numpy.asarray@ wraps
it without copying and @memoryview@ reads it directly.
A stable pointer to the vector's 'ForeignPtr' keeps the memory alive until
the Python object is deallocated, from whichever thread that happens on.
The vector is consumed: it is Python's now, and a scope over it is obtained
again through 'requestBufferMut'.
-}
newArray :: forall e π γ. (Storable e, BufferFormat e) => SVector e %1 -> Py π γ (PyResult (Bound π PyAny))
newArray = Unsafe.toLinear \(Vector mv) -> newRefOp \_ -> do
  let (fp, n) = SVM.unsafeToForeignPtr0 mv
      itemSize = bufferItemSize (Proxy @e)
  sp <- newStablePtr fp
  obj <- TF.withCString (bufferExportFormat (Proxy @e)) \fmt ->
    withForeignPtr fp \p ->
      c_hsBufferNew (castStablePtrToPtr sp) (castPtr p) (fromIntegral (n * itemSize)) (fromIntegral itemSize) fmt
  NonLinear.when (obj == nullPtr) (freeStablePtr sp)
  pure obj
