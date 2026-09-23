# H2Py tutorial

This is the tutorial that Appendix A of the design asks for: a `Counter` class written twice, once as the smallest module that works and once with the idioms a real module needs, then a class that keeps a Python object between calls, with the linearity mistakes a first module runs into and the exact GHC 9.12.4 error text each one produces.
The three Haskell snippets below are the file `h2py-examples/src/H2Py/Examples/Tutorial.hs`, which the examples package compiles and registers as the `h2py_examples.tutorial` submodule, so what you read here typechecks against the shipped API and runs under `h2py-examples/tests/test_tutorial.py`.

## What a module is

An H2Py module is three things:

1. A Haskell module with the payload types, the functions and methods, and three splices: `pyclass` declares a payload type as a Python class, `pymethods` registers its constructor and methods, and `pymodule` declares the module and generates the foreign export the C side calls.
2. A C file of two lines, which expands to the module's `PyInit_` function:

   ```c
   #define H2PY_MODULE tutorial
   #include <h2py/init.h>
   ```

3. A Cabal `foreign-library` stanza of type `native-shared` with `ghc-options: -threaded`, the C file under `c-sources`, and, on macOS, `ld-options: "-Wl,-undefined,dynamic_lookup"`; `h2py-examples/h2py-examples.cabal` is the model.
   The library that Cabal builds, `libtutorial.dylib` or `.so`, is renamed to `tutorial.abi3.so`, the file name CPython imports (`scripts/install-module.sh` does it), and a wheel is built by the hook under `h2py-examples/python/`.

The name in `pymodule` must match `H2PY_MODULE`.

## The seven pragmas

```haskell
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}
```

- `LinearTypes`: the `%1 ->` arrows of `Mut` receivers and of every consuming function.
- `QualifiedDo`: `Control.do`, explained next; without it a `do` block desugars to `Prelude`'s `>>=`, which `Py` has no instance for.
- `BlockArguments`: `attach'_ \... ->` and `detach \... ->` without parentheses.
- `TemplateHaskell`: the three splices and the `''Counter` and `'new` quotes.
- `NoImplicitPrelude` with `import Prelude.Linear`: the linear `Prelude`, whose `(+)`, `(<>)`, `show` and `consume` are what a linear body can use.
- `OverloadedStrings`: the `Text` literals in error messages and `toStr`.
- `DerivingStrategies`: `deriving newtype (Consumable)` on the payload.

`ImpredicativeTypes` is not among them; it becomes necessary only when a scope body is passed through `($)` or `(.)`, so write `attach'_ (…)` or `attach'_ \… ->`.
The examples package enables `LinearTypes`, `QualifiedDo`, `BlockArguments` and `OverloadedStrings` as `default-extensions`, and a module of your own may do the same; the pragmas are listed here so that a copy of the snippet into an empty file compiles.

## Snippet 1: the smallest counter

<!-- snippet 1 -->
```haskell
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
```

With the registration at the end of snippet 2 (`pymethods` and `pymodule`), this is the whole module:

```python
>>> import tutorial
>>> c = tutorial.Counter(40)
>>> c.incr(2); c.get()
42
>>> c.label()
'Counter(42)'
```

### The payload and `pyclass`

`Counter` is an ordinary Haskell type; `pyclass ''Counter` makes it a Python class by generating the `PyClass` instance, the cell that will hold the type object, and the `PyTypeOf` and `PyTypeHint` instances that let `Bound π Counter` be an argument, a result, and an `int`-style hint in the stub.
The payload must be `Consumable`, because Python's deallocator consumes it, and must be a closed type: a payload with a type parameter is refused by the splice, since a parameterised instance would let a stored reference's attachment unify with a later call's.
`Ref Int` is pure-borrow's mutable cell; the newtype around it is `Consumable` by `deriving newtype`.

### `Control.do` and `Control.pure`

`Py` is `BO'` from pure-borrow, and `BO'` has only linear-base's `Control.Functor.Linear.Monad`.
So every `do` block is `Control.do` and every `return` is `Control.pure`, with `import Control.Functor.Linear qualified as Control`.
A plain `do` fails with

```
• No instance for ‘ghc-internal-9.1204.0:GHC.Internal.Base.Monad
                     (BO' (Python π) π)’
    arising from a do statement
```

and `Prelude.Linear` exports neither `Functor` nor `Monad`, so `fmap` and `pure` from it are not in scope either: it is `Control.fmap`, as in `label`.

### The two axes of `Py π γ`

