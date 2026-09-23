{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Section 5.4 of the design, as amended in the implementation notes (15):
-- `& detached` marks a BO or BIO body to run with the interpreter released;
-- a Py body needs the attachment it would give up, so marking one is a type
-- error, raised by the Unsatisfiable instance the pymethods splice reaches.
-- EXPECT: detached: a Py body cannot run with the interpreter released
module DetachedPyMethod where

import Control.Functor.Linear qualified as Control
import Control.Monad.Borrow.Pure (Share, coerceShare)
import Data.Function ((&))
import Data.Ref.Linear (Ref)
import Data.Ref.Linear.Borrow qualified as RefB
import H2Py
import Prelude.Linear hiding ((&))

newtype Payload = Payload (Ref Int)
  deriving newtype (Consumable)

pyclass ''Payload

-- | A Py body: it may touch the interpreter, so it cannot run detached.
payloadGet :: Share π Payload -> Py π π Int
payloadGet p = Control.do
  n <- RefB.copyRef (coerceShare @(Ref Int) p)
  Control.pure n

pymethods ''Payload [method "get" 'payloadGet & detached]
