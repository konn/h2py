{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- |
The tutorial's @Counter@: a class whose state lives in the Haskell heap, with
the receiver-form methods of section 5.4 of the design.
-}
module H2Py.Examples.Counter (
  Counter (..),
  new,
  incr,
  get,
  label,
  add,
  h2py_class_Counter,
) where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.Pure
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Data.Ref.Linear.Borrow qualified as RefB
import Data.Text qualified as Text
import H2Py
import Prelude.Linear

newtype Counter = Counter (Ref Int)
  deriving newtype (Consumable)

pyclassWith (defaultClassSpec & classDoc "A counter whose state lives in the Haskell heap.") ''Counter

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

add :: Int -> Int -> Py π π Int
add x y = Control.pure (x + y)

pymethods
  ''Counter
  [ constructor 'new & param 0 "n"
  , method "incr" 'incr & param 0 "k" & doc "Add k to the counter."
  , method "get" 'get & doc "The current value."
  , method "label" 'label
  ]
