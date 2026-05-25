-- | The fixed Twister surface — Slab 6.3 of the Thread-6 plan.
-- |
-- | Replaces the per-machine PoC bindings (twisterRene / twisterGrids /
-- | twisterRepetitor / twisterOdonusNotes / Skip / Ratchet) with the
-- | constant 16-bank surface described in
-- | `calypso/docs/twister-surface-spec-2026-05-25.md` §7.
-- |
-- | Knob 0 press always enters the Notes bank, knob 1 always Velocity,
-- | and so on through knob 12.  The user's "which knob is which" muscle
-- | memory is now portable across sessions: a session declares voices /
-- | heads / grids, never which knob does what.
-- |
-- | The 13 declared banks live in two archetypes (per spec §10):
-- |
-- |   * **Cell-banks** (0-7) — 16 active knobs, knob N sweeps cell N of
-- |     a 16-element grid array.  Knobs 0-7 cover notes / velocity /
-- |     probability / ratchet / mod1..mod4 on the current voice's grid.
-- |   * **Playhead-banks** (8-12) — first P knobs active, rest dark.
-- |     Pre-Slab 6.2 every voice is single-playhead (P=1), so only
-- |     knob 0 dispatches; knobs 1-15 in these banks are unbound and
-- |     log "unbound" on turn.  When Slab 6.2 lifts P, additional
-- |     knob entries appear.
-- |
-- | Banks 13-15 are intentionally `Nothing` and left for future
-- | assignment (spec §15 Q1 — scale-select / swing / clock-source-
-- | override are the candidates).
-- |
-- | Side-button-bank wiring (Gate / Skip / Glide on R-top/middle/bottom)
-- | is not part of this slab — see Slab 6.6.  Until then those side
-- | buttons are no-ops.
-- |
-- | Current-voice plumbing (Slab 6.4) hasn't landed either; this slab
-- | hardcodes the bus prefix to `odonus.*`, matching the convention
-- | used throughout `Sessions/*.purs` and Slab 6.1's TwisterOdonusDemo.
-- | Slab 6.4 will introduce a `currentVoice` Ref and rewrite the
-- | prefix at dispatch time.
module Calypso.Frontend.Controller.Bindings
  ( allBindings
  , binaryBindings
  , dashboardBindings
  ) where

import Prelude ((<>), (+), map, negate, show)
import Data.Array (range)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))

import Calypso.Frontend.Controller
  ( BinaryBank(..), BinaryBindings
  , DashboardBank(..), DashboardBindings, PressToggle, KnobStepBank
  , Controller, ControllerMeta
  , KnobScale(..)
  , knob, midiController, sweepCells
  )
import Calypso.Frontend.Controller.Twister (SideBtn(..))

-- | The (knob-press → bank) table.  16 slots, one per Twister knob;
-- | the substrate consumes this directly via `subscribeTwister`.
-- | Initial bank on subscribe is the first non-`Nothing` entry (knob 0,
-- | Notes).  Pressing an empty-slot knob is logged and ignored.
allBindings :: Array (Maybe Controller)
allBindings =
  --  Cell-banks (knob index = bank index 0-7).
  [ Just bankNotes        -- 0 — Notes
  , Just bankVelocity     -- 1 — Velocity
  , Just bankProbability  -- 2 — Probability
  , Just bankRatchet      -- 3 — Ratchet
  , Just bankMod1         -- 4 — Mod1
  , Just bankMod2         -- 5 — Mod2
  , Just bankMod3         -- 6 — Mod3
  , Just bankMod4         -- 7 — Mod4
  --  Playhead-banks (knob index = bank index 8-12).
  , Just bankDirection    -- 8 — Direction
  , Just bankSpeed        -- 9 — Speed
  , Just bankTransp       -- 10 — Transposition
  , Just bankRangeStart   -- 11 — Range-start
  , Just bankRangeEnd     -- 12 — Range-end
  --  Open slots (spec §15 Q1).
  , Nothing               -- 13
  , Nothing               -- 14
  , Nothing               -- 15
  ]

-- | The CoreMIDI port name — shared across every Twister bank.  The
-- | Twister substrate (`subscribeTwister`) reads only the first bank's
-- | device name for the WebMIDI open; the others are repeated for
-- | metadata uniformity.
twisterDevice :: String
twisterDevice = "Midi Fighter Twister"

-- | The voice prefix this slab writes to.  Hardcoded to `odonus` until
-- | Slab 6.4 introduces current-voice tracking.  All session conventions
-- | (`Sessions/*.purs` Odonus declarations) use this prefix.
voicePrefix :: String
voicePrefix = "odonus"

