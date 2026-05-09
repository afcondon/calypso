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
import Data.Set (Set)
import Data.Set as Set
import Data.String as Str
import Data.String.CodeUnits (takeRight) as Str.CU
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.HTTP.Method (Method(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Int (toNumber)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust, isNothing)
import Data.Number as Number
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
import Web.Event.Event as WEvent
import Web.Event.EventTarget as WEvtTarget
import Web.HTML (window) as Web
import Web.HTML.Window as WWindow
import Web.UIEvent.KeyboardEvent as WKey
import Web.UIEvent.KeyboardEvent.EventTypes as WKeyTypes

import Data.Foldable (for_, foldr)

import Calypso.Frontend.CodeMirror (ErrorSpan)
import Calypso.Frontend.Config (backendUrl, formatNumber, prettyPrintJson, readHideParam, writeHideParam, wsBackendUrl)
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
-- |
-- | `author` is preserved from the wire — non-Nothing means the cell was
-- | dropped in by an external API caller (an agent, a tutorial script, a
-- | jam-partner) rather than authored at the helm. The cells pane shows a
-- | small marker for those; on PromoteCellToCode the author becomes a
-- | comment in the composition source.
type CellRec = { id :: String, kind :: String, source :: String, author :: Maybe String }

cellRecOf :: Cell -> CellRec
cellRecOf (Cell c) = { id: c.id, kind: c.kind, source: c.source, author: c.author }

cellOf :: CellRec -> Cell
cellOf c = Cell { id: c.id, kind: c.kind, source: c.source, form: false, author: c.author }

-- | Infer which section a cell belongs to, by inspecting its source's
-- | leading word.  Used to group cells in the accordion: `bind …` cells
-- | go to Voices, `bpm`/`midi-device`/etc. to Config, everything else
-- | (the live patterns) to Patterns.  This is *display-only*
-- | classification — the cell itself stores no section tag.
cellSection :: CellRec -> Section
cellSection c =
  let
    -- Extract the first whitespace-delimited word of the first
    -- non-empty, non-`--`-comment line.
    lines = Str.split (Pattern "\n") c.source
    firstStmt = Array.find (\l -> not (Str.null (stripLineComment l))) lines
    firstWord = case firstStmt of
      Nothing -> ""
      Just l -> case Str.split (Pattern " ") (stripLineComment l) of
        ws -> fromMaybe "" (Array.head (Array.filter (not <<< Str.null) ws))
  in
    if firstWord == "bind" || firstWord == "unbind"
      then SecVoices
      else if Array.elem firstWord configVerbs
        then SecConfig
        else SecPatterns
  where
    configVerbs =
      [ "bpm"
      , "midi-device"
      , "log-level"
      , "look-ahead-ms"
      , "gate-enabled"
      , "note-duration"
      , "cv-lead-ms"
      , "gate-duration"
      , "channel-offset"
      , "load"
      , "save"
      , "fh2-envelope"
      , "config"
      ]

-- | The six top-level panes. Each is independently toggleable
-- | via the view-toggle bar or via Cmd-1..Cmd-6 (Ctrl on non-Mac).
-- | Layout is left-to-right in the order declared here. Persisted
-- | in the URL as `?hide=cells,replies,…` (omitted when all show).
-- |
-- | Replies / Vocabulary / Mini-notation were previously sub-tabs of
-- | the Hylograph pane; promoted to top-level so quick lookups
-- | don't displace the editing surface.
-- |
-- | Hylograph stays the rightmost slot for the eventual pattern
-- | visualiser; until that lands its render is a placeholder.
data ColumnKey
  = KeyComposition
  | KeyCells
  | KeyReplies
  | KeyVocabulary
  | KeyMiniNotation
  | KeyHylograph
  | KeyConfig
  | KeyVoiceCells

derive instance Eq ColumnKey

-- | Order panes appear left-to-right in the row, and the index
-- | bound to Cmd-N (Cmd-1 = first, Cmd-8 = last).
allColumnKeys :: Array ColumnKey
allColumnKeys =
  [ KeyComposition
  , KeyCells
  , KeyReplies
  , KeyVocabulary
  , KeyMiniNotation
  , KeyHylograph
  , KeyConfig
  , KeyVoiceCells
  ]

type ColumnVisibility =
  { showComposition :: Boolean
  , showCells :: Boolean
  , showReplies :: Boolean
  , showVocabulary :: Boolean
  , showMiniNotation :: Boolean
  , showHylograph :: Boolean
  , showConfig :: Boolean
  , showVoiceCells :: Boolean
  }

allVisible :: ColumnVisibility
allVisible =
  { showComposition: true
  , showCells: true
  , showReplies: true
  , showVocabulary: true
  , showMiniNotation: true
  , showHylograph: true
  , showConfig: true
  , showVoiceCells: true
  }

-- | Initial visibility on a fresh load: editor + replies on, the
-- | reference panes off (Cmd-4/5/6/7/8 to bring them in).  Even on
-- | big monitors all seven side-by-side is too cramped — better
-- | to summon what you want, when you want.
defaultVisibility :: ColumnVisibility
defaultVisibility =
  { showComposition: true
  , showCells: true
  , showReplies: true
  , showVocabulary: false
  , showMiniNotation: false
  , showHylograph: false
  , showConfig: false
  , showVoiceCells: false
  }

isVisible :: ColumnKey -> ColumnVisibility -> Boolean
isVisible = case _ of
  KeyComposition -> _.showComposition
  KeyCells -> _.showCells
  KeyReplies -> _.showReplies
  KeyVocabulary -> _.showVocabulary
  KeyMiniNotation -> _.showMiniNotation
  KeyHylograph -> _.showHylograph
  KeyConfig -> _.showConfig
  KeyVoiceCells -> _.showVoiceCells

toggleKey :: ColumnKey -> ColumnVisibility -> ColumnVisibility
toggleKey k v = case k of
  KeyComposition -> v { showComposition = not v.showComposition }
  KeyCells -> v { showCells = not v.showCells }
  KeyReplies -> v { showReplies = not v.showReplies }
  KeyVocabulary -> v { showVocabulary = not v.showVocabulary }
  KeyMiniNotation -> v { showMiniNotation = not v.showMiniNotation }
  KeyHylograph -> v { showHylograph = not v.showHylograph }
  KeyConfig -> v { showConfig = not v.showConfig }
  KeyVoiceCells -> v { showVoiceCells = not v.showVoiceCells }

columnKeyLabel :: ColumnKey -> String
columnKeyLabel = case _ of
  KeyComposition -> "Composition"
  KeyCells -> "Cells"
  KeyReplies -> "Replies"
  KeyVocabulary -> "Vocabulary"
  KeyMiniNotation -> "Mini-notation"
  KeyHylograph -> "Hylograph"
  KeyConfig -> "Config"
  KeyVoiceCells -> "Voice Cells"

columnKeyToken :: ColumnKey -> String
columnKeyToken = case _ of
  KeyComposition -> "composition"
  KeyCells -> "cells"
  KeyReplies -> "replies"
  KeyVocabulary -> "vocabulary"
  KeyMiniNotation -> "mini-notation"
  KeyHylograph -> "hylograph"
  KeyConfig -> "config"
  KeyVoiceCells -> "voice-cells"

-- | Decode the `?hide=` query value into a `ColumnVisibility`.
-- |
-- | The URL param name is `hide` for legacy compatibility, but its
-- | semantics are now "panes whose visibility differs from default".
-- | An empty param yields `defaultVisibility` (1/2/3 on, 4/5/6 off).
-- | A token for an on-by-default pane (composition / cells / replies)
-- | hides it; a token for an off-by-default pane (vocabulary / mini-
-- | notation / hylograph) shows it.  Unknown tokens are ignored;
-- | "module"/"values"/"render"/"gutter" are accepted as legacy
-- | aliases from the Atelier era.
visibilityFromHide :: String -> ColumnVisibility
visibilityFromHide hide =
  let tokens = if hide == "" then [] else Str.split (Pattern ",") hide
      has t = Array.any (_ == t) tokens
  in
    -- On-by-default: visible unless an explicit hide-token appears.
    { showComposition: not (has "composition" || has "module")
    , showCells: not (has "cells")
    , showReplies: not (has "replies")
    -- Off-by-default: hidden unless an explicit show-token appears.
    , showVocabulary: has "vocabulary"
    , showMiniNotation: has "mini-notation" || has "mininotation"
    , showHylograph: has "hylograph" || has "render" || has "values" || has "gutter"
    , showConfig: has "config"
    , showVoiceCells: has "voice-cells" || has "voicecells"
    }

hideFromVisibility :: ColumnVisibility -> String
hideFromVisibility v =
  let entries = Array.catMaybes $
        map (\k -> if isVisible k v == isVisible k defaultVisibility
                     then Nothing
                     else Just (columnKeyToken k)) allColumnKeys
  in Str.joinWith "," entries

-- | Grid-template-columns string for the visible panes.  Equal-share
-- | columns: 1fr per visible pane, "1fr" fallback when nothing is on
-- | (the layout block still renders the empty grid container so the
-- | toolbar / view-toggle stay anchored).
gridTemplateForVisibility :: ColumnVisibility -> String
gridTemplateForVisibility v =
  let parts = Array.catMaybes $
        map (\k -> if isVisible k v then Just "1fr" else Nothing) allColumnKeys
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
  -- Per-statement results from the most recent composition fire.
  -- Empty between fires.  Surfaced in the Replies pane so "no sound
  -- came out" becomes diagnosable line-by-line — every statement's
  -- daemon reply is captured, including ones past the first error.
  , compositionFireLines :: Array { lineNum :: Int, source :: String, reply :: Either String String }
  -- Most recent purerl-tidal state snapshot, fetched via the `state`
  -- WS verb (read from the StateBus ETS table).  Refreshed on demand
  -- from the Config pane.  Pretty-printed before render.
  , configSnapshot :: Maybe String
  -- Last known BPM, displayed in the topbar widget.  Updated when
  -- the Config pane refreshes or when BpmCommit fires.  Initial
  -- value is the Main.purs default (120) until the first refresh
  -- proves otherwise.
  , bpmDisplay :: Number
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
  -- Voice Cells pane: user-defined "musical voice" stacks.  Each
  -- music cell can be assigned a stack via a 9-swatch colour
  -- picker (1 "no stack" + 8 colours).  Stack identity is the
  -- colour, full stop; same-coloured cards overlap visually with
  -- the front card fully visible; clicking a back card's header
  -- brings it to the front; clicking the front card's header fans
  -- the stack out for editing; clicking any header in a fanned
  -- stack restacks.  Stack assignment + per-stack ordering are
  -- in-session only — not persisted, not in the .tidal.  See
  -- docs/voice-cells-design.md.
  , stackOrder :: Map Int (Array String)
                                      -- colour 1..8 → cellIds in
                                      -- stack order, front first
  , fannedStack :: Maybe Int          -- colour of currently-fanned
                                      -- music stack, if any
  , configStackFanned :: Boolean      -- config cells form their own
                                      -- pseudo-stack (always present);
                                      -- this tracks whether it's
                                      -- fanned out
  , colorPickerOpen :: Maybe String   -- cellId whose picker is open
  , editingCard :: Maybe String       -- cellId currently popped open
                                      -- in the modal editor, if any.
                                      -- One-at-a-time; backdrop /
                                      -- Esc / Cmd-Enter close it.
                                      -- See docs/voice-cells-design.md
                                      -- "in-card editing" section.
  , armedModule :: Map String String  -- cellId → loaded module name
                                      -- ("M<hash>") set by a successful
                                      -- Cue.  Play is enabled iff a cell
                                      -- has an entry here.  PR2-phase:
                                      -- the module exports `result :: Int`;
                                      -- PR3 flips it to `pattern :: Pattern
                                      -- String` and wires voice install.
  , cuePending :: Set String          -- cellIds whose Cue is in flight.
                                      -- Cold compile is ~7s today (PR4's
                                      -- daemon path drops it to <300ms);
                                      -- the modal shows "compiling…" while
                                      -- a cellId is in this set so a long
                                      -- wait doesn't read as a hang.
  , cellMvoice :: Map String String   -- cellId → mvoice name (the
                                      -- purerl-tidal binding to install
                                      -- the cell's Pattern into).  PR3:
                                      -- in-session only; default per-cell
                                      -- is extractVoiceName(source).  Edit
                                      -- via small input field in modal
                                      -- header.  Persists per-session,
                                      -- not across server restarts (yet).
  , cellHistory :: Map String (Array { body :: String, modul :: String })
                                      -- Per-cell version log: every
                                      -- successful Cue prepends a
                                      -- {body, module} entry; module
                                      -- name encodes the source hash.
                                      -- Modules stay loaded so re-
                                      -- arming a previous entry is a
                                      -- cache hit (sub-ms).  Dedupe
                                      -- by modul — re-cuing identical
                                      -- source moves entry to top
                                      -- rather than piling up.
                                      -- Endless; in-session only.
  }

type Slots =
  ( moduleEditor :: H.Slot Editor.Query Editor.Output Unit
  , cellEditor :: H.Slot Editor.Query Editor.Output String
  , editorModal :: H.Slot Editor.Query Editor.Output Unit
  )

_moduleEditor :: Proxy "moduleEditor"
_moduleEditor = Proxy

_cellEditor :: Proxy "cellEditor"
_cellEditor = Proxy

_editorModal :: Proxy "editorModal"
_editorModal = Proxy

data Action
  = Compile
  | ScheduleCompile
  | ModuleChanged String
  | CellChanged String String
  | AddCell
  | RemoveCell String
  | ToggleCellKind String
  | PromoteCellToCode String         -- append cell source to composition, then remove cell
  | DemoteCursorLineToCell           -- copy cursor line in moduleEditor into a new cell
  | FireCell String String        -- cell id, current source
  | FireComposition String        -- current composition source
  | FireSection Section String    -- fire only one section's statements
  | WipeAndRestore                -- clear all cells, re-fire code pane
  | AcceptHunk ProposalId Int     -- POST /proposals/:id/hunks/:idx/accept
  | RejectHunk ProposalId Int     -- POST .../reject
  | ToggleFavoriteMenu
  | LoadFavorite String
  | FavoritesLoaded (Array Favorite)
  | VocabularyLoaded Vocabulary
  | KeyboardShortcut Int     -- Cmd-N pressed at the window level; toggles a column
  | RefreshConfigState       -- Config pane: ask purerl-tidal for its state snapshot
  | BpmCommit Number         -- topbar BPM widget: commit a new tempo via Link
  | BpmInputChanged String   -- intermediate: text typed in the BPM input
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
  -- Voice Cells pane: stack assignment via colour picker, fan-out
  -- to edit a stack's contents.  See docs/voice-cells-design.md.
  | OpenColorPicker String                  -- cellId
  | CloseColorPicker
  | SetCardColor String (Maybe Int)         -- cellId, Just N (assign) | Nothing (clear)
  | HeaderClick String                      -- cellId; resolves to
                                            -- bring-to-front /
                                            -- fan / restack based
                                            -- on current stack
                                            -- context
  | OpenEditor String                       -- click on small card body
  | CloseEditor                             -- backdrop / Esc / cancel
  | CommitEdit String String                -- Cmd-Enter from modal: fire + close
  -- PR2 cue/play-armed flow.  Cue compiles + hot-loads on the
  -- backend; Play invokes the loaded module's `result/0`.  When PR3
  -- lands these become the canonical fire path (replacing FireCell)
  -- and Play wires into the voice install.  Backend integrated test
  -- on per-cell-compile branch (purerl-tidal).
  | CueCell String String                   -- cellId, source
  | PlayArmed String String String          -- cellId, mvoiceName, moduleName
  | UpdateCellMvoice String String          -- cellId, new mvoice name
  | LoadHistoryEntry String String String   -- cellId, body, moduleName.
                                            -- Re-selects a previous cued
                                            -- version: replaces editor doc,
                                            -- writes through to cell source,
                                            -- re-arms.  Cache hit on the
                                            -- module since it's still loaded.
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
  , settingsOpen: false
  , compiling: false
  , errors: []
  , warnings: []
  , cellRanges: []
  , transportError: Nothing
  , runtimeError: Nothing
  , cellResults: Map.empty
  , compositionStatus: Nothing
  , compositionFireLines: []
  , configSnapshot: Nothing
  , bpmDisplay: 120.0
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
  , visibility: defaultVisibility
  , stackOrder: Map.empty
  , fannedStack: Nothing
  , configStackFanned: false
  , colorPickerOpen: Nothing
  , editingCard: Nothing
  , armedModule: Map.empty
  , cuePending: Set.empty
  , cellMvoice: Map.empty
  , cellHistory: Map.empty
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
    subscribeWindowShortcuts
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
  KeyboardShortcut digit ->
    case Array.index allColumnKeys (digit - 1) of
      Nothing -> pure unit
      Just key -> handleAction (ToggleColumn key)
  RefreshConfigState -> do
    -- Send the `state` verb through /eval; purerl-tidal returns the
    -- StateBus snapshot as the reply.  Stored verbatim; rendered with
    -- a JSON pretty-printer at draw time.  Also extracts bpm so the
    -- topbar widget reflects what the rig actually thinks tempo is.
    result <- evalSource "state"
    case result of
      Left err -> H.modify_ _ { configSnapshot = Just ("ERR: " <> err) }
      Right snap -> H.modify_ \s -> s
        { configSnapshot = Just snap
        , bpmDisplay = fromMaybe s.bpmDisplay (extractBpmFromSnapshot snap)
        }
  BpmInputChanged _ -> pure unit  -- live-input updates are observed via the input element's value
  BpmCommit n -> do
    -- Send `bpm <n>` to purerl-tidal, which forwards `/link/set-tempo`
    -- to link-spike, which broadcasts via Link to all peers.
    -- Optimistically update bpmDisplay so the input snaps to the
    -- committed value before the round-trip completes.
    H.modify_ _ { bpmDisplay = n }
    _ <- evalSource ("bpm " <> show n)
    pure unit
  ModuleChanged src -> do
    H.modify_ _ { moduleSource = src }
    handleAction ScheduleCompile
  CellChanged id src -> do
    H.modify_ \s -> s { cells = updateCell id src s.cells }
    handleAction ScheduleCompile
  AddCell -> do
    H.modify_ \s ->
      let newId = "c" <> show s.nextCellId
          newCell = { id: newId, kind: "expr", source: "", author: Nothing }
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
  PromoteCellToCode cellId -> do
    -- Append the cell's current source onto the end of the composition,
    -- then drop the cell.  Both happen in one local-state mutation; the
    -- subsequent ScheduleCompile sees a different cell-count and runs
    -- runFullCompile, which POSTs the whole new state to /session/compile.
    s0 <- H.get
    case Array.find (\c -> c.id == cellId) s0.cells of
      Nothing -> pure unit
      Just c -> do
        H.modify_ \s ->
          let sep = if Str.null s.moduleSource then ""
                    else if Str.CU.takeRight 1 s.moduleSource == "\n" then ""
                    else "\n"
              attribution = case c.author of
                Just a -> "-- from: " <> a <> "\n"
                Nothing -> ""
              newModule = s.moduleSource <> sep <> attribution <> c.source
                <> (if Str.CU.takeRight 1 c.source == "\n" then "" else "\n")
          in s
            { moduleSource = newModule
            , cells = filter (_.id >>> (_ /= cellId)) s.cells
            , cellResults = Map.delete cellId s.cellResults
            , cellTypes = Map.delete cellId s.cellTypes
            }
        -- Push the new content into the live moduleEditor view so the
        -- code-pane editor reflects the promoted text immediately;
        -- without this the parent state has the new source but the
        -- CodeMirror view still shows the old.
        st <- H.get
        _ <- H.tell _moduleEditor unit (Editor.ReplaceContent st.moduleSource)
        handleAction ScheduleCompile
  DemoteCursorLineToCell -> do
    -- Ask the module editor for its current cursor line and that line's
    -- text, then add a new cell whose source is that text.  The line in
    -- the composition is left untouched.
    result <- H.request _moduleEditor unit Editor.GetCursorLineText
    case result of
      Just (Just { text }) | not (Str.null (Str.trim text)) -> do
        H.modify_ \s ->
          let newId = "c" <> show s.nextCellId
              newCell = { id: newId, kind: "expr", source: text, author: Nothing }
          in s { cells = snoc s.cells newCell, nextCellId = s.nextCellId + 1 }
        handleAction ScheduleCompile
      _ -> pure unit
  FireCell cellId src -> do
    -- Tidal-style fire: Mod-Enter on a cell sends just that cell's
    -- text via /eval to the daemon.  The daemon's reply line lands
    -- in cellResults; errors land in transportError.  Strip blank
    -- lines and `--` comments first (same rule as the composition
    -- pane) so users can park notes inline.
    let stmts = compositionStatements src
        cleaned = Str.joinWith "\n" (map _.source stmts)
    if Str.null cleaned
      then H.modify_ \s -> s
        { cellResults = Map.insert cellId "(no statements)" s.cellResults }
      else do
        result <- evalSource cleaned
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
    H.modify_ _ { compositionStatus = Nothing, compositionFireLines = [], transportError = Nothing }
    if Array.null stmts
      then H.modify_ _ { compositionStatus = Just "(no statements to fire)" }
      else fireStatements stmts
  FireSection sec src -> do
    -- Fire only the statements in `sec`.  Useful for "boot voices",
    -- "set up config", "start patterns" as separate gestures during
    -- a session.  Statements before any section marker (SecDefault)
    -- are NOT included — the user opted out of taxonomy for those.
    let stmts = Array.filter (\e -> e.section == sec) (compositionStatements src)
    H.modify_ _ { compositionStatus = Nothing, compositionFireLines = [], transportError = Nothing }
    if Array.null stmts
      then H.modify_ _ { compositionStatus = Just $ "(no statements in section '" <> sectionLabel sec <> "')" }
      else fireStatements stmts
  WipeAndRestore -> do
    -- The Bret-Victor safety net: clear all cells (so the cells pane
    -- shows no overrides), then re-fire the prepared code-pane
    -- content (so the rig snaps back to the prepared session state).
    -- Distinct from `hush` (which silences everything) — restore
    -- returns the running rig to its prepared state, not silence.
    s0 <- H.get
    H.modify_ _
      { cells = []
      , cellResults = Map.empty
      , cellTypes = Map.empty
      , compositionStatus = Just "(cells wiped — restoring from code pane)"
      , compositionFireLines = []
      , transportError = Nothing
      }
    handleAction ScheduleCompile
    let stmts = compositionStatements s0.moduleSource
    if Array.null stmts
      then H.modify_ _ { compositionStatus = Just "(cells wiped — code pane is empty)" }
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
  OpenColorPicker cellId ->
    H.modify_ _ { colorPickerOpen = Just cellId }
  CloseColorPicker ->
    H.modify_ _ { colorPickerOpen = Nothing }
  SetCardColor cellId Nothing ->
    H.modify_ \s -> s
      { stackOrder = removeFromAllStacks cellId s.stackOrder
      , colorPickerOpen = Nothing
      }
  SetCardColor cellId (Just n) ->
    H.modify_ \s ->
      let cleaned = removeFromAllStacks cellId s.stackOrder
          inserted = Map.alter
            (\mArr -> Just (Array.cons cellId (fromMaybe [] mArr)))
            n
            cleaned
      in s { stackOrder = inserted, colorPickerOpen = Nothing }
  HeaderClick cellId -> do
    s <- H.get
    let isConfig = case Array.find (\c -> c.id == cellId) s.cells of
          Just c -> let sec = cellSection c in sec == SecConfig || sec == SecVoices
          Nothing -> false
    if isConfig
      then H.modify_ _ { configStackFanned = not s.configStackFanned }
      else case cellInColor s.stackOrder cellId of
        Nothing -> pure unit  -- lone music card; header click is a no-op
        Just color
          | s.fannedStack == Just color ->
              H.modify_ _ { fannedStack = Nothing }
          | otherwise -> do
              let stack = fromMaybe [] (Map.lookup color s.stackOrder)
              if Array.head stack == Just cellId
                then H.modify_ _ { fannedStack = Just color }
                else
                  -- Bring to front: remove + prepend within this stack.
                  H.modify_ \st -> st
                    { stackOrder = Map.update
                        (\arr -> Just (Array.cons cellId (Array.filter (_ /= cellId) arr)))
                        color
                        st.stackOrder
                    }
  OpenEditor cellId -> do
    -- One-at-a-time: opening a new card replaces any in-flight edit.
    -- Mirroring is automatic — the modal's editor emits Editor.Changed
    -- which we route to CellChanged, the existing per-cell source path.
    H.modify_ _ { editingCard = Just cellId }
  CloseEditor ->
    H.modify_ _ { editingCard = Nothing }
  CommitEdit cellId src -> do
    -- Fire the cell.  Don't auto-close — keep the modal open so the
    -- user sees the reply land in the in-modal reply area and can
    -- iterate (type → fire → see → type → fire).  Close manually via
    -- × or Esc once satisfied.  When compile-armed Cue arrives we'll
    -- be able to gate close on compile error here.
    handleAction (FireCell cellId src)
  CueCell cellId src -> do
    -- PR2: send the source through the new `cue` verb on purerl-tidal.
    -- Backend hashes, compiles to a generated PureScript module, hot-
    -- loads, replies `OK: cue M<hash>` or `ERR cue: <stderr>`.  On
    -- success we record the module name in armedModule; the modal's
    -- Play button enables.  On error we just show the reply text.
    let stmts = compositionStatements src
        cleaned = Str.joinWith "\n" (map _.source stmts)
    if Str.null cleaned
      then H.modify_ \s -> s
        { cellResults = Map.insert cellId "(no statements)" s.cellResults }
      else do
        -- Mark this cell's cue as in flight so the modal can render
        -- "compiling…" instead of looking hung during the 7s cold path.
        H.modify_ \s -> s { cuePending = Set.insert cellId s.cuePending }
        result <- evalSource ("cue " <> cleaned)
        H.modify_ \s -> s { cuePending = Set.delete cellId s.cuePending }
        case result of
          Left err -> H.modify_ _ { transportError = Just err }
          Right reply -> do
            H.modify_ \s -> s
              { cellResults = Map.insert cellId reply s.cellResults }
            case parseCueReply reply of
              Just modName -> do
                -- Arm + log history.  Dedupe by module name: if this
                -- exact module already exists in the cell's history,
                -- pull the entry to the top rather than piling up.
                let entry = { body: cleaned, modul: modName }
                H.modify_ \s ->
                  let existing = fromMaybe [] (Map.lookup cellId s.cellHistory)
                      filtered = Array.filter (\e -> e.modul /= modName) existing
                      updated  = Array.cons entry filtered
                  in s
                    { armedModule = Map.insert cellId modName s.armedModule
                    , cellHistory = Map.insert cellId updated s.cellHistory
                    }
              Nothing -> pure unit
  PlayArmed cellId mvoiceName moduleName -> do
    -- PR3: Install the previously-cued module's pattern into the
    -- named mvoice on the backend.  Backend looks up the binding
    -- registered for mvoiceName via `bind` and hands the loaded
    -- Pattern String to tidal_voice_sup:set_voice_pat.  Pattern
    -- starts firing through the rig immediately.
    result <- evalSource
      ("play-armed " <> mvoiceName <> " " <> moduleName)
    case result of
      Left err -> H.modify_ _ { transportError = Just err }
      Right reply ->
        H.modify_ \s -> s { cellResults = Map.insert cellId reply s.cellResults }
  UpdateCellMvoice cellId name -> do
    -- The mvoice name binds the cell's pattern to a purerl-tidal
    -- voice (set up via `bind`).  Empty string clears (defaults
    -- back to extractVoiceName at fire time).
    let trimmed = Str.trim name
    if Str.null trimmed
      then H.modify_ \s -> s { cellMvoice = Map.delete cellId s.cellMvoice }
      else H.modify_ \s -> s { cellMvoice = Map.insert cellId trimmed s.cellMvoice }
  LoadHistoryEntry cellId body modul -> do
    -- Re-select a previous cued version.  The module is still
    -- loaded (modules stay live for the BEAM session), so arming
    -- is just a Map.insert — no compile, no WS round-trip.
    -- Three things have to update in sync:
    --   1. The modal editor's document (Editor.ReplaceContent)
    --   2. The cell's source-of-truth in state.cells (so the small
    --      card body preview stays consistent)
    --   3. armedModule[cellId] = modul (so Play wires to this version)
    void $ H.tell _editorModal unit (Editor.ReplaceContent body)
    handleAction (CellChanged cellId body)
    H.modify_ \s -> s { armedModule = Map.insert cellId modul s.armedModule }
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
        s <- H.get
        if iHoldPen s
          then do
            -- Stale 409: this request was sent before our pen claim
            -- landed.  The banner from `penHeldMessage` would falsely
            -- say "Pen is unclaimed", overwriting the cleared state
            -- we just got from the PenUpdate broadcast.
            H.modify_ _ { compiling = false }
            pure (Left "pen-held: stale (we now hold the pen)")
          else do
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
-- | Drop everything from the first `--` onwards and trim trailing
-- | whitespace.  Whole-line `--` comments collapse to "".  Mini-notation
-- | uses single-`-` tokens (binding names like `live-tick`) but never
-- | `--`, so this is unambiguous.
stripLineComment :: String -> String
stripLineComment line = case Str.indexOf (Pattern "--") line of
  Just i -> Str.trim (Str.take i line)
  Nothing -> Str.trim line

