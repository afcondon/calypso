module Calypso.Frontend.Shell.Types where

import Prelude

import Data.Array (findIndex, modifyAt)
import Data.Array as Array
import Data.Either (Either)
import Data.Map (Map)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set (Set)
import Data.String as Str
import Data.String.Pattern (Pattern(..))
import Halogen as H
import Type.Proxy (Proxy(..))

import Calypso.Composition as Comp
import Calypso.Favorite (Favorite)
import Calypso.Frontend.Completion (Completion)
import Calypso.Frontend.Editor as Editor
import Calypso.Frontend.WsClient as WsClient
import Calypso.Pen (PenState, SubscriberId)
import Calypso.Proposal (Proposal, ProposalId)
import Calypso.Session (Cell(..), CellRange, CompileError)
import Calypso.Vocabulary (Vocabulary)

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
mapCellInList :: String -> (CellRec -> CellRec) -> Array CellRec -> Array CellRec
mapCellInList cellId f cells =
  fromMaybe cells do
    idx <- findIndex (_.id >>> (_ == cellId)) cells
    modifyAt idx f cells

-- | Cell taxonomy used by `cellSection` to drive rendering decisions.
data Section
  = SecConfig
  | SecVoices
  | SecPatterns
  | SecDefault

derive instance eqSection :: Eq Section

-- | Drop everything from the first `--` onwards and trim trailing
-- | whitespace.  Used on cell text where `#` is the Tidal-style
-- | parameter-attach operator and must be preserved.
stripLineComment :: String -> String
stripLineComment line = case Str.indexOf (Pattern "--") line of
  Just i -> Str.trim (Str.take i line)
  Nothing -> Str.trim line

-- | Strip both `--` and `#` line comments.  Used on module.source
-- | (the routing-grammar portion of the session), where `#` is a
-- | comment marker per `docs/composition-grammar.md`.
stripModuleLineComment :: String -> String
stripModuleLineComment line =
  let dashCut = case Str.indexOf (Pattern "--") line of
        Just i -> Str.take i line
        Nothing -> line
      hashCut = case Str.indexOf (Pattern "#") dashCut of
        Just i -> Str.take i dashCut
        Nothing -> dashCut
  in Str.trim hashCut

-- | Infer which section a cell belongs to, by inspecting its source's
-- | leading word.
cellSection :: CellRec -> Section
cellSection c =
  let
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

-- | The seven top-level panes.
data ColumnKey
  = KeyComposition
  | KeyReplies
  | KeyVocabulary
  | KeyMiniNotation
  | KeyHylograph
  | KeyConfig
  | KeyVoiceCells

derive instance Eq ColumnKey

allColumnKeys :: Array ColumnKey
allColumnKeys =
  [ KeyComposition
  , KeyReplies
  , KeyVocabulary
  , KeyMiniNotation
  , KeyHylograph
  , KeyConfig
  , KeyVoiceCells
  ]

type ColumnVisibility =
  { showComposition :: Boolean
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
  , showReplies: true
  , showVocabulary: true
  , showMiniNotation: true
  , showHylograph: true
  , showConfig: true
  , showVoiceCells: true
  }

