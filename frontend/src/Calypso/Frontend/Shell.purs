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
import Calypso.Frontend.FilePicker (pickJsonFile)
import Calypso.Frontend.Primer as Primer
import Calypso.Frontend.Vocabulary as Vocabulary
import Calypso.Frontend.WsClient as WsClient
import Calypso.Composition as Comp
import Calypso.Composition.Parser as Comp
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
type CellRec =
  { id :: String
  , kind :: String
  , source :: String
  , author :: Maybe String
  -- mvoice + tvoice live on the cell itself so they ride along with
  -- every save / hydrate round-trip.  Both Nothing on freshly-
  -- created cards; the renderer falls back to extractTvoice on the
  -- source.
  , mvoice :: Maybe String
  , tvoice :: Maybe String
  }

cellRecOf :: Cell -> CellRec
cellRecOf (Cell c) =
  { id: c.id, kind: c.kind, source: c.source, author: c.author
  , mvoice: c.mvoice, tvoice: c.tvoice
  }

cellOf :: CellRec -> Cell
cellOf c = Cell
  { id: c.id, kind: c.kind, source: c.source, form: false, author: c.author
  , mvoice: c.mvoice, tvoice: c.tvoice
  }

-- | Apply f to the cell whose id matches; leave others untouched.
-- | Used by the per-cell metadata edit handlers (mvoice, tvoice).
mapCellInList :: String -> (CellRec -> CellRec) -> Array CellRec -> Array CellRec
mapCellInList cellId f cells =
  fromMaybe cells do
    idx <- findIndex (_.id >>> (_ == cellId)) cells
    modifyAt idx f cells

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
  -- Tvoice category lookup, derived from the snapshot's `voices`
  -- array on each refresh.  Keyed by binding name; drives the type-
  -- color and glyph on Voice Cells cards.  Empty until first refresh
  -- — cards then render as TvUnknown until the first snapshot lands.
  , tvoiceTypes :: Map String TvoiceType
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
  , lastSyncedCells :: Map String { source :: String, kind :: String, mvoice :: Maybe String, tvoice :: Maybe String }
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
  , mvoiceOrder :: Map String (Array String)
                                      -- mvoice label → cellIds in
                                      -- stack order, front first.
                                      -- Absent → cells in this group
                                      -- render in original creation
                                      -- order.  Populated only when
                                      -- the user reorders via
                                      -- HeaderClick (bring-to-front).
  , fannedMvoice :: Maybe String      -- mvoice of the currently-
                                      -- fanned music stack, if any.
  , configStackFanned :: Boolean      -- config cells form their own
                                      -- pseudo-stack (always present);
                                      -- this tracks whether it's
                                      -- fanned out
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
  -- mvoice/tvoice now ride on each CellRec (see Calypso.Session.Cell)
  -- so they persist through hydrate/save round-trips.  No separate
  -- state maps needed.
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
  | WipeAndRestore                -- clear all cells, re-fire code pane
  | LoadWorkspace                 -- open file picker → POST /session/compile
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
  -- Voice Cells pane: fan-out / restack / bring-to-front via
  -- HeaderClick.  Stack assignment is by mvoice label (set via the
  -- modal header's mvoice input) — no separate color picker.
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
  | PlayArmed String String String          -- cellId, tvoiceName, moduleName
  | UpdateCellTvoice String String          -- cellId, new tvoice name (binding to dispatch into)
  | UpdateCellMvoice String String          -- cellId, new mvoice column label
  | NewVoiceCard                            -- creates a fresh empty Voice
                                            -- Cells card and pops it open
                                            -- in the modal editor.  Default
                                            -- mvoice/tvoice are blank — the
                                            -- pickers in the modal header
                                            -- prompt the user.
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
  , tvoiceTypes: Map.empty
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
  , mvoiceOrder: Map.empty
  , fannedMvoice: Nothing
  , configStackFanned: false
  , editingCard: Nothing
  , armedModule: Map.empty
  , cuePending: Set.empty
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
    -- Pull the rig snapshot so the tvoice picker + card colors have
    -- options on first paint.  No-op if the WS isn't open yet — the
    -- ↻ refresh button covers that case.
    handleAction RefreshConfigState
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
    -- topbar widget reflects what the rig actually thinks tempo is,
    -- and rebuilds the tvoice-type map so cards re-color from
    -- whatever bindings are currently registered.
    result <- evalSource "state"
    case result of
      Left err -> H.modify_ _ { configSnapshot = Just ("ERR: " <> err) }
      Right snap -> H.modify_ \s ->
        let s' = s
              { configSnapshot = Just snap
              , bpmDisplay = fromMaybe s.bpmDisplay (extractBpmFromSnapshot snap)
              }
        in s' { tvoiceTypes = recomputeTvoiceTypes s' }
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
    H.modify_ \s ->
      let s' = s { moduleSource = src }
      in s' { tvoiceTypes = recomputeTvoiceTypes s' }
    handleAction ScheduleCompile
  CellChanged id src -> do
    H.modify_ \s -> s { cells = updateCell id src s.cells }
    handleAction ScheduleCompile
  AddCell -> do
    H.modify_ \s ->
      let newId = "c" <> show s.nextCellId
          newCell = { id: newId, kind: "expr", source: "", author: Nothing, mvoice: Nothing, tvoice: Nothing }
      in s { cells = snoc s.cells newCell, nextCellId = s.nextCellId + 1 }
    handleAction ScheduleCompile
  NewVoiceCard -> do
    -- Creates an empty CellRec and immediately opens it in the
    -- editing modal.  No tvoice/mvoice override seeded — the pickers
    -- in the modal header prompt the user.  Card defaults to lone
    -- (no stack-color); column assignment happens via the existing
    -- color picker until drag-to-reparent ships.
    H.modify_ \s ->
      let newId = "c" <> show s.nextCellId
          newCell = { id: newId, kind: "expr", source: "", author: Nothing, mvoice: Nothing, tvoice: Nothing }
      in s
        { cells = snoc s.cells newCell
        , nextCellId = s.nextCellId + 1
        , editingCard = Just newId
        }
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
              newCell = { id: newId, kind: "expr", source: text, author: Nothing, mvoice: Nothing, tvoice: Nothing }
          in s { cells = snoc s.cells newCell, nextCellId = s.nextCellId + 1 }
        handleAction ScheduleCompile
      _ -> pure unit
  FireCell cellId src -> do
    -- Tidal-style fire: Mod-Enter on a cell sends each statement
    -- separately via /eval to the daemon (the daemon parses one
    -- statement per call). Replies are joined with newlines and
    -- land in cellResults; transport errors land in transportError.
    -- `cellStatements` runs the polysignal collapser, so multi-line
    -- polysignal blocks come through as single `polysignal <json>`
    -- statements rather than fragments.
    let stmts = cellStatements src
    if Array.null stmts
      then H.modify_ \s -> s
        { cellResults = Map.insert cellId "(no statements)" s.cellResults }
      else fireCellStatements cellId stmts
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
  LoadWorkspace -> do
    -- Open a browser file picker, read the chosen JSON, validate it
    -- decodes as a CompileRequest, and POST it to /session/compile.
    -- The server's replaceAll path swaps the in-memory state, persists
    -- to main/calypso-session.json, and broadcasts the snapshot to all
    -- subscribers (this client included).  Use this to swap workspaces
    -- without restarting the backend.
    picked <- H.liftAff pickJsonFile
    case picked of
      Left "cancelled" -> pure unit
      Left err -> H.modify_ _ { transportError = Just ("load: " <> err) }
      Right text -> case jsonParser text of
        Left err -> H.modify_ _ { transportError = Just ("load: bad JSON: " <> err) }
        Right j -> case CA.decode compileRequestCodec j of
          Left err -> H.modify_ _ { transportError = Just
            ("load: not a calypso-session.json: " <> CA.printJsonDecodeError err) }
          Right (CompileRequest req) -> do
            -- Push the loaded payload at the server's replaceAll endpoint
            -- (it updates in-memory state, persists, and broadcasts).
            result <- httpJson POST (backendUrl <> "/session/compile") text
            case result of
              Left err -> H.modify_ _ { transportError = Just ("load: " <> err) }
              Right resp -> do
                applyCompileResponse resp
                -- applyCompileResponse only refreshes "lastSynced" fields;
                -- the live moduleSource and cells need explicit replacement
                -- so a subsequent `▶ fire` walks the loaded composition,
                -- not the editor's prior content.
                let UserModule rm = req."module"
                    loadedCells = map cellRecOf req.cells
                H.modify_ \s -> s
                  { moduleSource = rm.source
                  , cells = loadedCells
                  , transportError = Nothing
                  , compositionStatus = Just "(workspace loaded — click ▶ fire to register on daemon)"
                  }
                _ <- H.tell _moduleEditor unit (Editor.ReplaceContent rm.source)
                pure unit
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
  HeaderClick cellId -> do
    s <- H.get
    case Array.find (\c -> c.id == cellId) s.cells of
      Nothing -> pure unit
      Just c ->
        let isConfig = let sec = cellSection c in sec == SecConfig || sec == SecVoices
        in if isConfig
             then H.modify_ _ { configStackFanned = not s.configStackFanned }
             else
               let mvoice = effectiveMvoice s c
                   groupCells = mvoiceGroupCells s mvoice
                   ordered = orderedMvoiceCells s mvoice groupCells
                   isFront = Array.head ordered == Just c
                   isAlone = Array.length ordered <= 1
               in if isAlone then pure unit
                  else if s.fannedMvoice == Just mvoice
                    -- Already fanned: any header click restacks.
                    then H.modify_ _ { fannedMvoice = Nothing }
                    else if isFront
                      -- Front of a collapsed stack: fan it out.
                      then H.modify_ _ { fannedMvoice = Just mvoice }
                      else
                        -- Back of a collapsed stack: bring to front.
                        let currentOrder = case Map.lookup mvoice s.mvoiceOrder of
                              Just ids -> ids
                              Nothing -> map _.id ordered
                            newOrder = Array.cons cellId
                              (Array.filter (_ /= cellId) currentOrder)
                        in H.modify_ _
                             { mvoiceOrder = Map.insert mvoice newOrder s.mvoiceOrder }
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
    -- `#` is preserved (sharp accidentals + Tidal param-attach), so
    -- this uses cellStatements not compositionStatements.
    let stmts = cellStatements src
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
  PlayArmed cellId tvoiceName moduleName -> do
    -- Install the previously-cued module's pattern into the named
    -- tvoice (binding) on the backend.  Backend looks up the binding
    -- registered for tvoiceName via `bind` and hands the loaded
    -- Pattern String to tidal_voice_sup:set_voice_pat.  Pattern
    -- starts firing through the rig immediately.
    result <- evalSource
      ("play-armed " <> tvoiceName <> " " <> moduleName)
    case result of
      Left err -> H.modify_ _ { transportError = Just err }
      Right reply ->
        H.modify_ \s -> s { cellResults = Map.insert cellId reply s.cellResults }
  UpdateCellTvoice cellId name -> do
    -- The tvoice name binds the cell's pattern to a purerl-tidal
    -- voice (set up via `bind`).  Empty string clears (defaults
    -- back to extractTvoice at fire time).  Stored on the cell
    -- itself so it survives hydrate/save round-trips.
    let trimmed = Str.trim name
        newVal = if Str.null trimmed then Nothing else Just trimmed
        updateOne c = c { tvoice = newVal }
    H.modify_ \s -> s { cells = mapCellInList cellId updateOne s.cells }
    handleAction ScheduleCompile
  UpdateCellMvoice cellId name -> do
    -- The mvoice is the user-assigned column label; no backend
    -- meaning.  Empty string clears (card falls back to displaying
    -- its tvoice as the column label).
    let trimmed = Str.trim name
        newVal = if Str.null trimmed then Nothing else Just trimmed
        updateOne c = c { mvoice = newVal }
    H.modify_ \s -> s { cells = mapCellInList cellId updateOne s.cells }
    handleAction ScheduleCompile
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
      cellsDirty = Array.filter cellChanged s.cells
      cellChanged c = case Map.lookup c.id s.lastSyncedCells of
        Just last ->
          last.source /= c.source
            || last.mvoice /= c.mvoice
            || last.tvoice /= c.tvoice
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
        (encodeCellPatch c)
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

