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
  ) where

import Prelude ((<>), negate)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))

import Calypso.Frontend.Controller
  ( BinaryBank(..), BinaryBindings
  , Controller, ControllerMeta
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
