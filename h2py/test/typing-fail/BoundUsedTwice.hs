{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Item 9 of the design: a Bound used twice, here shared and then returned.
-- A handle that has been shared cannot be used again: multiplicity error.
-- EXPECT: Couldn't match type
-- EXPECT: Many
-- EXPECT: One
-- EXPECT: arising from multiplicity of
module BoundUsedTwice where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.Pure (share)
import H2Py
import Prelude.Linear

badBoundUsedTwice :: forall π. Bound π PyAny %1 -> Py π π (PyResult (Bound π PyAny))
badBoundUsedTwice b = case share b of
  Ur v -> Control.do
    r <- getAttr v "x"
    Control.pure (consume r `lseq` Right (asAnyMut b))
