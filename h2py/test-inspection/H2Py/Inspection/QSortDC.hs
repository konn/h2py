{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-orphans #-}

{- |
The Core inspection that section 5.7 of the design asks for before the
README claims anything about the showcase kernel: @qsortDC@ specialised at
the 'Storable' backend a NumPy @float64@ buffer takes, inside a 'BIO' body of
the shape 'H2Py.Buffer.withBufferMut' runs.

pure-borrow's own @pure-borrow-inspection@ asserts the property for the
sequential @qsort@ at @Unboxed.Vector Int@ and permits the @Vector@ and @Ord@
dictionaries.

What the optimised Core of 'storableQsortDC' shows, with GHC 9.12.4 at @-O2@:

* the workload is specialised: the root builds its @DivideConquer@ record
  from @$s$wqsortDC'@, a copy of @qsortDC'@ at @Storable.Vector Double@ in
  @RealWorld@, and no @Vector@, @Ord@, @Storable@, @Forkable@ or outlives
  dictionary survives anywhere in the root;
* the scheduler is not: the root calls @$wdivideAndConquer'@ from
  "Control.Concurrent.DivideConquer.Linear" with the two dictionaries
  @$fTraversablePair@ and @$fRandomGenStdGen@, because @divideAndConquer'@
  carries no @INLINABLE@ pragma and its unfolding is too large for GHC to
  export on its own, so nothing can specialise it from outside the module.

The two surviving dictionaries are consumed once per work item by the
scheduler (the split's shape and the work-stealing generator), never by the
per-element loop, which is the specialised @$s$wqsortDC'@ and, below the
threshold, the specialised @qsort@ asserted separately below.
The property the design wants, no dictionary but @Vector@ and @Ord@, is stated
first and marked as not yet holding, with that reason; the property that does
hold, no dictionary but those two of the scheduler, follows it.
-}
module H2Py.Inspection.QSortDC (
  tests,
  storableQsortDC,
  storableQsort,
) where

import Control.Concurrent.DivideConquer.Linear (qsort, qsortDC)
import Control.Monad.Borrow.BO (Mut)
import Control.Monad.Borrow.IO (BIO)
import Data.Functor.Linear (Traversable)
import Data.Vector.Generic qualified as GenericVector
import Data.Vector.Generic.Mutable qualified as Generic
import Data.Vector.Generic.Mutable.Linear.Borrow.Unrestricted qualified as Vector
import Data.Vector.Mutable qualified as Boxed
import H2Py.Buffer (SVector)
import Prelude.Linear
import System.Random (RandomGen, StdGen)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.ExpectedFailure (expectFailBecause)
import Test.Tasty.Inspection

{- | The showcase kernel as @sortBody@ of the example module calls it: the
scheduler's @qsortDC@ at a 'Storable' @Double@ vector, in 'BIO', at the
lifetime of the borrow.
@qsortDC@ is @INLINE@, so a @SPECIALIZE@ pragma would be ignored; the root
is what the inliner leaves at the concrete types.
-}
storableQsortDC ::
  StdGen ->
  Int ->
  Int ->
  Mut α (SVector Double) %1 ->
  BIO α (Mut α (SVector Double))
{-# NOINLINE storableQsortDC #-}
storableQsortDC = qsortDC

{-# SPECIALIZE qsort ::
  Word ->
  Mut α (SVector Double) %1 ->
  BIO α ()
  #-}

-- | The sequential leaf the scheduler runs below the threshold, at the same backend.
storableQsort ::
  Word ->
  Mut α (SVector Double) %1 ->
  BIO α ()
{-# NOINLINE storableQsort #-}
storableQsort = qsort

tests :: TestTree
tests =
  testGroup
    "qsortDC at Storable Double"
    [ expectFailBecause
        "divideAndConquer' has no INLINABLE pragma and no exported unfolding, so the root keeps the scheduler's Traversable Pair and RandomGen StdGen dictionaries; the workload itself is specialised ($s$wqsortDC')"
        $( inspectTest
             ( ( hasNoTypeClassesExcept
                   'storableQsortDC
                   [''GenericVector.Vector, ''Ord]
               )
                 { testName =
                     Just "qsortDC root retains only Vector and Ord dictionaries"
                 }
             )
         )
    , $( inspectTest
           ( ( hasNoTypeClassesExcept
                 'storableQsortDC
                 [''Traversable, ''RandomGen]
             )
               { testName =
                   Just "qsortDC root retains only the scheduler's Traversable and RandomGen dictionaries"
               }
           )
       )
    , $( inspectTest
           ( (hasNoType 'storableQsortDC ''Boxed.MVector)
               { testName =
                   Just "qsortDC root has no boxed-vector backing"
               }
           )
       )
    , $( inspectTest
           ( ( hasNoTypeClassesExcept
                 'storableQsort
                 [''GenericVector.Vector, ''Ord]
             )
               { testName =
                   Just "sequential leaf retains only Vector and Ord dictionaries"
               }
           )
       )
    , $( inspectTest
           ( (hasNoType 'storableQsort ''Boxed.MVector)
               { testName =
                   Just "sequential leaf has no boxed-vector backing"
               }
           )
       )
    , $( inspectTest
           ( ( doesNotUseAnyOf
                 'storableQsort
                 [ 'qsort
                 , 'Vector.unsafeGet
                 , 'Vector.unsafeSwap
                 , 'Generic.unsafeRead
                 , 'Generic.unsafeSwap
                 , 'Generic.unsafeWrite
                 , 'Generic.basicUnsafeRead
                 , 'Generic.basicUnsafeWrite
                 ]
             )
               { testName =
                   Just "sequential leaf contains no listed generic-vector operations"
               }
           )
       )
    ]
