module Playground.Frontend.Shell where

import Prelude

import Affjax.RequestBody as RB
import Affjax.RequestHeader (RequestHeader(..)) as AX
import Affjax.ResponseFormat as RF
import Affjax.StatusCode (StatusCode(..)) as AX
import Affjax.Web (defaultRequest, printError, request) as AX
import Control.Alt ((<|>))
import Data.Argonaut.Core (Json, stringify)
import Data.Argonaut.Core as AJ
import Data.Argonaut.Parser (jsonParser)
import Data.Array (filter, findIndex, mapWithIndex, modifyAt, snoc)
import Data.Array as Array
import Data.String as Str
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.HTTP.Method (Method(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Int (toNumber)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String.Pattern (Pattern(..))
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Data.Time.Duration (Milliseconds(..))
import Effect.Aff (delay)
import Effect.Aff.Class (class MonadAff)
import Foreign.Object as Object
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import Type.Proxy (Proxy(..))

import Data.Foldable (for_)

import Playground.Frontend.CodeMirror (ErrorSpan)
import Playground.Frontend.Config (backendUrl, readHideParam, writeHideParam, wsBackendUrl)
import Playground.Frontend.Editor as Editor
import Playground.Frontend.FormCell (FieldKind(..), FieldSpec, analyseType, parseRecordLiteral, regenerateRecordSource)
import Playground.Frontend.InScope as InScope
import Playground.Frontend.RenderView as RenderView
import Playground.Frontend.SigilView as SigilView
import Playground.Frontend.Starter (Starter, starters)
import Playground.Frontend.Starter as Starter
import Playground.Frontend.Value (PlaygroundValue)
import Playground.Frontend.Value as Value
import Playground.Frontend.ValueView as ValueView
import Playground.Frontend.Worker (Worker, WorkerMessage(..))
import Playground.Frontend.Worker as Worker
import Playground.Frontend.WsClient as WsClient
import Playground.Conch
  ( Broadcast(..)
  , ClientMsg(..)
  , ConchHeldBody
  , ConchState
  , SubscriberId
  , broadcastCodec
  , clientMsgCodec
  , conchHeldBodyCodec
  , unSubscriberId
  )
import Playground.Session
  ( Cell(..)
  , CellEmit(..)
  , CellRange(..)
  , CellType(..)
  , CompileError(..)
  , CompileRequest(..)
  , CompileResponse(..)
  , Position(..)
  , UserModule(..)
  , compileRequestCodec
  , compileResponseCodec
  )

type CellRec = { id :: String, kind :: String, source :: String, form :: Boolean }

-- | Lift a starter's cell shape (no form metadata) into a `CellRec`.
withFormDefault :: { id :: String, kind :: String, source :: String } -> CellRec
withFormDefault c = { id: c.id, kind: c.kind, source: c.source, form: false }

-- | Which of the four main columns are visible in this tab. Each flag
-- | maps 1:1 to a rendered `pane-*` column. Persisted in the URL as
-- | `?hide=module,cells,values,render` (omitted when everything shows).
data ColumnKey = KeyModule | KeyCells | KeyGutter | KeyRender

derive instance Eq ColumnKey

type ColumnVisibility =
  { showModule :: Boolean
  , showCells :: Boolean
  , showGutter :: Boolean
  , showRender :: Boolean
  }

allVisible :: ColumnVisibility
allVisible =
  { showModule: true, showCells: true, showGutter: true, showRender: true }

isVisible :: ColumnKey -> ColumnVisibility -> Boolean
isVisible = case _ of
  KeyModule -> _.showModule
  KeyCells -> _.showCells
  KeyGutter -> _.showGutter
  KeyRender -> _.showRender

toggleKey :: ColumnKey -> ColumnVisibility -> ColumnVisibility
toggleKey k v = case k of
  KeyModule -> v { showModule = not v.showModule }
  KeyCells -> v { showCells = not v.showCells }
  KeyGutter -> v { showGutter = not v.showGutter }
  KeyRender -> v { showRender = not v.showRender }

columnKeyLabel :: ColumnKey -> String
columnKeyLabel = case _ of
  KeyModule -> "Module"
  KeyCells -> "Cells"
  KeyGutter -> "Values"
  KeyRender -> "Render"

-- | URL token for a column. "values" is the user-facing name for the
-- | gutter (which shows types + evaluated values); "gutter" is accepted
-- | as an alias when parsing for back-compat with any internal notes.
columnKeyToken :: ColumnKey -> String
columnKeyToken = case _ of
  KeyModule -> "module"
  KeyCells -> "cells"
  KeyGutter -> "values"
  KeyRender -> "render"

-- | Decode `?hide=` value into a visibility record. Unknown tokens are
-- | ignored so typos don't silently hide everything.
visibilityFromHide :: String -> ColumnVisibility
visibilityFromHide hide =
  let tokens = if hide == "" then [] else Str.split (Pattern ",") hide
      has t = Array.any (_ == t) tokens
  in
    { showModule: not (has "module")
    , showCells: not (has "cells")
    , showGutter: not (has "values" || has "gutter")
    , showRender: not (has "render")
    }

-- | Encode visibility as a `?hide=` value. Empty string when everything
-- | shows (the default); caller omits the param in that case.
hideFromVisibility :: ColumnVisibility -> String
hideFromVisibility v =
  let hidden = Array.catMaybes
        [ if v.showModule then Nothing else Just (columnKeyToken KeyModule)
        , if v.showCells then Nothing else Just (columnKeyToken KeyCells)
        , if v.showGutter then Nothing else Just (columnKeyToken KeyGutter)
        , if v.showRender then Nothing else Just (columnKeyToken KeyRender)
        ]
  in Str.joinWith "," hidden

-- | Grid-template-columns string listing only the visible columns'
-- | fractions. When a single column is visible, collapse to `1fr` so
-- | the track is guaranteed to fill the container regardless of which
-- | column it is (otherwise a lone `0.8fr` track leaves visible
-- | whitespace on the right in some browsers). Multiple visible
-- | columns preserve the 1.2 / 1.2 / 0.8 / 0.8 ratio.
gridTemplateForVisibility :: ColumnVisibility -> String
gridTemplateForVisibility v =
  let parts = Array.catMaybes
        [ if v.showModule then Just "1.2fr" else Nothing
        , if v.showCells then Just "1.2fr" else Nothing
        , if v.showGutter then Just "0.8fr" else Nothing
        , if v.showRender then Just "0.8fr" else Nothing
        ]
  in case Array.length parts of
       0 -> "1fr"
       1 -> "1fr"
       _ -> Str.joinWith " " parts

type State =
  { moduleSource :: String
  , cells :: Array CellRec
  , nextCellId :: Int
  , runtime :: String             -- "browser" | "node" | "purerl"
  , starterKey :: String          -- key of the currently-loaded starter
  , starterMenuOpen :: Boolean
  , settingsOpen :: Boolean       -- gear-revealed panel with runtime + in-scope + tagline
  , compiling :: Boolean
  , errors :: Array CompileError
  , warnings :: Array CompileError
  , cellRanges :: Array CellRange
  , transportError :: Maybe String
  , runtimeError :: Maybe String
  , cellResults :: Map String PlaygroundValue
  , cellTypes :: Map String String
  , pendingCompile :: Maybe H.ForkId
  , worker :: Maybe Worker
  , workerSub :: Maybe H.SubscriptionId
  , workerTimeout :: Maybe H.ForkId
  -- Conch + WebSocket transport. `myId` is assigned by the server on WS
  -- connect via the Welcome frame. `conch` is the latest server-authored
  -- state and updates on every ConchUpdate broadcast. `iHold` is the
  -- derived "am I the current holder" used for read-only editor toggles.
  -- `requestingConch`/`nextConchRetryAt`/`conchBackoffMs` drive the
  -- backoff state machine when requests are denied.
  , myId :: Maybe SubscriberId
  , conch :: ConchState
  , requestingConch :: Boolean
  , nextConchRetryAt :: Maybe Number
  , conchBackoffMs :: Int
  , ws :: Maybe WsClient.WebSocket
  , wsSub :: Maybe H.SubscriptionId
  , conchBanner :: Maybe String      -- shown when a 409 comes back from an HTTP write
  -- What we last pushed to the server. Used by Compile to diff the
  -- current state against the server's view so we can send granular
  -- PATCHes (POST /session/module, PATCH /session/cells/:id) instead
  -- of the coarse POST /session/compile that would clobber any
  -- agent-initiated writes landing in fields the human didn't touch.
  , lastSyncedModule :: String
  , lastSyncedCells :: Map String { source :: String, kind :: String }
  , lastSyncedRuntime :: String
  -- Per-tab column visibility. Seeded from the `?hide=` URL param on
  -- Startup and written back on every toggle, so a layout like
  -- `?hide=module,cells,values` (a render-only view) is shareable.
  , visibility :: ColumnVisibility
  }

type Slots =
  ( moduleEditor :: H.Slot Editor.Query Editor.Output Unit
  , cellEditor :: H.Slot Editor.Query Editor.Output String
  , sigil :: forall q. H.Slot q Void String
  , render :: forall q. H.Slot q Void String
  )

_moduleEditor :: Proxy "moduleEditor"
_moduleEditor = Proxy

_cellEditor :: Proxy "cellEditor"
_cellEditor = Proxy

_sigil :: Proxy "sigil"
_sigil = Proxy

_render :: Proxy "render"
_render = Proxy

data Action
  = Compile
  | ScheduleCompile
  | ModuleChanged String
  | CellChanged String String
  | AddCell
  | RemoveCell String
  | ToggleCellKind String
  | ToggleCellForm String              -- flip form/code display for a cell
  | CellFormFieldChanged String String String  -- cellId, fieldName, newValue (string-typed; coerced on regen)
  | SetRuntime String
  | ToggleStarterMenu
  | LoadStarter String
  | ToggleSettings
  | HandleWorkerMessage WorkerMessage
  | WorkerTimeout
  | WsOpened                -- WebSocket connected; Welcome frame will follow
  | WsIncoming String       -- raw JSON text frame from the server
  | WsClosed Int String     -- WS closed; TODO: reconnect
  | WsErrored               -- transient transport error
  | RequestConchAction      -- user clicked "Take Conch"
  | YieldConchAction        -- user clicked "Yield" (has the conch)
  | ForceConchAction        -- user clicked "Force Take" (holder idle)
  | DismissConchBanner
  | ToggleColumn ColumnKey  -- user clicked a column-visibility toggle
  | Startup                 -- runs once on init: read URL view state, compile, open WS

initialState :: forall i. i -> State
initialState _ =
  let s = Starter.defaultStarter
  in { moduleSource: s.moduleSource
     , cells: map withFormDefault s.cells
     , nextCellId: nextIdAfter s.cells
     , runtime: "browser"
     , starterKey: s.key
     , starterMenuOpen: false
     , settingsOpen: false
     , compiling: false
     , errors: []
     , warnings: []
     , cellRanges: []
     , transportError: Nothing
     , runtimeError: Nothing
     , cellResults: Map.empty
     , cellTypes: Map.empty
     , pendingCompile: Nothing
     , worker: Nothing
     , workerSub: Nothing
     , workerTimeout: Nothing
     , myId: Nothing
     , conch: { holder: Nothing, lastActivityAt: 0.0 }
     , requestingConch: false
     , nextConchRetryAt: Nothing
     , conchBackoffMs: 250
     , ws: Nothing
     , wsSub: Nothing
     , conchBanner: Nothing
     -- Empty strings / maps so the first Compile pass falls into the
     -- "everything changed, do a full /session/compile" branch and
     -- seeds lastSynced* from the server's response.
     , lastSyncedModule: ""
     , lastSyncedCells: Map.empty
     , lastSyncedRuntime: ""
     , visibility: allVisible
     }
  where
  -- Cell ids are "c1", "c2", …; pick an int strictly above the
  -- highest used so new cells don't collide.
  nextIdAfter cs = Array.length cs + 1

debounceMs :: Milliseconds
debounceMs = Milliseconds 400.0

workerTimeoutMs :: Milliseconds
workerTimeoutMs = Milliseconds 3000.0

component :: forall q i o m. MonadAff m => H.Component q i o m
component = H.mkComponent
  { initialState
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction
      , initialize = Just Startup
      }
  }

handleAction
  :: forall o m
   . MonadAff m
  => Action
  -> H.HalogenM State Action Slots o m Unit
handleAction = case _ of
  Startup -> do
    hide <- H.liftEffect readHideParam
    H.modify_ _ { visibility = visibilityFromHide hide }
    hydrateFromServer
    openWebSocket
  ModuleChanged src -> do
    -- Commit the user's content BEFORE any other state change.
    -- Halogen re-renders after each H.modify_; if other state updates
    -- run first, the intermediate render has moduleSource still at the
    -- old value, and the editor's UpdateInput receives stale
    -- initialDoc and clobbers the user's just-typed character via
    -- setContent.
    H.modify_ _ { moduleSource = src }
    handleAction ScheduleCompile
  CellChanged id src -> do
    H.modify_ \s -> s { cells = updateCell id src s.cells }
    handleAction ScheduleCompile
  AddCell -> do
    H.modify_ \s ->
      let newId = "c" <> show s.nextCellId
          newCell = { id: newId, kind: "expr", source: "", form: false }
      in s { cells = snoc s.cells newCell, nextCellId = s.nextCellId + 1 }
    handleAction ScheduleCompile
  RemoveCell id -> do
    H.modify_ \s -> s
      { cells = filter (_.id >>> (_ /= id)) s.cells
      , cellResults = Map.delete id s.cellResults
      }
    handleAction ScheduleCompile
  ToggleCellKind id -> do
    H.modify_ \s -> s
      { cells = map (\c -> if c.id == id then c { kind = flipKind c.kind } else c) s.cells
      -- Let-cells never emit; drop any stale result so the gutter
      -- doesn't render against the wrong kind.
      , cellResults = Map.delete id s.cellResults
      , cellTypes = Map.delete id s.cellTypes
      }
    handleAction ScheduleCompile
  ToggleCellForm id -> do
    s <- H.get
    case Array.find ((_ == id) <<< _.id) s.cells of
      Nothing -> pure unit
      Just c -> do
        let newForm = not c.form
        -- Flip locally first so the view swaps immediately; the PATCH
        -- response only updates compile-derived state (errors, types),
        -- not the cells array, so we can't wait for it.
        H.modify_ \st -> st
          { cells = map (\cc -> if cc.id == id then cc { form = newForm } else cc) st.cells
          }
        let body = stringify
              ( AJ.fromObject
                  ( Object.singleton "form" (AJ.fromBoolean newForm) )
              )
        result <- httpJson PATCH (backendUrl <> "/session/cells/" <> id) body
        case result of
          Right resp -> applyCompileResponse resp
          Left _ -> pure unit  -- conch banner shown by httpJson if 409
  CellFormFieldChanged id field newValue -> do
    s <- H.get
    case Array.find ((_ == id) <<< _.id) s.cells of
      Nothing -> pure unit
      Just c -> case Map.lookup id s.cellTypes of
        Nothing -> pure unit  -- haven't compiled yet; ignore
        Just typeStr -> case regenerateRecordSource typeStr c.source field newValue of
          Nothing -> pure unit  -- type or source unparseable; safe no-op
          Just newSrc -> do
            -- Optimistically update local state so the input doesn't
            -- snap back while the PATCH is in flight; the snapshot
            -- response will override harmlessly if it differs.
            H.modify_ \st -> st
              { cells = map (\cc -> if cc.id == id then cc { source = newSrc } else cc) st.cells
              }
            let body = stringify
                  ( AJ.fromObject
                      ( Object.singleton "source" (AJ.fromString newSrc) )
                  )
            result <- httpJson PATCH (backendUrl <> "/session/cells/" <> id) body
            case result of
              Right resp -> applyCompileResponse resp
              Left _ -> pure unit
  SetRuntime r -> do
    s0 <- H.get
    when (s0.runtime /= r) do
      H.modify_ _ { runtime = r, cellResults = Map.empty }
      handleAction ScheduleCompile
  ToggleStarterMenu -> H.modify_ \s -> s { starterMenuOpen = not s.starterMenuOpen }
  LoadStarter k -> case Starter.findByKey k of
    Nothing -> pure unit
    Just starter -> do
      H.modify_ \s -> s
        { moduleSource = starter.moduleSource
        , cells = map withFormDefault starter.cells
        , nextCellId = Array.length starter.cells + 1
        , starterKey = starter.key
        , starterMenuOpen = false
        , cellResults = Map.empty
        , cellTypes = Map.empty
        }
      handleAction ScheduleCompile
  ToggleSettings -> H.modify_ \s -> s { settingsOpen = not s.settingsOpen }
  ToggleColumn key -> do
    H.modify_ \s -> s { visibility = toggleKey key s.visibility }
    s <- H.get
    H.liftEffect $ writeHideParam (hideFromVisibility s.visibility)
  WsOpened -> pure unit   -- Welcome frame will arrive separately
  WsIncoming raw -> handleIncomingBroadcast raw
  WsClosed _ _ -> H.modify_ _ { ws = Nothing }    -- TODO: reconnect w/ backoff
  WsErrored -> pure unit
  RequestConchAction -> do
    sendClientMsg RequestConch
    H.modify_ _ { requestingConch = true }
  YieldConchAction -> sendClientMsg YieldConch
  ForceConchAction -> do
    sendClientMsg ForceConch
    H.modify_ _ { requestingConch = true }
  DismissConchBanner -> H.modify_ _ { conchBanner = Nothing }
  ScheduleCompile -> do
    s <- H.get
    case s.pendingCompile of
      Just fid -> H.kill fid
      Nothing -> pure unit
    fid <- H.fork do
      H.liftAff (delay debounceMs)
      handleAction Compile
    H.modify_ _ { pendingCompile = Just fid }
  Compile -> do
    H.modify_ _
      { compiling = true
      , transportError = Nothing
      , runtimeError = Nothing
      , pendingCompile = Nothing
      }
    s <- H.get
    -- Decide granular vs full: granular is safe only when the only
    -- diffs vs the server are text-edits to the module or existing
    -- cells. Any structural change (cells added, removed, kind
    -- flipped, runtime switched) falls back to the coarse
    -- POST /session/compile.
    if needsFullCompile s
      then runFullCompile s
      else runGranularCompile s
  HandleWorkerMessage msg -> case msg of
    Emit id value ->
      H.modify_ \s -> s { cellResults = Map.insert id (Value.parse value) s.cellResults }
    Done -> teardownExecution
    WorkerError err -> do
      H.modify_ _ { runtimeError = Just err }
      teardownExecution
    Unknown tag ->
      H.modify_ _ { runtimeError = Just ("worker: unknown message " <> tag) }
  WorkerTimeout -> do
    H.modify_ _ { runtimeError = Just ("timeout after " <> show workerTimeoutMs) }
    teardownExecution
  where
  updateCell id src cells =
    fromMaybe cells do
      idx <- findIndex (_.id >>> (_ == id)) cells
      modifyAt idx (_ { source = src }) cells
  flipKind = case _ of
    "let" -> "expr"
    _ -> "let"

-- | Decide whether to use POST /session/compile (clobbers everything
-- | on the server with our local view) or per-field granular PATCHes
-- | (only the fields we actually changed). Granular is only safe if
-- | our diff vs the server is limited to text edits on the module
-- | and existing cells. Anything else — cells added/removed, kind
-- | flipped, runtime switched — requires the full compile so the
-- | server ends up with the structural shape we expect.
needsFullCompile :: State -> Boolean
needsFullCompile s =
  s.runtime /= s.lastSyncedRuntime
    || Array.length s.cells /= Map.size s.lastSyncedCells
    || Array.any cellStructureDiverged s.cells
  where
  cellStructureDiverged c = case Map.lookup c.id s.lastSyncedCells of
    Nothing -> true
    Just last -> last.kind /= c.kind

-- | Granular path: POST /session/module if the module's text changed,
-- | then PATCH /session/cells/:id for every cell whose source changed.
-- | Each call returns a full CompileResponse; only the last is worth
-- | applying to the UI. If nothing actually changed, clear the
-- | "compiling" indicator and stop.
runGranularCompile
  :: forall o m
   . MonadAff m
  => State
  -> H.HalogenM State Action Slots o m Unit
runGranularCompile s = do
  let moduleDirty = s.moduleSource /= s.lastSyncedModule
      cellsDirty = Array.filter cellSourceChanged s.cells
      cellSourceChanged c = case Map.lookup c.id s.lastSyncedCells of
        Just last -> last.source /= c.source
        Nothing -> true
  if not moduleDirty && Array.null cellsDirty
    then H.modify_ _ { compiling = false }
    else do
      moduleResp <-
        if moduleDirty
          then Just <$> sendModuleEdit s.lastSyncedModule s.moduleSource
          else pure Nothing
      cellResps <- for cellsDirty \c -> httpJson PATCH
        (backendUrl <> "/session/cells/" <> c.id)
        (stringify (encodeJsonObject [ Tuple "source" c.source ]))
      let lastResp = Array.last cellResps <|> moduleResp
      case lastResp of
        Just (Right resp) -> applyCompileResponse resp
        Just (Left err) -> H.modify_ _
          { compiling = false, transportError = Just err }
        Nothing -> H.modify_ _ { compiling = false }

-- | Turn a user-driven module text edit into the narrowest PATCH the
-- | server will accept, so concurrent agent edits to untouched lines
-- | survive. Three branches, in order of specificity:
-- |   - Pure-append (new == old ++ suffix): PATCH appendBody.
-- |   - Single contiguous line range diff: PATCH replaceRange.
-- |   - Anything else (pure line insertion, tangled multi-range edit):
-- |     fall back to POST /session/module, which is a full replace.
sendModuleEdit
  :: forall o m
   . MonadAff m
  => String
  -> String
  -> H.HalogenM State Action Slots o m (Either String CompileResponse)
sendModuleEdit old new =
  case computeModuleDiff old new of
    DiffAppend suffix -> httpJson PATCH
      (backendUrl <> "/session/module")
      (stringify (encodeJsonObject [ Tuple "appendBody" suffix ]))
    DiffReplaceRange sl el text -> httpJson PATCH
      (backendUrl <> "/session/module")
      (stringify (encodeReplaceRange sl el text))
    DiffFullReplace -> httpJson POST
      (backendUrl <> "/session/module")
      (stringify (encodeJsonObject [ Tuple "source" new ]))
  where
  encodeReplaceRange sl el text =
    AJ.fromObject (Object.fromFoldable
      [ Tuple "replaceRange"
          (AJ.fromObject (Object.fromFoldable
            [ Tuple "startLine" (AJ.fromNumber (toNumber sl))
            , Tuple "endLine" (AJ.fromNumber (toNumber el))
            , Tuple "text" (AJ.fromString text)
            ]))
      ])

-- | Categorised line-level diff between two strings. `DiffAppend`
-- | strictly extends the old source; `DiffReplaceRange` swaps in a
-- | single contiguous run of lines; `DiffFullReplace` is the "too
-- | tangled for a single PATCH" bucket.
data ModuleDiff
  = DiffAppend String
  | DiffReplaceRange Int Int String
  | DiffFullReplace

computeModuleDiff :: String -> String -> ModuleDiff
computeModuleDiff old new =
  if pureAppend
    then DiffAppend (Str.drop (Str.length old) new)
    else
      let
        oldLines = Str.split (Pattern "\n") old
        newLines = Str.split (Pattern "\n") new
        oldLen = Array.length oldLines
        newLen = Array.length newLines
        prefix = lcpLines oldLines newLines
        -- Cap the suffix scan so it can't overlap the prefix in
        -- either array.
        capped = min (oldLen - prefix) (newLen - prefix)
        suffix = lcsLines oldLines newLines capped
        startLine = prefix + 1
        endLine = oldLen - suffix
        newSlice = Array.slice prefix (newLen - suffix) newLines
        text = Str.joinWith "\n" newSlice
      in
        -- Two cases that can't round-trip through replaceRange:
        --   - `endLine < startLine` means a pure insertion (zero
        --     lines replaced by new text) — replaceRange requires
        --     endLine >= startLine.
        --   - `text == ""` with a range that actually has lines in
        --     it means a pure deletion; the server's replaceLineRange
        --     would insert an empty line rather than collapse, which
        --     would make our next diff fire again (ping-pong).
        -- Both fall back to the full-replace POST.
        if endLine < startLine || Str.null text
          then DiffFullReplace
          else DiffReplaceRange startLine endLine text
  where
  pureAppend =
    Str.length new > Str.length old
      && Str.take (Str.length old) new == old
  lcpLines xs ys = go 0
    where
    go i
      | i >= Array.length xs = i
      | i >= Array.length ys = i
      | Array.index xs i /= Array.index ys i = i
      | otherwise = go (i + 1)
  lcsLines xs ys cap = go 0
    where
    xLen = Array.length xs
    yLen = Array.length ys
    go i
      | i >= cap = i
      | Array.index xs (xLen - 1 - i) /= Array.index ys (yLen - 1 - i) = i
      | otherwise = go (i + 1)

-- | Fallback path: POST the full state to /session/compile, let the
-- | server `replaceAll` its view to match ours. Only runs when the
-- | diff is too structural (add/remove cell, kind flip, runtime
-- | change) for granular endpoints to express — and note that in
-- | Drive mode this still clobbers any concurrent agent writes to
-- | fields the human hasn't touched. That's the known limitation
-- | documented on the Drive/Observe commit.
runFullCompile
  :: forall o m
   . MonadAff m
  => State
  -> H.HalogenM State Action Slots o m Unit
runFullCompile s = do
  let
    req = CompileRequest
      { "module": UserModule { source: s.moduleSource }
      , cells: map (\c -> Cell { id: c.id, kind: c.kind, source: c.source, form: c.form }) s.cells
      , runtime: s.runtime
      }
    bodyJson = stringify (CA.encode compileRequestCodec req)
  result <- httpJson POST (backendUrl <> "/session/compile") bodyJson
  case result of
    Left err -> H.modify_ _
      { compiling = false, transportError = Just err }
    Right resp -> applyCompileResponse resp

-- | Shared CompileResponse application: clear compiling, update
-- | errors/warnings/types/ranges, re-decorate editors, dispatch to
-- | the worker or fold in server-side emits, and snapshot the
-- | server's view into lastSynced* so the next Compile can diff.
applyCompileResponse
  :: forall o m
   . MonadAff m
  => CompileResponse
  -> H.HalogenM State Action Slots o m Unit
applyCompileResponse (CompileResponse r) = do
  let
    typesMap = Map.fromFoldable
      ( map (\(CellType ct) -> Tuple ct.id ct.signature) r.types )
    UserModule rm = r."module"
    syncedCells = Map.fromFoldable
      ( map (\(Cell c) -> Tuple c.id { source: c.source, kind: c.kind }) r.cells )
  H.modify_ _
    { compiling = false
    , errors = r.errors
    , warnings = r.warnings
    , cellRanges = r.cellLines
    , cellTypes = typesMap
    , lastSyncedModule = rm.source
    , lastSyncedCells = syncedCells
    , lastSyncedRuntime = r.runtime
    }
  decorateErrors r.errors r.cellLines
  if not (Array.null r.emits) then do
    teardownExecution
    H.modify_ \s' ->
      let decoded = Map.fromFoldable
            ( map (\(CellEmit e) -> Tuple e.id (Value.parse e.value)) r.emits )
      in s' { cellResults = decoded }
  else case r.js of
    Nothing -> teardownExecution
    Just js -> startExecution js

-- | Affjax wrapper for *mutating* endpoints. Sends the caller's
-- | `X-Atelier-Subscriber-Id` header if present, decodes 2xx as a
-- | `CompileResponse`, and surfaces a 409 (conch-held) by setting
-- | `conchBanner` in state so the UI can prompt the user to request
-- | the conch. Transport and decode failures collapse into `Left`.
-- |
-- | Note: tied to `HalogenM` (not just `MonadAff`) because 409 handling
-- | writes into component state.
httpJson
  :: forall o m
   . MonadAff m
  => Method
  -> String
  -> String
  -> H.HalogenM State Action Slots o m (Either String CompileResponse)
httpJson method url bodyJson = do
  s <- H.get
  let
    authHeaders = case s.myId of
      Nothing -> []
      Just sid -> [ AX.RequestHeader "X-Atelier-Subscriber-Id" (unSubscriberId sid) ]
  result <- H.liftAff $ AX.request $ AX.defaultRequest
    { method = Left method
    , url = url
    , responseFormat = RF.json
    , content = if Str.null bodyJson then Nothing else Just (RB.string bodyJson)
    , headers = authHeaders
    }
  case result of
    Left err -> pure (Left (AX.printError err))
    Right r -> case r.status of
      AX.StatusCode 409 -> do
        let banner = case CA.decode conchHeldBodyCodec r.body of
              Left _ -> "Another viewer holds the conch."
              Right held -> conchHeldMessage held
        H.modify_ _ { conchBanner = Just banner, compiling = false }
        pure (Left ("conch-held: " <> banner))
      AX.StatusCode code
        | code >= 200 && code < 300 -> case CA.decode compileResponseCodec r.body of
            Left decodeErr -> pure (Left ("decode: " <> CA.printJsonDecodeError decodeErr))
            Right resp -> pure (Right resp)
        | otherwise -> pure (Left ("HTTP " <> show code))

-- | Render the 409 payload as a human banner. `lastActivityAt` is raw
-- | ms-since-epoch; we present it as "idle Xs ago" so the user can
-- | tell whether a Force is plausible. Rough — the banner is transient,
-- | the full conch state is already visible in the indicator button.
conchHeldMessage :: ConchHeldBody -> String
conchHeldMessage held = case held.holder of
  Nothing -> "Conch is unclaimed. Take it to write."
  Just _ -> "Another viewer holds the conch. Request it to write."

-- | Build a JSON object from a list of string-keyed string values.
-- | We roll this by hand instead of reaching for a codec because each
-- | endpoint takes a different tiny shape and codecs would be more
-- | ceremony than the endpoint bodies deserve.
encodeJsonObject :: Array (Tuple String String) -> Json
encodeJsonObject pairs =
  AJ.fromObject (Object.fromFoldable (map encodeEntry pairs))
  where
  encodeEntry (Tuple k v) = Tuple k (AJ.fromString v)

-- | Initial page load: pull the server's session so a second Claude's
-- | writes survive a force-reload. If the server is at its pristine
-- | initial state (empty cells + the server's default module), or if
-- | we can't reach the server, fall back to compiling the local
-- | starter — otherwise the frontend would stomp the session with its
-- | starter the way it used to.
hydrateFromServer
  :: forall o m
   . MonadAff m
  => H.HalogenM State Action Slots o m Unit
hydrateFromServer = do
  result <- H.liftAff $ AX.request $ AX.defaultRequest
    { method = Left GET
    , url = backendUrl <> "/session"
    , responseFormat = RF.json
    , content = Nothing
    }
  case result of
    Left _ -> handleAction Compile
    Right { body } -> case CA.decode compileResponseCodec body of
      Left _ -> handleAction Compile
      Right (CompileResponse r) ->
        let UserModule rm = r."module"
        in if Array.null r.cells && rm.source == pristineServerModule
          then handleAction Compile
          else applyRemote r
  where
  pristineServerModule = "module Scratch where\n\nimport Prelude\n"

-- | Open the WebSocket subscription to `/session/ws` and wire incoming
-- | frames into the Halogen event stream via a Subscription. The WS
-- | connection lives for the component's lifetime; closures are logged
-- | and, in v1, not auto-reconnected (reconnect logic is a task-2.5
-- | follow-up — a page reload re-establishes).
openWebSocket
  :: forall o m
   . MonadAff m
  => H.HalogenM State Action Slots o m Unit
openWebSocket = do
  { emitter, listener } <- H.liftEffect HS.create
  ws <- H.liftEffect $ WsClient.connect (wsBackendUrl <> "/session/ws")
    { onOpen: HS.notify listener WsOpened
    , onMessage: \msg -> HS.notify listener (WsIncoming msg)
    , onClose: \code reason -> HS.notify listener (WsClosed code reason)
    , onError: HS.notify listener WsErrored
    }
  sub <- H.subscribe emitter
  H.modify_ _ { ws = Just ws, wsSub = Just sub }

-- | Dispatch an incoming WS frame. Three broadcast variants matter:
-- | `Welcome` binds our SubscriberId + initial conch state + snapshot;
-- | `Snapshot` carries a fresh compile response after another
-- | subscriber's write; `ConchUpdate` is a pure conch-state transition
-- | (grant/yield/force/disconnect).
handleIncomingBroadcast
  :: forall o m
   . MonadAff m
  => String
  -> H.HalogenM State Action Slots o m Unit
handleIncomingBroadcast raw = case jsonParser raw of
  Left _ -> pure unit
  Right j -> case CA.decode broadcastCodec j of
    Left _ -> pure unit
    Right bc -> case bc of
      Welcome r -> do
        H.modify_ _ { myId = Just r.yourId, conch = r.conch }
        let CompileResponse snap = r.snapshot
        applyRemote snap
        syncEditorsEditable
      Snapshot r -> do
        H.modify_ _ { conch = r.conch }
        s <- H.get
        let CompileResponse snap = r.snapshot
        when (remoteDiffers s snap) (applyRemote snap)
      ConchUpdate r -> do
        s <- H.get
        let wasRequesting = s.requestingConch
            iHoldNow = case r.conch.holder, s.myId of
              Just h, Just me -> h == me
              _, _ -> false
        H.modify_ _
          { conch = r.conch
          , requestingConch = if iHoldNow || (not wasRequesting) then false else s.requestingConch
          , conchBackoffMs = if iHoldNow then 250 else s.conchBackoffMs
          , conchBanner = if iHoldNow then Nothing else s.conchBanner
          }
        syncEditorsEditable

-- | Push the current `iHoldConch` value into every live editor so CM6
-- | updates its read-only state. Called after any transition that
-- | changes who holds the conch.
syncEditorsEditable
  :: forall o m
   . MonadAff m
  => H.HalogenM State Action Slots o m Unit
syncEditorsEditable = do
  s <- H.get
  let editable = iHoldConch s
  _ <- H.tell _moduleEditor unit (Editor.SetEditable editable)
  for_ s.cells \c ->
    H.tell _cellEditor c.id (Editor.SetEditable editable)

-- | Derived: do we currently hold the conch? Used to drive editor
-- | editability and the conch indicator button state.
iHoldConch :: State -> Boolean
iHoldConch s = case s.conch.holder, s.myId of
  Just h, Just me -> h == me
  _, _ -> false

-- | Serialise a `ClientMsg` and send it through the open WS. Silent
-- | no-op if the socket isn't open yet (shouldn't happen — UI actions
-- | that generate ClientMsgs are only wired once the welcome's arrived,
-- | and the JS FFI guards against send-before-open anyway).
sendClientMsg
  :: forall o m
   . MonadAff m
  => ClientMsg
  -> H.HalogenM State Action Slots o m Unit
sendClientMsg msg = do
  s <- H.get
  case s.ws of
    Nothing -> pure unit
    Just ws -> H.liftEffect $
      WsClient.send ws (stringify (CA.encode clientMsgCodec msg))

-- | Does the remote snapshot differ from what the frontend is
-- | currently showing? Compares input state (module, cells, runtime)
-- | and error count, so a server recompile that only clears a stale
-- | diagnostic still flushes the frontend's banner.
-- |
-- | With server-side conch exclusion the holder never receives their
-- | own echoed snapshots, so this is purely a defensive no-op check —
-- | avoids the edge case where a reconnect or server bug delivers a
-- | broadcast that matches local state exactly.
remoteDiffers
  :: forall r
   . State
  -> { "module" :: UserModule
     , cells :: Array Cell
     , runtime :: String
     , errors :: Array CompileError
     | r }
  -> Boolean
remoteDiffers s r =
  let UserModule rm = r."module"
      sameModule = rm.source == s.moduleSource
      sameRuntime = r.runtime == s.runtime
      sameCells = cellsMatch s.cells r.cells
      sameErrors = Array.length r.errors == Array.length s.errors
  in not (sameModule && sameRuntime && sameCells && sameErrors)
  where
  cellsMatch local remote =
    Array.length local == Array.length remote
      && Array.all identity
           (Array.zipWith cellEq local remote)
  cellEq local (Cell remote) =
    local.id == remote.id
      && local.kind == remote.kind
      && local.source == remote.source

-- | Take a remote snapshot and overwrite local display state with it.
-- | Mirrors the emits-vs-js branching in `Compile`: server-side
-- | runtimes (node/purerl) arrive with `emits` populated, browser
-- | runtime arrives with `js` and we have to execute it in a Worker
-- | to get values. Without the Worker branch, the RHS column stays
-- | blank when a remote write from another client lands under the
-- | browser runtime.
applyRemote
  :: forall o m
   . MonadAff m
  => { js :: Maybe String
     , "module" :: UserModule
     , cells :: Array Cell
     , runtime :: String
     , types :: Array CellType
     , cellLines :: Array CellRange
     , errors :: Array CompileError
     , warnings :: Array CompileError
     , emits :: Array CellEmit
     }
  -> H.HalogenM State Action Slots o m Unit
applyRemote r = do
  let UserModule rm = r."module"
      typesMap = Map.fromFoldable
        ( map (\(CellType ct) -> Tuple ct.id ct.signature) r.types )
      cellRecs = map (\(Cell c) -> { id: c.id, kind: c.kind, source: c.source, form: c.form }) r.cells
      resultsMap = Map.fromFoldable
        ( map (\(CellEmit e) -> Tuple e.id (Value.parse e.value)) r.emits )
      syncedCells = Map.fromFoldable
        ( map (\(Cell c) -> Tuple c.id { source: c.source, kind: c.kind }) r.cells )
  H.modify_ _
    { moduleSource = rm.source
    , cells = cellRecs
    , runtime = r.runtime
    , cellTypes = typesMap
    , cellResults = resultsMap
    , cellRanges = r.cellLines
    , errors = r.errors
    , warnings = r.warnings
    , lastSyncedModule = rm.source
    , lastSyncedCells = syncedCells
    , lastSyncedRuntime = r.runtime
    }
  decorateErrors r.errors r.cellLines
  if not (Array.null r.emits) then
    teardownExecution
  else case r.js of
    Nothing -> teardownExecution
    Just js -> startExecution js

-- | Push inline error decorations to each editor. `errs` are the
-- | raw CompileErrors from the response; we partition by filename
-- | (Playground/User.purs → module, Main.purs → cells, via
-- | `cellRanges`) and tell each editor slot its per-editor spans.
-- | Editors that have no errors still get told `[]` so stale
-- | squiggles from a previous compile go away.
decorateErrors
  :: forall o m
   . MonadAff m
  => Array CompileError
  -> Array CellRange
  -> H.HalogenM State Action Slots o m Unit
decorateErrors errs cellRanges = do
  s <- H.get
  let partition = partitionErrorsByEditor errs cellRanges
  H.tell _moduleEditor unit (Editor.SetErrors partition.moduleSpans)
  for_ s.cells \c -> do
    let spans = fromMaybe [] (Map.lookup c.id partition.cellSpans)
    H.tell _cellEditor c.id (Editor.SetErrors spans)

type ErrorPartition =
  { moduleSpans :: Array ErrorSpan
  , cellSpans :: Map String (Array ErrorSpan)
  }

partitionErrorsByEditor
  :: Array CompileError
  -> Array CellRange
  -> ErrorPartition
partitionErrorsByEditor errs cellRanges =
  Array.foldl classify { moduleSpans: [], cellSpans: Map.empty } errs
  where
  classify acc (CompileError e) = case e.position, e.filename of
    Just (Position p), Just file
      | endsWith "Playground/User.purs" file ->
          acc
            { moduleSpans =
                Array.snoc acc.moduleSpans
                  (makeSpan p.startLine p.startColumn p.endLine p.endColumn e.message)
            }
      | endsWith "Main.purs" file ->
          case findCellAt cellRanges p.startLine of
            Nothing -> acc
            Just (CellRange cr) ->
              let
                span =
                  makeSpan
                    (p.startLine - cr.startLine + 1)
                    p.startColumn
                    (p.endLine - cr.startLine + 1)
                    p.endColumn
                    e.message
                existing = fromMaybe [] (Map.lookup cr.id acc.cellSpans)
              in
                acc { cellSpans = Map.insert cr.id (Array.snoc existing span) acc.cellSpans }
    _, _ -> acc
  makeSpan sl sc el ec msg =
    { startLine: sl, startColumn: sc, endLine: el, endColumn: ec, message: msg }
  findCellAt ranges line =
    Array.find (\(CellRange cr) -> line >= cr.startLine && line <= cr.endLine) ranges
  endsWith suffix str =
    case Str.length str - Str.length suffix of
      n | n >= 0 ->
          Str.take (Str.length suffix) (Str.drop n str) == suffix
      _ -> false

-- | Tears down any live worker, its subscription, and its timeout fiber.
teardownExecution
  :: forall o m
   . MonadAff m
  => H.HalogenM State Action Slots o m Unit
teardownExecution = do
  s <- H.get
  case s.worker of
    Just w -> H.liftEffect (Worker.terminate w)
    Nothing -> pure unit
  case s.workerSub of
    Just sid -> H.unsubscribe sid
    Nothing -> pure unit
  case s.workerTimeout of
    Just fid -> H.kill fid
    Nothing -> pure unit
  H.modify_ _
    { worker = Nothing
    , workerSub = Nothing
    , workerTimeout = Nothing
    }

-- | Tears down any previous run, then spawns a fresh worker, posts the
-- | bundle JS, subscribes to worker messages, and schedules a timeout.
startExecution
  :: forall o m
   . MonadAff m
  => String
  -> H.HalogenM State Action Slots o m Unit
startExecution js = do
  teardownExecution
  H.modify_ _ { cellResults = Map.empty }
  { emitter, listener } <- H.liftEffect HS.create
  subId <- H.subscribe (HandleWorkerMessage <$> emitter)
  worker <- H.liftEffect $ Worker.spawnWorker (HS.notify listener)
  H.liftEffect $ Worker.postJs worker js
  timeoutId <- H.fork do
    H.liftAff (delay workerTimeoutMs)
    handleAction WorkerTimeout
  H.modify_ _
    { worker = Just worker
    , workerSub = Just subId
    , workerTimeout = Just timeoutId
    }

render :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
render state =
  HH.div
    [ HP.class_
        ( H.ClassName
            ( "playground-shell"
                <> (if state.compiling then " is-compiling" else "")
            )
        )
    ]
    [ renderHeader state
    , renderConchBanner state
    , if state.settingsOpen then renderSettingsPanel state else HH.text ""
    , HH.main
        [ HP.class_ (H.ClassName "columns")
        , HP.style ("grid-template-columns: " <> gridTemplateForVisibility state.visibility)
        ]
        ( (if state.visibility.showModule then [ renderModuleColumn state ] else [])
            <> (if state.visibility.showCells then [ renderCellsColumn state ] else [])
            <> (if state.visibility.showGutter then [ renderGutterColumn state ] else [])
            <> (if state.visibility.showRender then [ renderRenderColumn state ] else [])
        )
    , renderErrorPanel state
    ]

-- | Transient banner shown when the server rejected an HTTP write with
-- | 409 (conch held by someone else). Dismissable; also clears the next
-- | time the user successfully writes.
renderConchBanner :: forall m. State -> H.ComponentHTML Action Slots m
renderConchBanner state = case state.conchBanner of
  Nothing -> HH.text ""
  Just msg ->
    HH.div [ HP.class_ (H.ClassName "conch-banner") ]
      [ HH.text msg
      , HH.button
          [ HP.class_ (H.ClassName "conch-banner-dismiss")
          , HE.onClick \_ -> DismissConchBanner
          ]
          [ HH.text "×" ]
      ]

-- | Milliseconds since the current holder last touched the conch.
-- | Returns 0 when nobody holds. Used to decide whether a Force is
-- | permitted from the UI.
stateIdleMsFor :: State -> Number
stateIdleMsFor state = case state.conch.holder of
  Nothing -> 0.0
  Just _ -> state.conch.lastActivityAt  -- TODO: subtract `now` once we
                                         -- bind it per-render. For v1 this
                                         -- is a coarse overestimate — Force
                                         -- still works, the UI just shows
                                         -- "forceable" slightly eagerly.

-- | Revealed by the gear icon. Replaces the old standalone In Scope
-- | panel and absorbs the former header-bar tagline + runtime picker.
-- | The runtime sub-section also drives what the "in scope" lists show.
renderSettingsPanel :: forall m. State -> H.ComponentHTML Action Slots m
renderSettingsPanel state =
  let sc = InScope.forRuntime state.runtime
  in HH.section [ HP.class_ (H.ClassName "settings-panel") ]
    [ HH.p [ HP.class_ (H.ClassName "settings-tagline") ]
        [ HH.text
            "A REPL for agents, with a window for humans. Auto-compiles 400ms after you stop typing."
        ]
    , HH.div [ HP.class_ (H.ClassName "settings-section") ]
        [ HH.h3_ [ HH.text "Runtime" ]
        , HH.div [ HP.class_ (H.ClassName "runtime-toggle") ]
            [ runtimeButton state "browser" "Browser"
            , runtimeButton state "node" "Node"
            , runtimeButton state "purerl" "Purerl"
            ]
        ]
    , HH.div [ HP.class_ (H.ClassName "settings-section") ]
        [ HH.h3_
            [ HH.text "In scope — "
            , HH.span [ HP.class_ (H.ClassName "runtime-label") ]
                [ HH.text sc.runtimeLabel ]
            ]
        , HH.div [ HP.class_ (H.ClassName "in-scope-grid") ]
            [ renderList "Auto-imported (cells see these)" sc.autoImports
            , renderList "Highlighted packages" sc.highlightedPackages
            ]
        , if Array.null sc.notes then HH.text ""
          else HH.ul [ HP.class_ (H.ClassName "in-scope-notes") ]
            (map (\n -> HH.li_ [ HH.text n ]) sc.notes)
        ]
    ]
  where
  renderList title items =
    HH.div [ HP.class_ (H.ClassName "in-scope-section") ]
      [ HH.h4_ [ HH.text title ]
      , HH.ul_ (map (\x -> HH.li_ [ HH.text x ]) items)
      ]

renderHeader :: forall m. State -> H.ComponentHTML Action Slots m
renderHeader state =
  HH.header [ HP.class_ (H.ClassName "playground-header") ]
    [ HH.button
        [ HP.class_
            ( H.ClassName
                ( "settings-btn"
                    <> (if state.settingsOpen then " active" else "")
                )
            )
        , HP.title
            ( if state.settingsOpen
                then "Close settings"
                else "Runtime, in-scope, about"
            )
        , HE.onClick \_ -> ToggleSettings
        ]
        [ HH.text "⚙" ]
    , renderTitleConch state
    , renderViewToggle state
    , HH.div [ HP.class_ (H.ClassName "header-spacer") ] []
    , renderStarterDropdown state
    , HH.div [ HP.class_ (H.ClassName "header-spacer") ] []
    ]

-- | The title doubles as the conch button. Clicking "Atelier" takes /
-- | yields / requests the conch; the word beneath reflects the current
-- | state (replaces the old tagline, which now lives in the settings
-- | panel).
renderTitleConch :: forall m. State -> H.ComponentHTML Action Slots m
renderTitleConch state =
  let iHold = iHoldConch state
      nobodyHolds = case state.conch.holder of
        Nothing -> true
        Just _ -> false
      somebodyElseHolds = (not iHold) && (not nobodyHolds)
      idleMs = stateIdleMsFor state
      forceable = somebodyElseHolds && idleMs > 60000.0
      requesting = state.requestingConch && (not iHold)
      status
        | iHold = "You hold the pen"
        | requesting = "Requesting…"
        | nobodyHolds = "Unclaimed"
        | forceable = "Held (idle — force?)"
        | otherwise = "Observing"
      stateCls
        | iHold = "conch-holding"
        | requesting = "conch-requesting"
        | nobodyHolds = "conch-unclaimed"
        | otherwise = "conch-observing"
      title
        | iHold = "You hold the conch. Click to yield."
        | nobodyHolds = "Nobody holds the conch. Click to take it."
        | forceable = "Holder has been idle >60s. Click to force-take."
        | otherwise = "Another viewer holds the conch. Click to request it."
      action
        | iHold = YieldConchAction
        | forceable = ForceConchAction
        | otherwise = RequestConchAction
  in HH.button
       [ HP.class_ (H.ClassName ("title-conch " <> stateCls))
       , HP.title title
       , HE.onClick \_ -> action
       ]
       [ HH.span [ HP.class_ (H.ClassName "title-conch-name") ]
           [ HH.text "Atelier" ]
       , HH.span [ HP.class_ (H.ClassName "title-conch-status") ]
           [ HH.text status ]
       ]

-- | Toggle strip for column visibility. Each button is pressed when
-- | its column is visible; clicking flips that column and the URL's
-- | `?hide=` param follows.
renderViewToggle :: forall m. State -> H.ComponentHTML Action Slots m
renderViewToggle state =
  HH.div [ HP.class_ (H.ClassName "view-toggle") ]
    ( map (viewToggleButton state) [ KeyModule, KeyCells, KeyGutter, KeyRender ] )

viewToggleButton :: forall m. State -> ColumnKey -> H.ComponentHTML Action Slots m
viewToggleButton state key =
  let on = isVisible key state.visibility
      cls = "view-toggle-btn" <> (if on then " active" else "")
      tip =
        if on
          then "Hide the " <> columnKeyLabel key <> " column"
          else "Show the " <> columnKeyLabel key <> " column"
  in HH.button
       [ HP.class_ (H.ClassName cls)
       , HP.title tip
       , HE.onClick \_ -> ToggleColumn key
       ]
       [ HH.text (columnKeyLabel key) ]

renderStarterDropdown :: forall m. State -> H.ComponentHTML Action Slots m
renderStarterDropdown state =
  HH.div [ HP.class_ (H.ClassName "starter-dropdown") ]
    [ HH.button
        [ HP.class_ (H.ClassName "starter-btn")
        , HE.onClick \_ -> ToggleStarterMenu
        ]
        [ HH.text (currentLabel <> " ▾") ]
    , if state.starterMenuOpen
        then HH.div [ HP.class_ (H.ClassName "starter-menu") ]
          (map (renderStarterOption state) starters)
        else HH.text ""
    ]
  where
  currentLabel = case Starter.findByKey state.starterKey of
    Just s -> s.label
    Nothing -> "Starter ▾"

renderStarterOption :: forall m. State -> Starter -> H.ComponentHTML Action Slots m
renderStarterOption state s =
  HH.button
    [ HP.class_
        ( H.ClassName
            ( "starter-option"
                <> (if state.starterKey == s.key then " current" else "")
            )
        )
    , HE.onClick \_ -> LoadStarter s.key
    ]
    [ HH.div [ HP.class_ (H.ClassName "starter-label") ] [ HH.text s.label ]
    , HH.div [ HP.class_ (H.ClassName "starter-desc") ] [ HH.text s.description ]
    , HH.div [ HP.class_ (H.ClassName "starter-compat") ]
        [ compatBadge state.runtime "browser" s.compat.browser
        , compatBadge state.runtime "node" s.compat.node
        , compatBadge state.runtime "purerl" s.compat.purerl
        ]
    ]

compatBadge
  :: forall m
   . String
  -> String
  -> Boolean
  -> H.ComponentHTML Action Slots m
compatBadge currentRuntime label ok =
  HH.span
    [ HP.class_
        ( H.ClassName
            ( "compat-badge compat-"
                <> (if ok then "yes" else "no")
                <> (if currentRuntime == label then " compat-current" else "")
            )
        )
    ]
    [ HH.text ((if ok then "✓ " else "✗ ") <> label) ]

runtimeButton :: forall m. State -> String -> String -> H.ComponentHTML Action Slots m
runtimeButton state value label =
  HH.button
    [ HP.class_
        ( H.ClassName
            ( "runtime-btn"
                <> (if state.runtime == value then " runtime-active" else "")
            )
        )
    , HE.onClick \_ -> SetRuntime value
    ]
    [ HH.text label ]

renderModuleColumn :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderModuleColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-module") ]
    [ HH.slot _moduleEditor unit Editor.component
        { initialDoc: state.moduleSource, tag: "module" }
        (\(Editor.Changed src) -> ModuleChanged src)
    ]

renderCellsColumn :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderCellsColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-cells") ]
    ( mapWithIndex (renderCellRow state) state.cells
        <>
          [ HH.button
              [ HP.class_ (H.ClassName "add-cell-btn")
              , HE.onClick \_ -> AddCell
              ]
              [ HH.text "+ add cell" ]
          ]
    )

-- | Position-based color class (cycles every 8 cells). The same
-- | class is also applied to the matching gutter row, so a cell and
-- | its value/type entry visibly share an accent across the page.
cellColorClass :: Int -> String
cellColorClass idx = "cell-color-" <> show (idx `mod` 8)

renderCellRow :: forall m. MonadAff m => State -> Int -> CellRec -> H.ComponentHTML Action Slots m
renderCellRow state idx c =
  let formSpecs = do
        sig <- Map.lookup c.id state.cellTypes
        analyseType sig
      formEligible = case formSpecs of
        Just _ -> true
        Nothing -> false
      showAsForm = c.form && formEligible
      bodyHtml = case Tuple showAsForm formSpecs of
        Tuple true (Just specs) -> renderCellForm c specs
        _ ->
          HH.slot _cellEditor c.id Editor.component
            { initialDoc: c.source, tag: "cell" }
            (\(Editor.Changed src) -> CellChanged c.id src)
  in HH.div
       [ HP.class_
           ( H.ClassName
               ( "cell-row "
                   <> cellColorClass idx
                   <> (if c.kind == "let" then " cell-row-let" else " cell-row-expr")
                   <> (if showAsForm then " cell-row-form" else "")
               )
           )
       ]
       [ HH.div [ HP.class_ (H.ClassName "cell-meta") ]
           ( [ HH.span [ HP.class_ (H.ClassName "cell-id") ] [ HH.text c.id ]
             , HH.button
                 [ HP.class_ (H.ClassName ("cell-kind-btn cell-kind-" <> c.kind))
                 , HE.onClick \_ -> ToggleCellKind c.id
                 , HP.title
                     ( if c.kind == "let"
                         then "let-cell (splices verbatim; no gutter output). Click to switch to expr."
                         else "expr-cell (evaluated; shown in gutter). Click to switch to let."
                     )
                 ]
                 [ HH.text c.kind ]
             ]
               <>
                 ( if formEligible
                     then
                       [ HH.button
                           [ HP.class_
                               ( H.ClassName
                                   ( "cell-form-btn"
                                       <> (if c.form then " cell-form-on" else "")
                                   )
                               )
                           , HE.onClick \_ -> ToggleCellForm c.id
                           , HP.title
                               ( if c.form
                                   then "Form view active. Click to switch back to code."
                                   else "Type is form-compatible. Click to edit as a form."
                               )
                           ]
                           [ HH.text "⊞" ]
                       ]
                     else []
                 )
               <>
                 [ HH.button
                     [ HP.class_ (H.ClassName "remove-cell-btn")
                     , HE.onClick \_ -> RemoveCell c.id
                     , HP.title "Remove cell"
                     ]
                     [ HH.text "×" ]
                 ]
           )
       , bodyHtml
       ]

-- | Render a record-of-primitives cell as a form. Each field gets a
-- | typed input; on input we regenerate the full source as a canonical
-- | record literal and PATCH it through. Existing values are read out
-- | of the cell's current source (a record literal) when present;
-- | otherwise the form shows defaults.
renderCellForm :: forall m. MonadAff m => CellRec -> Array FieldSpec -> H.ComponentHTML Action Slots m
renderCellForm c specs =
  HH.div [ HP.class_ (H.ClassName "cell-form") ]
    ( map (renderFormField c existing) specs )
  where
  existing = case parseRecordLiteral c.source of
    Just pairs -> Map.fromFoldable pairs
    Nothing -> Map.empty

renderFormField
  :: forall m
   . MonadAff m
  => CellRec
  -> Map String String
  -> FieldSpec
  -> H.ComponentHTML Action Slots m
renderFormField c existing spec =
  let raw = case Map.lookup spec.name existing of
        Just v -> stripStringQuotes v
        Nothing -> ""
  in HH.label [ HP.class_ (H.ClassName "cell-form-field") ]
       [ HH.span [ HP.class_ (H.ClassName "cell-form-label") ]
           [ HH.text spec.name ]
       , inputForKind c spec raw
       ]

inputForKind
  :: forall m
   . MonadAff m
  => CellRec
  -> FieldSpec
  -> String
  -> H.ComponentHTML Action Slots m
inputForKind c spec raw = case spec.kind of
  FBoolean ->
    HH.input
      [ HP.type_ HP.InputCheckbox
      , HP.class_ (H.ClassName "cell-form-input cell-form-input-bool")
      , HP.checked (raw == "true")
      , HE.onChecked \b -> CellFormFieldChanged c.id spec.name (if b then "true" else "false")
      ]
  FString ->
    HH.input
      [ HP.type_ HP.InputText
      , HP.class_ (H.ClassName "cell-form-input cell-form-input-string")
      , HP.value raw
      , HE.onValueInput (\v -> CellFormFieldChanged c.id spec.name v)
      ]
  _ ->
    HH.input
      [ HP.type_ HP.InputNumber
      , HP.class_ (H.ClassName "cell-form-input cell-form-input-number")
      , HP.value raw
      , HE.onValueInput (\v -> CellFormFieldChanged c.id spec.name v)
      ]

-- | When seeding the form input from the source's parsed value, strip
-- | enclosing quotes so a String field renders as `hello`, not `"hello"`.
stripStringQuotes :: String -> String
stripStringQuotes s = case Str.stripPrefix (Pattern "\"") s of
  Nothing -> s
  Just rest -> case Str.stripSuffix (Pattern "\"") rest of
    Nothing -> s
    Just inner -> inner

-- | Gutter always shows the last-known values + types. On a failed
-- | compile the previous values stay put; errors are surfaced in the
-- | bottom panel. While a new compile is pending, CSS fades this column.
renderGutterColumn :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderGutterColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-gutter") ]
    [ renderResults state ]

renderResults :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderResults state =
  HH.div [ HP.class_ (H.ClassName "gutter-rows") ]
    ( Array.catMaybes (mapWithIndex maybeRow state.cells)
        <> renderRuntimeError state.runtimeError
    )
  where
  -- Preserve the original cell index for colour consistency; just
  -- drop let-cells from the gutter so it only shows evaluated values.
  maybeRow idx c =
    if c.kind == "expr" then Just (renderCellResult state idx c) else Nothing

renderCellResult :: forall m. MonadAff m => State -> Int -> CellRec -> H.ComponentHTML Action Slots m
renderCellResult state idx c =
  HH.div [ HP.class_ (H.ClassName ("gutter-row " <> cellColorClass idx)) ]
    [ HH.span [ HP.class_ (H.ClassName "gutter-cell-id") ] [ HH.text c.id ]
    , HH.div [ HP.class_ (H.ClassName "gutter-body") ]
        [ renderType state c
        , renderValue state c
        ]
    ]
  where
  renderType st cell = case Map.lookup cell.id st.cellTypes of
    Just sig ->
      HH.div [ HP.class_ (H.ClassName "gutter-type") ]
        [ HH.slot_ _sigil cell.id SigilView.component { typeString: sig } ]
    Nothing ->
      HH.span [ HP.class_ (H.ClassName "muted gutter-type") ] [ HH.text "—" ]
  renderValue st cell = case Map.lookup cell.id st.cellResults of
    Just v ->
      HH.div [ HP.class_ (H.ClassName "gutter-value") ]
        [ ValueView.render v ]
    Nothing ->
      HH.span [ HP.class_ (H.ClassName "muted") ] [ HH.text "—" ]

renderRuntimeError :: forall m. Maybe String -> Array (H.ComponentHTML Action Slots m)
renderRuntimeError = case _ of
  Nothing -> []
  Just err ->
    [ HH.pre [ HP.class_ (H.ClassName "runtime-error") ]
        [ HH.text ("runtime: " <> err) ]
    ]

-- | Fourth column: imperatively-mounted visual renderings of cell values.
-- | Dispatches per emit shape in the FFI (RenderView.js): SVG strings go
-- | through innerHTML, `ForceRender` values drive a d3-force simulation,
-- | anything else stays blank. Row-per-expr-cell to align with the cells
-- | column; empty rows kept so vertical alignment is preserved.
renderRenderColumn :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderRenderColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-render") ]
    [ HH.div [ HP.class_ (H.ClassName "render-rows") ]
        (Array.catMaybes (mapWithIndex maybeRow state.cells))
    ]
  where
  maybeRow idx c =
    if c.kind == "expr" then Just (renderCellVisual state idx c) else Nothing

renderCellVisual :: forall m. MonadAff m => State -> Int -> CellRec -> H.ComponentHTML Action Slots m
renderCellVisual state idx c =
  HH.div [ HP.class_ (H.ClassName ("render-row " <> cellColorClass idx)) ]
    [ HH.slot_ _render c.id RenderView.component { json: cellJson } ]
  where
  cellJson = case Map.lookup c.id state.cellResults of
    Just v -> Value.encode v
    Nothing -> ""

-- | Bottom panel: absent when clean. Each structured compile error is
-- | attributed to an originating surface (cell <id>, module, or just
-- | "runtime") and rendered with an error code + message.
renderErrorPanel :: forall m. State -> H.ComponentHTML Action Slots m
renderErrorPanel state =
  let
    transportRow = case state.transportError of
      Just err ->
        [ row { kind: "transport", target: "network", message: err, code: "" } ]
      Nothing -> []
    compileRows = map (attributedRow state "compile") state.errors
    warningRows = map (attributedRow state "warning") state.warnings
    rows = transportRow <> compileRows <> warningRows
  in
    case rows of
      [] -> HH.text ""
      _ ->
        HH.section [ HP.class_ (H.ClassName "error-panel") ]
          ( [ HH.h2_ [ HH.text "Errors" ] ] <> rows )
  where
  row r =
    HH.div
      [ HP.class_ (H.ClassName ("error-row error-" <> r.kind)) ]
      [ HH.div [ HP.class_ (H.ClassName "error-head") ]
          [ HH.span [ HP.class_ (H.ClassName "error-kind") ] [ HH.text r.kind ]
          , HH.span [ HP.class_ (H.ClassName "error-target") ] [ HH.text r.target ]
          , if r.code == "" then HH.text ""
            else HH.span [ HP.class_ (H.ClassName "error-code") ] [ HH.text r.code ]
          ]
      , HH.pre [ HP.class_ (H.ClassName "error-msg") ] [ HH.text r.message ]
      ]

attributedRow
  :: forall m
   . State
  -> String
  -> CompileError
  -> H.ComponentHTML Action Slots m
attributedRow state kind (CompileError e) =
  HH.div
    [ HP.class_ (H.ClassName ("error-row error-" <> kind)) ]
    [ HH.div [ HP.class_ (H.ClassName "error-head") ]
        [ HH.span [ HP.class_ (H.ClassName "error-kind") ] [ HH.text kind ]
        , HH.span [ HP.class_ (H.ClassName "error-target") ]
            [ HH.text (attribute state e) ]
        , HH.span [ HP.class_ (H.ClassName "error-code") ] [ HH.text e.code ]
        ]
    , HH.pre [ HP.class_ (H.ClassName "error-msg") ] [ HH.text e.message ]
    ]

-- | Given an error's filename + position, produce a human-readable
-- | "target" string: "cell c2 ▸ line 3" if it falls in a cell's range in
-- | Main.purs; "module ▸ line 5" if it's in Playground/User.purs;
-- | "runtime" otherwise (our own Transport errors, synthesis lines
-- | outside any cell).
attribute
  :: State
  -> { code :: String
     , filename :: Maybe String
     , position :: Maybe Position
     , message :: String
     }
  -> String
attribute state e =
  case e.filename, e.position of
    Just file, Just (Position p) ->
      if endsWith "Playground/User.purs" file then
        "module ▸ line " <> show p.startLine
      else if endsWith "Main.purs" file then
        case findCellAt state.cellRanges p.startLine of
          Just (CellRange cr) ->
            "cell " <> cr.id
              <> " ▸ line "
              <> show (p.startLine - cr.startLine + 1)
          Nothing -> "synthesis ▸ Main.purs line " <> show p.startLine
      else file
    _, _ -> "—"
  where
  findCellAt ranges line =
    Array.find (\(CellRange cr) -> line >= cr.startLine && line <= cr.endLine) ranges
  endsWith suffix s =
    case Str.length s - Str.length suffix of
      n | n >= 0 ->
          Str.take (Str.length suffix) (Str.drop n s) == suffix
      _ -> false
