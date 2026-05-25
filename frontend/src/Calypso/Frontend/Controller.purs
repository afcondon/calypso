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
  , BinaryBank(..)
  , BinaryBindings
  , midiController
  , knob
  , sweepCells
  , subscribeTwister
  ) where

import Prelude

import Calypso.Frontend.Controller.Twister
  (TwisterMsg(..), SideBtn, parseTwisterMsg)
import Calypso.Frontend.WebMIDI as MIDI
import Calypso.Frontend.WsClient (WebSocket)
import Calypso.Frontend.WsClient as WsClient
import Data.Array as Array
import Data.Foldable (traverse_)
import Data.Int (round, toNumber)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Ref (Ref)
import Effect.Ref as Ref

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
-- | `defaultValue` is the value the substrate seeds local bus state with
-- | at subscribe time — it should match the session's `liveXxxArrayOr`
-- | read-side fallback so the rings paint with each parameter's
-- | audible default on first bank entry.
type KnobBinding =
  { controlName  :: String
  , outMin       :: Number
  , outMax       :: Number
  , defaultValue :: Number
  }

-- | The shape returned by the `knob` smart constructor — captures the
-- | knob's index alongside its binding so `midiController` can build
-- | the `Map Int KnobBinding` from a flat array literal at the
-- | declaration site.
type KnobEntry =
  { idx          :: Int
  , name         :: String
  , outMin       :: Number
  , outMax       :: Number
  , defaultValue :: Number
  }

-- | One knob binding for use inside a `midiController` declaration.
-- |
-- |     knob 0 "rene.len" 50.0 800.0 200.0
-- |
-- | reads as: "encoder 0 drives the named scalar `rene.len`, scaling
-- | the Twister's 0..127 range to 50..800 ms, with an initial seed
-- | of 200.0."  The seed should match the session's `liveOr` /
-- | `liveIntOr` / `liveNumberArrayOr` read-side fallback so the
-- | rings paint accurately before any knob has been touched.
-- | CC values outside 0..127 (none from real hardware) are still
-- | scaled linearly with no clamping — keeps the math trivial and
-- | reversible.
knob :: Int -> String -> Number -> Number -> Number -> KnobEntry
knob idx name outMin outMax defaultValue =
  { idx, name, outMin, outMax, defaultValue }

-- | A side-button-bank (spec §10 "Binary-bank archetype") — entered
-- | by pressing a side-button rather than a knob.  In Binary-bank
-- | mode, knob-turn is ignored and knob-press toggles the boolean at
-- | `<controlPrefix><knobIdx>` on the live-control bus.
-- |
-- | Each Binary-bank addresses one 16-cell boolean array; the
-- | substrate sweeps cells `<prefix>0`..`<prefix>15` just like
-- | `sweepCells` does for rotary Cell-banks, but the dispatch verb is
-- | press-to-toggle rather than turn-to-set.
-- |
-- | Three Binary-banks are wired by Slab 6.6 (R-top Gate, R-middle
-- | Skip, R-bottom Glide); the remaining side-buttons stay open or
-- | get other verbs (Slab 6.4 binds L-bottom to voice-select, a
-- | distinct non-Binary-bank gesture).
newtype BinaryBank = BinaryBank
  { controlPrefix :: String  -- bus key prefix, e.g. "odonus.gate"
  , label         :: String  -- short label, e.g. "Gate"
  , color         :: Int     -- LED hue for the 16 rings while active
  , defaultOn     :: Boolean -- audible default: true seeds 1.0, false 0.0
  }

-- | The (side-button → Binary-bank) table.  Sparse — `Map.lookup`
-- | returns `Nothing` for side-buttons without an assigned bank.
type BinaryBindings = Map SideBtn BinaryBank