-- | Build the standard `ControllerMeta` for one Twister bank.  Every
-- | bank in this fixed surface points at the unified-sequencer
-- | controllable; only label + color differ.
bankMeta :: String -> Int -> ControllerMeta
bankMeta label color =
  { device:       twisterDevice
  , controllable: voicePrefix
  , label
  , color
  }

-- ---------------------------------------------------------------------------
-- Cell-banks (knobs 0-7) — sweepCells on the current voice's grid.
-- ---------------------------------------------------------------------------

-- | Notes bank.  Knob N → `odonus.noteN` over the four-octave piano
-- | range 36..84 (C2-C6).  Reader: `liveIntArrayOr defaults "odonus.note"`
-- | in Odonus session blocks.  Default seed 60 (middle C).
bankNotes :: Controller
bankNotes = midiController (bankMeta "Notes" 64)  -- bright green
  (sweepCells (voicePrefix <> ".note") 36.0 84.0 60.0)

-- | Velocity bank.  Knob N → `odonus.velN` over MIDI 0..127.  Reader:
-- | `liveIntArrayOr (replicate16 100) "odonus.vel"` — sampled per
-- | cell, fed into the MIDI emit by Slab 6.1.  Default seed 100.
bankVelocity :: Controller
bankVelocity = midiController (bankMeta "Velocity" 42)  -- yellow
  (sweepCells (voicePrefix <> ".vel") 0.0 127.0 100.0)

-- | Probability bank.  Knob N → `odonus.probabilityN` over 0.0..1.0.
-- | Continuous probability roll per step.  Reader:
-- | `liveNumberArrayOr (replicate16 1.0) "odonus.probability"`.
-- | Default seed 1.0 (always fire).
bankProbability :: Controller
bankProbability = midiController (bankMeta "Probability" 100)  -- magenta
  (sweepCells (voicePrefix <> ".probability") 0.0 1.0 1.0)

-- | Ratchet bank.  Knob N → `odonus.ratchetN` over 1..8 — full CCW is
-- | one emit (no retrigger), full CW is eight evenly-spaced sub-emits
-- | within the step's window.  Reader:
-- | `liveIntArrayOr (replicate16 1) "odonus.ratchet"`.  Engine clamps
-- | to ≥ 1.  Default seed 1 (one emit per step).
bankRatchet :: Controller
bankRatchet = midiController (bankMeta "Ratchet" 20)  -- orange
  (sweepCells (voicePrefix <> ".ratchet") 1.0 8.0 1.0)

