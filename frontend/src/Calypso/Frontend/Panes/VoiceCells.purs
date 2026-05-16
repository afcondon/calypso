module Calypso.Frontend.Panes.VoiceCells where

import Prelude

import Data.Array (mapWithIndex)
import Data.Array as Array
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Set as Set
import Data.String as Str
import Data.String.Pattern (Pattern(..))
import Data.Tuple (Tuple(..))
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import Calypso.Composition as Comp
import Calypso.Frontend.Editor as Editor
import Calypso.Frontend.Shell.Types
  ( Action(..)
  , CellRec
  , Section(..)
  , Slots
  , State
  , TvoiceType(..)
  , _editorModal
  , cellSection
  , extractTypefulCuesAsCellRecs
  , isTypefulSource
  , stripLineComment
  , tvoiceTypeClass
  , tvoiceTypeLabel
  )

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
renderCanvas
  :: forall m. MonadAff m
  => State
  -> Array (H.ComponentHTML Action Slots m)
renderCanvas state =
  let
    isConfigCell c =
      let sec = cellSection c in sec == SecConfig || sec == SecVoices
    configCells = Array.filter isConfigCell state.cells
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
                   in case Array.head stackCells of
                     -- Group filtered to empty (typeful mode dropped this
                     -- mvoice's wire cells).  Skip rendering entirely;
                     -- don't fall back to `c` — `c` is the unfiltered head
                     -- and might be the very wire cell we just hid.
                     Nothing ->
                       walk rest (Set.insert mvoice renderedMvoices) renderedConfig
                     Just lead ->
                       let
                         rendered =
                           if Array.length stackCells == 1
                             then renderVoiceCard state CardLone lead
                             else if state.fannedMvoice == Just mvoice
                               then renderFannedMusicStack state mvoice stackCells
                               else renderCollapsedMusicStack state mvoice stackCells
                       in
                         rendered Array.: walk rest (Set.insert mvoice renderedMvoices) renderedConfig
  in
    walk state.cells Set.empty false

-- | The mvoice label a cell currently belongs to: cellMvoice
-- | override, else cellTvoice override, else extracted from the
-- | source's first identifier.
effectiveMvoice :: State -> CellRec -> String
effectiveMvoice _ c =
  let tvoiceName = fromMaybe (extractTvoice c.source) c.tvoice
  in fromMaybe tvoiceName c.mvoice

-- | All non-config cells whose effective mvoice equals the given label.
-- |
-- | In typeful mode (composition source is PureScript), we also drop any
-- | music cell whose id isn't in the freshly-extracted set of typed cue
-- | declarations — wire-loaded Level-2 cells survive across composition
-- | swaps and their arm buttons would fail (their ids aren't valid PS
-- | identifiers).  Config cells stay visible either way: rig setup is
-- | still Level-2 wire commands.
mvoiceGroupCells :: State -> String -> Array CellRec
mvoiceGroupCells state mvoice =
  let typefulMode = isTypefulSource state.moduleSource
      typefulIds = if typefulMode
        then Set.fromFoldable
          (map _.id (extractTypefulCuesAsCellRecs state.moduleSource))
        else Set.empty
      isVisible c =
        let sec = cellSection c
            isConfig = sec == SecConfig || sec == SecVoices
            matchesMvoice = effectiveMvoice state c == mvoice
            visibleByMode =
              if typefulMode then Set.member c.id typefulIds else true
        in not isConfig && matchesMvoice && visibleByMode
  in Array.filter isVisible state.cells

-- | Apply user-specified ordering (mvoiceOrder) to a group of cells.
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

renderCollapsedMusicStack
  :: forall m. MonadAff m
  => State
  -> String
  -> Array CellRec
  -> H.ComponentHTML Action Slots m
renderCollapsedMusicStack state _mvoice cells =
  let
    total = Array.length cells
    stackHeightPx = (total - 1) * 22 + 140
  in
    HH.div
      [ HP.class_ (H.ClassName "voice-stack")
      , HP.style ("height: " <> show stackHeightPx <> "px;")
      ]
      (mapWithIndex (renderStackedCard state total) cells)

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

renderStackedCard
  :: forall m. MonadAff m
  => State
  -> Int
  -> Int
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
  = CardLone
  | CardStackedFront
  | CardStackedBehind
  | CardFanned
  | CardConfigFront
  | CardConfigBehind
  | CardConfigFanned

derive instance Eq CardKind

renderVoiceCard
  :: forall m. MonadAff m
  => State
  -> CardKind
  -> CellRec
  -> H.ComponentHTML Action Slots m
renderVoiceCard state kind c =
  let
    tvoiceName = fromMaybe (extractTvoice c.source) c.tvoice
    mvoiceName = fromMaybe tvoiceName c.mvoice
    cardTitle = mvoiceName <> ":" <> tvoiceName
    bodyPreview = previewBody c.source
    isConfig = kind == CardConfigFront || kind == CardConfigBehind || kind == CardConfigFanned
    isCompact = kind == CardStackedBehind || kind == CardConfigBehind
    tvoiceType = case cellPolyFamily c.source of
      Just family -> TvPolySignal family
      Nothing -> fromMaybe TvUnknown (Map.lookup tvoiceName state.tvoiceTypes)
    typeClass = " " <> tvoiceTypeClass tvoiceType
    polySignalClass = case tvoiceType of
      TvPolySignal _ -> " voice-card-polysignal"
      _ -> ""
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
                          [ HP.class_ (H.ClassName "voice-card-btn voice-card-arm")
                          , HE.onClick \_ -> ArmTypefulCue c.id tvoiceName c.id
                          , HP.title "arm — compile + hot-load this cue"
                          ]
                          [ HH.text "arm" ]
                      , HH.button
                          [ HP.class_ (H.ClassName "voice-card-btn voice-card-silence")
                          , HE.onClick \_ -> SilenceVoice c.id tvoiceName
                          , HP.title ("silence — clear the pattern on " <> tvoiceName)
                          ]
                          [ HH.text "silence" ]
                      ]
                )
            ])
      )