-- | Composition sections — the structural taxonomy the code pane is
-- | organised by.  Lines after a `# config` / `# voices` / `# patterns`
-- | marker (until the next marker) belong to that section.  Lines
-- | before any marker are `SecDefault`, fired alongside everything by
-- | the all-fire path; per-section fire skips them.
data Section
  = SecConfig
  | SecVoices
  | SecPatterns
  | SecDefault

derive instance eqSection :: Eq Section

-- | Render a section for log / UI strings.
sectionLabel :: Section -> String
sectionLabel = case _ of
  SecConfig -> "config"
  SecVoices -> "voices"
  SecPatterns -> "patterns"
  SecDefault -> "(unsectioned)"

-- | Recognise a section header line.  `# config`, `# voices`, or
-- | `# patterns` (after comment-strip + trim) returns the section;
-- | anything else returns Nothing.  Distinct from `# vel "…"` (the
-- | parameter-join shape) because the section names are a closed set.
sectionOfLine :: String -> Maybe Section
sectionOfLine line = case Str.trim line of
  "# config" -> Just SecConfig
  "# voices" -> Just SecVoices
  "# patterns" -> Just SecPatterns
  _ -> Nothing

-- | Join continuation lines into the previous logical line.  A
-- | continuation is any (already-comment-stripped, non-blank) line
-- | whose first character is `#`.  Used to support the multi-line
-- | parameter-join shape:
-- |
-- | ```
-- | lap "c3 e3 g3 c4"
-- |   # vel "100 60 80 50"
-- |   # laplace-resonator-strength "0.2 0.7"
-- | ```
-- |
-- | …flattens to one statement before being sent to the daemon, which
-- | already handles single-line ` # ` segments.  The line number on
-- | the joined entry stays at the structure line, so error reports
-- | point at where the user's intent began.
-- |
-- | Section header lines (`# config`, `# voices`, `# patterns`) are
-- | NOT continuations — they're separator markers that propagate the
-- | section tag forward through the next statements.
joinContinuations
  :: Array { lineNum :: Int, source :: String, section :: Section }
  -> Array { lineNum :: Int, source :: String, section :: Section }
