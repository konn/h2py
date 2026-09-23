{- |
Trusted escape hatches of the @Py@ world.

Every use is a proof obligation: the world protocol, an attachment held for the
whole scope on a bound thread and an arena established before and swept after,
is the caller's to establish.
-}
module H2Py.Py.Unsafe (
  unsafePyIO,
  unsafePyArena,
  unsafeRunPy,
  withFreshScope,
  checkAttached,
) where

import H2Py.Py.Internal