-- | Encode a cell patch body for PATCH /session/cells/:id.  Always
-- | emits source + mvoice + tvoice so any of those fields changing
-- | round-trips through the server.  The empty-string sentinel is
-- | how the server hears "clear this field" (Maybe Nothing).
encodeCellPatch :: CellRec -> String
encodeCellPatch c =
  stringify $ AJ.fromObject $ Object.fromFoldable
    [ Tuple "source" (AJ.fromString c.source)
    , Tuple "mvoice" (AJ.fromString (fromMaybe "" c.mvoice))
    , Tuple "tvoice" (AJ.fromString (fromMaybe "" c.tvoice))
    ]

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
      ( map (\(Cell c) -> Tuple c.id
              { source: c.source, kind: c.kind
              , mvoice: c.mvoice, tvoice: c.tvoice
              }) r.cells )
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

-- | Strip both `--` and `#` line comments.  Used on module.source
-- | (the routing-grammar portion of the session), where `#` is a
-- | comment marker per `docs/composition-grammar.md`.  Distinct from
-- | `stripLineComment`, which is used on cell text where `#` is the
-- | Tidal-style parameter-attach operator and must be preserved.
stripModuleLineComment :: String -> String
stripModuleLineComment line =
  let dashCut = case Str.indexOf (Pattern "--") line of
        Just i -> Str.take i line
        Nothing -> line
      hashCut = case Str.indexOf (Pattern "#") dashCut of
        Just i -> Str.take i dashCut
        Nothing -> dashCut
  in Str.trim hashCut

