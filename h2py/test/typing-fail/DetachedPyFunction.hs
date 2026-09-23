{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Section 5.4 of the design, as amended in the implementation notes (15):
-- the module-level form of DetachedPyMethod, `fn … & detached` on a Py body,
-- refused by the same Unsatisfiable instance through the pymodule splice.
-- EXPECT: detached: a Py body cannot run with the interpreter released
module DetachedPyFunction where

import Control.Functor.Linear qualified as Control
import Data.Function ((&))
import H2Py
import Prelude.Linear hiding ((&))

-- | A Py body with an argument: still a Py body once the argument is bound.
double :: Int -> Py π π Int
double n = Control.pure (n + n)

pymodule "detached_function" [fn "double" 'double & detached] []
