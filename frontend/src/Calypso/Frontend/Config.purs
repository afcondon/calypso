module Calypso.Frontend.Config
  ( backendUrl
  , wsBackendUrl
  , nowMs
  , readHideParam
  , writeHideParam
  , prettyPrintJson
  , formatNumber
  ) where

import Prelude
import Effect (Effect)

-- | The backend's origin, resolved from `window.location.hostname` so
-- | the same bundle works locally (`localhost`) and across Tailscale
-- | (a Mac host's tailnet hostname or 100.x.y.z address).  Backend
-- | listens on :3060.
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

-- | Pretty-print a JSON string with 2-space indentation.  Falls back
-- | to the input verbatim if the string isn't parseable as JSON.
foreign import prettyPrintJson :: String -> String

-- | Format a Number using JS's native `String(n)` — produces "120"
-- | for 120.0, "119.5" for fractional, etc.  PureScript's `show` on
-- | Number emits scientific notation in purerl, which doesn't apply
-- | here (browser side) but the same convenient short form is what
-- | a user wants to see.
foreign import formatNumber :: Number -> String
