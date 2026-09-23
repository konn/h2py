{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- Section 5.7 of the design: a shared view is unrestricted, so any number of
-- scopes may be open over it, and releasing it early from user code would
-- invalidate the others; the release belongs to the arena sweep alone, and
-- H2Py.Buffer does not export releaseBufferShare.
-- EXPECT: does not export
-- EXPECT: releaseBufferShare
module ReleaseBufferShareHidden where

import H2Py
import H2Py.Buffer (BufferShare, releaseBufferShare)

badRelease :: forall π e. BufferShare π e -> Py π π ()
badRelease = releaseBufferShare
