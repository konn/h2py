{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- |
The three snippets of @docs/tutorial.md@, compiled as part of the examples
package so that the tutorial cannot drift from the API.
The @pymodule@ splice at the end of snippet 2 is the standalone module the
tutorial describes; 'tutorialSpec' registers the same classes as the
@tutorial@ submodule of @h2py_examples@, which @tests/test_tutorial.py@ runs.
-}
module H2Py.Examples.Tutorial (
  Counter (..),
  new,
  incr,
  get,
  label,
  set,
  apply,
  square,
  h2py_class_Counter,
  Holder (..),
  newHolder,
  hold,
  held,
  heldRepr,
  release,
  h2py_class_Holder,
  callZero,
  tutorialSpec,
) where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.IO (BIO)
import Control.Monad.Borrow.Pure
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Data.Ref.Linear.Borrow qualified as RefB
import Data.Text (Text)
import Data.Text qualified as Text
import H2Py
import Prelude.Linear

-- ---------------------------------------------------------------------------
-- Snippet 1: the Counter of Appendix A.

newtype Counter = Counter (Ref Int)
  deriving newtype (Consumable)

pyclass ''Counter

new :: Int -> Py π π (PyResult (Bound π Counter))
new n = Control.do
  ref <- asksLinearly (Ref.new n)
  newObject (Counter ref)

incr :: forall π. Mut π Counter %1 -> Int -> Py π π ()
incr counter k = Control.do
  ref <- RefB.modify (+ k) (upcast counter :: Mut π (Ref Int))
  Control.pure (consume ref)

get :: Share π Counter -> Py π π Int
get counter = RefB.copyRef (coerceShare @(Ref Int) counter)

-- | A Python object built while the payload is borrowed, returned from the method.
label :: Share π Counter -> Py π π (PyResult (Bound π PyStr))
label counter = Control.do
  Ur n <- Control.fmap move (RefB.copyRef (coerceShare @(Ref Int) counter))
  toStr (Text.pack ("Counter(" <> show n <> ")"))

-- ---------------------------------------------------------------------------
-- Snippet 2: errors as values, a callback under the hold, and a detached body.

-- | Set the counter from any Python object, which must convert to an @int@.
set :: forall π. Mut π Counter %1 -> Borrowed π PyAny -> Py π π (PyResult ())
set counter obj = Control.do
  r <- fromPy obj
  case orFail counter r of
    Left e -> Control.pure (Left e)
    Right (counter', n) -> Control.do
      ref <- RefB.modify (\old -> old `lseq` n) (upcast counter' :: Mut π (Ref Int))
      Control.pure (Right (consume ref))

-- | Replace the value by @f(value)@: the callback runs while the payload is held.
apply :: forall π. Mut π Counter %1 -> Borrowed π PyAny -> Py π π (PyResult ())
apply counter f = Control.do
  (r, ref) <- RefB.update (callback f) (upcast counter :: Mut π (Ref Int))
  Control.pure (consume ref `lseq` r)

-- | The step under the hold: the old value in, the new value or the old one out.
callback :: forall π. Borrowed π PyAny -> Int %1 -> Py π π (PyResult (), Int)
callback f n = Control.do
  Ur old <- Control.pure (move n)
  arg <- toInt old
  applyTo f old arg

applyTo :: forall π. Borrowed π PyAny -> Int -> PyResult (Bound π PyLong) %1 -> Py π π (PyResult (), Int)
applyTo _ old (Left e) = Control.pure (Left e, old)
applyTo f old (Right arg) = case share arg of
  Ur v -> Control.do
    res <- call f [asAny v]
    store old res

store :: forall π. Int -> PyResult (Bound π PyAny) %1 -> Py π π (PyResult (), Int)
store old (Left e) = Control.pure (Left e, old)
store old (Right obj) = case share obj of
  Ur v -> Control.do
    r <- fromPy v
    Control.pure (keep old r)

keep :: Int -> PyResult Int %1 -> (PyResult (), Int)
keep old (Left e) = (Left e, old)
keep _ (Right new') = (Right (), new')

-- | A read-only body in @BIO@: it runs with the interpreter released.
square :: Share π Counter -> BIO π Int
square counter = Control.do
  Ur n <- Control.fmap move (RefB.copyRef (coerceShare @(Ref Int) counter))
  Control.pure (n * n)

pymethods
  ''Counter
  [ constructor 'new & param 0 "n"
  , method "incr" 'incr & param 0 "k"
  , method "get" 'get
  , method "label" 'label
  , method "set" 'set & param 0 "value"
  , method "apply" 'apply & param 0 "f"
  , method "square" 'square
  ]

pymodule "tutorial" [] [''Counter]

-- ---------------------------------------------------------------------------
-- Snippet 3: holding a Python object across calls.

-- | A payload that keeps a strong reference to a Python object between calls.
newtype Holder = Holder (Ref (Maybe (PyHandle PyAny)))
  deriving newtype (Consumable)

pyclass ''Holder

newHolder :: Py π π (PyResult (Bound π Holder))
newHolder = Control.do
  ref <- asksLinearly (Ref.new Nothing)
  newObject (Holder ref)

-- | Keep @obj@: the view is turned into a GC-managed handle, which the payload stores.
hold :: forall π. Mut π Holder %1 -> Borrowed π PyAny -> Py π π ()
hold holder obj = Control.do
  Ur h <- toHandle obj
  ref <- RefB.modify (\old -> old `lseq` Just h) (upcast holder :: Mut π (Ref (Maybe (PyHandle PyAny))))
  Control.pure (consume ref)

-- | The held object, or @None@: the handle is copied out of the payload and converted by @ToPy@.
held :: Share π Holder -> Py π π (Maybe (PyHandle PyAny))
held holder = Control.do
  Ur m <- Control.fmap move (RefB.copyRef (coerceShare @(Ref (Maybe (PyHandle PyAny))) holder))
  Control.pure m

-- | @repr@ of the held object, through a view of the handle in this call's arena.
heldRepr :: Share π Holder -> Py π π (PyResult Text)
heldRepr holder = Control.do
  Ur m <- Control.fmap move (RefB.copyRef (coerceShare @(Ref (Maybe (PyHandle PyAny))) holder))
  case m of
    Nothing -> pyFail (valueError "nothing is held")
    Just h -> Control.do
      Ur v <- fromHandleShare h
      repr v

-- | Forget the held object: its reference is released by the handle's finaliser.
release :: forall π. Mut π Holder %1 -> Py π π ()
release holder = Control.do
  ref <- RefB.modify (\old -> old `lseq` Nothing) (upcast holder :: Mut π (Ref (Maybe (PyHandle PyAny))))
  Control.pure (consume ref)

pymethods
  ''Holder
  [ constructor 'newHolder
  , method "hold" 'hold & param 0 "obj"
  , method "held" 'held
  , method "held_repr" 'heldRepr
  , method "release" 'release
  ]

-- | @f()@: the zero-argument call shape of the glossary.
callZero :: Borrowed π PyAny -> Py π π (PyResult (Bound π PyAny))
callZero f = call0 f

-- | The tutorial's classes and functions as the @tutorial@ submodule of @h2py_examples@.
tutorialSpec :: ModuleSpec
tutorialSpec =
  (submodule "tutorial" [fn "call_zero" 'callZero & param 0 "f"] [''Counter, ''Holder])
    { msDoc = "The snippets of docs/tutorial.md, importable."
    }
