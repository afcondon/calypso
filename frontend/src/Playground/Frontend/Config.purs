module Playground.Frontend.Config
  ( backendUrl
  , wsBackendUrl
  , nowMs
  , readHideParam
  , writeHideParam
  ) where

import Prelude
import Effect (Effect)

-- | The backend's origin, resolved from `window.location.hostname` so
-- | the same bundle works locally (`localhost`) and across Tailscale
-- | (an MacOS host's tailnet hostname or 100.x.y.z address). Port is
-- | still 3050.
foreign import backendUrl :: String

-- | The WS origin, mirroring `backendUrl` but with `ws://` / `wss://`
-- | per page protocol. Subscribers open `<wsBackendUrl>/session/ws`.
foreign import wsBackendUrl :: String

-- | ms since epoch.
foreign import nowMs :: Effect Number

-- | Read the `?hide=...` query param. Empty string if absent. Callers
-- | parse the comma-separated list of column names.
foreign import readHideParam :: Effect String

-- | Replace the `?hide=` query param in the current URL via
-- | `history.replaceState` — no navigation. Empty string removes the
-- | param.
foreign import writeHideParam :: String -> Effect Unit
