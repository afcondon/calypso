-- | User-editable controller bindings — the four-layer architecture's
-- | "what's plugged in" declaration for the controller family.
-- |
-- | Each (Controller, Controllable) pairing is a `Controller` value:
-- | hand-rolled data, not a typeclass instance.  The active pairing is
-- | runtime-selectable — `subscribeTwister` cycles through the
-- | `allBindings` list on Twister side buttons.  Adding a new pairing
-- | (a new machine to control, or a new hardware surface) is one block
-- | of declarations + one entry in `allBindings`.
-- |
-- | This file is deliberately a "rig declaration" surface in the
-- | Studio.purs spirit (see [[feedback_studio_long_identifiers]]) —
-- | rarely touched, descriptive names, all metadata in one place.
module Calypso.Frontend.Controller.Bindings
  ( allBindings
  , twisterRene
  , twisterGrids
  , twisterRepetitor
  ) where

import Calypso.Frontend.Controller (Controller, knob, midiController)

-- | The full list of controller pairings the pump rotates through.
-- | The first entry is the default-on-startup binding; the others are
-- | reachable via the Twister's side buttons (PrevPedal / NextPedal).
allBindings :: Array Controller
allBindings =
  [ twisterRene
  , twisterGrids
  , twisterRepetitor
  ]

-- | The CoreMIDI port name — shared across every Twister pairing.
-- | Verified empirically against the rig: Andrew's Twister is
-- | 0-indexed (default Midifighter firmware), top-left = CC=0.
twisterDevice :: String
twisterDevice = "Midi Fighter Twister"

-- | René machine layout — the Twister's 4×4 grid becomes a literal
-- | René front panel.  Knobs 0..15 sweep `rene.note0..15` over the
-- | MIDI drum-rack range (36..51) matching `studioRene`'s default
-- | notes; turning a knob retunes the cell at its position on every
-- | subsequent traversal step.
twisterRene :: Controller
twisterRene = midiController
  { device:       twisterDevice
  , controllable: "studioRene"
  , label:        "René"
  , color:        0     -- red
  }
  [ knob  0 "rene.note0"  36.0 51.0
  , knob  1 "rene.note1"  36.0 51.0
  , knob  2 "rene.note2"  36.0 51.0
  , knob  3 "rene.note3"  36.0 51.0
  , knob  4 "rene.note4"  36.0 51.0
  , knob  5 "rene.note5"  36.0 51.0
  , knob  6 "rene.note6"  36.0 51.0
  , knob  7 "rene.note7"  36.0 51.0
  , knob  8 "rene.note8"  36.0 51.0
  , knob  9 "rene.note9"  36.0 51.0
  , knob 10 "rene.note10" 36.0 51.0
  , knob 11 "rene.note11" 36.0 51.0
  , knob 12 "rene.note12" 36.0 51.0
  , knob 13 "rene.note13" 36.0 51.0
  , knob 14 "rene.note14" 36.0 51.0
  , knob 15 "rene.note15" 36.0 51.0
  ]

-- | Grids machine layout — the 4×4 grid carries Grids' six parameters
-- | on the first two rows (X/Y/per-drum-fills/randomness), the rest
-- | unbound.  Identical to the layout validated 2026-05-19 against
-- | the rig.
twisterGrids :: Controller
twisterGrids = midiController
  { device:       twisterDevice
  , controllable: "studioGrids"
  , label:        "Grids"
  , color:        85    -- cyan
  }
  [ knob  0 "grids.x"          0.0 255.0
  , knob  1 "grids.y"          0.0 255.0
  , knob  2 "grids.fillBd"     0.0 255.0
  , knob  3 "grids.fillSd"     0.0 255.0
  , knob  4 "grids.fillHh"     0.0 255.0
  , knob  5 "grids.randomness" 0.0 128.0
  ]

-- | Repetitor machine layout — four row-offset knobs that phase-shift
-- | each of the M/C1/C2/C3 rows independently against the pattern.
-- | "King 1" is 12 beats long so offsets 0..11 sweep through the
-- | full pattern length.
twisterRepetitor :: Controller
twisterRepetitor = midiController
  { device:       twisterDevice
  , controllable: "studioRepetitor"
  , label:        "Repetitor"
  , color:        42    -- yellow
  }
  [ knob  0 "rep.offM"  0.0 11.0
  , knob  1 "rep.offC1" 0.0 11.0
  , knob  2 "rep.offC2" 0.0 11.0
  , knob  3 "rep.offC3" 0.0 11.0
  ]
