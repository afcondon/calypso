module Playground.Server.Session
  ( SessionStore
  , ModulePatch(..)
  , ImportSpec
  , EvalRequest
  , EvalResponse
  , evalResponseCodec
  , newStore
  , get
  , compileAndStore
  , replaceAll
  , updateModule
  , previewUpdateModule
  , patchModule
  , previewModulePatch
  , appendCell
  , previewAppendCell
  , updateCell
  , previewUpdateCell
  , removeCell
  , previewRemoveCell
  , setRuntime
  , evaluate
  , applyModulePatch
  ) where

import Prelude

import Data.Argonaut.Core (Json, stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (filter, findIndex, modifyAt, snoc)
import Data.Array as Array
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..), hush)
import Data.Int (fromString) as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as Str
import Data.String.Pattern (Pattern(..))
import Effect (Effect)
import Effect.AVar (AVar)
import Effect.AVar as EffAVar
import Effect.Aff (Aff)
import Effect.Aff as Aff
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Effect.Exception (try)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FSA
import Node.FS.Sync as FSS

import Playground.Server.Adapter.BrowserWorker (browserWorker)
import Playground.Server.Adapter.NodeProcess (nodeProcess)
import Playground.Server.Adapter.PurerlBEAM (purerlBEAM)
import Playground.Server.Compile as Compile
import Playground.Server.Synthesize (synthesize)
import Playground.Session
  ( Cell(..)
  , CellEmit(..)
  , CompileError
  , CompileRequest(..)
  , CompileResponse(..)
  , UserModule(..)
  , cellCodec
  , compileErrorCodec
  , userModuleCodec
  )

-- | A structured edit to the user module's source. PATCH /session/module
-- | takes one of these and applies it under the session lock without
-- | requiring the agent to GET → string-replace → POST the whole body.
data ModulePatch
  = AddImport ImportSpec
  -- ^ Add an import after the last existing import line (or after the
  -- module header if none). The generated line shape follows the spec:
  -- `import M`, `import M as A`, `import M (f, g)`, or
  -- `import M (f, g) as A`. No-op if the module is already imported in
  -- any form; to change alias or names on an existing import, use
  -- ReplaceRange instead.
  | AppendBody String
  -- ^ Append text to the end of the module source, with a separating
  -- newline if the source doesn't already end in one.
  | ReplaceRange { startLine :: Int, endLine :: Int, text :: String }
  -- ^ Replace lines [startLine, endLine] (1-indexed, inclusive) with
  -- `text`. `text` may itself contain newlines (multi-line replacement).

-- | Spec for an import line. `module` is the fully-qualified name;
-- | `alias` and `names` are independently optional and combine into
-- | the standard PureScript surface syntax.
type ImportSpec =
  { "module" :: String
  , alias :: Maybe String
  , names :: Maybe (Array String)
  }

-- | Live session state: the human's (or Claude's) last-submitted
-- | inputs plus the most recent compile's derived outputs. A single
-- | AVar serialises writes — any update goes take → apply → recompile
-- | → put.
-- |
-- | `broadcast` is called after every accepted mutation with the fresh
-- | `CompileResponse`. Main.purs wires it to push a `Snapshot` frame to
-- | every WS subscriber (minus the conch holder, whose client already
-- | has the state it just wrote). Preview endpoints do not broadcast.
newtype SessionStore = SessionStore
  { lock :: AVar Unit
  , state :: Ref SessionState
  , broadcast :: CompileResponse -> Aff Unit
  -- | Absolute path of the on-disk spago project this session's compiles
  -- | write to. Adapters use this to write `src/*.purs` and read
  -- | `output/*.js`. Each workspace has its own subdirectory so concurrent
  -- | compiles don't stomp each other.
  , workspaceDir :: String
  -- | Name of the spago package living at `workspaceDir`. The outer
  -- | `spago.yaml` sees every workspace's package, so compiles must
  -- | disambiguate via `spago build -p <packageName>` — a shared name
  -- | across workspaces would cause spago to build the first match it
  -- | finds rather than the current workspace's.
  , packageName :: String
  }