`Py π γ a` is a computation that may touch the interpreter.
`π` is the attachment scope: *which call or scope a Python object belongs to*.
Every `Bound π t` and `Borrowed π t` carries it, the arena that owns their reference counts is swept when the scope ends, and the trampoline instantiates a fresh `π` at every call.
`γ` is the ordinary pure-borrow lifetime: *which scope a Haskell borrow belongs to*.
`Mut π Counter`, the receiver of `incr`, is a Haskell borrow of the payload, and `RefB.modify` wants its `γ` to be at least as long as the computation's.

The rule for user code: every function that uses a Python reference is written at `Py π π`, one lifetime for both axes, which is what the trampoline instantiates.
The operations in `H2Py.Object` are typed at `Py π' γ` with constraints such as `π >= γ` so that they also work inside a nested scope, but a signature of your own should say `Py π π`; the glossary at the end shows what happens when it does not.

## Snippet 2: errors as values, a callback under the hold, a detached body

<!-- snippet 2 -->
```haskell
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
```

### Errors are values: the `case` on a `PyResult`, with `orFail`

Nothing in H2Py throws for a Python error.
Every fallible operation returns `PyResult a = Either PyErr a`, and a method that returns `Left e` makes the trampoline raise `e` in Python after the sweep, with every reference released and the payload's lend state cleared.
`PyErr` is unrestricted, and the built-ins `typeError`, `valueError`, `runtimeError` build one lazily from a message; `pyErr (Proxy @MyError) "…"` does the same for a class declared with `newException`.

`set` shows the shape.
`fromPy obj` answers `PyResult Int`, and on the `Left` branch the linear `counter` still has to be consumed, or the checker complains that it was used zero times.
`orFail counter r :: Either PyErr (Mut π Counter, Int)` does both jobs at once: on `Left` it consumes `counter` and passes the error on, on `Right` it hands `counter` back next to the value, so the `Left` branch of the method is one line.
`orFail` takes any `Consumable`, a tuple of everything linear in scope if need be.

Two shapes fail here.
`Just _ <- …` or `Right n <- …` as a failable pattern on a linear bind is a multiplicity error: GHC 9.12.4 prints a bare `Couldn't match type ‘Many’ with ‘One’` at the statement and one more `arising from multiplicity of ‘counter’` for every linear variable in scope, and the second kind can drown the error you were looking for.
So is `case r of Right x -> …; _ -> …` when a branch's closure captures another linear variable: the linear `counter` would be used in one branch and not the other.
The way out is the one `apply` uses: a helper function with one equation per constructor (`applyTo`, `store`, `keep`), each taking every linear value as a parameter.

### A callback while the payload is held

`apply` calls back into Python from inside `RefB.update`, while the payload is borrowed mutably.
The dereference does not narrow `π`: the objects made under the hold, `toInt old` and the result of `call f`, are `Bound π t` of the call and outlive the update, and the payload stays claimed until the call's sweep.
If the callback reaches the same object and asks for its payload, `derefMut` answers `Left` with `busy: Counter is already borrowed by another scope`, which is the lend state doing PyO3's `BorrowMutError` job.

`share arg` turns the linear `Bound` into an unrestricted `Borrowed` view (`Ur v`), which `call` takes; a view is read-only by protocol, a handle is what the mutating operations of `H2Py.Object` take and give back.

### The three monads and the lifts

| Monad | World | What it can do |
|---|---|---|
| `BO γ a` | pure | pure-borrow's borrowing, no effects; `Data.Ref.Linear.Borrow`, `Data.Vector` borrows, `parBO` |
| `BIO γ a` | `RealWorld` | the same plus linear `IO`; `liftSystemIOU` of `Control.Monad.IO.Class.Linear` for an ordinary `IO` result |
| `Py π γ a` | `Python π` | the same plus every Python operation, on an attached thread |

The lifts go one way:

- `liftBO :: BO γ a %1 -> BO' w γ a` (from `Control.Monad.Borrow.IO`) runs pure borrowing code in either `BIO` or `Py`.
- `detach :: (forall δ. BIO (δ /\ γ) r) %1 -> Py π γ r` runs `BIO` code from `Py` with the interpreter released for the window; it is the only safe way to run `IO` from a method, and the right one for any long kernel, since under the GIL an attached thread blocks every other Python thread.
- There is no lift from `Py` into `BIO`, and `parBO` directly in `Py` is a type error that names the alternatives: `parPy` for branches that need Python, `detach (parBO …)` for `BIO` branches, `liftBO (parBO …)` for pure ones.

A registered body picks its monad by its type: `Py π π r` runs attached, `BO π r` is lifted, and `BIO π r`, as `square`, runs under `detach` automatically, so a read-only kernel over the payload releases the interpreter for its whole duration.
`method "…" 'f & detached` does the same for a `BO` body that is long.

### Registration

