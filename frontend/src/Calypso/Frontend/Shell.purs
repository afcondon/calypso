module Calypso.Frontend.Shell where

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
import Data.Int as Int
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

import Data.Foldable (for_, foldr)

import Calypso.Frontend.CodeMirror (ErrorSpan)
import Calypso.Frontend.Config (backendUrl, readHideParam, writeHideParam, wsBackendUrl)
import Calypso.Frontend.Completion (Completion, completionsFromVocabulary)
import Calypso.Frontend.Editor as Editor
import Calypso.Frontend.Favorite as Favorite
import Calypso.Frontend.Primer as Primer
import Calypso.Frontend.Vocabulary as Vocabulary
import Calypso.Frontend.WsClient as WsClient
import Calypso.Favorite (Favorite(..))
import Calypso.Vocabulary as CV
import Calypso.Vocabulary (Vocabulary)
import Calypso.Proposal
  ( Hunk(..)
  , Proposal(..)
  , ProposalId(..)
  , ProposalTarget(..)
  , unProposalId
  )
import Calypso.Pen
  ( Broadcast(..)
  , ClientMsg(..)
  , PenHeldBody
  , PenState
  , SubscriberId
  , broadcastCodec
  , clientMsgCodec
  , penHeldBodyCodec
  , unSubscriberId
  )
import Calypso.Session
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

-- | Local cell shape. Mirrors the wire `Cell` minus the `form` field
-- | (carried as `false` on the wire for back-compat until the wire shape
-- | is trimmed in the deferred housekeeping pass).
type CellRec = { id :: String, kind :: String, source :: String }

cellRecOf :: Cell -> CellRec
cellRecOf (Cell c) = { id: c.id, kind: c.kind, source: c.source }

cellOf :: CellRec -> Cell
cellOf c = Cell { id: c.id, kind: c.kind, source: c.source, form: false }

-- | Which of the three main columns are visible in this tab. Each flag
-- | maps 1:1 to a rendered `pane-*` column. Persisted in the URL as
-- | `?hide=composition,cells,hylograph` (omitted when everything shows).
-- |
-- | The composition pane shows the durable `.tidal` module — between
-- | config and score; the cells pane runs live expressions; the
-- | hylograph pane will eventually visualise patterns (currently shows
-- | the latest reply text per cell).
data ColumnKey = KeyComposition | KeyCells | KeyHylograph

derive instance Eq ColumnKey

-- | Which tab is active inside the Hylograph (third) pane.  Until
-- | the pattern visualiser lands, this pane doubles as the
-- | reference panel: a browsable index of devices/bindings parsed
-- | from the purerl-tidal setup files (`Vocabulary`), a primer for
-- | mini-notation operators (`MiniNotation`), and the existing
-- | per-cell daemon-reply readout (`Replies`).
data HylographTab = TabVocabulary | TabMiniNotation | TabReplies

derive instance Eq HylographTab

hylographTabLabel :: HylographTab -> String
hylographTabLabel = case _ of
  TabVocabulary -> "Vocabulary"
  TabMiniNotation -> "Mini-notation"
  TabReplies -> "Replies"

allHylographTabs :: Array HylographTab
allHylographTabs = [ TabVocabulary, TabMiniNotation, TabReplies ]

type ColumnVisibility =
  { showComposition :: Boolean
  , showCells :: Boolean
  , showHylograph :: Boolean
  }

allVisible :: ColumnVisibility
allVisible =
  { showComposition: true, showCells: true, showHylograph: true }

isVisible :: ColumnKey -> ColumnVisibility -> Boolean
isVisible = case _ of
  KeyComposition -> _.showComposition
  KeyCells -> _.showCells
  KeyHylograph -> _.showHylograph

toggleKey :: ColumnKey -> ColumnVisibility -> ColumnVisibility
toggleKey k v = case k of
  KeyComposition -> v { showComposition = not v.showComposition }
  KeyCells -> v { showCells = not v.showCells }
  KeyHylograph -> v { showHylograph = not v.showHylograph }

columnKeyLabel :: ColumnKey -> String
columnKeyLabel = case _ of
  KeyComposition -> "Composition"
  KeyCells -> "Cells"
  KeyHylograph -> "Hylograph"

columnKeyToken :: ColumnKey -> String
columnKeyToken = case _ of
  KeyComposition -> "composition"
  KeyCells -> "cells"
  KeyHylograph -> "hylograph"

-- | Decode `?hide=` value. Unknown tokens are ignored; "module"/"values"/
-- | "render" are accepted as legacy aliases for backward compatibility
-- | with shared URLs from the Atelier era.
visibilityFromHide :: String -> ColumnVisibility
visibilityFromHide hide =
  let tokens = if hide == "" then [] else Str.split (Pattern ",") hide
      has t = Array.any (_ == t) tokens
  in
    { showComposition: not (has "composition" || has "module")
    , showCells: not (has "cells")
    , showHylograph: not (has "hylograph" || has "render" || has "values" || has "gutter")
    }

hideFromVisibility :: ColumnVisibility -> String
hideFromVisibility v =
  let hidden = Array.catMaybes
        [ if v.showComposition then Nothing else Just (columnKeyToken KeyComposition)
        , if v.showCells then Nothing else Just (columnKeyToken KeyCells)
        , if v.showHylograph then Nothing else Just (columnKeyToken KeyHylograph)
        ]
  in Str.joinWith "," hidden

