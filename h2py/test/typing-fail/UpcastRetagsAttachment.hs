{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Item 3 of the design: upcast between attachment lifetimes.
-- The `Mut α a <: Mut β b` instance needs `α >= β`, and nothing relates two
-- unrelated attachments; upcast never looks at its dictionary, so the
-- refusal is checked at compile time rather than through a deferred error.
-- EXPECT: No instance for
-- EXPECT: <=!!
-- EXPECT: arising from a use of ‘upcast’
module UpcastRetagsAttachment where

import Control.Monad.Borrow.Pure (upcast)
import H2Py

badHandleAttachment :: forall π π'. Bound π PyAny %1 -> Bound π' PyAny
badHandleAttachment = upcast

badViewAttachment :: forall π π'. Borrowed π PyAny %1 -> Borrowed π' PyAny
badViewAttachment = upcast
