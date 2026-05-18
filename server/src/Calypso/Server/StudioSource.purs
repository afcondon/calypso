-- | StudioSource — write a Studio.purs module to disk and build.
-- |
-- | Workstream 2 of `docs/studio-pane-day-plan.md`.  Mirror of
-- | `Calypso.Server.SessionSource`, but targets the canonical rig
-- | declaration module (`Studio`) instead of the generated session
-- | module.  The frontend POSTs the full new Studio.purs text; we
-- | write it to `purerl-tidal/src/Studio.purs`, run purs +
-- | backend-erl + erlc on just that module, then send
-- | `reload-baseline` so the walker re-registers Studio's devices /
-- | instruments / drumkits / vmods.
-- |
-- | Round trip ~700ms warm-toolchain, matching the per-cell pipeline.
-- | Replaces the 60-90s `make erl` + DeepStar restart dance for the
-- | most common Studio edits.
module Calypso.Server.StudioSource
  ( StudioSourceRequest
  , StudioSourceResult
  , StudioSourceTimings
  , StudioSourceFetch
  , buildStudio
  , fetchStudio
  , studioSourceRequestCodec
  , studioSourceResultCodec
  , studioSourceFetchCodec
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Effect (Effect)
import Effect.Aff (Aff)

type StudioSourceRequest =
  { source :: String
  }

type StudioSourceTimings =
  { write :: Int
  , purs :: Int
  , be :: Int
  , erlc :: Int
  , ws :: Int
  , total :: Int
  }

-- | Same result shape as SessionSourceResult so frontends can share
-- | the rendering path (gutter errors, timings, OK banner).
type StudioSourceResult =
  { ok :: Boolean
  , reply :: String
  , error :: String
  , pursErrorsJson :: String
  , timings :: StudioSourceTimings
  }

foreign import buildStudioImpl
  :: StudioSourceRequest -> Effect (Promise StudioSourceResult)

buildStudio :: StudioSourceRequest -> Aff StudioSourceResult
buildStudio = toAffE <<< buildStudioImpl

studioSourceRequestCodec :: JsonCodec StudioSourceRequest
studioSourceRequestCodec = CAR.object "StudioSourceRequest"
  { source: CA.string
  }

studioSourceTimingsCodec :: JsonCodec StudioSourceTimings
studioSourceTimingsCodec = CAR.object "StudioSourceTimings"
  { write: CA.int
  , purs: CA.int
  , be: CA.int
  , erlc: CA.int
  , ws: CA.int
  , total: CA.int
  }

studioSourceResultCodec :: JsonCodec StudioSourceResult
studioSourceResultCodec = CAR.object "StudioSourceResult"
  { ok: CA.boolean
  , reply: CA.string
  , error: CA.string
  , pursErrorsJson: CA.string
  , timings: studioSourceTimingsCodec
  }

-- | GET /studio-source result — the current source on disk.
type StudioSourceFetch =
  { ok :: Boolean
  , source :: String
  , error :: String
  }

foreign import fetchStudioImpl :: Effect (Promise StudioSourceFetch)

fetchStudio :: Aff StudioSourceFetch
fetchStudio = toAffE fetchStudioImpl

studioSourceFetchCodec :: JsonCodec StudioSourceFetch
studioSourceFetchCodec = CAR.object "StudioSourceFetch"
  { ok: CA.boolean
  , source: CA.string
  , error: CA.string
  }