-- | Grid-template-columns string for the visible panes.  Equal-share
-- | columns: 50/50 with two visible, 33/33/33 with three.  Long
-- | proposal hunks fit by horizontal-scrolling within their pane,
-- | not by stretching the column.
gridTemplateForVisibility :: ColumnVisibility -> String
gridTemplateForVisibility v =
  let parts = Array.catMaybes
        [ if v.showComposition then Just "1fr" else Nothing
        , if v.showCells then Just "1fr" else Nothing
        , if v.showHylograph then Just "1fr" else Nothing
        ]
  in case Array.length parts of
       0 -> "1fr"
       1 -> "1fr"
       _ -> Str.joinWith " " parts

type State =
  { moduleSource :: String
  , cells :: Array CellRec
  , nextCellId :: Int
  , runtime :: String             -- carried for wire-shape compat; "purerl-tidal-ws"
  , favorites :: Array Favorite
  , favoriteKey :: Maybe String   -- last-loaded favorite, if any
  , favoriteMenuOpen :: Boolean
  -- Vocabulary parsed from purerl-tidal/setup/*.tidal — drives
  -- autocomplete and (later) the reference panel.  Held both as the
  -- raw vocabulary record (for the panel) and as a flattened
  -- completion list (for the editor's autocompletion source).
  , vocabulary :: Vocabulary
  , completions :: Array Completion
  , hylographTab :: HylographTab
  , settingsOpen :: Boolean
  , compiling :: Boolean
  , errors :: Array CompileError
  , warnings :: Array CompileError
  , cellRanges :: Array CellRange
  , transportError :: Maybe String
  , runtimeError :: Maybe String
  -- Per-cell most-recent reply text from the daemon (e.g. "OK: hush" or
  -- "ERR: ...").  In a future pass this gains structure (parsed
  -- mini-notation AST + ok/err split) so the hylograph pane can render
  -- patterns; for now we just show the line.
  , cellResults :: Map String String
  -- Latest reply from firing the composition pane (Mod-Enter on the
  -- LHS).  Surfaced in the header so the human gets feedback that
  -- the daemon received the body without the reply line cluttering
  -- the composition itself.  Cleared on next fire.
  , compositionStatus :: Maybe String
  , cellTypes :: Map String String
  , pendingCompile :: Maybe H.ForkId
  -- Pen + WebSocket transport.  The Pen is the descendant of
  -- Atelier's Conch — same plumbing, retargeted from "exclusive
  -- writer" to "approver of incoming proposals" once that
  -- machinery exists.  Today the holder is still the only one who
  -- can mutate /session/* state.
  , myId :: Maybe SubscriberId
  , pen :: PenState
  , requestingPen :: Boolean
  , nextPenRetryAt :: Maybe Number
  , penBackoffMs :: Int
  , ws :: Maybe WsClient.WebSocket
  , wsSub :: Maybe H.SubscriptionId
  , penBanner :: Maybe String
  -- Pending edit proposals.  Populated by the Welcome WS frame and
  -- updated incrementally by ProposalAdded / ProposalUpdated /
  -- ProposalRetired.  Filtered per-target before being pushed down
  -- to each editor instance.
  , proposals :: Array Proposal
  , lastSyncedModule :: String
  , lastSyncedCells :: Map String { source :: String, kind :: String }
  , lastSyncedRuntime :: String
  , visibility :: ColumnVisibility
  }

type Slots =
  ( moduleEditor :: H.Slot Editor.Query Editor.Output Unit
  , cellEditor :: H.Slot Editor.Query Editor.Output String
  )

_moduleEditor :: Proxy "moduleEditor"
_moduleEditor = Proxy

_cellEditor :: Proxy "cellEditor"
_cellEditor = Proxy

data Action
  = Compile
  | ScheduleCompile
  | ModuleChanged String
  | CellChanged String String
  | AddCell
  | RemoveCell String
  | ToggleCellKind String
  | FireCell String String        -- cell id, current source
  | FireComposition String        -- current composition source
  | AcceptHunk ProposalId Int     -- POST /proposals/:id/hunks/:idx/accept
  | RejectHunk ProposalId Int     -- POST .../reject
  | ToggleFavoriteMenu
  | LoadFavorite String
  | FavoritesLoaded (Array Favorite)
  | VocabularyLoaded Vocabulary
  | SwitchHylographTab HylographTab
  | ToggleSettings
  | WsOpened
  | WsIncoming String
  | WsClosed Int String
  | WsErrored
  | RequestPenAction
  | YieldPenAction
  | ForcePenAction
  | DismissPenBanner
  | ToggleColumn ColumnKey
  | Startup

initialState :: forall i. i -> State
initialState _ =
  -- Empty pre-hydration; `Startup` calls `hydrateFromServer` which
  -- replaces module + cells with whatever the server has persisted.
  -- No more Atelier-shaped placeholder content.
  { moduleSource: ""
  , cells: []
  , nextCellId: 1
  , runtime: "purerl-tidal-ws"
  , favorites: []
  , favoriteKey: Nothing
  , favoriteMenuOpen: false
  , vocabulary: Vocabulary.emptyVocabulary
  , completions: []
  , hylographTab: TabVocabulary
  , settingsOpen: false
  , compiling: false
  , errors: []
  , warnings: []
  , cellRanges: []
  , transportError: Nothing
  , runtimeError: Nothing
  , cellResults: Map.empty
  , compositionStatus: Nothing
  , cellTypes: Map.empty
  , pendingCompile: Nothing
  , myId: Nothing
  , pen: { holder: Nothing, lastActivityAt: 0.0 }
  , requestingPen: false
  , nextPenRetryAt: Nothing
  , penBackoffMs: 250
  , ws: Nothing
  , wsSub: Nothing
  , penBanner: Nothing
  , proposals: []
  , lastSyncedModule: ""
  , lastSyncedCells: Map.empty
  , lastSyncedRuntime: ""
  , visibility: allVisible
  }

debounceMs :: Milliseconds
debounceMs = Milliseconds 400.0

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
    favs <- H.liftAff Favorite.fetchFavorites
    handleAction (FavoritesLoaded favs)
    vocab <- H.liftAff Vocabulary.fetchVocabulary
    handleAction (VocabularyLoaded vocab)
  FavoritesLoaded favs ->
    H.modify_ _ { favorites = favs }
  VocabularyLoaded vocab ->
    H.modify_ _
      { vocabulary = vocab
      , completions = completionsFromVocabulary vocab
      }
  SwitchHylographTab tab ->
    H.modify_ _ { hylographTab = tab }
  ModuleChanged src -> do
    H.modify_ _ { moduleSource = src }
    handleAction ScheduleCompile
  CellChanged id src -> do
    H.modify_ \s -> s { cells = updateCell id src s.cells }
    handleAction ScheduleCompile
  AddCell -> do
    H.modify_ \s ->
      let newId = "c" <> show s.nextCellId
          newCell = { id: newId, kind: "expr", source: "" }
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
      , cellResults = Map.delete id s.cellResults
      , cellTypes = Map.delete id s.cellTypes
      }
    handleAction ScheduleCompile
  FireCell cellId src -> do
    -- Tidal-style fire: Mod-Enter on a cell sends just that cell's
    -- text via /eval to the daemon.  The daemon's reply line lands
    -- in cellResults; errors land in transportError.
    result <- evalSource src
    case result of
      Left err -> H.modify_ _ { transportError = Just err }
      Right reply ->
        H.modify_ \s -> s { cellResults = Map.insert cellId reply s.cellResults }
  FireComposition src -> do
    -- Composition is "all or nothing" but the daemon parses one
    -- statement per /eval call, so we split by line, drop blanks and
    -- `--` comments (the directive comments aren't for the daemon),
    -- and fire each statement in sequence.  Stop on the first error
    -- and report which line failed.
    let stmts = compositionStatements src
    H.modify_ _ { compositionStatus = Nothing, transportError = Nothing }
    if Array.null stmts
      then H.modify_ _ { compositionStatus = Just "(no statements to fire)" }
      else fireStatements stmts
  AcceptHunk pid idx -> proposalAction "accept" pid idx
  RejectHunk pid idx -> proposalAction "reject" pid idx
  ToggleFavoriteMenu -> H.modify_ \s -> s { favoriteMenuOpen = not s.favoriteMenuOpen }
  LoadFavorite k -> do
    s0 <- H.get
    case Favorite.findByKey k s0.favorites of
      Nothing -> pure unit
      Just (Favorite fav) -> do
        -- A favorite carries only the composition body — cells are
        -- ephemeral and never bundled.  Slot the body into the
        -- module source and let ScheduleCompile push it through the
        -- granular /session/module endpoint.
        H.modify_ \s -> s
          { moduleSource = fav.body
          , favoriteKey = Just fav.key
          , favoriteMenuOpen = false
          }
        handleAction ScheduleCompile
  ToggleSettings -> H.modify_ \s -> s { settingsOpen = not s.settingsOpen }
  ToggleColumn key -> do
    H.modify_ \s -> s { visibility = toggleKey key s.visibility }
    s <- H.get
    H.liftEffect $ writeHideParam (hideFromVisibility s.visibility)
  WsOpened -> pure unit
  WsIncoming raw -> handleIncomingBroadcast raw
  WsClosed _ _ -> H.modify_ _ { ws = Nothing }
  WsErrored -> pure unit
  RequestPenAction -> do
    sendClientMsg RequestPen
    H.modify_ _ { requestingPen = true }
  YieldPenAction -> sendClientMsg YieldPen
  ForcePenAction -> do
    sendClientMsg ForcePen
    H.modify_ _ { requestingPen = true }
  DismissPenBanner -> H.modify_ _ { penBanner = Nothing }
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
    if needsFullCompile s
      then runFullCompile s
      else runGranularCompile s
  where
  updateCell id src cells =
    fromMaybe cells do
      idx <- findIndex (_.id >>> (_ == id)) cells
      modifyAt idx (_ { source = src }) cells
  flipKind = case _ of
    "let" -> "expr"
    _ -> "let"

needsFullCompile :: State -> Boolean
needsFullCompile s =
  s.runtime /= s.lastSyncedRuntime
    || Array.length s.cells /= Map.size s.lastSyncedCells
    || Array.any cellStructureDiverged s.cells
  where
  cellStructureDiverged c = case Map.lookup c.id s.lastSyncedCells of
    Nothing -> true
    Just last -> last.kind /= c.kind

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
        capped = min (oldLen - prefix) (newLen - prefix)
        suffix = lcsLines oldLines newLines capped
        startLine = prefix + 1
        endLine = oldLen - suffix
        newSlice = Array.slice prefix (newLen - suffix) newLines
        text = Str.joinWith "\n" newSlice
      in
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

runFullCompile
  :: forall o m
   . MonadAff m
  => State
  -> H.HalogenM State Action Slots o m Unit
runFullCompile s = do
  let
    req = CompileRequest
      { "module": UserModule { source: s.moduleSource }
      , cells: map cellOf s.cells
      , runtime: s.runtime
      }
    bodyJson = stringify (CA.encode compileRequestCodec req)
  result <- httpJson POST (backendUrl <> "/session/compile") bodyJson
  case result of
    Left err -> H.modify_ _
      { compiling = false, transportError = Just err }
    Right resp -> applyCompileResponse resp

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
    resultsMap = Map.fromFoldable
      ( map (\(CellEmit e) -> Tuple e.id e.value) r.emits )
  H.modify_ \s -> s
    { compiling = false
    , errors = r.errors
    , warnings = r.warnings
    , cellRanges = r.cellLines
    , cellTypes = typesMap
    -- Merge fresh results over old ones so untouched cells keep their
    -- last reply visible while a single edited cell updates.
    , cellResults = Map.union resultsMap s.cellResults
    , lastSyncedModule = rm.source
    , lastSyncedCells = syncedCells
    , lastSyncedRuntime = r.runtime
    }
  decorateErrors r.errors r.cellLines

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
        let banner = case CA.decode penHeldBodyCodec r.body of
              Left _ -> "Another viewer holds the pen."
              Right held -> penHeldMessage held
        H.modify_ _ { penBanner = Just banner, compiling = false }
        pure (Left ("pen-held: " <> banner))
      AX.StatusCode code
        | code >= 200 && code < 300 -> case CA.decode compileResponseCodec r.body of
            Left decodeErr -> pure (Left ("decode: " <> CA.printJsonDecodeError decodeErr))
            Right resp -> pure (Right resp)
        | otherwise -> pure (Left ("HTTP " <> show code))

penHeldMessage :: PenHeldBody -> String
penHeldMessage held = case held.holder of
  Nothing -> "Pen is unclaimed. Take it to write."
  Just _ -> "Another viewer holds the pen. Request it to write."

encodeJsonObject :: Array (Tuple String String) -> Json
encodeJsonObject pairs =
  AJ.fromObject (Object.fromFoldable (map encodeEntry pairs))
  where
  encodeEntry (Tuple k v) = Tuple k (AJ.fromString v)

-- | Split the composition body into fire-able statements.  Drops
-- | blank lines and `--`-prefixed comments (including the
-- | typographic-layer @-directives, which are for the renderer not
-- | the daemon).  Each entry carries its 1-based source-line number
-- | so error messages can point at the right line.
compositionStatements :: String -> Array { lineNum :: Int, source :: String }
compositionStatements src =
  let lines = Str.split (Pattern "\n") src
      indexed = mapWithIndex (\i s -> { lineNum: i + 1, source: s }) lines
      isCommentLine s =
        let trimmed = Str.trim s
        in Str.null trimmed || Str.take 2 trimmed == "--"
  in Array.filter (\e -> not (isCommentLine e.source)) indexed

-- | Fire a list of statements in order against /eval.  Stops on the
-- | first error and reports the failing line; on full success reports
-- | the count.  Status lands in `compositionStatus`.
fireStatements
  :: forall o m
   . MonadAff m
  => Array { lineNum :: Int, source :: String }
  -> H.HalogenM State Action Slots o m Unit
fireStatements = go 0
  where
  go fired remaining = case Array.uncons remaining of
    Nothing ->
      H.modify_ _
        { compositionStatus = Just ("OK: fired " <> show fired <> " statements") }
    Just { head: e, tail } -> do
      result <- evalSource e.source
      case result of
        Left err ->
          H.modify_ _
            { compositionStatus = Just
                ("ERR at line " <> show e.lineNum <> ": " <> err)
            }
        Right _reply -> go (fired + 1) tail

-- | POST `{source, imports: []}` to /eval.  Returns the daemon's
-- | reply line on success, a human transport error on failure.  The
-- | server's EvalResponse wraps the reply text as `value`; an
-- | error-shaped response surfaces in `errors[0].message`.
evalSource
  :: forall o m
   . MonadAff m
  => String
  -> H.HalogenM State Action Slots o m (Either String String)
evalSource src = do
  let body = stringify
        ( AJ.fromObject
            ( Object.singleton "source" (AJ.fromString src) )
        )
  result <- H.liftAff $ AX.request $ AX.defaultRequest
    { method = Left POST
    , url = backendUrl <> "/eval"
    , responseFormat = RF.json
    , content = Just (RB.string body)
    }
  pure case result of
    Left err -> Left (AX.printError err)
    Right r
      | r.status == AX.StatusCode 200 -> case AJ.toObject r.body of
          Nothing -> Left "eval: response not an object"
          Just o ->
            let valueText = case Object.lookup "value" o of
                  Just v -> AJ.toString v
                  Nothing -> Nothing
                errorText = do
                  errsJ <- Object.lookup "errors" o
                  errs <- AJ.toArray errsJ
                  first <- Array.head errs
                  firstO <- AJ.toObject first
                  msgJ <- Object.lookup "message" firstO
                  AJ.toString msgJ
            in case valueText, errorText of
                 Just s, _ -> Right s
                 Nothing, Just e -> Left ("ERR: " <> e)
                 Nothing, Nothing -> Left "eval: empty response"
      | otherwise -> Left ("HTTP " <> show r.status)

-- | POST /proposals/:id/hunks/:idx/{accept,reject}.  On 2xx we let
-- | the server's broadcast tell the UI what changed (Snapshot for
-- | accept, ProposalUpdated/Retired for both).  On 409 (RebaseNeeded
-- | or Pen-held), surface via transportError; the existing
-- | ConchUpdate-handler logic clears it once the user has the Pen.
proposalAction
  :: forall o m
   . MonadAff m
  => String  -- "accept" or "reject"
  -> ProposalId
  -> Int
  -> H.HalogenM State Action Slots o m Unit
proposalAction verb pid idx = do
  s <- H.get
  let
    authHeaders = case s.myId of
      Nothing -> []
      Just sid -> [ AX.RequestHeader "X-Atelier-Subscriber-Id" (unSubscriberId sid) ]
    url = backendUrl <> "/proposals/" <> unProposalId pid
            <> "/hunks/" <> show idx <> "/" <> verb
  result <- H.liftAff $ AX.request $ AX.defaultRequest
    { method = Left POST
    , url = url
    , responseFormat = RF.json
    , content = Nothing
    , headers = authHeaders
    }
  case result of
    Left err -> H.modify_ _ { transportError = Just (AX.printError err) }
    Right r -> case r.status of
      AX.StatusCode 409 -> do
        let banner = case AJ.toObject r.body >>= Object.lookup "message" >>= AJ.toString of
              Just msg -> msg
              Nothing -> "proposal " <> verb <> " rejected"
        H.modify_ _ { transportError = Just ("pen-held: " <> banner) }
      AX.StatusCode code
        -- On accept, the server's WebSocket Snapshot broadcast
        -- excludes the pen holder (existing behavior to avoid echo
        -- on typed edits).  But the pen holder triggered this
        -- accept and they need to see the new source too — so apply
        -- the response body locally instead of waiting for a frame
        -- that won't arrive.  Reject endpoints don't mutate source
        -- so they don't need this fast-path.
        | code >= 200 && code < 300 ->
            when (verb == "accept") $
              case CA.decode compileResponseCodec r.body of
                Right (CompileResponse snap) -> applyRemote snap
                Left _ -> pure unit
        | otherwise -> H.modify_ _
            { transportError = Just ("proposal " <> verb <> " failed: HTTP " <> show code) }

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
        H.modify_ _ { myId = Just r.yourId, pen = r.pen, proposals = r.proposals }
        let CompileResponse snap = r.snapshot
        applyRemote snap
        syncEditorsEditable
        dispatchProposals
        -- Auto-claim the pen if nobody holds it.  Algorave-shaped
        -- live coding is usually one-person-one-rig; the click-to-
        -- take friction is pure tax.  If somebody else already
        -- holds it (the rare collab case) we leave them alone.
        case r.pen.holder of
          Nothing -> handleAction RequestPenAction
          Just _ -> pure unit
      Snapshot r -> do
        H.modify_ _ { pen = r.pen }
        s <- H.get
        let CompileResponse snap = r.snapshot
        when (remoteDiffers s snap) (applyRemote snap)
      PenUpdate r -> do
        s <- H.get
        let wasRequesting = s.requestingPen
            iHoldNow = case r.pen.holder, s.myId of
              Just h, Just me -> h == me
              _, _ -> false
            -- A 409 from any mutating call (e.g. LoadFavorite while
            -- somebody else held the pen) leaves a "pen-held"
            -- transportError sitting in the error panel.  Once the
            -- user has the pen the error is stale; clear it (and
            -- any runtimeError) so the panel mirrors the live state.
            stale = iHoldNow && isPenHeldError s.transportError
        H.modify_ _
          { pen = r.pen
          , requestingPen = if iHoldNow || (not wasRequesting) then false else s.requestingPen
          , penBackoffMs = if iHoldNow then 250 else s.penBackoffMs
          , penBanner = if iHoldNow then Nothing else s.penBanner
          , transportError = if stale then Nothing else s.transportError
          , runtimeError = if iHoldNow then Nothing else s.runtimeError
          }
        syncEditorsEditable
      ProposalAdded r -> do
        H.modify_ \s -> s { proposals = Array.snoc s.proposals r.proposal }
        dispatchProposals
      ProposalUpdated r -> do
        H.modify_ \s -> s
          { proposals = map (replaceWith r.proposal) s.proposals }
        dispatchProposals
        where
        replaceWith new@(Proposal np) old@(Proposal op) =
          if op.id == np.id then new else old
      ProposalRetired r -> do
        H.modify_ \s -> s
          { proposals = Array.filter (\(Proposal p) -> p.id /= r.id) s.proposals }
        dispatchProposals
      where
      isPenHeldError = case _ of
        Just msg -> Str.take 9 msg == "pen-held:"
        Nothing -> false

syncEditorsEditable
  :: forall o m
   . MonadAff m
  => H.HalogenM State Action Slots o m Unit
syncEditorsEditable = do
  s <- H.get
  let editable = iHoldPen s
  _ <- H.tell _moduleEditor unit (Editor.SetEditable editable)
  for_ s.cells \c ->
    H.tell _cellEditor c.id (Editor.SetEditable editable)

-- | Push the per-target slice of the proposals array down to each
-- | live editor.  Called after any state.proposals mutation.
dispatchProposals
  :: forall o m
   . MonadAff m
  => H.HalogenM State Action Slots o m Unit
dispatchProposals = do
  s <- H.get
  let modProps = Array.filter (\(Proposal p) -> p.target == TgtModule) s.proposals
  _ <- H.tell _moduleEditor unit (Editor.SetProposals modProps)
  for_ s.cells \c -> do
    let cellProps = Array.filter (forCell c.id) s.proposals
    H.tell _cellEditor c.id (Editor.SetProposals cellProps)
  where
  forCell cid (Proposal p) = case p.target of
    TgtCell pid -> pid == cid
    _ -> false

iHoldPen :: State -> Boolean
iHoldPen s = case s.pen.holder, s.myId of
  Just h, Just me -> h == me
  _, _ -> false

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

applyRemote
  :: forall o m r
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
     | r
     }
  -> H.HalogenM State Action Slots o m Unit
applyRemote r = do
  let UserModule rm = r."module"
      typesMap = Map.fromFoldable
        ( map (\(CellType ct) -> Tuple ct.id ct.signature) r.types )
      cellRecs = map cellRecOf r.cells
      resultsMap = Map.fromFoldable
        ( map (\(CellEmit e) -> Tuple e.id e.value) r.emits )
      syncedCells = Map.fromFoldable
        ( map (\(Cell c) -> Tuple c.id { source: c.source, kind: c.kind }) r.cells )
      -- Pull the highest-numbered cell from the snapshot so a fresh
      -- AddCell never collides with a pre-existing id.  Cell ids
      -- match `c<N>`; anything else is treated as 0 (still safe —
      -- max with the existing local counter keeps it monotonic).
      maxRemoteN = foldr max 0
        ( Array.mapMaybe (\(Cell c) -> parseCellNumber c.id) r.cells )
  H.modify_ \s -> s
    { moduleSource = rm.source
    , cells = cellRecs
    , nextCellId = max s.nextCellId (maxRemoteN + 1)
    , runtime = r.runtime
    , cellTypes = typesMap
    , cellResults = Map.union resultsMap s.cellResults
    , cellRanges = r.cellLines
    , errors = r.errors
    , warnings = r.warnings
    , lastSyncedModule = rm.source
    , lastSyncedCells = syncedCells
    , lastSyncedRuntime = r.runtime
    }
  decorateErrors r.errors r.cellLines

parseCellNumber :: String -> Maybe Int
parseCellNumber s = Str.stripPrefix (Pattern "c") s >>= Int.fromString

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
      | endsWith "Calypso/User.purs" file ->
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

render :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
render state =
  HH.div
    [ HP.class_
        ( H.ClassName
            ( "calypso-shell"
                <> (if state.compiling then " is-compiling" else "")
            )
        )
    ]
    [ renderHeader state
    , renderPenBanner state
    , if state.settingsOpen then renderSettingsPanel state else HH.text ""
    , HH.main
        [ HP.class_ (H.ClassName "columns")
        , HP.style ("grid-template-columns: " <> gridTemplateForVisibility state.visibility)
        ]
        ( (if state.visibility.showComposition then [ renderCompositionColumn state ] else [])
            <> (if state.visibility.showCells then [ renderCellsColumn state ] else [])
            <> (if state.visibility.showHylograph then [ renderHylographColumn state ] else [])
        )
    , renderErrorPanel state
    ]

renderPenBanner :: forall m. State -> H.ComponentHTML Action Slots m
renderPenBanner state = case state.penBanner of
  Nothing -> HH.text ""
  Just msg ->
    HH.div [ HP.class_ (H.ClassName "pen-banner") ]
      [ HH.text msg
      , HH.button
          [ HP.class_ (H.ClassName "pen-banner-dismiss")
          , HE.onClick \_ -> DismissPenBanner
          ]
          [ HH.text "×" ]
      ]

stateIdleMsFor :: State -> Number
stateIdleMsFor state = case state.pen.holder of
  Nothing -> 0.0
  Just _ -> state.pen.lastActivityAt

renderSettingsPanel :: forall m. State -> H.ComponentHTML Action Slots m
renderSettingsPanel _ =
  HH.section [ HP.class_ (H.ClassName "settings-panel") ]
    [ HH.p [ HP.class_ (H.ClassName "settings-tagline") ]
        [ HH.text
            "Calypso — a workshop afloat the purerl-tidal daemon. Cells fire on Cmd-Enter; the composition holds the durable bones."
        ]
    ]

renderHeader :: forall m. State -> H.ComponentHTML Action Slots m
renderHeader state =
  HH.header [ HP.class_ (H.ClassName "calypso-header") ]
    [ HH.button
        [ HP.class_
            ( H.ClassName
                ( "settings-btn"
                    <> (if state.settingsOpen then " active" else "")
                )
            )
        , HP.title
            ( if state.settingsOpen then "Close settings" else "About Calypso" )
        , HE.onClick \_ -> ToggleSettings
        ]
        [ HH.text "⚙" ]
    , renderTitlePen state
    , renderViewToggle state
    , HH.div [ HP.class_ (H.ClassName "header-spacer") ] []
    , renderFavoritesDropdown state
    , HH.div [ HP.class_ (H.ClassName "header-spacer") ] []
    ]

renderTitlePen :: forall m. State -> H.ComponentHTML Action Slots m
renderTitlePen state =
  let iHold = iHoldPen state
      nobodyHolds = case state.pen.holder of
        Nothing -> true
        Just _ -> false
      somebodyElseHolds = (not iHold) && (not nobodyHolds)
      idleMs = stateIdleMsFor state
      forceable = somebodyElseHolds && idleMs > 60000.0
      requesting = state.requestingPen && (not iHold)
      status
        | iHold = "You hold the pen"
        | requesting = "Requesting…"
        | nobodyHolds = "Unclaimed"
        | forceable = "Held (idle — force?)"
        | otherwise = "Observing"
      stateCls
        | iHold = "pen-holding"
        | requesting = "pen-requesting"
        | nobodyHolds = "pen-unclaimed"
        | otherwise = "pen-observing"
      title
        | iHold = "You hold the pen. Click to yield."
        | nobodyHolds = "Nobody holds the pen. Click to take it."
        | forceable = "Holder has been idle >60s. Click to force-take."
        | otherwise = "Another viewer holds the pen. Click to request it."
      action
        | iHold = YieldPenAction
        | forceable = ForcePenAction
        | otherwise = RequestPenAction
  in HH.button
       [ HP.class_ (H.ClassName ("title-pen " <> stateCls))
       , HP.title title
       , HE.onClick \_ -> action
       ]
       [ HH.span [ HP.class_ (H.ClassName "title-pen-name") ]
           [ HH.text "Calypso" ]
       , HH.span [ HP.class_ (H.ClassName "title-pen-status") ]
           [ HH.text status ]
       ]

renderViewToggle :: forall m. State -> H.ComponentHTML Action Slots m
renderViewToggle state =
  HH.div [ HP.class_ (H.ClassName "view-toggle") ]
    ( map (viewToggleButton state) [ KeyComposition, KeyCells, KeyHylograph ] )

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

renderFavoritesDropdown :: forall m. State -> H.ComponentHTML Action Slots m
renderFavoritesDropdown state =
  HH.div [ HP.class_ (H.ClassName "starter-dropdown") ]
    [ HH.button
        [ HP.class_ (H.ClassName "starter-btn")
        , HE.onClick \_ -> ToggleFavoriteMenu
        ]
        [ HH.text (currentLabel <> " ▾") ]
    , if state.favoriteMenuOpen
        then HH.div [ HP.class_ (H.ClassName "starter-menu") ]
          (case state.favorites of
             [] ->
               [ HH.div [ HP.class_ (H.ClassName "starter-option") ]
                   [ HH.div [ HP.class_ (H.ClassName "starter-label muted") ]
                       [ HH.text "(no favorites yet)" ]
                   , HH.div [ HP.class_ (H.ClassName "starter-desc") ]
                       [ HH.text "Drop a .tidal file in ~/.calypso/favorites/" ]
                   ]
               ]
             favs -> map (renderFavoriteOption state) favs)
        else HH.text ""
    ]
  where
  currentLabel = case state.favoriteKey of
    Just k -> k
    Nothing -> "Favorites"

renderFavoriteOption :: forall m. State -> Favorite -> H.ComponentHTML Action Slots m
renderFavoriteOption state (Favorite f) =
  HH.button
    [ HP.class_
        ( H.ClassName
            ( "starter-option"
                <> (if state.favoriteKey == Just f.key then " current" else "")
            )
        )
    , HE.onClick \_ -> LoadFavorite f.key
    ]
    [ HH.div [ HP.class_ (H.ClassName "starter-label") ] [ HH.text f.label ]
    ]

renderCompositionColumn :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderCompositionColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-composition") ]
    [ HH.div [ HP.class_ (H.ClassName "pane-toolbar") ]
        [ HH.button
            [ HP.class_ (H.ClassName "fire-btn")
            , HE.onClick \_ -> FireComposition state.moduleSource
            , HP.title "Fire the whole composition (Mod-Enter inside the editor)"
            ]
            [ HH.text "▶ fire" ]
        , case state.compositionStatus of
            Just msg ->
              HH.span [ HP.class_ (H.ClassName "fire-status") ]
                [ HH.text msg ]
            Nothing -> HH.text ""
        ]
    , HH.slot _moduleEditor unit Editor.component
        { initialDoc: state.moduleSource
        , tag: "module"
        , vocabulary: state.completions
        }
        compositionOutput
    ]
  where
  compositionOutput = case _ of
    Editor.Changed src -> ModuleChanged src
    Editor.Submitted src -> FireComposition src
    Editor.AcceptHunkO pid idx -> AcceptHunk pid idx
    Editor.RejectHunkO pid idx -> RejectHunk pid idx

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

cellColorClass :: Int -> String
cellColorClass idx = "cell-color-" <> show (idx `mod` 8)

renderCellRow :: forall m. MonadAff m => State -> Int -> CellRec -> H.ComponentHTML Action Slots m
renderCellRow state idx c =
  HH.div
    [ HP.class_
        ( H.ClassName
            ( "cell-row "
                <> cellColorClass idx
                <> (if c.kind == "let" then " cell-row-let" else " cell-row-expr")
            )
        )
    ]
    [ HH.div [ HP.class_ (H.ClassName "cell-meta") ]
        [ HH.span [ HP.class_ (H.ClassName "cell-id") ] [ HH.text c.id ]
        , HH.button
            [ HP.class_ (H.ClassName ("cell-kind-btn cell-kind-" <> c.kind))
            , HE.onClick \_ -> ToggleCellKind c.id
            , HP.title
                ( if c.kind == "let"
                    then "let-cell (splices verbatim; no reply shown). Click to switch to expr."
                    else "expr-cell (fired at the daemon; reply shown). Click to switch to let."
                )
            ]
            [ HH.text c.kind ]
        , HH.button
            [ HP.class_ (H.ClassName "fire-btn fire-btn-cell")
            , HE.onClick \_ -> FireCell c.id c.source
            , HP.title "Fire this cell (Mod-Enter inside the editor)"
            ]
            [ HH.text "▶" ]
        , HH.button
            [ HP.class_ (H.ClassName "remove-cell-btn")
            , HE.onClick \_ -> RemoveCell c.id
            , HP.title "Remove cell"
            ]
            [ HH.text "×" ]
        ]
    , HH.slot _cellEditor c.id Editor.component
        { initialDoc: c.source
        , tag: "cell"
        , vocabulary: state.completions
        }
        (cellOutput c.id)
    ]
  where
  cellOutput cid = case _ of
    Editor.Changed src -> CellChanged cid src
    Editor.Submitted src -> FireCell cid src
    Editor.AcceptHunkO pid idx -> AcceptHunk pid idx
    Editor.RejectHunkO pid idx -> RejectHunk pid idx

-- | Hylograph pane.  Currently a tabbed reference panel: the
-- | vocabulary parsed from purerl-tidal's setup files, a primer for
-- | mini-notation, and the existing per-cell daemon replies.  When
-- | the pattern visualiser lands, it'll likely become its own tab
-- | too — Asteroids/Battlezone vector aesthetic, per the user's
-- | direction.
renderHylographColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderHylographColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-hylograph") ]
    [ HH.div [ HP.class_ (H.ClassName "hylograph-tabs") ]
        (map (renderTab state.hylographTab) allHylographTabs)
    , HH.div [ HP.class_ (H.ClassName "hylograph-tab-body") ]
        [ case state.hylographTab of
            TabVocabulary -> renderVocabularyTab state
            TabMiniNotation -> Primer.renderMiniNotation
            TabReplies -> renderRepliesTab state
        ]
    ]
  where
  renderTab active tab =
    HH.button
      [ HP.classes
          [ H.ClassName "hylograph-tab"
          , H.ClassName (if active == tab then "hylograph-tab-active" else "")
          ]
      , HE.onClick \_ -> SwitchHylographTab tab
      ]
      [ HH.text (hylographTabLabel tab) ]

renderRepliesTab :: forall m. State -> H.ComponentHTML Action Slots m
renderRepliesTab state =
  HH.div [ HP.class_ (H.ClassName "hylograph-rows") ]
    (Array.catMaybes (mapWithIndex maybeRow state.cells))
  where
  maybeRow idx c =
    if c.kind == "expr" then Just (renderHylographRow state idx c) else Nothing

renderVocabularyTab :: forall m. State -> H.ComponentHTML Action Slots m
renderVocabularyTab state =
  let CV.Vocabulary v = state.vocabulary
  in case v.setupFiles of
       [] ->
         HH.div [ HP.class_ (H.ClassName "vocabulary-empty") ]
           [ HH.text "No setup files found. Set $CALYPSO_TIDAL_SETUP_DIR or drop *.tidal files into the default purerl-tidal/setup/ directory." ]
       sfs ->
         HH.div [ HP.class_ (H.ClassName "vocabulary-list") ]
           (map renderSetupFile sfs)

renderSetupFile :: forall m. CV.SetupFile -> H.ComponentHTML Action Slots m
renderSetupFile (CV.SetupFile sf) =
  HH.div [ HP.class_ (H.ClassName "vocabulary-device") ]
    [ HH.div [ HP.class_ (H.ClassName "vocabulary-device-header") ]
        [ HH.span [ HP.class_ (H.ClassName "vocabulary-device-name") ]
            [ HH.text sf.name ]
        , case sf.port of
            Just p ->
              HH.span [ HP.class_ (H.ClassName "vocabulary-device-port") ]
                [ HH.text p ]
            Nothing -> HH.text ""
        ]
    , HH.ul [ HP.class_ (H.ClassName "vocabulary-bindings") ]
        (map renderBinding sf.bindings)
    ]

renderBinding :: forall m. CV.Binding -> H.ComponentHTML Action Slots m
renderBinding (CV.Binding b) =
  HH.li [ HP.class_ (H.ClassName "vocabulary-binding") ]
    [ HH.span [ HP.class_ (H.ClassName "vocabulary-binding-name") ]
        [ HH.text b.name ]
    , HH.span [ HP.class_ (H.ClassName "vocabulary-binding-detail") ]
        [ HH.text (bindingSummary b) ]
    ]

bindingSummary :: forall r. { kind :: CV.BindingKind, channel :: Int, number :: Int | r } -> String
bindingSummary b = case b.kind of
  CV.MidiNote -> "note ch" <> show b.channel <> " (default " <> show b.number <> ")"
  CV.MidiCc -> "cc " <> show b.number <> " ch" <> show b.channel

renderHylographRow :: forall m. State -> Int -> CellRec -> H.ComponentHTML Action Slots m
renderHylographRow state idx c =
  HH.div [ HP.class_ (H.ClassName ("hylograph-row " <> cellColorClass idx)) ]
    [ HH.span [ HP.class_ (H.ClassName "hylograph-cell-id") ] [ HH.text c.id ]
    , case Map.lookup c.id state.cellResults of
        Just reply ->
          HH.pre [ HP.class_ (H.ClassName "hylograph-reply") ]
            [ HH.text reply ]
        Nothing ->
          HH.span [ HP.class_ (H.ClassName "muted") ] [ HH.text "—" ]
    ]

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
      if endsWith "Calypso/User.purs" file then
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