type SessionState =
  { runtime :: String
  , "module" :: UserModule
  , cells :: Array Cell
  , nextCellId :: Int
  , lastResponse :: Maybe CompileResponse
  }

initialState :: SessionState
initialState =
  { runtime: "browser"
  , "module": UserModule { source: "module Scratch where\n\nimport Prelude\n" }
  , cells: []
  , nextCellId: 1
  , lastResponse: Nothing
  }

newStore
  :: String
  -> String
  -> (CompileResponse -> Aff Unit)
  -> Effect SessionStore
newStore workspaceDir packageName broadcast = do
  -- If there's a persisted snapshot on disk, use it as the initial
  -- state so a server restart doesn't wipe the human's work. Fall
  -- back silently to `initialState` when the file is missing, empty,
  -- or fails to decode — we don't want boot to crash on stale state.
  loaded <- loadPersisted workspaceDir
  ref <- Ref.new (fromMaybe initialState loaded)
  -- AVar used as a mutex: initially "full" (contains unit); take
  -- claims the lock, put releases it.
  lock <- EffAVar.new unit
  pure (SessionStore { lock, state: ref, broadcast, workspaceDir, packageName })

-- ============================================================
-- Session persistence
-- ============================================================
-- | Subset of `SessionState` we save across restarts: the user's
-- | inputs (module, cells, runtime) plus the cell-id counter. The
-- | derived `lastResponse` is regenerated on the next compile so
-- | doesn't need to land on disk.
type PersistedState =
  { "module" :: UserModule
  , cells :: Array Cell
  , runtime :: String
  , nextCellId :: Int
  }

persistedStateCodec :: JsonCodec PersistedState
persistedStateCodec = CAR.object "PersistedState"
  { "module": userModuleCodec
  , cells: CA.array cellCodec
  , runtime: CA.string
  , nextCellId: CA.int
  }

-- | On-disk location for a workspace's persisted state. Kept under
-- | the workspace dir (gitignored alongside `output/`) so each
-- | workspace's state travels with its other artefacts.
sessionFilePath :: String -> String
sessionFilePath workspaceDir = workspaceDir <> "/atelier-session.json"

-- | Synchronous: boot path, called from `newStore`. Returns `Nothing`
-- | if the file is absent, empty, or fails to decode. Logs on
-- | decode failure so a silent fallback is visible in the logs.
loadPersisted :: String -> Effect (Maybe SessionState)
loadPersisted workspaceDir = do
  let path = sessionFilePath workspaceDir
  result <- try (FSS.readTextFile UTF8 path)
  case result of
    Left _ -> pure Nothing
    Right raw -> case jsonParser raw of
      Left err -> do
        Console.warn $ "atelier-session.json at " <> path <> " failed to parse: " <> err
        pure Nothing
      Right j -> case CA.decode persistedStateCodec j of
        Left err -> do
          Console.warn $ "atelier-session.json at " <> path <> " failed to decode: "
            <> CA.printJsonDecodeError err
          pure Nothing
        Right p -> pure $ Just $
          initialState
            { "module" = p."module"
            , cells = p.cells
            , runtime = p.runtime
            , nextCellId = p.nextCellId
            }

-- | Asynchronous: called from `withUpdate` / `patchModule` after a
-- | successful commit. Disk failure is logged but never propagates
-- | out as a compile error — persistence is nice-to-have, not
-- | correctness-critical.
persist :: String -> SessionState -> Aff Unit
persist workspaceDir s = do
  let path = sessionFilePath workspaceDir
      body = stringify $ CA.encode persistedStateCodec
        { "module": s."module"
        , cells: s.cells
        , runtime: s.runtime
        , nextCellId: s.nextCellId
        }
  result <- Aff.attempt (FSA.writeTextFile UTF8 path body)
  case result of
    Left err ->
      liftEffect $ Console.warn $
        "atelier-session.json write failed at " <> path <> ": " <> show err
    Right _ -> pure unit

