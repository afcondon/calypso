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
-- | empirically against the rig 2026-05-19, Andrew's Twister sends
-- | CCs starting at 1 (likely a PWYF firmware programming pass), so
-- | `knob 1` matches the top-left encoder, `knob 16` the bottom-right.
twister :: Controller
twister = midiController "Midi Fighter Twister"
  -- Row 1 (top): Repetitor offsets — phase-shift each row of the ZR
  -- pattern.  "King 1" is 12 beats long so offsets 0..11 cycle through
  -- the pattern; the live-control bus floors Number → Int.
  [ knob 1 "rep.offM"        0.0  11.0
  , knob 2 "rep.offC1"       0.0  11.0
  , knob 3 "rep.offC2"       0.0  11.0
  , knob 4 "rep.offC3"       0.0  11.0
  -- Row 2: Grids X/Y on the left, kick + snare density on the right.
  -- (0..255 on each axis, matches the MI Grids hardware's CV scaling.)
  , knob 5 "grids.x"         0.0 255.0
  , knob 6 "grids.y"         0.0 255.0
  , knob 7 "grids.fillBd"    0.0 255.0
  , knob 8 "grids.fillSd"    0.0 255.0
  -- Row 3: hi-hat density + global randomness (chaos).
  , knob 9  "grids.fillHh"    0.0 255.0
  , knob 10 "grids.randomness" 0.0 128.0
  ]
