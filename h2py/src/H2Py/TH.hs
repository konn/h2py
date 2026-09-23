{-# LANGUAGE TemplateHaskell #-}

{- |
The registration splices: @pyclass@, @pymethods@, @pymodule@ and
@newException@.
Every module also registers the iterator class of "H2Py.Class.Iterator".
See sections 5.4 and 5.11 of the design.

Registering a lifetime-polymorphic function is a splice because a value-level
@method@ would have to take a function polymorphic in @π@ as an argument, which
needs impredicative types or one newtype per arity; the tables the splices build
and the adjustors they point at are ordinary values.

@
pyclass ''Counter
pymethods ''Counter [constructor 'new, method "incr" 'incr, method "get" 'get]
pymodule "counter" [fn "add" 'add & param 0 "x" & param 1 "y"] [''Counter]
@

The module named by @pymodule@ must match the @H2PY_MODULE@ of the C file that
includes @<h2py/init.h>@.
-}
module H2Py.TH (
  -- * Classes
  pyclass,
  pyclassWith,
  ClassSpec (..),
  defaultClassSpec,
  frozen,
  subclassable,
  classDoc,
  abc,
  pythonName,
  extends,

  -- * Methods and slots
  pymethods,
  MethodSpec,
  constructor,
  method,
  slot,
  detached,

  -- * Modules
  pymodule,
  pymoduleWith,
  ModuleSpec (..),
  moduleSpec,
  FunctionSpec,
  fn,
  submodule,
  exception,
  newException,

  -- * Options
  HasOptions (..),
  param,
  hint,
  resultAs,
  doc,
) where

import Control.Monad (forM, unless)
import Data.IORef (IORef, newIORef)
import Data.Int (Int32)
import Data.Proxy (Proxy (..))
import Data.Text qualified as T
import Foreign.Ptr (Ptr, nullPtr)
import H2Py.Class.Internal
import H2Py.Class.Iterator (hsIteratorRegistration)
import H2Py.Class.Slot (slotEntries)
import H2Py.Convert.Internal (PyTypeHint (..), TypeHint (..))
import H2Py.Exception.Internal (PyExceptionClass (..))
import H2Py.Module.Internal hiding (doc, hint, param, resultAs)
import H2Py.Module.Internal qualified as Internal
import H2Py.Object.Internal (PyTypeOf (..), Sealed (..), asAnyMut, type (:<:))
import H2Py.Runtime.Internal (PyObject)
import Language.Haskell.TH
import Language.Haskell.TH.Syntax (lift)
import System.IO.Unsafe (unsafePerformIO)
import Unsafe.Linear qualified as Unsafe

-- * Options

{- | Registrations that carry 'FunctionOptions'.
The combinators are polymorphic in multiplicity, so that they chain with the
'&' of "Data.Function" and with the linear one of "Prelude.Linear" alike;
a registration table is plain data.
-}
class HasOptions s where
  modifyOptions :: (FunctionOptions -> FunctionOptions) -> s %m -> s

-- | Name parameter @i@ (zero-based); unnamed parameters render positional-only and cannot be passed by keyword.
param :: (HasOptions s) => Int -> String -> s %m -> s
param i name x = modifyOptions (Internal.param i (T.pack name)) x

-- | Replace the derived hint of parameter @i@ with a literal, such as @numpy.typing.NDArray[numpy.float64]@.
hint :: (HasOptions s) => Int -> String -> s %m -> s
hint i h x = modifyOptions (Internal.hint i (T.pack h)) x

-- | Replace the derived result hint with a literal.
resultAs :: (HasOptions s) => String -> s %m -> s
resultAs h x = modifyOptions (Internal.resultAs (T.pack h)) x

-- | A docstring.
doc :: (HasOptions s) => String -> s %m -> s
doc d x = modifyOptions (Internal.doc (T.pack d)) x

-- * Classes

-- | The options of @pyclass@.
data ClassSpec = ClassSpec
  { csFrozen :: Bool
  , csSubclassable :: Bool
  , csDoc :: String
  , csAbcs :: [String]
  , csPythonName :: Maybe String
  , csExtends :: Maybe Name
  }

defaultClassSpec :: ClassSpec
defaultClassSpec = ClassSpec False False "" [] Nothing Nothing

-- | No lend state: the payload must be 'Movable', methods receive it by value, and any number of threads may read it at once.
frozen :: ClassSpec %m -> ClassSpec
frozen x = Unsafe.toLinear (\c -> c {csFrozen = True}) x

-- | Set @Py_TPFLAGS_BASETYPE@, so Python code may subclass the class.
subclassable :: ClassSpec %m -> ClassSpec
subclassable x = Unsafe.toLinear (\c -> c {csSubclassable = True}) x

-- | The class docstring.
classDoc :: String -> ClassSpec %m -> ClassSpec
classDoc d x = Unsafe.toLinear (\c -> c {csDoc = d}) x

-- | Register the class with an abstract base class at module init, and render it as a base in the stub.
abc :: String -> ClassSpec %m -> ClassSpec
abc a x = Unsafe.toLinear (\c -> c {csAbcs = csAbcs c <> [a]}) x

-- | The Python name of the class, when it differs from the Haskell one.
pythonName :: String -> ClassSpec %m -> ClassSpec
pythonName n x = Unsafe.toLinear (\c -> c {csPythonName = Just n}) x

{- | Extend another Haskell class, declared with @subclassable@ and listed
before this one in the module: the child's type has the parent's in its bases,
each level keeps its own payload, 'H2Py.Class.newObjectWith' installs both,
and 'H2Py.Class.super' reaches the parent's.
The parent's cell must be in scope, so the parent is declared in the same
module or its @h2py_cell_\<Parent\>@ is imported.
-}
extends :: Name -> ClassSpec %m -> ClassSpec
extends parent x = Unsafe.toLinear (\c -> c {csExtends = Just parent}) x

{- | Declare a Haskell payload type as a Python class: the type cell, the
'PyClass' (or 'PyFrozenClass') instance, 'PyTypeOf' and 'PyTypeHint'.
Refuses a type constructor with parameters; see the closedness rule of the design.
-}
pyclass :: Name -> Q [Dec]
pyclass = pyclassWith defaultClassSpec

-- | 'pyclass' with options.
pyclassWith :: ClassSpec -> Name -> Q [Dec]
pyclassWith spec name = do
  info <- reify name
  tvs <- case info of
    TyConI (DataD _ _ tvs _ _ _) -> pure tvs
    TyConI (NewtypeD _ _ tvs _ _ _) -> pure tvs
    _ -> fail ("pyclass: " <> nameBase name <> " is not a data type or newtype")
  unless (null tvs) $
    fail
      ( "pyclass: "
          <> nameBase name
          <> " has type parameters; payload types must be closed, because a parameterised instance lets a stored reference's attachment unify with a later call's"
      )
  let cellName = mkName (cellNameFor name)
      pyName = maybe (nameBase name) id (csPythonName spec)
      nameE = [|T.pack $(litE (stringL pyName))|]
      docE = [|T.pack $(litE (stringL (csDoc spec)))|]
      subclassE = if csSubclassable spec then [|True|] else [|False|]
      abcsE = listE [[|T.pack $(litE (stringL a))|] | a <- csAbcs spec]
  cellSig <- sigD cellName [t|TypeCell|]
  cellDef <- valD (varP cellName) (normalB [|unsafePerformIO newTypeCell|]) []
  let cellPragma = PragmaD (InlineP cellName NoInline FunLike AllPhases)
  classInst <-
    if csFrozen spec
      then
        [d|
          instance PyFrozenClass $(conT name) where
            pyFrozenClassName _ = $nameE
            pyFrozenClassDoc _ = $docE
            pyFrozenClassTypeCell _ = $(varE cellName)
            pyFrozenClassSealed _ = UnsafeSealed
          |]
      else
        [d|
          instance PyClass $(conT name) where
            pyClassName _ = $nameE
            pyClassDoc _ = $docE
            pyClassTypeCell _ = $(varE cellName)
            pyClassSealed _ = UnsafeSealed
          |]
  typeOfInst <-
    [d|
      instance PyTypeOf $(conT name) where
        pyTypeOf _ = requireTypeCell $nameE $(varE cellName)
        pyTypeName _ = $nameE
        pyTypeSealed _ = UnsafeSealed
      |]
  hintInst <-
    [d|
      instance PyTypeHint $(conT name) where
        pyTypeHint _ = TName $nameE
      |]
  receiverInst <-
    if csFrozen spec
      then
        [d|
          instance PyReceiver $(conT name) Frozen where
            receiverName _ = $nameE
            receiverDoc _ = $docE
            receiverTypeCell _ = $(varE cellName)
            withReceiver = withFrozenPayload
            receiverDealloc _ = deallocFrozen
          |]
      else
        [d|
          instance PyReceiver $(conT name) Lent where
            receiverName _ = $nameE
            receiverDoc _ = $docE
            receiverTypeCell _ = $(varE cellName)
            withReceiver = withSharedPayload
            receiverDealloc _ = deallocPayload @($(conT name))
          |]
  extendsInsts <- case csExtends spec of
    Nothing -> pure []
    Just parent ->
      [d|
        instance PyExtends $(conT name) $(conT parent) where
          pyExtendsSealed _ _ = UnsafeSealed

        instance $(conT name) :<: $(conT parent)
        |]
  let baseE = case csExtends spec of
        Nothing -> [|Nothing|]
        Just parent -> [|Just $(varE (mkName (cellNameFor parent)))|]
      baseNameE = case csExtends spec of
        Nothing -> [|Nothing|]
        Just parent -> [|Just (pyTypeName (Proxy :: Proxy $(conT parent)))|]
  optsSig <- sigD (mkName (optionsNameFor name)) [t|ClassOptions|]
  optsDef <- valD (varP (mkName (optionsNameFor name))) (normalB [|ClassOptions $subclassE $abcsE $baseE $baseNameE|]) []
  pure ([cellSig, cellDef, cellPragma] <> classInst <> receiverInst <> extendsInsts <> typeOfInst <> hintInst <> [optsSig, optsDef])

-- | The first present half of a merged slot.
firstOf :: [Maybe a] -> Maybe a
firstOf = foldr (\x acc -> maybe acc Just x) Nothing

cellNameFor :: Name -> String
cellNameFor name = "h2py_cell_" <> nameBase name

optionsNameFor :: Name -> String
optionsNameFor name = "h2py_classopts_" <> nameBase name

registrationNameFor :: Name -> String
registrationNameFor name = "h2py_class_" <> nameBase name

-- * Methods

-- | A method registration for @pymethods@.
data MethodSpec
  = MConstructor Name FunctionOptions
  | MMethod String Name FunctionOptions Bool
  | MSlot Name Name FunctionOptions

instance HasOptions MethodSpec where
  modifyOptions f x =
    Unsafe.toLinear
      ( \case
          MConstructor n o -> MConstructor n (f o)
          MMethod s n o d -> MMethod s n (f o) d
          MSlot c n o -> MSlot c n (f o)
      )
      x

-- | The constructor: a function returning @Py π π (PyResult (Bound π T))@, run by @T(...)@.
constructor :: Name -> MethodSpec
constructor n = MConstructor n defaultFunctionOptions

-- | A method, in the receiver form or with an explicit receiver.
method :: String -> Name -> MethodSpec
method s n = MMethod s n defaultFunctionOptions False

{- | A protocol slot: the 'H2Py.Class.Slot.Slot' constructor and the function, e.g. @slot 'Repr 'showCounter@.
@slot 'Call 'f@ takes a method in any receiver form, and its options name the parameters as for a method.
-}
slot :: Name -> Name -> MethodSpec
slot con fnName = MSlot con fnName defaultFunctionOptions

-- | Run the body with the interpreter released: the right registration for any body that is long.
class Detachable s where
  detached :: s %m -> s

instance Detachable MethodSpec where
  detached x =
    Unsafe.toLinear
      ( \case
          MMethod s n o _ -> MMethod s n o True
          other -> other
      )
      x

instance Detachable FunctionSpec where
  detached x = Unsafe.toLinear (\f -> f {fsDetached = True}) x

{- | Register the methods and slots of a class, generating its
'ClassRegistration' for @pymodule@ to pick up.
Every class listed in a @pymodule@ needs a @pymethods@, possibly with an empty
list.
-}
pymethods :: Name -> [MethodSpec] -> Q [Dec]
pymethods cls specs = do
  let regName = mkName (registrationNameFor cls)
      clsT = conT cls
      proxyE = [|Proxy :: Proxy $clsT|]
      methodEs =
        [ [|
            makeMethod
              (describe (T.pack $(litE (stringL pyName))) True False (methodHintsAt @($clsT) scopeProxy $(fexp)) $(lift opts))
              (\p self args -> callMethodAt @($clsT) p $(fexp) self args)
            |]
        | MMethod pyName fnName opts isDetached <- specs
        , let fexp = if isDetached then [|Detached $(varE fnName)|] else varE fnName
        ]
      slotEs = [slotE con fnName opts | MSlot con fnName opts <- specs]
      slotE con fnName opts
        | nameBase con == "Call" =
            [|
              slotEntries @($clsT)
                ( Call
                    $(lift opts)
                    (methodHintsAt @($clsT) scopeProxy $(varE fnName))
                    (\p self args -> callMethodAt @($clsT) p $(varE fnName) (asAnyMut self) args)
                )
              |]
        | otherwise = [|slotEntries @($clsT) ($(conE con) $(varE fnName))|]
      ctorE = case [(n, o) | MConstructor n o <- specs] of
        [] -> [|Nothing|]
        ((n, o) : _) ->
          [|
            Just
              ( ConstructorReg
                  (describe (T.pack "__init__") True True (callableHintsAt scopeProxy $(varE n)) $(lift o))
                  (\p args -> callWithAt p $(varE n) args)
              )
            |]
  body <-
    [|
      do
        methods <- sequence $(listE methodEs)
        slotRegs <- sequence $(listE slotEs)
        let opts = $(varE (mkName (optionsNameFor cls)))
        finishClassRegistration
          ClassRegistration
            { classRegName = receiverName $proxyE
            , classRegDoc = receiverDoc $proxyE
            , classRegTypeCell = receiverTypeCell $proxyE
            , classRegDealloc = receiverDealloc $proxyE
            , classRegConstructor = $ctorE
            , classRegMethods = methods <> concatMap srMethods slotRegs
            , classRegSlots = concatMap srSlots slotRegs
            , classRegSlotDescs = concatMap srDescs slotRegs
            , classRegSubclassable = coSubclassable opts
            , classRegBases = maybe [] (: []) (coBaseName opts)
            , classRegAbcs = coAbcs opts
            , classRegBase = coBase opts
            , classRegSetItem = firstOf (map srSetItem slotRegs)
            , classRegDelItem = firstOf (map srDelItem slotRegs)
            }
      |]
  sig <- sigD regName [t|IO ClassRegistration|]
  def <- valD (varP regName) (normalB (pure body)) []
  pure [sig, def]

-- * Modules

-- | A module-level function registration.
data FunctionSpec = FunctionSpec
  { fsName :: String
  , fsFunction :: Name
  , fsOptions :: FunctionOptions
  , fsDetached :: Bool
  }

instance HasOptions FunctionSpec where
  modifyOptions f x = Unsafe.toLinear (\s -> s {fsOptions = f (fsOptions s)}) x

-- | A module-level function.
fn :: String -> Name -> FunctionSpec
fn s n = FunctionSpec s n defaultFunctionOptions False

-- | What a module registers.
data ModuleSpec = ModuleSpec
  { msName :: String
  , msDoc :: String
  , msFunctions :: [FunctionSpec]
  , msClasses :: [Name]
  , msExceptions :: [String]
  -- ^ Names declared with 'newException' in this module.
  , msSubmodules :: [ModuleSpec]
  }

-- | A module with functions and classes and nothing else.
moduleSpec :: String -> [FunctionSpec] -> [Name] -> ModuleSpec
moduleSpec name fns classes = ModuleSpec name "" fns classes [] []

-- | A submodule, registered as an attribute of its parent and in @sys.modules@ under the dotted name.
submodule :: String -> [FunctionSpec] -> [Name] -> ModuleSpec
submodule = moduleSpec

-- | Add an exception class declared with 'newException'.
exception :: String -> ModuleSpec %m -> ModuleSpec
exception e x = Unsafe.toLinear (\m -> m {msExceptions = msExceptions m <> [e]}) x

{- | Declare the module: the foreign export @h2py_hs_init_\<name\>@ that the C
initialiser calls, which fills the module object.
-}
pymodule :: String -> [FunctionSpec] -> [Name] -> Q [Dec]
pymodule name fns classes = pymoduleWith (moduleSpec name fns classes)

-- | 'pymodule' with docstring, exceptions and submodules.
pymoduleWith :: ModuleSpec -> Q [Dec]
pymoduleWith spec = do
  regE <- moduleRegistrationE True spec
  let regName = mkName ("h2py_module_" <> msName spec)
      initName = mkName ("h2py_hs_init_" <> msName spec)
  regSig <- sigD regName [t|IO ModuleRegistration|]
  regDef <- valD (varP regName) (normalB (pure regE)) []
  initSig <- sigD initName [t|Ptr PyObject -> IO Int32|]
  initDef <- valD (varP initName) (normalB [|\m -> $(varE regName) >>= \reg -> fmap fromIntegral (initModule reg m)|]) []
  initTy <- [t|Ptr PyObject -> IO Int32|]
  let export = ForeignD (ExportF CCall ("h2py_hs_init_" <> msName spec) initName initTy)
  pure [regSig, regDef, initSig, initDef, export]

{- | The registration expression of a module; the top-level module also
registers 'H2Py.Class.Iterator.HsIterator', which every @__iter__@ slot built
with 'H2Py.Class.Iterator.iterFromList' or 'H2Py.Class.Iterator.iterFromStep'
needs, once per process.
-}
moduleRegistrationE :: Bool -> ModuleSpec -> Q Exp
moduleRegistrationE isTop spec = do
  let fnEs =
        [ [|
            makeFunction
              (describe (T.pack $(litE (stringL (fsName f)))) False False (callableHintsAt scopeProxy $(fexp)) $(lift (fsOptions f)))
              (\p args -> callWithAt p $(fexp) args)
            |]
        | f <- msFunctions spec
        , let fexp = if fsDetached f then [|Detached $(varE (fsFunction f))|] else varE (fsFunction f)
        ]
      excEs =
        [ [|(T.pack $(litE (stringL e)), $(varE (mkName (exceptionBaseNameFor e))), $(varE (mkName (exceptionCellNameFor e))))|]
        | e <- msExceptions spec
        ]
  regNames <- forM (msClasses spec) \c -> do
    found <- lookupRegistration c
    case found of
      Just n -> pure n
      Nothing ->
        fail
          ( "pymodule: the class "
              <> nameBase c
              <> " has no pymethods in scope; add `pymethods ''"
              <> nameBase c
              <> " []` (with its methods, or an empty list) to the module that lists it"
          )
  let classEs = [varE n | n <- regNames] <> [[|hsIteratorRegistration|] | isTop]
  subEs <- mapM (moduleRegistrationE False) (msSubmodules spec)
  [|
    do
      fns <- sequence $(listE fnEs)
      classes <- sequence $(listE classEs)
      subs <- sequence $(listE (map pure subEs))
      pure (mkModuleRegistration (T.pack $(litE (stringL (msName spec)))) (T.pack $(litE (stringL (msDoc spec)))) fns classes $(listE excEs) subs)
    |]

{- | The registration binding of a class, @h2py_class_\<T\>@: looked up under
the module the class name carries first, so that two classes with one base
name in different modules resolve to their own registrations, then by the
bare name, for a class whose @pymethods@ lives in another module.
-}
lookupRegistration :: Name -> Q (Maybe Name)
lookupRegistration c = do
  let base = registrationNameFor c
  qualified <- case nameModule c of
    Just m -> lookupValueName (m <> "." <> base)
    Nothing -> pure Nothing
  case qualified of
    Just n -> pure (Just n)
    Nothing -> lookupValueName base

exceptionCellNameFor :: String -> String
exceptionCellNameFor e = "h2py_exc_" <> e

exceptionBaseNameFor :: String -> String
exceptionBaseNameFor e = "h2py_excbase_" <> e

{- | Declare a Python exception class, created at module init with the given
base (a dotted Python name such as @ValueError@), with a tag type and a
'PyExceptionClass' instance for 'H2Py.Exception.pyErr'.
List it in the module with 'exception'.
-}
newException :: String -> String -> Q [Dec]
newException name base = do
  let tagName = mkName name
      cellName = mkName (exceptionCellNameFor name)
      baseName = mkName (exceptionBaseNameFor name)
  tagDec <- dataD (pure []) tagName [] Nothing [] []
  cellSig <- sigD cellName [t|IORef (Ptr PyObject)|]
  cellDef <- valD (varP cellName) (normalB [|unsafePerformIO (newIORef nullPtr)|]) []
  let cellPragma = PragmaD (InlineP cellName NoInline FunLike AllPhases)
  baseSig <- sigD baseName [t|T.Text|]
  baseDef <- valD (varP baseName) (normalB [|T.pack $(litE (stringL base))|]) []
  inst <-
    [d|
      instance PyExceptionClass $(conT tagName) where
        exceptionTypeOf _ = readExceptionCell (T.pack $(litE (stringL name))) $(varE cellName)
        exceptionName _ = T.pack $(litE (stringL name))
        exceptionSealed _ = UnsafeSealed
      |]
  pure ([tagDec, cellSig, cellDef, cellPragma, baseSig, baseDef] <> inst)