`pymethods ''Counter […]` lists the constructor and the methods; `pymodule "tutorial" [functions] [''Counter]` declares the module.
A method is a function whose first parameter is the receiver, in one of four forms: `Mut π T %1 ->` and `Share π T ->` are the dereferenced payload (PyO3's `&mut self` and `&self`), `Bound π T %1 ->` and `Borrowed π T ->` are the object itself.
The remaining parameters are converted by `FromArg`: any `FromPy` value type (`Int`, `Text`, `[Double]`, `Maybe a`, tuples, `Map`, …) or a Python reference, `Bound π t` and `Borrowed π t` after a type check.
The result goes through `ToResult`: a `ToPy` value, a reference, `()` as `None`, and `PyResult` of any of them.

`param i "name"` names parameter `i`, so that Python can pass it by keyword and the stub shows it; an unnamed parameter is positional-only.
`doc "…"` sets the docstring, `hint i "…"` and `resultAs "…"` override a hint in the stub, and `classDoc` on `pyclassWith` documents the class.
The stub is rendered from the same description, and `__h2py_stub__()` on the imported module returns it; `scripts/h2py-stubs.py` writes it to a `.pyi`.

### Haskell exceptions

A Haskell exception is the exceptional path: it unwinds to the trampoline, becomes a Python exception through `ToPyErr` (`ArithException`, `ArrayException`, `IOException` and `ErrorCall` map to their nearest Python class, everything else to `RuntimeError`), and poisons what the call holds mutably, so that a later `derefMut` on that object answers `Left`.
`orThrow` and `throwPy` turn a `PyErr` into such an exception; they are an abort, not PyO3's `?`, and in a `Mut`-receiver method `orFail` is the tool.

## Snippet 3: holding a Python object across calls

A `Bound π t` lives exactly as long as the call that made it, so a payload cannot store one: the type checker refuses it (item 17 of section 8 of the design, and the first glossary entry below).
What a payload can store is a `PyHandle t`, PyO3's `Py<T>`: an unrestricted, GC-managed strong reference, made from a view with `toHandle` and released by a finaliser when the last copy dies.
`Holder` keeps one, or none.

<!-- snippet 3 -->
```haskell
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
```

```python
>>> from h2py_examples import tutorial
>>> h = tutorial.Holder()
>>> xs = [1, 2]
>>> h.hold(xs); h.held() is xs
True
>>> h.held_repr()
'[1, 2]'
>>> h.release(); h.held() is None
True
```

### `toHandle`, `fromHandle`, `fromHandleShare`

`toHandle :: Borrowed π t -> Py π' γ (Ur (PyHandle t))` takes a +1 on the object and wraps it in a handle; the `Ur` says what the type already says, that a handle is unrestricted.
In `hold`, the handle goes into the `Ref` through `RefB.modify`, whose linear function must consume the old contents: `\old -> old `lseq` Just h`, never `\_ -> Just h`, which is the multiplicity error of the second glossary entry.

The way back is `fromHandle :: PyHandle t -> Py π γ (Bound π t)`, which increfs the object into the current call's arena and hands out a reference that lives for this call, and `fromHandleShare`, the same as a view, which `heldRepr` uses to run `repr` on the held object.
The handle itself is also a `ToPy` value: `held` returns `Maybe (PyHandle PyAny)`, and the trampoline converts `Nothing` to `None` and `Just h` to the object, incref'd for the caller.

### Reading a handle out of a payload

`PyHandle` is `Dupable` and `Movable`, and copying one out of a borrow is the handle itself, so `Ref (Maybe (PyHandle PyAny))` is readable with `RefB.copyRef` like `Ref Int` was in `get`: the `Maybe` is `Copyable` when its content is.
The read is a linear `Maybe (PyHandle PyAny)`, which `Control.fmap move` turns into `Ur m` for the `case`.
A payload that holds a handle in an unrestricted position, `Ref (Ur (PyHandle PyAny))` or a list of handles inside `Ur`, works the same way and needs no instance at all.

### What the handle costs

A `PyHandle` keeps the object alive until the last copy of the handle is collected by the Haskell garbage collector, whose finaliser pushes the reference onto a pool that the next attached call drains.
So `release` does not decrement the count on the spot; the reference goes when the collector runs and a call drains the pool, which `test_tutorial.py` waits for with `ops.haskell_gc()` and a no-op call.
A payload should therefore hold handles for as long as they are meant to be held, and `release` them when they are not, rather than rely on the sweep of a call's arena, which never sees them.

## Glossary: four error messages

The four errors a first module meets, as GHC 9.12.4 prints them, and the mistake behind each.

### Returning a borrow from a scope

```
• Couldn't match type ‘π’ with ‘π' /\ π’
  Expected: Py (π' /\ π) (π' /\ π) (PyResult (Bound π PyStr))
    Actual: Py (π' /\ π) (π' /\ π) (PyResult (Bound (π' /\ π) PyStr))
  ‘π’ is a rigid type variable bound by
    the type signature for:
      escape :: forall (π :: Lifetime). Py π π (PyResult (Bound π PyStr))
```

The body of `attach'_` (or `attach_`, `parPy`, any rank-2 scope) created a reference and tried to return it to the enclosing scope.
Its lifetime is the intersection `π' /\ π`, and `π'` ends with the scope.
Return a value copied out instead (`copyOut`, `fromPy`), or a `PyHandle` made with `toHandle`, or create the object outside the scope.

### A `Mut` used twice, or not at all

```
• Couldn't match type ‘Many’ with ‘One’
    arising from multiplicity of ‘counter’
```

The linear receiver `counter` was used in two places, or in none, on some path.
Typical causes: the `Mut` passed to two operations instead of threading the handle the first one gives back; a `case` whose `Left` branch forgets to `consume` it (use `orFail`); a wildcard pattern `_` on it; a `let` binding of a linear value; a lambda `\_ -> n` passed to `RefB.modify`, whose linear argument must be consumed (`\old -> old `lseq` n`).
The message names the variable, and GHC reports it at the equation, not at the offending use, so read the whole function.
This error is also the one a wrong pattern on a `PyResult` produces, and it can drown the more informative errors of the same module: fix it first.

### A Python operand at a separate lifetime

```
• No instance for ‘γ Control.Monad.Borrow.Lifetime.Internal.<=!! π’
    arising from a use of ‘fromPy’
  Possible fix:
    add (γ Control.Monad.Borrow.Lifetime.Internal.<=!! π) to the context of
      the type signature for:
        bad :: forall (π :: Lifetime) (γ :: Lifetime).
               Share γ Counter -> Borrowed π PyAny -> Py π γ (PyResult Int)
```

The function was written at `Py π γ` with two unrelated lifetimes, and a Python operation on a `Borrowed π` operand needs `π >= γ`, which nothing relates.
Do not follow the "Possible fix": the `<=!!` goal is pure-borrow's internal solver class, and adding it to a signature makes every caller carry it.
Write the function at `Py π π`, which is what the trampoline instantiates anyway.

### A call with no arguments

```
• Ambiguous type variable ‘π''1’ arising from a use of ‘call’
  prevents the constraint ‘(π
                            Control.Monad.Borrow.Lifetime.Internal.<=!! π''1)’ from being solved.
  Relevant bindings include
    f :: Borrowed π PyAny
  Probable fix: use a type annotation to specify what ‘π''1’ should be.
```

The expression was `call f []`, or `toTuple []`, `toList []`, `callMethod o "name" []`.
The argument list of `call` is `[Borrowed π'' PyAny]`, and its attachment `π''` is a type variable of its own, so that arguments from an enclosing scope can be passed inside a nested one; an empty list leaves `π''` with nothing to determine it, and the constraint `π'' >= γ` that every argument must satisfy cannot be solved for an unknown.
Do not follow the "Probable fix" either: a type application such as `call @PyAny @π @π f []` compiles, but it is noise.
Use the zero-argument shapes, which have no argument list: `call0 f` for `f()`, `callMethod0 o "name"` for `o.name()`, and `emptyTuple` for `()`; `callZero` in snippet 3 is the first of them.
The same message with `‘toPy’` or `‘fromPy’` in place of `‘call’` is the more common ambiguity of a conversion whose Haskell type nothing fixes, and there the fix is a type application, `fromPy @Int v`.

## Building it

```bash
scripts/configure-python.sh .venv/bin/python
cabal build h2py-examples
scripts/install-module.sh
PYTHONPATH=build .venv/bin/python -m pytest h2py-examples/tests
```

`H2Py.Examples.Tutorial` is compiled by that build and registered as the `h2py_examples.tutorial` submodule through `tutorialSpec`, which `Module.hs` lists next to the other submodules; the top-level `h2py_examples.Counter` is `H2Py.Examples.Counter`, snippet 1 with docstrings and an `add` function.
Both modules declare a class named `Counter`, which is fine: a class is registered under its module's name, so the two are `h2py_examples.Counter` and `h2py_examples.tutorial.Counter`, and the splice resolves each `''Counter` to the registration of the module the name comes from.
To turn the tutorial into a module of its own, keep the `pymodule "tutorial"` line, add a stanza to the cabal file, a C file with `H2PY_MODULE tutorial`, and rename the built library to `tutorial.abi3.so`.
