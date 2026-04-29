module Playground.Server.Subscribers
  ( Subscribers
  , newSubscribers
  , register
  , unregister
  , idFor
  , members
  , broadcast
  , closeAll
  ) where

import Prelude

import Data.Array (filter)
import Data.Either (Either(..))
import Data.Foldable (for_, traverse_)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, attempt, launchAff_)
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Effect.Exception as Exception
import Effect.Ref (Ref)
import Effect.Ref as Ref

import HTTPurple.WebSocket (ServerSocket, close, send)
import HTTPurple.WebSocket.Types (Message)

import Playground.Conch (SubscriberId(..))

-- | Live WebSocket subscribers, keyed by their `ServerSocket`. Keying
-- | on the socket (rather than the id) matches the shape of
-- | `WsHandler.onMessage`: the framework hands us the socket, and we
-- | look up which id it was issued. HTTP authorisation doesn't need
-- | the reverse — the `X-Atelier-Subscriber-Id` header is compared
-- | directly against the conch holder without a socket round-trip.
newtype Subscribers = Subscribers (Ref (Map ServerSocket SubscriberId))

newSubscribers :: Effect Subscribers
newSubscribers = Subscribers <$> Ref.new Map.empty

-- | FFI-minted opaque id, unique for this server's lifetime. Backed by
-- | `crypto.randomUUID()` on Node ≥14.17 / ≥15.6; falls back to a
-- | 12-char base-36 string on older runtimes. Guessability is fine
-- | for local dev; before any network exposure, swap to a
-- | cryptographically-strong 32+ char token and document it.
foreign import _freshId :: Effect String

-- | Issue a fresh id for a newly-connected socket and track it.
register :: Subscribers -> ServerSocket -> Effect SubscriberId
register (Subscribers ref) sock = do
  raw <- _freshId
  let sid = SubscriberId raw
  Ref.modify_ (Map.insert sock sid) ref
  pure sid

-- | Drop a socket from the registry on WS close.
unregister :: Subscribers -> ServerSocket -> Effect Unit
unregister (Subscribers ref) sock = Ref.modify_ (Map.delete sock) ref

-- | Which id is this socket registered under, if any? Used in
-- | `onMessage` / `onClose` / `onError` to identify the subscriber
-- | before dispatching to the conch state machine.
idFor :: Subscribers -> ServerSocket -> Effect (Maybe SubscriberId)
idFor (Subscribers ref) sock = Map.lookup sock <$> Ref.read ref

members :: Subscribers -> Effect (Array (Tuple ServerSocket SubscriberId))
members (Subscribers ref) = Map.toUnfoldable <$> Ref.read ref

-- | Fan out a message to every subscriber except the optionally-excluded
-- | one. Per-socket failures are logged and skipped (best-effort match
-- | with HTTPurple's own `broadcast` semantics).
broadcast :: Subscribers -> Maybe SubscriberId -> Message -> Aff Unit
broadcast subs exclude msg = do
  entries <- liftEffect $ members subs
  let targets = filter (\(Tuple _ sid) -> excludeMiss sid) entries
  traverse_ sendOne targets
  where
  excludeMiss sid = case exclude of
    Nothing -> true
    Just e -> sid /= e
  sendOne (Tuple sock _) = do
    r <- attempt (send sock msg)
    case r of
      Right _ -> pure unit
      Left e -> liftEffect $ Console.error $
        "Subscribers.broadcast: " <> Exception.message e

-- | Shutdown hook: close every subscriber socket. Registered with
-- | HTTPurple's `ServerHandle.registerChannel` from Main so that SIGINT
-- | tears down every WS connection with code 1001 before the HTTP
-- | server closes.
closeAll :: Subscribers -> Int -> String -> Effect Unit
closeAll subs code reason = do
  entries <- members subs
  for_ entries \(Tuple sock _) ->
    launchAff_ (close sock code reason)
