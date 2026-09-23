{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Item 12 of the design: runPar in a Py computation, through the Par
-- applicative whose instance needs Forkable.
-- EXPECT: parBO cannot run inside Py
module RunParInPy where

import Control.Monad.Borrow.Pure (runPar)
import Data.Functor.Linear qualified as Data
import H2Py

badRunPar :: forall π γ. Py π γ ()
badRunPar = runPar (Data.pure ())
