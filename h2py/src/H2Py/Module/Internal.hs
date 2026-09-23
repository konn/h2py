{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveLift #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# OPTIONS_HADDOCK hide #-}

{- |
Functions, methods, classes, modules, the trampoline, and the module
description that the stub renders.
See sections 5.4, 5.11 and 5.12 of the design.

Registration is value-level: every combinator builds a 'PyFunction' from a
Haskell function through the 'PyCallable' class over its type, and records an
entry in a 'ModuleDesc'.
What needs a splice is only the instantiation of a lifetime-polymorphic
function inside the trampoline's rank-2 body, which "H2Py.TH" generates.
-}
module H2Py.Module.Internal (
  module H2Py.Module.Internal,
) where

import Control.Exception (SomeException, evaluate, try)
import Control.Functor.Linear qualified as Control
import Control.Monad qualified as NonLinear
import Control.Monad.Borrow.BO (Mut, Share, share, type (/\), type (>=))
import Control.Monad.Borrow.IO (BIO, liftBO)
import Control.Monad.Borrow.Lifetime.Internal (Lifetime (..))
import Control.Monad.Borrow.Pure (BO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Kind (Type)
import Data.List (partition)
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Foreign qualified as TF
import Foreign.C.String (CString, newCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray, mallocArray, peekArray, pokeArray, withArray)
import Foreign.Ptr (FunPtr, Ptr, castFunPtrToPtr, castPtr, castPtrToFunPtr, nullPtr)
import Foreign.Storable (peekElemOff)
import GHC.TypeError (ErrorMessage (..))
import H2Py.Class.Internal
import H2Py.Convert.Internal
import H2Py.Exception.Internal
import H2Py.Object.Internal
import H2Py.Py.Internal
import H2Py.Runtime.Internal
import Language.Haskell.TH.Syntax (Lift)
import Prelude.Linear (Consumable (..), Movable (..), Ur (..), lseq)
import Prelude.Linear.Unsatisfiable (Unsatisfiable, unsatisfiable)
import System.IO.Unsafe (unsafePerformIO)
import Unsafe.Linear qualified as Unsafe

-- * Module descriptions

-- | A parameter of a registered function, for the stub.
data ParamDesc = ParamDesc
  { paramName :: Maybe Text
  -- ^ 'Nothing' renders positional-only.
  , paramHint :: TypeHint
  }
  deriving stock (Show, Eq)

-- | A registered function or method, for the stub.
data FunctionDesc = FunctionDesc
  { functionName :: Text
  , functionParams :: [ParamDesc]
  , functionResult :: TypeHint
  , functionDoc :: Text
  , functionReceiver :: Bool
  -- ^ Renders @self@ first.
  , functionIsConstructor :: Bool
  }
  deriving stock (Show, Eq)

-- | A registered class, for the stub.
data ClassDesc = ClassDesc
  { classDescName :: Text
  , classDescDoc :: Text
  , classDescBases :: [Text]
  , classDescMethods :: [FunctionDesc]
  , classDescSlots :: [FunctionDesc]
  }
  deriving stock (Show, Eq)

-- | A registered exception class, for the stub.
data ExceptionDesc = ExceptionDesc
  { exceptionDescName :: Text
  , exceptionDescBase :: Text
  }
  deriving stock (Show, Eq)

-- | The description of a module: what the initialiser registers and the stub renders.
data ModuleDesc = ModuleDesc
  { moduleDescName :: Text
  , moduleDescDoc :: Text
  , moduleDescFunctions :: [FunctionDesc]
  , moduleDescClasses :: [ClassDesc]
  , moduleDescExceptions :: [ExceptionDesc]
  , moduleDescSubmodules :: [ModuleDesc]
  }
  deriving stock (Show, Eq)

-- * Argument and result conversion at the call boundary

{- | Arguments of a registered function: converted from the lent handle the
trampoline wraps each argument in.
Indexed by the call's attachment @π@, which is what a single-parameter class
over the reference types could not express.
-}
class FromArg (π :: Lifetime) a where
  -- | The hint the stub renders for this argument.
  argHint :: Proxy π -> Proxy a -> TypeHint

  -- | Convert the lent argument.
  fromArg :: Bound π PyAny %1 -> Py π π (PyResult a)

instance {-# OVERLAPPABLE #-} (FromPy a) => FromArg π a where
  argHint _ _ = pyTypeHint (Proxy @a)
  fromArg = Unsafe.toLinear \b -> case share b of
    Ur v -> fromPy v

{- | The hint of a reference tag: the tag's Python name, with the type
arguments a strict type checker wants on the built-in containers.
-}
tagHint :: forall t. (PyTypeOf t) => Proxy t -> TypeHint
tagHint p = case pyTypeName p of
  "list" -> TApply "list" [TAny]
  "tuple" -> TName "tuple[Any, ...]"
  "dict" -> TApply "dict" [TAny, TAny]
  "set" -> TApply "set" [TAny]
  name -> TName name

-- | The lent handle itself, after a type check.
instance {-# OVERLAPPING #-} (PyTypeOf t, π ~ π') => FromArg π (Bound π' t) where
  argHint _ _ = tagHint (Proxy @t)
  fromArg = Unsafe.toLinear \b -> case mutPtr b of
    (p, b') -> unsafePyIO do
      ty <- sealedTypeOf (Proxy @t)
      ok <- c_isInstance p ty
      if ok > 0
        then pure (Right (unsafeRetagMut b'))
        else Left <$> conversionError (pyTypeName (Proxy @t)) p

-- | The handle 'share'd into a view, after a type check.
instance {-# OVERLAPPING #-} (PyTypeOf t, π ~ π') => FromArg π (Borrowed π' t) where
  argHint _ _ = tagHint (Proxy @t)
  fromArg = Unsafe.toLinear \b -> case share b of
    Ur v -> unsafePyIO do
      let p = refPtr v
      ty <- sealedTypeOf (Proxy @t)
      ok <- c_isInstance p ty
      if ok > 0
        then pure (Right (unsafeRetagShare v))
        else Left <$> conversionError (pyTypeName (Proxy @t)) p

{- | Results of a registered function: converted, or incref'd out of the arena,
into the +1 the trampoline hands back to Python.
-}
class ToResult (π :: Lifetime) a where
  resultHint :: Proxy π -> Proxy a -> TypeHint
  toResult :: a %1 -> Py π π (PyResult (Bound π PyAny))

instance {-# OVERLAPPABLE #-} (ToPy a) => ToResult π a where
  resultHint _ _ = pyTypeHint (Proxy @a)
  toResult a = toPy a

instance {-# OVERLAPPING #-} (PyTypeOf t, π' >= π) => ToResult π (Bound π' t) where
  resultHint _ _ = tagHint (Proxy @t)
  toResult = Unsafe.toLinear \b -> case mutPtr b of
    (p, _) -> unsafePyArena \arena -> do
      c_incref p
      c_arenaRegister arena p
      pure (Right (unsafeBoundFromPtr p))

instance {-# OVERLAPPING #-} (PyTypeOf t, π' >= π) => ToResult π (Borrowed π' t) where
  resultHint _ _ = tagHint (Proxy @t)
  toResult = Unsafe.toLinear \v -> unsafePyArena \arena -> do
    let p = refPtr v
    c_incref p
    c_arenaRegister arena p
    pure (Right (unsafeBoundFromPtr p))

instance {-# OVERLAPPING #-} (ToResult π a) => ToResult π (PyResult a) where
  resultHint p _ = resultHint p (Proxy @a)
  toResult = \case
    Left e -> Control.pure (Left e)
    Right a -> toResult @π a

instance {-# OVERLAPPING #-} ToResult π () where
  resultHint _ _ = TNone
  toResult () = Control.fmap rightAny none

-- * Callables

{- | A Haskell function callable from Python at the call's attachment @π@:
each argument is converted by 'FromArg', the result by 'ToResult'.
The body may be @'Py' π π r@, @'BO' π r@ (lifted), or @'BIO' π r@ (run under
'detach', the interpreter released).
-}
class PyCallable (π :: Lifetime) f where
  -- | The hints of the arguments, left to right, and of the result.
  callableHints :: Proxy π -> Proxy f -> ([TypeHint], TypeHint)

  {- | Apply the function to the bound arguments, which the trampoline lends.
  The function is taken linearly because it may be a partial application
  that captured a lent handle.
  -}
  callWith :: f %1 -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))

instance {-# OVERLAPPABLE #-} (FromArg π a, PyCallable π r) => PyCallable π (a %1 -> r) where
  callableHints p _ = case callableHints p (Proxy @r) of
    (args, res) -> (argHint p (Proxy @a) : args, res)
  callWith = Unsafe.toLinear \f -> \case
    [] -> Control.pure (Left (typeError "H2Py: too few arguments bound for the call"))
    (b : bs) -> Control.do
      r <- fromArg @π b
      applyLinear f r bs

-- | Continue a call after converting one argument; dropping the function on 'Left' drops only lent, affine handles.
applyLinear :: forall π a r. (PyCallable π r) => (a %1 -> r) -> PyResult a %1 -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))
applyLinear _ (Left e) bs = consumeAll bs `lseq` Control.pure (Left e)
applyLinear f (Right a) bs = callWith @π (f a) bs

instance {-# OVERLAPPABLE #-} (FromArg π a, PyCallable π r) => PyCallable π (a -> r) where
  callableHints p _ = case callableHints p (Proxy @r) of
    (args, res) -> (argHint p (Proxy @a) : args, res)
  callWith = Unsafe.toLinear \f -> \case
    [] -> Control.pure (Left (typeError "H2Py: too few arguments bound for the call"))
    (b : bs) -> Control.do
      r <- fromArg @π b
      applyLinear (Unsafe.toLinear f) r bs

instance {-# OVERLAPPING #-} (ToResult π a, π ~ π', π ~ γ) => PyCallable π (Py π' γ a) where
  callableHints p _ = ([], resultHint p (Proxy @a))
  callWith body = \case
    [] -> Control.do
      a <- body
      toResult @π a
    bs -> Unsafe.toLinear (\_ -> consumeAll bs `lseq` Control.pure (Left (typeError "H2Py: too many arguments bound for the call"))) body

instance {-# OVERLAPPING #-} (ToResult π a, π ~ γ) => PyCallable π (BO γ a) where
  callableHints p _ = ([], resultHint p (Proxy @a))
  callWith body = \case
    [] -> Control.do
      a <- liftBO body
      toResult @π a
    bs -> Unsafe.toLinear (\_ -> consumeAll bs `lseq` Control.pure (Left (typeError "H2Py: too many arguments bound for the call"))) body

-- | A 'BIO' body runs detached, with the borrow lifetime shortened to the window.
instance {-# OVERLAPPING #-} (ToResult π a, π ~ γ) => PyCallable π (BIO γ a) where
  callableHints p _ = ([], resultHint p (Proxy @a))
  callWith body = \case
    [] -> Control.do
      a <- detach (unsafeShortenBIO body)
      toResult @π a
    bs -> Unsafe.toLinear (\_ -> consumeAll bs `lseq` Control.pure (Left (typeError "H2Py: too many arguments bound for the call"))) body

{- | Run a @BIO γ@ body at the window's @δ '/\' γ@.
Sound: a computation at a longer lifetime is usable at a shorter one, which is
the @<:@ instance of the monad; spelled out here for a rank-2 position.
-}
unsafeShortenBIO :: forall γ δ a. BIO γ a %1 -> BIO (δ /\ γ) a
unsafeShortenBIO x = Unsafe.coerce x

-- | Consume leftover lent handles: the affine no-op.
consumeAll :: [Bound π PyAny] %1 -> ()
consumeAll = \case
  [] -> ()
  (b : bs) -> consume b `lseq` consumeAll bs

{- | A registered detached body: a pure or effectful function marked to run
with the interpreter released, for a long kernel.
-}
newtype Detached f = Detached f

instance {-# OVERLAPPING #-} (FromArg π a, PyCallable π (Detached r)) => PyCallable π (Detached (a %1 -> r)) where
  callableHints p _ = case callableHints p (Proxy @(Detached r)) of
    (args, res) -> (argHint p (Proxy @a) : args, res)
  callWith = Unsafe.toLinear \(Detached f) -> \case
    [] -> Control.pure (Left (typeError "H2Py: too few arguments bound for the call"))
    (b : bs) -> Control.do
      r <- fromArg @π b
      applyLinear (\x -> Detached (f x)) r bs

instance {-# OVERLAPPING #-} (FromArg π a, PyCallable π (Detached r)) => PyCallable π (Detached (a -> r)) where
  callableHints p _ = case callableHints p (Proxy @(Detached r)) of
    (args, res) -> (argHint p (Proxy @a) : args, res)
  callWith = Unsafe.toLinear \(Detached f) -> \case
    [] -> Control.pure (Left (typeError "H2Py: too few arguments bound for the call"))
    (b : bs) -> Control.do
      r <- fromArg @π b
      applyLinear (\x -> Detached (Unsafe.toLinear f x)) r bs

-- | A pure body registered detached: run with the interpreter released, as a long pure kernel should.
instance {-# OVERLAPPING #-} (ToResult π a, π ~ γ) => PyCallable π (Detached (BO γ a)) where
  callableHints p _ = ([], resultHint p (Proxy @a))
  callWith (Detached body) = \case
    [] -> Control.do
      a <- detach (unsafeShortenBIO (liftBO body))
      toResult @π a
    bs -> Unsafe.toLinear (\_ -> consumeAll bs `lseq` Control.pure (Left (typeError "H2Py: too many arguments bound for the call"))) body

instance {-# OVERLAPPING #-} (ToResult π a, π ~ γ) => PyCallable π (Detached (BIO γ a)) where
  callableHints p _ = ([], resultHint p (Proxy @a))
  callWith (Detached body) = \case
    [] -> Control.do
      a <- detach (unsafeShortenBIO body)
      toResult @π a
    bs -> Unsafe.toLinear (\_ -> consumeAll bs `lseq` Control.pure (Left (typeError "H2Py: too many arguments bound for the call"))) body

{- | A @Py@ body cannot run detached; the marker is ignored.
| A @Py@ body cannot run detached: it needs the attachment it would give up.
-}
instance
  ( Unsatisfiable
      ( 'Text "detached: a Py body cannot run with the interpreter released."
          ':$$: 'Text "Mark only a BO or BIO body as detached, or run detach inside the Py body."
      )
  ) =>
  PyCallable π (Detached (Py π' γ a))
  where
  callableHints = unsatisfiable
  callWith = unsatisfiable

-- | Instantiate a lifetime-polymorphic function at the call's attachment, which the proxy names.
callWithAt :: forall π f. (PyCallable π f) => Proxy π -> f %1 -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))
callWithAt _ = callWith @π

-- | The hints of a function, at any attachment.
callableHintsAt :: forall π f. (PyCallable π f) => Proxy π -> f -> ([TypeHint], TypeHint)
callableHintsAt p _ = callableHints p (Proxy @f)

-- * Methods: receiver forms

{- | A method of the class @a@: a function whose first parameter is the
receiver, in one of four forms.
@'Mut' π a %1 ->@ and @'Share' π a ->@ are the dereferenced payload, PyO3's
@&mut self@ and @&self@; @'Bound' π a %1 ->@ and @'Borrowed' π a ->@ are the
object itself.
-}
class PyMethod (π :: Lifetime) a f where
  methodHints :: Proxy π -> Proxy a -> Proxy f -> ([TypeHint], TypeHint)
  callMethodWith :: f %1 -> Bound π a %1 -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))

instance {-# OVERLAPPING #-} (PyClass a, PyCallable π r, π ~ π', a ~ a') => PyMethod π a (Mut π' a' %1 -> r) where
  methodHints p _ _ = callableHints p (Proxy @r)
  callMethodWith = Unsafe.toLinear \f self args -> Control.do
    r <- derefMut self
    applyLinear f r args

instance {-# OVERLAPPING #-} (PyClass a, PyCallable π r, π ~ π', a ~ a') => PyMethod π a (Share π' a' -> r) where
  methodHints p _ _ = callableHints p (Proxy @r)
  callMethodWith = Unsafe.toLinear \f self args -> case share self of
    Ur v -> Control.do
      r <- derefShare v
      applyShared f r args

-- | Continue a shared-receiver call after the dereference.
applyShared :: forall π a r. (PyCallable π r) => (a -> r) -> PyResult (Ur a) %1 -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))
applyShared _ (Left e) args = consumeAll args `lseq` Control.pure (Left e)
applyShared f (Right (Ur s)) args = callWith @π (f s) args

instance {-# OVERLAPPING #-} (PyCallable π r, π ~ π', a ~ a') => PyMethod π a (Bound π' a' %1 -> r) where
  methodHints p _ _ = callableHints p (Proxy @r)
  callMethodWith f self args = callWith @π (f self) args

instance {-# OVERLAPPING #-} (PyCallable π r, π ~ π', a ~ a') => PyMethod π a (Borrowed π' a' -> r) where
  methodHints p _ _ = callableHints p (Proxy @r)
  callMethodWith = Unsafe.toLinear \f self args -> case share self of
    Ur v -> callWith @π (f v) args

{- | The by-value receiver of a frozen class: the payload is read, not
dereferenced, since a frozen class keeps no lend word.
-}
instance {-# OVERLAPPABLE #-} (PyFrozenClass a, PyCallable π r, a ~ a') => PyMethod π a (a' -> r) where
  methodHints p _ _ = callableHints p (Proxy @r)
  callMethodWith = Unsafe.toLinear \f self args -> case share self of
    Ur v -> Control.do
      r <- readFrozen v
      applyFrozen f r args

-- | Continue a by-value call after reading the frozen payload.
applyFrozen :: forall π a r. (Movable a, PyCallable π r) => (a -> r) -> PyResult a %1 -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))
applyFrozen _ (Left e) args = consumeAll args `lseq` Control.pure (Left e)
applyFrozen f (Right v) args = case move v of
  Ur x -> callWith @π (f x) args

instance {-# OVERLAPPABLE #-} (PyFrozenClass a, PyCallable π (Detached r), a ~ a') => PyMethod π a (Detached (a' -> r)) where
  methodHints p _ _ = callableHints p (Proxy @(Detached r))
  callMethodWith = Unsafe.toLinear \(Detached f) self args -> case share self of
    Ur v -> Control.do
      r <- readFrozen v
      applyFrozen (\x -> Detached (f x)) r args

instance {-# OVERLAPPING #-} (PyClass a, PyCallable π (Detached r), π ~ π', a ~ a') => PyMethod π a (Detached (Mut π' a' %1 -> r)) where
  methodHints p _ _ = callableHints p (Proxy @(Detached r))
  callMethodWith = Unsafe.toLinear \(Detached f) self args -> Control.do
    r <- derefMut self
    applyLinear (\m -> Detached (f m)) r args

instance {-# OVERLAPPING #-} (PyClass a, PyCallable π (Detached r), π ~ π', a ~ a') => PyMethod π a (Detached (Share π' a' -> r)) where
  methodHints p _ _ = callableHints p (Proxy @(Detached r))
  callMethodWith = Unsafe.toLinear \(Detached f) self args -> case share self of
    Ur v -> Control.do
      r <- derefShare v
      applyShared (\sh -> Detached (f sh)) r args

instance {-# OVERLAPPING #-} (PyCallable π (Detached r), π ~ π', a ~ a') => PyMethod π a (Detached (Bound π' a' %1 -> r)) where
  methodHints p _ _ = callableHints p (Proxy @(Detached r))
  callMethodWith (Detached f) self args = callWith @π (Detached (f self)) args

instance {-# OVERLAPPING #-} (PyCallable π (Detached r), π ~ π', a ~ a') => PyMethod π a (Detached (Borrowed π' a' -> r)) where
  methodHints p _ _ = callableHints p (Proxy @(Detached r))
  callMethodWith = Unsafe.toLinear \(Detached f) self args -> case share self of
    Ur v -> callWith @π (Detached (f v)) args

-- | Instantiate a lifetime-polymorphic method at the call's attachment.
callMethodAt :: forall a π f. (PyMethod π a f) => Proxy π -> f %1 -> Bound π PyAny %1 -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))
callMethodAt _ f self args = callMethodWith @π @a f (unsafeRetagMut self) args

-- | The hints of a method, at any attachment.
methodHintsAt :: forall a π f. (PyMethod π a f) => Proxy π -> f -> ([TypeHint], TypeHint)
methodHintsAt p _ = methodHints p (Proxy @a) (Proxy @f)

-- * The trampoline

{- | Run a call's body: under 'mask', drain the pool, push an arena, run on the
calling thread, which is bound because every entry from foreign code is.
On success the result's +1 is taken out of the arena by an incref, the arena
is swept, and the pointer returned; a 'Left' sets its error and returns @NULL@;
a Haskell exception becomes a Python exception through 'ToPyErr', poisons the
arena's mutable holds, and returns @NULL@.
No Haskell exception ever leaves.
-}
runPyCall :: (forall π. Proxy π -> Py π π (PyResult (Bound π PyAny))) -> IO (Ptr PyObject)
runPyCall body =
  withCallArena
    nullPtr
    ( \_ -> withFreshScope \(p :: Proxy π) -> do
        r <- unsafeRunPy (body p) >>= evaluate
        case r of
          Right b -> case mutPtr b of
            (ptr, _) -> do
              c_incref ptr
              pure ptr
          Left e -> do
            raiseErr e
            pure nullPtr
    )
    (\e -> raiseErr (someExceptionToPyErr e))

{- | The trampoline for a slot that answers a scalar: the failure sentinel is
returned after the error is raised.
-}
runPyCallScalar :: x -> (forall π. Proxy π -> Py π π (PyResult x)) -> IO x
runPyCallScalar failed body =
  withCallArena
    failed
    ( \_ -> withFreshScope \(p :: Proxy π) -> do
        r <- unsafeRunPy (body p) >>= evaluate
        case r of
          Right x -> pure x
          Left e -> do
            raiseErr e
            pure failed
    )
    (\e -> raiseErr (someExceptionToPyErr e))

-- | The parameter names of a registration, as a table the shim binds against; never freed.
newtype ParamNames = ParamNames (Ptr CString)

-- | Allocate the name table.  @Nothing@ marks a positional-only parameter.
newParamNames :: [Maybe Text] -> IO ParamNames
newParamNames names = do
  cstrs <- NonLinear.mapM (maybe (pure nullPtr) (newCString . T.unpack)) names
  ParamNames <$> newArrayNoFree cstrs

newArrayNoFree :: [CString] -> IO (Ptr CString)
newArrayNoFree xs = do
  p <- mallocArray (max 1 (length xs))
  pokeArray p xs
  pure p

{- | Bind the fastcall argument vector against the parameter names, and hand
the bound arguments to the body as lent handles.
-}
bindArguments :: Int -> ParamNames -> Ptr (Ptr PyObject) -> PySSize -> Ptr PyObject -> (forall π. Proxy π -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))) -> IO (Ptr PyObject)
bindArguments nparams (ParamNames names) args nargs kwnames body =
  allocaArray (max 1 nparams) \out -> do
    rc <- c_bindArgs args nargs kwnames names (fromIntegral nparams) out
    if rc < 0
      then pure nullPtr
      else do
        ptrs <- peekArray nparams out
        runPyCall \p -> body p (map unsafeBoundFromPtr ptrs)

-- * Registration values

-- | A function pointer with its calling convention, plus the description.
data PyFunction = PyFunction
  { pyFunctionDesc :: FunctionDesc
  , pyFunctionPtr :: FunPtr FastCall
  }

-- | Options on a registration: parameter names, hints, docstring.
data FunctionOptions = FunctionOptions
  { optParamNames :: [(Int, Text)]
  , optHints :: [(Int, TypeHint)]
  , optResultHint :: Maybe TypeHint
  , optDoc :: Text
  }
  deriving stock (Show, Eq, Lift)

defaultFunctionOptions :: FunctionOptions
defaultFunctionOptions = FunctionOptions [] [] Nothing ""

-- | Name parameter @i@ (zero-based); unnamed parameters render positional-only.
param :: Int -> Text -> FunctionOptions -> FunctionOptions
param i name o = o {optParamNames = (i, name) : optParamNames o}

-- | Replace the derived hint of parameter @i@ with a literal.
hint :: Int -> Text -> FunctionOptions -> FunctionOptions
hint i h o = o {optHints = (i, TName h) : optHints o}

-- | Replace the derived result hint with a literal.
resultAs :: Text -> FunctionOptions -> FunctionOptions
resultAs h o = o {optResultHint = Just (TName h)}

-- | A docstring.
doc :: Text -> FunctionOptions -> FunctionOptions
doc d o = o {optDoc = d}

-- | Build the description of a registration from the callable's hints and the options.
describe :: Text -> Bool -> Bool -> ([TypeHint], TypeHint) -> FunctionOptions -> FunctionDesc
describe name receiver ctor (argHints, resHint) opts =
  FunctionDesc
    { functionName = name
    , functionParams =
        [ ParamDesc (lookup i (optParamNames opts)) (maybe h id (lookup i (optHints opts)))
        | (i, h) <- zip [0 ..] argHints
        ]
    , functionResult = maybe resHint id (optResultHint opts)
    , functionDoc = optDoc opts
    , functionReceiver = receiver
    , functionIsConstructor = ctor
    }

-- | The names table of a description.
descParamNames :: FunctionDesc -> [Maybe Text]
descParamNames d = map paramName (functionParams d)

{- | Make the adjustor of a module-level function from a rank-2 body.
The splice @fn@ supplies the body; see "H2Py.TH".
-}
makeFunction :: FunctionDesc -> (forall π. Proxy π -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))) -> IO PyFunction
makeFunction desc body = do
  names <- newParamNames (descParamNames desc)
  let n = length (functionParams desc)
  ptr <- mkFastCall \_self args nargs kwnames -> bindArguments n names args nargs kwnames body
  pure (PyFunction desc ptr)

{- | Make the adjustor of a method from a rank-2 body over the receiver.
The first C argument is @self@, lent by the frame.
-}
makeMethod :: FunctionDesc -> (forall π. Proxy π -> Bound π PyAny -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))) -> IO PyFunction
makeMethod desc body = do
  names <- newParamNames (descParamNames desc)
  let n = length (functionParams desc)
  ptr <- mkFastCall \self args nargs kwnames ->
    bindArguments n names args nargs kwnames \p bound -> body p (unsafeBoundFromPtr self) bound
  pure (PyFunction desc ptr)

-- * Classes

-- | A slot registration: the slot id and its adjustor.
data SlotEntry = SlotEntry
  { slotId :: CInt
  , slotFunc :: Ptr ()
  }

{- | What one 'H2Py.Class.Slot.Slot' registers: type slots, methods for the
protocols that have no slot (@__enter__@ and @__exit__@), and the dunders the
stub renders.
-}
data SlotRegistration = SlotRegistration
  { srSlots :: [SlotEntry]
  , srMethods :: [PyFunction]
  , srDescs :: [FunctionDesc]
  , srSetItem :: Maybe ObjObjArgProc
  -- ^ The assignment half of @mp_ass_subscript@, which 'finishClassRegistration' merges with the deletion half.
  , srDelItem :: Maybe ObjObjArgProc
  }

instance Semigroup SlotRegistration where
  SlotRegistration a b c d e <> SlotRegistration a' b' c' d' e' = SlotRegistration (a <> a') (b <> b') (c <> c') (firstJust d d') (firstJust e e')
    where
      firstJust (Just x) _ = Just x
      firstJust Nothing y = y

instance Monoid SlotRegistration where
  mempty = SlotRegistration [] [] [] Nothing Nothing

-- | A registration of type slots only.
slotsOnly :: [SlotEntry] -> [FunctionDesc] -> SlotRegistration
slotsOnly entries descs = mempty {srSlots = entries, srDescs = descs}

-- | A constructor: its description and the rank-2 body the @tp_new@ trampoline runs.
data ConstructorReg = ConstructorReg FunctionDesc (forall π. Proxy π -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny)))

-- | A proxy at some attachment, for computing hints, which do not depend on it.
scopeProxy :: Proxy ('Al 0)
scopeProxy = Proxy

-- | Everything a class registers.
data ClassRegistration = ClassRegistration
  { classRegName :: Text
  , classRegDoc :: Text
  , classRegTypeCell :: TypeCell
  , classRegDealloc :: Ptr PyTypeObject -> (Ptr PyObject -> IO ()) -> Ptr PyObject -> IO ()
  -- ^ The deallocator, given the type and the action that finishes the deallocation.
  , classRegConstructor :: Maybe ConstructorReg
  , classRegMethods :: [PyFunction]
  , classRegSlots :: [SlotEntry]
  , classRegSlotDescs :: [FunctionDesc]
  , classRegSubclassable :: Bool
  , classRegBases :: [Text]
  , classRegAbcs :: [Text]
  , classRegBase :: Maybe TypeCell
  -- ^ The cell of the Haskell class this one extends.
  , classRegSetItem :: Maybe ObjObjArgProc
  , classRegDelItem :: Maybe ObjObjArgProc
  -- ^ The halves of @mp_ass_subscript@, merged into one slot by 'finishClassRegistration'.
  }

-- | The options @pyclass@ records for @pymethods@ to pick up.
data ClassOptions = ClassOptions
  { coSubclassable :: Bool
  , coAbcs :: [Text]
  , coBase :: Maybe TypeCell
  , coBaseName :: Maybe Text
  }

-- | @Py_TPFLAGS_DEFAULT@.
tpFlagsDefault :: Integer
tpFlagsDefault = 0

-- | @Py_TPFLAGS_BASETYPE@.
tpFlagsBaseType :: Integer
tpFlagsBaseType = 1024

-- | @Py_TPFLAGS_DISALLOW_INSTANTIATION@.
tpFlagsDisallowInstantiation :: Integer
tpFlagsDisallowInstantiation = 128

-- | @Py_TPFLAGS_IMMUTABLETYPE@.
tpFlagsImmutableType :: Integer
tpFlagsImmutableType = 256

slotTpDealloc, slotTpNew, slotTpMethods, slotTpRepr, slotTpStr, slotTpHash, slotTpRichCompare, slotTpCall, slotTpIter, slotTpIterNext, slotSqLength, slotSqContains, slotMpSubscript, slotMpAssSubscript, slotMpLength, slotNbBool, slotBfGetBuffer, slotBfReleaseBuffer, slotTpBase :: CInt
slotTpDealloc = 52
slotTpNew = 65
slotTpMethods = 64
slotTpRepr = 66
slotTpStr = 70
slotTpHash = 59
slotTpRichCompare = 67
slotTpCall = 50
slotTpIter = 62
slotTpIterNext = 63
slotSqLength = 45
slotSqContains = 41
slotMpSubscript = 5
slotMpAssSubscript = 3
slotMpLength = 4
slotNbBool = 9
slotBfGetBuffer = 1
slotBfReleaseBuffer = 2
slotTpBase = 48

-- | The @Py_nb_*@ slot ids of CPython's @typeslots.h@.
slotNbAdd, slotNbSubtract, slotNbMultiply, slotNbTrueDivide, slotNbFloorDivide, slotNbRemainder, slotNbPower, slotNbNegative, slotNbPositive, slotNbAbsolute, slotNbInvert, slotNbInplaceAdd, slotNbInplaceSubtract, slotNbInplaceMultiply :: CInt
slotNbAdd = 7
slotNbSubtract = 36
slotNbMultiply = 29
slotNbTrueDivide = 37
slotNbFloorDivide = 12
slotNbRemainder = 34
slotNbPower = 33
slotNbNegative = 30
slotNbPositive = 32
slotNbAbsolute = 6
slotNbInvert = 27
slotNbInplaceAdd = 14
slotNbInplaceSubtract = 23
slotNbInplaceMultiply = 18

-- | @METH_FASTCALL | METH_KEYWORDS@.
methFastCallKeywords :: CInt
methFastCallKeywords = 0x80 + 0x02

-- | Build a @PyMethodDef@ table from functions; never freed.
makeMethodDefs :: [PyFunction] -> IO (Ptr ())
makeMethodDefs fs = do
  defs <- c_methodDefsNew (fromIntegral (length fs))
  NonLinear.forM_ (zip [0 ..] fs) \(i, PyFunction desc ptr) ->
    TF.withCString (functionName desc) \cname ->
      TF.withCString (functionDoc desc) \cdoc ->
        c_methodDefSet defs i cname (castFunPtrToPtr ptr) methFastCallKeywords (if T.null (functionDoc desc) then nullPtr else cdoc)
  pure defs

-- | Whether a registration has a method of the given name.
hasMethodNamed :: Text -> ClassRegistration -> Bool
hasMethodNamed name reg = any ((== name) . functionName . pyFunctionDesc) (classRegMethods reg)

-- | Whether a registration fills the given type slot.
hasSlot :: CInt -> ClassRegistration -> Bool
hasSlot ident reg = any ((== ident) . slotId) (classRegSlots reg)

{- | Apply the rules CPython and PyO3 apply to protocol slots: @__enter__@
returns a new reference to @self@ when only @__exit__@ is registered,
@__iter__@ returns @self@ when @__next__@ is registered without it, and a class
with comparisons but no hash gets @__hash__ = None@.
What @pymethods@ generates calls this last.
-}
finishClassRegistration :: ClassRegistration -> IO ClassRegistration
finishClassRegistration regIn = do
  reg0 <- case (classRegSetItem regIn, classRegDelItem regIn) of
    (Nothing, Nothing) -> pure regIn
    (setter, deleter) -> do
      ptr <- mkObjObjArgProc \self key value ->
        if value == nullPtr
          then case deleter of
            Just del -> del self key value
            Nothing -> refuse "this object does not support item deletion"
          else case setter of
            Just set -> set self key value
            Nothing -> refuse "this object does not support item assignment"
      pure regIn {classRegSlots = classRegSlots regIn <> [SlotEntry slotMpAssSubscript (castFunPtrToPtr ptr)], classRegSetItem = Nothing, classRegDelItem = Nothing}
  reg1 <-
    if hasMethodNamed "__exit__" reg0 && not (hasMethodNamed "__enter__" reg0)
      then do
        let desc = FunctionDesc "__enter__" [] (TName (classRegName reg0)) "" True False
        enter <- makeMethod desc \_ self _ -> Control.pure (Right self)
        pure reg0 {classRegMethods = classRegMethods reg0 <> [enter]}
      else pure reg0
  reg2 <-
    if hasSlot slotTpIterNext reg1 && not (hasSlot slotTpIter reg1)
      then do
        ptr <- mkUnaryFunc \self -> do
          c_incref self
          pure self
        let desc = FunctionDesc "__iter__" [] (TName (classRegName reg1)) "" True False
        pure reg1 {classRegSlots = classRegSlots reg1 <> [SlotEntry slotTpIter (castFunPtrToPtr ptr)], classRegSlotDescs = classRegSlotDescs reg1 <> [desc]}
      else pure reg1
  if hasSlot slotTpRichCompare reg2 && not (hasSlot slotTpHash reg2)
    then do
      notImplemented <- c_hashNotImplemented
      pure reg2 {classRegSlots = classRegSlots reg2 <> [SlotEntry slotTpHash notImplemented]}
    else pure reg2
  where
    refuse msg = do
      raiseErr (typeError msg)
      pure (-1)

{- | Create the heap type of a class inside the module, fill its cell, and add
it to the module.  Attached, at module initialisation.
A class whose cell is already filled, because another module registered it
first, is only added to this module.
-}
registerClass :: Ptr PyObject -> ClassRegistration -> IO (PyResult ())
registerClass modul reg = do
  let cell = classRegTypeCell reg
  existing <- readTypeCell cell
  if existing /= nullPtr
    then addToModule existing
    else do
      ebase <- baseType
      case ebase of
        Left e -> pure (Left e)
        Right base -> createType base
  where
    addToModule ty = do
      rc <- TF.withCString (classRegName reg) \cname -> c_moduleAddObjectRef modul cname ty
      if rc < 0 then Left <$> takeError else pure (Right ())
    baseType = case classRegBase reg of
      Nothing -> pure (Right nullPtr)
      Just baseCell -> do
        base <- readTypeCell baseCell
        pure
          if base == nullPtr
            then Left (runtimeError ("H2Py: the base class of " <> classRegName reg <> " has not been registered; list base classes before their subclasses"))
            else Right base
    -- The dealloc adjustor needs the type; the type needs the dealloc.  Create
    -- the type first with a trampoline that reads the cell, which is filled
    -- before any instance can exist.  A class that extends another finishes
    -- through the parent's dealloc, which finishes through the actual type.
    finishDealloc = case classRegBase reg of
      Nothing -> c_finishDealloc
      Just baseCell -> \self -> do
        base <- readTypeCell baseCell
        parentDealloc <- c_typeGetSlot (castPtr base) slotTpDealloc
        callDestructor (castPtrToFunPtr parentDealloc) self
    createType base = do
      let cell = classRegTypeCell reg
      basicSize <- c_cellBasicSize
      deallocPtr <- mkDestructor \self -> do
        ty <- readTypeCell cell
        classRegDealloc reg (castPtr ty) finishDealloc self
      methods <- makeMethodDefs (classRegMethods reg)
      ctorSlot <- case classRegConstructor reg of
        Nothing -> pure []
        Just (ConstructorReg desc body) -> do
          names <- newParamNames (descParamNames desc)
          let n = length (functionParams desc)
          newPtr <- mkNewFunc \ty args kwargs -> do
            own <- readTypeCell cell
            constructorTrampoline (castPtr own) n names ty args kwargs body
          pure [SlotEntry slotTpNew (castFunPtrToPtr newPtr)]
      let entries =
            [SlotEntry slotTpDealloc (castFunPtrToPtr deallocPtr), SlotEntry slotTpMethods methods]
              <> ctorSlot
              <> classRegSlots reg
          flags =
            tpFlagsDefault
              + (if classRegSubclassable reg then tpFlagsBaseType else 0)
              + (case classRegConstructor reg of Nothing -> tpFlagsDisallowInstantiation; Just _ -> 0)
      modName <- moduleNameOf modul
      ty <- TF.withCString (modName <> "." <> classRegName reg) \cname ->
        TF.withCString (classRegDoc reg) \cdoc ->
          withArray (map slotId entries) \ids ->
            withArray (map slotFunc entries) \funcs ->
              c_makeType modul cname (if T.null (classRegDoc reg) then nullPtr else cdoc) basicSize (fromIntegral flags) ids funcs (fromIntegral (length entries)) base
      if ty == nullPtr
        then Left <$> takeError
        else do
          writeTypeCell cell ty
          r <- addToModule ty
          case r of
            Left e -> pure (Left e)
            Right () -> registerAbcs ty (classRegAbcs reg)

{- | Order the classes of a module so that a Haskell base class is created
before the classes that extend it; a base outside the list is assumed to be
registered already.
-}
orderClasses :: [ClassRegistration] -> [ClassRegistration]
orderClasses = go []
  where
    go done [] = reverse done
    go done pending =
      case partition ready pending of
        ([], _) -> reverse done <> pending
        (readyNow, rest) -> go (reverse readyNow <> done) rest
      where
        pendingCells = map classRegTypeCell pending
        ready r = case classRegBase r of
          Nothing -> True
          Just baseCell -> baseCell `notElem` pendingCells

-- | @abc.register(cls)@ for every named ABC.
registerAbcs :: Ptr PyObject -> [Text] -> IO (PyResult ())
registerAbcs _ [] = pure (Right ())
registerAbcs ty (abcName : rest) = do
  let (modName, clsName) = case T.breakOnEnd "." abcName of
        (m, c) | T.null m -> ("collections.abc", c)
        (m, c) -> (T.dropEnd 1 m, c)
  m <- TF.withCString modName c_importModule
  if m == nullPtr
    then Left <$> takeError
    else do
      cls <- TF.withCString clsName (c_getAttrString m)
      c_decref m
      if cls == nullPtr
        then Left <$> takeError
        else do
          r <- TF.withCString "register" \cname -> do
            registerFn <- c_getAttrString cls cname
            if registerFn == nullPtr
              then pure nullPtr
              else do
                res <- withArray [ty] \arr -> c_vectorcall registerFn arr 1 nullPtr
                c_decref registerFn
                pure res
          c_decref cls
          if r == nullPtr
            then Left <$> takeError
            else do
              c_decref r
              registerAbcs ty rest

foreign import ccall "dynamic" callDestructor :: FunPtr Destructor -> Ptr PyObject -> IO ()

{- | Unpack a @tp_new@ or @tp_call@ style @(args, kwargs)@ pair into fastcall
form, bind it against the parameter names, run the body on the bound pointers,
and free the vector.
-}
withUnpackedCall :: Int -> ParamNames -> Ptr PyObject -> Ptr PyObject -> ([Ptr PyObject] -> IO (Ptr PyObject)) -> IO (Ptr PyObject)
withUnpackedCall nparams (ParamNames names) args kwargs body =
  allocaBytes 8 \nargsPtr -> allocaBytes 8 \kwnamesPtr -> do
    vec <- c_unpackCall args kwargs nargsPtr kwnamesPtr
    if vec == nullPtr
      then pure nullPtr
      else do
        nargs <- peekElemOff (castPtr nargsPtr :: Ptr PySSize) 0
        kwnames <- peekElemOff (castPtr kwnamesPtr :: Ptr (Ptr PyObject)) 0
        r <- allocaArray (max 1 nparams) \out -> do
          rc <- c_bindArgs vec nargs kwnames names (fromIntegral nparams) out
          if rc < 0
            then pure nullPtr
            else peekArray nparams out >>= body
        NonLinear.unless (kwnames == nullPtr) (c_decref kwnames)
        c_free vec
        pure r

{- | The @tp_new@ of a class with a constructor: unpack @(args, kwargs)@, bind,
and run the user's constructor with the type being constructed recorded in
the arena, so that 'newObject' allocates through the subtype when there is one.
-}
constructorTrampoline :: Ptr PyTypeObject -> Int -> ParamNames -> Ptr PyTypeObject -> Ptr PyObject -> Ptr PyObject -> (forall π. Proxy π -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))) -> IO (Ptr PyObject)
constructorTrampoline ownType nparams names ty args kwargs body =
  withUnpackedCall nparams names args kwargs \ptrs ->
    withCallArena
      nullPtr
      ( \arena -> withFreshScope \(p :: Proxy π) -> do
          c_arenaSetCtor arena ty ownType
          res <- unsafeRunPy (body p (map unsafeBoundFromPtr ptrs)) >>= evaluate
          case res of
            Right b -> case mutPtr b of
              (ptr, _) -> do
                c_incref ptr
                pure ptr
            Left e -> do
              raiseErr e
              pure nullPtr
      )
      (\e -> raiseErr (someExceptionToPyErr e))

-- | The @tp_call@ of a class with a 'H2Py.Class.Slot.Call' slot: unpack, bind, and run the body on @self@.
makeCallSlot :: FunctionDesc -> (forall π. Proxy π -> Bound π PyAny -> [Bound π PyAny] -> Py π π (PyResult (Bound π PyAny))) -> IO SlotEntry
makeCallSlot desc body = do
  names <- newParamNames (descParamNames desc)
  let n = length (functionParams desc)
  ptr <- mkTernaryFunc \self args kwargs ->
    withUnpackedCall n names args kwargs \ptrs ->
      runPyCall \p -> body p (unsafeBoundFromPtr self) (map unsafeBoundFromPtr ptrs)
  pure (SlotEntry slotTpCall (castFunPtrToPtr ptr))

-- | The stub description of a class registration.
classDescOf :: ClassRegistration -> ClassDesc
classDescOf reg =
  ClassDesc
    { classDescName = classRegName reg
    , classDescDoc = classRegDoc reg
    , classDescBases = classRegBases reg <> classRegAbcs reg
    , classDescMethods = [d | Just (ConstructorReg d _) <- [classRegConstructor reg]] <> map pyFunctionDesc (classRegMethods reg)
    , classDescSlots = classRegSlotDescs reg
    }

-- | Assemble a module registration and its description; what @pymodule@ generates calls this.
mkModuleRegistration :: Text -> Text -> [PyFunction] -> [ClassRegistration] -> [(Text, Text, IORef (Ptr PyObject))] -> [ModuleRegistration] -> ModuleRegistration
mkModuleRegistration name modDoc fns classes excs subs =
  ModuleRegistration
    { moduleRegDesc =
        ModuleDesc
          { moduleDescName = name
          , moduleDescDoc = modDoc
          , moduleDescFunctions = map pyFunctionDesc fns
          , moduleDescClasses = map classDescOf classes
          , moduleDescExceptions = [ExceptionDesc n b | (n, b, _) <- excs]
          , moduleDescSubmodules = map moduleRegDesc subs
          }
    , moduleRegFunctions = fns
    , moduleRegClasses = classes
    , moduleRegExceptions = excs
    , moduleRegSubmodules = subs
    }

-- * Modules

-- | Everything a module registers.
data ModuleRegistration = ModuleRegistration
  { moduleRegDesc :: ModuleDesc
  , moduleRegFunctions :: [PyFunction]
  , moduleRegClasses :: [ClassRegistration]
  , moduleRegExceptions :: [(Text, Text, IORef (Ptr PyObject))]
  -- ^ Name, base (a Python dotted name), and the cell for the created type.
  , moduleRegSubmodules :: [ModuleRegistration]
  }

{- | Fill a module object: functions, classes, exceptions, submodules, and the
hidden @__h2py_stub__@ that returns the rendered stub.
Attached, on the importing thread; returns @-1@ with an exception set on failure.
-}
initModule :: ModuleRegistration -> Ptr PyObject -> IO CInt
initModule reg modul = do
  r <- try (initModuleBody reg modul)
  case r of
    Left (e :: SomeException) -> do
      raiseErr (someExceptionToPyErr e)
      pure (-1)
    Right (Left e) -> do
      raiseErr e
      pure (-1)
    Right (Right ()) -> pure 0

initModuleBody :: ModuleRegistration -> Ptr PyObject -> IO (PyResult ())
initModuleBody reg modul = do
  defs <- makeMethodDefs (moduleRegFunctions reg)
  rc <- c_moduleAddFunctions modul defs
  if rc < 0
    then Left <$> takeError
    else do
      rcls <- foldResults (map (registerClass modul) (orderClasses (moduleRegClasses reg)))
      case rcls of
        Left e -> pure (Left e)
        Right () -> do
          rexc <- foldResults (map (registerException modul) (moduleRegExceptions reg))
          case rexc of
            Left e -> pure (Left e)
            Right () -> do
              rsub <- foldResults (map (registerSubmodule modul (moduleDescName (moduleRegDesc reg))) (moduleRegSubmodules reg))
              case rsub of
                Left e -> pure (Left e)
                Right () -> do
                  rdoc <- setModuleDoc modul (moduleDescDoc (moduleRegDesc reg))
                  case rdoc of
                    Left e -> pure (Left e)
                    Right () -> registerStub modul (moduleRegDesc reg)

-- | Set @__doc__@ from the description, when there is one.
setModuleDoc :: Ptr PyObject -> Text -> IO (PyResult ())
setModuleDoc modul d
  | T.null d = pure (Right ())
  | otherwise = do
      s <- newPyText d
      if s == nullPtr
        then Left <$> takeError
        else do
          rc <- TF.withCString "__doc__" \cname -> c_setAttrString modul cname s
          c_decref s
          if rc < 0 then Left <$> takeError else pure (Right ())

foldResults :: [IO (PyResult ())] -> IO (PyResult ())
foldResults [] = pure (Right ())
foldResults (m : ms) = do
  r <- m
  case r of
    Left e -> pure (Left e)
    Right () -> foldResults ms

-- | The name of a module object, or @h2py@ if it cannot be read.
moduleNameOf :: Ptr PyObject -> IO Text
moduleNameOf modul = do
  nameObj <- c_moduleGetNameObject modul
  if nameObj == nullPtr
    then clearError >> pure "h2py"
    else do
      r <- peekPyText nameObj
      c_decref nameObj
      pure (either (const "h2py") id r)

-- | Create an exception class with @PyErr_NewException@ under the module's name.
registerException :: Ptr PyObject -> (Text, Text, IORef (Ptr PyObject)) -> IO (PyResult ())
registerException modul (name, base, cell) = do
  modName <- moduleNameOf modul
  baseObj <- resolveDotted base
  case baseObj of
    Left e -> pure (Left e)
    Right basePtr -> do
      exc <- TF.withCString (modName <> "." <> name) \cname -> c_errNewException cname basePtr nullPtr
      NonLinear.unless (basePtr == nullPtr) (c_decref basePtr)
      if exc == nullPtr
        then Left <$> takeError
        else do
          previous <- readIORef cell
          if previous /= nullPtr
            then do
              c_decref exc
              pure (Left (runtimeError ("H2Py: the exception class " <> name <> " was registered twice")))
            else do
              atomicModifyIORef' cell (const (exc, ()))
              rc <- TF.withCString name \cname -> c_moduleAddObjectRef modul cname exc
              if rc < 0 then Left <$> takeError else pure (Right ())

{- | Resolve a dotted Python name such as @ValueError@ or @collections.abc.Sequence@
to a new reference; a bare name is looked up in @builtins@.
-}
resolveDotted :: Text -> IO (PyResult (Ptr PyObject))
resolveDotted dotted = do
  let (modName, attr) = case T.breakOnEnd "." dotted of
        (m, a) | T.null m -> ("builtins", a)
        (m, a) -> (T.dropEnd 1 m, a)
  m <- TF.withCString modName c_importModule
  if m == nullPtr
    then Left <$> takeError
    else do
      v <- TF.withCString attr (c_getAttrString m)
      c_decref m
      if v == nullPtr then Left <$> takeError else pure (Right v)

-- | Create a submodule, fill it, add it as an attribute, and register it in @sys.modules@.
registerSubmodule :: Ptr PyObject -> Text -> ModuleRegistration -> IO (PyResult ())
registerSubmodule parent parentName sub = do
  let name = moduleDescName (moduleRegDesc sub)
      fullName = parentName <> "." <> name
  m <- TF.withCString fullName c_moduleNew
  if m == nullPtr
    then Left <$> takeError
    else do
      r <- initModuleBody sub m
      case r of
        Left e -> c_decref m >> pure (Left e)
        Right () -> do
          rc <- TF.withCString name \cname -> c_moduleAddObjectRef parent cname m
          if rc < 0
            then c_decref m >> (Left <$> takeError)
            else do
              mods <- c_importGetModuleDict
              rc' <- TF.withCString fullName \cname -> c_dictSetItemString mods cname m
              c_decref m
              if rc' < 0 then Left <$> takeError else pure (Right ())

-- | Add the hidden stub function to the module.
registerStub :: Ptr PyObject -> ModuleDesc -> IO (PyResult ())
registerStub modul desc = do
  fullName <- moduleNameOf modul
  let root = T.takeWhile (/= '.') fullName
      stub = renderStubsUnder (if root == fullName then Nothing else Just root) desc
  ptr <- mkFastCall \_ _ _ _ -> do
    p <- newPyText stub
    pure p
  let fdesc = FunctionDesc "__h2py_stub__" [] (TName "str") "The generated type stub of this module." False False
  defs <- makeMethodDefs [PyFunction fdesc ptr]
  rc <- c_moduleAddFunctions modul defs
  if rc < 0 then Left <$> takeError else pure (Right ())

-- * Stubs

-- | Render a @.pyi@ from a module description.
renderStubs :: ModuleDesc -> Text
renderStubs = renderStubsUnder Nothing

{- | 'renderStubs' for a submodule of the named root module, which defines the
iterator class every module shares.
-}
renderStubsUnder :: Maybe Text -> ModuleDesc -> Text
renderStubsUnder root desc =
  T.unlines $
    [ "# " <> moduleDescName desc <> ".pyi, generated by H2Py; do not edit."
    , "from typing import Any, Iterator"
    ]
      <> ["import " <> m | m <- hintModules desc]
      <> ["from " <> r <> " import HsIterator" | Just r <- [root], "HsIterator" `T.isInfixOf` body]
      <> [""]
      <> body'
  where
    body' =
      concatMap renderFunction (moduleDescFunctions desc)
        <> concatMap renderClass (moduleDescClasses desc)
        <> concatMap renderException (moduleDescExceptions desc)
        <> concatMap renderSubmodule (moduleDescSubmodules desc)
    body = T.unlines body'
    renderSubmodule sub =
      ["", "# submodule " <> moduleDescName desc <> "." <> moduleDescName sub <> ": see " <> moduleDescName sub <> ".pyi", ""]

renderParams :: Bool -> [ParamDesc] -> Text
renderParams receiver ps =
  T.intercalate ", " (["self" | receiver] <> named <> ["/" | not (null positional) && null named'])
  where
    positional = [p | p <- ps, paramName p == Nothing]
    named' = [p | p <- ps, paramName p /= Nothing]
    named =
      [ case paramName p of
          Just n -> n <> ": " <> renderHint (paramHint p)
          Nothing -> "arg" <> T.pack (show i) <> ": " <> renderHint (paramHint p)
      | (i :: Int, p) <- zip [0 ..] ps
      ]

renderFunction :: FunctionDesc -> [Text]
renderFunction f =
  [ "def " <> functionName f <> "(" <> renderParams False (functionParams f) <> ") -> " <> renderHint (functionResult f) <> ":"
  ]
    <> renderDocOrEllipsis "    " (functionDoc f)
    <> [""]

renderDocOrEllipsis :: Text -> Text -> [Text]
renderDocOrEllipsis indent d
  | T.null d = [indent <> "..."]
  | otherwise = [indent <> "\"\"\"" <> d <> "\"\"\""]

renderClass :: ClassDesc -> [Text]
renderClass c =
  [ "class " <> classDescName c <> (if null (classDescBases c) then "" else "(" <> T.intercalate ", " (map renderBase (classDescBases c)) <> ")") <> ":"
  ]
    <> (if T.null (classDescDoc c) then [] else ["    \"\"\"" <> classDescDoc c <> "\"\"\""])
    <> body
    <> [""]
  where
    members = classDescMethods c <> classDescSlots c
    body
      | null members && T.null (classDescDoc c) = ["    ..."]
      | otherwise = concatMap renderMethod members
    renderMethod m
      | functionIsConstructor m =
          ["    def __init__(" <> renderParams True (functionParams m) <> ") -> None: ..."]
      | otherwise =
          ["    def " <> functionName m <> "(" <> renderParams (functionReceiver m) (functionParams m) <> ") -> " <> renderHint (functionResult m) <> ":"]
            <> renderDocOrEllipsis "        " (functionDoc m)

{- | A base as the stub spells it: the generic abstract base classes of
@collections.abc@ take type arguments under a strict type checker, and the
registration knows none, so @Any@ is what an ABC base gets.
-}
renderBase :: Text -> Text
renderBase base
  | base `elem` map ("collections.abc." <>) unary = base <> "[Any]"
  | base `elem` map ("collections.abc." <>) binary = base <> "[Any, Any]"
  | base == "collections.abc.Generator" || base == "collections.abc.Coroutine" = base <> "[Any, Any, Any]"
  | otherwise = base
  where
    unary = ["Sequence", "MutableSequence", "Set", "MutableSet", "Iterable", "Iterator", "Collection", "Container", "Reversible", "Awaitable", "AsyncIterable", "AsyncIterator", "KeysView", "ValuesView"]
    binary = ["Mapping", "MutableMapping", "ItemsView"]

renderException :: ExceptionDesc -> [Text]
renderException e = ["class " <> exceptionDescName e <> "(" <> exceptionDescBase e <> "): ...", ""]

{- | The modules every dotted name in the hints and bases of a description
refers to (@numpy.typing.NDArray[numpy.float64]@ needs @numpy.typing@ and
@numpy@), sorted and without duplicates.
-}
hintModules :: ModuleDesc -> [Text]
hintModules desc = Set.toAscList (Set.fromList (concatMap dottedModules texts))
  where
    texts =
      concat
        [ concatMap functionTexts (moduleDescFunctions desc)
        , concat [classDescBases c <> concatMap functionTexts (classDescMethods c <> classDescSlots c) | c <- moduleDescClasses desc]
        , [exceptionDescBase e | e <- moduleDescExceptions desc]
        ]
    functionTexts f = renderHint (functionResult f) : map (renderHint . paramHint) (functionParams f)

-- | The module part of every dotted identifier in a rendered hint.
dottedModules :: Text -> [Text]
dottedModules t = [T.intercalate "." (init parts) | ident <- identifiers, let parts = T.splitOn "." ident, length parts > 1, all (not . T.null) parts]
  where
    identifiers = filter (not . T.null) (T.split (\c -> not (isIdentChar c || c == '.')) t)
    isIdentChar c = c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

-- | Compare the rendered stub against a committed file.
checkStubs :: ModuleDesc -> FilePath -> IO Bool
checkStubs desc path = do
  expected <- readFile path
  pure (T.pack expected == renderStubs desc)

-- * Cells for generated code

-- | The cell of a class, allocated once; used by the code @pyclass@ generates and marked @NOINLINE@ there.
unsafeNewTypeCell :: TypeCell
{-# NOINLINE unsafeNewTypeCell #-}
unsafeNewTypeCell = unsafePerformIO newTypeCell

-- | A fresh exception-class cell for @newException@; the splice marks its binding @NOINLINE@.
unsafeNewExceptionCell :: IORef (Ptr PyObject)
{-# NOINLINE unsafeNewExceptionCell #-}
unsafeNewExceptionCell = unsafePerformIO (newIORef nullPtr)

{- | Read an exception cell.
The cell is write-once, filled at module init before any trampoline can run;
a read before the fill is an error naming the class, never a @NULL@ that
reaches CPython.
-}
readExceptionCell :: Text -> IORef (Ptr PyObject) -> Ptr PyObject
readExceptionCell name ref = unsafePerformIO do
  p <- readIORef ref
  if p == nullPtr
    then error ("H2Py: the exception class " <> T.unpack name <> " was used before its module was initialised")
    else pure p
{-# NOINLINE readExceptionCell #-}

-- | Silence an unused-import warning for a type used only in signatures the splices refer to.
_kindType :: Proxy (Type -> Type)
_kindType = Proxy
