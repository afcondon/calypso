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
  , KnobScale(..)
  , ControllerMeta
  , BinaryBank(..)
  , BinaryBindings
  , DashboardBank(..)
  , DashboardBindings
  , PressToggle
  , KnobStepBank
  , midiController
  , knob
  , knobExp
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
import Data.Number (log, pow) as Math
import Data.String (Pattern(..)) as String
import Data.String (indexOf) as String
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

-- | How a knob's raw 0..127 CC value maps to the bus value.
-- |
-- |   * `Linear` — affine over `[outMin, outMax]` (the original
-- |     behaviour).  Knob centre = midpoint of the range, knob full-
-- |     CCW = outMin, full-CW = outMax.  Use for transposition, ratchet,
-- |     velocity, mod, range-start/end, direction floor-encoding.
-- |   * `Exponential` — geometric over `[outMin, outMax]` (both must
-- |     be positive).  Knob centre = geometric mean √(outMin·outMax),
-- |     so e.g. outMin=1/32 / outMax=32 puts knob centre at 1.0 with
-- |     equal travel for "slower" and "faster".  Musical-rate idiom.
data KnobScale = Linear | Exponential

derive instance eqKnobScale :: Eq KnobScale

-- | What one knob does: writes to `controlName` on the live-control
-- | bus, scaling the raw 0..127 CC value into `outMin..outMax` per
-- | `scaleMode`.  `defaultValue` is the value the substrate seeds
-- | local bus state with at subscribe time — it should match the
-- | session's `liveXxxArrayOr` read-side fallback so the rings paint
-- | with each parameter's audible default on first bank entry.
type KnobBinding =
  { controlName  :: String
  , outMin       :: Number
  , outMax       :: Number
  , defaultValue :: Number
  , scaleMode    :: KnobScale
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
  , scaleMode    :: KnobScale
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
  { idx, name, outMin, outMax, defaultValue, scaleMode: Linear }

-- | Exponential-mapped knob.  Same signature as `knob` but the
-- | 0..127 → outMin..outMax mapping is geometric.  Both bounds must
-- | be strictly positive — Exponential is undefined for zero / negative.
-- | Best for clock-relative rates (speed multipliers) where you want
-- | equal-feeling travel for "half-time" and "double-time".
knobExp :: Int -> String -> Number -> Number -> Number -> KnobEntry
knobExp idx name outMin outMax defaultValue =
  { idx, name, outMin, outMax, defaultValue, scaleMode: Exponential }

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

-- | One knob's press-to-toggle behaviour inside a Dashboard-bank.
-- |   * `busKey` — the full bus key to flip (e.g. "odonus.mute2").
-- |   * `inverted` — when `true`, the LED paint flips: bus value > 0.5
-- |     paints dark and ≤ 0.5 paints full.  Useful for params that are
-- |     stored as "muted = true" but should *display* as "active = full".
type PressToggle =
  { busKey   :: String
  , inverted :: Boolean
  }

-- | A side-button-bank that exposes a 4×4 dashboard of mixed-mode knobs
-- | (spec §10 "Dashboard-bank" archetype, Slab 6.6c).  Unlike Binary-
-- | banks where every knob does the same thing, each knob in a
-- | Dashboard-bank can have its own continuous turn-binding *and/or*
-- | press-toggle behaviour:
-- |
-- |   * Knobs with an entry in `knobs` dispatch their turn through the
-- |     KnobBinding (continuous CC writes to the bus, same shape as
-- |     a rotary Cell-bank knob).
-- |   * Knobs with an entry in `pressToggles` flip the boolean at
-- |     `<prefix>` (already includes the cell idx — the toggle target
-- |     is the full bus key, not a prefix).
-- |   * Knobs not present in either map are no-ops on turn / press.
-- |
-- | Used for the Four-voice Fugue mode (L-top) where columns are
-- | playheads and rows are per-playhead parameters.  Pressing the same
-- | side-button again exits back to the previous rotary bank, identical
-- | to Binary-bank exit semantics.
-- | One knob's stepped-rotate behaviour inside a Dashboard-bank.  N
-- | positions map to N WS verbs (e.g. 7 scale-selector positions →
-- | clear-scale + 6 set-scale verbs).  `trackKey` is a busState slot
-- | used only to detect position-change crossings — it isn't read by
-- | any voice on the BEAM side.
type KnobStepBank =
  { trackKey :: String
  , verbs    :: Array String
  }

newtype DashboardBank = DashboardBank
  { label         :: String
  , color         :: Int                   -- LED hue for the 16 rings
  , knobs         :: Map Int KnobBinding   -- continuous-turn per knob
  , pressToggles  :: Map Int PressToggle   -- knob idx → boolean toggle
  , pressCommands :: Map Int String        -- knob idx → one-shot WS verb
  , knobSteps     :: Map Int KnobStepBank  -- knob idx → stepped WS verb
  }

-- | The (side-button → Dashboard-bank) table.  Sparse.  A given side-
-- | button can be in either `BinaryBindings` or `DashboardBindings`,
-- | not both — the dispatch resolves binary first, then dashboard.
type DashboardBindings = Map SideBtn DashboardBank

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

-- | Update midiController to thread scaleMode through.
mkKnobBinding :: KnobEntry -> KnobBinding
mkKnobBinding e =
  { controlName:  e.name
  , outMin:       e.outMin
  , outMax:       e.outMax
  , defaultValue: e.defaultValue
  , scaleMode:    e.scaleMode
  }

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
      (map (\e -> Tuple e.idx (mkKnobBinding e)) entries)
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
  -> DashboardBindings
  -> Aff Unit
subscribeTwister rotaryBindings binaryBindings dashboardBindings =
  case firstBank rotaryBindings of
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
          currentBank      <- Ref.new initialIdx
          currentBinary    <- Ref.new (Nothing :: Maybe SideBtn)
          currentDashboard <- Ref.new (Nothing :: Maybe SideBtn)
          busState         <- Ref.new
                                (seedBusState rotaryBindings binaryBindings
                                              dashboardBindings)
          Console.log $
            "Controller: subscribed to '" <> initial.deviceName <> "'."
          Console.log $
            "Controller: initial bank " <> show initialIdx
              <> " ('" <> initial.label <> "')"
          logBankLayout rotaryBindings
          logBinaryLayout binaryBindings
          logDashboardLayout dashboardBindings
          -- Paint the initial bank's rings from the empty state — every
          -- ring will be dark until knobs are touched.  Establishes the
          -- "the rings are mine" handshake with the Twister firmware.
          paintBank mOutput rotaryBindings busState initialIdx
          _ <- MIDI.onMessage input
                 (handleBytes ws mOutput
                              rotaryBindings binaryBindings dashboardBindings
                              currentBank currentBinary currentDashboard
                              busState)
          pure unit

-- | Seed `busState` from each bank's declared defaults so the rings
-- | paint accurately before any knob has been touched.  Rotary defaults
-- | come from each `KnobBinding.defaultValue`; binary defaults sweep
-- | the prefix's 16 cells with 1.0 (if `defaultOn`) or 0.0; dashboard
-- | defaults come from each knob's continuous default (rotary-style)
-- | and each press-toggle defaults to 0 (off) — sessions wanting a
-- | non-zero seed for a dashboard toggle should declare it in their
-- | reader-side fallback (the substrate doesn't know default mute
-- | states the way it knows continuous defaults).  Each declared
-- | default should match the session's `liveXxxArrayOr` read-side
-- | fallback for the same bus key — Bindings.purs owns that coupling.
seedBusState
  :: Array (Maybe Controller)
  -> BinaryBindings
  -> DashboardBindings
  -> Map String Number
seedBusState rotaryBindings binaryBindings dashboardBindings =
  Map.fromFoldable
    (Array.concatMap rotaryEntries rotaryBindings
       <> Array.concatMap binaryEntries
            (Map.values binaryBindings # Array.fromFoldable)
       <> Array.concatMap dashboardEntries
            (Map.values dashboardBindings # Array.fromFoldable))
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

  dashboardEntries :: DashboardBank -> Array (Tuple String Number)
  dashboardEntries (DashboardBank db) =
       map (\(Tuple _ kb) -> Tuple kb.controlName kb.defaultValue)
           (Map.toUnfoldable db.knobs :: Array (Tuple Int KnobBinding))

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
  -> DashboardBindings
  -> Ref Int
  -> Ref (Maybe SideBtn)
  -> Ref (Maybe SideBtn)
  -> Ref (Map String Number)
  -> Array Int
  -> Effect Unit
handleBytes ws mOutput rotaryBindings binaryBindings dashboardBindings
            currentBank currentBinary currentDashboard busState bytes =
  case parseTwisterMsg bytes of
  Nothing -> Console.log $
    "Twister: unrecognised MIDI frame " <> show bytes

  Just (EncoderPress idx) -> do
    binary    <- Ref.read currentBinary
    dashboard <- Ref.read currentDashboard
    case binary of
      Just sb -> case Map.lookup sb binaryBindings of
        Nothing -> pure unit
        Just bb -> toggleBinaryCell ws mOutput bb busState idx
      Nothing -> case dashboard of
        Just sb -> case Map.lookup sb dashboardBindings of
          Nothing -> pure unit
          Just db -> dashboardKnobPress ws mOutput
                       rotaryBindings binaryBindings dashboardBindings
                       db busState idx
        Nothing -> case Array.index rotaryBindings idx of
          Just (Just (Controller cfg)) -> do
            Ref.write idx currentBank
            Console.log $
              "Twister: bank → " <> show idx <> " ('" <> cfg.label <> "')"
            paintBank mOutput rotaryBindings busState idx
          _ ->
            Console.log $
              "Twister: knob " <> show idx
                <> " pressed but no bank declared at that slot; staying put."

  Just (EncoderTurn cc val) -> do
    binary    <- Ref.read currentBinary
    dashboard <- Ref.read currentDashboard
    case binary of
      Just sb -> case Map.lookup sb binaryBindings of
        Nothing -> pure unit
        Just (BinaryBank bb) ->
          Console.log $
            "Twister Binary " <> bb.label <> ", knob " <> show cc
              <> " turn ignored (val=" <> show val <> ")"
      Nothing -> case dashboard of
        Just sb -> case Map.lookup sb dashboardBindings of
          Nothing -> pure unit
          Just db -> dashboardKnobTurn ws mOutput db busState cc val
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
                let scaled = scaleValueMode k.scaleMode k.outMin k.outMax val
                    frame  = "set-control " <> k.controlName <> " " <> show scaled
                Console.log $
                  "Twister Bank " <> show bank <> " ('" <> cfg.label
                    <> "'), knob " <> show cc <> " → " <> frame
                WsClient.send ws frame
                Ref.modify_ (Map.insert k.controlName scaled) busState
            _ ->
              Console.log $
                "Twister: knob " <> show cc
                  <> " turned but current bank " <> show bank
                  <> " is empty (val=" <> show val <> ")"

  -- Side-button-press: resolve binary first, then dashboard; the same
  -- side-button currently active exits back to rotary.
  Just (SideButtonPress sb) -> do
    binary    <- Ref.read currentBinary
    dashboard <- Ref.read currentDashboard
    case binary of
      Just activeSb | activeSb == sb -> do
        -- Exit binary mode → return to rotary bank.
        Ref.write Nothing currentBinary
        rotIdx <- Ref.read currentBank
        case Map.lookup sb binaryBindings of
          Just (BinaryBank b) ->
            Console.log $
              "Twister: exit binary " <> b.label
                <> " → rotary bank " <> show rotIdx
          _ -> pure unit
        paintBank mOutput rotaryBindings busState rotIdx
      _ -> case dashboard of
        Just activeSb | activeSb == sb -> do
          -- Exit dashboard → return to rotary.
          Ref.write Nothing currentDashboard
          rotIdx <- Ref.read currentBank
          case Map.lookup sb dashboardBindings of
            Just (DashboardBank d) ->
              Console.log $
                "Twister: exit dashboard " <> d.label
                  <> " → rotary bank " <> show rotIdx
            _ -> pure unit
          paintBank mOutput rotaryBindings busState rotIdx
        _ -> case Map.lookup sb binaryBindings of
          Just bb@(BinaryBank b) -> do
            -- Switch from rotary / other binary / other dashboard → binary.
            Ref.write (Just sb) currentBinary
            Ref.write Nothing currentDashboard
            Console.log $ "Twister: binary bank → " <> b.label
            paintBinaryBank mOutput bb busState
          Nothing -> case Map.lookup sb dashboardBindings of
            Just db@(DashboardBank d) -> do
              Ref.write (Just sb) currentDashboard
              Ref.write Nothing currentBinary
              Console.log $ "Twister: dashboard → " <> d.label
              paintDashboardBank mOutput db busState
            Nothing ->
              Console.log $
                "Twister: side-button " <> show sb <> " not assigned"

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

-- | Print the (side-button → Dashboard-bank) layout at subscribe time.
logDashboardLayout :: DashboardBindings -> Effect Unit
logDashboardLayout dashboardBindings = traverse_ describe pairs
  where
  pairs :: Array (Tuple SideBtn DashboardBank)
  pairs = Map.toUnfoldable dashboardBindings
  describe (Tuple sb (DashboardBank d)) = Console.log $
    "  Side-button " <> show sb <> " → Dashboard '" <> d.label <> "'"

-- | Knob-turn inside a Dashboard-bank.  Dispatch order: stepped knob
-- | (`knobSteps`) wins, then continuous knob (`knobs`).  A knob can
-- | live in both — the stepped binding takes priority for the rotation,
-- | while `pressCommands` / `pressToggles` still handle press separately.
-- | Knobs with no entry anywhere are no-ops on turn.
dashboardKnobTurn
  :: WebSocket
  -> Maybe MIDI.MIDIOutput
  -> DashboardBank
  -> Ref (Map String Number)
  -> Int
  -> Int
  -> Effect Unit
dashboardKnobTurn ws mOutput (DashboardBank db) busState cc val =
  case Map.lookup cc db.knobSteps of
    Just sb -> do
      bus <- Ref.read busState
      let n        = Array.length sb.verbs
          newSlot  = clampSlot n ((val * n) / 128)
          oldSlot  = case Map.lookup sb.trackKey bus of
                       Just v -> round v
                       Nothing -> -1
      when (newSlot /= oldSlot) do
        case Array.index sb.verbs newSlot of
          Nothing -> pure unit
          Just verb -> do
            Console.log $
              "Twister Dashboard '" <> db.label <> "', knob "
                <> show cc <> " step " <> show newSlot
                <> " → " <> verb
            WsClient.send ws verb
            Ref.modify_ (Map.insert sb.trackKey (toNumber newSlot))
                         busState
            let fill = if n > 1
                         then (newSlot * 127) / (n - 1)
                         else 0
            case mOutput of
              Nothing -> pure unit
              Just output ->
                MIDI.sendMessage output [ 0xB0, cc, fill ]
    Nothing -> case Map.lookup cc db.knobs of
      Nothing ->
        Console.log $
          "Twister Dashboard '" <> db.label <> "', knob " <> show cc
            <> " turn ignored (val=" <> show val <> ")"
      Just k -> do
        let scaled = scaleValueMode k.scaleMode k.outMin k.outMax val
            frame  = "set-control " <> k.controlName <> " " <> show scaled
        Console.log $
          "Twister Dashboard '" <> db.label <> "', knob " <> show cc
            <> " → " <> frame
        WsClient.send ws frame
        Ref.modify_ (Map.insert k.controlName scaled) busState
  where
  clampSlot :: Int -> Int -> Int
  clampSlot n i = max 0 (min (n - 1) i)

-- | Knob-press inside a Dashboard-bank: if the knob has a press-toggle
-- | binding, flip the boolean at that bus key and repaint the ring's
-- | fill.  Otherwise no-op (only specific knobs — the enable row in
-- | fugue mode — toggle on press).
dashboardKnobPress
  :: WebSocket
  -> Maybe MIDI.MIDIOutput
  -> Array (Maybe Controller)
  -> BinaryBindings
  -> DashboardBindings
  -> DashboardBank
  -> Ref (Map String Number)
  -> Int
  -> Effect Unit
dashboardKnobPress ws mOutput rotaryBindings binaryBindings dashboardBindings
                   (DashboardBank db) busState idx =
  case Map.lookup idx db.pressCommands of
    Just verb -> do
      -- One-shot WS verb: send the literal string (e.g. "hush",
      -- "phase-resync") and flash the ring bright as visual feedback.
      -- No bus state to track; the next bank repaint settles the ring
      -- back to its baseline fill.
      Console.log $
        "Twister Dashboard '" <> db.label <> "', knob " <> show idx
          <> " command → " <> verb
      WsClient.send ws verb
      -- clear-controls mirrors the BEAM-side bus clear locally: empty
      -- the busState then re-seed bindings' defaults, so when the user
      -- enters Skip / Gate / Notes / etc. the LEDs reflect the freshly
      -- reset state rather than the stale pre-clear values.  Then
      -- repaint the current dashboard so its rings update immediately.
      --
      -- Preserve `odonus.mute*` keys (matches the BEAM-side preserve
      -- list).  Mute is a deliberate audible-performance gesture, not
      -- knob improv — un-muting a playhead and then pressing clear
      -- shouldn't re-silence it.
      when (verb == "clear-controls") do
        current <- Ref.read busState
        let seeded = seedBusState rotaryBindings
                                  binaryBindings
                                  dashboardBindings
            isMuteKey k = String.indexOf (String.Pattern "odonus.mute") k
                            == Just 0
            preservedMutes = Map.filterWithKey (\k _ -> isMuteKey k) current
            nonMute = Map.filterWithKey (\k _ -> not (isMuteKey k)) seeded
            combined = Map.union preservedMutes nonMute
        Ref.write combined busState
        paintDashboardBank mOutput (DashboardBank db) busState
      case mOutput of
        Nothing -> pure unit
        Just output ->
          MIDI.sendMessage output [ 0xB0, idx, 127 ]
    Nothing -> case Map.lookup idx db.pressToggles of
      Nothing ->
        Console.log $
          "Twister Dashboard '" <> db.label <> "', knob " <> show idx
            <> " press (no-op)"
      Just pt -> do
        bus <- Ref.read busState
        let current = fromMaybe 0.0 (Map.lookup pt.busKey bus)
            newVal  = if current > 0.5 then 0.0 else 1.0
            frame   = "set-control " <> pt.busKey <> " " <> show newVal
            isOn    = newVal > 0.5
            fill    = if isOn /= pt.inverted then 127 else 0
        Console.log $
          "Twister Dashboard '" <> db.label <> "', knob " <> show idx
            <> " toggle → " <> frame
        WsClient.send ws frame
        Ref.modify_ (Map.insert pt.busKey newVal) busState
        case mOutput of
          Nothing -> pure unit
          Just output ->
            MIDI.sendMessage output [ 0xB0, idx, fill ]

-- | Paint all 16 rings for a Dashboard-bank.  Tint to the bank's
-- | colour; fills come from the bus values — continuous knobs reverse-
-- | scale through their KnobBinding, toggle knobs render 0 or 127 from
-- | the bus's stored boolean.  Knobs not in either map paint dark.
paintDashboardBank
  :: Maybe MIDI.MIDIOutput
  -> DashboardBank
  -> Ref (Map String Number)
  -> Effect Unit
paintDashboardBank mOutput (DashboardBank db) busState = case mOutput of
  Nothing -> pure unit
  Just output -> do
    bus <- Ref.read busState
    traverse_ (paintCell output bus) (Array.range 0 15)
  where
  paintCell output bus idx = do
    let fill = case Map.lookup idx db.knobSteps of
          Just sb ->
            let n    = Array.length sb.verbs
                slot = case Map.lookup sb.trackKey bus of
                         Just v -> max 0 (min (n - 1) (round v))
                         Nothing -> 0
            in if n > 1 then (slot * 127) / (n - 1) else 0
          Nothing -> case Map.lookup idx db.knobs of
            Just k ->
              let stored = fromMaybe k.outMin (Map.lookup k.controlName bus)
              in inverseScaleMode k.scaleMode k.outMin k.outMax stored
            Nothing -> case Map.lookup idx db.pressToggles of
              Just pt ->
                let v    = fromMaybe 0.0 (Map.lookup pt.busKey bus)
                    isOn = v > 0.5
                in if isOn /= pt.inverted then 127 else 0
              Nothing -> case Map.lookup idx db.pressCommands of
                -- Command cells paint at a dim baseline so they're
                -- visibly present without reading as "active".
                Just _  -> 40
                Nothing -> 0
    MIDI.sendMessage output [ 0xB1, idx, db.color ]
    MIDI.sendMessage output [ 0xB0, idx, fill ]

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
            in inverseScaleMode k.scaleMode k.outMin k.outMax stored
    MIDI.sendMessage output [ 0xB1, knobIdx, color ]
    MIDI.sendMessage output [ 0xB0, knobIdx, fill ]

-- | 0..127 → outMin..outMax under the given KnobScale.
-- |
-- |   * Linear: affine map (the original behaviour).
-- |   * Exponential: geometric map outMin * (outMax/outMin)^(val/127).
-- |     Knob centre (val=64) lands near √(outMin·outMax) — for
-- |     outMin=1/32, outMax=32 that's ≈ 1.0.
scaleValueMode :: KnobScale -> Number -> Number -> Int -> Number
scaleValueMode Linear outMin outMax val =
  outMin + (outMax - outMin) * (toNumber val / 127.0)
scaleValueMode Exponential outMin outMax val =
  let t = toNumber val / 127.0
  in outMin * Math.pow (outMax / outMin) t

-- | Convenience wrapper for callers that don't have a KnobScale handy
-- | (legacy default — Linear).  New call sites should plumb scaleMode
-- | from the KnobBinding.
scaleValue :: Number -> Number -> Int -> Number
scaleValue = scaleValueMode Linear

-- | Inverse of `scaleValueMode` — outMin..outMax → 0..127 byte for
-- | ring fill.  Clamps to 0..127 because off-range stored values (a
-- | future external bus write outside the knob's declared range)
-- | shouldn't crash the paint.
inverseScaleMode :: KnobScale -> Number -> Number -> Number -> Int
inverseScaleMode Linear outMin outMax value
  | outMax == outMin = 0
  | otherwise =
      let raw = round ((value - outMin) / (outMax - outMin) * 127.0)
      in clamp01_127 raw
inverseScaleMode Exponential outMin outMax value
  | outMax == outMin = 0
  | otherwise =
      let ratio = value / outMin
          t = Math.log ratio / Math.log (outMax / outMin)
          raw = round (t * 127.0)
      in clamp01_127 raw

clamp01_127 :: Int -> Int
clamp01_127 raw
  | raw < 0   = 0
  | raw > 127 = 127
  | otherwise = raw

-- | Legacy Linear-only inverse (kept for any remaining callers).
inverseScale :: Number -> Number -> Number -> Int
inverseScale = inverseScaleMode Linear
