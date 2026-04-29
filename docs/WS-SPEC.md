# HTTPurple WebSocket upgrade — design spec

**Status:** draft, not yet implemented. Against HTTPurple 4.0.0.
**Target consumer:** Atelier (`purescript-playground`), to replace its 2s `GET /session` poll with a push channel. Written so it could double as an upstream PR description for `sigma-andex/purescript-httpurple`.

## Motivation

HTTPurple 4.0.0 treats every request as an HTTP request/response pair driven by `handleRequest` inside `Server.purs:serveInternal` (lines 209–247). The resulting `net.Server` is created from the Node `http` server via `HTTP.createServer` and `EE.on_ HServer.requestH handler`, and that is the only event handler attached. The Node `http.Server` also emits an `'upgrade'` event when a client presents the standard WebSocket handshake headers (`Connection: Upgrade`, `Upgrade: websocket`); HTTPurple currently discards that event, so WebSocket upgrade requests fall through as unmatched HTTP and return 404/400.

We want routes to be able to opt in to WebSocket upgrade, receive framed text/binary messages, send to a single socket, broadcast to a named subscriber group, and participate in the server's normal shutdown.

## Design goals

- **Zero impact on existing users.** `serve`, `serveNodeMiddleware`, and any existing route handler keeps compiling and behaving identically. The WS surface is additive.
- **Idiomatic HTTPurple.** Routes stay `RouteDuplex'`-driven; the WS opt-in looks like any other typed route. No stringy keys, no global registries that users have to thread.
- **Typed messages are a user concern, not the framework's.** The primitive send/broadcast shuttles `String` (text frame) and `Buffer` (binary frame). Codec layering on top is the caller's problem, same as HTTPurple treats JSON bodies today.
- **Subscriber tracking is a first-class primitive.** The common case (Atelier's case) is "broadcast the new session snapshot to every client currently connected to `/session/ws`". A `Channel` type owns that set so users don't reinvent it.
- **Safe to call from `Aff`.** The user-visible send/broadcast primitives are `Aff`-valued; the FFI-uncurried `Effect` forms are internal.
- **Clean lifecycle.** When HTTPurple's existing `closingHandler` fires, all open sockets close with code 1001 and no further broadcasts succeed. Stale sockets self-prune on `'close'`/`'error'`.
- **Polymorphic socket type from day one.** `send`/`close`/`isOpen` live on a class `IsSocket s`. The server-side concrete is `ServerSocket`; task #2's browser-side `BrowserSocket` slots in as a second instance without touching existing call sites. (Browser support is *out of scope* for this spec; the class exists to pre-empt the refactor.)

## Route opt-in shape

### The new response variant

We extend `Response` with a third constructor-like state via a new type, rather than bolting a special case into the existing record. Today `Response` is:

```purescript
type Response =
  { status :: Status
  , headers :: ResponseHeaders
  , writeBody :: ServerResponse -> Aff Unit
  }
```

`ResponseM = Aff Response`. We introduce `ResponseOrUpgrade`:

```purescript
data ResponseOrUpgrade
  = HttpResponse Response
  | WsUpgrade WsHandler

type ResponseM = Aff ResponseOrUpgrade   -- redefined
```

and adjust the `ok`/`notFound`/... smart constructors to return `ResponseM` that wraps `HttpResponse`. All existing route handlers compile unchanged because their return type never mentions the constructor — the helpers in `HTTPurple.Response` are the only authors of `HttpResponse`. The router dispatches on the tag.

**Rationale for not using a combinator wrapping the handler.** A combinator (`wsRoute :: (Request route -> Aff WsHandler) -> ...`) forces the user's routes to fork into two shapes (HTTP routes vs WS routes). A union response type keeps a single `router :: Request -> ResponseM`, so a route can *decide* per-request whether to upgrade or serve a normal HTTP body based on headers or auth state — which is exactly what the `ws` ecosystem lets you do, and what we need at the end of task #2 when an unauthenticated GET of `/session/ws` should return 401.

### A WS handler and its callbacks

```purescript
newtype WsHandler = WsHandler
  { onOpen    :: ServerSocket -> Aff Unit
  , onMessage :: ServerSocket -> Message -> Aff Unit
  , onClose   :: ServerSocket -> CloseReason -> Aff Unit
  , onError   :: ServerSocket -> Error -> Aff Unit
  }

data Message
  = TextMessage String
  | BinaryMessage ArrayBuffer   -- same type on server and browser sides

type CloseReason =
  { code :: Int, reason :: String, wasClean :: Boolean }
```

`onOpen` fires after the WS handshake has been accepted and the socket is live. `onMessage` is the hot path. `onClose` fires exactly once per socket; `onError` may fire zero or more times before `onClose` (matches `ws`'s event model).

A convenience smart constructor handles the common "I only care about onMessage" case:

```purescript
wsHandler ::
  { onMessage :: ServerSocket -> Message -> Aff Unit
  , onOpen    :: ServerSocket -> Aff Unit           -- optional defaults
  , onClose   :: ServerSocket -> CloseReason -> Aff Unit
  , onError   :: ServerSocket -> Error -> Aff Unit
  }
  -> WsHandler
```

with `onOpen`/`onClose`/`onError` defaulting to `\_ _ -> pure unit` via Justifill.

## Socket primitives

Polymorphic from day one — the server and (future) browser concretes share a class so user code parameterised by `IsSocket s` ports without changes.

```purescript
class IsSocket s where
  send   :: s -> Message -> Aff Unit
  close  :: s -> Int -> String -> Aff Unit
  isOpen :: s -> Effect Boolean

-- Server-side concrete. Browser-side `BrowserSocket` lands in task #2 as
-- a pure addition (new instance, no call-site changes).
newtype ServerSocket = ServerSocket RawWebSocket   -- RawWebSocket :: foreign (ws.WebSocket)

instance IsSocket ServerSocket where ...

-- Convenience (class-polymorphic):
sendText   :: forall s. IsSocket s => s -> String -> Aff Unit
sendBinary :: forall s. IsSocket s => s -> ArrayBuffer -> Aff Unit
```

`send` completes its `Aff` when `ws`'s send-callback fires (success) or rejects with the callback's `Error` (backpressure, socket closed mid-send, etc.). `sendText` / `sendBinary` are convenience forms that wrap the matching `Message` constructor; `send` dispatches on `Message`.

`close` is idempotent; sending to a closed socket rejects the `Aff` with a `Error.error "socket closed"` that the user can catch. `broadcast` never raises per-socket errors — it logs them and continues.

`ServerSocket` identity is pointer identity on the underlying `ws.WebSocket`. We add an FFI `refEq` + identity-hash to support `Eq`/`Ord` so `Set ServerSocket` works for `Channel` membership.

## Subscriber tracking — `Channel`

```purescript
newtype Channel = Channel (Ref (Set ServerSocket))

-- Channels are born attached to their server, so shutdown auto-closes
-- every socket they hold. `serverChannel` is the only public constructor.
serverChannel :: ServerHandle -> Effect Channel

join      :: Channel -> ServerSocket -> Effect Unit
leave     :: Channel -> ServerSocket -> Effect Unit
broadcast :: Channel -> Message -> Aff Unit        -- sends to all, skipping closed; best-effort
members   :: Channel -> Effect (Array ServerSocket)
```

Channels are a server-side concept (fan-out across many connected clients), so `Channel` is concrete over `ServerSocket` rather than polymorphic. The `IsSocket s` polymorphism applies to per-socket operations (`send`/`close`/`isOpen`), which port to the browser; broadcast fan-out does not.

Because `serverChannel` needs a `ServerHandle` to auto-register, routing setup moves into a callback that runs once the handle exists. A typical Atelier-style usage:

```purescript
main :: Effect Unit
main =
  void $ serveWithHandle { port: Just 3050 } \handle -> do
    sessionChan <- serverChannel handle
    pure
      { route:  sessionRoute
      , router: sessionRouter sessionChan
      }

sessionRouter :: Channel -> Request SessionRoute -> ResponseM
sessionRouter chan { route: SessionWs } = pure $ WsUpgrade $ WsHandler
  { onOpen:    \s -> liftEffect (join chan s) *> sendCurrentSnapshot s
  , onMessage: \_ _ -> pure unit   -- read-only stream
  , onClose:   \s _ -> liftEffect (leave chan s)
  , onError:   \_ _ -> pure unit
  }
sessionRouter _ req = httpRouter req   -- ordinary handlers wrap via HttpResponse
```

Apps that only want HTTP keep using plain `serve`; `serveWithHandle` is the opt-in for channel-using apps.

**Why `Set ServerSocket` (identity) instead of tagged tokens?** Because the socket *is* the identity in the `ws` world, and we want `join`/`leave` to be O(1) on the socket we already hold in the handler closure. If a caller needs subject-tagged broadcast ("everyone subscribed to session *42*"), they allocate a `Map String Channel` themselves — the framework stays small.

## Concurrency and lifetime

1. **Shutdown.** `serveInternal` already registers a closing handler that calls `NServer.close netServer`. We extend it: the closing handler also iterates every `Channel` registered at the server level and calls `close s 1001 "Server shutting down"` on each socket. Registration happens automatically inside `serverChannel handle` — the channel is born attached to its server, so the user can never forget.
2. **Send races close.** `send`'s `Aff` resolves via `ws`'s callback. If the socket closed between "check state" and "write frame", `ws` delivers the error to the callback and we reject the `Aff`. `broadcast` swallows per-socket rejections (logs via `Effect.Console.error`) and continues — broadcast is best-effort by design. A failing socket typically emits `'close'` right after; `onClose` fires and the user's `leave chan s` prunes it.
3. **Stale subscribers.** A `Channel` is a `Ref (Set Socket)`. On `'close'`/`'error'` the framework fires the user's `onClose` / `onError`; the user is expected to call `leave`. A convenience `wsHandlerFor :: Channel -> (Socket -> Message -> Aff Unit) -> WsHandler` wires join/leave for you so the common case is a one-liner.
4. **Backpressure.** Not handled in v1. `ws.send` buffers internally and a slow consumer can run the server out of memory. We document this and leave `Socket.bufferedAmount`-based throttling to the caller; a v2 could expose a `sendBackpressured :: Socket -> Message -> Int -> Aff Unit` that drops when `bufferedAmount` exceeds a threshold.
5. **Thread safety.** Node is single-threaded; `Ref` is fine. No `AVar` needed for `Channel` state.

## Implementation sketch — keyed to `serveInternal`

Diff-shape against `Server.purs:209–247`:

```purescript
serveInternal inputOptions maybeNodeMiddleware settings = do
  channelsRef <- Ref.new ([] :: Array Channel)   -- NEW: server-scoped channels
  let
    -- ... filledOptions, host, port, onStarted as today ...
    -- NEW: we wrap the router to dispatch on ResponseOrUpgrade.
    handler = case maybeNodeMiddleware of
      Just nm -> handleExtRequestWithMiddleware' channelsRef $ merge rs { nodeMiddleware: nm }
      Nothing -> handleRequest' channelsRef rs
  -- sslOptions branch unchanged except we also bind upgradeH.
  netServer <- case sslOptions of
    Just { certFile, keyFile } -> do
      server <- HTTPS.createSecureServer' {...}
      server # EE.on_ HServer.requestH handler
      server # EE.on_ HServer.upgradeH (handleUpgrade wssRef rs)       -- NEW
      pure $ HServer.toNetServer server
    Nothing -> do
      server <- HTTP.createServer
      server # EE.on_ HServer.requestH handler
      server # EE.on_ HServer.upgradeH (handleUpgrade wssRef rs)       -- NEW
      pure $ HServer.toNetServer server
  netServer # EE.on_ listeningH onStarted
  listenTcp netServer options
  let closingHandler = do
        closeAllChannels channelsRef 1001 "Server shutting down"
        NServer.close netServer
  liftEffect $ registerClosingHandler filledOptions.closingHandler (\eff -> eff *> closingHandler)
```

Where:

- `HServer.upgradeH` is `node-http`'s `'upgrade'` event handler binding. If `Node.HTTP.Server` in `node-http-9.1.0` doesn't export it, we add a 5-line FFI stub inside HTTPurple instead of waiting for an upstream node-http release.
- `wssRef` is a single server-scoped `WebSocketServer` instance created at server startup with `{ noServer: true }` — `ws`'s supported "I'll hand you the upgrade event manually" mode.
- `handleUpgrade wssRef settings` receives the `IncomingMessage IMServer`, the raw `Net.Socket`, and the initial `head :: Buffer` that the `'upgrade'` event carries. Pseudocode:

```purescript
handleUpgrade :: forall route. Ref WebSocketServer -> RoutingSettings -> IncomingMessage IMServer -> Net.Socket -> Buffer -> Effect Unit
handleUpgrade wssRef rs req socket head = void $ runAff (\_ -> pure unit) do
  httpurpleReq <- fromHTTPRequest rs.route req
  case httpurpleReq of
    Left _ -> liftEffect $ rejectUpgrade socket 404 "Not Found"
    Right r -> do
      result <- rs.router r
      case result of
        HttpResponse _ -> liftEffect $ rejectUpgrade socket 400 "Bad Request"
        WsUpgrade (WsHandler cbs) -> liftEffect do
          wss <- Ref.read wssRef
          performHandshake wss req socket head \ws -> do
            let s = ServerSocket ws
            bindEvents s cbs
            runAff_ (\_ -> pure unit) (cbs.onOpen s)
```

- **Route-mismatch on upgrade** responds 404 on the raw socket and destroys it. We don't invoke the HTTPurple `notFoundHandler` for WS because its type returns an HTTP `Response`, which doesn't apply.
- **Handler returned `HttpResponse` for an upgrade request** responds 400 on the raw socket. (Alternative: honour it as a normal HTTP response written manually onto the raw socket — cleaner semantically but we lose the `ServerResponse` writer machinery; deferred to v2.)

### `ServerHandle` and `serveWithHandle`

`serve` continues to return the existing `ServerM` (an `Effect (Effect Unit)` closer). The new `serveWithHandle` variant exposes a `ServerHandle` to a setup callback, which is the only path through which `serverChannel` can create a channel:

```purescript
type ServerHandle =
  { close :: Effect Unit
  , -- internal: channelsRef, wssRef, etc. exposed via helpers,
    -- not as raw fields.
  }

serveWithHandle
  :: forall ...
  -> { | listenOpts }
  -> (ServerHandle -> Effect (BasicRoutingSettings route))
  -> ServerM
```

The setup callback runs synchronously during `serveInternal` after `channelsRef` exists but before the first request handler is bound, so any channel the user creates is already attached to the registry by the time the socket accepts connections.

## FFI plan

We use the `ws` npm package (pin to `ws@^9.x`, the current stable). On incoming frames we set `binaryType: "arraybuffer"` so receive and send share the `ArrayBuffer` type. New files:

- `src/HTTPurple/WebSocket.purs` — public API (`Socket`, `Message`, `WsHandler`, `send`/`close`/`Channel`/...).
- `src/HTTPurple/WebSocket.js` — FFI.
- `src/HTTPurple/WebSocket/Internal.purs` — private `ResponseOrUpgrade`, upgrade dispatcher. Not re-exported from `HTTPurple`.

### JS side (minimal)

```javascript
import { WebSocketServer } from "ws";

export const _mkWss = () => new WebSocketServer({ noServer: true });

// handleUpgrade :: WebSocketServer -> IncomingMessage -> net.Socket -> Buffer
//                -> (WebSocket -> Effect Unit) -> Effect Unit
export const _handleUpgrade = (wss) => (req) => (socket) => (head) => (cb) => () => {
  wss.handleUpgrade(req, socket, head, (ws) => { cb(ws)(); });
};

// _send :: RawWebSocket -> Foreign -> Effect Unit -> EffectFn1 Error Unit -> Effect Unit
export const _send = (ws) => (data) => (onOk) => (onErr) => () => {
  ws.send(data, (err) => {
    if (err) { onErr(err)(); } else { onOk(); }
  });
};

export const _close = (ws) => (code) => (reason) => () => {
  ws.close(code, reason);
};

export const _readyState = (ws) => () => ws.readyState;

// _on :: RawWebSocket -> String -> (Foreign -> Foreign -> Effect Unit) -> Effect Unit
// Callers normalize payload shape per event.
export const _on = (ws) => (event) => (handler) => () => {
  ws.on(event, (a, b) => handler(a)(b)());
};

export const _rejectUpgrade = (socket) => (code) => (msg) => () => {
  socket.write(`HTTP/1.1 ${code} ${msg}\r\n\r\n`);
  socket.destroy();
};
```

### PureScript side (FFI declarations)

```purescript
foreign import data WebSocketServer :: Type
foreign import data RawWebSocket    :: Type

foreign import _mkWss        :: Effect WebSocketServer
foreign import _handleUpgrade
  :: EffectFn5 WebSocketServer (IncomingMessage IMServer) Net.Socket Buffer
       (EffectFn1 RawWebSocket Unit) Unit
foreign import _send
  :: EffectFn4 RawWebSocket Foreign (Effect Unit) (EffectFn1 Error Unit) Unit
foreign import _close        :: EffectFn3 RawWebSocket Int String Unit
foreign import _readyState   :: RawWebSocket -> Effect Int
foreign import _on
  :: forall a b. EffectFn3 RawWebSocket String (EffectFn2 a b Unit) Unit
foreign import _rejectUpgrade :: EffectFn3 Net.Socket Int String Unit
```

`send` lifts `_send` into `Aff` via `makeAff`:

```purescript
send :: Socket -> Message -> Aff Unit
send (Socket ws) msg = makeAff \cb -> do
  runEffectFn4 _send ws (encodeMessage msg)
    (cb (Right unit))
    (mkEffectFn1 \err -> cb (Left err))
  pure nonCanceler
```

The `_on` wiring is `Effect` (fire-and-forget subscription). The callbacks the user provides are `Aff Unit`, so the dispatcher wraps each with `runAff_ logError (userCb arg)`.

### Effect vs Aff in the surface

| Operation                | Visible type                             | Rationale                                 |
|--------------------------|------------------------------------------|-------------------------------------------|
| `serverChannel`          | `ServerHandle -> Effect Channel`         | Ref allocation + registry wire-up          |
| `join` / `leave`         | `Channel -> ServerSocket -> Effect Unit` | Ref update                                 |
| `members`                | `Channel -> Effect (Array ServerSocket)` | Ref read                                   |
| `send` / `sendText` / `sendBinary` | `IsSocket s => s -> ... -> Aff Unit` | Waits for socket-write completion    |
| `broadcast`              | `Channel -> Message -> Aff Unit`         | Parallel-for over channel members          |
| `close`                  | `IsSocket s => s -> Int -> String -> Aff Unit` | Waits for close-frame ack (or rejects) |
| `isOpen`                 | `IsSocket s => s -> Effect Boolean`      | Synchronous readyState                     |
| Handler callbacks        | `... -> Aff Unit`                        | User's body runs in Aff, same as router    |

## What HTTPurple users have to change

**Nothing, if they don't care about WebSockets.** `serve` / `serveNodeMiddleware` keep their existing signatures and semantics. `Response` is unchanged. `ResponseM` widens from `Aff Response` to `Aff ResponseOrUpgrade`, but the public API authors `HttpResponse` entirely through smart constructors (`ok`, `notFound`, etc.), so typical callers are unaffected.

Apps that want to use WebSockets migrate to `serveWithHandle`, whose setup callback provides the `ServerHandle` needed to construct channels. This is the only way to obtain a `Channel`, because channels must be server-attached for auto-close to work.

## Decisions (2026-04-21)

Resolved with Andrew during the kickoff review; spec above reflects these:

1. **Local fork, not upstream.** `ResponseM` unifies to `Aff ResponseOrUpgrade`. If the maintainer later signals interest in a PR, we redo the separation as a non-breaking `serveWithUpgrade`/`ResponseOrUpgradeM` layer — but not pre-emptively.
2. **Channels auto-close on server shutdown.** `Channel` is only constructible via `serverChannel :: ServerHandle -> Effect Channel`, which registers with the server's registry at birth. Shutdown iterates the registry and closes every socket with code 1001. No user-remembered `registerChannel` step. Drives the `serveWithHandle` setup-callback shape.
3. **Binary messages carry `ArrayBuffer`, not `Buffer`.** Symmetric with the browser side in task #2, at the cost of a cheap `Buffer -> ArrayBuffer` view on the Node side (`new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength).buffer`). `ws` configured with `binaryType: "arraybuffer"` on incoming.
4. **Polymorphic socket type from day one.** `class IsSocket s` with `send`/`close`/`isOpen`. `ServerSocket` is the day-one instance; `BrowserSocket` slots in as a pure addition in task #2.
5. **`ws@^9.x` (current stable), not `^8.x`.** If a blocker appears during implementation we'll drop to `^8.x` and document why.
6. **sturdy-garbanzo parked.** Andrew has no load-bearing memory of it; treating as non-input for this spec.

Open verifications remaining (discover-at-implementation, not blockers):

- **`HServer.upgradeH` binding availability** in `node-http 9.1.0`. If `Node.HTTP.Server` doesn't export it, we add a 5-line FFI stub inside HTTPurple.
- **TLS / `wss://`.** The HTTPS path returns a `TLSServer` whose underlying socket satisfies the `net.Socket` interface `ws.handleUpgrade` expects. Spec assumes this; confirm with a handshake over HTTPS in the first implementation pass.

## Out of scope for task #1

- Browser-side `WebSocket` wrapper matching this API (task #2).
- Per-channel tagging, subject-based routing, pub/sub brokers.
- Heartbeat/keep-alive frames (user can layer; `ws` auto-handles ping/pong).
- Reconnect semantics (client-side concern).
- Backpressure primitives beyond a `bufferedAmount` read.
- Any changes to Atelier itself — this spec is about HTTPurple.

## Success criteria for the patch that follows

- `spago build` green with the local HTTPurple fork wired as an extraPackage of `purescript-playground`.
- A small example module in the fork's `test/` or `example/` dir that opens an HTTPurple server with one HTTP route and one WS route, echoes on receive, plus a Node client that connects, sends, receives, closes.
- `serve` (no-upgrade) regression: existing HTTPurple examples still compile and run bit-identically.
- Clean shutdown: `closingHandler` fires on SIGINT, all sockets close with code 1001, server exits.

## File layout (for the implementation PR)

```
src/HTTPurple/
  WebSocket.purs          -- public: class IsSocket, ServerSocket,
                          --         Message, WsHandler,
                          --         send, sendText, sendBinary,
                          --         close, isOpen,
                          --         Channel, serverChannel, join,
                          --         leave, broadcast, members,
                          --         wsHandler, wsHandlerFor,
                          --         ServerHandle, serveWithHandle
  WebSocket.js            -- FFI
  WebSocket/Internal.purs -- private: ResponseOrUpgrade,
                          --          handleUpgrade, performHandshake,
                          --          rejectUpgrade, channelsRef
  Server.purs             -- edited: serveInternal wires upgradeH and
                          --         channelsRef, closingHandler closes
                          --         channels; adds serveWithHandle
  Response.purs           -- edited: smart ctors return HttpResponse ..
```

Existing `Server.purs` exports (`serve`, `serveNodeMiddleware`) keep their current *call* signatures. `ResponseM` widens to `Aff ResponseOrUpgrade`, which is a source-compatible change for all callers that go through the `Response` smart constructors.
