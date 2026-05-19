-- | User-editable controller bindings — the four-layer architecture's
-- | "what's plugged in" declaration for the controller family.
-- |
-- | The shape mirrors `Studio.purs` on the BEAM side: a small file
-- | listing the named scalars each hardware surface drives, kept
-- | separate from the pump so editing one knob's range doesn't churn
-- | the runtime code.  Touched maybe once a week.
-- |
-- | Add new knobs by extending the array; the pump picks the change
-- | up on the next Calypso restart.
module Calypso.Frontend.Controller.Bindings
  ( twister
  ) where

import Calypso.Frontend.Controller (Controller, knob, midiController)

-- | The Midifighter Twister — primary hands-on surface for live-coding
-- | the rig.  16 knobs across the bank; we declare one knob at a time
-- | as the cells that consume each named scalar appear.
-- |
-- | Each entry reads: `knob <idx> <controlName> <outMin> <outMax>`.
-- | The Twister sends 0..127 on encoder turns; the pump scales linearly
-- | into the declared range and writes the result to the BEAM live-
-- | control bus via `set-control <name> <value>`.
-- |
-- | Cell code consuming these reads the same control name through
-- | `live`/`liveInt`/`liveBool` in `Tidal.LiveControl`.
-- |
-- | The names below match existing live-control slots already wired
-- | into Studio.purs — turning a knob takes effect on the next clock
-- | tick (~50 ms) with no Studio edit needed.
-- |
-- | Knob indices here are the CC value the hardware sends — verified
-- | empirically against the rig 2026-05-19: Andrew's Twister is
-- | **0-indexed** (default Midifighter firmware).  `knob 0` is the
-- | top-left encoder, `knob 15` the bottom-right.
-- |
-- | We declare each machine's full Twister layout as its own value
-- | and select one as the active `twister`.  When per-bank routing
-- | lands (Twister hardware banks 1..4 on separate MIDI channels)
-- | each layout will move to its own bank; until then they're swapped
-- | by editing the `twister =` line below.
twister :: Controller
twister = twisterRene

-- | René machine layout — the Twister's 4×4 grid becomes a literal
-- | René front panel.  Knobs 1..16 sweep `rene.note0..15` over the
-- | MIDI drum-rack range (36..51) matching `studioRene`'s default
-- | notes; turning a knob retunes the cell at its position on every
-- | subsequent traversal step.  Pushes on cells 1..16 are reserved
-- | for `rene.skip0..15` toggles once the pump handles button events
-- | (parser already recognises EncoderPress, dispatch comes later).
twisterRene :: Controller
twisterRene = midiController "Midi Fighter Twister"
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

-- | Grids + Repetitor layout — the previous active binding (validated
-- | end-to-end 2026-05-19).  Two rows of Repetitor row-offsets, two
-- | rows of Grids parameters.  Switch back by re-pointing `twister`
-- | at `twisterGrids` above.
twisterGrids :: Controller
twisterGrids = midiController "Midi Fighter Twister"
  [ knob  0 "rep.offM"         0.0  11.0
  , knob  1 "rep.offC1"        0.0  11.0
  , knob  2 "rep.offC2"        0.0  11.0
  , knob  3 "rep.offC3"        0.0  11.0
  , knob  4 "grids.x"          0.0 255.0
  , knob  5 "grids.y"          0.0 255.0
  , knob  6 "grids.fillBd"     0.0 255.0
  , knob  7 "grids.fillSd"     0.0 255.0
  , knob  8 "grids.fillHh"     0.0 255.0
  , knob  9 "grids.randomness" 0.0 128.0
  ]