-- | Cell taxonomy used by `cellSection` to drive rendering decisions.
-- | The `# config`/`# voices`/`# patterns` section markers were a
-- | feature of the legacy composition pane and are now inert; the
-- | ADT remains because cellSection still classifies cells by first
-- | word for card-styling decisions.  Phase 2b candidate for full
-- | replacement with a tvoice-driven classifier.
data Section
  = SecConfig
  | SecVoices
  | SecPatterns
  | SecDefault

derive instance eqSection :: Eq Section

-- | Parse the composition source into a flat array of statements.
-- | Strips `--` and `#` line comments (the new routing grammar treats
-- | both as comments), drops blank lines, and emits one entry per
-- | non-empty source line with its 1-based line number for error
-- | reporting.
compositionStatements
  :: String
  -> Array { lineNum :: Int, source :: String }
compositionStatements src =
  let lines = Str.split (Pattern "\n") src
      indexed = mapWithIndex
        (\i s -> { lineNum: i + 1, source: stripModuleLineComment s }) lines
      nonEmpty = Array.filter (\e -> not (Str.null (Str.trim e.source))) indexed
  in Comp.collapsePolySignalEntries nonEmpty

-- | Cell-text counterpart to `compositionStatements`. Strips only
-- | `--` line comments — `#` is the Tidal parameter-attach operator
-- | inside cell text, and also appears inside note tokens (`d#2`),
-- | so the module-level rule that treats `#` as a comment marker
-- | would break cell sources.
cellStatements
  :: String
  -> Array { lineNum :: Int, source :: String }
