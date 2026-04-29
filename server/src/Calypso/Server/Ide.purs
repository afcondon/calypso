-- | Stub IDE-query module. Atelier ran a `purs ide` subprocess and
-- | proxied type / completion / search queries through it. Calypso's
-- | session content is Tidal text, not PureScript — there's no IDE
-- | sidecar. The handlers in `Main.purs` for /ide/* still call into
-- | these functions, so we keep them on the type surface but always
-- | return empty results. A future cleanup pass deletes the /ide/*
-- | routes entirely and removes this module.
module Calypso.Server.Ide
  ( queryType
  , queryComplete
  , querySearch
  ) where

import Prelude

import Effect.Aff (Aff)

import Calypso.Session (IdeHit)

queryType :: String -> Aff (Array IdeHit)
queryType _ = pure []

queryComplete :: String -> Aff (Array IdeHit)
queryComplete _ = pure []

querySearch :: String -> Aff (Array IdeHit)
querySearch _ = pure []