-- | Mod1..Mod4 banks.  Knob N → `odonus.mod<K>.N` over CC range
-- | 0..127.  Slab 6.1 lifts mod1..mod4 onto the bus and into the
-- | snapshot; the per-rig CC translation layer (task #151) will
-- | eventually emit MIDI CCs for them.  Today these knobs write
-- | live values but the values aren't yet emitted as CCs.  Default
-- | seed 0 (no mod applied).
bankMod1 :: Controller
bankMod1 = midiController (bankMeta "Mod1" 85)   -- cyan
  (sweepCells (voicePrefix <> ".mod1.") 0.0 127.0 0.0)

bankMod2 :: Controller
bankMod2 = midiController (bankMeta "Mod2" 78)   -- light blue
  (sweepCells (voicePrefix <> ".mod2.") 0.0 127.0 0.0)

bankMod3 :: Controller
bankMod3 = midiController (bankMeta "Mod3" 75)   -- blue
  (sweepCells (voicePrefix <> ".mod3.") 0.0 127.0 0.0)

bankMod4 :: Controller
bankMod4 = midiController (bankMeta "Mod4" 110)  -- indigo
  (sweepCells (voicePrefix <> ".mod4.") 0.0 127.0 0.0)

-- ---------------------------------------------------------------------------
-- Playhead-banks (knobs 8-12) — sparse, P slots active.
--
-- Pre-Slab 6.2 the engine is single-playhead so only knob 0 is
-- declared; knobs 1-15 in these banks are unbound and the substrate
-- logs "unbound" on turn.  When 6.2 lifts P to per-voice config the
-- additional slots will appear here.
-- ---------------------------------------------------------------------------

-- | Direction bank.  Knob K (playhead K) → `odonus.direction<K>` over
-- | 0.0..2.0; reader floors to 0=fwd, 1=back, 2=pend (per spec §Q5).
-- | Engine consumes this once Slab 6.2 lands; today the bus key is
-- | declared but the engine is hardcoded NavForward.  Default 0 (fwd).
bankDirection :: Controller
bankDirection = midiController (bankMeta "Direction" 105)  -- purple
  [ knob 0 (voicePrefix <> ".direction0") 0.0 2.0 0.0 ]

-- | Speed bank.  Knob K (playhead K) → `odonus.speed<K>` as a
-- | clock-multiplier over 0.25..4.0.  Reader (post-6.2):
-- | `liveOr 1.0 "odonus.speed<K>"`.  Default 1.0 (master clock).
bankSpeed :: Controller
bankSpeed = midiController (bankMeta "Speed" 120)  -- hot pink
  [ knob 0 (voicePrefix <> ".speed0") 0.25 4.0 1.0 ]

-- | Transposition bank.  Knob K (playhead K) → `odonus.transp<K>`
-- | over -24..24 semitones (two-octave range each side).  Reader
-- | (post-6.2): `liveIntOr 0 "odonus.transp<K>"`.  Default 0.
bankTransp :: Controller
bankTransp = midiController (bankMeta "Transposition" 0)  -- red
  [ knob 0 (voicePrefix <> ".transp0") (-24.0) 24.0 0.0 ]

-- | Range-start bank.  Knob K (playhead K) → `odonus.rangeStart<K>`
-- | over 0..15 cell index.  The playhead doesn't traverse cells
-- | below this index.  Inert until Slab 6.2.  Default 0.
bankRangeStart :: Controller
bankRangeStart = midiController (bankMeta "Range-start" 56)  -- lime
  [ knob 0 (voicePrefix <> ".rangeStart0") 0.0 15.0 0.0 ]

-- | Range-end bank.  Knob K (playhead K) → `odonus.rangeEnd<K>`
-- | over 0..15 cell index.  Inert until Slab 6.2.  Default 15.
bankRangeEnd :: Controller
bankRangeEnd = midiController (bankMeta "Range-end" 50)  -- chartreuse
  [ knob 0 (voicePrefix <> ".rangeEnd0") 0.0 15.0 15.0 ]

-- ---------------------------------------------------------------------------
-- Side-button Binary-banks (Slab 6.6) — R-top / R-middle / R-bottom.
--
-- In a Binary-bank, knob-turn is ignored and knob-press toggles cell
-- N's boolean at `<prefix><N>`.  The 16 ring fills become all-or-
-- nothing (each ring is either dark or fully lit).  Pressing the same
-- side-button again exits the bank back to the previously-active
-- rotary bank.
--
-- L-top broken, L-middle reserved, L-bottom slated for Voice-select
-- in Slab 6.4 (distinct gesture, not a Binary-bank).
-- ---------------------------------------------------------------------------

-- | The three Binary-bank assignments wired by Slab 6.6.  Colours
-- | chosen to be visually distinct from the rotary palette: bright
-- | chartreuse Gate, vivid red Skip, deep indigo Glide.  Side-buttons
-- | not listed here are no-ops (the substrate logs "not assigned").
binaryBindings :: BinaryBindings
binaryBindings = Map.fromFoldable
  [ Tuple RTop (BinaryBank
      { controlPrefix: voicePrefix <> ".gate"
      , label:         "Gate"
      , color:         50    -- chartreuse — "pass / open"
      , defaultOn:     true  -- subtractive: rings start full, press to silence
      })
  , Tuple RMid (BinaryBank
      { controlPrefix: voicePrefix <> ".skip"
      , label:         "Skip"
      , color:         8     -- bright red-orange — "stop / blocked"
      , defaultOn:     false -- additive: rings start dark, press to skip a cell
      })
  , Tuple RBot (BinaryBank
      { controlPrefix: voicePrefix <> ".glide"
      , label:         "Glide"
      , color:         115   -- deep magenta — "smear / portamento"
      , defaultOn:     false -- additive: rings start dark, press to add glide
      })
  ]

-- ---------------------------------------------------------------------------
-- L-top Four-voice Fugue dashboard (Slab 6.6c).
--
-- 4×4 layout — columns are playheads K=0..3, rows are per-playhead
-- parameters:
--
--   Row 0 (knobs  0- 3): mute/enable.  Knob-press toggles
--                        `odonus.mute<K>` (subtractive: rings start full,
--                        press to silence that playhead).  Knob-turn
--                        is ignored.
--   Row 1 (knobs  4- 7): direction (0=fwd, 1=back, 2=pend).  Writes
--                        `odonus.direction<K>` over 0..2.  Engine
--                        floor-decodes.
--   Row 2 (knobs  8-11): speed (0.25..4.0).  Writes
--                        `odonus.speed<K>` continuous.
--   Row 3 (knobs 12-15): transposition (-24..24 semitones).  Writes
--                        `odonus.transp<K>` continuous.
--
-- Tint: lime — visually distinct from any rotary bank or other side-
-- button-bank.  Pressing L-top again exits back to whatever rotary
-- bank was last active.
-- ---------------------------------------------------------------------------

dashboardBindings :: DashboardBindings
dashboardBindings = Map.fromFoldable
  [ Tuple LTop fugueDashboard
  , Tuple LMid lMidGlobals
  ]

fugueDashboard :: DashboardBank
fugueDashboard = DashboardBank
  { label:         "Fugue"
  , color:         56    -- lime
  , knobs:         Map.fromFoldable (rowDirection <> rowSpeed <> rowTransp)
  , pressToggles:  Map.fromFoldable rowMute
  , pressCommands: Map.empty
  , knobSteps:     Map.empty
  }
  where
  -- Row 0 — mute press-toggles for columns 0..3.  Inverted: bus
  -- stores mute=true (1.0) but the LED paints "active = full ring"
  -- so a lit knob is an audible playhead, a dark knob is silenced.
  rowMute :: Array (Tuple Int PressToggle)
  rowMute = map (\k -> Tuple k
                  { busKey:   voicePrefix <> ".mute" <> show k
                  , inverted: true
                  })
                (range 0 3)

  -- Row 1 — direction (knobs 4..7).  Continuous over 0..2 with engine
  -- floor-decoding to fwd / back / pend.  Default 0 (fwd).
  rowDirection :: Array (Tuple Int KnobBinding')
  rowDirection = map (\k -> Tuple (4 + k)
                              { controlName:  voicePrefix <> ".direction" <> show k
                              , outMin:       0.0
                              , outMax:       2.0
                              , defaultValue: 0.0
                              , scaleMode:    Linear
                              })
                     (range 0 3)

  -- Row 2 — speed (knobs 8..11).  Exponential 1/32..32 so knob centre
  -- (CC=64) lands at 1.0 = master clock, with equal travel for slower
  -- and faster.  Default 1.0.  CCW = down to 1/32 (very slow), CW =
  -- up to 32x (very fast cell-stride).
  rowSpeed :: Array (Tuple Int KnobBinding')
  rowSpeed = map (\k -> Tuple (8 + k)
                          { controlName:  voicePrefix <> ".speed" <> show k
                          , outMin:       0.03125    -- 1/32
                          , outMax:       32.0
                          , defaultValue: 1.0
                          , scaleMode:    Exponential
                          })
                 (range 0 3)

  -- Row 3 — transposition (knobs 12..15).  Linear -24..24, default 0
  -- (the MFT hardware has a centre detente at CC=64 so the knob feels
  -- centre-zero).
  rowTransp :: Array (Tuple Int KnobBinding')
  rowTransp = map (\k -> Tuple (12 + k)
                           { controlName:  voicePrefix <> ".transp" <> show k
                           , outMin:       (-24.0)
                           , outMax:       24.0
                           , defaultValue: 0.0
                           , scaleMode:    Linear
                           })
                  (range 0 3)

-- Local alias for the `KnobBinding` row-type so the fugueDashboard
-- where-clause helpers don't need to import the full record name.
type KnobBinding' =
  { controlName  :: String
  , outMin       :: Number
  , outMax       :: Number
  , defaultValue :: Number
  , scaleMode    :: KnobScale
  }

-- ---------------------------------------------------------------------------
-- L-mid Globals — master-control dashboard (Slab 6.7a)
-- ---------------------------------------------------------------------------
-- Bottom row of heavy resets, addressable from the Twister L-mid side
-- button.  Rows 0-1 + row 3 will fill out in 6.7b-e (master transpose /
-- master speed / scale select / nav-mode / Marbles triad / mod shred);
-- for now they paint dark because they have no knobs / toggles / commands
-- registered.
--
-- Row 2 holds the four jam-recovery buttons.  All four send literal WS
-- verbs that already exist on the BEAM side (hush, clear-scale) or are
-- added in this slab (clear-controls, phase-resync).  Press one to fire;
-- the ring flashes bright as visual feedback, then settles back to dim
-- on the next bank entry.

lMidGlobals :: DashboardBank
lMidGlobals = DashboardBank
  { label:         "Globals"
  , color:         80    -- cyan-ish, distinct from fugue's lime (56)
  , knobs:         Map.fromFoldable (rowMasters <> rowShred)
  , pressToggles:  Map.empty
  , pressCommands: Map.fromFoldable (rowReset <> rowShredPress)
  , knobSteps:     Map.fromFoldable [ scaleSelectKnob, navModeKnob ]
  }
  where
  -- Row 0 (indices 0..3): master knobs.  Wired into Odonus's evaluator
  -- via the live-control bus — masterTransp adds uniformly to every
  -- playhead's transp[K], masterSpeed multiplies every speed[K], so a
  -- single turn shifts/slows the whole fugue in lockstep.
  --   0  masterTransp  Linear -12..+12 scale-degrees, centre 0
  --   1  masterSpeed   Exp 1/4..4, centre 1.0 (one octave slower → faster)
  --   2  swing         deferred (placeholder, stays dark)
  --   3  scale select  stepped 7-position knob (in knobSteps below)
  -- Row 1 (indices 4..7): traversal-shape selectors.  Slab 6.7d added
  -- the nav-mode stepped knob; cols 5..7 stay dark pending mutation
  -- triad design.
  --   4  nav-mode      stepped 3-position knob (cartesian/forward/reverse)
  rowMasters :: Array (Tuple Int KnobBinding')
  rowMasters =
    [ Tuple 0
        { controlName:  "odonus.masterTransp"
        , outMin:       (-12.0)
        , outMax:       12.0
        , defaultValue: 0.0
        , scaleMode:    Linear
        }
    , Tuple 1
        { controlName:  "odonus.masterSpeed"
        , outMin:       0.25
        , outMax:       4.0
        , defaultValue: 1.0
        , scaleMode:    Exponential
        }
    ]

  -- Row 0 col 3: stepped scale selector.  Knob position 0 sends
  -- `clear-scale` (return to binding's static cfg.scale); 1..6 send
  -- `set-scale <name>` for the curated pop-scale list.  All C-rooted —
  -- the user-perceived behaviour is "stay in key, switch mode".
  scaleSelectKnob :: Tuple Int KnobStepBank
  scaleSelectKnob = Tuple 3
    { trackKey: "lmid.scaleSlot"
    , verbs:
        [ "clear-scale"
        , "set-scale c-major"
        , "set-scale c-minor"
        , "set-scale c-major-pentatonic"
        , "set-scale c-harmonic-minor"
        , "set-scale c-messiaen-3"
        , "set-scale c-phrygian-dominant"
        ]
    }

  -- Row 1 col 0 (knob 4): nav-mode stepped knob.  Three positions cycle
  -- every Odonus voice's traversal mode via the `set-nav-mode` WS verb,
  -- which reuses the engine's existing set_config path (validates the
  -- atom against odonus_engine:nav_modes/0).  Cartesian is the default
  -- — it's the René-ish mode where direction[K] picks each playhead's
  -- X-step direction independently; forward forces all heads forward,
  -- reverse forces all heads back.  Position 0 = cartesian (the
  -- session's typical starting state) makes a turn-back-to-zero a
  -- predictable "return to default" gesture.
  navModeKnob :: Tuple Int KnobStepBank
  navModeKnob = Tuple 4
    { trackKey: "lmid.navMode"
    , verbs:
        [ "set-nav-mode cartesian"
        , "set-nav-mode forward"
        , "set-nav-mode reverse"
        ]
    }

  -- Row 2 (indices 8..11): heavy resets from least → most disruptive.
  -- Knob 10 paired with knob 11: hush silences every Odonus voice,
  -- unhush brings them back.  clear-scale was here originally but
  -- scale-select knob 3 position 0 already does that work — unhush
  -- earns the slot.
  rowReset :: Array (Tuple Int String)
  rowReset =
    [ Tuple 8  "phase-resync"
    , Tuple 9  "clear-controls"
    , Tuple 10 "unhush"
    , Tuple 11 "hush"
    ]

  -- Row 3 (indices 12..15): mod shred — continuous knob sets the shred
  -- rate (0..1, default 1.0 = full Mimetic reroll), press fires the
  -- `shred-mod N` WS verb which reads the rate from the bus and rolls
  -- a uniform die per cell; cells that roll <= rate get fresh random
  -- 0..127 written back to the bus.  Voices pick up new values on the
  -- next tick.  Turn down for partial reroll; turn to 0 for "lock".
  rowShred :: Array (Tuple Int KnobBinding')
  rowShred = map (\k -> Tuple (12 + k)
                          { controlName:  "odonus.shredRate" <> show (k + 1)
                          , outMin:       0.0
                          , outMax:       1.0
                          , defaultValue: 1.0
                          , scaleMode:    Linear
                          })
                 (range 0 3)

  rowShredPress :: Array (Tuple Int String)
  rowShredPress = map (\k -> Tuple (12 + k)
                              ("shred-mod " <> show (k + 1)))
                      (range 0 3)
