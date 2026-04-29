module Playground.Conch where

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

import Playground.Session (CompileResponse, compileResponseCodec)

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

-- | Turn-based write permission. `holder` is `Nothing` when nobody has
-- | the conch; mutating HTTP endpoints reject writes in that state with
-- | a 409. `lastActivityAt` is ms-since-epoch of the holder's most
-- | recent heartbeat or accepted write — clients show it as an idle
-- | indicator, and the server uses it to decide whether `ForceConch`
-- | from another subscriber should succeed.
type ConchState =
  { holder :: Maybe SubscriberId
  , lastActivityAt :: Number
  }

conchStateCodec :: JsonCodec ConchState
conchStateCodec = CAR.object "ConchState"
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
-- | compile response. The server skips the current conch holder when
-- | fanning out (they already have the state they just wrote).
-- |
-- | `ConchUpdate` fires on any conch state transition — grant, yield,
-- | force, idle-revoke.
data Broadcast
  = Welcome
      { yourId :: SubscriberId
      , conch :: ConchState
      , snapshot :: CompileResponse
      }
  | Snapshot
      { conch :: ConchState
      , snapshot :: CompileResponse
      }
  | ConchUpdate
      { conch :: ConchState
      }

broadcastCodec :: JsonCodec Broadcast
broadcastCodec = CA.codec' decode encode
  where
  decode json = case AJ.toObject json of
    Nothing -> Left (TypeMismatch "Broadcast object")
    Just o -> case Object.lookup "type" o >>= AJ.toString of
      Just "welcome" -> do
        yid <- field "yourId" o subscriberIdCodec
        cs <- field "conch" o conchStateCodec
        sn <- field "snapshot" o compileResponseCodec
        Right (Welcome { yourId: yid, conch: cs, snapshot: sn })
      Just "snapshot" -> do
        cs <- field "conch" o conchStateCodec
        sn <- field "snapshot" o compileResponseCodec
        Right (Snapshot { conch: cs, snapshot: sn })
      Just "conch" -> do
        cs <- field "conch" o conchStateCodec
        Right (ConchUpdate { conch: cs })
      Just tag -> Left (UnexpectedValue (AJ.fromString tag))
      Nothing -> Left (AtKey "type" MissingValue)
  encode = case _ of
    Welcome r -> tagged "welcome"
      [ "yourId" /\ CA.encode subscriberIdCodec r.yourId
      , "conch" /\ CA.encode conchStateCodec r.conch
      , "snapshot" /\ CA.encode compileResponseCodec r.snapshot
      ]
    Snapshot r -> tagged "snapshot"
      [ "conch" /\ CA.encode conchStateCodec r.conch
      , "snapshot" /\ CA.encode compileResponseCodec r.snapshot
      ]
    ConchUpdate r -> tagged "conch"
      [ "conch" /\ CA.encode conchStateCodec r.conch
      ]

-- | Messages a subscriber sends to the server over the WS connection.
-- | `RequestConch` asks for write permission; server replies with a
-- | `ConchUpdate` on grant, or (on denial) silently — the client reads
-- | denial from the unchanged holder in the next broadcast and enters
-- | backoff. `YieldConch` releases a held conch. `ForceConch` takes the
-- | conch if the current holder has been idle past the server's
-- | threshold (60s by default). `Heartbeat` extends the holder's lease.
data ClientMsg
  = RequestConch
  | YieldConch
  | ForceConch
  | Heartbeat

clientMsgCodec :: JsonCodec ClientMsg
clientMsgCodec = CA.codec' decode encode
  where
  decode json = case AJ.toObject json of
    Nothing -> Left (TypeMismatch "ClientMsg object")
    Just o -> case Object.lookup "type" o >>= AJ.toString of
      Just "request-conch" -> Right RequestConch
      Just "yield-conch" -> Right YieldConch
      Just "force-conch" -> Right ForceConch
      Just "heartbeat" -> Right Heartbeat
      Just tag -> Left (UnexpectedValue (AJ.fromString tag))
      Nothing -> Left (AtKey "type" MissingValue)
  encode = case _ of
    RequestConch -> tagged "request-conch" []
    YieldConch -> tagged "yield-conch" []
    ForceConch -> tagged "force-conch" []
    Heartbeat -> tagged "heartbeat" []

-- | Body of a 409 response when an HTTP mutating endpoint is called
-- | without the conch. Lets the client show "held by <x>, idle for Ys"
-- | and decide whether to offer a `ForceConch` button.
type ConchHeldBody =
  { error :: String
  , holder :: Maybe SubscriberId
  , lastActivityAt :: Number
  }

conchHeldBodyCodec :: JsonCodec ConchHeldBody
conchHeldBodyCodec = CAR.object "ConchHeldBody"
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
