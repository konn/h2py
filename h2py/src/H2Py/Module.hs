{- |
Registration of functions, methods and modules, and the module description
that the stub renders.
See sections 5.4 and 5.11 of the design.
Most users reach this through the splices of "H2Py.TH".
-}
module H2Py.Module (
  -- * Descriptions
  ModuleDesc (..),
  ClassDesc (..),
  FunctionDesc (..),
  ParamDesc (..),
  ExceptionDesc (..),
  renderStubs,
  checkStubs,

  -- * The call boundary
  FromArg (..),
  ToResult (..),
  PyCallable (..),
  PyMethod (..),
  Detached (..),

  -- * Options
  FunctionOptions (..),
  defaultFunctionOptions,
) where

import H2Py.Module.Internal