joinContinuations = Array.foldl step []
  where
  step acc entry =
    if Str.take 1 entry.source == "#" && isNothing (sectionOfLine entry.source)
      then case Array.unsnoc acc of
        Just { init, last } ->
          init <> [ last { source = last.source <> " " <> entry.source } ]
        Nothing -> [ entry ]  -- orphan `# …` with no preceding line; let
                              -- the parser emit its own error
      else acc <> [ entry ]

-- | Parse the composition source into a flat array of statements,
-- | each tagged with the section it falls under.  Section markers
-- | themselves are dropped from the output (they're navigational, not
-- | executable).  Lines before any marker get `SecDefault`.
compositionStatements
  :: String
  -> Array { lineNum :: Int, source :: String, section :: Section }
compositionStatements src =
  let lines = Str.split (Pattern "\n") src
      indexed = mapWithIndex
        (\i s -> { lineNum: i + 1, source: stripLineComment s }) lines
      nonBlank = Array.filter (\e -> not (Str.null e.source)) indexed
      tagged = tagSections SecDefault nonBlank
      -- Drop the section marker rows themselves; they're
      -- presentational, not statements to fire.
      noMarkers = Array.filter (\e -> isNothing (sectionOfLine e.source)) tagged
  in joinContinuations noMarkers
  where
  tagSections current xs = case Array.uncons xs of
    Nothing -> []
    Just { head, tail } -> case sectionOfLine head.source of
      Just sec ->
        -- Marker line itself carries the new section so it can be
        -- found and shown if needed; subsequent lines inherit.
        Array.cons
          { lineNum: head.lineNum, source: head.source, section: sec }
          (tagSections sec tail)
      Nothing ->
        Array.cons
          { lineNum: head.lineNum, source: head.source, section: current }
          (tagSections current tail)

