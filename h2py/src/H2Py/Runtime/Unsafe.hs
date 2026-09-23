{- |
The raw foreign imports of the shim and of the CPython limited API, for
library authors extending H2Py.
Every function that can run Python code is a safe foreign call; none may be
called from a thread that is not attached.
-}
module H2Py.Runtime.Unsafe (
  module H2Py.Runtime.Internal,
) where

import H2Py.Runtime.Internal
