{- |
The @Py@ world: code that may touch CPython, and the delimiters that run it.

@'Py' π γ a@ is a 'BIO' computation with two indices: @π@, the scope of its
Python references, and @γ@, the ordinary borrow lifetime; see section 5.1 of
the design.
-}
module H2Py.Py (
  -- * The world
  Python,
  Py,

  -- * Delimiters
  attach,
  attach_,
  attach',
  attach'_,
  detach,
  parPy,
  parBIO,

  -- * Exceptions raised by the delimiters
  NotAttached (..),
  AttachRefused (..),
  DetachRestoreRefused (..),
) where

import H2Py.Py.Internal
