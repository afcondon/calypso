-- | SessionSource — write a typeful session module to disk and build.
-- |
-- | Phase 4 endpoint substrate. The Calypso composition pane sends
-- | its full source text here; we write it to
-- | `Calypso.Generated.Session.purs`, run purs + backend-erl + erlc,
-- | and ask purerl-tidal to reload the baseline module.
module Calypso.Server.SessionSource
  ( SessionSourceRequest
  , SessionSourceResult
  , SessionSourceTimings
  , buildSession
  , sessionSourceRequestCodec
  , sessionSourceResultCodec
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Effect (Effect)
import Effect.Aff (Aff)

type SessionSourceRequest =
  { source :: String
  }

type SessionSourceTimings =
  { write :: Int
  , purs :: Int
  , be :: Int
  , erlc :: Int
  , ws :: Int
  , total :: Int
  }

-- | `pursErrorsJson` is the raw `purs --json-errors` envelope when
-- | the purs stage fails; empty otherwise. Forwarded verbatim so the
-- | frontend can render structured gutter errors without us having
-- | to parse + re-serialise.
type SessionSourceResult =
  { ok :: Boolean
  , reply :: String
  , error :: String
  , pursErrorsJson :: String
  , timings :: SessionSourceTimings
  }

foreign import buildSessionImpl
  :: SessionSourceRequest -> Effect (Promise SessionSourceResult)

buildSession :: SessionSourceRequest -> Aff SessionSourceResult
buildSession = toAffE <<< buildSessionImpl

sessionSourceRequestCodec :: JsonCodec SessionSourceRequest
sessionSourceRequestCodec = CAR.object "SessionSourceRequest"
  { source: CA.string
  }

sessionSourceTimingsCodec :: JsonCodec SessionSourceTimings
sessionSourceTimingsCodec = CAR.object "SessionSourceTimings"
  { write: CA.int
  , purs: CA.int
  , be: CA.int
  , erlc: CA.int
  , ws: CA.int
  , total: CA.int
  }

sessionSourceResultCodec :: JsonCodec SessionSourceResult
sessionSourceResultCodec = CAR.object "SessionSourceResult"
  { ok: CA.boolean
  , reply: CA.string
  , error: CA.string
  , pursErrorsJson: CA.string
  , timings: sessionSourceTimingsCodec
  }
