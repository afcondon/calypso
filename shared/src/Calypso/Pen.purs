-- | The Pen — turn-based approval permission for proposed edits.
-- |
-- | Calypso's collaboration model: anyone (humans, AI agents) can post
-- | edit proposals; only the holder of the Pen accepts them into the
-- | running source.  This module owns the WS-frame shapes the server
-- | and frontend share for negotiating who currently holds the Pen.
-- |
-- | (The Pen is the conceptual descendant of Atelier's Conch — same
-- | request/yield/force machinery, retargeted from "exclusive writer"
-- | to "approver of incoming proposals".)
module Calypso.Pen where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as AJ
import Data.Codec.Argonaut (JsonCodec, JsonDecodeError(..))
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple)
import Data.Tuple.Nested ((/\))
import Foreign.Object as Object

import Calypso.Session (CompileResponse, compileResponseCodec)

-- | A server-assigned identifier for one WebSocket subscriber. Lives
-- | for the duration of the WS connection; a reconnect gets a fresh id
-- | (no persistence). HTTP mutating endpoints authorise against this by
-- | reading the `X-Atelier-Subscriber-Id` header.
newtype SubscriberId = SubscriberId String

derive newtype instance Eq SubscriberId
derive newtype instance Ord SubscriberId
derive newtype instance Show SubscriberId

unSubscriberId :: SubscriberId -> String
unSubscriberId (SubscriberId s) = s

subscriberIdCodec :: JsonCodec SubscriberId
subscriberIdCodec =
  CA.prismaticCodec "SubscriberId" (Just <<< SubscriberId) unSubscriberId CA.string

-- | Pen state.  `holder` is `Nothing` when nobody has the Pen; in that
-- | case mutating HTTP endpoints reject writes with a 409.
-- | `lastActivityAt` is ms-since-epoch of the holder's most recent
-- | heartbeat or accepted action — clients show it as an idle indicator,
-- | and the server uses it to decide whether `ForcePen` from another
-- | subscriber should succeed.
type PenState =
  { holder :: Maybe SubscriberId
  , lastActivityAt :: Number
  }

penStateCodec :: JsonCodec PenState
penStateCodec = CAR.object "PenState"
  { holder: nullableSubscriberIdCodec
  , lastActivityAt: CA.number
  }

nullableSubscriberIdCodec :: JsonCodec (Maybe SubscriberId)
nullableSubscriberIdCodec = CA.codec' decode encode
  where
  decode json
    | AJ.isNull json = Right Nothing
    | otherwise = Just <$> CA.decode subscriberIdCodec json
  encode = case _ of
    Nothing -> AJ.jsonNull
    Just s -> CA.encode subscriberIdCodec s

-- | Messages the server pushes to subscribers over the WS connection.
-- |
-- | `Welcome` fires once, immediately after the handshake completes;
-- | it delivers the subscriber's assigned id plus the current snapshot
-- | so late-joining clients don't stay stale until the next write.
-- |
-- | `Snapshot` fires after every mutating HTTP write, carrying the new
-- | compile response.  The server skips the current Pen holder when
-- | fanning out (they already have the state they just wrote).
-- |
-- | `PenUpdate` fires on any Pen state transition — grant, yield,
-- | force, idle-revoke.
data Broadcast
  = Welcome
      { yourId :: SubscriberId
      , pen :: PenState
      , snapshot :: CompileResponse
      }
  | Snapshot
      { pen :: PenState
      , snapshot :: CompileResponse
      }
  | PenUpdate
      { pen :: PenState
      }

broadcastCodec :: JsonCodec Broadcast
broadcastCodec = CA.codec' decode encode
  where
  decode json = case AJ.toObject json of
    Nothing -> Left (TypeMismatch "Broadcast object")
    Just o -> case Object.lookup "type" o >>= AJ.toString of
      Just "welcome" -> do
        yid <- field "yourId" o subscriberIdCodec
        ps <- field "pen" o penStateCodec
        sn <- field "snapshot" o compileResponseCodec
        Right (Welcome { yourId: yid, pen: ps, snapshot: sn })
      Just "snapshot" -> do
        ps <- field "pen" o penStateCodec
        sn <- field "snapshot" o compileResponseCodec
        Right (Snapshot { pen: ps, snapshot: sn })
      Just "pen" -> do
        ps <- field "pen" o penStateCodec
        Right (PenUpdate { pen: ps })
      Just tag -> Left (UnexpectedValue (AJ.fromString tag))
      Nothing -> Left (AtKey "type" MissingValue)
  encode = case _ of
    Welcome r -> tagged "welcome"
      [ "yourId" /\ CA.encode subscriberIdCodec r.yourId
      , "pen" /\ CA.encode penStateCodec r.pen
      , "snapshot" /\ CA.encode compileResponseCodec r.snapshot
      ]
    Snapshot r -> tagged "snapshot"
      [ "pen" /\ CA.encode penStateCodec r.pen
      , "snapshot" /\ CA.encode compileResponseCodec r.snapshot
      ]
    PenUpdate r -> tagged "pen"
      [ "pen" /\ CA.encode penStateCodec r.pen
      ]

-- | Messages a subscriber sends to the server over the WS connection.
-- | `RequestPen` asks for the Pen; server replies with a `PenUpdate`
-- | on grant, or (on denial) silently — the client reads denial from
-- | the unchanged holder in the next broadcast and enters backoff.
-- | `YieldPen` releases a held Pen.  `ForcePen` takes the Pen if the
-- | current holder has been idle past the server's threshold (60s by
-- | default).  `Heartbeat` extends the holder's lease.
data ClientMsg
  = RequestPen
  | YieldPen
  | ForcePen
  | Heartbeat

clientMsgCodec :: JsonCodec ClientMsg
clientMsgCodec = CA.codec' decode encode
  where
  decode json = case AJ.toObject json of
    Nothing -> Left (TypeMismatch "ClientMsg object")
    Just o -> case Object.lookup "type" o >>= AJ.toString of
      Just "request-pen" -> Right RequestPen
      Just "yield-pen" -> Right YieldPen
      Just "force-pen" -> Right ForcePen
      Just "heartbeat" -> Right Heartbeat
      Just tag -> Left (UnexpectedValue (AJ.fromString tag))
      Nothing -> Left (AtKey "type" MissingValue)
  encode = case _ of
    RequestPen -> tagged "request-pen" []
    YieldPen -> tagged "yield-pen" []
    ForcePen -> tagged "force-pen" []
    Heartbeat -> tagged "heartbeat" []

-- | Body of a 409 response when an HTTP mutating endpoint is called
-- | without the Pen.  Lets the client show "held by <x>, idle for Ys"
-- | and decide whether to offer a `ForcePen` button.
type PenHeldBody =
  { error :: String
  , holder :: Maybe SubscriberId
  , lastActivityAt :: Number
  }

penHeldBodyCodec :: JsonCodec PenHeldBody
penHeldBodyCodec = CAR.object "PenHeldBody"
  { error: CA.string
  , holder: nullableSubscriberIdCodec
  , lastActivityAt: CA.number
  }

-- Internal helpers for tag-dispatched ADT codecs.
field :: forall a. String -> Object.Object Json -> JsonCodec a -> Either JsonDecodeError a
field key o codec = case Object.lookup key o of
  Nothing -> Left (AtKey key MissingValue)
  Just j -> case CA.decode codec j of
    Left e -> Left (AtKey key e)
    Right a -> Right a

tagged :: String -> Array (Tuple String Json) -> Json
tagged tag fields =
  AJ.fromObject (Object.fromFoldable ([ "type" /\ AJ.fromString tag ] <> fields))