defaultVisibility :: ColumnVisibility
defaultVisibility =
  { showComposition: true
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
  KeyReplies -> _.showReplies
  KeyVocabulary -> _.showVocabulary
  KeyMiniNotation -> _.showMiniNotation
  KeyHylograph -> _.showHylograph
  KeyConfig -> _.showConfig
  KeyVoiceCells -> _.showVoiceCells

toggleKey :: ColumnKey -> ColumnVisibility -> ColumnVisibility
toggleKey k v = case k of
  KeyComposition -> v { showComposition = not v.showComposition }
  KeyReplies -> v { showReplies = not v.showReplies }
  KeyVocabulary -> v { showVocabulary = not v.showVocabulary }
  KeyMiniNotation -> v { showMiniNotation = not v.showMiniNotation }
  KeyHylograph -> v { showHylograph = not v.showHylograph }
  KeyConfig -> v { showConfig = not v.showConfig }
  KeyVoiceCells -> v { showVoiceCells = not v.showVoiceCells }

columnKeyLabel :: ColumnKey -> String
columnKeyLabel = case _ of
  KeyComposition -> "Composition"
  KeyReplies -> "Replies"
  KeyVocabulary -> "Vocabulary"
  KeyMiniNotation -> "Mini-notation"
  KeyHylograph -> "Hylograph"
  KeyConfig -> "Config"
  KeyVoiceCells -> "Voice Cells"

columnKeyToken :: ColumnKey -> String
columnKeyToken = case _ of
  KeyComposition -> "composition"
  KeyReplies -> "replies"
  KeyVocabulary -> "vocabulary"
  KeyMiniNotation -> "mini-notation"
  KeyHylograph -> "hylograph"
  KeyConfig -> "config"
  KeyVoiceCells -> "voice-cells"

-- | Decode the `?hide=` query value into a `ColumnVisibility`.
visibilityFromHide :: String -> ColumnVisibility
visibilityFromHide hide =
  let tokens = if hide == "" then [] else Str.split (Pattern ",") hide
      has t = Array.any (_ == t) tokens
  in
    { showComposition: not (has "composition" || has "module")
    , showReplies: not (has "replies")
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

-- | Grid-template-columns string for the visible panes.
gridTemplateForVisibility :: ColumnVisibility -> String
gridTemplateForVisibility v =
  let parts = Array.catMaybes $
        map (\k -> if isVisible k v then Just "1fr" else Nothing) allColumnKeys
  in case Array.length parts of
       0 -> "1fr"
       1 -> "1fr"
       _ -> Str.joinWith " " parts

-- | Card-color class for a cell index (cycles 0-7).
cellColorClass :: Int -> String
cellColorClass idx = "cell-color-" <> show (idx `mod` 8)

-- | Tvoice classifier — drives card type-color and short label.
data TvoiceType
  = TvMidi
  | TvCV
  | TvGate
  | TvSample
  | TvPolySignal Comp.PolyFamily
  | TvUnknown

derive instance eqTvoiceType :: Eq TvoiceType

tvoiceTypeClass :: TvoiceType -> String
tvoiceTypeClass = case _ of
  TvMidi -> "tv-midi"
  TvCV -> "tv-cv"
  TvGate -> "tv-gate"
  TvSample -> "tv-sample"
  TvPolySignal _ -> "tv-polysignal"
  TvUnknown -> "tv-unknown"

tvoiceTypeLabel :: TvoiceType -> String
tvoiceTypeLabel = case _ of
  TvMidi -> "midi"
  TvCV -> "cv"
  TvGate -> "gate"
  TvSample -> "smp"
  TvPolySignal f -> polyFamilyShortLabel f
  TvUnknown -> ""

-- | 3-4 char family label for the card-tvtype corner badge.
polyFamilyShortLabel :: Comp.PolyFamily -> String
polyFamilyShortLabel = case _ of
  Comp.PFPolyLfo         -> "lfo"
  Comp.PFPolyClock       -> "clk"
  Comp.PFPolyEnv         -> "env"
  Comp.PFPolyEuclid      -> "euc"
  Comp.PFPolyEuclidPairs -> "eucp"
  Comp.PFPolyRand        -> "rnd"

type State =
  { moduleSource :: String
  , cells :: Array CellRec
  , nextCellId :: Int
  , runtime :: String
  , favorites :: Array Favorite
  , favoriteKey :: Maybe String
  , favoriteMenuOpen :: Boolean
  , vocabulary :: Vocabulary
  , completions :: Array Completion
  , settingsOpen :: Boolean
  , compiling :: Boolean
  , errors :: Array CompileError
  , warnings :: Array CompileError
  , cellRanges :: Array CellRange
  , transportError :: Maybe String
  , runtimeError :: Maybe String
  , clkReminder :: Maybe String
  , clkReminderShown :: Boolean
  , cellResults :: Map String String
  , compositionStatus :: Maybe String
  , compositionFireLines :: Array { lineNum :: Int, source :: String, reply :: Either String String }
  , configSnapshot :: Maybe String
  , tvoiceTypes :: Map String TvoiceType
  , bpmDisplay :: Number
  , cellTypes :: Map String String
  , pendingCompile :: Maybe H.ForkId
  , myId :: Maybe SubscriberId
  , pen :: PenState
  , requestingPen :: Boolean
  , nextPenRetryAt :: Maybe Number
  , penBackoffMs :: Int
  , ws :: Maybe WsClient.WebSocket
  , wsSub :: Maybe H.SubscriptionId
  , penBanner :: Maybe String
  , proposals :: Array Proposal
  , lastSyncedModule :: String
  , lastSyncedCells :: Map String { source :: String, kind :: String, mvoice :: Maybe String, tvoice :: Maybe String }
  , lastSyncedRuntime :: String
  , visibility :: ColumnVisibility
  , mvoiceOrder :: Map String (Array String)
  , fannedMvoice :: Maybe String
  , configStackFanned :: Boolean
  , editingCard :: Maybe String
  , armedModule :: Map String String
  , cuePending :: Set String
  , cellHistory :: Map String (Array { body :: String, modul :: String })
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
  | PromoteCellToCode String
  | DemoteCursorLineToCell
  | FireCell String String
  | FireComposition String
  | WipeAndRestore
  | LoadWorkspace
  | AcceptHunk ProposalId Int
  | RejectHunk ProposalId Int
  | ToggleFavoriteMenu
  | LoadFavorite String
  | FavoritesLoaded (Array Favorite)
  | VocabularyLoaded Vocabulary
  | KeyboardShortcut Int
  | RefreshConfigState
  | BpmCommit Number
  | BpmInputChanged String
  | ToggleSettings
  | WsOpened
  | WsIncoming String
  | WsClosed Int String
  | WsErrored
  | RequestPenAction
  | YieldPenAction
  | ForcePenAction
  | DismissPenBanner
  | DismissClkReminder
  | ToggleColumn ColumnKey
  | HeaderClick String
  | OpenEditor String
  | CloseEditor
  | CommitEdit String String
  | CueCell String String
  | PlayArmed String String String
  | UpdateCellTvoice String String
  | UpdateCellMvoice String String
  | NewVoiceCard
  | LoadHistoryEntry String String String
  | Startup
