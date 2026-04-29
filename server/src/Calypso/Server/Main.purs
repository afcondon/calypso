module Calypso.Server.Main where

import Prelude

import Data.Argonaut.Core (stringify, toObject)
import Data.Argonaut.Core as AJ
import Data.Argonaut.Parser (jsonParser)
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Foreign.Object as Object
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Effect.Aff (Aff)
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import HTTPurple
  ( Method(..)
  , Request
  , ResponseM
  , ResponseOrUpgrade(..)
  , ServerM
  , badRequest'
  , conflict'
  , ok'
  , response'
  , serveWithHandle
  , toString
  )
import HTTPurple.Status as Status
import HTTPurple.Headers (ResponseHeaders, headers)
import HTTPurple.Lookup ((!!))
import HTTPurple.WebSocket
  ( Message(..)
  , ServerSocket
  , sendText
  , wsHandler
  )
import HTTPurple.WebSocket.Types (WsHandler)
import Routing.Duplex (RouteDuplex', flag, root, segment)
import Routing.Duplex.Generic (noArgs, sum)
import Routing.Duplex.Generic.Syntax ((/), (?))

import Data.Int as Int
import Calypso.Server.Conch (ConchStore, RequestResult(..))
import Calypso.Server.Conch as Conch
import Calypso.Server.Favorites as Favorites
import Calypso.Server.Session (EvalRequest, EvalResponse, ModulePatch(..), SessionStore, evalResponseCodec)
import Calypso.Server.Session as Session
import Calypso.Server.Subscribers (Subscribers)
import Calypso.Server.Subscribers as Subscribers
import Data.String as String
import Calypso.Conch
  ( Broadcast(..)
  , SubscriberId(..)
  , broadcastCodec
  , clientMsgCodec
  , conchHeldBodyCodec
  )
import Calypso.Conch as PConch
import Calypso.Favorite (favoritesCodec)
import Calypso.Session
  ( Cell
  , CompileError(..)
  , CompileRequest(..)
  , CompileResponse(..)
  , UserModule(..)
  , compileRequestCodec
  , compileResponseCodec
  )

data Route
  = Health
  | SessionGet
  | SessionWs
  | SessionCompile
  | SessionModule { preview :: Boolean }
  | SessionCellAppend { preview :: Boolean }
  | SessionCellAt String { preview :: Boolean }
  -- Single-shot eval — POST cell text, get the daemon's reply line.
  | Eval
  -- GET-only listing of `~/.calypso/favorites/*.tidal` — composition-pane
  -- templates the user keeps cross-machine.  Loaded into the dropdown.
  | FavoritesRoute

derive instance Generic Route _

route :: RouteDuplex' Route
route = root $ sum
  { "Health": "health" / noArgs
  , "SessionGet": "session" / noArgs
  , "SessionWs": "session" / "ws" / noArgs
  , "SessionCompile": "session" / "compile" / noArgs
  , "SessionModule": "session" / "module" ? { preview: flag }
  , "SessionCellAppend": "session" / "cells" ? { preview: flag }
  , "SessionCellAt": "session" / "cells" / segment ? { preview: flag }
  , "Eval": "eval" / noArgs
  , "FavoritesRoute": "favorites" / noArgs
  }

-- ============================================================
-- Body codecs (ad-hoc for each endpoint's expected shape)
-- ============================================================

moduleBodyCodec :: JsonCodec { source :: String }
moduleBodyCodec = CAR.object "ModuleBody" { source: CA.string }

cellAppendBodyCodec :: JsonCodec { source :: String, kind :: String }
cellAppendBodyCodec = CAR.object "CellAppendBody"
  { source: CA.string
  , kind: CA.string
  }

-- | PATCH-body decoder: fields are genuinely optional (missing key
-- | means "don't change"). We don't use a codec here because
-- | codec-argonaut's `maybe` combinator expects a tagged-object wire
-- | form for `Maybe`, not the missing-vs-present convention HTTP
-- | clients will naturally use.
parseCellPatch :: String -> Either String { source :: Maybe String, kind :: Maybe String, form :: Maybe Boolean }
parseCellPatch raw = case jsonParser raw of
  Left e -> Left ("bad JSON: " <> e)
  Right j -> case toObject j of
    Nothing -> Left "bad request: expected a JSON object"
    Just o -> do
      source <- pickStr "source" o
      kind <- pickStr "kind" o
      form <- pickBool "form" o
      pure { source, kind, form }
  where
  pickStr key o = case Object.lookup key o of
    Nothing -> Right Nothing
    Just v -> case AJ.toString v of
      Just s -> Right (Just s)
      Nothing -> Left ("bad request: " <> key <> " must be a string")
  pickBool key o = case Object.lookup key o of
    Nothing -> Right Nothing
    Just v -> case AJ.toBoolean v of
      Just b -> Right (Just b)
      Nothing -> Left ("bad request: " <> key <> " must be a boolean")

-- | PATCH /session/module body decoder. Body must be a JSON object
-- | containing exactly one of:
-- |   {"addImport": "Data.Array"}
-- |   {"addImport": {"module": "Data.Array", "alias": "Array",
-- |                  "names": ["length", "take"]}} (alias + names optional)
-- |   {"appendBody": "...source..."}
-- |   {"replaceRange": {"startLine": N, "endLine": M, "text": "..."}}
parseModulePatch :: String -> Either String ModulePatch
parseModulePatch raw = case jsonParser raw of
  Left e -> Left ("bad JSON: " <> e)
  Right j -> case toObject j of
    Nothing -> Left "bad request: expected a JSON object"
    Just o ->
      case Object.lookup "addImport" o, Object.lookup "appendBody" o, Object.lookup "replaceRange" o of
        Just v, Nothing, Nothing -> AddImport <$> parseImportSpec v
        Nothing, Just v, Nothing -> case AJ.toString v of
          Just s -> Right (AppendBody s)
          Nothing -> Left "appendBody must be a string"
        Nothing, Nothing, Just v -> parseReplaceRange v
        Nothing, Nothing, Nothing ->
          Left "expected one of: addImport, appendBody, replaceRange"
        _, _, _ ->
          Left "expected exactly one of: addImport, appendBody, replaceRange"
  where
  parseImportSpec v = case AJ.toString v of
    Just s -> Right { "module": s, alias: Nothing, names: Nothing }
    Nothing -> case toObject v of
      Nothing -> Left "addImport must be a string or {module, alias?, names?} object"
      Just o -> do
        m <- pickStr "module" o
        a <- pickOptStr "alias" o
        ns <- pickOptStrArray "names" o
        pure { "module": m, alias: a, names: ns }
  parseReplaceRange v = case toObject v of
    Nothing -> Left "replaceRange must be an object"
    Just o -> do
      sl <- pickInt "startLine" o
      el <- pickInt "endLine" o
      tx <- pickStr "text" o
      pure (ReplaceRange { startLine: sl, endLine: el, text: tx })
  pickInt key o = case Object.lookup key o of
    Nothing -> Left ("missing field: " <> key)
    Just v -> case AJ.toNumber v of
      Nothing -> Left (key <> " must be a number")
      Just n -> case Int.fromNumber n of
        Just i -> Right i
        Nothing -> Left (key <> " must be a non-fractional number")
  pickStr key o = case Object.lookup key o of
    Nothing -> Left ("missing field: " <> key)
    Just v -> case AJ.toString v of
      Just s -> Right s
      Nothing -> Left (key <> " must be a string")
  pickOptStr key o = case Object.lookup key o of
    Nothing -> Right Nothing
    Just v -> case AJ.toString v of
      Just s -> Right (Just s)
      Nothing -> Left (key <> " must be a string when present")
  pickOptStrArray key o = case Object.lookup key o of
    Nothing -> Right Nothing
    Just v -> case AJ.toArray v of
      Nothing -> Left (key <> " must be an array when present")
      Just arr -> do
        strs <- traverse (asString key) arr
        pure (Just strs)
  asString key v = case AJ.toString v of
    Just s -> Right s
    Nothing -> Left (key <> " entries must be strings")

-- ============================================================
-- Response assembly
-- ============================================================

snapshotJson :: CompileResponse -> String
snapshotJson = stringify <<< CA.encode compileResponseCodec

errorSnapshotJson :: String -> String -> String
errorSnapshotJson code msg =
  stringify $ CA.encode compileResponseCodec $
    CompileResponse
      { js: Nothing
      , warnings: []
      , errors:
          [ CompileError { code, filename: Nothing, position: Nothing, message: msg } ]
      , types: []
      , cellLines: []
      , emits: []
      , runtime: "browser"
      , "module": UserModule { source: "" }
      , cells: []
      }

parseBody
  :: forall a
   . JsonCodec a
  -> String
  -> Either String a
parseBody codec s = case jsonParser s of
  Left e -> Left ("bad JSON: " <> e)
  Right j -> case CA.decode codec j of
    Left e -> Left ("bad request: " <> CA.printJsonDecodeError e)
    Right a -> Right a

-- | Body decoder for `POST /eval`.  Accepts `{"source": "..."}`.
parseEvalBody :: String -> Either String EvalRequest
parseEvalBody raw = case jsonParser raw of
  Left e -> Left ("bad JSON: " <> e)
  Right j -> case toObject j of
    Nothing -> Left "expected a JSON object"
    Just o -> case Object.lookup "source" o of
      Nothing -> Left "missing field: source"
      Just v -> case AJ.toString v of
        Just s -> Right { source: s }
        Nothing -> Left "source must be a string"

evalResponseJson :: EvalResponse -> String
evalResponseJson = stringify <<< CA.encode evalResponseCodec

-- ============================================================
-- App context + authorisation
-- ============================================================

-- | Per-process server state.
-- |
-- | `workspaces` is authoritative for which session stores exist —
-- | every lookup goes through it so a DELETE takes effect immediately
-- | for subsequent requests. `mainStore` is a convenience pointer to
-- | the store registered under `WorkspaceId "main"`; the WS handler
-- | reads from it directly, since Phase 1b keeps the browser tabs
-- | pinned to main (per-subscriber workspace routing is Phase 2).
-- |
-- | Single-store app context.  Calypso runs one session per server
-- | (no /workspaces partitioning); the broadcast hooks plus the
-- | conch live alongside it.
type AppCtx =
  { mainStore :: SessionStore
  , subs :: Subscribers
  , conchStore :: ConchStore
  }

-- | Flattener for handlers that target the single store.  Kept as a
-- | helper so the existing call sites read clearly; every endpoint
-- | resolves to the same store now, but we may grow per-route auth
-- | concerns here later.
withStore
  :: AppCtx
  -> Request Route
  -> (SessionStore -> ResponseM)
  -> ResponseM
withStore ctx _req action = action ctx.mainStore

-- | Small `{error, message}` envelope for top-level error responses.
-- | These are structurally different from the session-level errors
-- | that ride inside a `CompileResponse`.
errorJson :: String -> String -> String
errorJson code message =
  stringify $ CA.encode
    (CAR.object "Error" { error: CA.string, message: CA.string })
    { error: code, message }

-- | Before any mutating HTTP endpoint runs its work, the caller must
-- | prove they hold the conch via the `X-Atelier-Subscriber-Id`
-- | header. Missing header / mismatched id / nobody-holds-it all yield
-- | a 409 with the current conch state in the body so the client can
-- | decide whether to `RequestConch` or `ForceConch`.
-- |
-- | Returns the caller's `SubscriberId` on success so the writer can
-- | heartbeat the conch after the write lands.
requireConch
  :: AppCtx
  -> Request Route
  -> Aff (Either ResponseOrUpgrade SubscriberId)
requireConch ctx req = do
  conch <- liftEffect $ Conch.getState ctx.conchStore
  let deny = do
        let body =
              { error: "conch-held"
              , holder: conch.holder
              , lastActivityAt: conch.lastActivityAt
              }
            json = stringify (CA.encode conchHeldBodyCodec body)
        r <- conflict' jsonCors json
        pure (Left r)
  case req.headers !! "X-Atelier-Subscriber-Id" of
    Nothing -> deny
    Just raw ->
      let sid = SubscriberId raw
      in case conch.holder of
          Just h | h == sid -> pure (Right sid)
          _ -> deny

-- | Per-response header profiles pulled up to the module level so the
-- | auth helper + mkRouter share them.
plainCors :: ResponseHeaders
plainCors = headers
  { "Access-Control-Allow-Origin": "*"
  , "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS"
  , "Access-Control-Allow-Headers": "Content-Type, X-Atelier-Subscriber-Id"
  }

jsonCors :: ResponseHeaders
jsonCors = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  , "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS"
  , "Access-Control-Allow-Headers": "Content-Type, X-Atelier-Subscriber-Id"
  }

-- ============================================================
-- WebSocket dispatch
-- ============================================================

-- | WS handler wired up inside `serveWithHandle`. Every connected
-- | subscriber flows through this one set of callbacks; identity is
-- | looked up via `Subscribers.idFor sock` on each message.
makeWsHandler :: AppCtx -> WsHandler
makeWsHandler ctx = wsHandler
  { onOpen: \sock -> do
      sid <- liftEffect $ Subscribers.register ctx.subs sock
      conch <- liftEffect $ Conch.getState ctx.conchStore
      -- Phase 1b: browser tabs always observe the "main" workspace.
      -- Per-subscriber workspace routing is a Phase 2 concern.
      snap <- liftEffect $ Session.get ctx.mainStore
      let welcome = Welcome { yourId: sid, conch, snapshot: snap }
      sendText sock (stringify (CA.encode broadcastCodec welcome))
  , onMessage: \sock msg -> case msg of
      TextMessage raw -> handleClientMsg ctx sock raw
      _ -> pure unit
  , onClose: \sock _ -> do
      maybeSid <- liftEffect $ Subscribers.idFor ctx.subs sock
      liftEffect $ Subscribers.unregister ctx.subs sock
      case maybeSid of
        Nothing -> pure unit
        Just sid -> do
          r <- liftEffect $ Conch.onDisconnect ctx.conchStore sid
          handleConchResult ctx r
  , onError: \_ _ -> pure unit
  }

handleClientMsg :: AppCtx -> ServerSocket -> String -> Aff Unit
handleClientMsg ctx sock raw = case jsonParser raw of
  Left e -> liftEffect $ Console.error ("WS client msg JSON parse: " <> e)
  Right j -> case CA.decode clientMsgCodec j of
    Left e -> liftEffect $ Console.error ("WS client msg decode: " <> CA.printJsonDecodeError e)
    Right cm -> do
      maybeSid <- liftEffect $ Subscribers.idFor ctx.subs sock
      case maybeSid of
        Nothing -> pure unit
        Just sid -> dispatchClientMsg ctx sid cm

dispatchClientMsg :: AppCtx -> SubscriberId -> PConch.ClientMsg -> Aff Unit
dispatchClientMsg ctx sid = case _ of
  PConch.RequestConch -> do
    r <- liftEffect $ Conch.request ctx.conchStore sid
    handleConchResult ctx r
  PConch.YieldConch -> do
    r <- liftEffect $ Conch.yield ctx.conchStore sid
    handleConchResult ctx r
  PConch.ForceConch -> do
    r <- liftEffect $ Conch.force ctx.conchStore sid
    handleConchResult ctx r
  PConch.Heartbeat -> liftEffect $ Conch.heartbeat ctx.conchStore sid

handleConchResult :: AppCtx -> RequestResult -> Aff Unit
handleConchResult ctx = case _ of
  Granted cs -> do
    let msg = ConchUpdate { conch: cs }
        encoded = stringify (CA.encode broadcastCodec msg)
    Subscribers.broadcast ctx.subs Nothing (TextMessage encoded)
  Unchanged -> pure unit

-- ============================================================
-- main
-- ============================================================

-- | On-disk location for the single session.  server/run.js launches
-- | from the repo root, so a cwd-relative path resolves correctly
-- | without knowing where this module lives on disk.  The legacy
-- | `runtime-workspace/workspaces/main/` shape is retained so existing
-- | persisted state (calypso-session.json) doesn't get orphaned.
sessionDir :: String
sessionDir = "runtime-workspace/workspaces/main"

main :: ServerM
main = serveWithHandle { port: 3060, hostname: "0.0.0.0" } \handle -> do
  -- Ensure ~/.calypso/favorites exists and is seeded with default.tidal
  -- before the first store gets built — that way the dropdown is
  -- non-empty on a fresh install and the initial-session seeding has
  -- something to read from.
  favDir <- Favorites.favoritesDir
  Favorites.ensureFavoritesDir favDir
  defaultBody <- Favorites.loadDefaultBody favDir
  subs <- Subscribers.newSubscribers
  conchStore <- Conch.newStore
  handle.registerChannel (Subscribers.closeAll subs)
  let broadcastSnapshot resp = do
        conch <- liftEffect $ Conch.getState conchStore
        let msg = Snapshot { conch, snapshot: resp }
            encoded = stringify (CA.encode broadcastCodec msg)
        Subscribers.broadcast subs conch.holder (TextMessage encoded)
  mainStore <- Session.newStore
    sessionDir
    "calypso-runtime"
    defaultBody
    broadcastSnapshot
  let ctx = { mainStore, subs, conchStore }
  pure
    { route
    , router: mkRouter ctx
    }

mkRouter
  :: AppCtx
  -> Request Route
  -> ResponseM
mkRouter ctx req@{ route: r, method, body } =
  case method of
    Options -> ok' plainCors ""
    _ -> case r of
      Health -> ok' plainCors "ok"

      SessionGet -> withStore ctx req \store -> do
        resp <- liftEffect (Session.get store)
        ok' jsonCors (snapshotJson resp)

      SessionWs -> pure (WsUpgrade (makeWsHandler ctx))

      SessionCompile -> withStore ctx req \store -> do
        -- With body: set state from the CompileRequest, then compile.
        -- This is the shape the frontend POSTs today.
        -- Without body (empty string): recompile current state.
        -- Either way, mutates — requires the conch.
        authResult <- requireConch ctx req
        case authResult of
          Left r' -> pure r'
          Right sid -> do
            bodyStr <- toString body
            resp <- if String.null bodyStr || bodyStr == "{}"
              then liftAff (Session.compileAndStore store)
              else case parseBody compileRequestCodec bodyStr of
                Left _ -> liftAff (Session.compileAndStore store)
                Right rq -> liftAff (Session.replaceAll store rq)
            liftEffect $ Conch.heartbeat ctx.conchStore sid
            ok' jsonCors (snapshotJson resp)

      SessionModule { preview } -> withStore ctx req \store -> case method of
        Post -> do
          bodyStr <- toString body
          case parseBody moduleBodyCodec bodyStr of
            Left msg -> ok' jsonCors (errorSnapshotJson "BadRequest" msg)
            Right { source } ->
              if preview
                then do
                  resp <- liftAff (Session.previewUpdateModule store (UserModule { source }))
                  ok' jsonCors (snapshotJson resp)
                else do
                  authResult <- requireConch ctx req
                  case authResult of
                    Left r' -> pure r'
                    Right sid -> do
                      resp <- liftAff (Session.updateModule store (UserModule { source }))
                      liftEffect $ Conch.heartbeat ctx.conchStore sid
                      ok' jsonCors (snapshotJson resp)
        Patch -> do
          bodyStr <- toString body
          case parseModulePatch bodyStr of
            Left msg -> ok' jsonCors (errorSnapshotJson "BadRequest" msg)
            Right patch ->
              if preview
                then do
                  result <- liftAff (Session.previewModulePatch store patch)
                  case result of
                    Left msg -> ok' jsonCors (errorSnapshotJson "BadRequest" msg)
                    Right resp -> ok' jsonCors (snapshotJson resp)
                else do
                  authResult <- requireConch ctx req
                  case authResult of
                    Left r' -> pure r'
                    Right sid -> do
                      result <- liftAff (Session.patchModule store patch)
                      case result of
                        Left msg -> ok' jsonCors (errorSnapshotJson "BadRequest" msg)
                        Right resp -> do
                          liftEffect $ Conch.heartbeat ctx.conchStore sid
                          ok' jsonCors (snapshotJson resp)
        _ -> ok' jsonCors (errorSnapshotJson "MethodNotAllowed" "module endpoint accepts POST or PATCH")

      SessionCellAppend { preview } -> withStore ctx req \store -> do
        bodyStr <- toString body
        case parseBody cellAppendBodyCodec bodyStr of
          Left msg -> ok' jsonCors (errorSnapshotJson "BadRequest" msg)
          Right rq ->
            if preview
              then do
                resp <- liftAff (Session.previewAppendCell store rq)
                ok' jsonCors (snapshotJson resp)
              else do
                authResult <- requireConch ctx req
                case authResult of
                  Left r' -> pure r'
                  Right sid -> do
                    resp <- liftAff (Session.appendCell store rq)
                    liftEffect $ Conch.heartbeat ctx.conchStore sid
                    ok' jsonCors (snapshotJson resp)

      SessionCellAt cellId { preview } -> withStore ctx req \store -> case method of
        Delete ->
          if preview
            then do
              resp <- liftAff (Session.previewRemoveCell store cellId)
              ok' jsonCors (snapshotJson resp)
            else do
              authResult <- requireConch ctx req
              case authResult of
                Left r' -> pure r'
                Right sid -> do
                  resp <- liftAff (Session.removeCell store cellId)
                  liftEffect $ Conch.heartbeat ctx.conchStore sid
                  ok' jsonCors (snapshotJson resp)
        Patch -> do
          bodyStr <- toString body
          case parseCellPatch bodyStr of
            Left msg -> ok' jsonCors (errorSnapshotJson "BadRequest" msg)
            Right patch ->
              if preview
                then do
                  resp <- liftAff (Session.previewUpdateCell store cellId patch)
                  ok' jsonCors (snapshotJson resp)
                else do
                  authResult <- requireConch ctx req
                  case authResult of
                    Left r' -> pure r'
                    Right sid -> do
                      resp <- liftAff (Session.updateCell store cellId patch)
                      liftEffect $ Conch.heartbeat ctx.conchStore sid
                      ok' jsonCors (snapshotJson resp)
        _ -> ok' jsonCors (errorSnapshotJson "MethodNotAllowed" "cell endpoint accepts PATCH or DELETE")

      FavoritesRoute -> case method of
        Get -> do
          dir <- liftEffect Favorites.favoritesDir
          favs <- liftAff (Favorites.listFavorites dir)
          ok' jsonCors (stringify (CA.encode favoritesCodec favs))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/favorites accepts GET")

      Eval -> case method of
        Post -> do
          bodyStr <- toString body
          case parseEvalBody bodyStr of
            Left msg -> badRequest' jsonCors (errorJson "BadRequest" msg)
            Right req' -> do
              resp <- liftAff (Session.evaluate ctx.mainStore req')
              ok' jsonCors (evalResponseJson resp)
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/eval accepts POST")
