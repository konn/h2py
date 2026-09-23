{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Item 3 of the design: upcast between worlds.
-- BO' has a nominal role on its world, so the incoherent Coercible instance
-- cannot turn a Py computation into a BIO one.
-- EXPECT: Couldn't match type
-- EXPECT: Python
-- EXPECT: RealWorld
module UpcastLaundersWorld where

import Control.Monad.Borrow.IO (BIO)
import Control.Monad.Borrow.Pure (upcast)
import H2Py

badLaunder :: forall π γ a. Py π γ a %1 -> BIO γ a
badLaunder = upcast
