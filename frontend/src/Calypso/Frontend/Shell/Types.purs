module Calypso.Frontend.Shell.Types where

import Prelude

import Data.Array (findIndex, modifyAt)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set as Set
import Data.Set (Set)
import Data.Number as Number
import Data.String as Str
import Data.String.CodeUnits as SCU
import Data.String.Pattern (Pattern(..))
import Data.Tuple (Tuple(..), snd)
import Data.CodePoint.Unicode as CP
import Halogen as H
import Type.Proxy (Proxy(..))

import Calypso.Composition as Comp
import Calypso.Composition.Parser as CompP
import Calypso.Composition.Serializer as CompS
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

-- | Phase 2a (read-only projection): parse the module source as a
-- | composition, find every `cue <id> [meta] = body` declaration, and
-- | lift it into a `CellRec` suitable for display in the Voice Cells
-- | pane. Cue id becomes the cell id; cue body becomes the cell source;
-- | metadata maps directly to the corresponding cell fields.
-- |
-- | Returns `[]` on parse failure — the caller falls back to whatever
-- | cells came over the wire. We don't surface a parse error here: the
-- | existing composition-pane error display already shows it on the
-- | shell's authoritative parse path.
extractCuesAsCellRecs :: String -> Array CellRec
extractCuesAsCellRecs src =
  if isTypefulSource src
    then extractTypefulCuesAsCellRecs src
    else case CompP.parseComposition src of
      Left _ -> []
      Right (Comp.Composition stmts) -> Array.mapMaybe cueToCell stmts
  where
  cueToCell = case _ of
    Comp.StmtCue c -> Just
      { id: c.id
      , kind: "expr"
      , source: c.body
      , author: Nothing
      , mvoice: c.mvoice
      , tvoice: c.tvoice
      }
    _ -> Nothing

-- | Heuristic: does this composition source look like a PureScript
-- | module?  Used by `extractCuesAsCellRecs` to dispatch between the
-- | Level-2 composition parser and the Phase-4 typeful-cues extractor.
-- | A real PS module starts (after blanks/comments) with `module … where`;
-- | we approximate with `"module "` anywhere in the source.  False
-- | positives in pathological Level-2 text are vanishingly unlikely.
isTypefulSource :: String -> Boolean
isTypefulSource src = Str.contains (Pattern "module ") src

