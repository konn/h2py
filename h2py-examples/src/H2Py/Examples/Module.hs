{-# LANGUAGE TemplateHaskell #-}

{- | The example module: @h2py_examples@, with its submodules @nparallel@,
@shapes@, @concurrency@, @ops@ and @tutorial@.

The tutorial's @Counter@ shares its Haskell name with "H2Py.Examples.Counter"'s;
the splice resolves each class's registration by the module the class name
carries, so the tutorial module is imported qualified as itself.
-}
module H2Py.Examples.Module (
  h2py_hs_init_h2py_examples,
) where

import Data.Function ((&))
import H2Py
import H2Py.Examples.Concurrency
import H2Py.Examples.Counter
import H2Py.Examples.NParallel (nparallelSpec)
import H2Py.Examples.Ops (h2py_class_Base, h2py_class_Cell, h2py_class_Helper, opsModule)
import H2Py.Examples.Shapes
import H2Py.Examples.Tutorial (tutorialSpec)
import H2Py.Examples.Tutorial qualified

pymoduleWith
  (moduleSpec "h2py_examples" [fn "add" 'add & param 0 "x" & param 1 "y" & doc "Add two integers."] [''Counter])
    { msDoc = "H2Py's example module."
    , msSubmodules =
        [ nparallelSpec
        , submodule "shapes" [] [''Vec2, ''Stack, ''Samples, ''Named, ''Child]
        , concurrencySpec
        , opsModule
        , tutorialSpec
        ]
    }
