-- | The controller layer of the four-family architecture
-- | (emitter / modifier / destination / controller).  A `Controller` is
-- | a declarative binding from a hardware surface's knobs and buttons
-- | to named scalars on the BEAM-side live-control bus.
-- |
-- | Today: Midifighter Twister, knobs only.  The pump opens the device
-- | over Web MIDI, parses incoming CC frames via
-- | `Calypso.Frontend.Controller.Twister`, and writes each turn to the
-- | bus via the existing `set-control <name> <value>` text verb on the
-- | purerl-tidal WebSocket.  Cell code that calls `live "rene.len"`
-- | (etc.) sees the result on the next clock tick.
-- |
-- | The pump opens its **own** WebSocket directly to purerl-tidal at
-- | `ws://localhost:3012/ws` rather than reusing Calypso server's
-- | session WS (`/session/ws` on :3060), because Calypso server
-- | interprets WS frames (pen / proposals / cells) and doesn't relay
-- | arbitrary text to BEAM.  Direct connection also keeps the
-- | controller layer independent of session state — knob turns aren't
-- | gated by pen ownership.
module Calypso.Frontend.Controller
  ( Controller(..)
  , KnobBinding
  , KnobEntry
  , midiController
  , knob
  , subscribeTwister
  ) where

import Prelude

import Calypso.Frontend.Controller.Twister
  (TwisterMsg(..), parseTwisterMsg)
import Calypso.Frontend.WebMIDI as MIDI
import Calypso.Frontend.WsClient (WebSocket)
import Calypso.Frontend.WsClient as WsClient
import Data.Int (toNumber)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console as Console

-- | A configured hardware controller.  `knobs` is keyed by encoder
-- | index (0..15 for a Twister); future controllers with non-numeric
-- | surfaces will lift this to a richer key.
newtype Controller = Controller
  { deviceName :: String
  , knobs :: Map Int KnobBinding
  }

-- | What one knob does: writes to `controlName` on the live-control
-- | bus, scaling the raw 0..127 CC value linearly into `outMin..outMax`.
type KnobBinding =
  { controlName :: String
  , outMin :: Number
  , outMax :: Number
  }

-- | The shape returned by the `knob` smart constructor — captures the
-- | knob's index alongside its binding so `midiController` can build
-- | the `Map Int KnobBinding` from a flat array literal at the
-- | declaration site.
type KnobEntry =
  { idx :: Int
  , name :: String
  , outMin :: Number
  , outMax :: Number
  }

-- | One knob binding for use inside a `midiController` declaration.
-- |
-- |     knob 0 "rene.len" 50.0 800.0
-- |
-- | reads as: "encoder 0 drives the named scalar `rene.len`, scaling
-- | the Twister's 0..127 range to 50..800 ms."  CC values outside
-- | 0..127 (none from real hardware) are still scaled linearly with
-- | no clamping — keeps the math trivial and reversible.
knob :: Int -> String -> Number -> Number -> KnobEntry
knob idx name outMin outMax = { idx, name, outMin, outMax }

-- | Build a `Controller` from a device name + a flat array of knob
-- | entries.  The device name must match exactly what WebMIDI reports
-- | for the hardware (e.g. `"Midi Fighter Twister"`, spaces and all).
midiController :: String -> Array KnobEntry -> Controller
midiController deviceName entries = Controller
  { deviceName
  , knobs: Map.fromFoldable
      (map (\e -> Tuple e.idx
                    { controlName: e.name
                    , outMin: e.outMin
                    , outMax: e.outMax
                    })
           entries)
  }

-- | Where to send the `set-control` frames.  Hardcoded to localhost
-- | for the prototype — the rig is single-machine.  Lift to config
-- | when the multi-host story matters.
beamWsUrl :: String
beamWsUrl = "ws://localhost:3012/ws"

-- | Subscribe to a controller's hardware events and forward them to the
-- | live-control bus.
-- |
-- | Opens a direct WebSocket to purerl-tidal (separate from Calypso's
-- | session WS), asks the browser for WebMIDI access (the user is
-- | prompted on first run), looks up the controller's input port by
-- | name, attaches an `onmidimessage` handler that parses each frame
-- | as a `TwisterMsg`, maps `EncoderTurn idx val` events through the
-- | configured knob binding, and writes the scaled value to BEAM via
-- | the `set-control` text verb.
-- |
-- | Failures are logged to the browser console rather than thrown —
-- | the controller layer is best-effort: a missing device or a closed
-- | BEAM shouldn't block the rest of Calypso from coming up.  Frames
-- | sent before the BEAM WS finishes its handshake are silently
-- | dropped by `WsClient.send`, so there's no race to manage on init.
subscribeTwister :: Controller -> Aff Unit
subscribeTwister (Controller cfg) = do
  liftEffect $ Console.log "Controller: requesting WebMIDI access…"
  access <- MIDI.requestMIDIAccess
  liftEffect do
    Console.log "Controller: WebMIDI access granted"
    Console.log $ "Controller: connecting to BEAM at " <> beamWsUrl
    ws <- WsClient.connect beamWsUrl
      { onOpen: Console.log "Controller: BEAM WS open"
      , onMessage: \resp -> Console.log $ "Controller: BEAM ← " <> resp
      , onClose: \_ _ -> Console.warn "Controller: BEAM WS closed"
      , onError: Console.warn "Controller: BEAM WS error"
      }
    mInput <- MIDI.openInputByName access cfg.deviceName
    case mInput of
      Nothing -> do
        ports <- MIDI.getInputs access
        Console.warn $
          "Controller: input '" <> cfg.deviceName
            <> "' not found.  Visible inputs: "
            <> show (map _.name ports)
      Just input -> do
        Console.log $ "Controller: subscribed to '" <> cfg.deviceName <> "'"
        _ <- MIDI.onMessage input (handleBytes ws cfg.knobs)
        pure unit

handleBytes :: WebSocket -> Map Int KnobBinding -> Array Int -> Effect Unit
handleBytes ws knobs bytes = case parseTwisterMsg bytes of
  Nothing -> pure unit
  Just msg -> case msg of
    EncoderTurn idx val -> case Map.lookup idx knobs of
      Nothing ->
        -- Knob has no binding — log once so unbound knobs are visible
        -- in DevTools without spamming (one line per turn is acceptable
        -- for the prototype).  Trim later if the noise gets old.
        Console.log $
          "Twister knob " <> show idx <> " (unbound, val=" <> show val <> ")"
      Just k -> do
        let scaled = scaleValue k.outMin k.outMax val
            frame = "set-control " <> k.controlName <> " " <> show scaled
        Console.log $ "Twister knob " <> show idx <> " → " <> frame
        WsClient.send ws frame
    _ -> pure unit

-- | Linear 0..127 → outMin..outMax.  Values outside the input range
-- | (which shouldn't happen on real hardware) are passed through with
-- | the same affine map — no clamping.
scaleValue :: Number -> Number -> Int -> Number
scaleValue outMin outMax val =
  outMin + (outMax - outMin) * (toNumber val / 127.0)