cellStatements src =
  let lines = Str.split (Pattern "\n") src
      indexed = mapWithIndex
        (\i s -> { lineNum: i + 1, source: stripLineComment s }) lines
      nonEmpty = Array.filter (\e -> not (Str.null (Str.trim e.source))) indexed
  in Comp.collapsePolySignalEntries nonEmpty

-- | Fire a list of statements in order against /eval.  Stops on the
-- | first error and reports the failing line; on full success reports
-- | the count.  Status lands in `compositionStatus`.
fireStatements
  :: forall o m
   . MonadAff m
  => Array { lineNum :: Int, source :: String }
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

-- | Fire a list of statements one at a time against /eval and stash
-- | the combined replies in `cellResults` for the given cell. Differs
-- | from `fireStatements` (composition-target) in two ways: per-cell
-- | UI state, and the daemon-frame discipline is identical (one
-- | statement per WS frame) so multi-line polysignal blocks reach
-- | purerl-tidal as their collapsed wire form without trailing-line
-- | contamination.
fireCellStatements
  :: forall o m
   . MonadAff m
  => String
  -> Array { lineNum :: Int, source :: String }
  -> H.HalogenM State Action Slots o m Unit
fireCellStatements cellId stmts = go [] stmts
  where
  go acc remaining = case Array.uncons remaining of
    Nothing ->
      let combined = Str.joinWith "\n" (Array.reverse acc)
      in H.modify_ \s -> s
           { cellResults = Map.insert cellId combined s.cellResults }
    Just { head: e, tail } -> do
      result <- evalSource e.source
      case result of
        Left err -> do
          H.modify_ _ { transportError = Just err }
          -- Surface the transport failure in the cell too so the user
          -- sees something — otherwise the cell looks idle.
          go (Array.cons ("transport: " <> err) acc) tail
        Right reply -> go (Array.cons reply acc) tail

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
        ( map (\(Cell c) -> Tuple c.id
                { source: c.source, kind: c.kind
                , mvoice: c.mvoice, tvoice: c.tvoice
                }) r.cells )
      -- Pull the highest-numbered cell from the snapshot so a fresh
      -- AddCell never collides with a pre-existing id.  Cell ids
      -- match `c<N>`; anything else is treated as 0 (still safe —
      -- max with the existing local counter keeps it monotonic).
      maxRemoteN = foldr max 0
        ( Array.mapMaybe (\(Cell c) -> parseCellNumber c.id) r.cells )
  H.modify_ \s ->
    let s' = s
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
    in s' { tvoiceTypes = recomputeTvoiceTypes s' }
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

-- | Tvoice category — the four-color taxonomy applied to bindings
-- | based on their first sink's destination/element.  Drives the
-- | type-color and glyph on Voice Cells cards so visual identity
-- | tracks "what kind of signal does this card emit" rather than
-- | "which mvoice column."  Envelope is reserved for a future
-- | user-assignable role tag (no SinkType for it today; ADSRs go
-- | out as continuous CV like LFOs do).
data TvoiceType
  = TvMidi
  | TvCV
  | TvGate
  | TvSample
  -- | Polysignal cells are autonomous: no incoming pattern, the FH-2
  -- | generates its own modulation/clocks/gates. The family carries
  -- | the short label rendered in the card-tvtype slot (lfo/clk/env/
  -- | euc/eucp/rnd). All families share a single header colour and a
  -- | double-border treatment to read as "this is not pattern-fed."
  | TvPolySignal Comp.PolyFamily
  | TvUnknown

derive instance eqTvoiceType :: Eq TvoiceType

-- | CSS class for a tvoice type — used in addition to the legacy
-- | stack-color-N class on `voice-card-v2`.  CSS rules under these
-- | selectors override the stack header background.
tvoiceTypeClass :: TvoiceType -> String
tvoiceTypeClass = case _ of
  TvMidi -> "tv-midi"
  TvCV -> "tv-cv"
  TvGate -> "tv-gate"
  TvSample -> "tv-sample"
  TvPolySignal _ -> "tv-polysignal"
  TvUnknown -> "tv-unknown"

-- | Compact label rendered in the corner of a card to disambiguate
-- | sub-types within a category (note vs. cc, pitch vs. mod, etc.).
-- | Empty for TvUnknown so unmapped tvoices don't get a misleading
-- | label.
tvoiceTypeLabel :: TvoiceType -> String
tvoiceTypeLabel = case _ of
  TvMidi -> "midi"
  TvCV -> "cv"
  TvGate -> "gate"
  TvSample -> "smp"
  TvPolySignal f -> polyFamilyShortLabel f
  TvUnknown -> ""

-- | 3-4 char family label for the card-tvtype corner badge. Picks the
-- | usual modular-synth-rack abbreviations so readers scanning the
-- | grid spot "lfo", "env", "clk" instantly without parsing the body.
polyFamilyShortLabel :: Comp.PolyFamily -> String
polyFamilyShortLabel = case _ of
  Comp.PFPolyLfo         -> "lfo"
  Comp.PFPolyClock       -> "clk"
  Comp.PFPolyEnv         -> "env"
  Comp.PFPolyEuclid      -> "euc"
  Comp.PFPolyEuclidPairs -> "eucp"
  Comp.PFPolyRand        -> "rnd"