-- | Read the current session snapshot as a CompileResponse (for
-- | `GET /session`). Falls back to an empty-ish response when no
-- | compile has happened yet — callers just get back the input state
-- | alongside empty derived fields.
get :: SessionStore -> Effect CompileResponse
get (SessionStore { state }) = do
  s <- Ref.read state
  pure $ case s.lastResponse of
    Just (CompileResponse r) -> CompileResponse r
      { runtime = s.runtime
      , "module" = s."module"
      , cells = s.cells
      }
    Nothing -> emptyResponse s

emptyResponse :: SessionState -> CompileResponse
emptyResponse s = CompileResponse
  { js: Nothing
  , warnings: []
  , errors: []
  , types: []
  , cellLines: []
  , emits: []
  , runtime: s.runtime
  , "module": s."module"
  , cells: s.cells
  }

pickAdapter :: String -> _
pickAdapter = case _ of
  "node" -> nodeProcess
  "purerl" -> purerlBEAM
  _ -> browserWorker

-- | Apply a state update under the lock, then recompile against the
-- | new state, cache + return the snapshot. `finally` guarantees the
-- | lock is released even when `compileNow` throws or the adapter
-- | hangs long enough to be cancelled — otherwise a single stuck
-- | compile wedges every subsequent write in the process.
withUpdate
  :: SessionStore
  -> (SessionState -> SessionState)
  -> Aff CompileResponse
withUpdate (SessionStore { lock, state, broadcast, workspaceDir, packageName }) f = do
  _ <- AVar.take lock
  Aff.finally (AVar.put unit lock) do
    s0 <- liftEffect (Ref.read state)
    let s1 = f s0
    liftEffect (Ref.write s1 state)
    resp <- compileNow workspaceDir packageName s1
    liftEffect $ Ref.modify_ (_ { lastResponse = Just resp }) state
    persist workspaceDir s1
    broadcast resp
    pure resp

compileNow :: String -> String -> SessionState -> Aff CompileResponse
compileNow workspaceDir packageName s =
  let
    req = CompileRequest
      { "module": s."module"
      , cells: s.cells
      , runtime: s.runtime
      }
    synth = synthesize { purerl: s.runtime == "purerl" } req
    adapter = pickAdapter s.runtime
  in
    Compile.compile adapter workspaceDir packageName
      { userSource: synth.userSource
      , mainSource: synth.mainSource
      , cellLines: synth.cellLines
      , "module": s."module"
      , cells: s.cells
      }

-- | Public: force a recompile with the current state.
compileAndStore :: SessionStore -> Aff CompileResponse
compileAndStore store = withUpdate store identity

-- | Replace the full input state (module + cells + runtime) from a
-- | CompileRequest and compile. Used by POST /session/compile when
-- | the client supplies a body (matches the pre-session-store
-- | behaviour the frontend still relies on). nextCellId is bumped
-- | past the incoming ids so later server-side appends don't collide.
replaceAll :: SessionStore -> CompileRequest -> Aff CompileResponse
replaceAll store (CompileRequest r) = withUpdate store \s -> s
  { runtime = r.runtime
  , "module" = r."module"
  , cells = r.cells
  , nextCellId = nextIdAfter r.cells
  }
  where
  nextIdAfter cs =
    let maxId = Array.foldl
                  (\acc (Cell c) -> max acc (parseCellNumber c.id))
                  0 cs
    in maxId + 1
  parseCellNumber s = case Str.stripPrefix (Pattern "c") s of
    Just rest -> case Int.fromString rest of
      Just n -> n
      Nothing -> 0
    Nothing -> 0

updateModule :: SessionStore -> UserModule -> Aff CompileResponse
updateModule store m = withUpdate store _ { "module" = m }

-- | Trial-apply a full module replacement — compile against the
-- | resulting source but don't persist. Counterpart to `updateModule`
-- | for POST /session/module?preview=true.
previewUpdateModule :: SessionStore -> UserModule -> Aff CompileResponse
previewUpdateModule (SessionStore { lock, state, workspaceDir, packageName }) m = do
  _ <- AVar.take lock
  Aff.finally (AVar.put unit lock) do
    s0 <- liftEffect (Ref.read state)
    compileNow workspaceDir packageName (s0 { "module" = m })

