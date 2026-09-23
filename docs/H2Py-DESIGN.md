# H2Py: PyO3-style Python extension modules on Pure Borrow

Status: **v1.6, after two adversarial review rounds and the maintainer's decisions on both** (three reviewers per round, one lens each; the first round and the revisions since v1.0 are in Appendix B, the second round and the decisions taken on it in Appendix C).
Author: Claude (Fable 5.1) with Hiromi Ishii, 2026-09-17, revised 2026-09-22.
Scope: a feasibility assessment, a design, and an implementation plan for a Haskell library in the spirit of [PyO3](https://pyo3.rs) that lets one write CPython extension modules in Haskell, built on top of the Pure Borrow API.
It also compares that design against a library built on Linear Haskell and `linear-base` alone, with no borrowing baked in.

Build targets, fixed by the maintainer: the CPython stable ABI (`abi3`) and the free-threaded stable ABI (`abi3t`, PEP 803, final for CPython 3.15).
No per-version wheels.
If a hand-rolled build tool ever becomes necessary it is written with Shake, but existing Python packaging tools are preferred where they fit.

Everything below that changes `pure-borrow` itself is subject to the review discipline in `AGENTS.md`: plan review before implementation, implementation review before commit, at least three lenses, one reviewer per lens.
This document is the plan review for the upstream part.

## 0. Summary and verdict

The library is feasible.
CPython already solves the hard problem the way we would: PyO3 does *runtime* borrow checking at the Python boundary, with a `RefCell`-like flag in every `#[pyclass]` object, because Python aliases objects freely and no static checker can see across that boundary.
Inside a method body, Rust's static borrow checker takes over from the flag.
H2Py has the same shape: one word per object at the boundary, PyO3's flag, recording the lend that Python cannot hold linearly, and Pure Borrow's static discipline inside.

Four decisions carry the design.

1. **Pure Borrow gains an impure `BO`.**
   `BO α` is a linear `ST`: its only eliminators are pure, and its parallelism is pure.
   Every interaction with CPython is a side effect, so today one would have to smuggle it through `unsafeSystemIOToBO`, which breaks the purity that `runBO` and `parBO` rely on.
   The fix is a *world* index on the monad: `BO' w α a` with `BO = BO' Pure` and `BIO = BO' RealWorld`.
   The world is a phantom parameter with a nominal role, every existing signature generalises at zero cost, `runBO` keeps accepting only the pure world, `BIO` is eliminated only from `IO`, and `parBO` keeps its implementation and works over both worlds.
   This is the one substantial change to `pure-borrow`, it is useful far beyond Python, and it comes with one small soundness fix the review surfaced, the forced `End` witness.
   A transformer over an arbitrary base monad was considered and parked; `workspace/PURE-BORROW-AS-TRANSFORMER.md` records why.
2. **Python object references are `pure-borrow` borrows of arena-owned slots.**
   The +1 that keeps a Python object alive for a scope `π` is owned by the scope's arena, or by Python's frame for an argument, and never by Haskell code.
   `Bound π t = Mut π (PyRef t)` is the unique handle: linear, the only handle through which the object may be mutated from Haskell.
   `Borrowed π t = Share π (PyRef t)` is a view: unrestricted, freely copied, read-only by protocol.
   The rule that makes this sound is the library's own: a shared borrow may not mutate; a unique borrow may mutate, even destructively, but may not *invalidate* the resource, so there is no `decref` on a handle and release belongs to the arena alone.
   This is the brief's second option, `PyRef` wrapped in `Mut` and `Share`, and it is where the design ended after two wrong turns that Appendix B records.
3. **Haskell payloads inside Python classes are reached by dereferencing the handle.**
   `derefMut` turns the unique handle `Bound π a` into `Mut γ a`, an in-place borrow of the payload for the rest of the scope, `derefShare` turns a view into `Share γ a`, and `copyPayload` copies the payload out.
   A method is written as `incr :: Mut π Counter %1 -> Int -> Py π π ()` or `get :: Share π Counter -> Py π π Int`, one lifetime variable, exactly as `&mut self` and `&self`, and the registration splice dereferences the handle for it.
   No `PyRef` wrapper, no new `AliasKind` and no callback: the runtime state is one word per object, PyO3's borrow flag, the lend that Python cannot hold linearly and that ends with the scope, and on the dereferenced borrow every container operation, `splitAt`, `reborrowing`, `Data.Ref.Linear.Borrow`, `parBO` and the scheduler apply unchanged.
4. **Attachment to the interpreter is a world that carries its own lifetime.**
   `Py π γ a = BO' (Python π) γ a` is the type of code that may touch CPython: `π` is the scope of its Python references and `γ` the ordinary borrow lifetime, and the two are tracked separately because they are different things.
   It is run only by the call trampoline and by `attach`, each of which holds the attachment for its whole scope on a bound thread, as PyO3 holds `'py`.
   `Python π` is not `Forkable`, since attachment is bound to the thread, so `parBO` in `Py` is a type error; the world's own fork-join is `parPy`, which releases, forks, and attaches afresh in each branch, so that every reference of the parent scope is usable there.
   Because forking is unavailable while attached, the parent has always released when a branch attaches, which makes the parent-child deadlock PyO3 can only document a type error here.
   Python references are indexed by `π`, so a reference created inside a borrow scope is not confined to that scope; Haskell borrows are indexed by `γ`, so `detach`, which runs a `BIO (δ /\ γ)` body, keeps every one of them and loses every Python operation.
   The detached body can therefore use a `Mut` over a NumPy buffer and run `parBO` and the divide-and-conquer scheduler on it.
   That is the showcase: in-place, statically disjoint, multi-core kernels over NumPy arrays, with the interpreter detached, callable from Python.

The linear-base-only alternative (section 6) keeps the `Py` monad, the runtime word, GC-managed handles and a checkout/checkin access style with a pure body.
It gives up scoped views of owned references that can still see the enclosing scope, in-place borrows of a payload, disjoint splitting for parallelism, and a detached body that uses the caller's resources.
The recommendation is to build on Pure Borrow, with the receiver-form methods as the beginner surface, with the caveat stated in 6.3 that "applied showcase of Pure Borrow" is a goal of this maintainer, not an engineering argument.

Cost after two reviews: about 18 to 23 engineer-weeks to a usable 0.1, of which the upstream work is done except the structured `parBO` change of 4.4.
The first draft said 9 to 12 and the first review 13 to 16; the second review's reasons for the increase, the structured `parBO` change, Template Haskell registration and the size of Phase 3, are recorded in Appendix C.

## 1. Goals and non-goals

Goals for 0.1:

- Write a CPython extension module in Haskell: module-level functions, classes with Haskell payloads and methods, errors in both directions, conversions for the usual scalar and container types.
- Safe parallelism inside a call: detach from the interpreter, use `parBO`, `Par`, and `Control.Concurrent.DivideConquer.Linear` on borrows of Haskell-owned data and of NumPy buffers.
- Free-threaded CPython through `abi3t`, which PEP 803 makes available from CPython 3.15.
  Free-threaded 3.13 and 3.14 have no stable ABI and are therefore out of scope, since per-version wheels are.
- Soundness on the Haskell side at the level `pure-borrow` already promises: no two live `Mut`s over the same memory, no borrow outliving its scope, no CPython call from a detached or unattached thread.

Non-goals for 0.1:

- Subclassing Python classes from Haskell (`Py_TPFLAGS_BASETYPE` stays off), `__slots__`, metaclasses, async/await.
- Cycle-GC integration (`tp_traverse`) for payloads that hold Python references; leaks through cycles are documented, as they were in early PyO3.
- Windows.
- More than one Haskell-built extension module per process; see 5.9.
- Embedding Python into a Haskell program; `inline-python` covers that direction.

## 2. Feasibility and risk register

| # | Risk | Severity | Assessment and mitigation |
|---|------|----------|---------------------------|
| R1 | Building and distributing a Haskell `.so` as a Python extension | high, well understood | Cabal `foreign-library` (`type: native-shared`) links dynamically against the store's Haskell libraries; the wheel must bundle on the order of 40 to 50 of them plus `libgmp` and `libffi`, which `auditwheel`/`delocate` do but at 50 to 150 MB per wheel. A `-staticlib` build is the alternative and needs position-independent Haskell libraries throughout; whether ghcup's x86_64 Linux bindists provide them is not established. Phase 1 is a two-week spike that settles this before any API is written. |
| R2 | A GHC RTS inside a host process it does not own | medium | Mandatory `-threaded`, `--install-signal-handlers=no`, RTS options via the environment, never `hs_exit`, `fork()` unsupported after import with a child hook that turns calls into a clear error, one RTS per process. Constraints to document, not unknowns. |
| R3 | Per-call overhead | medium | Entering the RTS through an adjustor or `foreign export` is on the order of a microsecond; every CPython call that can run Python code or block is a `safe` foreign call, which releases and reacquires the capability. PyO3 is on the order of 50 to 100 ns. Both numbers are hypotheses until Phase 1 measures them on the real trampoline, arena push and sweep, pool drain and a dereference included. H2Py targets coarse-grained calls. |
| R4 | Reference leaks on exception paths | medium | Haskell has no destructors, so an owned reference dropped by an exception would leak. Owned references are registered in a per-scope arena swept at scope exit, with eager release explicit and nested scopes for loops. See 5.2. |
| R5 | Ergonomics of `/\`-typed scopes for Python library authors | medium | Methods are written at the call's lifetime, `Mut π a %1 -> … -> Py π π r`, with no outlives constraint and one lifetime variable; the two axes appear only inside scopes (`sharing`, `reborrowing`, `attach'`, buffers), where the library's operations carry a `π >= γ` that solves on every meet. |
| R6 | Registration machinery | low | Function pointers come from `foreign import ccall "wrapper"` adjustors and conversion glue from type classes, but registering a lifetime-polymorphic method is a Template Haskell splice (`pymethods`, `pymodule`), because a value-level `method` would need an impredicative argument type (Appendix C); TH is also used for `pyclass ''T` (instance generation plus the closedness check of 5.3). |
| R7 | Stable-ABI constraints and `abi3t` | low | The shim uses only limited-API functions, with the attachment check as a shim thread-local because `PyGILState_Check` is not one; the object layout is never computed, `PyObject_GetTypeData` (PEP 697) is used instead; module init is multi-phase, with `PyModExport_` (PEP 793) for `abi3t`. Minimum versions: 3.12 for `abi3`, 3.15 for `abi3t`. |
| R8 | Generalising 372 `BO` signatures across 25 modules | low, mechanical | Phantom index, nominal role, explicit `forall` with `w` last so explicit type applications keep their positions; verified by `pure-borrow-inspection` and the three benchmark suites. |
| R9 | `parBO` and the scheduler lose branch exceptions | medium | Today a branch that throws leaves the parent blocked on an `MVar`; inside a Python process that is a hang with the interpreter attached. Decided: `parBO` and the scheduler become structured, no branch outliving the call on any exit path (4.4): a failing branch cancels its sibling and both are joined before the rethrow, and a parent interrupted asynchronously cancels and joins both before it unwinds; an upstream change of its own, with the concurrency reviewer `AGENTS.md` requires, landing as Phase 0.5 before Phase 4 exposes `qsortDC` to Python. |

Nothing in the list is a soundness risk for the borrow model itself.
The one-word runtime lend at the boundary is PyO3's own, proven approach with its shared count removed, and the review's three blockers were all in the reference model and the capability plumbing, both now redesigned.

## 3. PyO3 in one table, mapped to Haskell

| PyO3 | Meaning | H2Py |
|------|---------|------|
| `Python<'py>` | the thread is attached to the interpreter for `'py` | the monad `Py π γ`: Python references scoped by `π`, Haskell borrows by `γ`; attachment held per scope on a bound thread, checked per operation |
| `Bound<'py, T>` | owned strong reference, cannot outlive `'py` | `Bound π t = Mut π (PyRef t)`: the unique handle to an arena-owned +1; linear, may mutate, cannot release |
| `Borrowed<'a, 'py, T>` | borrowed reference, no refcount traffic | `Borrowed π t = Share π (PyRef t)`: a view; unrestricted, read-only by protocol |
| `Py<T>` | GIL-independent strong reference, needs a token to use | `PyHandle t`, unrestricted, GC-managed |
| `#[pyclass] struct T` | Python type carrying a Rust payload with a runtime borrow flag | `pyclass ''T`: the Haskell payload type *is* the Python type tag, so an instance is `Bound π T` |
| `&self` / `&mut self` | runtime-checked shared / exclusive access to the payload | methods with receiver `Share α T ->` / `Mut α T %1 ->`; `pymethods` dereferences the handle for them |
| `PyRef<T>` / `PyRefMut<T>` | the guard, when it must be explicit | `derefShare` on a `Borrowed π T` view / `derefMut` on the linear `Bound π T` handle: in-place borrows of the payload, held for the scope; one word per object guards what the types cannot see |
| `PyBorrowError`, `PyBorrowMutError` | raised on conflicting borrows | `RuntimeError: busy`, one error, in PyO3's two cases: a writer against any hold, a reader against a writer; the lend state is PyO3's flag, `Free`, `Shared n`, `Mut`, `Poisoned` |
| `#[pyclass(frozen)]` | no flag, payload must be `Sync` | `pyclass ''T` with the `frozen` option: unrestricted payload, no word, methods receive it by value |
| `Python::detach` (`allow_threads`) | release the GIL around Python-free work; closure must be `Ungil` | `detach :: (forall δ. BIO (δ /\ γ) r) %1 -> Py π γ r`; the body is `BIO`, so it cannot touch CPython, and it keeps every Haskell borrow |
| `!Send` on `Python<'py>` and `Bound<'py, T>` | a forked closure cannot capture the attachment | `Python π` is not `Forkable`: `parBO` in `Py` is a type error; `detach (parBO …)` forks `BIO` branches, and `parPy` attaches afresh in each branch |
| `Python::attach` inside a rayon worker | re-attach on a worker thread, with no evidence that the caller released | `attach_` inside a branch, which is safe because forking is refused while attached, so a branch always runs in a released parent |
| `PyErr`, `PyResult` | Python exception as a Rust value | the same: `PyErr` is an unrestricted value and every fallible operation returns `PyResult a = Either PyErr a`; nothing unwinds for a Python error, and a Haskell exception becomes `RuntimeError` unless `ToPyErr` maps it, and poisons |
| `FromPyObject`, `IntoPyObject` | conversions | `FromPy`, `ToPy` for value types; reference-typed arguments and results handled by the trampoline |
| `#[pyfunction]`, `#[pymethods]`, `#[pymodule]` | proc macros | the splices `pymethods` and `pymodule` over value-level tables of adjustors |
| `PyBuffer` / rust-numpy `PyReadwriteArray` | buffer protocol views with a global borrow registry | `requestBufferMut` then `withBufferMut` over `Data.Vector.Generic.Mutable.Linear.Borrow.Unrestricted` with a `Storable` backend, with the same registry |
| `pyo3-stub-gen` | type stubs, from a separate binary that links the crate | built in: `renderStubs` on the module description, emitted by the build hook (5.11) |

## 4. Upstream change: the impure `BO`

Status: **landed** in commit `a816d2a`, with the amendments recorded in `workspace/WORLD-BASE-IMPURITY-REVIEW.md`; this section is the plan as reviewed, with module names updated to the canonical hierarchy, and the two amendments that bind H2Py are stated in section 7.

### 4.1 Why the current `BO` cannot host CPython

`BO α a` is `State# (ForBO α) %1 -> (# State# (ForBO α), a #)`, and its eliminators `runBO`, `srunBO`, `execBO` and `unsafePerformEvaluateUndupableBO` all end in `runRW#`.
That is what makes a `BO` computation a pure value: GHC may duplicate it, float it, share it, or never run it, and none of that is observable because the only effects are on resources the linear discipline proves unaliased.
`parBO` inherits the same licence: it forks real threads, but the result is deterministic because the branches are pure.

A CPython call is none of those things.
Reference counts, attachment, arbitrary Python callbacks, exceptions and I/O are all observable, so a `BO` that performed them could be run twice by CSE, run zero times by laziness, or run on a thread that is not attached.
`unsafeSystemIOToBO` exists for the library's own trusted primitives and says so in its Haddock.
A Python binding cannot be built on it.

### 4.2 Design: a world index on the monad

```haskell
-- Control.Monad.Borrow.Internal   (as landed; the plan was written against the WIP module Control.Monad.Borrow.Generic.Internal)
newtype BO' (w :: Type) (α :: Lifetime) a
  = BO' (State# (ForBO α) %1 -> (# State# (ForBO α), a #))
type role BO' nominal nominal representational

data Pure                          -- the pure world; an uninhabited tag, like GHC.Exts.RealWorld
type BO  = BO' Pure                -- exactly today's BO
type BIO = BO' RealWorld           -- the impure world

-- The capability to lift IO into a world.
-- The method is the lifting function itself, so a bodiless instance diverges at its first use
-- and a working forged instance has to contain Unsafe.coerce; see 4.3.
class Impure w where
  liftLinIO :: System.IO.Linear.IO a %1 -> BO' w α a
instance Impure RealWorld where liftLinIO = unsafeLinIOToBO
```

The representation does not change.
`w` is a phantom parameter of kind `Type`, so downstream libraries can introduce their own worlds; H2Py introduces `Python π` in 5.1.
The kind is open on purpose: a closed `World` kind would have forced H2Py to newtype `Py` over `BIO` and lift every container operation by hand.

The role annotation is load-bearing.
A phantom parameter is inferred to have role phantom, so without the annotation `Data.Coerce.coerce :: BIO α a -> BO α a` typechecks with no constructor in scope; the review compiled and ran exactly that, and it printed from inside `runRW#`.
`α` is already nominal because `State#`'s parameter is, which is why the existing `BO` never needed an annotation.

Every signature in the library that mentions `BO β x` becomes `BO' w β x`, with an explicit `forall` that places `w` last.
The explicit `forall` is not optional: for a signature without one, GHC orders type variables left to right, so `w` would come first and every existing explicit type application such as `execBO @α @(After α a)` at `BO.hs:137` would silently change meaning.
The generalisation covers the scope combinators (`srunBO`, `sharing`, `reborrowing` and their variants, the plural forms), `borrowM`, `askLinearly`, `evaluateBO`, `modifyBO`, `Reborrowable`, `Clone` (whose `clone :: Share α a %1 -> BO' w α a` stays sound because an instance must then work at `Pure`), and every container module.
The `<:` instance for the monad keeps the world fixed: `instance (α >= β, a <: b) => BO' w α a <: BO' w β b`, and `assocBOEq` likewise.
The world is phantom, so the optimised Core is identical; `pure-borrow-inspection` and the three benchmark suites are the evidence.

What stays pure-only, and what is generalised over every world:

```haskell
runBO  :: Linearly %1 -> (forall α. BO α (After α a)) %1 -> a     -- unchanged: only the Pure world
runBO_ , runBOLend, execBO, sexecBO, scope_                            -- unchanged

-- A world whose computations may be moved to another thread unchanged.
-- A nullary marker: no method, no runtime content; discharged statically at every concrete world.
class Forkable w
instance Forkable Pure
instance Forkable RealWorld

parBO  :: (Forkable w) => BO' w α a %1 -> BO' w α b %1 -> BO' w α (a, b)     -- today's body, one implementation
newtype Par w α a = Par (BO' w α a)
instance (Forkable w) => Control.Applicative (Par w α)                        -- today's applicative

divideAndConquer, divideAndConquer', naiveDivideAndConquer, naiveDivideAndConquer', qsortDC, fftDC, qsort
        :: (Forkable w, …) => …                                                 -- same gate: forkBO is the same fork
sequentialDivideAndConquer, sequentialDivideAndConquer'
        :: …                                                                    -- forks nothing: unconstrained
```

`parBO` keeps exactly its current implementation and semantics, and it is one implementation for every world at which it exists: every `BO' w` is a state function, so the body that forks two of them is world-independent.
`Forkable` states the one thing a world must satisfy for that body to be meaningful: a computation of the world carries nothing bound to the thread it started on, because a branch runs on an unbound thread.
The two state-token worlds are the instances, so at `BO` and `BIO` nothing changes and no dictionary survives inlining.
A world with a per-thread invariant is not an instance, and that is not a restriction on `parBO` but a fact about the world: its fork-join must give the invariant up first, and 5.1 shows H2Py's, `parPy`, which is `parBO` applied through the world's own release.
Such a world declares an `Unsatisfiable` instance so that the type error names the alternatives.
The divide-and-conquer scheduler carries the same constraint, since its `forkBO` is the same fork, and its records are world-polymorphic so that one kernel serves every world.

What is new, in `Control.Monad.Borrow.IO`:

```haskell
liftBO        :: forall α a w. BO α a %1 -> BO' w α a                                 -- pure into any world
liftIO        :: forall α a w. (Impure w) => System.IO.Linear.IO a %1 -> BO' w α a    -- linear-base's linear IO; = liftLinIO
liftSystemIOU :: forall α a w. (Impure w) => IO a -> BO' w α (Ur a)                   -- unrestricted result, always safe

-- in .Unsafe:
unsafeLiftBIO :: forall α a w. (Impure w) => BIO α a %1 -> BO' w α a                  -- a BIO computation into another impure world, unchanged

runBIO     :: (forall α. BIO α (After α a)) %1 -> System.IO.Linear.IO a
runBIOLend :: (forall α. BIO α (Lend α a))  %1 -> System.IO.Linear.IO a
runBIO_    :: (forall α. BIO α a)           %1 -> System.IO.Linear.IO a
withBIO    :: (forall α. BIO α (After α (Ur a))) -> IO a              -- the withLinearIO-shaped runner

```

`liftSystemIOU` is the safe lifting: its result is `Ur`, so an aliased value returned by system `IO` can never be mistaken for a linear one; the name follows linear-base's `MonadIO`.
`liftIO` takes linear-base's `IO`, whose own `fromSystemIO` already carries the freshness obligation, so lifting it adds none.
`unsafeSystemIOToBO :: IO a %1 -> BO' w α a` remains in `.Unsafe` for the library's trusted primitives.

Lifting a whole `BIO` computation into another impure world is not part of the safe API.
It is sound for memory, and it keeps `Impure w` so that the pure world stays closed even to the hatch, but a downstream world may attach a per-thread invariant to its scopes, and running arbitrary `BIO` code, which may block, fork, or itself enter such a scope, *while inside* one is where liveness hazards live; 5.1 shows the case.
A world that wants to run `BIO` code safely provides a delimiter that leaves its invariant first, as H2Py's `detach` does.
No `concurrently` is provided: `parBO` over `RealWorld` is the parallel combinator, and an `async`-style operation with cancellation is not something this library needs.

### 4.3 Soundness argument

The purity of `BO` is untouched.
`runBO` still requires `forall α. BO α _`, which is `BO' Pure`, and `Pure` has no `Impure` instance.

Class-as-capability needs one more line than the first draft had.
A user can declare an orphan instance with no method body, which is a warning rather than an error, and if the capability were a witness that nothing ever forces, the dictionary would never be inspected and the lift would succeed.
The review demonstrated exactly that hole against today's `End` class: a bodiless `instance End α` lets safe code `reclaim` a lender while its `Mut` is live, and the program prints the write made through the borrow.
`Impure` avoids the hole by making its method the operation: `liftLinIO` is what `liftIO` calls, so a bodiless `instance Impure Pure` diverges on first use, and an instance that works has to contain `Unsafe.coerce`, which is unsound code its author wrote rather than nothing.
`End` got the corresponding fix, forcing `endToken` in `reclaim`, `withEnd` and `unAfter`, in the same upstream change.

`runBIO` never introduces `runRW#`.
It takes the state token from the enclosing linear `IO`, coerces it to `State# (ForBO α)`, runs the body, and hands the token back, exactly as `stToIO` sequences an `ST` computation.
`withBIO` takes its argument with an unrestricted arrow, so the body cannot close over linear variables and may be run any number of times by the surrounding `IO`; this is `System.IO.Linear.withLinearIO`'s shape.

Lifetime erasure is unchanged.
`runBIO` instantiates the parametric `α` at a fresh `Al i` from `newLifetime`, as `runBO` does, and applies `withEnd` to the `After` only once the body has returned; the argument in `srunBO`'s Haddock applies verbatim.

`liftBO` is sound because a pure computation is a special case of an impure one.
`unsafeLiftBIO` still requires `Impure w`, so that even the escape hatch can never bring a `RealWorld` computation into the pure world; what makes it unsafe is liveness in a world with a per-thread invariant (5.1), not memory.

Exceptions do not create aliasing.
An exception escaping a `BIO` body abandons the linear values in flight; a `Lend` that is never reclaimed means the owner is simply lost, as it already is when `error` fires inside `runBO`.
Leak-freedom on exception paths is a resource-management property that H2Py addresses with its arena in 5.2.

### 4.4 One soundness fix, and one recorded behaviour

1. **Forced `End` witness** (a fix, filed as its own pull request before the world index).
   `reclaim`, `withEnd` and `unAfter` pattern-match `endToken` so a forged instance diverges.
   A runtime spec defines the bodiless orphan instance and asserts that forcing `reclaim`'s result throws rather than returning.
   Recorded in a `Note [Forged capability instances]` cited from the Haddock of `End`.
2. **`parBO` and branch exceptions** (decided: structured; an upstream change still to land, Phase 0.5).
   Today `parBO` is two `forkIO`s and two `takeMVar`s with no `try`, `mask` or `finally`, so an exception in a branch is printed by the RTS and the parent blocks; the scheduler's `concurrentMap_` discards every worker's `Thread` and the parent blocks on a bare `takeMVar#`, so a worker that throws inside `divide` leaves its subtree unreleased and the root never fills.
   Inside a Python process each is a hang with the interpreter attached.
   The maintainer's decision is that propagation is the only sound behaviour, and the second review sharpened what it requires: `parBO`, `Par` and the scheduler become *structured*, no branch outliving the call on any exit path.
   A branch runs under `try` and reports `Either`; the parent waits under `mask`; on a branch's failure it cancels the sibling with a private exception, so that the sibling's own `ThreadKilled` cannot replace the real one, waits for it, and rethrows; on an asynchronous exception delivered to the parent while it waits, it cancels and waits for both under `uninterruptibleMask_` before unwinding, which is the shape of `async`'s `concurrently`.
   The scheduler needs an exit latch every worker signals in `finally`, a first-failure slot, the existing `consume master` shutdown to wake sleepers, `throwTo` for workers inside a callback, and the parent waiting on the latch before it rethrows.
   The reason is ownership: a branch still running when the exception leaves the call could keep writing through a borrow into memory the parent's unwinding is about to release, in H2Py a payload the sweep poisons and Python may then free, or a NumPy buffer whose view the sweep releases, and joining the sibling only on the child-failure path, as the first version of this decision said, leaves the parent-interrupt path open.
   The residue is recorded: `throwTo` lands only at a safe point, so a non-allocating loop compiled without `-fno-omit-yields`, or a branch blocked in a `safe` call, delays the join until it reaches one.
   The change carries the concurrency reviewer `AGENTS.md` requires for anything that touches `parBO` or the scheduler, and lands as Phase 0.5, before Phase 4 exposes `qsortDC` and `fftDC` to Python; until it lands, a Haskell exception inside a parallel branch hangs the call.
   A propagated exception reaches the trampoline like any other Haskell exception and poisons what the arena holds mutably (5.3), so the shipped kernels still validate their inputs first and answer `Left` where they can.

### 4.5 Impact and migration

Source compatibility for users of the safe API is complete: `BO α a`, `runBO`, the scopes and every container operation keep their names and shapes, and explicit type applications keep their positions.
Users who pattern-match the `BO` constructor through `Control.Monad.Borrow.Unsafe` see it move to `BO'`, and every `Control.Monad.Borrow.Pure.*` module below the umbrella is gone in favour of the canonical `Control.Monad.Borrow` hierarchy.
Instances of `Reborrowable` written outside the library must generalise their method bodies over `w`; the only known instances are in `Experimental`.
`Par` gains the world parameter, which is the one visible change to a public type.
Haddock now shows `BO' w β x` where it showed `BO β x`; the tutorial in `Control.Monad.Borrow.Pure` gains a paragraph on worlds.

The name `BO'` is the maintainer's decision; the reviewers had preferred `Borrowing`.

### 4.6 Tests and evidence for the upstream change

- `test/Control/Monad/Borrow/IOSpec.hs`: effect ordering through `liftSystemIOU` observed via `IORef`; `runBIO` reclaiming a lender; `withBIO` result; `parBO` at `BIO` running both branches on a split borrow, with the existing `parBO` tests unchanged at `BO`.
- `TypingCases`: `runBO lin (liftSystemIOU (pure ()))` must fail with the world mismatch; `unsafeLiftBIO` into `BO` must fail for want of `Impure Pure`; `Data.Coerce.coerce` from `BIO α a` to `BO α a` must fail on the nominal role; `parBO`, `runPar` and `divideAndConquer` at a world with no `Forkable` instance must fail, and at a world with an `Unsatisfiable` instance must fail with that instance's message.
  These are ordinary type-equality, missing-instance and role errors, which `-fdefer-type-errors` defers, so they belong in `TypingCases` rather than `test/typing-fail/`.
- A runtime spec for a bodiless `instance Impure Pure`, asserting that `liftIO` diverges, alongside the `End` one.
- `pure-borrow-inspection` unchanged and green at `-O2`; `qsort-bench`, `fft-bench` and `pure-borrow-bench` before and after, numbers quoted in the PR.
- `--flags=+slow` built and tested, since the scope combinators are touched.

## 5. H2Py design

### 5.1 The `Py` monad and attachment

```haskell
-- H2Py.Py
data Python (π :: Lifetime)        -- world tag: a Python scope whose references and arena live for π
instance Impure (Python π)         -- liftLinIO is the same coercion as RealWorld's; H2Py is a trusted library
type Py π = BO' (Python π)         -- Py π γ a: Python references scoped by π, Haskell borrows by γ

attach  :: (forall π. Py π (π /\ γ) (After π a))              %1 -> BIO γ a   -- pin a bound thread, attach, run, release
attach_ :: (forall π. Py π (π /\ γ) a)                         %1 -> BIO γ a
attach' :: (forall π'. Py (π' /\ π) (π' /\ γ) (After π' a))   %1 -> Py π γ a  -- a nested scope with its own arena, on the same attached thread
attach'_ :: (forall π'. Py (π' /\ π) (π' /\ γ) a)              %1 -> Py π γ a  -- the srunBO_ shape: the loop tool, for a body with no finaliser

-- Leaving the scope, and re-entering the interpreter from another thread.
detach :: (forall δ. BIO (δ /\ γ) r) %1 -> Py π γ r                        -- release the scope's hold for the window δ, run, restore
parPy  :: (forall δ π'. Py π' (π' /\ (δ /\ γ)) a) %1
       -> (forall δ π'. Py π' (π' /\ (δ /\ γ)) b) %1
       -> Py π γ (a, b)
parPy f g = detach (parBO (attach_ f) (attach_ g))                         -- the world's own fork-join: release, fork, attach in each branch

instance Unsatisfiable (Text "parBO cannot run inside Py: use parPy, liftBO (parBO …) or detach (parBO …)") => Forkable (Python π)

-- The lifts are pure-borrow's own, under their own names: liftBO from Control.Monad.Borrow.IO, and linear-base's
-- MonadIO methods (liftSystemIOU for IO) through Impure (Python π); H2Py defines no liftIO or liftBO of its own.
-- There is no liftBIO into Py: detach is the safe way to run a BIO computation from Py, see below.
```

`Py π γ a` is a `BIO γ a` computation with one more index and one invariant that is held per scope and checked per operation.
Attachment to the interpreter is held for a whole scope, as PyO3 holds it for `'py`.
The trampoline's thread holds the GIL from Python for the duration of the call, and `attach` pins a bound thread with `runInBoundThread` and brackets its body in `PyGILState_Ensure` and `PyGILState_Release` under `mask`.
The bound thread is what CPython's per-OS-thread thread state requires, since `Release` must run on the thread that ran `Ensure`, and what GHC's freedom to move an unbound thread between OS threads at any `safe` call would otherwise violate; the trampoline's thread is bound for free, because GHC runs every entry from C in a bound thread.
Between operations no attachment work happens, so a scope with many Python operations pays nothing per operation beyond one check.

**Forking.**
`Python π` is not `Forkable` (4.2), because attachment is bound to the thread; the `Unsatisfiable` instance turns `parBO` in a `Py` computation into a type error that names the three shapes that are right.
`liftBO (parBO …)` runs pure branches while attached, which is fine for short pure work.
`detach (parBO …)` runs `BIO` branches with the hold released: they keep every Haskell borrow and may do `IO`, and they cannot express a Python operation because they have no `π`, which is what PyO3 gets from `Python<'py>` being `!Send`.
`parPy` is the world's own fork-join, and it does something PyO3 cannot: its branches may re-enter the interpreter on their own threads with every reference of the parent scope usable inside them, the call's arguments included, because the parent's attachment `π` is a leaf of each branch's ambient `π' /\ (δ /\ π)` and the parent's arena is alive while it waits.

`parPy` is nothing but `detach`, `parBO` and `attach_`: release, fork, attach in each branch.
The parent-child deadlock of PyO3's `Python::attach` in a worker is a type error here for one reason: forking is unavailable while attached, so a branch always runs inside a `detach`, in a released parent, and its `attach_` can never wait for the thread it was forked from.
An earlier draft carried a lifetime-gated token, `Detached δ π` with `detachWith` and `attachFrom`, as evidence of the release; the second review showed the evidence to be redundant, since a plain `attach_` in a branch is exactly as safe, and the counted lend state of 5.3 removed the token's last job, the nesting of one arena under another, so the token is gone.
Under the GIL the branches' attachments serialise and their Haskell work overlaps; under free-threading both overlap.
`attach_` on the parent's own released thread is legal CPython nesting, `Ensure` after `SaveThread` with `Release` restoring the released state.

What no type can close is the sibling case: a branch that is attached and then blocks while another branch waits for the GIL.
The right shape is always available and natural, `detach` inside the branch before it waits or forks further, so the residue needs a deliberately wrong shape, and it is the same residue PyO3 documents.

Two things narrow the ways of breaking that rule by accident.
There is no `liftBIO` into `Py` in the safe API: the safe way to run a `BIO` computation from `Py` is `detach`, which releases the attachment first and therefore cannot deadlock on anything the body blocks on, forks, or attaches; `unsafeLiftBIO` in `.Unsafe` runs one while attached, and is unsafe for liveness rather than for memory.
And every Python operation begins, inside the shim, with a check of the shim's own thread-local attachment flag, set and cleared by its `Ensure`, `Release`, `SaveThread` and `RestoreThread` wrappers, because `PyGILState_Check` is not in the limited API; a `NULL` from `PyGILState_GetThisThreadState`, which is, additionally catches a Haskell worker that never attached, and `GetThisThreadState` alone would not do, since a detached thread still has a thread state; the check raises `NotAttached` as a Haskell exception on an unattached thread, so the residual routes to Python from the wrong thread, through lifted `IO` that forks or attaches, end in an exception rather than in undefined behaviour.
What remains reachable is deliberate: `IO` lifted with `liftSystemIOU` may fork a Haskell thread that attaches while the `Py` thread blocks on it, which is the same residue PyO3 has with `std::thread::spawn` and `Python::attach`.

Per-operation attachment was considered and rejected: it does not remove the rule, because on the trampoline path the calling thread holds the GIL for the call whether or not each operation re-ensures it, so a branch acquiring the GIL per operation would wait on a parent blocked in `parBO` all the same; removing the hold instead would cost a GIL acquisition per operation and the atomicity between consecutive operations that PyO3 provides.

The two lifetimes are different things and are tracked on different axes.
`γ` is the ordinary borrow lifetime and is what every `pure-borrow` operation sees; `attach` meets it with its attachment, and a borrow taken at the caller's `γ`, with `borrow x lin`, may leave a Python scope as it may leave any `liftBO` block, whereas `borrowM` borrows at the ambient `π /\ γ` and may not.
`π` is the Python scope: the index of every Python reference (5.2) and of the arena it belongs to; it is fresh in `attach` and in each trampoline call, and nested through `attach'` by intersection, so a reference from an outer scope is usable in an inner one while a reference from the inner one cannot escape.
Every delimiter also meets the ambient borrow lifetime with its attachment: the trampoline runs its body at `Py π π`, `attach` at `Py π (π /\ γ)`, `attach'` at `Py (π' /\ π) (π' /\ γ)`, `attachFrom` at `Py (π' /\ π) (π' /\ γ')`.
Outer Haskell borrows stay usable inside, since `π /\ γ <= γ`; the constraint of 5.2 solves for every reference of an enclosing attachment; and a payload borrow dereferenced inside a scope (5.3) is indexed by the ambient, so it dies before the sweep that releases its hold.
A body that must return an `After π a`, as `attach` and `attach'` require, produces it with `Control.fmap upcast (pureAfter x)`, because `pureAfter` at the ambient yields `After (π /\ γ) a` and `After` shortens the safe way, or with the bare `After` constructor; a loop body that has nothing to finalise uses `attach'_`, which asks for no `After` at all.
This is PyO3's `'py`, with the half of `Python<'py>` that PyO3 gets from the `Ungil` auto trait supplied instead by the world: a `BIO` body has no `π` and therefore no Python operation.

The first draft used a fixed `Python` tag and let Python references take the ambient borrow lifetime.
That conflation surfaced as a hole exactly where a user meets it first: inside a borrow scope, `sharing` on a handle or `reborrowing` on a Haskell structure, the ambient is `α /\ γ` with `α` rank-2, so a reference created there, by `toPy` or `getAttr`, could not be returned from the scope; in that draft receiver methods ran inside such a scope, so no method with a receiver could return a Python object.
With the two axes separate, a reference created inside a borrow scope is `Bound π _` and returns as a matter of course.

The `Python` world carries `π`, the index of every Python reference and of its arena, and the attachment invariant of its thread.
It is entered by the trampoline in 5.4 and by `attach`; both push an arena and sweep it at the end, under `mask` so that an asynchronous exception cannot leave the arena stack or the attachment inconsistent.
`runBIO` does not accept a `Py` computation, because `Python π` is not `RealWorld`; because `Impure (Python π)` holds, every `BIO` and `BO` computation lifts into it, so every container operation in `pure-borrow` is usable directly inside a method body with no lifting.
From an unbound thread, `runInBoundThread` does not `forkOS`; it re-enters Haskell as a bound thread on the current worker through a `safe` call, which is cheap, but the outer thread cannot receive asynchronous exceptions until the body completes, so a `timeout` around such an `attach` fires late.
`Py_IsFinalizing` is in the limited API from 3.13, and 3.12 has only the private `_Py_IsFinalizing`; so `attach`, and `detach`'s restore path, consult it where available and on every version a shim flag set by a Python `atexit` handler registered at module init, and refuse with an exception during finalisation, because `PyGILState_Ensure` and `PyEval_RestoreThread` then terminate the OS thread before 3.13.8, orphaning the RTS task and leaving its Haskell thread blocked forever, and hang it from 3.13.8 on.
The check races a flag that may flip afterwards, so a daemon Python thread returning from a detached kernel at interpreter exit can still hang, which is CPython's documented behaviour, and a `PyHandle` used from a stray Haskell thread at interpreter exit is documented as undefined.

`detach` releases the scope's hold with `PyEval_SaveThread`, runs a `BIO` body, and restores it with `PyEval_RestoreThread`, under `mask`, on the bound thread that holds it.
Releasing is required before any wait on another thread that must attach, which `parPy` does for you; before a long kernel under the GIL, so that other Python threads make progress; and before any long attached stretch under free-threading, whose stop-the-world pauses wait for attached threads.
The scheduler runs the same way: `detach (divideAndConquer …)` with `attach_` inside `divide` is a parallel sort with a Python comparator.
The body is typed `BIO (δ /\ γ)`, so it cannot run any `Py` operation, and there is no way to convert a `Py` computation into a `BIO` one.
It can use every Haskell borrow whose lifetime outlives `δ /\ γ`, which includes a buffer borrow from `withBufferMut` and a payload borrow from `derefMut` (5.3), and it can run `parBO` and the scheduler on them.
That typing is what `withBufferMut` relies on (5.7), and it is the analogue of PyO3's `Ungil` bound, expressed by the absence of `π` rather than by an auto trait.
A user who `liftIO`s their own `foreign import` of a CPython function inside a detached body is in `unsafe` territory, exactly as in PyO3.

Under free-threading, detaching around a long kernel is mandatory rather than polite: CPython's stop-the-world pauses wait for every attached thread.
Deadlocks are the same as in PyO3 and are documented the same way: never block on another Haskell thread that needs to attach while attached; detach first.
`checkSignals :: Py π γ (PyResult ())` wraps `PyErr_CheckSignals`; it runs handlers only on Python's main thread and it is a `Py` operation, so a detached kernel cannot call it, and a pending `KeyboardInterrupt` is reported, as a `Left`, by the first check or Python call after the kernel returns.

### 5.2 Python object references

```haskell
-- H2Py.Object
data PyRef t                                  -- the raw slot: a pointer; its +1 is owned by the scope's arena or by Python's frame; never exposed bare
type role PyRef nominal
type Bound    π t = Mut   π (PyRef t)         -- the unique handle: linear, LinearOnly, not Movable; may mutate the object
type Borrowed π t = Share π (PyRef t)         -- a view: unrestricted, Dupable, Movable; read-only by protocol
data PyHandle t                               -- unrestricted GC-managed strong reference: ForeignPtr with a deferred-release finaliser
type role PyHandle nominal

-- Views and handles relate exactly as Share and Mut do; nothing here is new.
share    :: Bound π t %1 -> Ur (Borrowed π t)                                                   -- pure-borrow's share
sharing  :: Bound π t %1 -> (forall β. Borrowed (β /\ π) t -> Py π' (β /\ γ) r) %1 -> Py π' γ (r, Bound π t)   -- pure-borrow's sharing
subShare :: (π >= π') => Borrowed π t -> Borrowed π' t                                          -- pure-borrow's subShare

-- Reading operations take a view and hand back fresh references as handles.
getAttr  :: (π >= γ) => Borrowed π t -> Text -> Py π' γ (PyResult (Bound π' u))
getItem, call, iterate, len, repr, copyOut, downcast :: …                                        -- likewise, on Borrowed
-- Mutating operations take the handle and return it beside the result, so that it survives a failure.
setAttr  :: (π >= γ, π'' >= γ) => Bound π t %1 -> Text -> Borrowed π'' u -> Py π' γ (PyResult (), Bound π t)
setItem, delAttr, delItem, the in-place number operations :: …                                  -- likewise, on Bound
-- Monomorphic constructors behind ToPy, for the tutorial.
toStr    :: (π >= γ) => Text -> Py π' γ (PyResult (Bound π' PyStr))
toInt, toFloat, toList, … :: …

toHandle   :: (π >= γ) => Borrowed π t -> Py π' γ (Ur (PyHandle t))                             -- incref into a GC-managed handle
fromHandle :: PyHandle t -> Py π γ (Bound π t)                                                  -- incref into the current arena
downcast   :: (PyTypeOf t, π >= γ) => Borrowed π u -> Py π' γ (Ur (Maybe (Borrowed π t)))      -- Ur: the result is unrestricted, so it must not be bound linearly
downcastMut :: (PyTypeOf t, π >= γ) => Bound π u %1 -> Py π' γ (Either (Bound π u) (Bound π t))
```

A reference is indexed by the attachment `π` it was created in, and every operation on it requires `π >= γ`: the reference outlives the ambient borrow lifetime, which bounds everything the operation's result could be stored in.
The attachment axis is never narrowed by a Haskell scope, which is what lets a reference created inside a borrow scope leave it; and every attachment delimiter meets the ambient borrow lifetime with its attachment (5.1), which is what makes the constraint solvable and, in 5.3, what keeps a dereferenced payload borrow inside the scope whose sweep releases it.

**The principle.**
A shared borrow may not mutate; a unique borrow may mutate, even destructively, but may not *invalidate* the resource, because release belongs to the owner.
For a Python reference the resource is the slot holding a +1, the owner is the scope's arena, and so there is no `decref`: a handle can mutate the object, a view can read it, and the +1 goes away when the arena is swept at the end of `π`.
That is what makes `Mut` and `Share` exactly the right types, and it is the answer to the question in the brief: no `PyBorrow` alias kind, and no wrapper, just `PyRef` under `Mut` and `Share`.

The ownership review's refutation of the first draft stays in the document, because it is the reason the principle is stated the way it is.
That draft had a `decref :: Bound π t %1 -> …`, and then

```haskell
bad b = Control.do
  b <- reborrowing_ b \b' -> decref b'   -- b' is a sub-borrow; the scope restores b afterwards
  decref b                               -- second release of the same slot
```

typechecks and releases twice.
The fault was not that `Bound` is a `Mut`; it was that a borrow was given an operation that invalidates what it borrows.
With no such operation there is no such program: every scope restores its borrow to a resource that is still valid, as scopes do everywhere else in the library.

**Instances**, all inherited.
`Bound` is `Consumable` through the affine no-op, `LinearOnly`, and neither `Dupable` nor `Movable`, which is `Mut`'s instance set; `Borrowed` is `Dupable`, `Movable` and `Consumable`, with `subShare` as its shortening, which is `Share`'s.
`Copyable (PyRef t)` and `Clone (PyRef t)` are declared `Unsatisfiable` with a message: copying the pointer out of a borrow would create an unscoped alias, and `Clone` runs in the pure world where no `incref` is possible; `copyOut` in 5.6 is the monadic replacement.
`DistributesAlias` is not derivable for `PyRef` and there is nothing to split.
Every operation demands `π >= γ` for the ambient borrow lifetime `γ`, and that rule is load-bearing: a reference packed existentially into a payload (`data Some where Some :: Bound π t %1 -> Some`, or the `Borrowed` variant) is legal and inert, because no rule of the outlives relation lengthens a lifetime, so nothing can ever be done with it.
The tests in Phase 2 assert both halves: the packed forms compile, and every operation on them is refused.

**Static and dynamic exclusivity.**
Through one handle, the types do the work: a second `derefMut` through the same `Bound` is a multiplicity error, a mutation through a view is a type error, and a handle that has been `share`d cannot mutate again.
What the types cannot see is Python: it may alias any object, it may call in from another thread, and two independent `getAttr` lookups or two `fromHandle` calls return two handles to one object.
Those conflicts are what the runtime word of 5.3 refuses, as PyO3's flag refuses them; inside a method both designs are static, and the difference is that here the handle itself is a borrow, so the static half also spans scopes and returned values, at no cost.

**Arena.**
Every attachment, that is every trampoline entry, every `attach` and every `attach'`, owns an arena: a chunked array of raw pointers that never moves, with a free-list.
The arena is the sole owner of every +1 created during its attachment and the runtime counterpart of the attachment lifetime: a reference belongs to the arena of the attachment `π` it was created in, which is the monad's index at the point of creation, so "which arena" is answered by the type and never by a thread-local lookup.
A `PyRef` is a pointer; the slot needs no address, because nothing releases a slot early.
Creating a reference registers its +1 in the current attachment's arena; handing a reference out of the scope, to Python as the call's result, to a `PyHandle`, or to `PyErr_SetRaisedException`, increfs and leaves the slot to the sweep.
At the end of the attachment, normal or exceptional, the arena is swept in one `safe` C call, in a fixed order: first every hold the scope took on a class payload (5.3) is released, or poisoned on an exceptional exit; then every buffer view still open is released with `PyBuffer_Release`; then every slot is `Py_DecRef`ed.
The order matters because a decref may run `tp_dealloc` and free the object whose type data the hold lives in, and a `__del__` reached from the decref loop may re-enter through a nested trampoline whose arena is a child of the one being swept, which is harmless only because the holds are already gone.
Holds are recorded in a list of their own, keyed by object, because a hold may be on an argument the frame lent, which has no slot.
An arena is touched only by the thread of its own attachment: a branch that re-enters through `attach_` creates its references in its own arena and only reads or mutates through outer references, never releasing them, so there is no cross-thread arena traffic and no lock.
The only cross-thread traffic is the deferred release pool below, which is locked.

Two consequences are documented rather than hidden.
There is no eager release, so a loop that creates one reference per iteration grows the arena linearly unless it wraps the iteration in `attach'`, which owns a child arena and sweeps it at the end of the iteration; `Bound (π' /\ π) t` cannot escape `attach'`, so the early sweep is sound.
This is the model PyO3 used until 0.21, and the reason it left it, unbounded growth without an explicit pool, is the same reason `attach'` exists; the other reason, a pool-ordering unsoundness, cannot arise here because arenas are lexically nested by rank-2 lifetimes.
And handing a reference out costs one incref where a transfer of the +1 would have cost nothing; that is nanoseconds per call and it is what keeps every borrow restorable.

**Deferred release pool.**
`PyHandle t` is PyO3's `Py<T>`: unrestricted, storable in payloads and Haskell structures across calls, released by a `ForeignPtr` finaliser.
The finaliser runs on the RTS finaliser thread, which is unbound and unattached, so it never calls CPython; it pushes the pointer onto a mutex-protected pool in the shim.
The pool is drained on every trampoline entry and exit and on every `attach`, with the protocol the review asked for: lock, swap the vector out, unlock, then decref each pointer in one `safe` call.
Holding the pool mutex across a decref would let `tp_dealloc` re-enter Haskell, allocate, and wait for a GC that cannot complete while the finaliser thread is blocked on the same mutex inside an `unsafe` push.
A C finaliser never decrefs for the same reason: it may run on a bound, attached thread, and a callback into Haskell from a C finaliser aborts the RTS.

**Foreign call safety.**
`Py_DecRef` runs arbitrary Python code (`__del__`, weakref callbacks, and H2Py's own `tp_dealloc`, which re-enters Haskell to consume a payload), so it is a `safe` call, as is every CPython function that can run Python code, block, or call back: `PyGILState_Ensure`, `PyEval_RestoreThread`, `PyObject_Call`, `PyObject_GetAttr`, `PyLong_AsLong` on a non-exact `int`, and so on.
A callback into Haskell from an `unsafe` call either deadlocks on the capability or makes the scheduler `stg_exit` the process with "re-entered unsafely".
Only `Py_IncRef` and exact-type leaf reads (`PyLong_CheckExact` then `PyLong_AsLong`, `PyFloat_AsDouble` on an exact `float`) are `unsafe`.
Under `abi3t` and PEP 703, borrowed-reference accessors such as `PyList_GetItem` are unsafe under concurrent mutation, so the shim uses only new-reference accessors; at the 3.12 floor those are `PySequence_GetItem`, `PyObject_GetItem` and `PyMapping_GetItemString`, since `PyList_GetItemRef` and `PyDict_GetItemRef` arrive only in 3.13.

Arguments arrive lent.
Python's frame holds a +1 on each argument for the duration of the call, so the trampoline wraps each `PyObject *` as a `Bound π PyAny` with no incref, exactly as `borrow` lends a resource without a `Lend` when the owner is known to outlive the scope; `π` is the call's attachment.
A function that only needs a view takes `Borrowed π PyAny` and the trampoline `share`s the handle for it.
Returning a reference to Python increfs it, since the frame's or the arena's +1 is not ours to give away.

Typed references use a phantom `t :: Type` tag: the built-in tags `PyAny`, `PyLong`, `PyFloat`, `PyBool`, `PyStr`, `PyBytes`, `PyTuple`, `PyList`, `PyDict`, `PyBaseException` are empty data types, and a user's payload type is its own tag (5.3).
Protocol operations are split by what the C API declares them to do, not by what Python code they run may do: reading operations (`getAttr`, `getItem`, `call`, `iterate`, `len`, `repr`, `copyOut`, `downcast`) take a `Borrowed π t` with `(π >= γ)` and hand fresh references back as `Bound π' _` inside `PyResult` (5.5); mutating operations (`setAttr`, `setItem`, `delAttr`, `delItem`, the in-place number operations) take the `Bound π t` and return it beside a `PyResult ()`, so that a method keeps its handle after a failed operation, as `Data.Ref.Linear.Borrow.modify` returns its handle.
Whether the Python code a call runs mutates other objects is invisible to the types, which is the same residue as everywhere else in the design and is what the runtime word of 5.3 exists for.
This convention is for *library* operations, and it is cheap to satisfy, because the ambient borrow lifetime is always a meet that contains the current attachment: `π` at a call boundary, `π /\ γ` inside `attach`, `π' /\ γ` inside `attach'`, `β /\ γ` inside a pure-borrow scope.
The constraint on a reference from any enclosing attachment therefore solves by the meet-elimination instances (`α /\ β <= α`, `α /\ β <= β` and their recursion through the incoherent layer), and so does a handle narrowed by `sharing` or `reborrowing`, `Bound (β /\ π) t`, inside the scope that narrowed it.
The first draft compared the reference's attachment with the current attachment instead, `π >= π'`; under that rule a narrowed handle satisfies no operation, since `π' <= β /\ π` needs `π' <= β` for a fresh `β`, so `sharing` on a handle could not have been used for anything.
User-written functions and methods do not add outlives constraints (5.4); they are written at the call's attachment, and receiver-form methods at the ambient borrow lifetime.

### 5.3 Python classes with Haskell payloads

```haskell
-- H2Py.Class
class (Consumable a) => PyClass a where     -- instances are generated by `pyclass ''T`; see the closedness rule below
  pyClassName :: Proxy a -> Text
  pyClassDoc  :: Proxy a -> Text
  -- method table and options are attached by `pymethods`

newObject  :: (PyClass a) => a %1 -> Py π γ (PyResult (Bound π a))

-- Dereference: a borrow of the object becomes a borrow of its payload, in place, at the ambient lifetime.
-- Left is busy, a live buffer export, or a poisoned object (5.5).
derefMut   :: (PyClass a, π >= γ) => Bound π a %1 -> Py π' γ (PyResult (Mut γ a))          -- claims the object for this scope
derefShare :: (PyClass a, π >= γ) => Borrowed π a -> Py π' γ (PyResult (Ur (Share γ a)))   -- claims it shared; repeatable within the scope
copyPayload :: (PyClass a, Copyable a, π >= γ) => Borrowed π a -> Py π' γ (PyResult a)     -- claim, copy, release at once; a fresh owner
```

`derefMut` and `derefShare` are for the handle what `Data.Ref.Linear.Borrow.readShare` is for a `Ref`: a dereference, not a scope.
The handle is consumed, and what comes back is an ordinary borrow of the payload where it lies.
There is no operation from a view to a `Mut` of the payload, which is the library's rule that a `Share` never yields a `Mut`; a view dereferences to `Share γ a` or copies through `copyPayload`, and nothing else.
There is no callback and no checkout: the payload is never taken out of the object, so there is nothing to put back, and the borrow is usable for the rest of the scope, interleaved with Python calls as PyO3's `PyRefMut` is.
On the dereferenced borrow every part of `pure-borrow` applies with nothing lifted: the container operations, `Data.Ref.Linear.Borrow` when the payload holds a `Ref`, `sharing` and `reborrowing`, `splitAt`, and inside `liftBO` or `detach` `parBO` and the scheduler, since `γ >= δ /\ γ` holds by meet elimination.
A long kernel is `detach` around the borrow; two payloads at once are two dereferences; replacement of an immutable payload is a `Ref` inside the payload type, as Appendix A does.

The result is indexed by the ambient borrow lifetime `γ`, not by the handle's `π`, and that choice carries the soundness of the hold.
Inside `sharing`, `reborrowing`, `withBufferMut` or `attach'` the ambient is a meet with a rank-2 component, so a payload borrow obtained there cannot leave the scope; and because every attachment delimiter meets the ambient with its attachment (5.1), the borrow dies no later than the sweep of the attachment that holds the object.
A narrowed handle, `Bound (β /\ π) a` inside `reborrowing`, dereferences under the same constraint, so a method that must keep its handle dereferences inside `reborrowing` and gets the handle back afterwards.

There is no `Cell` type.
The Haskell payload type is the Python type tag, so an instance of the class `Counter` is `Bound π Counter`, as `Bound<'py, Counter>` is in PyO3; `Cell` collided with Rust's flagless `Cell<T>` and with PyO3's deprecated `PyCell`.

The Python object holds a `StablePtr` to the payload and one machine word, the lend state below, in type data allocated with a negative `basicsize` and reached through `PyObject_GetTypeData` (PEP 697), never through offset arithmetic; that is what keeps the layout valid under `abi3t`, where `PyObject` is opaque.
`tp_dealloc` is a Haskell adjustor that catches every exception and reports it with `PyErr_WriteUnraisable`, saving and restoring any pending exception around it, because an exception escaping into the RTS's C entry point terminates the process.
It frees the `StablePtr`, runs `consume` on the payload unless the word is `Poisoned`, in which case the payload is leaked rather than traversed, since a torn header is exactly what `consume` must not read; then it fetches `tp_free` through `PyType_GetSlot` and decrefs the heap type, obtained through `PyObject_Type` rather than `Py_TYPE`, which is an inline read of a struct that `abi3t` makes opaque.
It is entered from Python on an attached thread, so a payload that holds `PyHandle`s releases them correctly.

**Closedness of payload types.**
`pyclass ''T` refuses a type constructor with parameters.
The reason is not the existential packing of 5.2, which is inert, but a parameterised instance: with `data Holder π = Holder (Bound π PyAny)` and `instance PyClass (Holder π)`, a method typed `Mut π (Holder π) %1 -> Py π π ()` unifies the stored reference's attachment with the *current* call's, and any operation on it, `getAttr` or `derefMut`, typechecks after the arena that owned it has been swept.
A type parameter of kind `Type` admits the same through `Box (Bound π PyAny)`.
So payload types are closed, existentials inside them are allowed and inert, and a hand-written `PyClass` instance carries this rule as a documented obligation, the way an `unsafe impl` does.

**The runtime lend: PyO3's flag, for Python's sake.**
Through the handle it receives, exclusivity is static: the `Bound` is linear, so no second `derefMut` through it can exist, and a view derived from it yields only a `Share`; nothing at runtime ever looks at a Haskell borrow.
What the types cannot see is that the owner of a Python object is the Python heap, which is unrestricted and multi-threaded: it cannot hold a linear `Lend`, and the same object enters Haskell through any number of independent trampoline calls at once, from other threads or re-entrantly from a callback, while `fromHandle` mints a fresh `Bound` from an unrestricted `PyHandle` each time it is called, so every entry manufactures its `Mut` from a raw pointer and the types see a forest of unrelated owners.
The lend state is the `Lend` that Python cannot hold, recorded in the object because the lender is unrestricted, and it says what a `Lend` says: lent exclusively, or lent read-only, and read-only lends are plural.
So the word records `Free`, `Shared n`, `Mut` or `Poisoned`, which is PyO3's `BorrowFlag` exactly.
`derefMut` compares-and-swaps `Free` to `Mut`, with C11 atomics and acquire/release ordering, and, still holding it, reads the buffer export count of 5.12, releasing and answering `Left` with `BufferError` if it is non-zero; `derefShare` adds one to `Shared n`, or moves `Free` to `Shared 1`, by the same compare-and-swap, so a view may be dereferenced any number of times in a scope and by any number of scopes at once; `copyPayload` adds one for the duration of the copy and subtracts it.
Every other combination answers `Left` with `RuntimeError("busy")`: `derefMut` against any hold and `derefShare` against `Mut`, which is what PyO3's `try_borrow_mut` and `try_borrow` answer, and it never waits, since a wait while attached would deadlock under the GIL against the detached kernel it waits for, which is why PyO3 does not wait either.
A nested trampoline call, `__repr__` calling a property getter through Python, say, is just another scope: it reads alongside its parent and is refused a write, as in PyO3.
The scope's arena records each hold it took, in the same C call as the compare-and-swap so that an asynchronous exception cannot separate the two, and the sweep undoes exactly those: it subtracts what the scope added to `Shared n`, and moves its `Mut` back to `Free`, or to `Poisoned` on an exceptional exit.
The hold ends when the arena that took it is swept, at the end of the call or of the `attach'` that scoped it, exactly as PyO3's guard ends with its Rust scope; the sweep is the release point that an earlier draft invented a callback to provide, and `attach'` is the tool for a hold shorter than the call.
The one consequence to document is that a hold outlives the borrow it was taken for: after `derefMut` inside `reborrowing`, the restored handle names an object that is still `Mut` until the sweep, so a second dereference of it in the same scope answers `busy`.
No scope identity is stored and no nesting rule exists.
An earlier draft had a single-holder shared state, `Shared h`, which needed both and made every long or detached read-only method exclude every other reader for its whole duration; the count is what the detached showcase needs, and it is the one integer the design keeps on the Haskell side of the boundary.
The other counter belongs to Python: a class with a `Buffer` slot (5.12) counts its live buffer views as `bytearray` does, and a dereference while views exist answers `Left` with `BufferError`.
`tp_dealloc` cannot run while the word is held, because every `Bound π a` and `Borrowed π a` derives from a +1 that is held for `π`: an argument lent by the caller's frame, or an arena slot.
Nothing else touches the word: `share`, `sharing`, `reborrowing`, `subShare` and the trampoline's lend of a `Bound` are static, and they do not touch the Python refcount either, since the arena owns every +1.

**Related work.**
The lend state is a one-object case of dynamic ownership for Python as studied by Stoldt, Bucher, Clebsch, Johnson, Parkinson, van Rossum, Snow and Wrigstad, *Dynamic Region Ownership for Concurrency Safety* (PLDI 2025), which gives groups of Python objects, regions, an ownership discipline enforced at runtime, so that what would have been a data race becomes a deterministic failure the programmer can be told about.
The shape is the same, ownership enforced at runtime at a boundary the types cannot see, refusal rather than a race, and immutability as the way to share, which is what `frozen` classes are; the scale is not, since H2Py guards one Haskell payload behind one Python object and leaves the Python heap unrestricted, and what it records is a lend that returns to Python at the sweep rather than a transfer between owners.
Were Python itself to carry dynamic regions, the lend state would be the region's ownership and could be subsumed by it; the comparison rests on the paper's abstract and is to be checked against its text before the tutorial repeats it.

**Exceptional exit.**
Python errors are values (5.5), so no Python error ever unwinds through a method, and no borrow, hold or in-place update is ever left half-done by one.
What can unwind is a Haskell exception: `error` and the pure exceptions such as `ArithException`, an asynchronous exception (`ThreadKilled`, `timeout`), and an `IO` exception from a lifted action or a detached body.
Any of these may have interrupted a multi-step in-place update, so at an exceptional sweep every object the arena holds as `Mut` is poisoned: its word moves to `Poisoned`, every later dereference answers `Left` with `RuntimeError("object poisoned by an interrupted update")`, and `tp_dealloc` leaks the payload instead of consuming it; the scope's shared holds are only subtracted, since nothing wrote through them.
That is the whole rule.
It is more conservative than PyO3, whose `RefCell` does not poison, and it is required here because a torn growable-vector header followed by an unchecked write is a memory-safety failure, not a logic error; it is also rarely reached, because the ordinary failure of a method is a `Left`, not an exception.
A Haskell exception escaping a nested trampoline call is converted to a Python exception there and arrives in the outer scope as a `Left`; the inner arena has already poisoned its own holds.
The sweep runs under `mask`, so an asynchronous exception cannot separate the release of the holds from the release of the references.

`frozen` classes (`pyclass ''T` with `frozen`) have an instance set of their own: `PyFrozenClass a` requires `Movable a`, `newObject` `move`s the payload into GC ownership, methods receive it by value, no word is kept, `tp_dealloc` frees only the `StablePtr`, and any number of threads may read it at once; the `Consumable` obligation of `PyClass` does not apply, by the multiplicity conventions of `AGENTS.md`.

### 5.4 Functions, methods, modules and the trampoline

User code, in the receiver form that `pymethods` accepts directly:

```haskell
new   :: Int -> Py π π (PyResult (Bound π Counter))       -- newObject may fail to allocate
incr  :: Mut π Counter %1 -> Int -> Py π π ()             -- &mut self: the wrapper dereferences the handle
get   :: Share π Counter -> Py π π Int                     -- &self
label :: Share π Counter -> Py π π (PyResult (Bound π PyStr))   -- a Python object built while the payload is borrowed, returned from the method
sort  :: Mut π Big %1 -> BIO π ()                          -- a long kernel: run under detach, the interpreter released
stats :: Share π Big -> BO π Double                        -- pure but long: registered detached below
add   :: Int -> Int -> Py π π Int

pyclass ''Counter
pyclass ''Big
pymethods ''Counter [constructor 'new, method "incr" 'incr, method "get" 'get, method "label" 'label]
pymethods ''Big [method "sort" 'sort, method "stats" 'stats & detached]
pymodule "counter" [fn "add" 'add] [''Counter, ''Big]
```

A method whose receiver is `Mut π a %1 ->` or `Share π a ->` is called on the dereferenced payload: `method "incr" 'incr` generates `derefMut self` followed by a `case` that returns the `Left` or runs `incr m k`, where `self` is the `Bound π a` the trampoline lent for the call, and a `Share` receiver is `derefShare` on the `share`d handle.
Every user-written function and method, receiver form or not, is written at `Py π π`, one lifetime for both axes.
The trampoline instantiates both axes at the same fresh lifetime, so at a call boundary `Py π π` is always available and every operation's `π >= γ` is `Reflect`; the second review compiled the alternatives and found them wanting, since a receiver at a separate `α` cannot use a Python operand without `(π >= α) =>`, and that given does not compose through a narrowed handle, because transitivity of the outlives relation is not derived (C4).
The price is that a receiver-form method is called only at the call's ambient, never on a borrow narrowed by `reborrowing`; a method that wants that writes `(π >= α) => Mut α a %1 -> … -> Py π α r` itself, which composes on a meet but not through a given.
The body is `Py π π` and may call Python while the payload is borrowed, as `&mut self` may in PyO3, and a Python object it builds is `Bound π _` and returns from the method, which is the reason the two axes are separate.
A `BO π` body is accepted and lifted; a `BIO π` body runs under `detach`, with the borrow shortened to the window; and the `detached` adjustor runs a `BO π` body the same way, which is the right registration for any body that is long, since holding or releasing the interpreter is a property of the method's cost rather than of its world, and a pure `parBO` kernel is exactly what should run released.
The receiver form removes `Bound`, the dereference, the outlives constraint and the `consume` of the receiver from user code, and it matches `&mut self`/`&self`.
A method that needs the object itself, for example to return it, to pass it to Python, or to borrow two objects, takes an explicit receiver, `Bound π a %1 ->` if it will mutate and `Borrowed π a ->` if it will only read, and dereferences it itself, inside `reborrowing` when it must keep the handle.

Registration is value-level.
Every registration combinator also records an entry in a `ModuleDesc` value, which is what 5.11 renders into type stubs; `param`, `hint` and `doc` annotate an entry.
`fn`, `method` and `constructor` build a `PyFunction` from a Haskell function through a `PyCallable` class over its type: each argument is converted by `FromArg π`, the result by `ToResult π`.
`FromArg π a` has instances `(FromPy a) => FromArg π a`, `FromArg π (Bound π t)` (the lent handle, with a type check), and `FromArg π (Borrowed π t)` (the handle `share`d); `ToResult π a` has `(ToPy a) => ToResult π a`, `(π' >= π) => ToResult π (Bound π' t)` and `(π' >= π) => ToResult π (Borrowed π' t)`, both by incref, and `(ToResult π a) => ToResult π (PyResult a)`, which raises the `Left` (5.5), so a body may be typed `Py π α r` or `Py π α (PyResult r)` as a PyO3 method returns `T` or `PyResult<T>`.
Both classes are indexed by the call's attachment, which is what the review showed a single-parameter `ToPy (Borrowed π t)` instance cannot express: such an instance must work at every current attachment, including one where `π` has ended, so a reference stashed in a payload could be incref'd after its object died.
`FromPy` and `ToPy` themselves stay single-parameter classes over value types (5.6).

Function pointers come from `foreign import ccall "wrapper"` adjustors created at module initialisation and never freed; a call through an adjustor enters the RTS on a bound thread exactly as a `foreign export` does.
`PyMethodDef` tables are `malloc`ed and never freed.
Registering a method is a Template Haskell splice: `pymethods` and `pymodule` generate, for each name, the wrapper that instantiates the method's `π` inside `runPyCall`'s rank-2 body, because a value-level `method` would have to take a function polymorphic in `π` as an argument, which needs impredicative types or one newtype per arity; the tables the splices build and the adjustors they point at are ordinary values, and `pyclass ''T` uses TH for the `PyClass` instance and the closedness check.
The only `foreign export` is the module initialiser `h2py_hs_init_<name>`, generated by `pymodule`.

The C the user writes:

```c
#define H2PY_MODULE counter
#include <h2py/init.h>
```

The header expands to a multi-phase `PyInit_counter` for `abi3`, returning a `PyModuleDef` whose `Py_mod_exec` slot initialises the RTS on first use and calls `h2py_hs_init_counter`, with `Py_mod_multiple_interpreters` set to not supported; and, when compiled for `abi3t` with `Py_TARGET_ABI3T`, a `PyModExport_counter` (PEP 793, final for 3.15), whose slot array has no `PyModuleDef` behind it and therefore carries the name, doc, methods and state through `Py_mod_name`, `Py_mod_doc`, `Py_mod_methods`, `Py_mod_state_size` and the traverse, clear and free slots, plus `Py_mod_gil`; both hooks may coexist, and 3.15 prefers the new one.
`Py_mod_gil` must not appear in the `abi3` slot array: 3.12 rejects unknown slot ids at import.
Single-phase init cannot declare either slot, which is why the first draft's "`PyInit_` creates the module" was wrong.
`PyInit_` must be C because it runs before `hs_init`; everything after it is Haskell.

The trampoline is the only runner of `Py` besides `attach`, and it lives in `H2Py.Runtime.Internal`:

```haskell
runPyCall :: (forall π. Py π π (PyResult (Bound π PyAny))) -> IO (Ptr PyObject)
```

Under `mask` it drains the pool, pushes an arena, restores the mask and runs the body on the calling thread, which is bound because every entry from foreign code is.
On success it takes the result's +1 out of the arena, sweeps, pops, and returns the pointer.
A `Left` result sets its `PyErr` as the raised exception, through `PyErr_SetRaisedException` for a materialised one and `PyErr_SetString` for a lazy one, sweeps, pops, and returns `NULL`.
A Haskell exception becomes a Python exception through `ToPyErr`, `RuntimeError` with its `displayException` text by default, poisons the arena's mutable holds (5.3), sweeps, pops, and returns `NULL`; it must never propagate out of the RTS entry point, because the RTS would terminate the process.

### 5.5 Errors

```haskell
-- H2Py.Exception
data PyErr                                            -- unrestricted: a materialised exception object held through a PyHandle, or a lazy class-and-message pair
type PyResult a = Either PyErr a
class PyExceptionClass e                              -- the built-in exception tags, and every class made by newException (5.12)
pyErr        :: (PyExceptionClass e) => Proxy e -> Text -> PyErr             -- lazy; needs no attachment
fromObject   :: (π >= γ) => Borrowed π PyBaseException -> Py π' γ PyErr     -- incref into a handle
toObject     :: PyErr -> Py π γ (Bound π PyBaseException)                    -- materialise and normalise
pyFail       :: PyErr -> Py π γ (PyResult a)                                 -- pure . Left; it raises nothing
orFail       :: (Consumable s) => s %1 -> PyResult a %1 -> Either PyErr (s, a)  -- consume the scope's linear values on Left, thread them on Right
orThrow      :: PyResult a %1 -> Py π γ a                                    -- an abort, not PyO3's ?: throws the PyErr as a Haskell exception; see below
throwPy      :: PyErr -> Py π γ a                                            -- orThrow . Left
checkSignals :: Py π γ (PyResult ())                                         -- PyErr_CheckSignals; handlers run on Python's main thread only
class (Exception e) => ToPyErr e where toPyErr :: e -> PyErr                 -- Haskell exceptions crossing the boundary
```

Python errors are values, as they are in PyO3, whose `PyResult<T>` this is.
Every operation that CPython reports as fallible, by a `NULL` or `-1` return, returns `PyResult`: the protocol operations of 5.2, `newObject` and `toPy` for allocation, `fromPy` for conversion, the dereferences of 5.3 for `busy`, a live buffer export and a poisoned object, `requestBufferMut` of 5.7, and `checkSignals`.
The shim fetches the raised exception into a `PyErr` at the call, and the operation returns `Left`; nothing unwinds.
An operation that cannot fail keeps a plain result, and `downcast` answers `Maybe`, since a failed type check is not an error.

This is the decision that makes the exception story short.
A Python error never interrupts a method, so no borrow, no hold and no in-place update is ever left half-done by one, and `KeyboardInterrupt`, which arrives as a `Left` from `checkSignals` or from any Python call, can never poison an object.
The first draft threw Python errors as a Haskell exception, with a `catchPy` on unrestricted arrows and a `tryPy` on a linear one; the linear one is exactly the arrow that linear-base's `System.IO.Linear` documents as unsound, and the unrestricted one had nothing left to catch once errors were values, so both are gone.
What remains of throwing is `orThrow`, and it is an abort rather than a shorthand: it turns a `PyErr` into a Haskell exception that nothing below the trampoline can catch, so it abandons every linear value in scope, which the semantics permit, and the sweep then poisons what the scope holds mutably, as for any Haskell exception (5.3).
It is not PyO3's `?`, which is a value-level early return that the caller receives; a method whose object must stay usable after an error propagates `Left` as a value, and `orThrow` is for the case where abandoning the call is what is meant.

Propagation is an inline `case`.
There is no `ExceptT` over a linear monad, because a short-circuiting bind would have to consume, without applying it, the linear continuation it skips; so a method that must stop on `Left` writes the `case`, and in the `Left` branch consumes the linear values in scope, which the type checker enforces and which is the discipline `pure-borrow` imposes everywhere.
A method that only propagates writes nothing special: the trampoline accepts a body typed `Py π π r` or `Py π π (PyResult r)` through the `ToResult` instance of 5.4, and a `Left` becomes the raised exception.
The cost is nesting: the second review measured two to four `case` levels in a small method, and linear-base 0.7 gives `Either e` no `Control.Functor` or `Applicative` instance, so results cannot be combined applicatively either.
`orFail` reduces every `Left` branch to `Control.pure (Left e)` by consuming the scope's linear values on the caller's behalf, tuples of borrows being `Consumable` already.
`borrowM` at the ambient is never usable in a method, in either branch, since its `Lend` is reclaimed only after the ambient ends, so a method borrows through `reborrowing`, `sharing` or `srunBO`, which restore.
`orThrow` is the abort of the previous paragraph, and in a `Mut`-receiver method it is a poor substitute for `?`, since it poisons the object; `orFail` is the tool there.
For the same reason no fallible operation takes a continuation: a scope whose resource might not be granted would be unable to consume the linear body it cannot run, so acquisition is a separate fallible step and every scope is infallible, which is the shape of 5.7.

Haskell exceptions are the exceptional path.
`error` and the pure exceptions, asynchronous exceptions, and `IO` exceptions from a lifted action or a detached body unwind to the trampoline, which converts them with `ToPyErr`, `RuntimeError` with the `displayException` text by default and the standard mappings for `ArithException`, `ArrayException`, `IOException` and `ErrorCall`, sweeps, and poisons what the arena holds mutably (5.3).
A lifted `IO` action that wants to handle its own failure does so inside, with linear-base's `catch` on an unrestricted body, and returns a value.

`PyErr` is unrestricted, so it may be stored, compared and returned freely.
A materialised one holds its object through a `PyHandle`, released by the finaliser through the pool; a lazy one is materialised by `toObject`, or by the trampoline with `PyErr_SetString`, so that constructing an error costs nothing on the path that does not raise it.

### 5.6 Conversions

```haskell
class PyTypeHint a where pyTypeHint :: Proxy a -> TypeHint          -- the stub hint, see 5.11
class PyTypeHint a => FromPy a where fromPy :: (π >= γ) => Borrowed π PyAny -> Py π' γ (PyResult a)
class (PyTypeHint a, Consumable a) => ToPy a where toPy :: (π >= γ) => a %1 -> Py π γ (PyResult (Bound π PyAny))
-- The constraint is what lets an instance body use the reference operations, which all carry it: without it the
-- second review could write no FromPy or ToPy instance against the public signatures. ToPy's Consumable superclass
-- is what a Left in the middle of a composite conversion needs, to consume the components not yet converted.

-- Copying a value back out of a reference whose tag fixes its Haskell type; cannot fail.
type family HsOf (t :: Type) :: Type     -- PyLong ↦ Integer, PyFloat ↦ Double, PyBool ↦ Bool, PyStr ↦ Text, PyBytes ↦ ByteString, PyNone ↦ ()
class PyValue t
copyOut :: (PyValue t, π >= γ) => Borrowed π t -> Py π' γ (Ur (HsOf t))
```

Both classes are over *value* types; reference-typed arguments and results are the trampoline's business (5.4).
`copyOut` is the analogue of `copyMut`: it materialises the Haskell value eagerly, while the reference is valid and the thread attached, and returns it in `Ur` because a result bound in a linear monad is otherwise linear, which is why `Unrestricted.copyAt` returns `Ur a` too.
It is monadic for the reason `Copyable`'s own law exists, that a copy must complete while the borrow is live, plus the reason every reference operation is: reading the value is an interpreter call, and a pure version would be a thunk forced on an unknown thread at an unknown time, which is the per-operation attachment 5.1 rejected.
`fromPy` is the same operation for narrowing or structural conversions, `Int` from an `int` that may overflow, `[a]` from an iterable, `Map k v` from a mapping, with a `TypeError` or `OverflowError` path.
`fromPy` answers `Left` with a `TypeError` on mismatch, with PyO3-style messages.
`toPy` is linear because moving a linearly owned Haskell value into Python is a consumption: a `Data.Vector.Storable`-backed `Unrestricted.Vector` becomes a NumPy-compatible array without a copy.
The linearity costs callers nothing, since an unrestricted value may be passed to a linear function; it burdens instance authors, so a `Generic`-derived default for `Movable` types is provided.
Instances cover `Int`, `Integer`, `Word`, `Double`, `Float`, `Bool`, `Char`, `Text`, `String`, `ByteString`, `()`, `Maybe`, `Either`, tuples up to 5, lists, `Vector`, `Map`, `Set`, `Ur a` via `a`, and `PyHandle t`.
`Generic`-derived instances for records map to dictionaries and to `NamedTuple`-like classes; they are a later phase.

### 5.7 Buffers and the parallel showcase

```haskell
-- H2Py.Buffer
type SVector e = Data.Vector.Generic.Mutable.Linear.Borrow.Unrestricted.Vector Data.Vector.Storable.Vector e

data BufferMut   π e     -- a writable view, holding the handle it was requested from; linear, affine
data BufferShare π e     -- a read-only view; unrestricted
type role BufferMut   nominal nominal   -- without these, coerce and the safe upcast retag the view's lifetime and element type (Appendix C)
type role BufferShare nominal nominal

-- Acquisition is the fallible step and takes no continuation (5.5); the scopes over an acquired view cannot fail.
requestBufferMut   :: forall e π π' γ. (Storable e, BufferFormat e, π >= γ) => Bound π PyAny %1 -> Py π' γ (PyResult (BufferMut π e))
requestBufferShare :: forall e π π' γ. (Storable e, BufferFormat e, π >= γ) => Borrowed π PyAny -> Py π' γ (PyResult (BufferShare π e))
withBufferMut   :: forall e π π' γ r. (π >= γ) => BufferMut   π e %1 -> (forall α. Mut   (α /\ γ) (SVector e) %1 -> BIO (α /\ γ) r) %1 -> Py π' γ (r, BufferMut π e)
withBufferShare :: forall e π π' γ r. (π >= γ) => BufferShare π e    -> (forall α. Share (α /\ γ) (SVector e)    -> BIO (α /\ γ) r) %1 -> Py π' γ r
releaseBuffer   :: BufferMut π e %1 -> Py π' γ (Bound π PyAny)     -- early release; otherwise the sweep releases
newArray        :: forall e π γ. (Storable e, BufferFormat e) => SVector e %1 -> Py π γ (PyResult (Bound π PyAny))
```

A writable view is a mutation of the object by protocol (`PyBUF_WRITABLE`), so `requestBufferMut` takes the handle, which the view keeps until it is released; a read-only view takes a `Borrowed`.
Acquisition is the fallible step, by the rule of 5.5 that a fallible operation takes no continuation, and the scopes over an acquired view cannot fail.

`requestBufferMut` requests a writable, C-contiguous buffer with format information, checks the element format against `BufferFormat e` (native byte order only, both `l` and `q` accepted for 64-bit integers) and the data pointer's alignment, registers the address range in the **borrow registry**, and records the view in the arena; a non-contiguous or read-only array, a format mismatch, or a range the registry already holds exclusively answers `Left` with `BufferError`, releasing the view first.
`withBufferMut` wraps the pointer as a `Data.Vector.Storable.Mutable.MVector` through `unsafeFromForeignPtr` with a no-op finaliser, lifts it into the generic unrestricted owner with `unsafeFromMutable`, borrows it, runs the body through `detach`, and hands the view back, so a second kernel can run on it without a second request.
The view is released, with `PyBuffer_Release` and its registry entry, by `releaseBuffer` or else by the sweep of the arena that holds it, both attached, so no release ever runs on the detached path.
A multi-dimensional array is presented flattened; `ndarray.resize` refuses while the view is held unless the caller passes `refcheck=False`, which is the same contract every C extension has.

The registry is not a later phase.
Two Python threads calling `sortInPlace(arr)` on the same array would otherwise each obtain a `Mut` over the same memory, since both bodies run detached; that is precisely the invariant the library sells, and rust-numpy solves it the same way, with a global table keyed by data-pointer range holding shared and exclusive counts under a mutex.
The honest residual, shared with rust-numpy: the buffer protocol does not lock the array, so Python code, or a view H2Py did not create, can still write to it while we hold the view.
The disjointness Pure Borrow proves is among Haskell borrows, and that is stated in the Haddock.

The body is `BIO`, not `Py`, and it runs detached.
Exclusive access to a buffer is granted only to a computation that cannot call back into Python, which removes the one way a method could itself invalidate its own view, and it is what makes the body free to run on every core.

`qsortDC` and `fftDC` are generic in the `vector` backend, so they apply to an `SVector` over a NumPy buffer unchanged:

```haskell
sortInPlace :: Bound π PyAny %1 -> Py π π (PyResult ())     -- at the call's lifetime, as every user function is (5.4)
sortInPlace array = Control.do
  r <- requestBufferMut @Double array
  case r of
    Left e -> Control.pure (Left e)
    Right buf -> Control.do
      ((), buf) <- withBufferMut buf \vec -> Control.do
        Ur gen <- liftSystemIOU newStdGen
        Ur workers <- liftSystemIOU getNumCapabilities
        vec <- qsortDC gen workers 4096 vec              -- the body is BIO, which is Forkable: no lift
        Control.pure (consume vec)
      Control.pure (Right (consume buf))      -- the view is affine: dropping it releases nothing, the sweep does
```

Whether `qsortDC` at `Storable.Vector Double` runs dictionary-free after a `SPECIALIZE` pragma in the user's module is not established: `pure-borrow-inspection` asserts it today for `qsort` at `Unboxed.Vector Int` only, so Phase 4 adds that inspection before the README claims it; and the kernel's inputs are validated before the scheduler runs, so that a bad input answers `Left` where a branch exception, once it propagates (4.4), would poison the object.

`newArray` hands a Haskell-owned pinned buffer to Python without a copy through a small exporter type `HsBuffer`, a heap type whose type data holds a `StablePtr` to the `ForeignPtr` and the length, implementing `Py_bf_getbuffer`/`Py_bf_releasebuffer`, whose `tp_dealloc` frees the `StablePtr` with `hs_free_stable_ptr`, which is callable from a thread that never entered Haskell; `PyMemoryView_FromObject` on it gives a view that `numpy.asarray` wraps without copying.
The first draft's capsule owner cannot work: a memoryview created from a raw buffer has no exporter, so nothing keeps the Haskell memory alive.
NumPy's own C API is never linked; the buffer protocol suffices in both directions.

### 5.8 Concurrency and free-threading

- Under the GIL, `Py` computations from different Python threads are serialised by the interpreter; Haskell threads spawned by `parBO` or the scheduler run in parallel with each other and with Python once the calling thread has detached.
- Under free-threading (`abi3t`, 3.15 and later), `Py` computations from different Python threads run concurrently inside the RTS.
  Payload access is guarded by the object's lend state, one compare-and-swap: a second thread's `derefMut` while any scope holds the object, or its `derefShare` while a scope holds it mutably, gets `RuntimeError("busy")`.
  Readers from any number of threads proceed together, as in PyO3, and `frozen` classes carry no lend state at all.
  Module-level Haskell state must be thread-safe; the library provides none.
- A dereferenced payload may be split and its halves run through `liftBO (parBO …)` attached, or through `detach (parBO …)` and the scheduler with the interpreter released, which is the form for anything long; a branch that needs Python is `parPy`.
  `parBO` directly in `Py` is a type error that names those three (5.1).
- Refcount operations go through `Py_IncRef`/`Py_DecRef`, which are atomic under free-threading and are the only form the stable ABI allows.
- The `abi3t` build declares `Py_MOD_GIL_NOT_USED` once the Phase 5 audit has passed; the `abi3` build cannot and need not.
- Subinterpreters are declared unsupported (`Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED`); the RTS is process-global.

### 5.9 Embedding the RTS

- `hs_init_ghc` with `RtsOptsAll`, `--install-signal-handlers=no` so that `SIGINT` stays Python's, and additional options from `H2PY_RTS_OPTS`; `-N` is the recommended default for the demo module.
  The threaded RTS's ticker is a pthread, not a signal, so the user-guide caveat about `SIGVTALRM` does not apply.
- `-threaded` is mandatory: several Python threads may enter at once, and every CPython call that may run Python code is `safe` (5.2).
- `hs_init` has no main-thread requirement in the threaded RTS, and entries may come from any OS thread once it has completed.
- `hs_exit` is never called; the RTS cannot be restarted, Python never unloads extension modules, and process exit reclaims everything.
  Because `hs_exit` never runs, `flushStdHandles` never runs either: a module that writes to `stdout` or `stderr` sets them to line buffering at init or flushes from a Python `atexit` handler, and no Haskell finaliser runs at process exit.
- The process is multithreaded from the moment the module is imported, so CPython 3.12 and later warn on every `os.fork()`, and `multiprocessing`'s Linux default would fork a live RTS.
  Module init registers an after-fork child hook through `os.register_at_fork` that makes every trampoline raise `RuntimeError` naming the `spawn` start method, instead of deadlocking on a capability owned by a thread that no longer exists.
- One Haskell-built extension module per process in 0.1.
  Each wheel bundles its own copy of the runtime, and two copies in one process do not stay apart: `auditwheel` renames files, not symbols, so under `RTLD_GLOBAL` a second wheel's libraries bind to the first wheel's runtime, and on macOS GHC's libraries bind runtime symbols through the flat namespace anyway, so importing a second H2Py wheel aborts the interpreter.
  The roadmap item is a shared `libh2py-rts` that all modules link against.

### 5.10 Build and distribution

- Targets: `abi3` at `Py_LIMITED_API = 0x030C0000` (CPython 3.12 and later) and `abi3t` (3.15 and later, PEP 803: built with `Py_TARGET_ABI3T = 0x030F0000`, which also defines `Py_GIL_DISABLED`, wheel tag `abi3.abi3t`, suffix `.abi3t.so`).
  Everything the shim uses is in the limited API at those versions: `PyType_FromSpec` and `PyType_FromModuleAndSpec`, `PyObject_GetTypeData`, `PyObject_Type`, `METH_FASTCALL | METH_KEYWORDS`, `PyObject_Vectorcall`, `Py_buffer` with `PyObject_GetBuffer`/`PyBuffer_Release` and the `Py_bf_*` slots, `PyMemoryView_FromObject`, `PyErr_GetRaisedException`/`PyErr_SetRaisedException`, `PyErr_SetString`, `PyErr_CheckSignals`, `Py_IncRef`/`Py_DecRef`, `PyGILState_Ensure`/`PyGILState_Release`/`PyGILState_GetThisThreadState`, `PyEval_SaveThread`/`PyEval_RestoreThread`, `PyCapsule_*`, `Py_mod_multiple_interpreters`, and `Py_IsFinalizing` from 3.13; `PyGILState_Check` is not, which is why the attachment check is a shim thread-local (5.1), and `Py_TYPE` is an inline read of a struct `abi3t` makes opaque, which is why the type is fetched through `PyObject_Type`; `Py_mod_gil` and `PyModExport_` only in the `abi3t` build.
- A Cabal `foreign-library` stanza with `type: native-shared`, `c-sources: cbits/init.c`, and on macOS `ld-options: -undefined dynamic_lookup`, because an extension module resolves interpreter symbols at load time rather than linking `libpython`.
  The include directory is taken from `sysconfig` of the target interpreter rather than from `pkgconfig-depends: python3`, which `uv`, `pyenv` and plain venvs do not provide.
- Packaging: an existing tool first.
  The candidate is a thin `hatchling` or `setuptools` build hook that runs `cabal build` for the stanza, renames the artifact to `<module>.abi3.so` (or `<module>.abi3t.so`), and hands the wheel to `auditwheel repair` or `delocate-wheel` to bundle the Haskell runtime libraries with their `@rpath`s rewritten.
  Only if those hooks cannot express the pipeline is a Shake-based tool written; Phase 1 decides.
  The hook also imports the built module once to write its type stub and `py.typed` into the package (5.11).
- `-staticlib`, producing a single self-contained extension, is evaluated in Phase 1 against the dynamic route on wheel size, PIC availability of the Haskell libraries on x86_64 Linux (not established), and the `libgmp` LGPL notice a bundled wheel must carry.

### 5.11 Type stubs

Stub generation is built in, and it is a rendering of the same description the initialiser uses.
`fn`, `method`, `constructor`, `pyclass` and `pymodule` build a `ModuleDesc` value: the module name and docstring, every function with its parameter hints, return hint, parameter names and docstring, every class with its constructor, methods and docstring, and every registered exception class.
`renderStubs :: ModuleDesc -> Text` prints a `.pyi` from it, and `checkStubs :: ModuleDesc -> FilePath -> IO Bool` compares against a committed file, so a `cabal test` can assert the stub is current without an interpreter.

Hints come from a class that is a superclass of both conversion classes, so every convertible type has one and a stub can never be partial:

```haskell
class PyTypeHint a where
  pyTypeHint :: Proxy a -> TypeHint

data TypeHint
  = TName Text                 -- int, str, Counter, numpy.typing.NDArray[numpy.float64]
  | TApply Text [TypeHint]     -- list[int], dict[str, float]
  | TUnion [TypeHint]          -- int | str
  | TOptional TypeHint         -- T | None
  | TTuple [TypeHint]
  | TNone
  | TAny
```

Instances: `Int`, `Integer`, `Word` to `int`; `Double`, `Float` to `float`; `Bool` to `bool`; `Text`, `String`, `Char` to `str`; `ByteString` to `bytes`; `()` to `None`; `Maybe a` to `a | None`; `Either a b` to `a | b`; `[a]` and `Vector a` to `list[a]`; `Map k v` to `dict[k, v]`; `Set a` to `set[a]`; tuples to `tuple[...]`; `Ur a` and `PyHandle t` to the hint of `a` or `t`; `Borrowed π t` and `Bound π t` to the hint of the tag, so `PyLong` is `int`, `PyAny` is `Any`, and a user class is its Python name.
A newtype `AsAny` gives `Any` for a type its author does not want to describe, and a `hint` override on a registration replaces the derived hint with a literal, which is how a buffer argument typed `Borrowed π PyAny` is published as `numpy.typing.NDArray[numpy.float64]`.

Parameter names are not recoverable from a Haskell function's type, so `param i "name"` supplies them; unnamed parameters are rendered positional-only (`def add(x: int, y: int, /) -> int: ...`), which is valid and honest.
Receiver-form and explicit-receiver methods render `self`; a constructor renders `__init__` returning `None`.
Docstrings come from `doc "..."` on a registration and from `pyClassDoc`.

```haskell
pymodule "counter"
  [ fn "add" 'add & param 0 "x" & param 1 "y" & doc "Add two integers." ]
  [ ''Counter ]
```

```python
# counter.pyi, generated
from typing import Any

def add(x: int, y: int) -> int:
    """Add two integers."""

class Counter:
    """A counter whose state lives in the Haskell heap."""
    def __init__(self, n: int) -> None: ...
    def incr(self, k: int, /) -> None: ...
    def get(self) -> int: ...
```

Emission: the module exposes a hidden `__h2py_stub__()` returning the rendered text; the build hook (5.10) imports the built module once, writes `<module>.pyi` and `py.typed` into the package, and the wheel ships them.
`h2py stubs <module>` does the same from the command line, and `checkStubs` guards CI.
This is the division `pyo3-stub-gen` uses, minus its separate binary, because here the description is already a value at runtime.

### 5.12 Protocols and subtyping

Three different things go by these names, and they get three different mechanisms: implementing Python protocols on a Haskell class, the subtype relation between Python types as seen from Haskell, and inheritance in either direction.

**Implementing Python protocols on a Haskell class.**
CPython protocols are type slots (`Py_tp_repr`, `Py_tp_hash`, `Py_tp_richcompare`, `Py_tp_call`, `Py_tp_iter`, `Py_tp_iternext`, `Py_sq_length`, `Py_sq_contains`, `Py_mp_subscript`, `Py_mp_ass_subscript`, the `Py_nb_*` number slots, `Py_bf_getbuffer`), all available through `PyType_Slot` in the limited API.
Rather than magic method names checked by a macro, H2Py exposes them as a GADT whose constructors fix the Haskell signature of each slot, so the type checker does what PyO3's proc macro does:

```haskell
data Slot a where                                                                           -- every receiver at the call's lifetime, as in 5.4
  Repr     :: (forall π. Share π a -> Py π π Text) -> Slot a
  Str      :: (forall π. Share π a -> Py π π Text) -> Slot a
  Hash     :: (forall π. Share π a -> Py π π Int) -> Slot a
  Compare  :: (forall π. Share π a -> Borrowed π PyAny -> CompareOp -> Py π π (Maybe Bool)) -> Slot a   -- Nothing is NotImplemented
  Bool     :: (forall π. Share π a -> Py π π Bool) -> Slot a
  Len      :: (forall π. Share π a -> Py π π Int) -> Slot a
  Contains :: (FromPy k) => (forall π. Share π a -> k -> Py π π Bool) -> Slot a
  GetItem  :: (FromPy k, ToPy v) => (forall π. Share π a -> k -> Py π π v) -> Slot a
  SetItem  :: (FromPy k, FromPy v) => (forall π. Mut π a %1 -> k -> v -> Py π π ()) -> Slot a
  DelItem  :: (FromPy k) => (forall π. Mut π a %1 -> k -> Py π π ()) -> Slot a
  Iter     :: (PyClass it) => (forall π. Share π a -> Py π π (PyResult (Bound π it))) -> Slot a
  Next     :: (ToPy v) => (forall π. Mut π a %1 -> Py π π (Maybe v)) -> Slot a                -- Nothing raises StopIteration
  Call     :: (PyCallable f) => f -> Slot a                                                    -- receiver rules as for methods
  Enter    :: (forall π. Bound π a %1 -> Py π π (Bound π a)) -> Slot a                         -- explicit receiver; the default returns self
  Exit     :: (forall π. Mut π a %1 -> Maybe (Borrowed π PyBaseException) -> Py π π Bool) -> Slot a
  Number   :: NumberOps a -> Slot a                                                            -- Add, Sub, Mul, Neg, ...; each optional, each with a reflected form
  Buffer   :: (Storable e, BufferFormat e) => (forall bk α. Borrow bk α a %1 -> Borrow bk α (SVector e)) -> Slot a
```

Slots are registered next to methods: `pymethods ''Counter [method "incr" 'incr, slot (Repr showCounter), slot (Len counterLen)]`.
Each receiver follows the method rule of 5.4: a `Share`-receiver slot runs on `derefShare` of the handle and a `Mut`-receiver slot on `derefMut`, `detached` applies to a slot as to a method, conflicting holds answer `Left` as they do for methods, and a slot body, like a method body, may return `r` or `PyResult r`.
A binary slot receives its operand as `Borrowed π PyAny`; an operand of the same class is `downcast` and then `derefShare`d, which succeeds when the operand *is* the receiver of a `Share`-receiver slot, since a shared hold is reused within the scope, so `c == c` works, and raises `busy` under a `Mut` receiver, as `a += a` does in PyO3.
Each slot renders its dunder in the stub with the hint derived from its signature; `Iter` renders `Iterator[V]` from the iterator class's `Next` hint.

Rules copied from PyO3 and CPython: `Compare` without `Hash` sets `__hash__` to `None`; `Enter` returns a new reference to `self` by default; `Iter` defaults to `self` when a `Next` slot is registered; a `Number` operation that returns `Nothing` yields `NotImplemented` so that Python tries the reflected form.
Iterators are ordinary classes with a `Next` slot; the library ships a monomorphic `HsIterator` class holding an existential state and a step function, with `iterFromList :: (ToPy v) => [v] -> Py π γ (Bound π HsIterator)` and `iterFromStep :: s %1 -> (forall π' γ'. s %1 -> Py π' γ' (PyResult (Maybe (Bound π' PyAny)), s)) -> Py π γ (PyResult (Bound π HsIterator))`.
A state that is a `Bound π t` may be moved into an iterator; it is inert there by the rule of 5.2, since the step function is polymorphic in the ambient lifetime and can therefore never satisfy `π >= γ'`.
An iterator over a class instance therefore holds a `PyHandle` to it, and each `Next` does `fromHandle` and `derefShare` afresh, so the hold lasts one call and a mutation between calls is refused by the word, not by a stale borrow.

`Buffer` is the interesting one.
It exports the payload's own storage to Python through a projection on the borrow, and the export is *counted* for the lifetime of the view, with the order of the two atomics fixed so that they cannot interleave: a dereference claims the word first and reads the count under the claim, releasing and answering `Left` with `BufferError` if it is non-zero, as `bytearray` refuses to resize while exported; `bf_getbuffer` claims the word, increments the count and releases, and raises `BufferError` on the Python side if the word is held; `bf_releasebuffer` decrements with release ordering, without a claim, since it cannot fail and must not.
This count is Python's, maintained by the buffer slots and never by Haskell code, and it does not distinguish read-only from writable views: any live view excludes any dereference.
NumPy writing through the view and a Haskell `derefMut` on the same object are therefore mutually excluded, which is stronger than what rust-numpy can offer for class-owned buffers and is the class-owned counterpart of the registry in 5.7.

**Subtyping between Python types, from Haskell.**
Built-in tags form the CPython hierarchy (`PyBool` under `PyLong`, every tag under `PyAny`, the exception tags under `PyBaseException`), expressed as a closed relation `t :<: u` that `extends` declarations extend, and lifted to references through pure-borrow's own subtyping class: `instance (π >= γ, t :<: u) => Borrowed π t <: Borrowed γ u`, and likewise for `Bound`.
`upcast` is free; `downcast` is `PyObject_TypeCheck`, which is subtype-aware, so a parameter typed `Borrowed π PyLong` accepts a `bool` and any `int` subclass, and `PyLong_CheckExact` is used only for the `unsafe` leaf fast path in conversions.
`FromPy [a]` accepts any iterable except `str` and `bytes`, and `FromPy (Map k v)` any mapping, which are PyO3's rules.

The Haskell-side counterpart of a `typing.Protocol` is a class over tags: `class PySized t where len :: (π >= γ) => Borrowed π t -> Py π' γ Int`, with instances for the built-in tags that implement `__len__` and an instance generated for every user class that registers a `Len` slot, so a Haskell function can accept "anything sized" as `(PySized t) => Borrowed π t`.
`PyAny` has no such instances; the dynamic operations on it (`lenAny`, `getItemAny`, ...) answer `Left` with `TypeError` as PyO3's do.
0.1 ships the dynamic operations, which are what PyO3 has; the structural classes are 0.2.

**Inheritance.**
A Haskell class extending another Haskell class: `pyclass ''Child & extends ''Parent`.
The type is created with the parent in its `bases`, PEP 697's negative `basicsize` appends the child's type data to the parent's layout, and each level keeps its own payload, its own word and its own `PyObject_GetTypeData` lookup, so a dereference of the child's payload and one of the parent's are independent holds, exactly as `as_super` is in PyO3.
`super :: (c :<: p) => Borrowed π c -> Borrowed π p` is `upcast`, and `superMut :: (c :<: p) => Bound π c %1 -> Bound π p` is its handle form, provided separately because `Mut` is invariant in its payload; the constructor of a child takes both payloads, `newObjectWith :: p %1 -> c %1 -> Py π γ (Bound π c)`; the child's `tp_dealloc` consumes the child payload and then calls the parent's dealloc obtained through `PyType_GetSlot`.
Extending a built-in (`extendsBuiltin PyDict`) is the same mechanism and is 0.2, because variable-size bases such as `int` and `tuple` need `Py_TPFLAGS_ITEMS_AT_END` and their own tests.

Python subclassing a Haskell class: the `subclassable` option sets `Py_TPFLAGS_BASETYPE`.
The constructor allocates through the actual subtype's `tp_alloc`, CPython's `subtype_dealloc` handles the subclass's `__dict__` and weakrefs before reaching ours, ours frees through the actual type's `tp_free`, and every payload lookup already goes through `PyObject_GetTypeData` with our own type, which is defined to work on subclass instances.
A method on the base sees a subclass instance as `Borrowed π Base`, which is correct.
`tp_finalize` (`__del__` on the Python side) stays unsupported, since `PyObject_CallFinalizerFromDealloc` is not in the limited API; that is the caveat the runtime review raised, and it does not affect `subclassable` itself.
The option is off by default.

Abstract base classes and stubs: `abc "collections.abc.Sequence"` on a class calls `register` at module init and renders the ABC as a base in the stub, so `isinstance` and the type checker agree; a `typing.Protocol` needs nothing, since conformance is structural and the dunders are in the stub; an `extends` base renders as a real base.
Exception classes: `newException "CounterError" ''PyValueError` creates a Python exception type at init with the given base and a `PyExceptionClass` instance for `pyErr`, `ToPyErr` maps a Haskell exception to it, and the stub renders `class CounterError(ValueError): ...`.

On the Haskell side the two remaining subtypings are already in the library: lifetimes through `<:` and `subBorrowed`, and worlds through `liftBO` and `detach`, which are the only directions a computation may move in the safe API.

## 6. Comparison with a linear-base-only design

### 6.1 The alternative

A `Py s` monad over linear-base's `System.IO.Linear.IO` with an `ST`-style scope token `s`; linear owned references `PyObj s t` with monadic `decref`; unrestricted `Borrowed s t` for call-scoped arguments; unrestricted `PyHandle t` for storage; classes with the same runtime word accessed by checkout/checkin with a pure body, since there is no borrow to hand out (`update :: (a %1 -> (r, a)) %1 -> PyObj s (Cell a) %1 -> Py s (r, PyObj s (Cell a))`); buffers as linear handles moved into and out of a detached body; release of leaked references at the end of each `run`, in the manner of `System.IO.Resource.Linear.RIO`.
No lifetimes, no `/\`, no `After`, no `Mut`/`Share`.

### 6.2 What each design can express

| Concern | Pure Borrow based | linear-base only |
|---------|-------------------|------------------|
| Attachment scoping | `Py π γ` with attachment and borrow lifetimes on separate axes, each with `/\` sub-lifetimes; nested `attach'`/`detach`/`sharing` scopes relate to each other | `Py s` with an ST-style token; a nested scope needs a fresh `s'`, and nothing from `s` is usable inside it |
| Call-scoped borrowed arguments | `Borrowed π t`, zero refcount traffic | the same: an ST-style `s` prevents escape of unrestricted values as it does for `STRef s` |
| A scoped view of a unique reference | `sharing`: the view lives in `β /\ π` and the body still sees every resource of `γ`; the handle comes back | possible only with a fresh `s'`, so the body sees nothing from the enclosing scope; otherwise the view can outlive the owner's `decref` |
| Leak-freedom on exception paths | per-attachment arenas, nested through `attach'`, sole owners of every +1 | a `RIO`-style release of everything at the end of `run`; `run`s nest with a fresh `s'` as `attach'` nests arenas, but nothing relates `s'` to `s`, so an outer resource is unusable inside |
| A detached body using enclosing resources | uses any borrow that outlives it directly | must move every needed linear value in and back out; nothing borrowed from the caller is usable |
| Temporary read-only sharing of a payload | `derefShare`, `sharing` on the dereferenced borrow, `subShare` on views | `Ur` copy or a `Dupable` deep copy |
| In-place disjoint parallelism over a payload or a NumPy buffer | `splitAt` then `parBO` or the scheduler, statically disjoint, and the halves are borrows of one buffer that the scope restores | expressible on the design's own owned vector with `Unsafe.toLinear` over `MVector.splitAt`, as this library does internally, but each half is then an owner the body must hand back by value, with no restoration at scope end and no view of the halves as borrows of one buffer; linear-base's own `slice`s do not help (`Data.Array.Mutable.Linear.slice` copies, `Data.Vector.Mutable.Linear.slice` consumes and is O(1) only at offset 0, `Data.Array.Destination.split` is write-only) |
| Nested mutable payloads | element-owning `Vector` and `Ref` compose | linear-base containers hold unrestricted elements only |
| Beginner surface | receiver-form methods, `PyHandle`, `FromPy`/`ToPy`: one lifetime variable, `π`, in every signature | the same surface, with one token variable `s` |
| Type errors | mention `/\` and outlives constraints when scopes are misused | simpler messages |
| Dependencies | `pure-borrow` and its closure | `linear-base` only |
| Implementation effort | the substrate (RTS, shim, trampolines, registration, conversions, exceptions, packaging) is identical; the access layer is about 15% of the code | about 85% of the same work |

### 6.3 Verdict

The linear-base-only design is the subset of the Pure Borrow design obtained by removing the borrow-returning combinators and the `/\` algebra.
It keeps everything a Python developer needs on day one, and it loses exactly the capabilities that distinguish a Haskell extension from a C or Rust one for numerical work: statically disjoint, in-place, multi-core kernels over buffers Python owns, with the interpreter detached, and scoped views that can still see their caller.
It also forfeits the argument of the paper, that borrowing rather than mere linearity is what makes nested and shared mutable state tractable.

That last sentence is a goal of this maintainer, and it is stated as one so that the reader can weigh it: on engineering grounds alone the two designs are close for scalar-heavy modules and far apart for array-heavy ones.
The recommendation is to build on Pure Borrow, with the beginner surface documented first and the borrow surface introduced through the parallel examples.

## 7. Packages, phases and gates

Packages:

- `pure-borrow` (upstream): the `End` witness fix and the world index with `Control.Monad.Borrow.IO`, both landed in commit `a816d2a` with the amendments of `workspace/WORLD-BASE-IMPURITY-REVIEW.md`.
- `h2py`, its own repository depending on the released `pure-borrow`: `H2Py` (prelude and tutorial), `H2Py.Py`, `H2Py.Object`, `H2Py.Class`, `H2Py.Convert`, `H2Py.Exception`, `H2Py.Module`, `H2Py.TH`, `H2Py.Buffer`, `H2Py.Runtime`, each with `.Internal` and `.Unsafe` siblings following `pure-borrow`'s suffix convention; `cbits/h2py.c`, `include/h2py/h2py.h`, `include/h2py/init.h`.
- `h2py-examples`: one extension module, `h2py_examples`, since 5.9 allows one Haskell-built module per process, with the `Counter` class and an `nparallel` submodule exposing `sort`, `fft` and a stencil over NumPy arrays; a `pytest` suite; a benchmark script.
- Python-side packaging: the build hook from 5.10.

Phases, each ending in a gate:

0. **Upstream** (done).
   The forced `End` witness and the world index with `BIO`, the generalised `parBO` and the scheduler landed in commit `a816d2a`, after the plan review and the implementation review recorded in `workspace/WORLD-BASE-IMPURITY-REVIEW.md`.
   Two of that review's corrections bind H2Py: the safe `execBIO` eliminates only `BIO`, so `runPyCall` and `attach` are built on the trusted generic eliminator of `Control.Monad.Borrow.Unsafe` and carry its world-protocol obligation, the arena and the attachment established before the body and swept after it; and `Forkable` is a trusted assertion, so the `Unsatisfiable` instance for `Python π` is mandatory rather than advisory.
0.5. **Structured `parBO`** (1 week).
   The change of 4.4 to `parBO`, `Par` and the scheduler, with the concurrency reviewer; it gates Phase 4.
1. **Spike** (2 weeks).
   A hand-written module with one function and one class, built by `foreign-library` against the 3.12 limited API, imported from CPython 3.12 and 3.13 on macOS aarch64 and Linux x86_64.
   Gate: import works; call overhead measured on the real trampoline path, arena push and sweep, pool drain and the thread-local attachment check included, against PyO3's `getattr` on the same machine, plus one `derefMut` round trip; `KeyboardInterrupt` unaffected; a Python thread pool calling in concurrently works; a Python operation from an unbound `forkIO` thread raises `NotAttached`, and `detach (parBO (attach_ …) (attach_ …))` works; dynamic versus `-staticlib` distribution decided with wheel sizes; the packaging hook chosen.
2. **Objects, exceptions, conversions** (2 to 3 weeks).
   `Py` with its two axes, `attach`/`attach'`/`detach`/`parPy`, `Bound`/`Borrowed`, arena with its sweep order and hold list, pool, `PyHandle`, protocol operations, `FromPy`/`ToPy`, `FromArg`/`ToResult`, `PyErr`/`PyResult`.
   Gate: refcount-delta tests through `sys.getrefcount` for every operation, including `Left` paths and Haskell-exception paths; `TypingCases` for every item in section 8.
3. **Classes and registration** (5 weeks; the second review found 3 short by the size of the `Slot` GADT, inheritance and the stub gate).
   `pyclass`, `newObject`, `derefMut`/`derefShare`/`copyPayload` with the one-word lend, the `detached` adjustor, poisoning, `pymethods`/`pymodule`, adjustor-based tables, `ModuleDesc` with `PyTypeHint`, `renderStubs` and `checkStubs`; the `Slot` GADT except `Buffer`, `HsIterator`, `extends` between Haskell classes, `subclassable`, `abc`, `newException`, and the tag relation `:<:` with `upcast`/`downcast`.
   Gate: contention tests that assert `busy` for a second thread's `derefMut` during a detached kernel, for `derefMut` on two handles to one object in one scope, and for a re-entrant `derefMut` through a Python callback; that a second thread's `derefShare` during a detached read-only kernel, a repeated `derefShare` in one scope and `c == c` succeed; poisoning tests for asynchronous and `error` exits and clean release when a method returns `Left`; a hold scoped by `attach'` is released at its end; a Python error inside a `Mut`-receiver method leaves the object usable; dealloc consumes payloads, leaks poisoned ones, and never raises; the `counter` example; its rendered stub matches a committed golden file and passes `mypy --strict` against the Python test suite.
4. **Buffers and the showcase** (3 weeks).
   `requestBufferMut`/`withBufferMut` with the registry; `HsBuffer` and `newArray`; the `Buffer` slot with its export count; the `qsortDC`-at-`Storable` inspection test; `nparallel` with `qsortDC` and `fftDC`; benchmarks against `numpy.sort` and `numpy.fft.fft` across core counts.
   Gate: numbers in the README; two-thread `sortInPlace` on one array is refused; a branch exception in `qsortDC` reaches the caller as a Python exception and poisons rather than hangs (4.4), and the shipped kernels are shown to answer `Left` on every input they reject.
5. **`abi3t`, packaging, docs** (2 to 3 weeks).
   3.15 free-threaded CI, `Py_MOD_GIL_NOT_USED` audit, wheels for both ABIs shipping `<module>.pyi` and `py.typed` written by the hook, `h2py stubs`, the fork hook, the tutorial with the error-message glossary.
   The `abi3t` half depends on a released CPython 3.15; if none is available when the phase starts, 0.1 ships `abi3` only and `abi3t` follows in 0.1.1.

Test discipline follows `AGENTS.md`: "must not typecheck" cases in `TypingCases` with deferred type errors inspected at runtime, multiplicity errors in `test/typing-fail/`, and `expectFailBecause` only for properties we want and do not yet have.
Every phase that touches `pure-borrow` or adds an `unsafe` use in `h2py` gets the three-lens review before commit, with the ergonomics lens folded into the design-fit reviewer.

## 8. Escape attempts the type checker must refuse, and packed forms that must be inert

Each refusal is a `TypingCases` entry or a `typing-fail` case; each inert form is a spec that the packed value compiles and every operation on it is refused.

1. `runBO lin (liftSystemIOU (pure ()))`: world mismatch.
2. `runBIO (getAttr ...)`: `Python π` is not `RealWorld`.
3. `coerce :: BIO α a -> BO α a`, and `coerce` or `upcast` between worlds, between `PyRef` tags, between attachment lifetimes, and on `BufferMut π e` and `BufferShare π e`: nominal roles on every index-carrying type, since the incoherent `Coercible a b => a <: b` instance turns a phantom role into a safe-API retag.
4. Returning a `Bound π t` from `attach_`, or a `Bound (π' /\ π) t` from `attach'`: the attachment escapes its rank-2 binder.
5. Returning a `Borrowed π t` from a trampoline body through the result type at a longer attachment: refused by `ToResult`'s outlives constraint, since `π` is the call's attachment and cannot be lengthened.
6. Using a `Borrowed π t` inside `detach`'s body: no `Py` operation is available in `BIO`.
7. Returning a payload borrow obtained by `derefMut` or `derefShare` inside `attach'`, `sharing`, `reborrowing` or `withBufferMut` from that scope: the ambient carries the scope's rank-2 lifetime, which escapes.
8. `derefMut` or `setAttr` on a `Borrowed π a`: a `Share` never yields a `Mut`; there is no such function.
9. Two `derefMut` through one `Bound π a`, or `derefMut` on a handle that has been `share`d: multiplicity error (`typing-fail`).
   Runtime spec: `derefMut` on two handles to one object in one scope, `derefMut` from a second thread while another scope holds the object, and a re-entrant `derefMut` through a Python callback each answer `Left` with `busy`; `derefShare` twice in one scope and from two scopes at once succeeds, and `derefShare` while another scope holds `Mut` answers `busy`; a dereference while a buffer view is live answers `Left` with `BufferError`; no Python error becomes a Haskell exception except through `orThrow`, which is an abort.
10. `copyMut` or `copy` on a `Bound π t`, `clone` (the `Clone` class) on a `Borrowed π t`: `Unsatisfiable`.
11. `move`, `dup`, `dup2` on a `Bound π t`: no instance.
12. `parBO`, `runPar` or `divideAndConquer` in a `Py` computation: the `Unsatisfiable` instance's message.
    Allowed, and asserted to compile and run: `liftBO (parBO …)`, `detach (parBO …)` over a split borrow, and `parPy` whose branches use the call's arguments, under both builds, serialising on the GIL and overlapping under free-threading.
    Runtime spec: a Python operation reached from an unattached thread through lifted `IO` raises `NotAttached`.
13. `attach_` inside a `Py` computation with no `detach` around it: world mismatch, since `attach_` runs in `BIO` and there is no lift into `Py`; a branch can attach only inside `detach`, in a released parent.
14. Returning a `Bound π' t` from an `attach_` inside a `parPy` branch: `π'` escapes its rank-2 binder.
15. `liftBIO` from `Py`: no such function in the safe API; `unsafeLiftBIO` into `BO`: missing `Impure Pure`.
16. `pyclass ''Holder` for `data Holder π` or `data Box a`: refused by the splice.
17. Inert: `data Some where Some :: Bound π t %1 -> Some` and the `Borrowed` and `Mut` variants, stored in a payload and taken out in a later call; every operation that carries `π >= γ` on the unpacked value, `toHandle`, `getAttr`, `setAttr`, `derefMut`, `derefShare` and the monadic container operations, is refused; the pure operations that touch no memory, `size` or `splitAt` on a stale `Share`, typecheck, which is harmless only because no buffer-backed or payload type has a pure `Copyable` instance or any other pure dereferencing read, an invariant H2Py keeps for every wrapper it defines.
18. `instance Impure Pure` and `instance End α` with no body: compile with a warning, and using the capability diverges (runtime specs).
19. Allowed, and asserted to compile: returning a `Bound π' u` created inside a `sharing` or `reborrowing` body or while a `Mut γ a` from `derefMut` is live, and a `Mut γ x` from `borrow x lin` at the caller's `γ` inside `attach`'s body leaving `attach`, whereas `borrowM` borrows at the ambient `π /\ γ` and cannot; all are the reason the two axes are separate.
    Also allowed: `reborrowing_` and `sharing` on a `Bound π t`, which restore it, since no operation on a handle invalidates its slot, with `getAttr` on the narrowed view and `derefMut` on the narrowed handle inside them; and `liftBO (parBO …)` and `detach (parBO …)` over a split dereferenced payload.
20. A `catch` or `try` over `Py` with a linear body: not provided, by linear-base's rule that any linear arrow on `catch` is unsound; nothing needs it, since Python errors are values, and the only catching available is linear-base's unrestricted `catch` inside a lifted `IO` action, whose body cannot capture a linear value.
21. A receiver at a separate lifetime using a Python operand, `Mut α a %1 -> Borrowed π u -> Py π α r`, without `(π >= α) =>`: refused with an unsolved `α <=!! π`; the receiver form of 5.4 is written at `Py π π`, and the constrained form composes on a meet but not through a given (`TypingCases`, both directions).

## 9. Open questions for the maintainers

1. Whether the tutorial opens with `PyHandle` and the conversions or with the receiver-form methods.

Decided since v1.0: `h2py` is its own repository, depending on the released `pure-borrow`; `parBO` and the scheduler become structured (4.4); `coerceMut` is not needed; the exception-path guard for impure `update` is abolished; Python errors are values with `orFail`, and `orThrow` is an abort rather than `?` (5.5); the shared lend is counted, PyO3's flag (5.3), and the release token of earlier drafts is gone with its last job (5.1).

## Appendix A. Worked example

Typechecked against the real API by both ergonomics reviews, in the receiver form; the second review's three modules, a counter with a callback while holding the payload, a merge of two payloads, and a NumPy kernel with `parBO` inside `detach`, compiled once written at `Py π π` and are the tutorial's examples.

```haskell
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}
-- ImpredicativeTypes is not needed here; it is needed once a scope body is passed through ($) or (.).
module Counter where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.Pure                 -- exports upcast, coerceShare, consume, move, Ur
import Data.Ref.Linear (Ref)
import Data.Ref.Linear qualified as Ref
import Data.Ref.Linear.Borrow qualified as RefB
import Data.Text qualified as Text
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
  ref <- RefB.modify (+ k) (upcast counter :: Mut π (Ref Int))   -- Mut π Counter <: Mut π (Ref Int): a newtype is a subtype both ways
  Control.pure (consume ref)

get :: Share π Counter -> Py π π Int
get counter = RefB.copyRef (coerceShare @(Ref Int) counter)      -- a linear Int, which ToResult consumes

-- A Python object built while the payload is borrowed, returned from the method: `π` is not narrowed by the dereference.
label :: Share π Counter -> Py π π (PyResult (Bound π PyStr))
label counter = Control.do
  Ur n <- Control.fmap move (RefB.copyRef (coerceShare @(Ref Int) counter))   -- every bind is linear: move before an unrestricted use
  toStr (Text.pack ("Counter(" <> show n <> ")"))

pymethods ''Counter [constructor 'new, method "incr" 'incr, method "get" 'get, method "label" 'label]
pymodule "counter" [] [''Counter]
```

```python
>>> import counter
>>> c = counter.Counter(40)
>>> c.incr(2); c.get()
42
```

The `nparallel` submodule's `sortInPlace` is in 5.7, with the imports it needs: `Control.Concurrent (getNumCapabilities)`, `Control.Concurrent.DivideConquer.Linear (qsortDC)`, `Control.Monad.Borrow.IO (liftSystemIOU)`, `System.Random (newStdGen)`, `H2Py.Buffer`.

What the tutorial must contain, per the ergonomics review: the seven pragmas above; that `BO'` has only linear-base's `Control.Functor.Linear.Monad`, so `Control.do` and `Control.pure` are mandatory and a plain `do` block fails with "No instance for (Monad (BO' (Python π) γ))"; that `Prelude.Linear` exports neither `Functor` nor `Monad`; the two axes of `Py π γ`, with the rule of thumb that `π` is "which call or scope a Python object belongs to" and `γ` is "which scope a Haskell borrow belongs to"; how to read `forall α. … (α /\ γ)`; `Ur` unwrapping, and that every `x <- …` in `Control.do` binds `x` linearly, so `move` or `Ur` comes before any unrestricted use; that `let` is not linear, so a linear result is taken apart with `case`; that `Prelude.Linear`'s arithmetic is linear, so `(* k)` is not the unrestricted function `SV.modify` wants; `consume` of a borrow that is no longer needed; the `case` on a `PyResult`, with `orFail` for its `Left` branch, and that a `Just _` pattern on a linear result is a multiplicity error that hides every other error in the module; that every function using a Python reference is written at `Py π π`; the three monads and the lifts; and a glossary from the three error texts a beginner will meet, as GHC 9.12.4 prints them, to the mistake behind each: "Couldn't match type ‘π’ with ‘β /\ π’ … ‘π’ is a rigid type variable" for returning a borrow from a scope, "Couldn't match type ‘Many’ with ‘One’ arising from multiplicity of ‘counter’" for using a `Mut` twice or not at all, and an unsolved `<=!!` goal, whose "Possible fix" line must not be followed, for a function that uses a Python operand from a receiver at a separate lifetime: write it at `Py π π`.

## Appendix B. Adversarial review log

Three reviewers, fresh context each, instructed to refute rather than confirm: **A** linear ownership and type-level soundness; **B** runtime, FFI and concurrency; **C** user ergonomics, performance, build feasibility and fairness of the comparison.
Every finding is listed with its disposition.
"Fixed" names the section that now carries the fix; "refined" means the finding was accepted with a narrower rule and the argument is given; "rebutted" means it was not accepted and the argument is given.
No soundness or ownership finding was rebutted.

### Reviewer A: ownership and soundness

| # | Finding (severity, label) | Disposition |
|---|---------------------------|-------------|
| A1 | `Bound = Mut π (PyRef t)` with destroying operations double-frees through `reborrowing_` (blocker, substantiated) | Fixed in 5.2: `Bound` and `Borrowed` are their own types, not aliases; the program is kept in the text as the reason. (v1.0 wording: from v1.1 they are aliases of `Mut` and `Share` over `PyRef` again, sound because no operation invalidates a slot; see the revision log.) |
| A2 | Phantom role lets `coerce` launder `BIO` into `BO`, forge `ImpureWitness Pure`, and retag `Borrowed` (blocker, substantiated by running it) | Fixed in 4.2 and 5.2: nominal role annotations on `Borrowing`, `ImpureWitness`, `Bound`, `Borrowed`, `PyHandle`; `coerce` attempts added to section 8. (v1.0 wording: `Borrowing` became `BO'`, `ImpureWitness` became the `liftLinIO` method, and the roles sit on `PyRef` and `PyHandle`, since the aliases carry none.) |
| A3 | Class-as-capability forgeable by a bodiless orphan instance; `End` already is (blocker, substantiated by running it; reproduced by the author) | Fixed in 4.3 and 4.4: every consumer forces the witness; the `End` fix is filed as its own upstream change and is a Phase 0 prerequisite. |
| A4 | `ToPy (Borrowed π t)` cannot carry `π >= γ`, so a stashed reference is incref'd after death (major, substantiated) | Fixed in 5.4 and 5.6: reference-typed arguments and results go through the call-lifetime-indexed `FromArg π`/`ToResult π`; `FromPy`/`ToPy` are value-type classes only. |
| A5 | Two live `Mut`s over one NumPy buffer from two Python threads (major, substantiated) | Fixed in 5.7: the address-range borrow registry moves into 0.1 (Phase 4); the Python-side residual is stated. |
| A6 | Arena free-list mutated from two OS threads via a `Bound` captured by `concurrently` branches (major, substantiated) | Fixed in 5.2: foreign-thread release only atomically tombstones the slot; the owner alone touches the free-list; sweep cannot overlap because `concurrently` joins before returning (4.2 records that dependency). (v1.0 wording: `concurrently` and the tombstone protocol are gone, and 5.2 now has no cross-thread arena traffic at all.) |
| A7 | Exceptional exit from `withMut` exposes a torn payload (major, plausible) | Refined in 5.3: poison on asynchronous and `error`-class exits; a synchronous `PyException` resets cleanly because Python exceptions are raised only between complete container operations, which are `BO` and cannot raise one. The reviewer asked for unconditional poisoning; the narrower rule is justified in the text and is what keeps `KeyboardInterrupt` from destroying objects (C5). Set aside in v1.2, whose checkout bodies could not raise a Python exception, in force again in v1.3, whose in-place dereferences reinstated the case, and moot from v1.4, where Python errors are values that never unwind and the Haskell exceptions that remain poison unconditionally. |
| A8 | Section 8 items 3, 4, 6, 7 were not refused; existential packing is legal and inert only because every dereferencing operation demands `π >= γ` (major, substantiated) | Fixed in 5.2 and 8: the rule is stated as load-bearing, inert forms get their own specs; the closedness rule of 5.3 is added because a lifetime-parameterised payload type defeats the inert rule (C1). |
| A9 | `<:` for the monad and `assocBOEq` must keep `w` fixed (minor, not established) | Fixed in 4.2. |
| A10 | The world index does not protect thread affinity across `concurrently` (minor) | Documented in 5.1. |
| A11 | Arena growth for dropped temporaries is linear, not bounded by live count (minor, substantiated) | Fixed in 5.2: nested arenas, then called `scoped` and now `attach'`; the growth is documented. |
| A12 | Appendix A does not typecheck; `modifyCell` must force the returned payload (minor, substantiated) | Fixed in Appendix A and 5.3. |
| A13 | `runPyCall` must not be reachable from unattached code (minor, not established) | Fixed in 5.4: it lives in `H2Py.Runtime.Internal`. |

### Reviewer B: runtime, FFI and concurrency

| # | Finding (severity, label) | Disposition |
|---|---------------------------|-------------|
| B1 | `Py_DecRef` as an `unsafe` import deadlocks or aborts when `tp_dealloc` re-enters Haskell (blocker, substantiated) | Fixed in 5.2 and 5.9: every callback-capable or blocking CPython call is `safe`; sweep and drain are single `safe` C calls. |
| B2 | Free-threaded builds have no stable ABI before 3.15; `abi3` minimum is 3.12; `Py_mod_gil` breaks 3.12 imports (blocker on scope, substantiated) | Fixed in 1, 5.8, 5.10: `abi3` at 3.12, `abi3t` at 3.15, `Py_mod_gil` only in the `abi3t` build. |
| B3 | `abi3t` makes `PyObject` and `PyModuleDef` opaque; single-phase init cannot carry the slots (major, substantiated) | Fixed in 5.3 and 5.4: negative `basicsize` with `PyObject_GetTypeData`, `tp_free` via `PyType_GetSlot`, multi-phase `PyInit_` plus `PyModExport_`, new-reference accessors only, detach mandatory under free-threading. |
| B4 | `parBO` and the scheduler turn a branch exception into a hang with the interpreter attached (major, substantiated) | First recorded as a separate question, then decided in 4.4: `parBO` and the scheduler propagate, after both branches have finished; an upstream change of its own, landing before Phase 4 exposes `qsortDC`. |
| B5 | Pool mutex held across decref admits a GC deadlock; arena free-list races (major, plausible) | Fixed in 5.2: swap-out drain protocol; finalisers only push. (The tombstone release went with `concurrently`.) |
| B6 | `newArray`'s capsule owner keeps nothing alive (major, substantiated) | Fixed in 5.7: `HsBuffer` exporter heap type with `Py_bf_*` slots. |
| B7 | Exceptions on the dealloc path terminate the process; `checkSignals` semantics overstated (major/minor, substantiated) | Fixed in 5.3 and 5.1: dealloc catches everything and reports through `PyErr_WriteUnraisable`; `checkSignals` is main-thread only and unavailable to detached kernels. |
| B8 | `attach` not exception-safe as described; `runInBoundThread` facts; finalisation hang (minor, substantiated/plausible) | Fixed in 5.1: `mask` discipline everywhere, corrected description of `runInBoundThread`, `Py_IsFinalizing` guard where available. |
| B9 | Dynamic linking bundles dozens of libraries; RTS never shared across wheels; fork hook needed; PIC availability for `-staticlib` unknown (minor, plausible) | Fixed in R1, 5.9, 5.10 and Phase 1: wheel sizes and the LGPL notice recorded, after-fork child hook added, `-staticlib` evaluated in the spike. |
| B10 | Buffer details: strides, flattening, formats, alignment, `refcheck`, nesting of release inside `Py` (minor, verified) | Fixed in 5.7. |

### Reviewer C: ergonomics, performance, delivery, fairness

| # | Finding (severity, label) | Disposition |
|---|---------------------------|-------------|
| C1 | Payload types have no `'static` bound (major, substantiated) | Fixed in 5.3: `pyclass ''T` refuses parameterised types; the obligation is stated for hand-written instances. |
| C2 | `Py_DecRef` cannot be `unsafe` (major, substantiated) | Same as B1. |
| C3 | Appendix A and the 5.4 snippet do not typecheck (major, substantiated) | Fixed in Appendix A with the reviewer's transcription, simplified by the receiver form; the `coerceMut` the reviewer proposed is not needed, since `upcast` from `Data.Coerce.Directed` reaches a newtype payload through the `Mut` subtyping instance. |
| C4 | The `(π >= γ)` convention on user methods does not compose, since transitivity is not derived (major, substantiated) | Fixed in 5.2 and 5.4: user code is written at the call or scope lifetime; the outlives convention is for library operations only. |
| C5 | The beginner surface shows lifetimes, and `modifyCell` poisons on any Python exception including `KeyboardInterrupt` (major, substantiated) | Fixed in 5.3 and 5.4: receiver-form methods with generated dereferences are the primary surface; the checkout operation of that draft, `modifyPure`, took a pure body and poisoned only on `error` or asynchronous exceptions, and v1.3 removed it in favour of a `Ref` inside the payload; v1.4 closes the `KeyboardInterrupt` half for good, since it arrives as a value and cannot poison. |
| C6 | `w` "quantified last" only holds with an explicit `forall`; `execBO @α …` would change meaning (major, substantiated) | Fixed in 4.2: explicit `forall` with `w` last on every generalised signature, checked mechanically. |
| C7 | Stable-ABI version claims inconsistent; single-phase init cannot declare the slots (major, plausible) | Same as B2 and B3. |
| C8 | Comparison rows 2 to 4 were straw men; "applied showcase" is a goal, not an engineering argument (major, substantiated) | Fixed in 6.2 and 6.3: rows rewritten with the precise linear-base facts (`slice` copies, `Vector.slice` consumes, `Destination.split` write-only, `RIO` releases at `run` granularity, ST-style `s` gives call-scoped borrowed arguments); the goal is named as one. |
| C9 | Build effort understated; `pkgconfig-depends` unreliable in venvs (minor, plausible) | Fixed in 5.10 and 7: `sysconfig` include path, two-week spike. |
| C10 | Onboarding hazards: no base `Monad`, `Prelude.Linear` lacks `Functor`/`Monad`, error glossary, `ImpredicativeTypes` (minor, substantiated) | Fixed in Appendix A's tutorial list. |
| C11 | Naming: `Cell`, `Bound = Mut`, `clone` vs `Clone`, `BO'` (minor, substantiated) | Fixed: no `Cell`. (v1.0 wording: `Bound` is an alias again, `cloneRef` is gone, and `Borrowing` was not taken.) |
| C12 | `Impure w` and four lifts visible to users (minor, substantiated) | Fixed in 5.1: `Impure` kept out of the tutorial. (The monomorphic re-exports were withdrawn in v1.5, since they collided with linear-base's and pure-borrow's names, C2.13; the lifts are pure-borrow's own.) |
| C13 | Linear `toPy` is fine for callers; add a `Movable`/`Generic` default (substantiated) | Fixed in 5.6. |
| C14 | Per-call cost unmeasured (not established) | Recorded in R3 and the Phase 1 gate. |
| C15 | `foreign import ccall "wrapper"` adjustors are a simpler alternative to TH-generated `foreign export`s (observation) | Adopted in 5.4 for the adjustors and the tables; registering a lifetime-polymorphic method itself is a splice (C2.8). |

### What the reviewers attacked and found to hold

`runBIO`/`withBIO` introduce no `runRW#`; `liftSystemIO`'s `Ur` result is enough; `liftIO` over linear-base's `IO` adds no obligation; `parBO` and `Par` stay pure and `liftBO (parBO …)` inside `Py` is fine; lifetime lengthening is underivable through the outlives instances, so `Share`/`Mut`/`Lend`/`After`/`EndToken` subtyping all point the safe way; `borrow`/`borrowM` at a user-chosen lifetime on a payload yields at most a leak or a poisoned object; `Clone` is guarded by its result index and `Copyable (Bound)` unsatisfiable is right; every entry from foreign code runs on a bound thread and bound threads never migrate; `detach` then `attach` nesting is legal CPython usage; with every callback-capable call `safe`, no capability/GIL/GC cycle could be built; draining the pool only when attached is necessary; `hs_init` has no main-thread requirement; the CAS flag with reset in `finally` and `tp_dealloc`-while-borrowed impossible; `qsortDC`/`fftDC` at a `Storable` backend apply unchanged; TH can emit `foreign export` if ever needed; the world index is the right axis, since `Conquer`'s abstract sublifetimes carry no evidence a lifetime-indexed impurity constraint could use; the phantom world is zero-cost in Core and no inspection obligation touches a world-polymorphic binding.

### Revisions since v1.0, from the maintainer's follow-up decisions

- The indexed monad is named `BO'`, as in the WIP module; the reviewers' `Borrowing` was not taken.
- `Impure`'s method is the lifting function itself rather than a forced witness, which closes the bodiless-instance hole (A3) without a runtime check.
- `parBO` keeps its implementation and semantics and is gated by the nullary marker class `Forkable`, whose instances are the two state-token worlds; the scheduler and the shipped kernels carry the same marker, the sequential variant does not.
  `Par` is its applicative; the branch-exception change (B4) was first recorded in 4.4 as a separate upstream question and is now decided there: propagate, after both branches have finished.
- Attachment is held per scope on a bound thread, as in v1.0.
  Three alternatives were drafted in between and withdrawn: a per-operation attachment scheme, because on the trampoline path the caller's GIL hold makes it deadlock exactly as the scoped one would, at the cost of a GIL acquisition per operation; and an open type family `Branch` mapping a world to the world of its forked branches, with `Branch (Python π) = RealWorld`, because its only non-identity instance served `parBO` written directly in an attached method, which holds the GIL while waiting and is never the right shape; `Branch (Python π) = Pure` was judged too restrictive.
  The marker class is what the maintainer first proposed as `ParWorld`; it became the right description once the Python world had a fork-join of its own.
- `detachWith`, `attachFrom` and `parPy`, from the maintainer's `PyGIL`/`parPy` sketch: the release window is a rank-2 lifetime `δ`, the token `Detached δ π` is unrestricted, and `attachFrom` requires `δ >= γ'`, which makes a packed or escaped token inert by the same rule as a packed reference.
  Linearity of the token, as first sketched, was replaced by the lifetime gate because a linear token can still be packed into a payload.
  The parent-child deadlock of `Python::attach` in a worker is a type error here, though the second review showed that the reason is the `Forkable` gate rather than the token (A2.8).
  A branch never releases an outer reference, so there is no cross-thread arena traffic.
  (Withdrawn in v1.6: the second review showed a plain `attach_` in a branch to be exactly as safe, and the counted lend state removed the token's remaining job, arena nesting; `parPy` is now `detach`, `parBO` and `attach_`.)
- `liftBIO` is removed from the safe API and becomes `unsafeLiftBIO` in `.Unsafe`: `detach` is the safe way to run `BIO` code from `Py`, since it releases the attachment first; the direct lift is unsafe for liveness.
  Every Python operation still checks the shim's attachment flag and raises `NotAttached` on an unattached thread, as defence in depth for `IO` that forks.
- `concurrently` and the `async` dependency are removed; nothing in the design needed them.
- A transformer over an arbitrary base monad was designed and parked; `workspace/PURE-BORROW-AS-TRANSFORMER.md` records the reason, which is that `parBO` is a property of the base's effects that no general characterisation yet exists for.
- The Python world carries its own lifetime: `Py π γ = BO' (Python π) γ` replaces the fixed `Python` tag, Python references are indexed by the scope axis `π`, and `attach'` replaces `scoped`.
  The reason is a hole in v1.0 that the fixed tag could not avoid: a Python object created inside a payload scope took the scope's rank-2 borrow lifetime and could not be returned from it, so no receiver-form method could return a Python object.
- Section 8 gains the two positive cases that motivate the separate axes.
- The reference model went through three forms before settling, and the record matters because the last one is the first draft's shape with one operation removed.
  The first draft had `Bound π t = Mut π (PyRef t)` with a consuming `decref`, which reviewer A refuted (A1).
  The fix in v1.0 made `Bound` an affine owner outside the alias machinery; a later draft collapsed both forms into a single unrestricted `Share` with `withMut` taking a view, which was sound by the runtime flag but discarded the static half of exclusivity and let a `Share` yield a `Mut`, and the maintainer rejected it on sight.
  The final form restores `Bound π t = Mut π (PyRef t)` and `Borrowed π t = Share π (PyRef t)` under the principle that a shared borrow may not mutate and a unique borrow may mutate but may not invalidate: the arena is the sole owner of every +1, there is no `decref`, references leaving the scope are incref'd, mutating protocol operations and `withMut` take the handle and return it, reading operations and `withShare` take a view, and the runtime flag guards only what the types cannot see, Python-side aliases and independently obtained handles.
  `cloneRef`, `withBorrowed`, `asBorrowed`, `decref` and the arena's cross-thread release protocol are gone; `copyOut` is added as the monadic `copyMut` analogue.
- Payload access is a dereference, `derefMut`, `derefShare` and `copyPayload`, from the maintainer's two observations that reborrowing is irrelevant to a dereference and that a lend must be exclusive, so no borrow counter belongs on the Haskell side.
  Two intermediate drafts are withdrawn: the scopes `withMut`, `withShare` and `modifyPure` of v1.1, and the checkout operations `update`, `updateDetached`, `update2` and `modify` of v1.2, which existed only to give the runtime hold a release point tighter than the scope.
  The arena sweep is that release point, as the end of a Rust scope is for PyO3's guard, and `attach'` tightens it; so the payload is borrowed in place for the rest of the scope, methods may call Python while holding it, reviewer A's exception rule (A7) stands, and the `detached` adjustor selects `detach` for a long pure body.
  The word became `Free`, `Shared h`, `Mut h` or `Poisoned`, with `h` the holding arena, because an unrestricted view must be dereferenceable more than once in a scope; there is still no count, and a hold outliving the borrow it was taken for is documented as the one cost.
  Two corrections came with it: every operation's constraint moved from the attachment axis to the borrow axis, `π >= γ`, without which a handle narrowed by `sharing` or `reborrowing` satisfied no operation at all; and every attachment delimiter now meets the ambient borrow lifetime with its attachment, without which a dereferenced borrow could outlive the sweep that releases its hold.
  The observation that `Data.Ref.Linear.Borrow.update` skips its write-back when the body throws is recorded in `workspace/WORLD-BASE-IMPURITY.md`; it is not a defect there, since the cells of an aborted `BIO` computation are unreachable and linear-base's `catch` cannot close over a linear value, but at H2Py's recovery boundary a Python object keeps its payload alive, and that is why the dereference yields the payload itself rather than a `Ref` cell around it.
- Python errors are values, from the maintainer's question whether `Either` and an `RIO`-like table would serve: `PyErr` is unrestricted, every fallible operation returns `PyResult a = Either PyErr a`, and nothing unwinds for a Python error, which is PyO3's own `PyResult`.
  `PyException`, `catchPy` and `tryPy` are gone; the linear `tryPy` was the arrow linear-base documents as unsound, and there is no function that turns a `PyErr` into a Haskell exception.
  The exception rule of 5.3 collapses to one line, every Haskell exception reaching the sweep poisons what the arena holds mutably, and `KeyboardInterrupt` can no longer poison anything, which closes C5 entirely; the dereferences answer `busy`, a live export and a poisoned object as `Left`.
  Fallible operations never take a continuation, since a scope denied its resource could not consume the linear body it cannot run, so buffer access became acquire-then-scope in 5.7.
  The arena is the `RIO`-style table the question named: it already owned every reference and every hold with release on every exit path, and with errors as values nothing linear is ever needed for cleanup.
- Three decisions close the loose ends before the second review: `h2py` is its own repository; `parBO` and the scheduler propagate branch exceptions (4.4, made structured after the second review), an upstream change still to land; and `coerceMut` is not needed, since `upcast` from `Data.Coerce.Directed` covers a newtype payload (Appendix A).
  The exception-path guard for impure `update` proposed in the impurity plan is abolished, since with errors as values H2Py does not need it and `pure-borrow` never did.

## Appendix C. Second adversarial review log (v1.4)

Three reviewers with fresh context, one lens each, instructed to refute rather than confirm: **A2** linear ownership and type-level soundness, who typechecked twenty probe modules against the built library through a type-level stub of sections 5.1 to 5.12; **B2** runtime, FFI and concurrency, against the CPython 3.12 and 3.13 headers, the RTS library, PEP 793 and PEP 803, and the landed `parBO` and scheduler; **C2** user ergonomics, performance, delivery and fairness, who wrote three sample modules against the API as specified.
Every finding is listed with its disposition, and the labels are the reviewers' own.
Two findings were put to the maintainer as open decisions and decided the next day, as the end of this appendix records; every other one is fixed in the section named.

### Reviewer A2: ownership and soundness

| # | Finding (severity, label) | Disposition |
|---|---------------------------|-------------|
| A2.1 | `Detached`, `BufferMut` and `BufferShare` have phantom roles, so `coerce` and the safe `upcast` retag their indices; a write through a released NumPy view typechecks (blocker, substantiated) | Fixed in 5.1, 5.7 and 8.3: nominal role annotations on every index-carrying H2Py type, with `TypingCases` entries. |
| A2.2 | The `π >= γ` convention leaves `fromPy`, `toPy`, `Compare`, `Exit`, every receiver method with a Python operand and the 5.7 example untypeable; `(π >= α) =>` composes on a meet but not through a given (major, substantiated) | Fixed in 5.4, 5.6, 5.7 and 5.12: user code is written at `Py π π`, receiver forms and slots included; `fromPy` and `toPy` carry `(π >= γ)`. |
| A2.3 | Join-then-rethrow covers a child's exception only; a parent interrupted asynchronously in `parBO` unwinds while branches write through borrows the sweep releases (major, plausible) | Fixed in 4.4 with B2.1: structured `parBO` and scheduler, cancel and join on both paths. |
| A2.4 | `copyPayload`'s transient claim can write `Free` over a live scope's shared hold (major, plausible) | Fixed in 5.3: a claim is released only by whoever installed it; `copyPayload` leaves a reused hold untouched. |
| A2.5 | The export count and the word are two atomics with an unstated check order (major/minor, not established) | Fixed in 5.3 and 5.12 with B2.4: the dereference claims the word first and reads the count under the claim. |
| A2.6 | 8.17 overstates inertness: pure operations such as `size` on a packed stale `Share` typecheck; only the `Unsatisfiable` `Copyable` keeps a stale NumPy share from reading freed memory (minor, substantiated) | Fixed in 8.17: reworded, and the invariant that no buffer-backed or payload type gets a pure dereferencing read is recorded. |
| A2.7 | 8.19 was wrong about `borrowM`, which borrows at the ambient `π /\ γ` and cannot leave `attach`; `borrow x lin` at the caller's `γ` can (minor, substantiated) | Fixed in 5.1 and 8.19. |
| A2.8 | The token does not gate re-entry as 5.1 said: a plain `attach` in a branch may use the parent's references, safely, since the parent has released (minor, substantiated) | Fixed in 0, 3, 5.1 and Appendix B: the deadlock is a type error because forking is refused while attached; the token's remaining job, arena nesting, went with the counted lend state, and `Detached`, `detachWith` and `attachFrom` are withdrawn (v1.6). |
| A2.9 | Linear `toPy` needs `Consumable` on components for a `Left` mid-conversion; mutating operations consume the handle on `Left` (minor, substantiated) | Fixed in 5.6 and 5.2: `Consumable` superclass on `ToPy`; mutating operations return `(PyResult (), Bound π t)`. |
| A2.10 | `downcast` returns its unrestricted result outside `Ur`, so it binds linearly (minor, substantiated) | Fixed in 5.2. |
| A2.11 | Appendix A's `label` does not typecheck: a linear `Int` passed to `show`, no `Semigroup Text` under `Prelude.Linear` (minor, substantiated) | Fixed in Appendix A with C2.1. |
| A2.12 | The lifetime `(>=)` has no fixity declaration upstream, so `π >= δ /\ γ` misparses (minor, substantiated) | Filed as an upstream task; parentheses until it lands. |
| A2.13 | `frozen` classes violate the multiplicity conventions: a `Consumable` linear payload moved into GC ownership needs `Movable` (minor, plausible) | Fixed in 5.3: `PyFrozenClass` with `Movable`, `move` at `newObject`, no `consume`. |
| A2.14 | `pureAfter` yields `After (π /\ γ) a` where the delimiters want `After π a` (minor, substantiated) | Fixed in 5.1 with C2.6: `attach'_` for bodies without a finaliser, and the `upcast` idiom documented. |

### Reviewer B2: runtime, FFI and concurrency

| # | Finding (severity, label) | Disposition |
|---|---------------------------|-------------|
| B2.1 | "Join first, then rethrow" is the right invariant but the wrong mechanism: branches are bare `forkIO`s with `takeMVar`, the scheduler joins no worker, and a failing branch can leave its sibling blocked forever (major, substantiated from source) | Fixed in 4.4: structured `parBO`, `Par` and scheduler with the cancel-then-join protocol, the latch and the safe-point residue recorded; Phase 0.5. |
| B2.2 | `PyGILState_Check` is not in the limited API (major, substantiated) | Fixed in 5.1, 5.10, R7 and the Phase 1 gate: a shim thread-local flag plus `PyGILState_GetThisThreadState`. |
| B2.3 | `tp_dealloc` consumes a poisoned payload, the torn header the poison exists to protect (major, plausible) | Fixed in 5.3: a poisoned payload is leaked, not consumed. |
| B2.4 | Export count versus word TOCTOU, also under the GIL because a dereference spans `safe` calls (major, plausible) | Fixed in 5.12 with A2.5. |
| B2.5 | Sweep order unspecified; a decref before the hold's release is a write after free; frame-lent arguments have no slot for their hold; the `copyPayload` release rule (major, plausible) | Fixed in 5.2 and 5.3: holds, then views, then decrefs; a hold list keyed by object. |
| B2.6 | Arena identity as a reusable address; CAS and record as separate steps (minor, plausible) | Fixed in 5.3: the compare-and-swap and the arena's record are one C call; scope identities are gone altogether with the counted lend state (v1.6). |
| B2.7 | `Py_IsFinalizing` is 3.13 and later, the thread is terminated before 3.13.8 and hung after, the check is a race, and the restore path was unguarded (minor, substantiated) | Fixed in 5.1: an `atexit` flag on every version, both paths guarded, the residual named. |
| B2.8 | PEP 793's export hook carries name, doc, methods and state in slots; PEP 803's macro, tags and suffix (minor, substantiated) | Fixed in 5.4 and 5.10. |
| B2.9 | Never calling `hs_exit` means `Handle` buffers never flush (minor, plausible) | Fixed in 5.9. |
| B2.10 | The `…Ref` new-reference accessors are 3.13 and later; the 3.12 floor needs `PySequence_GetItem` and `PyObject_GetItem` (minor, substantiated) | Fixed in 5.2. |

Found to hold: `PyGILState_Ensure` after `PyEval_SaveThread` on one thread; the `runInBoundThread` facts, probed (no `forkOS`, a late `timeout`); every callback-capable call being `safe` closes the GIL, capability and GC cycles; `busy` never waiting is right under both builds; the pool's swap-out drain, provided its critical section never allocates or calls back; the 3.12 limited-API inventory of 5.10; `refcheck` and the exporter's `obj`; the fixed-size buffer owner cannot reallocate away from NumPy's memory.
Not verified: `Py_TYPE` and `Py_IS_TYPE` under `abi3t`, so the design uses `PyObject_Type`; PEP 697's alignment guarantee for the atomic word; PEP 803's silence on the `PyGILState` functions; the exact outcome of a nested call-in from an `unsafe` call.

### Reviewer C2: ergonomics, performance, delivery, fairness

| # | Finding (severity, label) | Disposition |
|---|---------------------------|-------------|
| C2.1 | Appendix A does not typecheck (`label`), and `toStr` was undeclared (blocker, substantiated) | Fixed in Appendix A and 5.2. |
| C2.2 | The 5.7 showcase fails twice: H2Py's monomorphic `liftBO` cannot enter a `BIO` body, and `requestBufferMut` needs `π >= γ` (blocker, substantiated) | Fixed in 5.7 and 5.1: `Py π π`, `qsortDC` run directly at `RealWorld`, no H2Py lifts. |
| C2.3 | The receiver form and "`γ` left polymorphic" break on the first Python argument; only `Py π π` composes (blocker, substantiated) | Fixed in 5.4, R5 and 6.2 with A2.2. |
| C2.4 | `FromPy`/`ToPy` methods and the `Borrowed`-taking slots cannot be implemented by users (blocker, substantiated) | Fixed in 5.6 and 5.12 with A2.2. |
| C2.5 | Errors as values cost two to four `case` levels, `Either` has no linear `Applicative`, `borrowM` traps the `Left` branch, and `raise` raised nothing (major, substantiated) | Fixed in 5.5: `pyFail`, `orFail`, the `borrowM` rule, and `orThrow` as an explicit abort rather than a `?` (v1.6). |
| C2.6 | `attach'` is unwritable with the tools named, since `pureAfter` yields the wrong `After` (major, substantiated) | Fixed in 5.1: `attach'_` and the `upcast` idiom. |
| C2.7 | A detached `Share`-receiver method holds `Shared h` with the interpreter released and answers `busy` to every other reader for its duration; "enclosing arena" was unspecified for nested trampolines; the iterator idiom was not given (major, plausible) | Fixed in 5.3 and 5.12: the shared lend is counted, PyO3's flag, and a nested trampoline call is just another scope (v1.6). |
| C2.8 | "No Template Haskell is required for methods" is not shown typeable: a value-level `method` needs an impredicative argument (major, plausible) | Fixed in R6, 3 and 5.4: registration is a splice. |
| C2.9 | The estimate is short by about half; Phase 5 depends on 3.15; the `parBO` change had no phase; two example modules contradict 5.9 (major, plausible) | Fixed in 0 and 7: 18 to 23 weeks, Phase 0.5, one example module, the 3.15 dependency stated. |
| C2.10 | Performance numbers asserted without measurement; the Phase 1 spike measures a floor without arena, pool or dereference; the `SPECIALIZE` claim is not established (major, not established and substantiated) | Fixed in R3, 5.7 and the Phase 1 gate. |
| C2.11 | Section 6 unfair in three rows, and 5.2 contradicted section 0 on PyO3's static half (major, substantiated as text) | Fixed in 5.2 and 6.2. |
| C2.12 | Two of the three glossary error texts are wrong for GHC 9.12.4 (minor, substantiated) | Fixed in Appendix A. |
| C2.13 | `liftIO`, `liftBO` and `copyRef` collide with linear-base's and pure-borrow's names; the `(* k)` and `let` traps (minor, substantiated) | Fixed in 5.1, 5.3 and Appendix A: no H2Py lifts, `copyPayload`, tutorial notes. |

The reviewer's nineteen internal inconsistencies, mostly dispositions in Appendix B that described superseded drafts, are corrected in place and marked as historical wording.
The three sample modules compiled against a stub of the API once written at `Py π π`, and their stuck points are the tutorial notes of Appendix A.

### Revisions in v1.5

- User code is written at `Py π π` (5.4); `fromPy` and `toPy` carry `(π >= γ)` and `ToPy` requires `Consumable` (5.6); the slots follow (5.12).
- Nominal roles on `BufferMut` and `BufferShare` (5.7, 8.3), and on `Detached` while it existed.
- Structured `parBO` and scheduler (4.4, R9, Phase 0.5).
- The word: the hold recorded with the CAS in one C call, `copyPayload`'s release rule, the export count read under the claim (5.3, 5.12); sweep order and a hold list (5.2); poisoned payloads leaked at dealloc (5.3); `PyFrozenClass` (5.3). The per-thread arena serials and the dynamic arena stack of v1.5 went with the single-holder state in v1.6.
- A shim thread-local attachment check; the `Py_IsFinalizing` guard on both paths with an `atexit` flag; PEP 793 slots and PEP 803 build settings; new-reference accessors at 3.12; `Handle` flushing (5.1, 5.4, 5.9, 5.10).
- `pyFail`, `orFail`, the nesting cost stated and `orThrow` left open (5.5); `attach'_` and the `After` idiom (5.1); mutating operations return the handle beside the result, `downcast` in `Ur`, `toStr` declared (5.2); no H2Py `liftIO` or `liftBO`, `copyPayload` (5.1, 5.3).
- Registration is a splice (R6, 3, 5.4); the estimate is 18 to 23 weeks, one example module, the Phase 1 gate measures the real path, the `qsortDC` inspection is in Phase 4 (0, 7); the section 6 rows are corrected; Appendix A typechecks and the glossary carries GHC 9.12.4's texts; Appendix B's stale dispositions are marked.

### Decisions after the second review (v1.6)

- **Errors: values, with an explicit abort.** `orFail` stays as the pure helper for the `Left` branch; `orThrow` and `throwPy` are provided and documented as an abort, not as PyO3's `?`: a `PyErr` becomes a Haskell exception nothing below the trampoline can catch, the linear values in scope are abandoned, which the semantics permit, and the sweep poisons what the scope holds mutably (5.5). The impure `update` guard stays abolished.
- **The shared lend is counted.** The lend state is `Free`, `Shared n`, `Mut` or `Poisoned`, PyO3's `BorrowFlag`: the `Lend` that Python, an unrestricted and multi-threaded owner, cannot hold linearly, recorded in the object. Readers from any number of scopes proceed together; a writer is refused against any hold and a reader against a writer; scope identities and the nesting rule of v1.5 are gone (5.3, 5.8, 5.12).
- **The release token is gone.** With arena nesting no longer needed, `Detached`, `detachWith` and `attachFrom` had no job left, and `parPy` is `detach`, `parBO` and `attach_` (5.1, section 8 items 13 and 14).
- **Related work.** The lend state is placed next to Verona's dynamic region ownership for Python (5.3), as the one-object case of the same idea, pending a check against the paper's text.
