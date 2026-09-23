{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Item 9 of the design: two derefMut through one Bound.
-- The handle is linear, so the second dereference is a multiplicity error,
-- which GHC never defers.
-- EXPECT: Couldn't match type
-- EXPECT: Many
-- EXPECT: One
-- EXPECT: arising from multiplicity of
module TwoDerefMut where

import Control.Functor.Linear qualified as Control
import Data.Ref.Linear (Ref)
import H2Py
import H2Py.Module.Internal (unsafeNewTypeCell)
import Prelude.Linear

newtype Payload = Payload (Ref Int)
  deriving newtype (Consumable)

instance PyClass Payload where
  pyClassName _ = "Payload"
  pyClassTypeCell _ = unsafeNewTypeCell

badTwoDerefMut :: forall π. Bound π Payload %1 -> Py π π ()
badTwoDerefMut b = Control.do
  first <- derefMut b
  second <- derefMut b
  Control.pure (consume first `lseq` consume second)
