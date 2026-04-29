-- | The PurerlTidalWS adapter.
-- |
-- | Replaces Atelier's three compile-and-run adapters with a single
-- | one-shot WebSocket round-trip into a running purerl-tidal at
-- | ws://localhost:3012/ws. Each cell evaluation: open WS, send the
-- | cell text as a single frame, await one reply frame, close.
-- |
-- | Wire shape returned to `Compile.compile` matches the existing
-- | `BuildResult` codec so the rest of the pipeline keeps decoding
-- | cleanly. ERR replies populate `errors`; OK replies leave them
-- | empty. The raw reply is stashed in an extra `reply` field that
-- | the codec ignores during decode but a future Tidal-shaped
-- | response type can pick up. Step 4 swaps the wire format for
-- | something Tidal-native.
module Calypso.Server.Adapter.PurerlTidalWS
  ( purerlTidalWs
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Effect.Exception (Error)

import Calypso.Server.Adapter (Adapter)

foreign import sendCellImpl
  :: String
  -> (Error -> Effect Unit)
  -> (Json -> Effect Unit)
  -> Effect Unit

sendCell :: String -> Aff Json
sendCell cellText = makeAff \resolve -> do
  sendCellImpl cellText
    (\err -> resolve (Left err))
    (\json -> resolve (Right json))
  pure nonCanceler

purerlTidalWs :: Adapter
purerlTidalWs =
  { name: "purerl-tidal-ws"
  -- The Adapter contract is `workspaceDir -> packageName -> userSrc -> mainSrc`.
  -- For Tidal we ignore the workspace/package args (no compile workspace)
  -- and treat `userSrc` as the cell text to forward verbatim. `mainSrc`
  -- is unused. Step 4 will introduce a Tidal-native contract that
  -- doesn't carry these compile-shaped arguments.
  , bundle: \_ _ userSrc _ -> sendCell userSrc
  }
