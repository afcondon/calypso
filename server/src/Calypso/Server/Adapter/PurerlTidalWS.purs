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
  , sendCell
  , TidalReply
  ) where

import Prelude

import Data.Argonaut.Core (Json, toBoolean, toObject, toString) as AJ
import Data.Argonaut.Core (Json)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Effect.Exception (Error, error) as Exn
import Effect.Exception (Error)
import Foreign.Object as Object

import Calypso.Server.Adapter (Adapter)

-- | Tidal-shaped reply from the daemon. `ok` reflects the heuristic in
-- | the FFI (text starting with "ERR"/"ERROR" → ok=false). `reply` is
-- | the daemon's full reply line, verbatim.
type TidalReply = { ok :: Boolean, reply :: String }

foreign import sendCellImpl
  :: String
  -> (Error -> Effect Unit)
  -> (Json -> Effect Unit)
  -> Effect Unit

-- | Send a cell to purerl-tidal, get back a typed reply. Preferred over
-- | the Adapter wrapper for new code — no BundleOutcome shape-fitting.
sendCell :: String -> Aff TidalReply
sendCell cellText = makeAff \resolve -> do
  sendCellImpl cellText
    (\err -> resolve (Left err))
    (\json -> case decodeReply json of
        Nothing ->
          resolve (Left (Exn.error "PurerlTidalWS FFI returned malformed JSON"))
        Just r ->
          resolve (Right r))
  pure nonCanceler
  where
  decodeReply :: Json -> Maybe TidalReply
  decodeReply json = do
    obj <- AJ.toObject json
    okJson <- Object.lookup "ok" obj
    replyJson <- Object.lookup "reply" obj
    ok <- AJ.toBoolean okJson
    reply <- AJ.toString replyJson
    pure { ok, reply }

-- | Legacy Adapter-shaped wrapper. Returns the FFI's raw Json so
-- | `Compile.compile`'s BuildResult decoder can handle it. Kept while
-- | the old compile pipeline is still in tree; once step 4 strips
-- | Compile.purs, this can go away and only `sendCell` remains.
purerlTidalWs :: Adapter
purerlTidalWs =
  { name: "purerl-tidal-ws"
  , bundle: \_ _ userSrc _ -> sendCellRaw userSrc
  }
  where
  sendCellRaw :: String -> Aff Json
  sendCellRaw cellText = makeAff \resolve -> do
    sendCellImpl cellText
      (\err -> resolve (Left err))
      (\json -> resolve (Right json))
    pure nonCanceler