-- | Pull `voices: [{name, signature, sinks}, ...]` out of a StateBus
-- | snapshot and classify each tvoice by the first sink's destKind +
-- | element.  Returns an empty map if the snapshot is unparseable or
-- | malformed.  Used by Voice Cells card rendering to color cards by
-- | binding type.
extractTvoiceTypes :: String -> Map String TvoiceType
extractTvoiceTypes raw = case jsonParser raw of
  Left _ -> Map.empty
  Right j -> fromMaybe Map.empty do
    obj <- AJ.toObject j
    voicesJ <- Object.lookup "voices" obj
    voices <- AJ.toArray voicesJ
    pure (Map.fromFoldable (Array.mapMaybe parseVoice voices))
  where
    parseVoice j = do
      obj <- AJ.toObject j
      nameJ <- Object.lookup "name" obj
      name <- AJ.toString nameJ
      sinksJ <- Object.lookup "sinks" obj
      sinks <- AJ.toArray sinksJ
      firstSink <- Array.head sinks
      sinkObj <- AJ.toObject firstSink
      destKindJ <- Object.lookup "destKind" sinkObj
      destKind <- AJ.toString destKindJ
      elementJ <- Object.lookup "element" sinkObj
      element <- AJ.toString elementJ
      pure (Tuple name (classifyTvoice destKind element))

    classifyTvoice :: String -> String -> TvoiceType
    classifyTvoice destKind element = case destKind, element of
      "ToMidi", _        -> TvMidi
      "ToGate", _        -> TvGate
      "ToES5",  _        -> TvGate
      "ToCV",   "Sample" -> TvSample
      "ToCV",   _        -> TvCV
      "ToESX",  _        -> TvCV
      _,        _        -> TvUnknown

-- | Parser-driven tvoice-type map: derive directly from the
-- | composition text in `module.source`.  The verb tells us the
-- | signal kind (`gate`, `cv`, `midi-*`); the device-decl tells us
-- | the device-type the binding targets; together they classify into
-- | a TvoiceType for card colouring.  Returns an empty map if the
-- | text doesn't parse — caller falls back to the snapshot path.
-- |
-- | This runs on every module-source change so the picker + card
-- | colours track the user's edits live, without waiting for a
-- | snapshot refresh.
extractTvoiceTypesFromComposition :: String -> Map String TvoiceType
extractTvoiceTypesFromComposition src = case Comp.parseComposition src of
  Left _ -> Map.empty
  Right (Comp.Composition stmts) ->
    let
      -- First pass: alias → device-type kind.  Used to classify CV
      -- bindings against destination (esx-8cv vs es9 etc.) when the
      -- type-color depends on it.
      deviceKinds = Map.fromFoldable
        (Array.mapMaybe deviceAliasKind stmts)
    in
      Map.fromFoldable (Array.mapMaybe (bindingType deviceKinds) stmts)
  where
    deviceAliasKind = case _ of
      Comp.StmtDevice (Comp.DevMidi    r) -> Just (Tuple r.alias "midi")
      Comp.StmtDevice (Comp.DevEs9     r) -> Just (Tuple r.alias "es9")
      Comp.StmtDevice (Comp.DevFh2     r) -> Just (Tuple r.alias "fh2")
      Comp.StmtDevice (Comp.DevYarns   r) -> Just (Tuple r.alias "yarns")
      Comp.StmtDevice (Comp.DevOsc     r) -> Just (Tuple r.alias "osc")
      Comp.StmtDevice (Comp.DevEs5     r) -> Just (Tuple r.alias "es5")
      Comp.StmtDevice (Comp.DevEsx8Gt  r) -> Just (Tuple r.alias "esx-8gt")
      Comp.StmtDevice (Comp.DevEsx8Cv  r) -> Just (Tuple r.alias "esx-8cv")
      Comp.StmtDevice (Comp.DevFhx8Gt  r) -> Just (Tuple r.alias "fhx-8gt")
      _ -> Nothing
    bindingType deviceKinds = case _ of
      Comp.StmtBinding (Comp.BindMidiNote   b) -> Just (Tuple b.name TvMidi)
      Comp.StmtBinding (Comp.BindMidiCc     b) -> Just (Tuple b.name TvMidi)
      Comp.StmtBinding (Comp.BindMidiCcCont b) -> Just (Tuple b.name TvMidi)
      Comp.StmtBinding (Comp.BindGate       b) -> Just (Tuple b.name TvGate)
      Comp.StmtBinding (Comp.BindCv         b) -> Just (Tuple b.name (cvType b.mode))
      Comp.StmtBinding (Comp.BindCvCont     b) -> Just (Tuple b.name TvCV)
      -- Polysignals: autonomous device configs. The alias names the
      -- bank that hosts the polysignal; tag it so the card carrying
      -- its block gets the polysignal colour + double-border.
      Comp.StmtDeviceConfig (Comp.PolySignalCfg cfg) ->
        Just (Tuple cfg.alias (TvPolySignal cfg.family))
      _ -> Nothing
    cvType = case _ of
      Comp.CvSampleMap -> TvSample
      _ -> TvCV