-- | Macro for the common case: a 4×4 grid of knobs sweeping the cells
-- | of a single 16-element array on the live-control bus.  Generates
-- | 16 KnobEntries named `<prefix>0`..`<prefix>15`, matching the
-- | naming convention `liveIntArrayOr` / `liveBoolArrayOr` use to
-- | spread an array across the bus.
-- |
-- |     midiController { ... } (sweepCells "rene.note" 36.0 51.0 60.0)
-- |
-- | is equivalent to writing 16 individual `knob N "rene.noteN" 36.0
-- | 51.0 60.0` lines.  Use this whenever a Twister page represents
-- | one indexed array — Odonus's `notes` / `skip` / `ratchet` /
-- | `probability`, René's `notes` / `skip`, future vmod cell arrays.
-- |
-- | The prefix is the bus key prefix without the trailing digit.  The
-- | cell index N becomes the literal suffix `0`..`15` so what the
-- | engine reads via `liveIntArrayOr defaults prefix` matches what
-- | the Twister writes via `set-control <prefix><N> <value>`.  All
-- | 16 cells share the same default — typically the same value the
-- | session passes to `liveIntArrayOr (replicate16 X) prefix`.
sweepCells :: String -> Number -> Number -> Number -> Array KnobEntry
sweepCells prefix outMin outMax defaultValue =
  map (\i -> knob i (prefix <> show i) outMin outMax defaultValue)
      (Array.range 0 15)

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
                    { controlName:  e.name
                    , outMin:       e.outMin
                    , outMax:       e.outMax
                    , defaultValue: e.defaultValue
                    })
           entries)
  }

-- | Where to send the `set-control` frames.  Hardcoded to localhost
-- | for the prototype — the rig is single-machine.  Lift to config
-- | when the multi-host story matters.
beamWsUrl :: String
beamWsUrl = "ws://localhost:3012/ws"

-- | Subscribe to a controller's hardware events and forward them to the
-- | live-control bus.  The MFT Twister has **no dedicated hardware bank
-- | buttons** (those exist on Midifighter 3D/Pro variants only); the
-- | canonical bank-select gesture on this hardware is **pressing a
-- | knob**.  Up to 16 virtual banks total — bank N is entered by
-- | pressing knob N.
-- |
-- | `bindings` is a sparse array of length up-to-16: index N holds
-- | `Just controller` if pressing knob N should switch to that bank,
-- | `Nothing` otherwise.  The pump's initial bank is the first
-- | non-`Nothing` slot (defaults to 0 if all empty — pump is a
-- | no-op).
-- |
-- | Knob turns dispatch through whatever bank is currently active.
-- | Empty banks (knob press to `Nothing` slot) are logged and
-- | ignored — current bank stays where it was.
-- |
-- | Opens a direct WebSocket to purerl-tidal (separate from Calypso's
-- | session WS — see [[reference_calypso_server_not_beam_proxy]]).
-- | Asks the browser for WebMIDI access (one-time permission prompt),
-- | looks up the input + output ports by name, and dispatches each event.
-- |
-- | **LED feedback (Slab 6.5b)**: the pump tracks a `Ref (Map String
-- | Number)` of bus values it has written and repaints the Twister's
-- | 16 rings on every bank switch.  Each ring's fill (0..127, 11 LED
-- | segments) is the inverse-scaled stored value for that bank's
-- | knob — unbound knobs in the new bank paint to 0 (dark).  No
-- | external bus changes are observed yet; that's a future slab.
-- |
-- | Failures are logged to the browser console rather than thrown —
-- | the controller layer is best-effort.  Frames sent before the BEAM
-- | WS finishes its handshake are silently dropped by `WsClient.send`.
subscribeTwister
  :: Array (Maybe Controller)
  -> BinaryBindings
  -> Aff Unit
subscribeTwister rotaryBindings binaryBindings = case firstBank rotaryBindings of
  Nothing -> liftEffect $ Console.warn
    "Controller: no banks declared, pump is a no-op"
  Just (Tuple initialIdx (Controller initial)) -> do
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
      mOutput <- MIDI.openOutputByName access initial.deviceName
      case mOutput of
        Nothing -> do
          ports <- MIDI.getOutputs access
          Console.warn $
            "Controller: output '" <> initial.deviceName
              <> "' not found — LED feedback disabled.  Visible outputs: "
              <> show (map _.name ports)
        Just _ -> Console.log $
          "Controller: opened output '" <> initial.deviceName
            <> "' for LED feedback"
      case mInput of
        Nothing -> do
          ports <- MIDI.getInputs access
          Console.warn $
            "Controller: input '" <> initial.deviceName
              <> "' not found.  Visible inputs: "
              <> show (map _.name ports)
        Just input -> do
          currentBank   <- Ref.new initialIdx
          currentBinary <- Ref.new (Nothing :: Maybe SideBtn)
          busState      <- Ref.new
                             (seedBusState rotaryBindings binaryBindings)
          Console.log $
            "Controller: subscribed to '" <> initial.deviceName <> "'."
          Console.log $
            "Controller: initial bank " <> show initialIdx
              <> " ('" <> initial.label <> "')"
          logBankLayout rotaryBindings
          logBinaryLayout binaryBindings
          -- Paint the initial bank's rings from the empty state — every
          -- ring will be dark until knobs are touched.  Establishes the
          -- "the rings are mine" handshake with the Twister firmware.
          paintBank mOutput rotaryBindings busState initialIdx
          _ <- MIDI.onMessage input
                 (handleBytes ws mOutput rotaryBindings binaryBindings
                              currentBank currentBinary busState)
          pure unit

