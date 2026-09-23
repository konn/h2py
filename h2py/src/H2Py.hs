{- |
H2Py: CPython extension modules in Haskell, in the spirit of PyO3, on top of
pure-borrow.

= Tutorial

A module is a Haskell module with a few splices, and a two-line C file.
Everything in a method runs in @'Py' π π@, the world of code attached to the
interpreter, which is a 'BIO' with one more index; it has only linear-base's
monad, so @Control.do@ and @Control.pure@ from "Control.Functor.Linear" are
mandatory.

@
{-\# LANGUAGE TemplateHaskell \#-}
module Counter where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.Pure
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Data.Ref.Linear.Borrow qualified as RefB
import H2Py
import Prelude.Linear

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
get counter = RefB.copyRef (coerceShare \@(Ref Int) counter)

pymethods ''Counter [constructor 'new, method "incr" 'incr, method "get" 'get]
pymodule "counter" [] [''Counter]
@

@
\#define H2PY_MODULE counter
\#include <h2py/init.h>
@

The two axes of @'Py' π γ@: @π@ is which call or scope a Python object belongs
to, and @γ@ is which scope a Haskell borrow belongs to.
Every function that uses a Python reference is written at @Py π π@, one
lifetime for both, which is what the trampoline instantiates at every call.

Python errors are values: every fallible operation returns @'PyResult' a@, a
@Left@ is raised in Python when the method returns it, and 'orFail' reduces a
@Left@ branch to one line by consuming the linear values in scope.
Haskell exceptions are the exceptional path and poison what the call holds
mutably.

Three shapes for parallelism: @liftBO (parBO …)@ for short pure work while
attached, @detach (parBO …)@ for @BIO@ branches with the interpreter released,
and 'parPy' for branches that need Python; @parBO@ directly in @Py@ is a type
error that names them.
-}
module H2Py (
  module H2Py.Py,
  module H2Py.Object,
  module H2Py.Class,
  module H2Py.Convert,
  module H2Py.Exception,
  module H2Py.TH,
) where

import H2Py.Class
import H2Py.Convert
import H2Py.Exception
import H2Py.Object
import H2Py.Py
import H2Py.TH
