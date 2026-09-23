{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Item 12 of the design: parBO in a Py computation.
-- Forkable (Python π) is Unsatisfiable, and Forkable dictionaries are erased,
-- so the refusal is checked at compile time; the message names the three
-- shapes that are right.
-- EXPECT: parBO cannot run inside Py
-- EXPECT: parPy
module ParBOInPy where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.Pure (parBO)
import H2Py

badParBO :: forall π γ. Py π γ ((), ())
badParBO = parBO (Control.pure ()) (Control.pure ())
