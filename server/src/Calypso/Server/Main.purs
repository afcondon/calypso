module Calypso.Server.Main where

import Prelude

import Data.Argonaut.Core (stringify, toObject)
import Data.Argonaut.Core as AJ
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Foreign.Object as Object
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..))
import Data.String.Pattern (Pattern(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
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
import Effect (Effect)
import Node.Process as Process
import Calypso.Server.Pen (PenStore, RequestResult(..))
import Calypso.Server.Pen as Pen
import Calypso.Server.Favorites as Favorites
import Calypso.Server.Hash (sha1Hex)
import Calypso.Server.FireLog as FireLog
import Calypso.Server.Proposals (ProposalStore)
import Calypso.Server.Proposals as Proposals
import Calypso.Server.Vocabulary as Vocabulary
import Calypso.Server.Session (EvalRequest, EvalResponse, ModulePatch(..), SessionStore, evalResponseCodec)
import Calypso.Server.Session as Session
import Calypso.Server.Arm (armCue, armRequestCodec, armResultCodec)
import Calypso.Server.SessionSource (buildSession, sessionSourceRequestCodec, sessionSourceResultCodec)
import Calypso.Server.StudioSource (buildStudio, fetchStudio, studioSourceFetchCodec, studioSourceRequestCodec, studioSourceResultCodec)
import Calypso.Server.Studio (getStudio, studioSnapshotCodec)
import Calypso.Server.Sessions as Sessions
import Calypso.Server.Subscribers (Subscribers)
import Calypso.Server.Subscribers as Subscribers
import Data.String as String
import Calypso.Pen
  ( Broadcast(..)
  , SubscriberId(..)
  , broadcastCodec
  , clientMsgCodec
  , penHeldBodyCodec
  )
import Calypso.Pen as PPen
import Calypso.Favorite (favoritesCodec)
import Calypso.Vocabulary (vocabularyCodec)
import Calypso.Proposal
  ( Hunk(..)
  , Proposal(..)
  , ProposalId(..)
  , ProposalTarget(..)
  , hunkCodec
  , proposalCodec
  , proposalTargetCodec
  )
import Calypso.Session
  ( Cell(..)
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
  -- GET-only listing of bindings + devices parsed from the
  -- purerl-tidal setup directory.  Drives autocomplete + the
  -- reference panel.
  | VocabularyRoute
  -- Proposals: anyone (humans, AI agents) can POST; the Pen holder
  -- accepts/rejects per-hunk; the proposer can withdraw.
  | ProposalsRoute
  | ProposalOne String
  | ProposalHunkAccept String String  -- proposal id, hunk index (parsed in handler)
  | ProposalHunkReject String String
  -- Read-only fire-log query: returns the most recent N entries from
  -- `~/.calypso/fire-log.jsonl`.  Used by the (eventual) Log pane to
  -- recover patterns wiped from the cells pane.
  | FireLogRoute
  -- POST {tvoice, cueName} — arm a typeful cue. Synthesises a bridge
  -- module, builds it via purs + backend-erl --filter, erlc's,
  -- ships play-armed to purerl-tidal. Phase 3 of typeful cues.
  | Arm
  -- POST {source} — write the composition pane to
  -- Calypso.Generated.Session.purs and rebuild. After this, /arm
  -- targets cues from the freshly-built session. Phase 4 of
  -- typeful cues.
  | SessionSource
  -- GET — return the current Studio snapshot from purerl-tidal:
  -- devices, instruments, drum kits, and any reservation conflicts.
  -- The frontend's Studio pane consumes this; reservations Phase 1b.
  | StudioRoute
  -- POST {source} — write Studio.purs and rebuild via the per-cell
  -- pipeline (purs --filter + backend-erl --filter + erlc).
  -- ~700ms warm-toolchain.  Workstream 2 of studio-pane-day-plan.md.
  | StudioSource
  -- GET — return the list of available session templates in
  -- purerl-tidal/src/Sessions/, e.g. ["Fugue", "Grids", "Rene", ...].
  -- The frontend's gear menu populates the session picker from this.
  | SessionsList
  -- GET /sessions/<name> — return the named template's source with
  -- the module declaration rewritten to `Calypso.Generated.Session`.
  -- Frontend feeds this directly into the existing fire-typeful path
  -- (PATCH /session/module + POST /session-source) — no special
  -- machinery needed.
  | SessionsGet String

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
  , "VocabularyRoute": "vocabulary" / noArgs
  , "ProposalsRoute": "proposals" / noArgs
  , "ProposalOne": "proposals" / segment
  , "ProposalHunkAccept": "proposals" / segment / "hunks" / segment / "accept"
  , "ProposalHunkReject": "proposals" / segment / "hunks" / segment / "reject"
  , "FireLogRoute": "log" / noArgs
  , "Arm": "arm" / noArgs
  , "SessionSource": "session-source" / noArgs
  , "StudioRoute": "studio" / noArgs
  , "StudioSource": "studio-source" / noArgs
  , "SessionsList": "sessions" / noArgs
  , "SessionsGet": "sessions" / segment
  }

-- ============================================================
-- Body codecs (ad-hoc for each endpoint's expected shape)
-- ============================================================

moduleBodyCodec :: JsonCodec { source :: String }
moduleBodyCodec = CAR.object "ModuleBody" { source: CA.string }

cellAppendBodyCodec :: JsonCodec { source :: String, kind :: String, author :: Maybe String }
cellAppendBodyCodec = CAR.object "CellAppendBody"
  { source: CA.string
  , kind: CA.string
  , author: CAR.optional CA.string
  }

-- | PATCH-body decoder: fields are genuinely optional (missing key
-- | means "don't change"). We don't use a codec here because
-- | codec-argonaut's `maybe` combinator expects a tagged-object wire
-- | form for `Maybe`, not the missing-vs-present convention HTTP
-- | clients will naturally use.
parseCellPatch
  :: String
  -> Either String
       { source :: Maybe String
       , kind :: Maybe String
       , form :: Maybe Boolean
       , mvoice :: Maybe String
       , tvoice :: Maybe String
       }
parseCellPatch raw = case jsonParser raw of
  Left e -> Left ("bad JSON: " <> e)
  Right j -> case toObject j of
    Nothing -> Left "bad request: expected a JSON object"
    Just o -> do
      source <- pickStr "source" o
      kind <- pickStr "kind" o
      form <- pickBool "form" o
      -- mvoice/tvoice use the empty-string sentinel for "clear":
      -- key absent → preserve current value; key present and "" →
      -- set to Nothing; key present and non-empty → set to Just s.
      mvoice <- pickStr "mvoice" o
      tvoice <- pickStr "tvoice" o
      pure { source, kind, form, mvoice, tvoice }
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
      -- empty source → SHA-1 of "" (well-known); proposers won't post
      -- against an error response anyway.
      , sourceHash: "da39a3ee5e6b4b0d3255bfef95601890afd80709"
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
-- | (no /workspaces partitioning); the broadcast hooks, the Pen, and
-- | the proposal queue live alongside it.
type AppCtx =
  { mainStore :: SessionStore
  , subs :: Subscribers
  , penStore :: PenStore
  , proposalStore :: ProposalStore
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

-- ============================================================
-- Proposal handling
-- ============================================================

-- | Body decoder for `POST /proposals`.  We don't accept an `id` (the
-- | server mints it) or `createdAt` (the server stamps it).
parseProposalCreateBody
  :: String
  -> Either String { author :: String
                   , target :: ProposalTarget
                   , basedOn :: String
                   , hunks :: Array Hunk
                   , prompt :: Maybe String
                   }
parseProposalCreateBody raw = case jsonParser raw of
  Left e -> Left ("bad JSON: " <> e)
  Right j -> case AJ.toObject j of
    Nothing -> Left "expected a JSON object"
    Just o -> do
      author <- requireStr "author" o
      tJson <- requireField "target" o
      target <- case CA.decode proposalTargetCodec tJson of
        Left e -> Left ("target: " <> CA.printJsonDecodeError e)
        Right t -> Right t
      basedOn <- requireStr "basedOn" o
      hunksJson <- requireField "hunks" o
      hunksArr <- case AJ.toArray hunksJson of
        Nothing -> Left "hunks must be an array"
        Just arr -> Right arr
      hunks <- traverse decodeHunk hunksArr
      let prompt = case Object.lookup "prompt" o of
            Nothing -> Nothing
            Just v -> AJ.toString v
      pure { author, target, basedOn, hunks, prompt }
  where
  requireField key o = case Object.lookup key o of
    Nothing -> Left ("missing field: " <> key)
    Just v -> Right v
  requireStr key o = case Object.lookup key o of
    Nothing -> Left ("missing field: " <> key)
    Just v -> case AJ.toString v of
      Just s -> Right s
      Nothing -> Left (key <> " must be a string")
  decodeHunk j = case CA.decode hunkCodec j of
    Left e -> Left ("hunk: " <> CA.printJsonDecodeError e)
    Right h -> Right h

-- | Broadcast a frame to every connected subscriber, no skip.  Used
-- | for proposal-{added,updated,retired} since proposals affect the
-- | review surface for everyone, including the proposer (who needs
-- | the server-assigned ProposalId).
broadcastToAll :: Subscribers -> Broadcast -> Aff Unit
broadcastToAll subs msg =
  Subscribers.broadcast subs Nothing
    (TextMessage (stringify (CA.encode broadcastCodec msg)))

-- | Read the source body of a proposal's target.
sourceForTarget :: AppCtx -> ProposalTarget -> Aff (Maybe String)
sourceForTarget ctx tgt = do
  CompileResponse r <- liftEffect $ Session.get ctx.mainStore
  let UserModule m = r."module"
  pure case tgt of
    TgtModule -> Just m.source
    TgtCell cid ->
      _.source <<< (\(Cell c) -> c) <$>
        Array.find (\(Cell c) -> c.id == cid) r.cells

-- | Apply a hunk to a source body.  startLine is 1-based.
applyHunk :: Hunk -> String -> String
applyHunk (Hunk h) src =
  let lines = String.split (Pattern "\n") src
      before = Array.take (h.startLine - 1) lines
      after = Array.drop (h.startLine - 1 + Array.length h.removed) lines
      merged = before <> h.added <> after
  in String.joinWith "\n" merged

-- | Accept a hunk: validate basedOn, apply to source, persist,
-- | broadcast Snapshot, then plus broadcast ProposalUpdated/Retired.
handleProposalAccept :: AppCtx -> SubscriberId -> ProposalId -> Int -> ResponseM
handleProposalAccept ctx sid pid idx = do
  -- Look up the proposal and its target source first; we need both
  -- to validate basedOn before mutating anything.
  ps <- liftEffect $ Proposals.listProposals ctx.proposalStore
  case Array.find (\(Proposal p) -> p.id == pid) ps of
    Nothing -> response' Status.notFound jsonCors
      (errorJson "NoSuchProposal" "no such proposal")
    Just (Proposal p) -> case Array.index p.hunks idx of
      Nothing -> badRequest' jsonCors (errorJson "BadHunkIndex" "hunk index out of range")
      Just hunk -> do
        mSrc <- liftAff (sourceForTarget ctx p.target)
        case mSrc of
          Nothing -> response' Status.notFound jsonCors
            (errorJson "NoSuchTarget" "proposal target no longer exists")
          Just currentSrc -> do
            currentHash <- liftEffect $ sha1Hex currentSrc
            if currentHash /= p.basedOn
              then response' Status.conflict jsonCors
                (errorJson "RebaseNeeded"
                  "proposal basedOn does not match current source; rebase needed")
              else do
                let newSrc = applyHunk hunk currentSrc
                snap <- liftAff case p.target of
                  TgtModule ->
                    Session.updateModule ctx.mainStore (UserModule { source: newSrc })
                  TgtCell cid ->
                    Session.updateCell ctx.mainStore cid
                      { source: Just newSrc, kind: Nothing, form: Nothing
                      , mvoice: Nothing, tvoice: Nothing }
                liftEffect $ Pen.heartbeat ctx.penStore sid
                taken <- liftEffect $ Proposals.takeHunk ctx.proposalStore pid idx
                case taken of
                  Just (Tuple _ Nothing) ->
                    liftAff $ broadcastToAll ctx.subs (ProposalRetired { id: pid })
                  Just (Tuple _ (Just updated)) ->
                    liftAff $ broadcastToAll ctx.subs (ProposalUpdated { proposal: updated })
                  Nothing -> pure unit
                ok' jsonCors (snapshotJson snap)

-- | Reject a hunk: pluck it from the proposal and broadcast the
-- | updated/retired frame.  No source mutation.
handleProposalReject :: AppCtx -> SubscriberId -> ProposalId -> Int -> ResponseM
handleProposalReject ctx sid pid idx = do
  taken <- liftEffect $ Proposals.takeHunk ctx.proposalStore pid idx
  case taken of
    Nothing -> response' Status.notFound jsonCors
      (errorJson "NoSuchProposal" "proposal or hunk not found")
    Just (Tuple _ remaining) -> do
      liftEffect $ Pen.heartbeat ctx.penStore sid
      case remaining of
        Nothing ->
          liftAff $ broadcastToAll ctx.subs (ProposalRetired { id: pid })
        Just updated ->
          liftAff $ broadcastToAll ctx.subs (ProposalUpdated { proposal: updated })
      ok' jsonCors (errorJson "ok" "rejected")

-- | Before any mutating HTTP endpoint runs its work, the caller must
-- | prove they hold the pen via the `X-Atelier-Subscriber-Id`
-- | header. Missing header / mismatched id / nobody-holds-it all yield
-- | a 409 with the current pen state in the body so the client can
-- | decide whether to `RequestPen` or `ForcePen`.
-- |
-- | Returns the caller's `SubscriberId` on success so the writer can
-- | heartbeat the pen after the write lands.
requirePen
  :: AppCtx
  -> Request Route
  -> Aff (Either ResponseOrUpgrade SubscriberId)
requirePen ctx req = do
  pen <- liftEffect $ Pen.getState ctx.penStore
  let deny = do
        let body =
              { error: "pen-held"
              , holder: pen.holder
              , lastActivityAt: pen.lastActivityAt
              }
            json = stringify (CA.encode penHeldBodyCodec body)
        r <- conflict' jsonCors json
        pure (Left r)
  case req.headers !! "X-Atelier-Subscriber-Id" of
    Nothing -> deny
    Just raw ->
      let sid = SubscriberId raw
      in case pen.holder of
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
      pen <- liftEffect $ Pen.getState ctx.penStore
      snap <- liftEffect $ Session.get ctx.mainStore
      proposals <- liftEffect $ Proposals.listProposals ctx.proposalStore
      let welcome = Welcome { yourId: sid, pen, snapshot: snap, proposals }
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
          r <- liftEffect $ Pen.onDisconnect ctx.penStore sid
          handlePenResult ctx r
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

dispatchClientMsg :: AppCtx -> SubscriberId -> PPen.ClientMsg -> Aff Unit
dispatchClientMsg ctx sid = case _ of
  PPen.RequestPen -> do
    r <- liftEffect $ Pen.request ctx.penStore sid
    handlePenResult ctx r
  PPen.YieldPen -> do
    r <- liftEffect $ Pen.yield ctx.penStore sid
    handlePenResult ctx r
  PPen.ForcePen -> do
    r <- liftEffect $ Pen.force ctx.penStore sid
    handlePenResult ctx r
  PPen.Heartbeat -> liftEffect $ Pen.heartbeat ctx.penStore sid

handlePenResult :: AppCtx -> RequestResult -> Aff Unit
handlePenResult ctx = case _ of
  Granted cs -> do
    let msg = PenUpdate { pen: cs }
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

-- | Resolve the listen port from `$BACKEND_PORT`, falling back to
-- | 3060.  Honours SDI's lazy-spawn protocol (SDI rewrites the
-- | literal port in the registered startCommand to an internal port
-- | and exports it as `$BACKEND_PORT` so the server binds where SDI
-- | expects to proxy it).
resolvePort :: Effect Int
resolvePort = do
  raw <- Process.lookupEnv "BACKEND_PORT"
  pure case raw >>= Int.fromString of
    Just p -> p
    Nothing -> 3060

main :: ServerM
main = do
  port <- liftEffect resolvePort
  serveOn port

serveOn :: Int -> ServerM
serveOn port = serveWithHandle { port, hostname: "0.0.0.0" } \handle -> do
  -- Ensure ~/.calypso/favorites exists and is seeded with default.tidal
  -- before the first store gets built — that way the dropdown is
  -- non-empty on a fresh install and the initial-session seeding has
  -- something to read from.
  favDir <- Favorites.favoritesDir
  Favorites.ensureFavoritesDir favDir
  defaultBody <- Favorites.loadDefaultBody favDir
  subs <- Subscribers.newSubscribers
  penStore <- Pen.newStore
  proposalStore <- Proposals.newStore
  handle.registerChannel (Subscribers.closeAll subs)
  let broadcastSnapshot resp = do
        pen <- liftEffect $ Pen.getState penStore
        let msg = Snapshot { pen, snapshot: resp }
            encoded = stringify (CA.encode broadcastCodec msg)
        -- Broadcast to ALL subscribers, including the pen holder. The
        -- previous behaviour excluded the pen holder on the assumption
        -- they'd already have the result from their own HTTP/WS call;
        -- but that breaks the new permissionless cell-append lane,
        -- where a non-pen-holder writes and the pen holder needs the
        -- snapshot to see the new cell appear. Snapshot apply is
        -- idempotent so the redundant frame to a self-initiating
        -- pen-holder is harmless.
        Subscribers.broadcast subs Nothing (TextMessage encoded)
  mainStore <- Session.newStore
    sessionDir
    "calypso-runtime"
    defaultBody
    broadcastSnapshot
  let ctx = { mainStore, subs, penStore, proposalStore }
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
        -- Either way, mutates — requires the pen.
        authResult <- requirePen ctx req
        case authResult of
          Left r' -> pure r'
          Right sid -> do
            bodyStr <- toString body
            resp <- if String.null bodyStr || bodyStr == "{}"
              then liftAff (Session.compileAndStore store)
              else case parseBody compileRequestCodec bodyStr of
                Left _ -> liftAff (Session.compileAndStore store)
                Right rq -> liftAff (Session.replaceAll store rq)
            liftEffect $ Pen.heartbeat ctx.penStore sid
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
                  authResult <- requirePen ctx req
                  case authResult of
                    Left r' -> pure r'
                    Right sid -> do
                      resp <- liftAff (Session.updateModule store (UserModule { source }))
                      liftEffect $ Pen.heartbeat ctx.penStore sid
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
                  authResult <- requirePen ctx req
                  case authResult of
                    Left r' -> pure r'
                    Right sid -> do
                      result <- liftAff (Session.patchModule store patch)
                      case result of
                        Left msg -> ok' jsonCors (errorSnapshotJson "BadRequest" msg)
                        Right resp -> do
                          liftEffect $ Pen.heartbeat ctx.penStore sid
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
                -- Append-cell does NOT require the pen: a freshly-appended cell
                -- has form: false and is therefore inert (not part of the
                -- playing composition). The helm gesture that DOES affect what's
                -- playing — PATCH …/cells/:id { form: true } — keeps its pen
                -- check below. This is the lane that lets agents and tutorial
                -- scripts drop suggestions into the cells pane without holding
                -- the pen; the helm picks them up by promoting.
                resp <- liftAff (Session.appendCell store rq)
                ok' jsonCors (snapshotJson resp)

      SessionCellAt cellId { preview } -> withStore ctx req \store -> case method of
        Delete ->
          if preview
            then do
              resp <- liftAff (Session.previewRemoveCell store cellId)
              ok' jsonCors (snapshotJson resp)
            else do
              authResult <- requirePen ctx req
              case authResult of
                Left r' -> pure r'
                Right sid -> do
                  resp <- liftAff (Session.removeCell store cellId)
                  liftEffect $ Pen.heartbeat ctx.penStore sid
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
                  authResult <- requirePen ctx req
                  case authResult of
                    Left r' -> pure r'
                    Right sid -> do
                      resp <- liftAff (Session.updateCell store cellId patch)
                      liftEffect $ Pen.heartbeat ctx.penStore sid
                      ok' jsonCors (snapshotJson resp)
        _ -> ok' jsonCors (errorSnapshotJson "MethodNotAllowed" "cell endpoint accepts PATCH or DELETE")

      FavoritesRoute -> case method of
        Get -> do
          dir <- liftEffect Favorites.favoritesDir
          favs <- liftAff (Favorites.listFavorites dir)
          ok' jsonCors (stringify (CA.encode favoritesCodec favs))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/favorites accepts GET")

      VocabularyRoute -> case method of
        Get -> do
          dir <- liftEffect Vocabulary.vocabularyDir
          vocab <- liftAff (Vocabulary.listVocabulary dir)
          ok' jsonCors (stringify (CA.encode vocabularyCodec vocab))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/vocabulary accepts GET")

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

      Arm -> case method of
        Post -> do
          authResult <- requirePen ctx req
          case authResult of
            Left r' -> pure r'
            Right sid -> do
              bodyStr <- toString body
              case parseBody armRequestCodec bodyStr of
                Left msg -> badRequest' jsonCors (errorJson "BadRequest" msg)
                Right req' -> do
                  result <- liftAff (armCue req')
                  liftEffect $ Pen.heartbeat ctx.penStore sid
                  ok' jsonCors (stringify (CA.encode armResultCodec result))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/arm accepts POST")

      SessionSource -> case method of
        Post -> do
          authResult <- requirePen ctx req
          case authResult of
            Left r' -> pure r'
            Right sid -> do
              bodyStr <- toString body
              case parseBody sessionSourceRequestCodec bodyStr of
                Left msg -> badRequest' jsonCors (errorJson "BadRequest" msg)
                Right req' -> do
                  result <- liftAff (buildSession req')
                  liftEffect $ Pen.heartbeat ctx.penStore sid
                  ok' jsonCors
                    (stringify (CA.encode sessionSourceResultCodec result))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/session-source accepts POST")

      StudioRoute -> case method of
        Get -> do
          result <- liftAff getStudio
          case result of
            Left err -> badRequest' jsonCors (errorJson "StudioFetchFailed" err)
            Right snap -> ok' jsonCors (stringify (CA.encode studioSnapshotCodec snap))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/studio accepts GET")

      StudioSource -> case method of
        Get -> do
          result <- liftAff fetchStudio
          ok' jsonCors (stringify (CA.encode studioSourceFetchCodec result))
        Post -> do
          authResult <- requirePen ctx req
          case authResult of
            Left r' -> pure r'
            Right sid -> do
              bodyStr <- toString body
              case parseBody studioSourceRequestCodec bodyStr of
                Left msg -> badRequest' jsonCors (errorJson "BadRequest" msg)
                Right req' -> do
                  result <- liftAff (buildStudio req')
                  liftEffect $ Pen.heartbeat ctx.penStore sid
                  ok' jsonCors
                    (stringify (CA.encode studioSourceResultCodec result))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/studio-source accepts GET or POST")

      SessionsList -> case method of
        Get -> do
          dir   <- liftEffect Sessions.sessionsDir
          names <- liftAff (Sessions.listSessions dir)
          ok' jsonCors (stringify (CA.encode Sessions.sessionsListCodec { names }))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/sessions accepts GET")

      SessionsGet name -> case method of
        Get -> do
          dir    <- liftEffect Sessions.sessionsDir
          result <- liftAff (Sessions.readSession dir name)
          case result of
            Left  err    -> badRequest' jsonCors (errorJson "SessionsRead" err)
            Right source -> ok' jsonCors
              (stringify (CA.encode Sessions.sessionContentCodec { source }))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/sessions/<name> accepts GET")

      ProposalsRoute -> case method of
        Get -> do
          ps <- liftEffect $ Proposals.listProposals ctx.proposalStore
          ok' jsonCors (stringify (CA.encode (CA.array proposalCodec) ps))
        Post -> do
          bodyStr <- toString body
          case parseProposalCreateBody bodyStr of
            Left msg -> badRequest' jsonCors (errorJson "BadRequest" msg)
            Right p -> do
              pid <- liftEffect Proposals.freshProposalId
              now <- liftEffect Proposals.currentTimeMs
              let proposal = Proposal
                    { id: pid
                    , author: p.author
                    , target: p.target
                    , basedOn: p.basedOn
                    , hunks: p.hunks
                    , prompt: p.prompt
                    , createdAt: now
                    }
              liftEffect $ Proposals.addProposal ctx.proposalStore proposal
              broadcastToAll ctx.subs (ProposalAdded { proposal })
              ok' jsonCors (stringify (CA.encode proposalCodec proposal))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/proposals accepts GET or POST")

      ProposalOne idStr -> case method of
        Delete -> do
          let pid = ProposalId idStr
          mw <- liftEffect $ Proposals.withdraw ctx.proposalStore pid
          case mw of
            Nothing -> response' Status.notFound jsonCors
              (errorJson "NoSuchProposal" ("proposal not found: " <> idStr))
            Just _ -> do
              broadcastToAll ctx.subs (ProposalRetired { id: pid })
              ok' jsonCors (errorJson "ok" ("withdrawn: " <> idStr))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/proposals/:id accepts DELETE")

      ProposalHunkAccept idStr idxStr -> case method of
        Post -> case Int.fromString idxStr of
          Nothing -> badRequest' jsonCors (errorJson "BadHunkIndex" idxStr)
          Just idx -> do
            authResult <- requirePen ctx req
            case authResult of
              Left r' -> pure r'
              Right sid -> handleProposalAccept ctx sid (ProposalId idStr) idx
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/proposals/:id/hunks/:idx/accept accepts POST")

      ProposalHunkReject idStr idxStr -> case method of
        Post -> case Int.fromString idxStr of
          Nothing -> badRequest' jsonCors (errorJson "BadHunkIndex" idxStr)
          Just idx -> do
            authResult <- requirePen ctx req
            case authResult of
              Left r' -> pure r'
              Right sid -> handleProposalReject ctx sid (ProposalId idStr) idx
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/proposals/:id/hunks/:idx/reject accepts POST")

      FireLogRoute -> case method of
        Get -> do
          -- Default: last 200 entries.  Trivially overrideable later
          -- with a query param if it ever matters; 200 is plenty for
          -- one performance session's worth of recovery.
          entries <- liftAff (FireLog.readRecent 200)
          ok' jsonCors (stringify (CA.encode (CA.array FireLog.entryCodec) entries))
        _ -> response' Status.methodNotAllowed jsonCors
          (errorJson "MethodNotAllowed" "/log accepts GET")