-- | Seed `busState` from each bank's declared defaults so the rings
-- | paint accurately before any knob has been touched.  Rotary defaults
-- | come from each `KnobBinding.defaultValue`; binary defaults sweep
-- | the prefix's 16 cells with 1.0 (if `defaultOn`) or 0.0.  Each
-- | declared default should match the session's `liveXxxArrayOr` read-
-- | side fallback for the same bus key — Bindings.purs owns that
-- | coupling.
seedBusState
  :: Array (Maybe Controller)
  -> BinaryBindings
  -> Map String Number
seedBusState rotaryBindings binaryBindings =
  Map.fromFoldable
    (Array.concatMap rotaryEntries rotaryBindings
       <> Array.concatMap binaryEntries
            (Map.values binaryBindings # Array.fromFoldable))
  where
  rotaryEntries :: Maybe Controller -> Array (Tuple String Number)
  rotaryEntries = case _ of
    Nothing -> []
    Just (Controller cfg) ->
      map (\(Tuple _ kb) -> Tuple kb.controlName kb.defaultValue)
          (Map.toUnfoldable cfg.knobs :: Array (Tuple Int KnobBinding))

  binaryEntries :: BinaryBank -> Array (Tuple String Number)
  binaryEntries (BinaryBank bb) =
    let v = if bb.defaultOn then 1.0 else 0.0
    in map (\i -> Tuple (bb.controlPrefix <> show i) v)
           (Array.range 0 15)

-- | The first slot in `bindings` that holds a Controller, paired with
-- | its index.  Used to pick the initial bank and to read the shared
-- | device name.  Returns Nothing if every slot is Nothing.
firstBank :: Array (Maybe Controller) -> Maybe (Tuple Int Controller)
firstBank bindings =
  Array.head
    (Array.mapMaybe identity
       (Array.mapWithIndex (\i mc -> map (Tuple i) mc) bindings))

-- | Print the (knob-press → bank) layout at subscribe time so the user
-- | can check which knob enters which machine without reaching for
-- | source.  Empty slots are elided.
logBankLayout :: Array (Maybe Controller) -> Effect Unit
logBankLayout bindings = traverse_ Console.log
  (Array.mapMaybe identity
     (Array.mapWithIndex describeBank bindings))
  where
    describeBank i = case _ of
      Nothing -> Nothing
      Just (Controller cfg) -> Just $
        "  Bank " <> show i <> " (press knob " <> show i <> "): '"
          <> cfg.label <> "' → " <> cfg.controllableName

handleBytes
  :: WebSocket
  -> Maybe MIDI.MIDIOutput
  -> Array (Maybe Controller)
  -> BinaryBindings
  -> Ref Int
  -> Ref (Maybe SideBtn)
  -> Ref (Map String Number)
  -> Array Int
  -> Effect Unit
handleBytes ws mOutput rotaryBindings binaryBindings
            currentBank currentBinary busState bytes =
  case parseTwisterMsg bytes of
  Nothing -> Console.log $
    "Twister: unrecognised MIDI frame " <> show bytes

  -- Knob-press: in Binary-bank mode → toggle cell; otherwise → bank switch.
  Just (EncoderPress idx) -> do
    binary <- Ref.read currentBinary
    case binary of
      Just sb -> case Map.lookup sb binaryBindings of
        Nothing -> pure unit  -- shouldn't happen — we entered via a valid binding
        Just bb -> toggleBinaryCell ws mOutput bb busState idx
      Nothing -> case Array.index rotaryBindings idx of
        Just (Just (Controller cfg)) -> do
          Ref.write idx currentBank
          Console.log $
            "Twister: bank → " <> show idx <> " ('" <> cfg.label <> "')"
          -- Repaint all 16 rings from the bus values we've written so
          -- far.  The Twister firmware doesn't keep cross-bank state;
          -- without this the rings would still show the previous
          -- bank's positions.
          paintBank mOutput rotaryBindings busState idx
        _ ->
          Console.log $
            "Twister: knob " <> show idx
              <> " pressed but no bank declared at that slot; staying put."

  -- Knob-turn: in Binary-bank mode → ignored; otherwise → forward to bus.
  Just (EncoderTurn cc val) -> do
    binary <- Ref.read currentBinary
    case binary of
      Just sb -> case Map.lookup sb binaryBindings of
        Nothing -> pure unit
        Just (BinaryBank bb) ->
          Console.log $
            "Twister Binary " <> bb.label <> ", knob " <> show cc
              <> " turn ignored (val=" <> show val <> ")"
      Nothing -> do
        bank <- Ref.read currentBank
        case Array.index rotaryBindings bank of
          Just (Just (Controller cfg)) -> case Map.lookup cc cfg.knobs of
            Nothing ->
              Console.log $
                "Twister Bank " <> show bank <> " ('" <> cfg.label
                  <> "'), knob " <> show cc
                  <> " (unbound, val=" <> show val <> ")"
            Just k -> do
              let scaled = scaleValue k.outMin k.outMax val
                  frame  = "set-control " <> k.controlName <> " " <> show scaled
              Console.log $
                "Twister Bank " <> show bank <> " ('" <> cfg.label
                  <> "'), knob " <> show cc <> " → " <> frame
              WsClient.send ws frame
              -- Mirror the just-written value into local state.  The
              -- Twister firmware self-paints the ring at the turned
              -- knob's own position, so we don't repaint here — only
              -- on bank switch.  Storing the value lets the next
              -- paintBank produce the right fill if the user comes
              -- back to this bank later.
              Ref.modify_ (Map.insert k.controlName scaled) busState
          _ ->
            Console.log $
              "Twister: knob " <> show cc
                <> " turned but current bank " <> show bank
                <> " is empty (val=" <> show val <> ")"

  -- Side-button-press: enter / exit / switch Binary-bank mode.
  Just (SideButtonPress sb) -> case Map.lookup sb binaryBindings of
    Nothing ->
      Console.log $
        "Twister: side-button " <> show sb <> " not assigned"
    Just bb@(BinaryBank b) -> do
      current <- Ref.read currentBinary
      case current of
        Just sameSb | sameSb == sb -> do
          -- Same side-button → exit, restore rotary bank.
          Ref.write Nothing currentBinary
          rotIdx <- Ref.read currentBank
          Console.log $
            "Twister: exit binary " <> b.label
              <> " → rotary bank " <> show rotIdx
          paintBank mOutput rotaryBindings busState rotIdx
        _ -> do
          -- Different side-button (or coming from rotary) → enter / switch.
          Ref.write (Just sb) currentBinary
          Console.log $ "Twister: binary bank → " <> b.label
          paintBinaryBank mOutput bb busState

  Just _ -> pure unit  -- encoder/side-button releases unused

-- | Print the (side-button → Binary-bank) layout at subscribe time.
-- | Silent if `binaryBindings` is empty.
logBinaryLayout :: BinaryBindings -> Effect Unit
logBinaryLayout binaryBindings = traverse_ describe pairs
  where
  pairs :: Array (Tuple SideBtn BinaryBank)
  pairs = Map.toUnfoldable binaryBindings
  describe (Tuple sb (BinaryBank b)) = Console.log $
    "  Side-button " <> show sb <> " → Binary '" <> b.label
      <> "' (prefix " <> b.controlPrefix <> ")"

-- | Toggle one cell of a Binary-bank.  Reads the current value of
-- | `<prefix><idx>` from local bus state, writes its boolean inverse
-- | (0.0 ↔ 1.0) back to the bus, mirrors locally, and repaints just
-- | that ring's fill (the bank's tint is already in place from the
-- | binary-bank entry paint).
-- |
-- | Convention: values > 0.5 read as `true`.  Matches
-- | `Tidal.LiveControl.liveBoolOr` which treats any non-zero number
-- | as true.
toggleBinaryCell
  :: WebSocket
  -> Maybe MIDI.MIDIOutput
  -> BinaryBank
  -> Ref (Map String Number)
  -> Int
  -> Effect Unit
toggleBinaryCell ws mOutput (BinaryBank bb) busState idx = do
  bus <- Ref.read busState
  let cellName = bb.controlPrefix <> show idx
      current  = fromMaybe 0.0 (Map.lookup cellName bus)
      newVal   = if current > 0.5 then 0.0 else 1.0
      frame    = "set-control " <> cellName <> " " <> show newVal
  Console.log $
    "Twister Binary '" <> bb.label <> "', cell " <> show idx
      <> " → " <> frame
  WsClient.send ws frame
  Ref.modify_ (Map.insert cellName newVal) busState
  -- Repaint this ring's fill — bank tint stays from the entry paint.
  case mOutput of
    Nothing -> pure unit
    Just output ->
      MIDI.sendMessage output
        [ 0xB0, idx, if newVal > 0.5 then 127 else 0 ]

-- | Repaint all 16 rings for a Binary-bank.  All rings tint to the
-- | bank's hue (so the user sees the mode shift); each ring's fill is
-- | binary: 127 if the bus value is non-zero, 0 otherwise.  Unset
-- | cells read as 0 (dark) — the substrate doesn't know the session's
-- | actual defaults until something has touched them.
paintBinaryBank
  :: Maybe MIDI.MIDIOutput
  -> BinaryBank
  -> Ref (Map String Number)
  -> Effect Unit
paintBinaryBank mOutput (BinaryBank bb) busState = case mOutput of
  Nothing -> pure unit
  Just output -> do
    bus <- Ref.read busState
    traverse_ (paintCell output bus) (Array.range 0 15)
  where
  paintCell output bus idx = do
    let cellName = bb.controlPrefix <> show idx
        value    = fromMaybe 0.0 (Map.lookup cellName bus)
        fill     = if value > 0.5 then 127 else 0
    MIDI.sendMessage output [ 0xB1, idx, bb.color ]
    MIDI.sendMessage output [ 0xB0, idx, fill ]

-- | Repaint all 16 rings on the Twister to match the bus values stored
-- | in `busState` for the given bank's knob bindings.  Unbound knobs in
-- | the new bank paint to 0 (dark).  No-op if the output port wasn't
-- | opened (LED feedback disabled — pump still works for writes).
-- |
-- | Each ring gets two CC frames (PWYF protocol; verified against the
-- | rig in `producing-with-your-feet/src/Component/App.purs`):
-- |
-- |   * `0xB1 idx hue`  — RGB color override.  All 16 rings in this
-- |     bank tint to `cfg.color`, so the user sees an immediate
-- |     bank-wide colour shift on press.  The bank-home indicator
-- |     (spec §8.3) is implicit in the user's own gesture — *"I just
-- |     pressed knob 5, all rings turned light-blue → I'm in Mod2."*
-- |     MFT classic lacks a separate indicator LED above each knob,
-- |     so this is the cleanest mapping of the spec onto the hardware.
-- |   * `0xB0 idx fill` — ring-fill segments (11 steps linear over
-- |     0..127).  Reflects each cell's stored value reverse-scaled
-- |     through that knob's `outMin..outMax`.
paintBank
  :: Maybe MIDI.MIDIOutput
  -> Array (Maybe Controller)
  -> Ref (Map String Number)
  -> Int
  -> Effect Unit
paintBank mOutput bindings busState bankIdx = case mOutput of
  Nothing -> pure unit
  Just output -> case Array.index bindings bankIdx of
    Just (Just (Controller cfg)) -> do
      bus <- Ref.read busState
      traverse_ (paintOneRing output cfg.color cfg.knobs bus)
                (Array.range 0 15)
    _ -> pure unit  -- empty bank — leave rings as the firmware has them
  where
  paintOneRing output color knobs bus knobIdx = do
    let fill = case Map.lookup knobIdx knobs of
          Nothing -> 0  -- unbound knob in this bank → dark
          Just k ->
            let stored = fromMaybe k.outMin (Map.lookup k.controlName bus)
            in inverseScale k.outMin k.outMax stored
    MIDI.sendMessage output [ 0xB1, knobIdx, color ]
    MIDI.sendMessage output [ 0xB0, knobIdx, fill ]

-- | Linear 0..127 → outMin..outMax.  Values outside the input range
-- | (which shouldn't happen on real hardware) are passed through with
-- | the same affine map — no clamping.
scaleValue :: Number -> Number -> Int -> Number
scaleValue outMin outMax val =
  outMin + (outMax - outMin) * (toNumber val / 127.0)

-- | Inverse of `scaleValue` — outMin..outMax → 0..127 byte for ring
-- | fill.  Clamps to 0..127 because off-range stored values (a future
-- | external bus write outside the knob's declared range) shouldn't
-- | crash the paint.  When outMin equals outMax the knob is degenerate
-- | and we paint at the floor.
inverseScale :: Number -> Number -> Number -> Int
inverseScale outMin outMax value
  | outMax == outMin = 0
  | otherwise =
      let raw = round ((value - outMin) / (outMax - outMin) * 127.0)
      in if raw < 0 then 0 else if raw > 127 then 127 else raw
