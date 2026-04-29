-- | Tiny FFI to Node's crypto.createHash for SHA-1.  Used to
-- | content-stamp source bodies so a Proposal's `basedOn` can be
-- | validated against the live source at acceptance time.
module Calypso.Server.Hash
  ( sha1Hex
  ) where

import Effect (Effect)

foreign import sha1Hex :: String -> Effect String