-- | Apply a structured edit to the current module source. Returns
-- | `Left` (with a diagnostic message) when the patch is invalid
-- | against the current source (e.g. ReplaceRange out of bounds);
-- | otherwise applies the patch, recompiles, and returns the new
-- | snapshot. Lock semantics match `withUpdate`.
patchModule
  :: SessionStore
  -> ModulePatch
  -> Aff (Either String CompileResponse)
patchModule (SessionStore { lock, state, broadcast, workspaceDir, packageName }) patch = do
  _ <- AVar.take lock
  Aff.finally (AVar.put unit lock) do
    s0 <- liftEffect (Ref.read state)
    let UserModule m = s0."module"
    case applyModulePatch patch m.source of
      Left err -> pure (Left err)
      Right newSrc -> do
        let s1 = s0 { "module" = UserModule { source: newSrc } }
        liftEffect (Ref.write s1 state)
        resp <- compileNow workspaceDir packageName s1
        liftEffect $ Ref.modify_ (_ { lastResponse = Just resp }) state
        persist workspaceDir s1
        broadcast resp
        pure (Right resp)

-- | Trial-apply a `ModulePatch` — compile against the resulting
-- | source, return the compile response, but do not write the new
-- | source or the response back into session state. Intended for
-- | agents that want to probe a change's error/type implications
-- | before committing it (PATCH /session/module?preview=true).
previewModulePatch
  :: SessionStore
  -> ModulePatch
  -> Aff (Either String CompileResponse)
previewModulePatch (SessionStore { lock, state, workspaceDir, packageName }) patch = do
  _ <- AVar.take lock
  Aff.finally (AVar.put unit lock) do
    s0 <- liftEffect (Ref.read state)
    let UserModule m = s0."module"
    case applyModulePatch patch m.source of
      Left err -> pure (Left err)
      Right newSrc -> do
        let s1 = s0 { "module" = UserModule { source: newSrc } }
        resp <- compileNow workspaceDir packageName s1
        pure (Right resp)

-- | Pure: apply a `ModulePatch` to a source string. Exposed for
-- | testability.
applyModulePatch :: ModulePatch -> String -> Either String String
applyModulePatch patch src = case patch of
  AddImport spec ->
    if hasImport spec."module" src
      then Right src
      else Right (insertImport (renderImport spec) src)
  AppendBody text ->
    Right (ensureTrailingNewline src <> text)
  ReplaceRange { startLine, endLine, text } ->
    replaceLineRange startLine endLine text src

-- | Render an ImportSpec as a single PureScript import line.
renderImport :: ImportSpec -> String
renderImport spec =
  "import " <> spec."module" <> namesBit <> aliasBit
  where
  namesBit = case spec.names of
    Just ns -> " (" <> Str.joinWith ", " ns <> ")"
    Nothing -> ""
  aliasBit = case spec.alias of
    Just a -> " as " <> a
    Nothing -> ""

-- | Match `import <name>` ignoring trailing qualifiers/aliases. Lines
-- | are trimmed before comparison.
hasImport :: String -> String -> Boolean
hasImport name src =
  Array.any matches (Str.split (Pattern "\n") src)
  where
  prefix = "import " <> name
  matches line = case Str.stripPrefix (Pattern prefix) (Str.trim line) of
    Nothing -> false
    Just rest ->
      Str.length rest == 0
        || Str.take 1 rest == " "
        || Str.take 1 rest == "\t"
        || Str.take 1 rest == "("