-- | Modal pop-out editor.  When `editingCard = Just id`, renders a
-- | dim backdrop + a 3×-scale card on top, hosting the existing
-- | CodeMirror Editor component.
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
        tvoiceName = fromMaybe defaultTvoice c.tvoice
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
          [ HH.div
              [ HP.class_ (H.ClassName "voice-edit-backdrop")
              , HE.onClick \_ -> CloseEditor
              ]
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
                  , HH.input
                      [ HP.class_ (H.ClassName "voice-edit-mvoice")
                      , HP.value mvoiceName
                      , HP.placeholder "mvoice"
                      , HP.title "mvoice — column label (user-assigned).  Commit on blur or Enter."
                      , HE.onValueChange \v -> UpdateCellMvoice c.id v
                      ]
                  , HH.span [ HP.class_ (H.ClassName "voice-edit-sep") ]
                      [ HH.text ":" ]
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
                      -- Cell-edit modal sees only one cell's body, no
                      -- composition-level `cue` lines, so the tiderl
                      -- decorator has nothing to colour here. Empty
                      -- array is correct.
                      , tvoiceColors: []
                      }
                      (modalEditorOutput c.id)
                  ]
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
                              [ HH.text " " ]
                          ]
                  )
              , HH.div [ HP.class_ (H.ClassName "voice-card-footer voice-edit-footer") ]
                  ( if isConfig
                      then
                        [ HH.button
                            [ HP.class_ (H.ClassName "voice-card-btn voice-card-play")
                            , HE.onClick \_ -> CommitEdit c.id c.source
                            , HP.title "fire this config statement (Cmd-Enter)"
                            ]
                            [ HH.text "▶" ]
                        ]
                      else
                        let cueInFlight = Set.member c.id state.cuePending
                        in
                        [ HH.button
                            ( [ HP.class_
                                  ( H.ClassName
                                      ( "voice-card-btn voice-card-arm"
                                          <> if cueInFlight then " is-disabled" else ""
                                      )
                                  )
                              , HP.title
                                  ( if cueInFlight
                                      then "arm in progress"
                                      else "arm — compile + hot-load this cue (Cmd-Enter)"
                                  )
                              , HP.disabled cueInFlight
                              ]
                              <> if cueInFlight then [] else
                                   [ HE.onClick \_ ->
                                       ArmTypefulCue c.id tvoiceName c.id
                                   ]
                            )
                            [ HH.text (if cueInFlight then "…" else "arm") ]
                        , HH.button
                            [ HP.class_ (H.ClassName "voice-card-btn voice-card-silence")
                            , HE.onClick \_ -> SilenceVoice c.id tvoiceName
                            , HP.title ("silence — clear the pattern on " <> tvoiceName)
                            ]
                            [ HH.text "silence" ]
                        ]
                  )
              ]
          ]
  where
    modalEditorOutput cid = case _ of
      Editor.Changed src -> CellChanged cid src
      Editor.Submitted src -> CommitEdit cid src
      Editor.AcceptHunkO pid idx -> AcceptHunk pid idx
      Editor.RejectHunkO pid idx -> RejectHunk pid idx
      Editor.MoveRequested -> CloseEditor

