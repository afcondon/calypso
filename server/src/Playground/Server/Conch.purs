module Playground.Server.Conch
  ( ConchStore
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

import Playground.Conch (ConchState, SubscriberId)

-- | In-memory conch state, shared by the HTTP writer endpoints (which
-- | authorise against `holder`) and the WS message dispatcher (which
-- | mutates it on `request`/`yield`/`force`/heartbeats).
newtype ConchStore = ConchStore (Ref ConchState)

newStore :: Effect ConchStore
newStore = do
  now <- currentTimeMs
  ref <- Ref.new { holder: Nothing, lastActivityAt: now }
  pure (ConchStore ref)

getState :: ConchStore -> Effect ConchState
getState (ConchStore ref) = Ref.read ref

-- | How long the holder can be silent before another subscriber's
-- | `ForceConch` is allowed to succeed. 60s is the agreed default;
-- | exposed in case a test or a config knob wants to override.
idleTimeoutMs :: Number
idleTimeoutMs = 60000.0

-- | Result of a state-changing conch operation. `Granted` carries the
-- | new state and signals "broadcast this to all subscribers".
-- | `Unchanged` means the request was rejected (e.g. the conch is held
-- | by someone active) — no state change, no broadcast, and the
-- | requester's client-side backoff kicks in.
data RequestResult
  = Granted ConchState
  | Unchanged

request :: ConchStore -> SubscriberId -> Effect RequestResult
request (ConchStore ref) sid = do
  cs <- Ref.read ref
  case cs.holder of
    Nothing -> do
      now <- currentTimeMs
      let cs' = { holder: Just sid, lastActivityAt: now }
      Ref.write cs' ref
      pure (Granted cs')
    Just _ -> pure Unchanged

-- | Release a held conch. No-op if the caller isn't actually the
-- | holder (defensive — the WS dispatcher also verifies identity).
yield :: ConchStore -> SubscriberId -> Effect RequestResult
yield (ConchStore ref) sid = do
  cs <- Ref.read ref
  case cs.holder of
    Just h | h == sid -> do
      now <- currentTimeMs
      let cs' = { holder: Nothing, lastActivityAt: now }
      Ref.write cs' ref
      pure (Granted cs')
    _ -> pure Unchanged

-- | Take an idle holder's conch. Succeeds only if the current holder
-- | has been silent past `idleTimeoutMs`; otherwise the request is
-- | rejected the same as a normal `request`.
force :: ConchStore -> SubscriberId -> Effect RequestResult
force (ConchStore ref) sid = do
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
-- | `Heartbeat` messages and after every accepted HTTP write. Silent
-- | no-op if the caller doesn't hold the conch.
heartbeat :: ConchStore -> SubscriberId -> Effect Unit
heartbeat (ConchStore ref) sid = do
  cs <- Ref.read ref
  case cs.holder of
    Just h | h == sid -> do
      now <- currentTimeMs
      Ref.write (cs { lastActivityAt = now }) ref
    _ -> pure unit

-- | WS disconnect hook. If the departing subscriber held the conch,
-- | release it and return the new state for broadcast.
onDisconnect :: ConchStore -> SubscriberId -> Effect RequestResult
onDisconnect (ConchStore ref) sid = do
  cs <- Ref.read ref
  case cs.holder of
    Just h | h == sid -> do
      now <- currentTimeMs
      let cs' = { holder: Nothing, lastActivityAt: now }
      Ref.write cs' ref
      pure (Granted cs')
    _ -> pure Unchanged

foreign import currentTimeMs :: Effect Number
