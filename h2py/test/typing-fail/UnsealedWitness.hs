{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Note [Sealed classes] of H2Py.Object.Internal: a hand-written PyClass
-- instance outside the trusted modules cannot define pyClassSealed, because
-- the witness's only constructor is exported by H2Py.Object.Unsafe alone.
-- Left undefined, the method compiles with a warning and fails at the first
-- use (test_errors.py checks that); written down, it does not compile.
-- EXPECT: not in scope
-- EXPECT: UnsafeSealed
module UnsealedWitness where

import Data.Ref.Linear (Ref)
import H2Py
import H2Py.Module.Internal (unsafeNewTypeCell)
import Prelude.Linear

newtype Forged = Forged (Ref Int)
  deriving newtype (Consumable)

instance PyClass Forged where
  pyClassName _ = "Forged"
  pyClassTypeCell _ = unsafeNewTypeCell
  pyClassSealed _ = UnsafeSealed
