{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Item 3 of the design: upcast between PyRef tags.
-- The incoherent `Coercible a b => a <: b` instance reaches PyRef, whose tag
-- role is nominal; upcast never looks at its dictionary, so this refusal is
-- checked at compile time rather than through a deferred error.
-- EXPECT: Couldn't match type
-- EXPECT: PyLong
-- EXPECT: PyStr
module UpcastRetagsTag where

import Control.Monad.Borrow.Pure (upcast)
import H2Py

badRetag :: forall π. Bound π PyLong %1 -> Bound π PyStr
badRetag = upcast
