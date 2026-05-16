-- | Arm — fire a single cue arm-switch on the purerl-tidal side.
-- |
-- | Given (tvoice, cueName), open a WS to purerl-tidal and send
-- | `play-armed <tvoice> <cueName>`.  The BEAM handler resolves the
-- | cue by calling calypso_generated_session@ps:<cueName>/0 and
-- | extracts the body Pattern.  No compilation happens here — that
-- | belongs to /session-source (▶ run).
-- |
-- | The Aff returns total + WS timings so the frontend can report
-- | what the arm cost.
module Calypso.Server.Arm
  ( ArmRequest
  , ArmTimings
  , ArmResult
  , armCue
  , armRequestCodec
  , armResultCodec
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Effect (Effect)
import Effect.Aff (Aff)

type ArmRequest =
  { tvoice :: String
  , cueName :: String
  }

type ArmTimings =
  { total :: Int
  , ws :: Int
  }

-- | `ok` reflects the purerl-tidal reply (false on ERR/ERROR or any
-- | upstream failure). `error` is empty on success; otherwise a
-- | short reason. `reply` is the WS reply line verbatim when one
-- | arrived.
type ArmResult =
  { ok :: Boolean
  , reply :: String
  , error :: String
  , timings :: ArmTimings
  }

foreign import armCueImpl :: ArmRequest -> Effect (Promise ArmResult)

armCue :: ArmRequest -> Aff ArmResult
armCue = toAffE <<< armCueImpl

armRequestCodec :: JsonCodec ArmRequest
armRequestCodec = CAR.object "ArmRequest"
  { tvoice: CA.string
  , cueName: CA.string
  }

armTimingsCodec :: JsonCodec ArmTimings
armTimingsCodec = CAR.object "ArmTimings"
  { total: CA.int
  , ws: CA.int
  }

armResultCodec :: JsonCodec ArmResult
armResultCodec = CAR.object "ArmResult"
  { ok: CA.boolean
  , reply: CA.string
  , error: CA.string
  , timings: armTimingsCodec
  }