-- | Recompute tvoiceTypes from both sources.  Parser-derived entries
-- | (from `module.source` text) override snapshot entries when both
-- | name the same binding.  The snapshot path remains as a fallback
-- | for bindings registered on the rig but not in the user's text.
recomputeTvoiceTypes :: State -> Map String TvoiceType
recomputeTvoiceTypes s =
  let fromText = extractTvoiceTypesFromComposition s.moduleSource
      fromSnapshot = case s.configSnapshot of
        Nothing -> Map.empty
        Just raw -> extractTvoiceTypes raw
  in Map.union fromText fromSnapshot

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
            [ HP.class_ (H.ClassName "fire-btn")
            , HE.onClick \_ -> LoadWorkspace
            , HP.title "Load a calypso-session.json from disk"
            ]
            [ HH.text "↥ load…" ]
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
    [ HH.div [ HP.class_ (H.ClassName "voice-cells-toolbar") ]
        [ HH.button
            [ HP.class_ (H.ClassName "voice-cells-new")
            , HE.onClick \_ -> NewVoiceCard
            , HP.title "Create a new Voice Cells card and open it for editing."
            ]
            [ HH.text "+ new card" ]
        ]
    , HH.div [ HP.class_ (H.ClassName "voice-cells-canvas") ]
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
    -- Group music cells by their effective mvoice.  Order of first
    -- appearance in state.cells determines column position; cards
    -- within a group obey mvoiceOrder if set, otherwise creation
    -- order (i.e. the order the cells appear in state.cells).
    walk
      :: Array CellRec
      -> Set String                 -- mvoices already rendered
      -> Boolean                    -- config stack already rendered?
      -> Array (H.ComponentHTML Action Slots m)
    walk remaining renderedMvoices renderedConfig = case Array.uncons remaining of
      Nothing -> []
      Just { head: c, tail: rest }
        | isConfigCell c ->
            if renderedConfig
              then walk rest renderedMvoices renderedConfig
              else renderConfigStack state configCells
                Array.: walk rest renderedMvoices true
        | otherwise ->
            let mvoice = effectiveMvoice state c
            in if Set.member mvoice renderedMvoices
                 then walk rest renderedMvoices renderedConfig
                 else
                   let
                     groupCells = mvoiceGroupCells state mvoice
                     stackCells = orderedMvoiceCells state mvoice groupCells
                     rendered =
                       if Array.length stackCells <= 1
                         then renderVoiceCard state CardLone c
                         else if state.fannedMvoice == Just mvoice
                           then renderFannedMusicStack state mvoice stackCells
                           else renderCollapsedMusicStack state mvoice stackCells
                   in
                     rendered Array.: walk rest (Set.insert mvoice renderedMvoices) renderedConfig
  in
    walk state.cells Set.empty false

-- | The mvoice label a cell currently belongs to: cellMvoice
-- | override, else cellTvoice override, else extracted from the
-- | source's first identifier.  Drives column-grouping in the
-- | Voice Cells canvas — cards sharing an effective mvoice stack
-- | together.
effectiveMvoice :: State -> CellRec -> String
effectiveMvoice _ c =
  let tvoiceName = fromMaybe (extractTvoice c.source) c.tvoice
  in fromMaybe tvoiceName c.mvoice

-- | All non-config cells whose effective mvoice equals the given
-- | label.  Used by the canvas walker to assemble a stack.
mvoiceGroupCells :: State -> String -> Array CellRec
mvoiceGroupCells state mvoice =
  Array.filter
    (\c ->
      let sec = cellSection c
          isConfig = sec == SecConfig || sec == SecVoices
      in not isConfig && effectiveMvoice state c == mvoice)
    state.cells

-- | Apply user-specified ordering (mvoiceOrder) to a group of
-- | cells, falling back to the natural creation order in
-- | state.cells when no override is recorded.  IDs in the override
-- | that no longer exist as cells are silently dropped; cells that
-- | are missing from the override list (e.g. newly-created in this
-- | mvoice) get appended at the end.
orderedMvoiceCells :: State -> String -> Array CellRec -> Array CellRec
orderedMvoiceCells state mvoice groupCells =
  case Map.lookup mvoice state.mvoiceOrder of
    Nothing -> groupCells
    Just ids ->
      let byId = Map.fromFoldable (map (\c -> Tuple c.id c) groupCells)
          ordered = Array.mapMaybe (\cid -> Map.lookup cid byId) ids
          orderedSet = Set.fromFoldable (map _.id ordered)
          extras = Array.filter (\c -> not (Set.member c.id orderedSet)) groupCells
      in ordered <> extras

-- | A collapsed music stack: cards overlap with only the front fully
-- | visible.  No toolbar — header click on the front fans, header
-- | click on a back card brings it forward, header click in fanned
-- | view restacks (handled in HeaderClick).
renderCollapsedMusicStack
  :: forall m. MonadAff m
  => State
  -> String                        -- mvoice label
  -> Array CellRec                 -- in stack order, front first
  -> H.ComponentHTML Action Slots m
renderCollapsedMusicStack state _mvoice cells =
  let
    total = Array.length cells
    -- (total-1) cards behind, each peeking ~22px (header row),
    -- plus the front card in full (front-card height ~140px).
    stackHeightPx = (total - 1) * 22 + 140
  in
    HH.div
      [ HP.class_ (H.ClassName "voice-stack")
      , HP.style ("height: " <> show stackHeightPx <> "px;")
      ]
      (mapWithIndex (renderStackedCard state total) cells)

-- | A fanned music stack: cards laid out in a grid, each fully
-- | visible.  Restack happens via HeaderClick on any card.
renderFannedMusicStack
  :: forall m. MonadAff m
  => State
  -> String
  -> Array CellRec
  -> H.ComponentHTML Action Slots m
renderFannedMusicStack state _mvoice cells =
  HH.div
    [ HP.class_ (H.ClassName "voice-stack voice-stack-fanned") ]
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
    -- tvoice = bind name (cellTvoice override else heuristic from
    -- cell source).  mvoice = user-assigned column label (cellMvoice
    -- override else default to tvoice so a freshly-created card reads
    -- "bass:bass" rather than ":bass").  Same resolution as the
    -- modal so card and modal stay in sync.
    tvoiceName = fromMaybe (extractTvoice c.source) c.tvoice
    mvoiceName = fromMaybe tvoiceName c.mvoice
    cardTitle = mvoiceName <> ":" <> tvoiceName
    bodyPreview = previewBody c.source
    isConfig = kind == CardConfigFront || kind == CardConfigBehind || kind == CardConfigFanned
    isCompact = kind == CardStackedBehind || kind == CardConfigBehind
    -- Tvoice category drives the card header background.  Resolved
    -- against the snapshot-derived tvoiceTypes map; falls back to
    -- TvUnknown when the binding hasn't been registered yet.
    -- Polysignal classification is cell-local: the cell's first word
    -- tells us directly which family it is. Don't route this through
    -- state.tvoiceTypes (which is a composition-source view); a cell
    -- can carry a polysignal block before it's registered in the
    -- composition pane, and the card should colour correctly anyway.
    tvoiceType = case cellPolyFamily c.source of
      Just family -> TvPolySignal family
      Nothing -> fromMaybe TvUnknown (Map.lookup tvoiceName state.tvoiceTypes)
    typeClass = " " <> tvoiceTypeClass tvoiceType
    -- Polysignal cells get an extra class for the double-border
    -- treatment — the visual signal that this cell is autonomous
    -- (no incoming Pattern); the FH-2 generates the signal itself.
    polySignalClass = case tvoiceType of
      TvPolySignal _ -> " voice-card-polysignal"
      _ -> ""
    -- Config cards keep the amber-dashed treatment via the
    -- stack-config class; non-config cards use only the type-color
    -- (or fall through to the dim TvUnknown look).
    colorClass = if isConfig then " stack-config" else ""
    kindClass = case kind of
      CardLone -> " voice-card-lone"
      CardStackedFront -> " voice-card-front"
      CardStackedBehind -> " voice-card-compact"
      CardFanned -> " voice-card-fanned"
      CardConfigFront -> " voice-card-front"
      CardConfigBehind -> " voice-card-compact"
      CardConfigFanned -> " voice-card-fanned"
    typeIcon = inferTypeIcon c.source
  in
    HH.div
      [ HP.class_
          ( H.ClassName
              ("voice-card-v2" <> colorClass <> kindClass <> typeClass <> polySignalClass)
          )
      ]
      ( [ HH.div
            [ HP.class_ (H.ClassName "voice-card-header")
            , HE.onClick \_ -> HeaderClick c.id
            , HP.title (case kind of
                CardLone -> "lone card — set its mvoice in the editor to stack it with peers"
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
                [ HH.text cardTitle ]
            , HH.span [ HP.class_ (H.ClassName "voice-card-tvtype") ]
                [ HH.text (tvoiceTypeLabel tvoiceType) ]
            ]
        ] <> (if isCompact then [] else
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
      )

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
        defaultTvoice = extractTvoice c.source
        -- tvoice = bind name the cell will install into when Play is
        -- pressed.  Override via the picker / input in the modal
        -- header; falls back to the heuristic-extracted first
        -- identifier.
        tvoiceName = fromMaybe defaultTvoice c.tvoice
        -- mvoice = user-assigned column label.  Defaults to the
        -- tvoice when not set (so a freshly-created card reads
        -- "bass:bass" rather than ":bass").
        mvoiceName = fromMaybe tvoiceName c.mvoice
        typeIcon = inferTypeIcon c.source
        sec = cellSection c
        isConfig = sec == SecConfig || sec == SecVoices
        tvoiceType = case cellPolyFamily c.source of
          Just family -> TvPolySignal family
          Nothing -> fromMaybe TvUnknown (Map.lookup tvoiceName state.tvoiceTypes)
        typeClass = " " <> tvoiceTypeClass tvoiceType
        polySignalClass = case tvoiceType of
          TvPolySignal _ -> " voice-card-polysignal"
          _ -> ""
        colorClass = if isConfig then " stack-config" else ""
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
                      ("voice-edit-modal voice-card-v2" <> colorClass <> typeClass <> polySignalClass)
                  )
              ]
              [ HH.div [ HP.class_ (H.ClassName "voice-card-header") ]
                  [ HH.span [ HP.class_ (H.ClassName "voice-card-icon") ]
                      [ HH.text typeIcon ]
                  -- Mvoice input: user-assigned column label.
                  -- Defaults to the tvoice name when not set, so the
                  -- card title reads "<mvoice>:<tvoice>".  Freeform —
                  -- column-grouping is still by stack-color today;
                  -- this label is just the display.
                  , HH.input
                      [ HP.class_ (H.ClassName "voice-edit-mvoice")
                      , HP.value mvoiceName
                      , HP.placeholder "mvoice"
                      , HP.title "mvoice — column label (user-assigned).  Commit on blur or Enter."
                      , HE.onValueChange \v -> UpdateCellMvoice c.id v
                      ]
                  , HH.span [ HP.class_ (H.ClassName "voice-edit-sep") ]
                      [ HH.text ":" ]
                  -- Tvoice picker: <select> populated from registered
                  -- bindings.  Native dropdown UI — deterministic
                  -- across browsers.  If the cell currently references
                  -- a tvoice that isn't (yet) a registered binding,
                  -- it's prepended as an option so the value displays
                  -- correctly rather than snapping to the first
                  -- registered binding.  Freeform "type a new tvoice"
                  -- is deferred — declare new bindings in the
                  -- Composition pane (`bind <name> ...`) and they'll
                  -- show up here on the next state refresh.
                  , let knownOpts = Array.fromFoldable (Map.keys state.tvoiceTypes)
                        allOpts =
                          if tvoiceName == "" || Array.elem tvoiceName knownOpts
                            then knownOpts
                            else Array.cons tvoiceName knownOpts
                        placeholder =
                          if tvoiceName == ""
                            then [ HH.option [ HP.value "" ] [ HH.text "— pick tvoice —" ] ]
                            else []
                    in HH.select
                         [ HP.class_ (H.ClassName "voice-edit-tvoice-select")
                         , HP.value tvoiceName
                         , HP.title "registered bindings — pick one to set this cell's tvoice."
                         , HE.onValueChange \v -> UpdateCellTvoice c.id v
                         ]
                         ( placeholder <>
                           map
                             (\n -> HH.option
                               [ HP.value n
                               , HP.selected (n == tvoiceName)
                               ]
                               [ HH.text n ])
                             allOpts
                         )
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
                                   Just m  -> [ HE.onClick \_ -> PlayArmed c.id tvoiceName m ]
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
    -- Polysignals: per-family glyph picks the shape closest to what
    -- the family makes audible/visible at the jacks.
    "polylfo"          -> "∿"  -- waveform
    "polyclock"        -> "▣"  -- pulse grid
    "polyenv"          -> "◣"  -- attack/decay ramp
    "polyeuclid"       -> "◇"  -- rotating shape
    "polyeuclid-pairs" -> "◈"  -- paired
    "polyrand"         -> "⌖"  -- crosshair / target / chance
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
-- |
-- | Polysignal cells are an exception: their first word is the family
-- | verb (`polylfo` etc.) and the second word is the user-chosen
-- | alias (`myLFO`). We return the alias so the tvoice lookup in
-- | `state.tvoiceTypes` resolves against `PolySignalCfg.alias` and
-- | the card title reads `myLFO:myLFO` rather than `polylfo:polylfo`.
extractTvoice :: String -> String
extractTvoice src =
  let lines = Str.split (Pattern "\n") src
      firstStmt = Array.find (\l -> not (Str.null (stripLineComment l))) lines
  in case firstStmt of
    Nothing -> "(empty)"
    Just l ->
      let words = Array.filter (not <<< Str.null) (Str.split (Pattern " ") (stripLineComment l))
          firstWord = fromMaybe "?" (Array.head words)
      in if isPolySignalVerb firstWord then
           fromMaybe firstWord (Array.index words 1)
         else
           firstWord

-- | True for any of the six polysignal verbs. Listed verbatim rather
-- | than dispatched through the parser because this fires per-render —
-- | a string check is fine for a six-element set.
isPolySignalVerb :: String -> Boolean
isPolySignalVerb = case _ of
  "polylfo"          -> true
  "polyclock"        -> true
  "polyenv"          -> true
  "polyeuclid"       -> true
  "polyeuclid-pairs" -> true
  "polyrand"         -> true
  _ -> false

-- | Cell-local polysignal detection: inspect the first non-comment
-- | line's first word and classify by family. Used by `renderVoiceCard`
-- | to colour polysignal cards even when the polysignal block isn't
-- | (yet) in the composition pane's `module.source` (so the
-- | composition-driven `extractTvoiceTypesFromComposition` hasn't
-- | discovered it).
cellPolyFamily :: String -> Maybe Comp.PolyFamily
cellPolyFamily src =
  let lines = Str.split (Pattern "\n") src
      firstStmt = Array.find (\l -> not (Str.null (stripLineComment l))) lines
      firstWord = case firstStmt of
        Nothing -> ""
        Just l -> fromMaybe "" $ Array.head
          (Array.filter (not <<< Str.null) (Str.split (Pattern " ") (stripLineComment l)))
  in case firstWord of
    "polylfo"          -> Just Comp.PFPolyLfo
    "polyclock"        -> Just Comp.PFPolyClock
    "polyenv"          -> Just Comp.PFPolyEnv
    "polyeuclid"       -> Just Comp.PFPolyEuclid
    "polyeuclid-pairs" -> Just Comp.PFPolyEuclidPairs
    "polyrand"         -> Just Comp.PFPolyRand
    _ -> Nothing

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
