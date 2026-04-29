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
  ( sendCell
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

-- | Tidal-shaped reply from the daemon. `ok` reflects the heuristic in
-- | the FFI (text starting with "ERR"/"ERROR" → ok=false). `reply` is
-- | the daemon's full reply line, verbatim.
type TidalReply = { ok :: Boolean, reply :: String }

foreign import sendCellImpl
  :: String
  -> (Error -> Effect Unit)
  -> (Json -> Effect Unit)
  -> Effect Unit

-- | One-shot send: open WS to purerl-tidal, ship the cell text as one
-- | frame, await one reply frame, close. Aff bridges the FFI's two-
-- | callback shape into the standard error-or-result envelope.
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
