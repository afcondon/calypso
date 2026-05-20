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
import Data.Set as Set
import Data.String as Str
import Data.String.CodeUnits (takeRight) as Str.CU
import Data.String.CodeUnits as SCU
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.HTTP.Method (Method(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Int (toNumber)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
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
import Web.Event.Event as WEvent
import Web.Event.EventTarget as WEvtTarget
import Web.HTML (window) as Web
import Web.HTML.Window as WWindow
import Web.UIEvent.KeyboardEvent as WKey
import Web.UIEvent.KeyboardEvent.EventTypes as WKeyTypes

import Data.Foldable (for_, foldr)

import Calypso.Frontend.CodeMirror (ErrorSpan)
import Calypso.Frontend.Config (backendUrl, formatNumber, prettyPrintJson, readHideParam, writeHideParam, wsBackendUrl)
import Calypso.Frontend.Completion (completionsFromVocabulary)
import Calypso.Frontend.Editor as Editor
import Calypso.Frontend.Favorite as Favorite
import Calypso.Frontend.FilePicker (pickJsonFile)
import Calypso.Frontend.Panes.Composition (renderCompositionColumn)
import Calypso.Frontend.Panes.Config (renderConfigColumn)
import Calypso.Frontend.Panes.Hylograph (renderHylographColumn)
import Calypso.Frontend.Panes.MiniNotation (renderMiniNotationColumn)
import Calypso.Frontend.Panes.Replies (renderRepliesColumn)
import Calypso.Frontend.Panes.Studio (renderStudioColumn)
import Calypso.Frontend.Panes.Vocabulary (renderVocabularyColumn)
import Calypso.Frontend.Panes.VoiceCells
  ( clkReminderText
  , effectiveMvoice
  , extractTvoice
  , hasClockDependentPolySignal
  , mvoiceGroupCells
  , orderedMvoiceCells
  , renderEditingModal
  , renderVoiceCellsColumn
  )
import Calypso.Frontend.Primer as Primer
import Calypso.Frontend.Studio as Studio
import Calypso.Frontend.Vocabulary as Vocabulary
import Calypso.Frontend.WsClient as WsClient
import Calypso.Frontend.Controller (subscribeTwister)
import Calypso.Frontend.Controller.Bindings (allBindings) as ControllerBindings
import Calypso.Composition as Comp
import Calypso.Composition.Parser as Comp
import Calypso.Composition.Serializer as CompS
import Calypso.Favorite (Favorite(..))
import Calypso.Proposal
  ( Proposal(..)
  , ProposalId
  , ProposalTarget(..)
  , unProposalId
  )
import Calypso.Pen
  ( Broadcast(..)
  , ClientMsg(..)
  , PenHeldBody
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
import Calypso.Frontend.Shell.Types
  ( Action(..)
  , CellRec
  , ColumnKey
  , Section(..)
  , Slots
  , State
  , TvoiceType(..)
  , _cellEditor
  , _editorModal
  , _moduleEditor
  , allColumnKeys
  , appendUnrepresentedCellsAsCues
  , cellOf
  , cellRecOf
  , cellSection
  , columnKeyLabel
  , defaultVisibility
  , extractCuesAsCellRecs
  , migrateCellIdsToTvoice
  , gridTemplateForVisibility
  , hideFromVisibility
  , isVisible
  , mapCellInList
  , mergeCueCells
  , mergeCueCellsCompositionWins
  , isVerbCell
  , tvoiceTypeShortClass
  , stripLineComment
  , stripModuleLineComment
  , syncCellIntoTypefulSource
  , toggleKey
  , visibilityFromHide
  )


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
  , clkReminder: Nothing
  , clkReminderShown: false
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
  , lastBuiltModule: ""
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
  , studio: Nothing
  , studioBuffer: Nothing
  , studioFireStatus: Nothing
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
    -- Phase 2a (live projection): re-derive cue cards from the
    -- composition source as the user types. Uses the composition-wins
    -- merge variant so editing a cue's body in the composition pane
    -- updates the corresponding card's source; novel `cue` ids appear
    -- as new cards. Removing a cue line does NOT yet remove its card
    -- (Phase 2b concern — needs dirty-tracking).
    H.modify_ \s ->
      let cuesAsCells = extractCuesAsCellRecs src
          mergedCells = mergeCueCellsCompositionWins s.cells cuesAsCells
          s' = s { moduleSource = src, cells = mergedCells }
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
    -- Two dispatch paths, chosen by the cell's first word:
    --
    -- * **Verb cells** (`bind`, `bpm`, `kit`, `polylfo`, `fh2-trigger`,
    --   `hush`, …) — fire each statement directly via `/eval`, one
    --   per call. The daemon's `try_parse_prefixed` handles them.
    --   `cellStatements` runs the polysignal collapser so multi-line
    --   polysignal blocks come through as a single `polysignal <json>`
    --   statement rather than fragments.
    --
    -- * **Music cells** (anything else) — wrap in `cue <body>` + on
    --   success dispatch `play-armed <tvoice> <module>`. The bare-
    --   binding wire-protocol dispatch (path 4) and the `:expr`
    --   operator (path 2) were retired per the architectural-bet
    --   doc; one road from musical intent to running sound.
    --
    -- Polysignal autoformat: cells that parse as exactly one
    -- polysignal block get re-printed canonical (column-aligned
    -- vectors, `<>` continuation markers) before firing. Applies on
    -- both paths (polysignal cells are verb cells but they still need
    -- the cleanup).
    fired <- case Comp.autoformatPolySignalCell src of
      Just pretty | pretty /= src -> do
        H.modify_ \s -> s
          { cells = map
              (\c -> if c.id == cellId then c { source = pretty } else c)
              s.cells
          }
        _ <- H.tell _cellEditor cellId (Editor.ReplaceContent pretty)
        _ <- H.tell _editorModal unit (Editor.ReplaceContent pretty)
        pure pretty
      _ -> pure src
    maybeShowClkReminder fired
    if isVerbCell fired
      then do
        let stmts = cellStatements fired
        if Array.null stmts
          then H.modify_ \s -> s
            { cellResults = Map.insert cellId "(no statements)" s.cellResults }
          else fireCellStatements cellId stmts
      else
        -- Non-verb cells used to fire the legacy `cue` + `play-armed
        -- M<hash>` pipeline (fireMusicCell, retired with the typeful
        -- pivot).  Cells whose body is a typed cue identifier arm via
        -- the `arm` button (ArmTypefulCue), not the fire path.
        H.modify_ \s -> s
          { cellResults = Map.insert cellId
              ("not a verb-cell — use ▶ run on the composition pane "
                <> "then the card's arm button")
              s.cellResults
          }
  FireComposition src -> do
    -- Composition is "all or nothing" but the daemon parses one
    -- statement per /eval call, so we split by line, drop blanks and
    -- `--` comments (the directive comments aren't for the daemon),
    -- and fire each statement in sequence.  Stop on the first error
    -- and report which line failed.
    maybeShowClkReminder src
    let stmts = compositionStatements src
    H.modify_ _ { compositionStatus = Nothing, compositionFireLines = [], transportError = Nothing }
    if Array.null stmts
      then H.modify_ _ { compositionStatus = Just "(no statements to fire)" }
      else fireStatements stmts
  FireTypefulComposition src -> do
    -- POST the composition source to /session-source.  Server writes
    -- it to Calypso.Generated.Session.purs, builds, and asks
    -- purerl-tidal to reload-baseline.  Re-arm any voices afterward
    -- to pick up new cue bodies on currently-playing patterns.
    H.modify_ _
      { compositionStatus = Just "fire typeful: building…"
      , transportError = Nothing
      }
    result <- buildSessionRequest src
    case result of
      Left err ->
        -- `err` is `headline\n\ndetails` (see buildSessionRequest).
        -- The action row is single-line, so show only the headline
        -- there; the full thing including raw compiler output renders
        -- in the bottom ERRORS panel's HH.pre block.
        let
          headline = case Str.split (Pattern "\n\n") err of
            [] -> err
            arr -> fromMaybe err (Array.head arr)
        in H.modify_ _
          { compositionStatus = Just ("fire typeful: " <> headline)
          , transportError = Just err
          }
      Right { reply, totalMs } -> do
        H.modify_ _
          { compositionStatus = Just
              ("fire typeful: " <> reply <> " (" <> show totalMs <> "ms)")
          , lastBuiltModule = src
          }
        -- Reload-baseline repopulates the BEAM Studio module; refresh
        -- the pane so a freshly-built composition's devices /
        -- instruments / drumKits show up without an extra click.
        handleAction RefreshStudio
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
                    cuesAsCells = extractCuesAsCellRecs rm.source
                    mergedCells = mergeCueCells loadedCells cuesAsCells
                H.modify_ \s -> s
                  { moduleSource = rm.source
                  , cells = mergedCells
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
  WsOpened -> do
    -- Controller layer: subscribe to Midifighter Twister via WebMIDI
    -- and forward encoder turns to the BEAM live-control bus as
    -- `set-control <name> <value>` text verbs.  The pump opens its
    -- own WS to BEAM (`ws://localhost:3012/ws`); Calypso's session WS
    -- on :3060 isn't a transparent BEAM proxy.
    --
    -- The pump takes the full list of (Controller, Controllable)
    -- pairings — it starts on the first and cycles via the Twister
    -- side buttons.  Best-effort: if the browser blocks WebMIDI or
    -- the device isn't present, the pump logs to the console and the
    -- rest of Calypso comes up regardless.
    _ <- H.fork $ H.liftAff $ subscribeTwister ControllerBindings.allBindings
    pure unit
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
  DismissClkReminder -> H.modify_ _ { clkReminder = Nothing }
    -- clkReminderShown stays true — don't re-surface this session.
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
  SilenceVoice cellId tvoiceName -> do
    -- Clear the named voice's pattern on the BEAM.  Binding stays so
    -- any card targeting this tvoice can re-arm cleanly afterward.
    -- No pen required — silence is a transient runtime action, not a
    -- session edit.
    result <- evalSource ("silence " <> tvoiceName)
    case result of
      Left err -> H.modify_ _ { transportError = Just err }
      Right reply -> do
        -- Clear armed markers on ALL cards targeting this tvoice
        -- (armedModule is per-cell but the "is playing" state is
        -- per-tvoice).  Without this, sibling cards keep showing
        -- the ▶ marker after their shared voice was silenced.
        s0 <- H.get
        let cellsOnVoice = Array.filter
              (\c -> fromMaybe (extractTvoice c.source) c.tvoice == tvoiceName)
              s0.cells
            cellIds = map _.id cellsOnVoice
        H.modify_ \s -> s
          { cellResults = Map.insert cellId reply s.cellResults
          , armedModule = Array.foldr Map.delete s.armedModule cellIds
          }
  ArmTypefulCue cellId tvoiceName cueName -> do
    -- Two-phase arm:
    --   1. If THIS card's body has diverged from what's currently
    --      built into the BEAM, project just its line back into the
    --      module source and run a full build+reload first.  We
    --      explicitly scope to a single cell so a broken edit in
    --      some OTHER card doesn't poison the build path here —
    --      every cue stays independently armable.
    --   2. Send `play-armed <tvoice> <cueName>` via POST /arm.
    --
    -- If the build fails (purs/erlc/etc.) we surface the error in
    -- the card's result area and bail out — the BEAM still has the
    -- previously-built body, so silently arming here would mislead
    -- the user into hearing the OLD pattern after a failed edit.
    s0 <- H.get
    let mCell = Array.find (\c -> c.id == cellId) s0.cells
    case mCell of
      Nothing -> pure unit  -- can't happen via UI, but bail safely
      Just cell -> do
        let projectedSource = syncCellIntoTypefulSource cell s0.moduleSource
            needsBuild = projectedSource /= s0.lastBuiltModule
        buildOk <- if needsBuild
          then do
            H.modify_ _
              { moduleSource = projectedSource
              , compositionStatus = Just "arm: rebuilding edited cell…"
              , transportError = Nothing
              }
            buildResult <- buildSessionRequest projectedSource
            case buildResult of
              Left err -> do
                -- Build pipeline reported failure (purs / erlc / WS /
                -- transport).  Surface in the card AND the composition
                -- status; bail out without arming so the user doesn't
                -- silently re-arm the previously-built body.
                H.modify_ \s -> s
                  { compositionStatus = Just ("arm rebuild failed: " <> err)
                  , transportError = Just err
                  , cellResults = Map.insert cellId
                      ("rebuild failed: " <> err) s.cellResults
                  }
                pure false
              Right { reply, totalMs } -> do
                H.modify_ _
                  { compositionStatus = Just
                      ("arm rebuild: " <> reply <> " (" <> show totalMs <> "ms)")
                  , lastBuiltModule = projectedSource
                  }
                pure true
          else pure true
        when buildOk do
          -- Phase 2: actual arm.  POST /arm → BEAM `play-armed`.
          H.modify_ \s -> s { cuePending = Set.insert cellId s.cuePending }
          result <- armCueRequest tvoiceName cueName
          H.modify_ \s -> s { cuePending = Set.delete cellId s.cuePending }
          case result of
            Left err -> H.modify_ _ { transportError = Just err }
            Right { ok, reply } -> do
              H.modify_ \s -> s
                { cellResults = Map.insert cellId reply s.cellResults }
              when ok $
                -- Track which cue is currently armed on this cell so the
                -- modal can mark the active row in the history list.
                let entry = { body: cueName, modul: cueName }
                in H.modify_ \s ->
                  let existing = fromMaybe [] (Map.lookup cellId s.cellHistory)
                      filtered = Array.filter (\e -> e.modul /= cueName) existing
                      updated  = Array.cons entry filtered
                  in s
                    { armedModule = Map.insert cellId cueName s.armedModule
                    , cellHistory = Map.insert cellId updated s.cellHistory
                    }
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
  PlayPiece name -> do
    -- Hand the named Section to the BEAM conductor.  The composition
    -- must have been ▶ run first so calypso_generated_session@ps:
    -- <name>/0 is loaded; otherwise the BEAM replies with an error.
    result <- evalSource ("play-piece " <> name)
    case result of
      Left err -> H.modify_ _ { transportError = Just err }
      Right reply ->
        H.modify_ _ { compositionStatus = Just ("piece " <> name <> ": " <> reply) }
  StopPiece -> do
    result <- evalSource "stop-piece"
    case result of
      Left err -> H.modify_ _ { transportError = Just err }
      Right reply ->
        H.modify_ _ { compositionStatus = Just reply }
  RefreshStudio -> do
    -- Fetch GET /studio and stash the decoded snapshot.  On failure
    -- surface via transportError (same channel as other read errors)
    -- and leave any prior snapshot in place — a stale view is more
    -- useful than a wiped one.
    result <- H.liftAff Studio.fetchStudioSnapshot
    case result of
      Left err -> H.modify_ _ { transportError = Just err }
      Right snap -> H.modify_ _ { studio = Just snap }
  StartEditStudio -> do
    -- Fetch the current Studio.purs source from disk via /studio-source
    -- and open the inline edit buffer.  On fetch failure surface via
    -- transportError; the pane stays in read-only mode.
    result <- H.liftAff Studio.fetchStudioSource
    case result of
      Left err -> H.modify_ _ { transportError = Just err }
      Right src -> H.modify_ _
        { studioBuffer = Just src
        , studioFireStatus = Nothing
        }
  UpdateStudioBuffer src ->
    H.modify_ _ { studioBuffer = Just src }
  CancelEditStudio ->
    H.modify_ _ { studioBuffer = Nothing, studioFireStatus = Nothing }
  SaveStudio -> do
    s <- H.get
    case s.studioBuffer of
      Nothing -> pure unit
      Just src -> do
        let authHeaders = case s.myId of
              Nothing -> []
              Just sid ->
                [ AX.RequestHeader "X-Atelier-Subscriber-Id"
                    (unSubscriberId sid)
                ]
        result <- H.liftAff (Studio.postStudioSource authHeaders src)
        H.modify_ _ { studioFireStatus = Just result }
        case result of
          Right _ -> do
            -- Build + reload-baseline succeeded.  Drop the edit buffer,
            -- re-fetch the Studio snapshot so the pane reflects the new
            -- rig declarations + cleared/new claim conflicts.
            H.modify_ _ { studioBuffer = Nothing }
            handleAction RefreshStudio
          Left _ -> pure unit  -- error already in studioFireStatus
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

-- | Parse the composition source into a flat array of statements.
-- | Strips `--` and `#` line comments (the new routing grammar treats
-- | both as comments), drops blank lines, and emits one entry per
-- | non-empty source line with its 1-based line number for error
-- | reporting.
-- |
-- | `cue <id> [meta] [= body]` declarations (and any indented
-- | continuation lines) are filtered out before wire collapse: they
-- | are file-level card declarations, not daemon dispatches. The cards
-- | themselves still fire via the cue/play-armed path on the Voice
-- | Cells side; the file-level declaration only exists so the cards
-- | survive a session reload.
compositionStatements
  :: String
  -> Array { lineNum :: Int, source :: String }
compositionStatements src =
  let lines = Str.split (Pattern "\n") src
      filtered = stripCueBlocksFromLines lines
      indexed = mapWithIndex
        (\i s -> { lineNum: i + 1, source: stripModuleLineComment s }) filtered
      nonEmpty = Array.filter (\e -> not (Str.null (Str.trim e.source))) indexed
  in Comp.collapsePolySignalEntries
       (Comp.collapseGridsEntries
         (Comp.collapseMacroEntries nonEmpty))

-- | Replace every `cue <id>` block (header line + any indented
-- | continuation lines) with a blank line per replaced line, so the
-- | rest of the pipeline still sees the original 1-based line numbers
-- | for error reporting on non-cue statements. Operates on raw lines
-- | (before any comment stripping) because indent is a meaningful
-- | signal here.
stripCueBlocksFromLines :: Array String -> Array String
stripCueBlocksFromLines = go []
  where
  go acc remaining = case Array.uncons remaining of
    Nothing -> Array.reverse acc
    Just { head, tail }
      | isCueHeaderLine head ->
          let { continuations, rest } = splitContinuations tail
              dropped = continuations
              -- One blank substitution per dropped line preserves line
              -- numbering for downstream error messages.
              padding = Array.replicate (1 + Array.length dropped) ""
          in go (Array.reverse padding <> acc) rest
      | otherwise -> go (Array.cons head acc) tail

  splitContinuations xs =
    let { init, rest: r } = takeWhilePartition isIndentedNonBlank xs
    in { continuations: init, rest: r }

  -- | A `cue <id>` header line: column-0 (no leading whitespace),
  -- | first token is exactly `cue`, second token is an identifier.
  isCueHeaderLine raw =
    case SCU.uncons raw of
      Just { head: c, tail: _ }
        | c == ' ' || c == '\t' -> false
      _ ->
        case Array.head (Str.split (Pattern " ") (Str.trim raw)) of
          Just "cue" ->
            -- Disambiguate: bare `cue <body...>` as a verb-cell text
            -- (the path-2-style cue verb) doesn't exist at file level,
            -- so anything that starts with `cue ` at column 0 in the
            -- composition source is a file declaration.
            let restAfterCue = Str.drop 4 (Str.trim raw)
            in not (Str.null (Str.trim restAfterCue))
          _ -> false

  isIndentedNonBlank raw =
    case SCU.uncons raw of
      Just { head: c, tail: _ } -> (c == ' ' || c == '\t') && not (Str.null (Str.trim raw))
      Nothing -> false

-- | Partition by predicate from the start: prefix that satisfies p, then rest.
takeWhilePartition :: forall a. (a -> Boolean) -> Array a -> { init :: Array a, rest :: Array a }
takeWhilePartition p xs =
  let n = case Array.findIndex (not <<< p) xs of
        Just i -> i
        Nothing -> Array.length xs
  in { init: Array.take n xs, rest: Array.drop n xs }

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
  in Comp.collapsePolySignalEntries
       (Comp.collapseGridsEntries
         (Comp.collapseMacroEntries nonEmpty))

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

-- | If the about-to-fire source contains a clock-dependent polysignal
-- | (polyclock / polyeuclid / polyeuclid-pairs / polyrand) AND we
-- | haven't shown the reminder this session yet, surface the Clk-
-- | source toast. First-fire-per-session: latches `clkReminderShown`
-- | so subsequent fires don't re-surface it even after the user
-- | dismisses (dismiss only clears the visible message; the latch
-- | stays). User-facing rationale: the gotcha is real but you only
-- | need to hear about it once.
maybeShowClkReminder
  :: forall o m
   . MonadAff m
  => String
  -> H.HalogenM State Action Slots o m Unit
maybeShowClkReminder src = do
  s <- H.get
  when (not s.clkReminderShown && hasClockDependentPolySignal src) do
    H.modify_ _
      { clkReminder = Just clkReminderText
      , clkReminderShown = true
      }

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

-- | POST /arm `{tvoice, cueName}`.  Backend response shape is
-- | `{ok, reply, error, timings}` — we only consume ok + reply.  Pen-
-- | required; 409 surfaces as a transport error like other mutating
-- | endpoints.
armCueRequest
  :: forall o m
   . MonadAff m
  => String
  -> String
  -> H.HalogenM State Action Slots o m
       (Either String { ok :: Boolean, reply :: String })
armCueRequest tvoice cueName = do
  s <- H.get
  let
    authHeaders = case s.myId of
      Nothing -> []
      Just sid -> [ AX.RequestHeader "X-Atelier-Subscriber-Id" (unSubscriberId sid) ]
    body = stringify
      ( AJ.fromObject
          ( Object.fromFoldable
              [ Tuple "tvoice" (AJ.fromString tvoice)
              , Tuple "cueName" (AJ.fromString cueName)
              ]
          )
      )
  result <- H.liftAff $ AX.request $ AX.defaultRequest
    { method = Left POST
    , url = backendUrl <> "/arm"
    , responseFormat = RF.json
    , content = Just (RB.string body)
    , headers = authHeaders
    }
  pure case result of
    Left err -> Left (AX.printError err)
    Right r
      | r.status == AX.StatusCode 200 ->
          case AJ.toObject r.body of
            Nothing -> Left "arm: response not an object"
            Just o ->
              let ok = fromMaybe false (Object.lookup "ok" o >>= AJ.toBoolean)
                  reply = fromMaybe ""
                    (Object.lookup "reply" o >>= AJ.toString)
                  err = fromMaybe ""
                    (Object.lookup "error" o >>= AJ.toString)
              in if ok
                 then Right { ok, reply }
                 else Left (if Str.null err then reply else err)
      | r.status == AX.StatusCode 409 ->
          Left "arm: pen-held — take the pen first"
      | otherwise -> Left ("arm: HTTP " <> show r.status)

-- | POST /session-source `{source}`.  Server writes the source to
-- | Calypso.Generated.Session.purs, builds via purs +
-- | backend-erl --filter + erlc, then sends reload-baseline.
-- | Returns `{reply, totalMs}` on success; a user-readable error
-- | string on failure (parse error, build failure, transport).
buildSessionRequest
  :: forall o m
   . MonadAff m
  => String
  -> H.HalogenM State Action Slots o m
       (Either String { reply :: String, totalMs :: Int })
buildSessionRequest src = do
  s <- H.get
  let
    authHeaders = case s.myId of
      Nothing -> []
      Just sid -> [ AX.RequestHeader "X-Atelier-Subscriber-Id" (unSubscriberId sid) ]
    body = stringify
      ( AJ.fromObject (Object.singleton "source" (AJ.fromString src)) )
  result <- H.liftAff $ AX.request $ AX.defaultRequest
    { method = Left POST
    , url = backendUrl <> "/session-source"
    , responseFormat = RF.json
    , content = Just (RB.string body)
    , headers = authHeaders
    }
  pure case result of
    Left err -> Left (AX.printError err)
    Right r
      | r.status == AX.StatusCode 200 ->
          case AJ.toObject r.body of
            Nothing -> Left "session-source: response not an object"
            Just o ->
              let ok = fromMaybe false (Object.lookup "ok" o >>= AJ.toBoolean)
                  reply = fromMaybe ""
                    (Object.lookup "reply" o >>= AJ.toString)
                  err = fromMaybe ""
                    (Object.lookup "error" o >>= AJ.toString)
                  details = fromMaybe ""
                    (Object.lookup "pursErrorsJson" o >>= AJ.toString)
                  total = fromMaybe 0 do
                    t <- Object.lookup "timings" o
                    tObj <- AJ.toObject t
                    n <- Object.lookup "total" tObj >>= AJ.toNumber
                    Int.fromNumber n
                  headline = if Str.null err then reply else err
                  full = if Str.null details
                           then headline
                           else headline <> "\n\n" <> details
              in if ok
                 then Right { reply, totalMs: total }
                 else Left full
      | r.status == AX.StatusCode 409 ->
          Left "session-source: pen-held — take the pen first"
      | otherwise -> Left ("session-source: HTTP " <> show r.status)

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
      "8" -> Just 8
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
        -- Populate the Studio pane on session load so opening it
        -- (Cmd-8) shows the current rig snapshot without a manual
        -- refresh.  Independent of the pen state — Studio is read-only.
        handleAction RefreshStudio
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
  -- Phase 2b step 1: lift any wire-loaded cell that lacks a corresponding
  -- `cue` declaration in the composition source by appending one. Achieves
  -- 1:1 commensurability between cards and the composition pane on
  -- legacy sessions. Idempotent and safe-on-parse-failure.
  let appended = fromMaybe rm.source
        (appendUnrepresentedCellsAsCues rm.source cellRecs)
      -- Level 2 follow-up: rename cell-NNN auto-ids → tvoice-based
      -- names so the named-form serializer kicks in for legacy cells.
      idMig = migrateCellIdsToTvoice cellRecs
      finalCells = idMig.cells
      -- Map old id → new id so we can rename cues in the parsed AST
      -- to match the renamed cells before serializing.
      idMap = Map.fromFoldable
        (Array.zipWith (\old new -> Tuple old.id new.id) cellRecs finalCells)
      -- Level 2 canonicalization: parse the appended source, apply the
      -- id rename to its cues, and re-serialize through the level-2-
      -- aware serializer. Result: every cue with a tvoice renders in
      -- `<tvoice>[:suffix] = body` form under a `section <mvoice>`
      -- header. Falls through on parse failure.
      migratedSource = case Comp.parseComposition appended of
        Right comp ->
          let renamed = if idMig.didRename then applyIdMap idMap comp else comp
          in CompS.serializeComposition renamed <> "\n"
        Left _ -> appended
  H.modify_ \s ->
    let
      -- Phase 2a (read-only Model B projection): lift any `cue <id>`
      -- declarations from the composition source into cells alongside
      -- the wire-loaded array. Wire-loaded wins on id collision so
      -- legacy JSON sessions keep their exact rendering; cues that
      -- aren't yet represented as cells appear as additional cards.
      -- We use the post-rename finalCells here so id-collision detection
      -- against the cue-derived array works correctly.
      cuesAsCells = extractCuesAsCellRecs migratedSource
      mergedCells = mergeCueCells finalCells cuesAsCells
      s' = s
        { moduleSource = migratedSource
        , cells = mergedCells
        , nextCellId = max s.nextCellId (maxRemoteN + 1)
        , runtime = r.runtime
        , cellTypes = typesMap
        , cellResults = Map.union resultsMap s.cellResults
        , cellRanges = r.cellLines
        , errors = r.errors
        , warnings = r.warnings
        , lastSyncedModule = rm.source  -- keep PRE-migration source as
                                        -- lastSynced so the next compile
                                        -- pushes the migration up to the
                                        -- server too.
        , lastSyncedCells = syncedCells
        , lastSyncedRuntime = r.runtime
        , lastBuiltModule = rm.source   -- assume BEAM matches disk after
                                        -- boot; ArmTypefulCue will only
                                        -- force a rebuild once cells
                                        -- diverge from this baseline.
        }
    in s' { tvoiceTypes = recomputeTvoiceTypes s' }
  -- If we migrated, schedule a compile so the server gets the new source.
  when (migratedSource /= rm.source) $ handleAction ScheduleCompile
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
            <> (if state.visibility.showReplies then [ renderRepliesColumn state ] else [])
            <> (if state.visibility.showVocabulary then [ renderVocabularyColumn state ] else [])
            <> (if state.visibility.showMiniNotation then [ renderMiniNotationColumn state ] else [])
            <> (if state.visibility.showHylograph then [ renderHylographColumn state ] else [])
            <> (if state.visibility.showConfig then [ renderConfigColumn state ] else [])
            <> (if state.visibility.showVoiceCells then [ renderVoiceCellsColumn state ] else [])
            <> (if state.visibility.showStudio then [ renderStudioColumn state ] else [])
        )
    , renderErrorPanel state
    , renderEditingModal state
    , renderClkReminder state
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

-- | Corner toast surfaced on first fire of a clock-dependent polysignal
-- | in this session. Dismissable; latches so it won't re-surface after
-- | dismissal (the `clkReminderShown` flag in State). Positioned via
-- | the `.clk-reminder` CSS class — bottom-right toast, separate visual
-- | language from the top-banner `.pen-banner` so they can coexist.
renderClkReminder :: forall m. State -> H.ComponentHTML Action Slots m
renderClkReminder state = case state.clkReminder of
  Nothing -> HH.text ""
  Just msg ->
    HH.div [ HP.class_ (H.ClassName "clk-reminder") ]
      [ HH.div [ HP.class_ (H.ClassName "clk-reminder-title") ]
          [ HH.text "FH-2 clock check" ]
      , HH.div [ HP.class_ (H.ClassName "clk-reminder-body") ]
          [ HH.text msg ]
      , HH.button
          [ HP.class_ (H.ClassName "clk-reminder-dismiss")
          , HE.onClick \_ -> DismissClkReminder
          ]
          [ HH.text "Got it" ]
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
-- | Apply an id-rename map to every StmtCue in a Composition. Used by
-- | the level-2 hydrate path to align cue ids in source with the
-- | tvoice-renamed cells in state.cells. Cues whose id isn't in the
-- | map are left untouched (so user-supplied ids like `test1` survive).
applyIdMap :: Map String String -> Comp.Composition -> Comp.Composition
applyIdMap m (Comp.Composition stmts) = Comp.Composition (map renameOne stmts)
  where
  renameOne = case _ of
    Comp.StmtCue c -> case Map.lookup c.id m of
      Just newId -> Comp.StmtCue (c { id = newId })
      Nothing -> Comp.StmtCue c
    other -> other

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