-- | Fire a list of statements in order against /eval.  Stops on the
-- | first error and reports the failing line; on full success reports
-- | the count.  Status lands in `compositionStatus`.
fireStatements
  :: forall o m
   . MonadAff m
  => Array { lineNum :: Int, source :: String, section :: Section }
  -> H.HalogenM State Action Slots o m Unit
fireStatements stmts = go [] stmts
  where
  -- Run every statement.  Past the first error we *keep going* — the
  -- previous behaviour stopped on the first failure, which left the
  -- user blind to subsequent ones (yesterday's "all three bind lines
  -- failed but only the first one's reported" gap).  Each per-line
  -- reply lands in `compositionFireLines`; the summary in
  -- `compositionStatus` reports total / errors so the composition
  -- toolbar still shows a glanceable count.
  go acc remaining = case Array.uncons remaining of
    Nothing -> do
      let total = Array.length acc
          errs = Array.length (Array.filter isErr acc)
          summary = case errs of
            0 -> "OK: fired " <> show total <> " statements"
            n -> "ERR: " <> show n <> " of " <> show total <> " failed"
      H.modify_ _
        { compositionFireLines = acc
        , compositionStatus = Just summary
        }
    Just { head: e, tail } -> do
      result <- evalSource e.source
      go (Array.snoc acc { lineNum: e.lineNum, source: e.source, reply: result }) tail
  isErr r = case r.reply of
    Left _ -> true
    Right _ -> false

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

-- | Wire a window-level keydown listener that fires `KeyboardShortcut`
-- | for Cmd-1..Cmd-6 (Ctrl-1..6 on non-Mac). preventDefault stops Chrome
-- | from swallowing Cmd-N as tab-switch on macOS.  Editor-level keymaps
-- | (CodeMirror's Mod-/, Mod-Enter, etc.) still get the event first if
-- | focus is in an editor — we only act when the modifier+digit shape
-- | matches, not on every keystroke.
subscribeWindowShortcuts
  :: forall o m
   . MonadAff m
  => H.HalogenM State Action Slots o m Unit
subscribeWindowShortcuts = do
  { emitter, listener } <- H.liftEffect HS.create
  H.liftEffect do
    target <- WWindow.toEventTarget <$> Web.window
    cb <- WEvtTarget.eventListener \evt ->
      case WKey.fromEvent evt of
        Nothing -> pure unit
        Just kev -> do
          -- Escape: close the editing modal if one is open.  No
          -- modifier required.  CodeMirror doesn't bind Escape by
          -- default, so the keydown bubbles to window.  CloseEditor
          -- is a no-op when nothing is being edited.
          when (WKey.key kev == "Escape") do
            HS.notify listener CloseEditor
          let mod = WKey.metaKey kev || WKey.ctrlKey kev
          when mod do
            case digitFor (WKey.key kev) of
              Nothing -> pure unit
              Just d -> do
                WEvent.preventDefault evt
                HS.notify listener (KeyboardShortcut d)
    WEvtTarget.addEventListener WKeyTypes.keydown cb false target
  _ <- H.subscribe emitter
  pure unit
  where
    digitFor :: String -> Maybe Int
    digitFor = case _ of
      "1" -> Just 1
      "2" -> Just 2
      "3" -> Just 3
      "4" -> Just 4
      "5" -> Just 5
      "6" -> Just 6
      "7" -> Just 7
      _   -> Nothing

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

-- | Parse purerl-tidal's `cue` verb reply for the loaded module name.
-- | Backend replies `OK: cue M<hash>` on success, `ERR cue: <stderr>`
-- | on failure (we ignore the latter here — caller still shows the
-- | text in cellResults).
parseCueReply :: String -> Maybe String
parseCueReply reply = Str.trim <$> Str.stripPrefix (Pattern "OK: cue ") reply

-- | Opacity for a history row at depth `idx` (0 = most recent).
-- | Linear decay with a floor so rows are always slightly visible —
-- | "endless fading to black" without losing the option to scroll
-- | back through deep history.
historyOpacity :: Int -> String
historyOpacity idx =
  let f = max 0.12 (1.0 - Int.toNumber idx * 0.10)
  in show f

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
            <> (if state.visibility.showReplies then [ renderRepliesColumn state ] else [])
            <> (if state.visibility.showVocabulary then [ renderVocabularyColumn state ] else [])
            <> (if state.visibility.showMiniNotation then [ renderMiniNotationColumn state ] else [])
            <> (if state.visibility.showHylograph then [ renderHylographColumn state ] else [])
            <> (if state.visibility.showConfig then [ renderConfigColumn state ] else [])
            <> (if state.visibility.showVoiceCells then [ renderVoiceCellsColumn state ] else [])
        )
    , renderErrorPanel state
    , renderEditingModal state
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
    , renderBpmWidget state
    , renderViewToggle state
    , HH.div [ HP.class_ (H.ClassName "header-spacer") ] []
    , renderFavoritesDropdown state
    , HH.div [ HP.class_ (H.ClassName "header-spacer") ] []
    ]

