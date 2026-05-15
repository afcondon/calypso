-- | Arm — orchestrate a single cue arm-switch on the purerl-tidal
-- | side.
-- |
-- | Given (tvoice, cueName), synthesise a bridge module
-- | Tidal.Generated.M<tvoice> that extracts <cueName>'s body, build
-- | it via purs + purs-backend-erl --filter, erlc the result, then
-- | send `play-armed <tvoice> M<tvoice>` over WS. The handler-side
-- | code:load_file makes the freshly-built BEAM module take effect;
-- | the voice gen_server's pattern swaps on the next cycle.
-- |
-- | The Aff returns timings for each stage so the frontend can
-- | report what the arm cycle cost.
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
  , purs :: Int
  , be :: Int
  , erlc :: Int
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
  , purs: CA.int
  , be: CA.int
  , erlc: CA.int
  , ws: CA.int
  }

armResultCodec :: JsonCodec ArmResult
armResultCodec = CAR.object "ArmResult"
  { ok: CA.boolean
  , reply: CA.string
  , error: CA.string
  , timings: armTimingsCodec
  }