-- | Opacity for a history row at depth `idx` (0 = most recent).
-- | Linear decay with a floor so rows are always slightly visible.
historyOpacity :: Int -> String
historyOpacity idx =
  let f = max 0.12 (1.0 - Int.toNumber idx * 0.10)
  in show f

-- | Cheap heuristic: pick a glyph based on the first verb/word of
-- | the cell's source.
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
    "polylfo"          -> "∿"
    "polyclock"        -> "▣"
    "polyenv"          -> "◣"
    "polyeuclid"       -> "◇"
    "polyeuclid-pairs" -> "◈"
    "polyrand"         -> "⌖"
    _ ->
      let body = Str.toLower src
      in if Str.contains (Pattern "sine") body
         || Str.contains (Pattern "saw") body
         || Str.contains (Pattern "tri") body
         || Str.contains (Pattern "square") body
         || Str.contains (Pattern "cosine") body
         || Str.contains (Pattern ":slow") body
         then "◇"
         else if Str.contains (Pattern "midi-cc-cont") body
                 || Str.contains (Pattern "cv-cont") body
              then "⬡"
              else "▲"

-- | First word of the first non-comment, non-empty line. Polysignal
-- | cells return the alias (second word) so the tvoice lookup resolves.
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

isPolySignalVerb :: String -> Boolean
isPolySignalVerb = case _ of
  "polylfo"          -> true
  "polyclock"        -> true
  "polyenv"          -> true
  "polyeuclid"       -> true
  "polyeuclid-pairs" -> true
  "polyrand"         -> true
  _ -> false

-- | True for polysignal families that need the FH-2's internal clock
-- | to be ticking to produce output.
isClockDependentPolyVerb :: String -> Boolean
isClockDependentPolyVerb = case _ of
  "polyclock"        -> true
  "polyeuclid"       -> true
  "polyeuclid-pairs" -> true
  "polyrand"         -> true
  _ -> false

-- | Does the source contain at least one clock-dependent polysignal
-- | family? Used by the fire path to decide whether to surface the
-- | Clk reminder.
hasClockDependentPolySignal :: String -> Boolean
hasClockDependentPolySignal src =
  let lines = Str.split (Pattern "\n") src
      firstWord l =
        let trimmed = Str.trim (stripLineComment l)
        in case Array.head (Array.filter (not <<< Str.null) (Str.split (Pattern " ") trimmed)) of
             Just w -> w
             Nothing -> ""
  in Array.any (isClockDependentPolyVerb <<< firstWord) lines

-- | Reminder text shown in the Clk-reminder toast.
clkReminderText :: String
clkReminderText =
  "This polysignal needs the FH-2 to be clocked. "
    <> "Confirm front-panel shows Clk: Int (always runs at displayed BPM) "
    <> "— or USB/DIN/X-in with an active source — otherwise the FH-2 will "
    <> "load the config silently and produce no output."

-- | Cell-local polysignal detection.
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

-- | Compact body preview for the card face.
previewBody :: String -> String
previewBody src =
  let lines = Array.filter (not <<< Str.null)
                (map stripLineComment (Str.split (Pattern "\n") src))
      joined = Str.joinWith " · " lines
  in if Str.length joined > 80 then Str.take 77 joined <> "…" else joined
