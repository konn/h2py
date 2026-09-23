{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Item 16 of the design: pyclass on a parameterised payload type.
-- A payload with a type parameter would let a stored reference's attachment
-- unify with a later call's, so the splice refuses it with the closedness
-- message before generating any instance.
-- EXPECT: has type parameters
-- EXPECT: payload types must be closed
module PyclassParameterised where

import Data.Ref.Linear (Ref)
import H2Py
import Prelude.Linear

newtype Box a = Box (Ref a)
  deriving newtype (Consumable)

pyclass ''Box