-- | Phase 4 (typeful-cues projection): walk PureScript source line-by-line
-- | looking for cue declarations of the form
-- |
-- |     bass1A :: Cue "bass"
-- |     bass1A = on bass1 (mini "c2 e2 g2 ~ b2 ~ ~ g2 e2")
-- |
-- | For each matched pair, produce a `CellRec` with id = cue name,
-- | mvoice = type-level Symbol, tvoice extracted from `on <binding>` in
-- | the RHS, source = body display text (the RHS after `=`).
-- |
-- | Definition lines can span multiple physical lines (next-line
-- | continuations indented under the `=`); v1 takes only the rest of the
-- | declaration line.  Refine if multi-line bodies start appearing.
-- |
-- | The arm button reads `c.id` as the cue name for the typeful path,
-- | so id-as-cue-name is the source-of-truth (and stays stable across
-- | body edits).  Bodies that don't include `on <binding>` produce
-- | `tvoice = Nothing`; the card will need a manual override.
-- | Inverse of `extractTypefulCuesAsCellRecs`: rewrite ONE cue's body
-- | line in source to reflect that cell's current source.  Used at
-- | arm time to roll the just-edited card's body back into the
-- | module source before the typeful build pipeline runs.
-- |
-- | Single-cell scope is deliberate: if cell X has unsaved bad syntax
-- | and the user arms cell Y, only cell Y's body is touched.  Cell X's
-- | body in source stays at the last-built version, so Y can still
-- | arm cleanly.  Without this scoping, a broken edit in one card
-- | would poison every arm — purs compile would fail on Cell X every
-- | time even when the user is trying to test a different cue.
-- |
-- | Conservative: only touches a line if it looks exactly like the
-- | body line the matching extractor would recognise (i.e. the line
-- | directly under a `<name> :: Cue "<mvoice>"` signature where name
-- | equals the target cell's id).  Other top-level bindings
-- | (`session = …`, helper defs) are left alone.
-- |
-- | Multi-line bodies aren't handled — extractor v1 only takes the
-- | first def line, so the same line is the only one we'd rewrite.
syncCellIntoTypefulSource :: CellRec -> String -> String
syncCellIntoTypefulSource cell src =
  let
    cueIds = Set.fromFoldable
      (map _.id (extractTypefulCuesAsCellRecs src))
    lines = Str.split (Pattern "\n") src
    rewriteLine line = case parseDefShape line of
      Just { name, body }
        | name == cell.id
        , Set.member name cueIds
        , cell.source /= body -> name <> " = " <> cell.source
      _ -> line
  in
    Str.joinWith "\n" (map rewriteLine lines)
  where
  -- `<name> = <body>` where <name> is a PS identifier.  No leading
  -- whitespace tolerance — top-level defs only.
  parseDefShape :: String -> Maybe { name :: String, body :: String }
  parseDefShape line = case Str.indexOf (Pattern "=") line of
    Nothing -> Nothing
    Just ix -> do
      let lhs = Str.trim (Str.take ix line)
          rhs = Str.trim (Str.drop (ix + 1) line)
      guardJust (isPsIdent lhs)
      Just { name: lhs, body: rhs }

  isPsIdent :: String -> Boolean
  isPsIdent s = case SCU.toCharArray s of
    [] -> false
    _ -> Str.length (SCU.fromCharArray (Array.takeWhile isIdentChar (SCU.toCharArray s)))
           == Str.length s

  isIdentChar c =
    (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c == '_'
      || c == '\''

  guardJust :: Boolean -> Maybe Unit
  guardJust b = if b then Just unit else Nothing

extractTypefulCuesAsCellRecs :: String -> Array CellRec
extractTypefulCuesAsCellRecs src =
  collectPairs (Str.split (Pattern "\n") src) []
  where
  collectPairs lines acc = case Array.uncons lines of
    Nothing -> Array.reverse acc
    Just { head, tail } -> case parseTypeSig head of
      Just sig ->
        case Array.uncons tail of
          Nothing -> Array.reverse acc
          Just { head: defLine, tail: rest } ->
            case parseDef sig.name defLine of
              Just body ->
                let cell =
                      { id: sig.name
                      , kind: "expr"
                      , source: body
                      , author: Nothing
                      , mvoice: Just sig.mvoice
                      , tvoice: extractTvoiceFromBody body
                      }
                in collectPairs rest (Array.cons cell acc)
              Nothing -> collectPairs rest acc
      Nothing -> collectPairs tail acc

  -- Match `<name> :: Cue "<mvoice>"` with whitespace tolerance.
  parseTypeSig :: String -> Maybe { name :: String, mvoice :: String }
  parseTypeSig line =
    let trimmed = Str.trim line
    in case Str.split (Pattern "::") trimmed of
      [ left, right ] -> do
        let lName = Str.trim left
            rTrim = Str.trim right
        guardJust (isPsIdent lName)
        mv <- extractCueMvoice rTrim
        Just { name: lName, mvoice: mv }
      _ -> Nothing

  -- Match `<name> = <body>` where <name> equals the previous sig's name.
  parseDef :: String -> String -> Maybe String
  parseDef expectedName line =
    let trimmed = Str.trim line
    in case Str.indexOf (Pattern "=") trimmed of
      Nothing -> Nothing
      Just ix -> do
        let lhs = Str.trim (Str.take ix trimmed)
            rhs = Str.trim (Str.drop (ix + 1) trimmed)
        guardJust (lhs == expectedName)
        Just rhs

  -- `Cue "mvoice"` → Just "mvoice"; tolerates extra whitespace.
  extractCueMvoice :: String -> Maybe String
  extractCueMvoice s =
    case Str.indexOf (Pattern "Cue ") s of
      Nothing -> Nothing
      Just _ ->
        case Str.indexOf (Pattern "\"") s of
          Nothing -> Nothing
          Just q1 ->
            let rest = Str.drop (q1 + 1) s
            in case Str.indexOf (Pattern "\"") rest of
              Nothing -> Nothing
              Just q2 -> Just (Str.take q2 rest)

  -- `on bass1 (mini "...")` → Just "bass1"; first occurrence wins.
  extractTvoiceFromBody :: String -> Maybe String
  extractTvoiceFromBody body =
    case Str.indexOf (Pattern "on ") body of
      Nothing -> Nothing
      Just ix ->
        let after = Str.drop (ix + 3) body
            firstWord =
              SCU.fromCharArray
                (Array.takeWhile isIdentChar (SCU.toCharArray after))
        in if Str.null firstWord then Nothing else Just firstWord

  isIdentChar c =
    (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c == '_'
      || c == '\''

  isPsIdent s = case SCU.toCharArray s of
    [] -> false
    _ -> Str.length (SCU.fromCharArray (Array.takeWhile isIdentChar (SCU.toCharArray s))) == Str.length s

  guardJust :: Boolean -> Maybe Unit
  guardJust b = if b then Just unit else Nothing

-- | Extract the names of top-level `Section` declarations from a
-- | composition source.  Mirrors `extractTypefulCuesAsCellRecs` but
-- | matches `<name> :: Section` type signatures.  Used by the
-- | composition pane to render one Play-piece button per detected
-- | section.
extractSectionNames :: String -> Array String
extractSectionNames src =
  Array.mapMaybe parseSectionSig (Str.split (Pattern "\n") src)
  where
  parseSectionSig :: String -> Maybe String
  parseSectionSig line =
    let trimmed = Str.trim line
    in case Str.split (Pattern "::") trimmed of
      [ left, right ] -> do
        let lName = Str.trim left
            rTrim = Str.trim right
        guardJustS (isPsIdentS lName)
        guardJustS (rTrim == "Section")
        Just lName
      _ -> Nothing

  guardJustS :: Boolean -> Maybe Unit
  guardJustS b = if b then Just unit else Nothing

  isIdentCharS c =
    (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c == '_'
      || c == '\''

  isPsIdentS s = case SCU.toCharArray s of
    [] -> false
    _ -> Str.length (SCU.fromCharArray
           (Array.takeWhile isIdentCharS (SCU.toCharArray s))) == Str.length s

-- | Merge composition-derived cells (the new lens) into the existing
-- | cells array (the wire/JSON lens). Used at session-hydrate time;
-- | "wire-loaded wins on id collision" so pre-existing JSON sessions
-- | render unchanged while novel `cue` statements appear as new cards.
mergeCueCells :: Array CellRec -> Array CellRec -> Array CellRec
mergeCueCells existing derived =
  let existingIds = Set.fromFoldable (map _.id existing)
      novel = Array.filter (\c -> not (Set.member c.id existingIds)) derived
  in existing <> novel

-- | Live-edit variant: composition-derived cells WIN on id collision.
-- | Used by `ModuleChanged` so editing a cue body in the composition
-- | pane immediately updates the corresponding card. Without this the
-- | first version of each cue gets stuck in `state.cells` and later
-- | edits are silently dropped.
-- |
-- | Phase 2a accepts this for cue ids only; any wire-loaded cell whose
-- | id collides with a cue is overwritten (correct intent for Phase 2,
-- | where composition is the source of truth). Phase 2b will collapse
-- | this distinction by retiring the wire cells path entirely.
mergeCueCellsCompositionWins :: Array CellRec -> Array CellRec -> Array CellRec
mergeCueCellsCompositionWins existing derived =
  let derivedById = mkById derived
      updated = map (\c -> fromMaybe c (lookupById c.id derivedById)) existing
      existingIds = Set.fromFoldable (map _.id existing)
      novel = Array.filter (\c -> not (Set.member c.id existingIds)) derived
  in updated <> novel
  where
  mkById :: Array CellRec -> Array (Tuple String CellRec)
  mkById = map (\c -> Tuple c.id c)
  lookupById :: String -> Array (Tuple String CellRec) -> Maybe CellRec
  lookupById k = map snd <<< Array.find (\(Tuple k' _) -> k' == k)

-- | Render one cell as a `cue` statement string suitable for
-- | appending to the composition source. Wraps the cell's body in
-- | the canonical cue syntax via the shared serializer so the
-- | re-parse round-trip stays clean.
cellRecAsCueLine :: CellRec -> String
cellRecAsCueLine c = CompS.serializeStatement
  (Comp.StmtCue
    { id: c.id
    , mvoice: c.mvoice
    , tvoice: c.tvoice
    , whenTag: Nothing
    , body: c.source
    })

-- | Level 2 step 2: rename auto-generated `cell-NNN` ids to
-- | tvoice-based names so the level-2 serializer can render them in
-- | the clean named form (`qd1 = body` instead of
-- | `cue cell-005 [tvoice=qd1] = body`).
-- |
-- | Renaming policy:
-- | - Only ids matching the literal pattern `cell-<digits>` are
-- |   touched. User-supplied ids like `test1`, `qd1`, etc. are left
-- |   alone.
-- | - Cells without a tvoice can't be migrated (no name to use); they
-- |   keep their `cell-NNN` id.
-- | - Multiple cells sharing (mvoice, tvoice) get `:a`, `:b`, `:c`
-- |   suffixes assigned in source-order. Single occurrences get no
-- |   suffix.
-- |
-- | Returns the renamed cells AND whether any rename happened, so the
-- | caller can decide whether to push the change to the server.
migrateCellIdsToTvoice
  :: Array CellRec
  -> { cells :: Array CellRec, didRename :: Boolean }
migrateCellIdsToTvoice cells0 =
  let
    -- Preprocess: cells whose body is `set-control <name> <value>` get
    -- their tvoice set to the control name. Lets the level-2 rename
    -- + serializer collapse them into the `name <- value` shorthand.
    cells = map setControlTvoice cells0
    setControlTvoice c = case c.tvoice, parseSetControlBody c.source of
      Nothing, Just { name } -> c { tvoice = Just name }
      _, _ -> c

    -- First pass: count occurrences per (mvoice, tvoice) among the
    -- migration-eligible cells. Lets us decide whether a `:a/:b/:c`
    -- suffix is needed (skipped when only one cell uses this tvoice).
    counts :: Array (Tuple (Tuple (Maybe String) String) Int)
    counts = Array.foldl bumpCount [] cells

    bumpCount acc c = case c.tvoice, isCellNumberedId c.id of
      Just tv, true ->
        let key = Tuple c.mvoice tv
        in case Array.findIndex (\(Tuple k _) -> k == key) acc of
          Just i -> fromMaybe acc (Array.modifyAt i (\(Tuple k n) -> Tuple k (n + 1)) acc)
          Nothing -> Array.snoc acc (Tuple key 1)
      _, _ -> acc

    multCount :: Tuple (Maybe String) String -> Int
    multCount key = fromMaybe 1 do
      Tuple _ n <- Array.find (\(Tuple k _) -> k == key) counts
      pure n

    -- Second pass: assign renamed ids in source-order. Track running
    -- counter so the n-th cell with this (mvoice, tvoice) gets the
    -- n-th suffix.
    renamed = _.cells (Array.foldl step { cells: [], used: [] } cells)

    step st c = case c.tvoice, isCellNumberedId c.id of
      Just tv, true ->
        let
          key = Tuple c.mvoice tv
          mult = multCount key
          idx = nextUsed st.used key
          used' = recordUsed st.used key idx
          newId = if mult <= 1
            then tv
            else tv <> ":" <> suffixLetter idx
        in { cells: Array.snoc st.cells (c { id = newId }), used: used' }
      _, _ -> st { cells = Array.snoc st.cells c }

    nextUsed used key = case Array.find (\(Tuple k _) -> k == key) used of
      Just (Tuple _ n) -> n
      Nothing -> 0
    recordUsed used key n = case Array.findIndex (\(Tuple k _) -> k == key) used of
      Just i -> fromMaybe used (Array.modifyAt i (\(Tuple k _) -> Tuple k (n + 1)) used)
      Nothing -> Array.snoc used (Tuple key (n + 1))

    -- Also consider the set-control tvoice preprocessing a rename
    -- worth syncing to the server (the wire copy of the cell didn't
    -- have tvoice set, so this is genuinely new info to persist).
    tvoiceChanged = Array.any identity
      (Array.zipWith (\a b -> a.tvoice /= b.tvoice) cells0 renamed)
    idChanged = Array.length renamed == Array.length cells
      && Array.any identity (Array.zipWith (\a b -> a.id /= b.id) cells renamed)
    didRename = idChanged || tvoiceChanged
  in { cells: renamed, didRename }

-- | If `body` is exactly `set-control <name> <number>` (whitespace-
-- | tokenised, trimmed), extract the control name and parsed value.
-- | Used by the level-2 migration to auto-derive a tvoice for legacy
-- | set-control cells, and by tests pinning the rename contract.
parseSetControlBody :: String -> Maybe { name :: String, value :: Number }
parseSetControlBody body =
  case Str.split (Pattern " ") (Str.trim body) of
    ["set-control", name, valueStr] -> case Number.fromString valueStr of
      Just value -> Just { name, value }
      Nothing -> Nothing
    _ -> Nothing

-- | `cell-005`, `cell-027` — yes. `cell-`, `cell-abc`, `qd1` — no.
isCellNumberedId :: String -> Boolean
isCellNumberedId s = case Str.stripPrefix (Pattern "cell-") s of
  Just rest -> not (Str.null rest)
    && Array.all CP.isDecDigit (Str.toCodePointArray rest)
  Nothing -> false

-- | Map 0/1/2/... → "a"/"b"/"c"/... for cue-id suffixes. Wraps to
-- | numeric form past 25 (`a..z`, then `1`, `2`, ...) so the suffix
-- | space is unbounded if you somehow end up with 27 cards under one
-- | tvoice. Practically: nobody hits this.
suffixLetter :: Int -> String
suffixLetter i =
  let letters = ['a','b','c','d','e','f','g','h','i','j','k','l','m'
               ,'n','o','p','q','r','s','t','u','v','w','x','y','z']
  in if i < 26
       then SCU.singleton (fromMaybe 'a' (Array.index letters i))
       else show (i - 25)

-- | Phase 2b step 1 (1:1 view commensurability): for each cell in
-- | `state.cells` that isn't already represented as a `cue` declaration
-- | in the composition source, append a `cue` line for it. Idempotent:
-- | running twice on the same input produces no further changes.
-- |
-- | Returns `Just newSource` if any cells needed appending; `Nothing` if
-- | every cell was already a cue in the source (or if the source fails
-- | to parse — in which case we don't dare touch it).
appendUnrepresentedCellsAsCues :: String -> Array CellRec -> Maybe String
appendUnrepresentedCellsAsCues source cells = case CompP.parseComposition source of
  Left _ -> Nothing  -- don't touch a non-parsing source; risks data loss
  Right (Comp.Composition stmts) ->
    let
      existingCueIds = Set.fromFoldable (Array.mapMaybe cueId stmts)
      unrepresented = Array.filter
        (\c -> not (Set.member c.id existingCueIds))
        cells
    in
      if Array.null unrepresented
        then Nothing
        else
          let
            appendix = Str.joinWith "\n" (map cellRecAsCueLine unrepresented)
            -- Ensure a separating blank line. If source already ends in
            -- one newline, add one more so the appended cues sit under
            -- an empty separator line; otherwise add two.
            sep = case Str.stripSuffix (Pattern "\n") source of
              Just _ -> "\n"
              Nothing -> "\n\n"
          in Just (source <> sep <> appendix <> "\n")
  where
  cueId = case _ of
    Comp.StmtCue c -> Just c.id
    _ -> Nothing

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

-- | Daemon-side verbs accepted by purerl-tidal's WS handler. Cells
-- | whose first word is in this set fire as verbs (the existing
-- | per-statement dispatch). Cells whose first word is not in this
-- | set are music cells: they wrap in `cue <body>` + `play-armed
-- | <tvoice> <module>` per the architectural-bet doc (path-2 / path-4
-- | dispatch was retired).
-- |
-- | Keep in sync with `try_parse_prefixed/1` in
-- | `purerl-tidal/src/Tidal/WebSocket/Handler.erl`.
daemonVerbs :: Array String
daemonVerbs =
  -- Transport / lifecycle
  [ "hush", "silence", "state"
  -- Config
  , "bpm", "config", "log-level", "look-ahead-ms", "gate-enabled"
  , "note-duration", "cv-lead-ms", "gate-duration", "channel-offset"
  , "load", "save"
  -- Voices / binding
  , "bind", "unbind", "midi-device"
  -- Cue / play / control bus
  , "cue", "play-armed", "set-control", "release-claim"
  -- Pattern dispatch verbs (carry a pattern body)
  , "midi-note", "midi-cc", "midi-cc-cont", "gate", "cv", "cv-cont"
  -- Aggregate-voice verbs
  , "kit", "chord", "drumkit", "fh2-trigger"
  -- Hardware / device control
  , "midi", "fh2", "es9", "es5", "esx-8gt", "esx-8cv", "fhx-8gt"
  , "osc", "fh2-config", "fh2-gate", "fh2-envelope", "fh2-shape"
  , "yarns"
  -- Polysignal families
  , "polysignal"
  , "polylfo", "polyclock", "polyenv"
  , "polyeuclid", "polyeuclid-pairs", "polyrand"
  ]

-- | True if the cell's first non-comment, non-empty word names a
-- | daemon verb. Music cells (false) flow through cue/play-armed at
-- | fire time; verb cells (true) keep the direct dispatch path.
isVerbCell :: String -> Boolean
isVerbCell src =
  let
    lines = Str.split (Pattern "\n") src
    firstStmt = Array.find (\l -> not (Str.null (stripLineComment l))) lines
    firstWord = case firstStmt of
      Nothing -> ""
      Just l -> case Str.split (Pattern " ") (stripLineComment l) of
        ws -> fromMaybe "" (Array.head (Array.filter (not <<< Str.null) ws))
  in Array.elem firstWord daemonVerbs

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

-- | Short CSS-class token for the tvoice type, used by the CodeMirror
-- | tiderl decorator. JS prepends `cm-tiderl-cue-` to produce the
-- | final class name. Keep in sync with the CSS rules in
-- | `frontend/public/style.css` under "Tiderl cue keyword colours".
tvoiceTypeShortClass :: TvoiceType -> String
tvoiceTypeShortClass = case _ of
  TvMidi -> "midi"
  TvCV -> "cv"
  TvGate -> "gate"
  TvSample -> "sample"
  TvPolySignal _ -> "polysignal"
  TvUnknown -> "unknown"

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
  -- | The composition source currently *built into the BEAM* (last
  -- | successful `buildSessionRequest`).  Distinct from
  -- | `lastSyncedModule` which tracks server-state sync — that just
  -- | updates Calypso's in-memory store, not the compiled
  -- | `Calypso.Generated.Session.beam`.  Read by `ArmTypefulCue` to
  -- | decide whether to fire a full build+reload before arming.
  , lastBuiltModule :: String
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
  -- Phase 4 typeful-cues fire — POST /session-source with the
  -- composition source as a PureScript module.  Server writes it to
  -- Calypso.Generated.Session.purs, builds via purs + backend-erl
  -- --filter + erlc, then asks purerl-tidal to reload-baseline.
  -- Voices currently playing keep their captured patterns until
  -- re-armed; arm afterward to pick up new cue bodies cleanly.
  | FireTypefulComposition String
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
  -- Typeful-cues arm — `(cellId, tvoice, cueName)`.  Hits the
  -- backend's POST /arm which ships `play-armed <tvoice> <cueName>`
  -- to purerl-tidal in a single WS round-trip; the BEAM resolves the
  -- cue by calling calypso_generated_session@ps:<cueName>/0.
  | ArmTypefulCue String String String
  -- Silence one voice — `(cellId, tvoice)`.  Sends `silence <tvoice>`
  -- through /eval; the BEAM clears the voice's pattern but keeps the
  -- binding so re-arming restarts it cleanly.
  | SilenceVoice String String
  | UpdateCellTvoice String String
  | UpdateCellMvoice String String
  | NewVoiceCard
  | LoadHistoryEntry String String String
  -- MVP-2 conductor: send `play-piece <name>` / `stop-piece` over /eval.
  -- The named value must be a `Section` (Pattern AnyCue) at module
  -- top-level in Calypso.Generated.Session.
  | PlayPiece String
  | StopPiece
  | Startup
