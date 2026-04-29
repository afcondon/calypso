module Calypso.Server.Pen
  ( PenStore
  , RequestResult(..)
  , newStore
  , getState
  , request
  , yield
  , force
  , heartbeat
  , onDisconnect
  , idleTimeoutMs
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Ref (Ref)
import Effect.Ref as Ref

import Calypso.Pen (PenState, SubscriberId)

-- | In-memory Pen state, shared by the HTTP writer endpoints (which
-- | authorise against `holder`) and the WS message dispatcher (which
-- | mutates it on `request`/`yield`/`force`/heartbeats).
newtype PenStore = PenStore (Ref PenState)

newStore :: Effect PenStore
newStore = do
  now <- currentTimeMs
  ref <- Ref.new { holder: Nothing, lastActivityAt: now }
  pure (PenStore ref)

getState :: PenStore -> Effect PenState
getState (PenStore ref) = Ref.read ref

-- | How long the holder can be silent before another subscriber's
-- | `ForcePen` is allowed to succeed. 60s is the agreed default;
-- | exposed in case a test or a config knob wants to override.
idleTimeoutMs :: Number
idleTimeoutMs = 60000.0

-- | Result of a state-changing Pen operation.  `Granted` carries the
-- | new state and signals "broadcast this to all subscribers".
-- | `Unchanged` means the request was rejected (e.g. the Pen is held
-- | by someone active) — no state change, no broadcast, and the
-- | requester's client-side backoff kicks in.
data RequestResult
  = Granted PenState
  | Unchanged

request :: PenStore -> SubscriberId -> Effect RequestResult
request (PenStore ref) sid = do
  cs <- Ref.read ref
  case cs.holder of
    Nothing -> do
      now <- currentTimeMs
      let cs' = { holder: Just sid, lastActivityAt: now }
      Ref.write cs' ref
      pure (Granted cs')
    Just _ -> pure Unchanged

-- | Release a held Pen.  No-op if the caller isn't actually the
-- | holder (defensive — the WS dispatcher also verifies identity).
yield :: PenStore -> SubscriberId -> Effect RequestResult
yield (PenStore ref) sid = do
  cs <- Ref.read ref
  case cs.holder of
    Just h | h == sid -> do
      now <- currentTimeMs
      let cs' = { holder: Nothing, lastActivityAt: now }
      Ref.write cs' ref
      pure (Granted cs')
    _ -> pure Unchanged

-- | Take an idle holder's Pen.  Succeeds only if the current holder
-- | has been silent past `idleTimeoutMs`; otherwise the request is
-- | rejected the same as a normal `request`.
force :: PenStore -> SubscriberId -> Effect RequestResult
force (PenStore ref) sid = do
  cs <- Ref.read ref
  now <- currentTimeMs
  case cs.holder of
    Nothing -> do
      let cs' = { holder: Just sid, lastActivityAt: now }
      Ref.write cs' ref
      pure (Granted cs')
    Just _ ->
      if now - cs.lastActivityAt >= idleTimeoutMs
        then do
          let cs' = { holder: Just sid, lastActivityAt: now }
          Ref.write cs' ref
          pure (Granted cs')
        else pure Unchanged

-- | Touch the activity timestamp — called on holder-originated
-- | `Heartbeat` messages and after every accepted HTTP write.  Silent
-- | no-op if the caller doesn't hold the Pen.
heartbeat :: PenStore -> SubscriberId -> Effect Unit
heartbeat (PenStore ref) sid = do
  cs <- Ref.read ref
  case cs.holder of
    Just h | h == sid -> do
      now <- currentTimeMs
      Ref.write (cs { lastActivityAt = now }) ref
    _ -> pure unit

-- | WS disconnect hook.  If the departing subscriber held the Pen,
-- | release it and return the new state for broadcast.
onDisconnect :: PenStore -> SubscriberId -> Effect RequestResult
onDisconnect (PenStore ref) sid = do
  cs <- Ref.read ref
  case cs.holder of
    Just h | h == sid -> do
      now <- currentTimeMs
      let cs' = { holder: Nothing, lastActivityAt: now }
      Ref.write cs' ref
      pure (Granted cs')
    _ -> pure Unchanged

foreign import currentTimeMs :: Effect Number
