-- | Midifighter Twister wire-protocol parser.
-- |
-- | Ported from `producing-with-your-feet/src/Data/Twister.purs`, with
-- | the `Data.Midi` newtypes (`CC`/`MidiValue`) replaced by `Int` —
-- | Calypso doesn't carry a MIDI-types dependency.  The conventions
-- | are the Twister's hardware defaults, verified in PWYF:
-- |
-- |   * Channel 1: encoder turns.  CC = encoder index (0..15), value
-- |     = current position (0..127).
-- |   * Channel 2: encoder presses + releases.  CC = encoder index,
-- |     value 127 = press, anything else = release.
-- |   * Channel 5: the four side buttons.  CC 8 / 9 / 10 map to the
-- |     prev / next / refresh actions.
-- |
-- | Status byte layout: `1011 nnnn`, where the high nibble is `B`
-- | (Control Change) and the low nibble is `channel - 1`.  We mask
-- | the low nibble + add 1 to recover a 1-indexed channel number.
module Calypso.Frontend.Controller.Twister
  ( TwisterMsg(..)
  , SideBtn(..)
  , parseTwisterMsg
  ) where

import Prelude

import Data.Array as Array
import Data.Int.Bits (and)
import Data.Maybe (Maybe(..))

-- | One parsed event from the Twister hardware.
-- |
-- |   * `EncoderTurn idx val` — knob `idx` (0..15) has moved to position
-- |     `val` (0..127).
-- |   * `EncoderPress idx`    — the same knob was pushed.
-- |   * `EncoderRelease idx`  — released.
-- |   * `SideButton b`        — one of the four bezel buttons fired.
data TwisterMsg
  = EncoderTurn Int Int
  | EncoderPress Int
  | EncoderRelease Int
  | SideButton SideBtn

derive instance eqTwisterMsg :: Eq TwisterMsg

-- | The Twister's four side buttons.  Bank-cycling is up to the host;
-- | the hardware just emits which physical button was pressed.
data SideBtn = PrevPedal | NextPedal | RefreshLEDs

derive instance eqSideBtn :: Eq SideBtn

-- | Parse a raw MIDI frame as a Twister event.  Returns `Nothing` for
-- | anything that doesn't match the known channels — keeps the pump's
-- | error surface narrow (unknown bytes are silently dropped rather
-- | than spamming the console).
parseTwisterMsg :: Array Int -> Maybe TwisterMsg
parseTwisterMsg bytes = do
  status <- Array.index bytes 0
  cc <- Array.index bytes 1
  val <- Array.index bytes 2
  let channel = (and status 0x0F) + 1
  case channel of
    1 -> Just (EncoderTurn cc val)
    2
      | val == 127 -> Just (EncoderPress cc)
      | otherwise -> Just (EncoderRelease cc)
    5 -> case cc of
      8 -> Just (SideButton PrevPedal)
      9 -> Just (SideButton NextPedal)
      10 -> Just (SideButton RefreshLEDs)
      _ -> Nothing
    _ -> Nothing