-- | Pull `config.bpm` out of a StateBus JSON snapshot.  Returns
-- | Nothing if the snapshot doesn't parse, isn't an object, lacks
-- | the expected nested keys, or has a non-numeric bpm.  Used to
-- | sync the topbar BPM widget with what purerl-tidal thinks the
-- | tempo is.
extractBpmFromSnapshot :: String -> Maybe Number
extractBpmFromSnapshot raw = case jsonParser raw of
  Left _ -> Nothing
  Right j -> do
    obj <- AJ.toObject j
    cfgJ <- Object.lookup "config" obj
    cfgObj <- AJ.toObject cfgJ
    bpmJ <- Object.lookup "bpm" cfgObj
    AJ.toNumber bpmJ

-- | Topbar BPM widget — number input that fires `bpm <n>` over WS
-- | on commit (Enter or blur).  The value reflects the most-recent
-- | StateBus snapshot (see RefreshConfigState); editing is direct.
-- | DAW convention puts BPM in the top toolbar; this is the same.
renderBpmWidget :: forall m. State -> H.ComponentHTML Action Slots m
renderBpmWidget state =
  HH.div [ HP.class_ (H.ClassName "topbar-bpm") ]
    [ HH.input
        [ HP.type_ HP.InputNumber
        , HP.value (formatNumber state.bpmDisplay)
        , HP.title "BPM (Enter to commit; broadcasts via Link to all peers)"
        , HP.class_ (H.ClassName "topbar-bpm-input")
        , HE.onValueChange \v -> case Number.fromString v of
            Just n -> BpmCommit n
            Nothing -> BpmInputChanged v
        ]
    , HH.span [ HP.class_ (H.ClassName "topbar-bpm-label") ] [ HH.text "bpm" ]
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
    ( map (viewToggleButton state) allColumnKeys )

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
        , HH.button
            [ HP.class_ (H.ClassName "fire-btn fire-btn-section")
            , HE.onClick \_ -> FireSection SecConfig state.moduleSource
            , HP.title "Fire only statements under '# config'"
            ]
            [ HH.text "▶ config" ]
        , HH.button
            [ HP.class_ (H.ClassName "fire-btn fire-btn-section")
            , HE.onClick \_ -> FireSection SecVoices state.moduleSource
            , HP.title "Fire only statements under '# voices'"
            ]
            [ HH.text "▶ voices" ]
        , HH.button
            [ HP.class_ (H.ClassName "fire-btn fire-btn-section")
            , HE.onClick \_ -> FireSection SecPatterns state.moduleSource
            , HP.title "Fire only statements under '# patterns'"
            ]
            [ HH.text "▶ patterns" ]
        , HH.button
            [ HP.class_ (H.ClassName "fire-btn")
            , HE.onClick \_ -> DemoteCursorLineToCell
            , HP.title "Make the line under the cursor into a new cell (line stays in composition)"
            ]
            [ HH.text "↧ make cell" ]
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
    Editor.MoveRequested -> DemoteCursorLineToCell

renderCellsColumn :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderCellsColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-cells") ]
    ( renderSection SecConfig "config"
        <> renderSection SecVoices "voices"
        <> renderSection SecPatterns "patterns"
        <>
          [ HH.div [ HP.class_ (H.ClassName "cells-toolbar") ]
              [ HH.button
                  [ HP.class_ (H.ClassName "add-cell-btn")
                  , HE.onClick \_ -> AddCell
                  ]
                  [ HH.text "+ add cell" ]
              , HH.button
                  [ HP.class_ (H.ClassName "wipe-restore-btn")
                  , HE.onClick \_ -> WipeAndRestore
                  , HP.title "Clear all cells and re-fire the code pane (snap back to prepared session state)"
                  ]
                  [ HH.text "↺ wipe & restore" ]
              ]
          ]
    )
  where
    -- Each accordion section renders only the cells whose inferred
    -- kind matches.  Empty sections still get a header so the user
    -- sees the structure even with no cells active.  Cells keep their
    -- absolute index in `state.cells` (the basis for cellColorClass)
    -- so colour stripes don't shift when sections expand/collapse.
    indexedCells = mapWithIndex (\i c -> { idx: i, cell: c }) state.cells
    cellsInSection sec =
      Array.filter (\e -> cellSection e.cell == sec) indexedCells
    renderSection sec label =
      let cs = cellsInSection sec
          countLabel = case Array.length cs of
            0 -> ""
            n -> " (" <> show n <> ")"
      in
        [ HH.div
            [ HP.class_ (H.ClassName ("cells-section-header cells-section-" <> label)) ]
            [ HH.text (label <> countLabel) ]
        ]
        <> map (\e -> renderCellRow state e.idx e.cell) cs

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
        , case c.author of
            Just a -> HH.span
              [ HP.class_ (H.ClassName "cell-author-dot")
              , HP.title ("From " <> a)
              ]
              []
            Nothing -> HH.text ""
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
            [ HP.class_ (H.ClassName "promote-cell-btn")
            , HE.onClick \_ -> PromoteCellToCode c.id
            , HP.title "Save cell — append source to composition and remove this cell"
            ]
            [ HH.text "↩" ]
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
    Editor.MoveRequested -> PromoteCellToCode cid

-- | Hylograph pane.  Reserved for the upcoming pattern visualiser
-- | (Asteroids/Battlezone vector aesthetic).  Placeholder until that
-- | lands — the previous reference-panel content (Vocabulary, Mini-
-- | notation, Replies) has been promoted to top-level panes of its
-- | own, addressable via Cmd-3..5.
renderHylographColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderHylographColumn _ =
  HH.section [ HP.class_ (H.ClassName "pane pane-hylograph") ]
    [ HH.div [ HP.class_ (H.ClassName "hylograph-placeholder") ]
        [ HH.div [ HP.class_ (H.ClassName "hylograph-placeholder-title") ]
            [ HH.text "Hylograph" ]
        , HH.div [ HP.class_ (H.ClassName "hylograph-placeholder-body muted") ]
            [ HH.text "Pattern visualiser coming soon." ]
        ]
    ]

-- | Replies pane — per-cell most-recent reply from the daemon, plus
-- | the most recent composition fire's per-statement results.
-- | Was a tab inside Hylograph; promoted to a top-level pane (Cmd-3)
-- | so you can keep an eye on firings without displacing the editor.
renderRepliesColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderRepliesColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-replies") ]
    ( compositionSection <> cellsSection )
  where
  compositionSection =
    if Array.null state.compositionFireLines
      then []
      else
        [ HH.div [ HP.class_ (H.ClassName "replies-section") ]
            ( [ HH.div [ HP.class_ (H.ClassName "replies-section-header") ]
                  [ HH.text "▶ composition" ]
              ] <> map renderFireLine state.compositionFireLines
            )
        ]
  cellsSection =
    [ HH.div [ HP.class_ (H.ClassName "replies-section") ]
        ( [ HH.div [ HP.class_ (H.ClassName "replies-section-header") ]
              [ HH.text "cells" ]
          ] <> Array.catMaybes (mapWithIndex maybeRow state.cells)
        )
    ]
  maybeRow idx c =
    if c.kind == "expr" then Just (renderHylographRow state idx c) else Nothing

-- | One row in the composition fire results — line number, source
-- | preview, and the daemon's reply (or transport error) coloured
-- | green for success, red for failure.
renderFireLine
  :: forall m
   . { lineNum :: Int, source :: String, reply :: Either String String }
  -> H.ComponentHTML Action Slots m
renderFireLine r =
  let
    cls = case r.reply of
      Right _ -> "replies-fire-row replies-fire-ok"
      Left _ -> "replies-fire-row replies-fire-err"
    replyText = case r.reply of
      Right s -> s
      Left e -> e
  in
    HH.div [ HP.class_ (H.ClassName cls) ]
      [ HH.span [ HP.class_ (H.ClassName "replies-fire-linenum") ]
          [ HH.text (show r.lineNum) ]
      , HH.span [ HP.class_ (H.ClassName "replies-fire-source") ]
          [ HH.text r.source ]
      , HH.pre [ HP.class_ (H.ClassName "replies-fire-reply") ]
          [ HH.text replyText ]
      ]

-- | Vocabulary pane — devices and bindings parsed from purerl-tidal's
-- | setup/*.tidal files.  Browsable reference for the live-coder.
renderVocabularyColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderVocabularyColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-vocabulary") ]
    [ renderVocabularyBody state ]

renderVocabularyBody :: forall m. State -> H.ComponentHTML Action Slots m
renderVocabularyBody state =
  let CV.Vocabulary v = state.vocabulary
  in case v.setupFiles of
       [] ->
         HH.div [ HP.class_ (H.ClassName "vocabulary-empty") ]
           [ HH.text "No setup files found. Set $CALYPSO_TIDAL_SETUP_DIR or drop *.tidal files into the default purerl-tidal/setup/ directory." ]
       sfs ->
         HH.div [ HP.class_ (H.ClassName "vocabulary-list") ]
           (map renderSetupFile sfs)

-- | Mini-notation pane — operator primer (Primer.renderMiniNotation
-- | is the lifted markup; this just wraps it in a pane shell).
renderMiniNotationColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderMiniNotationColumn _ =
  HH.section [ HP.class_ (H.ClassName "pane pane-mini-notation") ]
    [ Primer.renderMiniNotation ]

-- | Config pane — read-only inspector for purerl-tidal's runtime
-- | state.  Pulls a JSON snapshot via the `state` WS verb (which
-- | reads from the StateBus ETS table on the server).  Refresh is
-- | manual via the button: state changes happen on every cell-fire,
-- | but the pane shouldn't repaint on every event — that's noise.
-- | Voice Cells column — prototype of the voice-oriented redesign
-- | sketched in `docs/voice-cells-design.md`.
-- |
-- | Two zones:
-- |   - `config` (top, never pivoted) holds rig-config cells:
-- |     `bind` / `unbind` / `midi-device` / `fh2-envelope` / `fh2-gate`
-- |     declarations. These set up the rig; not music.
-- |   - `music` (below) holds the playable cells (`<name> "<pat>"`,
-- |     `<name> :<expr>`, `fh2-shape`, `bpm`, `hush`). Each rendered
-- |     as a card showing the voice name + a body preview. Click to
-- |     fire (uses the same `FireCell` action as the cells column).
-- |
-- | Pure read of `state.cells` — no separate parser yet. Visual
-- | encoding (kind=shape, bundle=color, machine=border) is on the
-- | roadmap but starts here as a uniform card with name-derived
-- | color tinting.
renderVoiceCellsColumn :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderVoiceCellsColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-voice-cells") ]
    [ HH.div [ HP.class_ (H.ClassName "voice-cells-canvas") ]
        (renderCanvas state)
    ]

-- | Walk all cells in original order; emit one of:
-- |   - lone music card (no colour)
-- |   - music stack (collapsed or fanned) at first-encountered position
-- |   - config stack (synthetic, contains all SecConfig + SecVoices
-- |     cells; rendered at first config-cell position)
-- | Subsequent members of an already-rendered stack are skipped.
-- | Cards bigger than v3 — wider, taller body, more breathing room.
renderCanvas
  :: forall m. MonadAff m
  => State
  -> Array (H.ComponentHTML Action Slots m)
renderCanvas state =
  let
    isConfigCell c =
      let sec = cellSection c in sec == SecConfig || sec == SecVoices
    configCells = Array.filter isConfigCell state.cells
    walk
      :: Array CellRec
      -> Set Int                    -- music-stack colours already rendered
      -> Boolean                    -- config stack already rendered?
      -> Array (H.ComponentHTML Action Slots m)
    walk remaining renderedStacks renderedConfig = case Array.uncons remaining of
      Nothing -> []
      Just { head: c, tail: rest }
        | isConfigCell c ->
            if renderedConfig
              then walk rest renderedStacks renderedConfig
              else renderConfigStack state configCells
                Array.: walk rest renderedStacks true
        | otherwise -> case cellInColor state.stackOrder c.id of
            Nothing ->
              renderVoiceCard state CardLone c
                Array.: walk rest renderedStacks renderedConfig
            Just color
              | Set.member color renderedStacks ->
                  walk rest renderedStacks renderedConfig
              | otherwise ->
                  let
                    -- Render in stackOrder (front first).  Look up each
                    -- cellId in the cell list to get the CellRec.
                    cellsById = Map.fromFoldable (map (\c2 -> Tuple c2.id c2) state.cells)
                    orderedIds = fromMaybe [] (Map.lookup color state.stackOrder)
                    stackCells = Array.mapMaybe (\cid -> Map.lookup cid cellsById) orderedIds
                    rendered =
                      if state.fannedStack == Just color
                        then renderFannedMusicStack state color stackCells
                        else renderCollapsedMusicStack state color stackCells
                  in
                    rendered Array.: walk rest (Set.insert color renderedStacks) renderedConfig
  in
    walk state.cells Set.empty false

-- | A collapsed music stack: cards overlap with only the front fully
-- | visible.  No toolbar — header click on the front fans, header
-- | click on a back card brings it forward, header click in fanned
-- | view restacks (handled in HeaderClick).
renderCollapsedMusicStack
  :: forall m. MonadAff m
  => State
  -> Int                           -- color
  -> Array CellRec                 -- in stack order, front first
  -> H.ComponentHTML Action Slots m
renderCollapsedMusicStack state color cells =
  let
    total = Array.length cells
    -- (total-1) cards behind, each peeking ~22px (header row),
    -- plus the front card in full (front-card height ~140px).
    stackHeightPx = (total - 1) * 22 + 140
  in
    HH.div
      [ HP.class_ (H.ClassName ("voice-stack stack-color-" <> show color))
      , HP.style ("height: " <> show stackHeightPx <> "px;")
      ]
      (mapWithIndex (renderStackedCard state total) cells)

-- | A fanned music stack: cards laid out in a grid, each fully
-- | visible.  Restack happens via HeaderClick on any card.
renderFannedMusicStack
  :: forall m. MonadAff m
  => State
  -> Int
  -> Array CellRec
  -> H.ComponentHTML Action Slots m
renderFannedMusicStack state color cells =
  HH.div
    [ HP.class_ (H.ClassName ("voice-stack voice-stack-fanned stack-color-" <> show color)) ]
    [ HH.div [ HP.class_ (H.ClassName "voice-stack-fan-grid") ]
        (map (renderVoiceCard state CardFanned) cells)
    ]

-- | Config cells form a synthetic always-present stack.  Rendered
-- | inline with the music stacks (no separate zone).  Visually
-- | distinct via .voice-stack-config (dashed accent on the header).
renderConfigStack
  :: forall m. MonadAff m
  => State
  -> Array CellRec
  -> H.ComponentHTML Action Slots m
renderConfigStack state cells =
  if state.configStackFanned
    then
      HH.div
        [ HP.class_ (H.ClassName "voice-stack voice-stack-fanned voice-stack-config") ]
        [ HH.div [ HP.class_ (H.ClassName "voice-stack-fan-grid") ]
            (map (renderVoiceCard state CardConfigFanned) cells)
        ]
    else
      let
        total = Array.length cells
        stackHeightPx = (total - 1) * 22 + 140
      in
        HH.div
          [ HP.class_ (H.ClassName "voice-stack voice-stack-config")
          , HP.style ("height: " <> show stackHeightPx <> "px;")
          ]
          (mapWithIndex (renderStackedConfigCard state total) cells)

-- | One card inside a collapsed music stack.  Index 0 is the front
-- | (fully visible at the bottom of the container); higher indices
-- | recede upward, peeking only their header strip (~22px).
renderStackedCard
  :: forall m. MonadAff m
  => State
  -> Int                           -- total cards in stack
  -> Int                           -- this card's index (0 = front)
  -> CellRec
  -> H.ComponentHTML Action Slots m
renderStackedCard state total idx c =
  let
    isFront = idx == 0
    topPx = (total - 1 - idx) * 22
    zIdx = total - idx
    cardKind = if isFront then CardStackedFront else CardStackedBehind
  in
    HH.div
      [ HP.class_ (H.ClassName "voice-card-stacked-wrapper")
      , HP.style
          ( "top: " <> show topPx <> "px;"
              <> "z-index: " <> show zIdx <> ";"
          )
      ]
      [ renderVoiceCard state cardKind c ]

-- | One card inside the (collapsed) config stack — same geometry as
-- | renderStackedCard but with config-flavoured CardKind so the
-- | renderVoiceCard branch suppresses the picker etc.
renderStackedConfigCard
  :: forall m. MonadAff m
  => State
  -> Int
  -> Int
  -> CellRec
  -> H.ComponentHTML Action Slots m
renderStackedConfigCard state total idx c =
  let
    isFront = idx == 0
    topPx = (total - 1 - idx) * 22
    zIdx = total - idx
    cardKind = if isFront then CardConfigFront else CardConfigBehind
  in
    HH.div
      [ HP.class_ (H.ClassName "voice-card-stacked-wrapper")
      , HP.style
          ( "top: " <> show topPx <> "px;"
              <> "z-index: " <> show zIdx <> ";"
          )
      ]
      [ renderVoiceCard state cardKind c ]

-- | Card-rendering variants. Each maps to a distinct CSS shape +
-- | feature set so renderVoiceCard can stay one function.
data CardKind
  = CardLone               -- music card, not in a stack
  | CardStackedFront       -- music card, front of a collapsed stack
  | CardStackedBehind      -- music card, behind in a collapsed stack
  | CardFanned             -- music card, in a fanned stack
  | CardConfigFront        -- config card, front of (collapsed) config stack
  | CardConfigBehind       -- config card, behind in config stack
  | CardConfigFanned       -- config card, fanned

derive instance Eq CardKind

-- | The card itself.  Three zones: header (stack-coloured background
-- | with BLACK text — playing-card title-bar look — type icon + name
-- | + colour-swatch trigger), body (expression preview), footer (cue
-- | + play).  Behind-cards in a collapsed stack render header-only;
-- | config cards skip the picker + cue (config is rig setup, not
-- | performance).
-- |
-- | Header click handler is wired on every card; HeaderClick action
-- | resolves to bring-to-front / fan / restack based on context
-- | (handled in handleAction so the render stays declarative).
renderVoiceCard
  :: forall m. MonadAff m
  => State
  -> CardKind
  -> CellRec
  -> H.ComponentHTML Action Slots m
renderVoiceCard state kind c =
  let
    -- mvoice override (set in modal header) takes precedence over the
    -- heuristic source-extracted name.  Same resolution rule as
    -- renderEditingModal — keeps small card and modal in sync.
    voiceName = fromMaybe (extractVoiceName c.source)
                          (Map.lookup c.id state.cellMvoice)
    bodyPreview = previewBody c.source
    color = cellInColor state.stackOrder c.id
    isConfig = kind == CardConfigFront || kind == CardConfigBehind || kind == CardConfigFanned
    isCompact = kind == CardStackedBehind || kind == CardConfigBehind
    colorClass =
      if isConfig then " stack-config"
      else case color of
        Just n -> " stack-color-" <> show n
        Nothing -> " stack-color-none"
    kindClass = case kind of
      CardLone -> " voice-card-lone"
      CardStackedFront -> " voice-card-front"
      CardStackedBehind -> " voice-card-compact"
      CardFanned -> " voice-card-fanned"
      CardConfigFront -> " voice-card-front"
      CardConfigBehind -> " voice-card-compact"
      CardConfigFanned -> " voice-card-fanned"
    isPickerOpen = state.colorPickerOpen == Just c.id
    typeIcon = inferTypeIcon c.source
  in
    HH.div
      [ HP.class_
          ( H.ClassName
              ("voice-card-v2" <> colorClass <> kindClass)
          )
      ]
      ( [ HH.div
            [ HP.class_ (H.ClassName "voice-card-header")
            , HE.onClick \_ -> HeaderClick c.id
            , HP.title (case kind of
                CardLone -> "lone card — assign a colour to stack it"
                CardStackedFront -> "click to fan the stack"
                CardStackedBehind -> "click to bring this card to the front"
                CardFanned -> "click to restack"
                CardConfigFront -> "click to fan config"
                CardConfigBehind -> "click to bring this card to the front"
                CardConfigFanned -> "click to restack config")
            ]
            [ HH.span [ HP.class_ (H.ClassName "voice-card-icon") ]
                [ HH.text typeIcon ]
            , HH.span [ HP.class_ (H.ClassName "voice-card-name") ]
                [ HH.text voiceName ]
            ]
        -- Colour swatch is a SIBLING of the header (not a descendant)
        -- so its click doesn't bubble up to the header's HeaderClick
        -- handler.  Positioned absolutely at top-right via CSS.
        -- Suppressed for config cards (they aren't user-stackable).
        ] <> (if isConfig then [] else
              [ HH.button
                  [ HP.class_ (H.ClassName "voice-card-swatch")
                  , HE.onClick \_ ->
                      if isPickerOpen then CloseColorPicker
                      else OpenColorPicker c.id
                  , HP.title "pick a stack colour"
                  ]
                  [ HH.text "●" ]
              ])
        <> (if isCompact then [] else
            [ HH.div
                [ HP.class_ (H.ClassName "voice-card-body")
                , HE.onClick \_ -> OpenEditor c.id
                , HP.title "click to edit"
                ]
                [ HH.text bodyPreview ]
            , HH.div [ HP.class_ (H.ClassName "voice-card-footer") ]
                ( if isConfig
                    then
                      [ HH.button
                          [ HP.class_ (H.ClassName "voice-card-btn voice-card-play")
                          , HE.onClick \_ -> FireCell c.id c.source
                          , HP.title "fire this config statement"
                          ]
                          [ HH.text "▶" ]
                      ]
                    else
                      [ HH.button
                          [ HP.class_ (H.ClassName "voice-card-btn voice-card-cue")
                          , HE.onClick \_ -> FireCell c.id c.source
                          , HP.title "cue (compile-armed in future; fires immediately today)"
                          ]
                          [ HH.text "cue" ]
                      , HH.button
                          [ HP.class_ (H.ClassName "voice-card-btn voice-card-play")
                          , HE.onClick \_ -> FireCell c.id c.source
                          , HP.title "play (fire immediately)"
                          ]
                          [ HH.text "▶" ]
                      ]
                )
            ])
        <> (if isPickerOpen && not isConfig
              then [ renderColorPicker c.id color ]
              else [])
      )

-- | 9-swatch popover.  3×3 grid; first cell is "no stack" (clears the
-- | assignment), the other 8 are stack colours.  Current colour gets
-- | a subtle highlight ring.  Clicking outside the picker doesn't
-- | dismiss yet — click the swatch trigger again, or pick a colour.
renderColorPicker
  :: forall m. MonadAff m
  => String                        -- cellId
  -> Maybe Int                     -- current color (Nothing = lone)
  -> H.ComponentHTML Action Slots m
renderColorPicker cellId current =
  HH.div [ HP.class_ (H.ClassName "voice-card-picker") ]
    ( [ swatch Nothing ]
        <> map (\n -> swatch (Just n)) (Array.range 1 8)
    )
  where
    swatch :: Maybe Int -> H.ComponentHTML Action Slots m
    swatch n =
      let
        cls = case n of
          Just k -> "voice-picker-swatch stack-color-" <> show k
          Nothing -> "voice-picker-swatch stack-color-none"
        isCurrent = n == current
        markedCls = if isCurrent then cls <> " voice-picker-current" else cls
      in
        HH.button
          [ HP.class_ (H.ClassName markedCls)
          , HE.onClick \_ -> SetCardColor cellId n
          , HP.title (case n of
              Nothing -> "no stack (lone card)"
              Just k -> "stack " <> show k)
          ]
          [ HH.text (case n of
              Nothing -> "∅"
              Just _ -> "") ]

-- | Modal pop-out editor.  When `editingCard = Just id`, renders a
-- | dim backdrop + a 3×-scale card on top, hosting the existing
-- | CodeMirror Editor component.  The original small card stays in
-- | place underneath (probably hidden by the overlay) — keystrokes
-- | mirror back to it via Editor.Changed → CellChanged so a commit
-- | from the modal is just "fire the cell, then close".
-- |
-- | Backdrop click = cancel.  Cmd-Enter inside the editor → Submitted
-- | → CommitEdit.  An error/reply scaffold is in the layout but inert
-- | until cue/compile semantics arrive.
renderEditingModal
  :: forall m. MonadAff m
  => State -> H.ComponentHTML Action Slots m
renderEditingModal state = case state.editingCard of
  Nothing -> HH.text ""
  Just cellId -> case Array.find (\c -> c.id == cellId) state.cells of
    Nothing -> HH.text ""
    Just c ->
      let
        voiceName = extractVoiceName c.source
        -- The mvoice the cell will install into when Play is pressed.
        -- Override via the small input in the modal header; falls back
        -- to the heuristic-extracted first identifier from the source.
        mvoice = fromMaybe voiceName (Map.lookup c.id state.cellMvoice)
        typeIcon = inferTypeIcon c.source
        color = cellInColor state.stackOrder c.id
        sec = cellSection c
        isConfig = sec == SecConfig || sec == SecVoices
        colorClass =
          if isConfig then " stack-config"
          else case color of
            Just n -> " stack-color-" <> show n
            Nothing -> " stack-color-none"
      in
        HH.div [ HP.class_ (H.ClassName "voice-edit-overlay") ]
          [ -- Backdrop is a SIBLING of the modal, decorative only:
            -- pointer-events: none lets wheel scroll and clicks reach
            -- the columns underneath (vocabulary / mini-notation /
            -- config) so you can consult them while editing.  Close
            -- via × button, Esc, or commit (cue / play / Cmd-Enter).
            HH.div
              [ HP.class_ (H.ClassName "voice-edit-backdrop") ]
              []
          , HH.div
              [ HP.class_
                  ( H.ClassName
                      ("voice-edit-modal voice-card-v2" <> colorClass)
                  )
              ]
              [ HH.div [ HP.class_ (H.ClassName "voice-card-header") ]
                  [ HH.span [ HP.class_ (H.ClassName "voice-card-icon") ]
                      [ HH.text typeIcon ]
                  -- Mvoice input: small text field showing the
                  -- purerl-tidal binding name the cell installs
                  -- into.  Default = extractVoiceName(source);
                  -- editable inline.  Empty value clears the
                  -- override (falls back to the default).
                  , HH.input
                      [ HP.class_ (H.ClassName "voice-edit-mvoice")
                      , HP.value mvoice
                      , HP.title "mvoice — the binding to install this cell's pattern into.  Commit on blur or Enter."
                      -- onValueChange fires on commit (blur/Enter), not
                      -- every keystroke.  This avoids the controlled-
                      -- input race where Halogen re-renders mid-typing
                      -- and snaps HP.value back, eating characters.
                      -- Same pattern the topbar BPM widget uses.
                      , HE.onValueChange \v -> UpdateCellMvoice c.id v
                      ]
                  , HH.button
                      [ HP.class_ (H.ClassName "voice-edit-close")
                      , HE.onClick \_ -> CloseEditor
                      , HP.title "close (Esc)"
                      ]
                      [ HH.text "×" ]
                  ]
              , HH.div [ HP.class_ (H.ClassName "voice-edit-body") ]
                  [ HH.slot _editorModal unit Editor.component
                      { initialDoc: c.source
                      , tag: "voice-edit"
                      , vocabulary: state.completions
                      }
                      (modalEditorOutput c.id)
                  ]
              -- Per-card history — sits directly under the editor with
              -- no separator, so the live pattern flows visually into
              -- the version log.  Most-recent first; the row at the
              -- top is the currently-armed entry (highlighted with a
              -- ▶ pip); subsequent rows fade to near-black via the
              -- opacity gradient (steeper than the original — Andrew's
              -- request).  Click any → load body + re-arm (module's
              -- still in BEAM memory, so cache hit, instant).
              , let history = fromMaybe [] (Map.lookup c.id state.cellHistory)
                    armedMod = Map.lookup c.id state.armedModule
                in if Array.null history
                     then HH.text ""
                     else HH.div [ HP.class_ (H.ClassName "voice-edit-history") ]
                       (Array.mapWithIndex
                          (\idx h ->
                            let isArmed = Just h.modul == armedMod
                                cls = "voice-edit-history-row"
                                  <> if isArmed then " is-armed" else ""
                            in HH.div
                                 [ HP.class_ (H.ClassName cls)
                                 , HP.style ("opacity: " <> historyOpacity idx)
                                 , HP.title h.modul
                                 , HE.onClick \_ -> LoadHistoryEntry c.id h.body h.modul
                                 ]
                                 [ HH.span [ HP.class_ (H.ClassName "voice-edit-history-marker") ]
                                     [ HH.text (if isArmed then "▶" else " ") ]
                                 , HH.span [ HP.class_ (H.ClassName "voice-edit-history-body") ]
                                     [ HH.text h.body ]
                                 ])
                          history)
              -- Reply / status line — sits just above Cue/Play so the
              -- relationship is visually direct: "this is what the
              -- last commit returned".  Compact (single-row when the
              -- text fits); compile errors that span multiple lines
              -- still wrap and grow the area as needed.  "compiling…"
              -- placeholder while a cue is in flight.
              , HH.div [ HP.class_ (H.ClassName "voice-edit-replies") ]
                  ( if Set.member c.id state.cuePending
                      then
                        [ HH.span
                            [ HP.class_ (H.ClassName "voice-edit-pending") ]
                            [ HH.text "compiling…" ]
                        ]
                      else case Map.lookup c.id state.cellResults of
                        Just reply ->
                          [ HH.pre
                              [ HP.class_ (H.ClassName "voice-edit-reply-text") ]
                              [ HH.text reply ]
                          ]
                        Nothing ->
                          [ HH.span
                              [ HP.class_ (H.ClassName "voice-edit-replies-empty") ]
                              [ HH.text " " ]  -- empty placeholder; no "no replies yet" stub
                          ]
                  )
              , HH.div [ HP.class_ (H.ClassName "voice-card-footer voice-edit-footer") ]
                  ( if isConfig
                      then
                        -- Config cards keep the legacy fire path —
                        -- they're not part of the cue/compile pipeline.
                        [ HH.button
                            [ HP.class_ (H.ClassName "voice-card-btn voice-card-play")
                            , HE.onClick \_ -> CommitEdit c.id c.source
                            , HP.title "fire this config statement (Cmd-Enter)"
                            ]
                            [ HH.text "▶" ]
                        ]
                      else
                        -- Music cards: PR2 cue/play-armed flow.  Cue
                        -- compiles + hot-loads on the backend; Play
                        -- enables once a module is armed and invokes it.
                        let armed = Map.lookup c.id state.armedModule
                            playEnabled = isJust armed
                            cueInFlight = Set.member c.id state.cuePending
                        in
                        [ HH.button
                            ( [ HP.class_
                                  ( H.ClassName
                                      ( "voice-card-btn voice-card-cue"
                                          <> if cueInFlight then " is-disabled" else ""
                                      )
                                  )
                              , HP.title
                                  ( if cueInFlight
                                      then "compile in progress"
                                      else "cue — compile + hot-load this cell on the backend"
                                  )
                              , HP.disabled cueInFlight
                              ]
                              <> if cueInFlight then [] else
                                   [ HE.onClick \_ -> CueCell c.id c.source ]
                            )
                            [ HH.text (if cueInFlight then "…" else "cue") ]
                        , HH.button
                            ( [ HP.class_
                                  ( H.ClassName
                                      ( "voice-card-btn voice-card-play"
                                          <> if playEnabled then "" else " is-disabled"
                                      )
                                  )
                              , HP.title
                                  ( case armed of
                                      Just m  -> "play armed module " <> m
                                      Nothing -> "play — disabled until a successful cue"
                                  )
                              , HP.disabled (not playEnabled)
                              ]
                              <> case armed of
                                   Just m  -> [ HE.onClick \_ -> PlayArmed c.id mvoice m ]
                                   Nothing -> []
                            )
                            [ HH.text "▶" ]
                        ]
                  )
              ]
          ]
  where
    -- The modal's editor and the small card share a cell id, so we
    -- route Changed through the existing CellChanged handler — that's
    -- the mirror.  Submitted (Cmd-Enter) commits and closes.
    modalEditorOutput cid = case _ of
      Editor.Changed src -> CellChanged cid src
      Editor.Submitted src -> CommitEdit cid src
      Editor.AcceptHunkO pid idx -> AcceptHunk pid idx
      Editor.RejectHunkO pid idx -> RejectHunk pid idx
      Editor.MoveRequested -> CloseEditor   -- Mod-Shift-Enter: just close

-- | Cheap heuristic: pick a glyph based on the first verb/word of
-- | the cell's source.  Type icons are vector-graphics-y placeholders
-- | until we wire real binding info from the dispatcher snapshot.
-- | Reverse lookup: which stack colour (if any) does a cellId belong
-- | to?  Walks the small stackOrder map; up to 8 entries so cheap.
cellInColor :: Map Int (Array String) -> String -> Maybe Int
cellInColor m cellId =
  Array.findMap
    (\(Tuple n cells) -> if Array.elem cellId cells then Just n else Nothing)
    (Map.toUnfoldable m :: Array (Tuple Int (Array String)))

-- | Remove a cellId from every stack in the map, dropping any stack
-- | that becomes empty.  Used when re-assigning a card's colour.
removeFromAllStacks :: String -> Map Int (Array String) -> Map Int (Array String)
removeFromAllStacks cellId =
  Map.mapMaybe
    (\arr ->
      let arr' = Array.filter (_ /= cellId) arr
      in case Array.length arr' of
           0 -> Nothing
           _ -> Just arr')

inferTypeIcon :: String -> String
inferTypeIcon src =
  let lines = Str.split (Pattern "\n") src
      firstStmt = Array.find (\l -> not (Str.null (stripLineComment l))) lines
      firstWord = case firstStmt of
        Nothing -> ""
        Just l -> case Array.filter (not <<< Str.null) (Str.split (Pattern " ") (stripLineComment l)) of
          ws -> fromMaybe "" (Array.head ws)
  in case firstWord of
    "bind" -> "⚙"
    "unbind" -> "⚙"
    "midi-device" -> "⌬"
    "fh2-envelope" -> "✦"
    "fh2-gate" -> "✦"
    "fh2-trigger" -> "⚡"
    "fh2-shape" -> "⌇"
    "hush" -> "■"
    "bpm" -> "♩"
    -- Music cells: glyph by clues in the body.
    _ ->
      let body = Str.toLower src
      in if Str.contains (Pattern "sine") body
         || Str.contains (Pattern "saw") body
         || Str.contains (Pattern "tri") body
         || Str.contains (Pattern "square") body
         || Str.contains (Pattern "cosine") body
         || Str.contains (Pattern ":slow") body
         then "◇"      -- LFO/modulator
         else if Str.contains (Pattern "midi-cc-cont") body
                 || Str.contains (Pattern "cv-cont") body
              then "⬡"  -- continuous CC
              else "▲"   -- default: melodic source / trigger

-- | First word of the first non-comment, non-empty line.  For music
-- | cells this is the voice name (`bass`, `kick`, `bass-cutoff`); for
-- | config cells it's the verb (`bind`, `midi-device`, …).
extractVoiceName :: String -> String
extractVoiceName src =
  let lines = Str.split (Pattern "\n") src
      firstStmt = Array.find (\l -> not (Str.null (stripLineComment l))) lines
  in case firstStmt of
    Nothing -> "(empty)"
    Just l ->
      let words = Array.filter (not <<< Str.null) (Str.split (Pattern " ") (stripLineComment l))
      in fromMaybe "?" (Array.head words)

-- | Compact body preview for the card face.  Strips comments, joins
-- | non-empty lines with a separator, truncates with an ellipsis.
previewBody :: String -> String
previewBody src =
  let lines = Array.filter (not <<< Str.null)
                (map stripLineComment (Str.split (Pattern "\n") src))
      joined = Str.joinWith " · " lines
  in if Str.length joined > 80 then Str.take 77 joined <> "…" else joined


renderConfigColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderConfigColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-config") ]
    [ HH.div [ HP.class_ (H.ClassName "config-toolbar") ]
        [ HH.button
            [ HP.class_ (H.ClassName "config-refresh-btn")
            , HE.onClick \_ -> RefreshConfigState
            , HP.title "Re-fetch state from purerl-tidal"
            ]
            [ HH.text "↻ refresh" ]
        ]
    , HH.pre [ HP.class_ (H.ClassName "config-body") ]
        [ HH.text body ]
    ]
  where
    body = case state.configSnapshot of
      Nothing -> "(no snapshot yet — click ↻ refresh)"
      Just s -> prettyPrintJson s

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