-- | Insert a pre-rendered import line after the last existing import.
-- | If there are no imports, insert after the `module ... where`
-- | header. If there's no header either, prepend the line.
insertImport :: String -> String -> String
insertImport newLine src =
  let lines = Str.split (Pattern "\n") src
      anchor = case Array.findLastIndex isImport lines of
        Just i -> Just i
        Nothing -> Array.findIndex isModuleHeader lines
  in case anchor of
       Just i ->
         Str.joinWith "\n"
           (Array.take (i + 1) lines <> [ newLine ] <> Array.drop (i + 1) lines)
       Nothing -> newLine <> "\n" <> src
  where
  isImport l = case Str.stripPrefix (Pattern "import ") (Str.trim l) of
    Just _ -> true
    Nothing -> false
  isModuleHeader l = case Str.stripPrefix (Pattern "module ") (Str.trim l) of
    Just _ -> true
    Nothing -> false

ensureTrailingNewline :: String -> String
ensureTrailingNewline s
  | Str.length s == 0 = s
  | Str.take 1 (Str.drop (Str.length s - 1) s) == "\n" = s
  | otherwise = s <> "\n"

-- | Replace lines [startLine, endLine] (1-indexed, inclusive) with
-- | `text`. `text` may itself contain newlines.
replaceLineRange :: Int -> Int -> String -> String -> Either String String
replaceLineRange startLine endLine text src
  | startLine < 1 = Left ("startLine must be >= 1 (got " <> show startLine <> ")")
  | endLine < startLine =
      Left ("endLine (" <> show endLine <> ") must be >= startLine (" <> show startLine <> ")")
  | otherwise =
      let lines = Str.split (Pattern "\n") src
          n = Array.length lines
      in if endLine > n
           then Left ("endLine " <> show endLine <> " exceeds line count " <> show n)
           else
             let before = Array.take (startLine - 1) lines
                 after = Array.drop endLine lines
                 inserted = Str.split (Pattern "\n") text
             in Right $ Str.joinWith "\n" (before <> inserted <> after)

appendCell :: SessionStore -> { source :: String, kind :: String } -> Aff CompileResponse
appendCell store { source, kind } = withUpdate store (appendCellState { source, kind })

appendCellState :: { source :: String, kind :: String } -> SessionState -> SessionState
appendCellState { source, kind } s =
  let newId = "c" <> show s.nextCellId
      newCell = Cell { id: newId, kind, source, form: false }
  in s { cells = snoc s.cells newCell, nextCellId = s.nextCellId + 1 }

-- | Trial-apply a cell append — compile against the resulting cells
-- | but don't persist or broadcast. Counterpart to `appendCell` for
-- | POST /session/cells?preview=true.
previewAppendCell
  :: SessionStore -> { source :: String, kind :: String } -> Aff CompileResponse
previewAppendCell store body = withPreview store (appendCellState body)

updateCell
  :: SessionStore
  -> String
  -> { source :: Maybe String, kind :: Maybe String, form :: Maybe Boolean }
  -> Aff CompileResponse
updateCell store cellId patch = withUpdate store (updateCellState cellId patch)

updateCellState
  :: String
  -> { source :: Maybe String, kind :: Maybe String, form :: Maybe Boolean }
  -> SessionState
  -> SessionState
updateCellState cellId patch s = s { cells = applyPatch s.cells }
  where
  applyPatch cells = fromMaybe cells do
    idx <- findIndex (\(Cell c) -> c.id == cellId) cells
    modifyAt idx (patchCell patch) cells
  patchCell p (Cell c) = Cell
    { id: c.id
    , source: fromMaybe c.source p.source
    , kind: fromMaybe c.kind p.kind
    , form: fromMaybe c.form p.form
    }

-- | Trial-apply a cell update — compile against the resulting cells
-- | but don't persist or broadcast. Counterpart to `updateCell` for
-- | PATCH /session/cells/:id?preview=true.
previewUpdateCell
  :: SessionStore
  -> String
  -> { source :: Maybe String, kind :: Maybe String, form :: Maybe Boolean }
  -> Aff CompileResponse
previewUpdateCell store cellId patch = withPreview store (updateCellState cellId patch)

removeCell :: SessionStore -> String -> Aff CompileResponse
removeCell store cellId = withUpdate store (removeCellState cellId)

