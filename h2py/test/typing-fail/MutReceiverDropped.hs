{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Item 9 of the design: a Mut receiver dropped without consume.
-- The dereferenced payload is a linear borrow; a wildcard pattern discards it,
-- which is a multiplicity error.
-- EXPECT: Couldn't match type
-- EXPECT: Many
-- EXPECT: One
-- EXPECT: arising from a non-linear pattern
module MutReceiverDropped where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.Pure (Mut)
import Data.Ref.Linear (Ref)
import H2Py
import H2Py.Module.Internal (unsafeNewTypeCell)
import Prelude.Linear

newtype Payload = Payload (Ref Int)
  deriving newtype (Consumable)

instance PyClass Payload where
  pyClassName _ = "Payload"
  pyClassTypeCell _ = unsafeNewTypeCell

badDroppedReceiver :: forall π. Mut π Payload %1 -> Int -> Py π π ()
badDroppedReceiver _ _ = Control.pure ()
