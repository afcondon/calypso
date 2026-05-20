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
  , ControllerMeta
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
import Data.Array as Array
import Data.Foldable (traverse_)
import Data.Int (toNumber)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console as Console

-- | A configured (Controller, Controllable) pairing — the data shape
-- | for one possible attachment of a hardware surface to a machine.
-- |
-- | Each pairing carries its own metadata (which machine it controls,
-- | what colour the LEDs glow, a human-readable label) so the UI can
-- | render and the LED-feedback path can re-paint when the active
-- | pairing changes.  Multiple Controllers can share a `deviceName`
-- | and differ only in `knobs` + metadata — that's the whole "this
-- | physical Twister is now bound to René instead of Grids" story.
newtype Controller = Controller
  { deviceName       :: String  -- CoreMIDI port name (e.g. "Midi Fighter Twister")
  , controllableName :: String  -- Studio export name (e.g. "studioRene") — wires UI claims
  , label            :: String  -- short human label for UI ("René", "Grids", "Repetitor")
  , color            :: Int     -- LED hue 0..127 — `0xB1 idx hue` on the Twister
  , knobs            :: Map Int KnobBinding
  }

-- | The metadata record passed to `midiController` — separated from
-- | the knob list so each binding's identity is declarative.
type ControllerMeta =
  { device       :: String
  , controllable :: String
  , label        :: String
  , color        :: Int
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

-- | Build a `Controller` from a metadata record + a flat array of knob
-- | entries.  The device name must match exactly what WebMIDI reports
-- | for the hardware (e.g. `"Midi Fighter Twister"`, spaces and all).
-- |
-- |     twisterRene = midiController
-- |       { device:       "Midi Fighter Twister"
-- |       , controllable: "studioRene"
-- |       , label:        "René"
-- |       , color:        0     -- red hue
-- |       }
-- |       [ knob 0 "rene.note0" 36.0 51.0, … ]
midiController :: ControllerMeta -> Array KnobEntry -> Controller
midiController meta entries = Controller
  { deviceName:       meta.device
  , controllableName: meta.controllable
  , label:            meta.label
  , color:            meta.color
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
-- | live-control bus.  Pairings are dispatched **per hardware bank** —
-- | the Twister's 4 banks send CCs in contiguous ranges (Bank 1 = CC
-- | 0..15, Bank 2 = 16..31, Bank 3 = 32..47, Bank 4 = 48..63), so we
-- | compute `bank = cc / 16, knob = cc mod 16` and look up the
-- | matching pairing in the bindings array.
-- |
-- | The user switches pairings by pressing the Twister's hardware bank
-- | button.  No software state to track — every event is self-
-- | describing.  The Twister also re-paints its own LED bank colours
-- | per bank, so visual confirmation of the switch is free.
-- |
-- | Opens a direct WebSocket to purerl-tidal (separate from Calypso's
-- | session WS — see [[reference_calypso_server_not_beam_proxy]]).
-- | Asks the browser for WebMIDI access (one-time permission prompt),
-- | looks up the input port by name, and dispatches each EncoderTurn.
-- |
-- | Failures are logged to the browser console rather than thrown —
-- | the controller layer is best-effort.  Frames sent before the BEAM
-- | WS finishes its handshake are silently dropped by `WsClient.send`.
subscribeTwister :: Array Controller -> Aff Unit
subscribeTwister bindings = case Array.head bindings of
  Nothing -> liftEffect $ Console.warn "Controller: no bindings declared, pump is a no-op"
  Just (Controller initial) -> do
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
      mInput <- MIDI.openInputByName access initial.deviceName
      case mInput of
        Nothing -> do
          ports <- MIDI.getInputs access
          Console.warn $
            "Controller: input '" <> initial.deviceName
              <> "' not found.  Visible inputs: "
              <> show (map _.name ports)
        Just input -> do
          Console.log $
            "Controller: subscribed to '" <> initial.deviceName <> "'."
          logBankLayout bindings
          _ <- MIDI.onMessage input (handleBytes ws bindings)
          pure unit

-- | Print the bank → pairing layout at subscribe time so the user can
-- | check which Twister bank gives which machine without reaching for
-- | source.
logBankLayout :: Array Controller -> Effect Unit
logBankLayout bindings = traverse_ Console.log
  (Array.mapWithIndex describeBank bindings)
  where
    describeBank i (Controller cfg) =
      "  Bank " <> show (i + 1) <> ": '" <> cfg.label
        <> "' → " <> cfg.controllableName

handleBytes :: WebSocket -> Array Controller -> Array Int -> Effect Unit
handleBytes ws bindings bytes = case parseTwisterMsg bytes of
  Nothing -> pure unit
  Just (EncoderTurn cc val) -> do
    let bank    = cc / 16
        knobIdx = cc `mod` 16
    case Array.index bindings bank of
      Nothing ->
        Console.log $
          "Twister Bank " <> show (bank + 1) <> ", knob " <> show knobIdx
            <> " — no pairing for this bank (CC " <> show cc <> ", val=" <> show val <> ")"
      Just (Controller cfg) -> case Map.lookup knobIdx cfg.knobs of
        Nothing ->
          Console.log $
            "Twister Bank " <> show (bank + 1) <> " ('" <> cfg.label
              <> "'), knob " <> show knobIdx <> " (unbound, val=" <> show val <> ")"
        Just k -> do
          let scaled = scaleValue k.outMin k.outMax val
              frame  = "set-control " <> k.controlName <> " " <> show scaled
          Console.log $
            "Twister Bank " <> show (bank + 1) <> " ('" <> cfg.label
              <> "'), knob " <> show knobIdx <> " → " <> frame
          WsClient.send ws frame
  Just _ -> pure unit  -- presses/releases/side buttons unused for now

-- | Linear 0..127 → outMin..outMax.  Values outside the input range
-- | (which shouldn't happen on real hardware) are passed through with
-- | the same affine map — no clamping.
scaleValue :: Number -> Number -> Int -> Number
scaleValue outMin outMax val =
  outMin + (outMax - outMin) * (toNumber val / 127.0)
