-- | Midifighter Twister wire-protocol parser.
-- |
-- | Ported from `producing-with-your-feet/src/Data/Twister.purs`, with
-- | the `Data.Midi` newtypes (`CC`/`MidiValue`) replaced by `Int` —
-- | Calypso doesn't carry a MIDI-types dependency.  The conventions
-- | are the Twister's hardware defaults:
-- |
-- |   * Channel 1: encoder turns.  CC = encoder index (0..15), value
-- |     = current position (0..127).
-- |   * Channel 2: encoder presses + releases.  CC = encoder index,
-- |     value 127 = press, 0 = release.
-- |   * Channel 4: the six side buttons.  CC 8..13 map L-top, L-mid,
-- |     L-bot, R-top, R-mid, R-bot in that order — value 127 = press,
-- |     0 = release.  Confirmed against the MFT manual's Bank 1 MIDI
-- |     appendix and empirically by inspecting the raw bytes; matches
-- |     "Switch Action = CC Hold" in the Midifighter Utility.
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
-- |   * `EncoderTurn idx val`     — knob `idx` (0..15) at position `val`.
-- |   * `EncoderPress idx`        — the same knob was pushed (val=127).
-- |   * `EncoderRelease idx`      — released (val=0).
-- |   * `SideButtonPress sb`      — one of the six bezel buttons pressed.
-- |   * `SideButtonRelease sb`    — released.
data TwisterMsg
  = EncoderTurn Int Int
  | EncoderPress Int
  | EncoderRelease Int
  | SideButtonPress SideBtn
  | SideButtonRelease SideBtn

derive instance eqTwisterMsg :: Eq TwisterMsg

-- | The Twister's six side buttons — three on each side, named by
-- | physical position.  Andrew's Twister has L-top broken (memory
-- | `reference_mft_twister_hardware_reality`); the rest are
-- | programmable via the host.
data SideBtn = LTop | LMid | LBot | RTop | RMid | RBot

derive instance eqSideBtn :: Eq SideBtn
derive instance ordSideBtn :: Ord SideBtn

instance showSideBtn :: Show SideBtn where
  show LTop = "LTop"
  show LMid = "LMid"
  show LBot = "LBot"
  show RTop = "RTop"
  show RMid = "RMid"
  show RBot = "RBot"

-- | Map a channel-5 CC index to a side-button position.  The CCs are
-- | the MFT default-firmware assignments; if hardware events log the
-- | wrong button on first test, this table is the place to retune.
sideBtnFromCC :: Int -> Maybe SideBtn
sideBtnFromCC cc = case cc of
  8  -> Just LTop
  9  -> Just LMid
  10 -> Just LBot
  11 -> Just RTop
  12 -> Just RMid
  13 -> Just RBot
  _  -> Nothing

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
    4 -> case sideBtnFromCC cc of
      Nothing -> Nothing
      Just sb
        | val == 127 -> Just (SideButtonPress sb)
        | otherwise  -> Just (SideButtonRelease sb)
    _ -> Nothing
