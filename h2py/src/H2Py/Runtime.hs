{- |
The runtime: attachment checks and the opaque foreign types.
The trampoline itself lives in "H2Py.Module.Internal" and is reachable only
through the registration machinery.
-}
module H2Py.Runtime (
  PyObject,
  PyTypeObject,
  isAttached,
) where

import H2Py.Runtime.Internal