removeCellState :: String -> SessionState -> SessionState
removeCellState cellId s = s { cells = filter (\(Cell c) -> c.id /= cellId) s.cells }

-- | Trial-apply a cell removal — compile against the resulting cells
-- | but don't persist or broadcast. Counterpart to `removeCell` for
-- | DELETE /session/cells/:id?preview=true.
previewRemoveCell :: SessionStore -> String -> Aff CompileResponse
previewRemoveCell store cellId = withPreview store (removeCellState cellId)

-- | Shared tail of every preview endpoint: take the lock, apply the
-- | state transformation in memory only, compile, release — no write,
-- | no broadcast.
withPreview :: SessionStore -> (SessionState -> SessionState) -> Aff CompileResponse
withPreview (SessionStore { lock, state, workspaceDir, packageName }) f = do
  _ <- AVar.take lock
  Aff.finally (AVar.put unit lock) do
    s0 <- liftEffect (Ref.read state)
    compileNow workspaceDir packageName (f s0)

setRuntime :: SessionStore -> String -> Aff CompileResponse
setRuntime store runtime = withUpdate store _ { runtime = runtime }

-- ============================================================
-- /eval
-- ============================================================

-- | Input shape for a one-shot expression evaluation. `source` is a
-- | PureScript expression (not a module). `imports` are spliced in
-- | verbatim after `import Prelude` — pass either bare module names
-- | ("Data.Array") or full import specs ("Data.Array as Array").
type EvalRequest =
  { source :: String
  , imports :: Array String
  }

-- | Output shape for `/eval`. `value` is the emit produced by running
-- | the expression under Node, pre-parsed from its JSON-string form
-- | into structured Json (Nothing if the expression didn't emit — e.g.
-- | it failed to compile, or its type isn't `ToPlaygroundValue`).
-- | `type` is deliberately absent for now: purs-ide can't see per-
-- | workspace output, so exposing it would be unreliable.
type EvalResponse =
  { value :: Maybe Json
  , errors :: Array CompileError
  , warnings :: Array CompileError
  }

evalResponseCodec :: JsonCodec EvalResponse
evalResponseCodec = CAR.object "EvalResponse"
  { value: CAR.optional CA.json
  , errors: CA.array compileErrorCodec
  , warnings: CA.array compileErrorCodec
  }

-- | Synthesise a one-cell throwaway session from `EvalRequest`, run it
-- | through the preview pipeline (no state mutation, no broadcast,
-- | lock-serialised), and strip down the result. The caller's store
-- | is used purely as a compile sandbox — its in-memory state is
-- | unchanged afterwards. Runtime is forced to `"node"` so emits
-- | come back to the server instead of being shipped to the browser.
evaluate :: SessionStore -> EvalRequest -> Aff EvalResponse
evaluate store { source, imports } = do
  resp <- withPreview store \s -> s
    { runtime = "node"
    , "module" = UserModule { source: renderEvalModule imports }
    , cells = [ Cell { id: "eval", kind: "expr", source, form: false } ]
    , nextCellId = 2
    }
  pure (extractEval resp)

-- | Build the Playground.User module source an /eval call compiles
-- | against. Always includes `import Prelude`; subsequent imports are
-- | spliced verbatim — the caller chooses whether to write bare
-- | names, aliases, or explicit lists.
renderEvalModule :: Array String -> String
renderEvalModule imports =
  "module Playground.User where\n\nimport Prelude\n"
    <> Str.joinWith "" (map (\i -> "import " <> i <> "\n") imports)

extractEval :: CompileResponse -> EvalResponse
extractEval (CompileResponse r) =
  { value: do
      CellEmit e <- Array.find (\(CellEmit em) -> em.id == "eval") r.emits
      -- Node adapter forwards emit values as pre-stringified JSON.
      -- Parse back to structured Json; if parsing fails for any
      -- reason, drop the value (errors/warnings still carry signal).
      hush (jsonParser e.value)
  , errors: r.errors
  , warnings: r.warnings
  }
