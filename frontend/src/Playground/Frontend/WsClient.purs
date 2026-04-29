module Playground.Frontend.WsClient
  ( WebSocket
  , Callbacks
  , connect
  , send
  , close
  ) where

import Prelude

import Effect (Effect)
import Effect.Uncurried
  ( EffectFn1
  , EffectFn2
  , runEffectFn1
  , runEffectFn2
  )

-- | Opaque handle over the browser `WebSocket` instance. Keep hold of
-- | it to `send` frames or to `close` the connection explicitly — the
-- | runtime also closes it automatically when the page unloads.
foreign import data WebSocket :: Type

-- | Event callbacks a client registers with a new connection. The
-- | framework fires `onOpen` once after the handshake, `onMessage` once
-- | per incoming text frame (binary frames aren't wired — Atelier only
-- | exchanges JSON), `onClose` once when the socket closes cleanly or
-- | abnormally, and `onError` zero or more times on transport errors
-- | (may precede an `onClose`).
type Callbacks =
  { onOpen :: Effect Unit
  , onMessage :: String -> Effect Unit
  , onClose :: Int -> String -> Effect Unit
  , onError :: Effect Unit
  }

foreign import _connect :: EffectFn2 String Callbacks WebSocket
foreign import _send :: EffectFn2 WebSocket String Unit
foreign import _close :: EffectFn1 WebSocket Unit

-- | Open a connection to the given URL and register the callbacks. The
-- | returned handle is live immediately but `onOpen` fires only after
-- | the WS handshake completes.
connect :: String -> Callbacks -> Effect WebSocket
connect url cbs = runEffectFn2 _connect url cbs

-- | Send a text frame. Silent no-op if the socket isn't open yet —
-- | callers should wait for `onOpen` before the first send.
send :: WebSocket -> String -> Effect Unit
send ws s = runEffectFn2 _send ws s

-- | Close the connection. Server's `onClose` fires shortly after with
-- | a clean close code.
close :: WebSocket -> Effect Unit
close ws = runEffectFn1 _close ws
