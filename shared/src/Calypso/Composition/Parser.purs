-- | Parser for the Calypso composition grammar.  See
-- | `docs/composition-grammar.md` for the spec and
-- | `Calypso.Composition` for the AST.
-- |
-- | The top-level entrypoint is `parseComposition :: String -> Either
-- | ParseError Composition`.  `parseStatement` parses one line in
-- | isolation and is exposed for tests.
module Calypso.Composition.Parser
  ( parseComposition
  , parseStatement
  , compositionP
  , statementP
  , collapsePolySignalBlocks
  , collapsePolySignalEntries
  , collapseMacroEntries
  , polySignalEnvelopeJson
  , prettyPolySignal
  , autoformatPolySignalCell
  ) where

import Prelude

import Calypso.Composition
  ( Bank(..)
  , Binding(..)
  , Composition(..)
  , ControlStmt
  , CueStmt
  , CvBinding
  , CvMode(..)
  , Device(..)
  , DeviceConfig(..)
  , ExpanderDevice
  , Fh2VoiceConfig
  , Fh2VoiceMode(..)
  , Fh2ModeConfig
  , GateBinding
  , Latency
  , MidiCcBinding
  , MidiNoteBinding
  , OscDevice
  , OutRef(..)
  , PolyFamily(..)
  , PolySignalConfig
  , PolySlot
  , PolyValue(..)
  , RootDevice
  , Statement(..)
  , TagStmt
  )
import Control.Alt ((<|>))
import Data.Array (many)
import Data.Array as Array
import Data.CodePoint.Unicode as CP
import Data.Either (Either(..))
import Data.Foldable (elem) as F
import Data.Foldable (all, foldl)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String (CodePoint, codePointFromChar)
import Data.String (Pattern(..), joinWith, length, null, split, stripPrefix, stripSuffix, trim) as Str
import Data.String.CodeUnits as SCU
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Parsing (ParseError, Parser, fail, runParser)
import Parsing.Combinators (choice, optionMaybe, try)
import Parsing.String (char, eof, satisfy, string)
import Parsing.String.Basic (intDecimal, number, takeWhile1)

-- ───────────────────────────────────────────────────────────────────
-- Public entry points
-- ───────────────────────────────────────────────────────────────────

parseComposition :: String -> Either ParseError Composition
parseComposition input = case runParser input compositionP of
  Left e -> Left e
  Right (Composition stmts) -> Right (Composition (resolveSections stmts))

-- | Post-parse pass: walk the flat statement list, track the running
-- | section's mvoice context, and fill it into any StmtCue whose
-- | own mvoice field is Nothing. StmtSection markers are dropped from
-- | the result — they're consumed by this pass. Cues with explicit
-- | mvoice metadata (from the old `cue <id> [mvoice=...]` form) are
-- | left untouched.
resolveSections :: Array Statement -> Array Statement
resolveSections = Array.reverse <<< _.acc <<< foldl step { acc: [], current: Nothing }
  where
  step state stmt = case stmt of
    StmtSection name -> state { current = Just name }
    StmtCue c -> case c.mvoice of
      Nothing -> state { acc = Array.cons (StmtCue (c { mvoice = state.current })) state.acc }
      Just _  -> state { acc = Array.cons stmt state.acc }
    _ -> state { acc = Array.cons stmt state.acc }

parseStatement :: String -> Either ParseError Statement
parseStatement input = runParser input (skipFiller *> statementP <* skipFiller <* eof)

-- ───────────────────────────────────────────────────────────────────
-- Whitespace, comments, separators
-- ───────────────────────────────────────────────────────────────────

cpSpace :: CodePoint
cpSpace = codePointFromChar ' '

cpTab :: CodePoint
cpTab = codePointFromChar '\t'

isHSpaceCP :: CodePoint -> Boolean
isHSpaceCP cp = cp == cpSpace || cp == cpTab

-- | One or more spaces or tabs (NOT newlines).  Inside a single
-- | statement.
hspace1 :: Parser String Unit
hspace1 = void (takeWhile1 isHSpaceCP)

hspace :: Parser String Unit
hspace = void (optionMaybe hspace1)

-- | A comment from `--` or `#` up to (but not including) the next
-- | newline.
commentP :: Parser String Unit
commentP = (commentStart *> consumeRest)
  where
  commentStart = void (try (string "--")) <|> void (char '#')
  consumeRest = void (many (satisfy (\c -> c /= '\n' && c /= '\r')))

-- | Filler between statements: any mix of horizontal whitespace,
-- | newlines, and comments.  Reduces to "next meaningful char."
skipFiller :: Parser String Unit
skipFiller = void $ many $
  void (satisfy isSpaceish)
    <|> commentP
  where
  isSpaceish c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

-- ───────────────────────────────────────────────────────────────────
-- Tokens
-- ───────────────────────────────────────────────────────────────────

isIdentStartCP :: CodePoint -> Boolean
isIdentStartCP = CP.isAlpha

isIdentRestCP :: CodePoint -> Boolean
isIdentRestCP cp = CP.isAlphaNum cp
  || cp == codePointFromChar '_'
  || cp == codePointFromChar '-'

-- | Identifier: `[a-zA-Z][a-zA-Z0-9_-]*` — used for keywords, device
-- | aliases, binding names, mode words.
identP :: Parser String String
identP = do
  first <- satisfy (isIdentStartCP <<< codePointFromChar)
  rest <- optionMaybe (takeWhile1 isIdentRestCP)
  pure (SCU.singleton first <> case rest of
    Nothing -> ""
    Just r -> r)

-- | Match a literal keyword followed by horizontal whitespace.  The
-- | trailing whitespace prevents `lat` from matching the start of
-- | `latency`.
keyword :: String -> Parser String Unit
keyword kw = try (string kw *> hspace1)

-- | Quoted string with `\"` and `\\` escapes.
stringLit :: Parser String String
stringLit = char '"' *> bodyP <* char '"'
  where
  bodyP = do
    chars <- many quotedChar
    pure (charsToStr chars)
  quotedChar =
    (try (string "\\\"") *> pure '"')
      <|> (try (string "\\\\") *> pure '\\')
      <|> satisfy (\c -> c /= '"' && c /= '\\')

charsToStr :: Array Char -> String
charsToStr = SCU.fromCharArray

-- | Optional `latency N` clause. Also accepts the abbreviated `lat N`
-- | form used by every setup file in `purerl-tidal/setup/*.tidal` and
-- | by the daemon's `midi-device` arm — Calypso's typed grammar should
-- | not be more restrictive than the wire syntax it's meant to mirror.
latencyClauseP :: Parser String (Maybe Latency)
latencyClauseP =
  optionMaybe
    ( try (hspace1 *> (try (keyword "latency") <|> keyword "lat") *> number) )

-- | `<key>=<int>` pair.  Whitespace not allowed around `=`.
kvIntP :: String -> Parser String Int
kvIntP key = try (string key *> char '=' *> intDecimal)

-- | `<key>=<out-ref>` pair.
kvOutRefP :: String -> Parser String OutRef
kvOutRefP key = try (string key *> char '=' *> outRefP)

-- | Output reference: bare integer (local MCV) or `<alias>:<int>`
-- | (expander slot).
outRefP :: Parser String OutRef
outRefP = try expander <|> local
  where
  local = OutLocal <$> intDecimal
  expander = do
    alias <- identP
    _ <- char ':'
    slot <- intDecimal
    pure (OutExpander alias slot)

-- ───────────────────────────────────────────────────────────────────
-- Top-level grammar
-- ───────────────────────────────────────────────────────────────────

compositionP :: Parser String Composition
compositionP = do
  skipFiller
  stmts <- many (statementP <* skipFiller)
  eof
  pure (Composition stmts)

statementP :: Parser String Statement
statementP = choice
  [ try (StmtSection <$> sectionHeaderP)
  , try (StmtCue <$> cueP)
  , try (StmtBpm <$> bpmP)
  , try (StmtLinkSync <$> linkSyncP)
  , try (StmtControl <$> controlP)
  , try (StmtTag <$> tagDeclP)
  , try (StmtBinding <$> bindingP)
  , try (StmtDeviceConfig <$> deviceConfigP)
  , try (StmtDevice <$> deviceP)
  -- Level 2 named-cue form: <tvoice>[:<suffix>] = <body> or indented.
  -- Must be the LAST alternative so existing keyword-led statements
  -- (binding/device/etc.) try their keyword prefixes first.
  , StmtCue <$> namedCueP
  ] <* hspace <* optionMaybe commentP

-- | `section <Name>` header. Sets the mvoice context for subsequent
-- | `<tvoice> = <body>` named-cue declarations.
sectionHeaderP :: Parser String String
sectionHeaderP = do
  _ <- keyword "section"
  name <- identP
  pure name

-- | Level 2 named-cue form: `<tvoice>[:<suffix>] = <body>` or
-- | `<tvoice>[:<suffix>]\n  <body>`. Mvoice is taken from the most
-- | recent preceding `section` header by `resolveSections` after the
-- | flat parse — `namedCueP` itself returns `mvoice: Nothing`.
-- |
-- | Also recognises the `<name> <- <value>` set-control shorthand,
-- | which sugars to a cue whose body is `set-control <name> <value>`.
-- | Reads as "set this control's value" and sits nicely alongside
-- | pattern cues in the same `section ctrl` block.
namedCueP :: Parser String CueStmt
namedCueP = do
  tvoice <- identP
  suffix <- optionMaybe (try (char ':' *> identP))
  body <- (try (setControlSugarP tvoice)) <|> (try inlineCueBodyP) <|> indentedCueBodyP
  let
    id = case suffix of
      Just s -> tvoice <> ":" <> s
      Nothing -> tvoice
  pure
    { id
    , mvoice: Nothing  -- resolved by resolveSections after the flat parse
    , tvoice: Just tvoice
    , whenTag: Nothing
    , body
    }

-- | `<- <number>` after the identifier sugars to
-- | `set-control <ident> <value>`. The captured ident IS the control
-- | name. Body is canonical PureScript-ish form so re-parse + redispatch
-- | through the regular `set-control` verb stays simple.
setControlSugarP :: String -> Parser String String
setControlSugarP controlName = do
  _ <- hspace
  _ <- string "<-"
  _ <- hspace
  value <- number
  pure ("set-control " <> controlName <> " " <> show value)

-- ───────────────────────────────────────────────────────────────────
-- Transport / Controls / Tags / Cues  (Phase 1 of .tiderl)
-- ───────────────────────────────────────────────────────────────────

-- | `bpm <number>`. Default tempo declaration; the runtime treats
-- | this as the value to broadcast over Link when no peer-tempo is
-- | present.
bpmP :: Parser String Number
bpmP = do
  _ <- keyword "bpm"
  number

-- | `link sync on` / `link sync off`. Boolean — whether to follow
-- | the Link mesh's tempo (true) or hold the declared bpm fixed
-- | regardless of peers (false).
linkSyncP :: Parser String Boolean
linkSyncP = do
  _ <- keyword "link"
  _ <- keyword "sync"
  word <- identP
  case word of
    "on" -> pure true
    "off" -> pure false
    other -> fail ("link sync expects on|off, got: " <> other)

-- | `control <name> = <number>`. Initial value for the live-control
-- | bus slot of the given name.
controlP :: Parser String ControlStmt
controlP = do
  _ <- keyword "control"
  name <- identP
  _ <- hspace
  _ <- char '='
  _ <- hspace
  value <- number
  pure { name, value }

-- | `tag <name> = <string>`. Initial value for the tag bus slot
-- | (a named string-valued runtime state). Booleans are spelled as
-- | the strings "on"/"off"; other values are user-defined enums
-- | (e.g. "verse"/"chorus") consumed by `byTag` combinators.
tagDeclP :: Parser String TagStmt
tagDeclP = do
  _ <- keyword "tag"
  name <- identP
  _ <- hspace
  _ <- char '='
  _ <- hspace
  defaultValue <- tagValueP
  pure { name, defaultValue }
  where
  -- Tag values are bare words (identifiers); future versions may
  -- accept quoted strings if values need spaces or special chars.
  tagValueP = identP

-- | `cue <id> [<key>=<value> ...] <body>`. Two forms:
-- |
-- | Inline (compact, for short bodies):
-- |   cue d1 [mvoice=drums tvoice=qd1] = mini "x ~ x ~"
-- |
-- | Indented continuation (canonical, supports multi-line):
-- |   cue d1 [mvoice=drums tvoice=qd1]
-- |     mini "x ~ x ~"
-- |
-- | For the indented form, the body is the concatenation of one or
-- | more continuation lines that share at least one column of leading
-- | horizontal whitespace. The common indent is stripped on capture,
-- | so the stored `body` reads exactly as cell text.
cueP :: Parser String CueStmt
cueP = do
  _ <- keyword "cue"
  id <- identP
  meta <- optionMaybe (try (hspace1 *> cueMetaP))
  body <- (try inlineCueBodyP) <|> indentedCueBodyP
  let
    m = fromMaybe emptyMeta meta
  pure
    { id
    , mvoice: m.mvoice
    , tvoice: m.tvoice
    , whenTag: m.whenTag
    , body
    }
  where
  emptyMeta = { mvoice: Nothing, tvoice: Nothing, whenTag: Nothing }

-- | `= <body>` on the same line as the header.
inlineCueBodyP :: Parser String String
inlineCueBodyP = do
  _ <- hspace
  _ <- char '='
  _ <- hspace
  raw <- takeWhile1 (\cp -> cp /= cpNewline && cp /= cpReturn)
  pure (Str.trim raw)

-- | Continuation lines after the header. The header line is consumed
-- | up to (and including) its terminating newline; then one or more
-- | indented lines form the body. Body terminates at the first
-- | non-blank line whose first column is non-whitespace.
indentedCueBodyP :: Parser String String
indentedCueBodyP = do
  _ <- hspace
  _ <- optionMaybe commentP
  _ <- lineEndingP
  -- Allow blank lines between header and first body line.
  _ <- many blankLineP
  firstLine <- indentedCueLineP
  rest <- many (try (blankPreceded indentedCueLineP))
  let lines = Array.cons firstLine rest
  pure (dedentJoin lines)

-- | One indented body line: leading horizontal whitespace (the indent),
-- | then at least one character of content. Returns the (indent, content)
-- | pair so the caller can compute the common indent for dedent.
indentedCueLineP :: Parser String { indent :: String, content :: String }
indentedCueLineP = do
  indent <- takeWhile1 isHSpaceCP
  content <- takeWhile1 (\cp -> cp /= cpNewline && cp /= cpReturn)
  _ <- optionMaybe lineEndingP
  pure { indent, content }

-- | One line ending: `\r\n`, `\n`, or bare `\r`. Returns unit.
lineEndingP :: Parser String Unit
lineEndingP =
  try (void (string "\r\n"))
    <|> void (char '\n')
    <|> void (char '\r')

-- | A line that is entirely blank (zero or more whitespace, then newline).
blankLineP :: Parser String Unit
blankLineP = try do
  _ <- many (satisfy (\c -> c == ' ' || c == '\t'))
  lineEndingP

-- | Consume zero-or-more blank lines, then parse the inner combinator.
-- | Used to allow user comments / spacing inside an indented cue body
-- | without breaking the block.
blankPreceded :: forall a. Parser String a -> Parser String a
blankPreceded p = do
  _ <- many blankLineP
  p

-- | Strip the common leading indent from a non-empty list of body
-- | lines and join with `\n`. The common indent is the longest prefix
-- | of horizontal whitespace shared by every line's stored indent.
dedentJoin :: Array { indent :: String, content :: String } -> String
dedentJoin lines =
  let common = commonPrefix (map _.indent lines)
      stripCommon line = case Str.stripPrefix (Str.Pattern common) line.indent of
        Just suffix -> suffix <> line.content
        Nothing -> line.content
  in Str.joinWith "\n" (map stripCommon lines)

-- | Longest shared leading-character prefix of an array of strings.
commonPrefix :: Array String -> String
commonPrefix = case _ of
  [] -> ""
  arr -> case Array.head arr of
    Nothing -> ""
    Just first -> foldl shared first (fromMaybe [] (Array.tail arr))
  where
  shared a b =
    let n = sharedLength a b 0
    in SCU.take n a
  sharedLength a b i =
    case SCU.charAt i a, SCU.charAt i b of
      Just ca, Just cb | ca == cb -> sharedLength a b (i + 1)
      _, _ -> i

-- | `[key=value key=value ...]` — bracketed metadata for cue
-- | declarations. Whitespace-separated key=value pairs.
cueMetaP :: Parser String { mvoice :: Maybe String, tvoice :: Maybe String, whenTag :: Maybe String }
cueMetaP = do
  _ <- char '['
  _ <- hspace
  pairs <- cueMetaPairsP
  _ <- hspace
  _ <- char ']'
  pure (foldCueMeta pairs)

cueMetaPairsP :: Parser String (Array (Tuple String String))
cueMetaPairsP = do
  first <- optionMaybe cueKvP
  case first of
    Nothing -> pure []
    Just p -> do
      rest <- many (try (hspace1 *> cueKvP))
      pure ([p] <> rest)

cueKvP :: Parser String (Tuple String String)
cueKvP = do
  key <- identP
  _ <- char '='
  value <- identP
  pure (Tuple key value)

foldCueMeta
  :: Array (Tuple String String)
  -> { mvoice :: Maybe String, tvoice :: Maybe String, whenTag :: Maybe String }
foldCueMeta = Array.foldl step
  { mvoice: Nothing, tvoice: Nothing, whenTag: Nothing }
  where
  step acc (Tuple k v) = case k of
    "mvoice" -> acc { mvoice = Just v }
    "tvoice" -> acc { tvoice = Just v }
    "when"   -> acc { whenTag = Just v }
    _ -> acc  -- unknown keys silently ignored; future-compat

cpNewline :: CodePoint
cpNewline = codePointFromChar '\n'

cpReturn :: CodePoint
cpReturn = codePointFromChar '\r'

-- ───────────────────────────────────────────────────────────────────
-- Devices
-- ───────────────────────────────────────────────────────────────────

deviceP :: Parser String Device
deviceP = choice $ map try
  [ DevMidi    <$> rootDeviceP "midi"
  , DevEs9     <$> rootDeviceP "es9"
  , DevFh2     <$> rootDeviceP "fh2"
  , DevYarns   <$> rootDeviceP "yarns"
  , DevOsc     <$> oscDeviceP
  , DevEs5     <$> expanderDeviceP "es5"
  , DevEsx8Gt  <$> expanderDeviceP "esx-8gt"
  , DevEsx8Cv  <$> expanderDeviceP "esx-8cv"
  , DevFhx8Gt  <$> expanderDeviceP "fhx-8gt"
  ]

-- | Root device: `<type> <alias> <port-string> [latency N]`.
rootDeviceP :: String -> Parser String RootDevice
rootDeviceP typeKw = do
  _ <- keyword typeKw
  alias <- identP
  _ <- hspace1
  port <- stringLit
  latency <- latencyClauseP
  pure { alias, port, latency }

-- | Expander: `<type> <alias> on <parent-alias>`.
expanderDeviceP :: String -> Parser String ExpanderDevice
expanderDeviceP typeKw = do
  _ <- keyword typeKw
  alias <- identP
  _ <- hspace1
  _ <- string "on"
  _ <- hspace1
  parent <- identP
  pure { alias, parent }

-- | OSC: `osc <alias> host=<host> port=<int>`.
oscDeviceP :: Parser String OscDevice
oscDeviceP = do
  _ <- keyword "osc"
  alias <- identP
  _ <- hspace1
  _ <- string "host"
  _ <- char '='
  host <- hostnameP
  _ <- hspace1
  port <- kvIntP "port"
  pure { alias, host, port }

-- | Hostname token: lets `127.0.0.1`, `localhost`, etc. through.
hostnameP :: Parser String String
hostnameP = takeWhile1 isHostCP
  where
  isHostCP cp = CP.isAlphaNum cp
    || cp == codePointFromChar '.'
    || cp == codePointFromChar '-'
    || cp == codePointFromChar '_'

-- ───────────────────────────────────────────────────────────────────
-- Device-internal config
-- ───────────────────────────────────────────────────────────────────

deviceConfigP :: Parser String DeviceConfig
deviceConfigP = choice $ map try
  -- fh2-mode must precede fh2-config: the `keyword` parser consumes the
  -- "fh2-" prefix and would otherwise commit to the wrong branch.
  [ PolySignalCfg <$> polySignalConfigP
  , Fh2ModeCfg   <$> fh2ModeConfigP
  , Fh2VoiceCfg  <$> fh2ConfigP
  ]

-- | `fh2-config <alias>:<mode> voice=N out=O ch=K`.
fh2ConfigP :: Parser String Fh2VoiceConfig
fh2ConfigP = do
  _ <- keyword "fh2-config"
  device <- identP
  _ <- char ':'
  mode <- fh2VoiceModeP
  _ <- hspace1
  voice <- kvIntP "voice"
  _ <- hspace1
  out <- kvOutRefP "out"
  _ <- hspace1
  channel <- kvIntP "ch"
  pure { device, mode, voice, out, channel }

-- | `fh2-mode <alias>:<name>`. Names refer to entries in the fh2-config
-- | mode registry (`FH2.Modes.availableModes` — currently "ochd", "pnw").
-- | The parser doesn't validate the name against the registry — that's
-- | the dispatch layer's job at apply time, so the grammar stays decoupled
-- | from the mode catalogue.
fh2ModeConfigP :: Parser String Fh2ModeConfig
fh2ModeConfigP = do
  _ <- keyword "fh2-mode"
  device <- identP
  _ <- char ':'
  modeName <- identP
  pure { device, modeName }

fh2VoiceModeP :: Parser String Fh2VoiceMode
fh2VoiceModeP = do
  word <- identP
  case word of
    "envelope" -> pure Fh2Envelope
    "gate" -> pure Fh2Gate
    other -> fail ("unknown FH-2 voice mode: " <> other)

-- ───────────────────────────────────────────────────────────────────
-- Bindings
-- ───────────────────────────────────────────────────────────────────

bindingP :: Parser String Binding
bindingP = choice $ map try
  [ BindMidiNote   <$> midiNoteBindingP
  , BindMidiCcCont <$> midiCcShape "midi-cc-cont"
  , BindMidiCc     <$> midiCcShape "midi-cc"
  , BindGate       <$> gateBindingP
  -- cv-cont must precede cv: keyword "cv" would otherwise consume
  -- the prefix of "cv-cont" and then fail when it doesn't see a mode.
  , BindCvCont     <$> cvContBindingP
  , BindCv         <$> cvBindingP
  ]

-- | `midi-note <name> <device> <ch> <note> <vel> <dur> [latency N]`.
midiNoteBindingP :: Parser String MidiNoteBinding
midiNoteBindingP = do
  _ <- keyword "midi-note"
  name <- identP
  _ <- hspace1
  device <- identP
  _ <- hspace1
  channel <- intDecimal
  _ <- hspace1
  note <- intDecimal
  _ <- hspace1
  velocity <- intDecimal
  _ <- hspace1
  durationMs <- intDecimal
  latency <- latencyClauseP
  pure { name, device, channel, note, velocity, durationMs, latency }

-- | Shared shape for `midi-cc` / `midi-cc-cont`.
midiCcShape :: String -> Parser String MidiCcBinding
midiCcShape verb = do
  _ <- keyword verb
  name <- identP
  _ <- hspace1
  device <- identP
  _ <- hspace1
  channel <- intDecimal
  _ <- hspace1
  cc <- intDecimal
  latency <- latencyClauseP
  pure { name, device, channel, cc, latency }

-- | `gate <name> <device> <channel> [latency N]`.
gateBindingP :: Parser String GateBinding
gateBindingP = do
  _ <- keyword "gate"
  name <- identP
  _ <- hspace1
  device <- identP
  _ <- hspace1
  channel <- intDecimal
  latency <- latencyClauseP
  pure { name, device, channel, latency }

-- | `cv <name> <device> <bus> <mode> [latency N]`.
cvBindingP :: Parser String CvBinding
cvBindingP = do
  _ <- keyword "cv"
  name <- identP
  _ <- hspace1
  device <- identP
  _ <- hspace1
  busOrSlot <- intDecimal
  _ <- hspace1
  mode <- cvModeP
  latency <- latencyClauseP
  pure { name, device, busOrSlot, mode, latency }

cvModeP :: Parser String CvMode
cvModeP = do
  word <- identP
  case word of
    "voct" -> pure CvVoct
    "literal" -> pure CvLiteral
    "sample-map" -> pure CvSampleMap
    other -> fail ("unknown cv mode: " <> other)

-- | `cv-cont <name> <device> <bus> [latency N]`. No mode word — the
-- | continuous-CV action only sets a sustained value, no V/oct or
-- | sample-map shaping.  Parses into a CvBinding with mode=CvLiteral
-- | as a no-op placeholder; the field is ignored downstream.
cvContBindingP :: Parser String CvBinding
cvContBindingP = do
  _ <- keyword "cv-cont"
  name <- identP
  _ <- hspace1
  device <- identP
  _ <- hspace1
  busOrSlot <- intDecimal
  latency <- latencyClauseP
  pure { name, device, busOrSlot, mode: CvLiteral, latency }

-- ───────────────────────────────────────────────────────────────────
-- Poly-family macros — parameter-major block statements
--
-- Cell text shape:
--   <family> <alias> <bank>
--   <param> [<v1>, <v2>, ..., <vN>]
--   <param> [<v1>, <v2>, ..., <vN>]
--   ...
--
-- The declaration line names the family verb (one per FamilySpec
-- below), an alias for the target FH-2 device, and an output bank
-- (`main` / `cv1`..`cv7` / `gt1`..`gt8`, 1-indexed user-facing →
-- 0-indexed in the AST). Continuation lines each carry one parameter
-- sweep — a `[...]` list whose length equals the family's slot
-- arity. We lookahead-match on the parameter name rather than
-- enforcing indentation: a line whose first identifier isn't a
-- known parameter for this family ends the macro.
--
-- The transpose to slot-major form happens at parse time.
-- ───────────────────────────────────────────────────────────────────

-- | What kind of value a parameter accepts. Each ValueShape determines
-- | both the parser used to read individual values and the PolyValue
-- | constructor wrapping them.
data ValueShape
  = ShInt
  | ShNumber
  | ShToken (Array String)    -- valid token alphabet

-- | Per-parameter declaration: name the user types, name shipped to
-- | fh2-config (often the same — only `ratios`→`ratio` and
-- | `shapes`→`shape` differ today), and the value vocabulary.
type ParamSpec =
  { cellName :: String
  , envName :: String
  , shape :: ValueShape
  }

-- | Per-family declaration: arity (slot count), bank predicate, and
-- | the parameter set. The parser uses this to dispatch on the
-- | declaration verb and to validate continuation lines.
type FamilySpec =
  { family :: PolyFamily
  , verb :: String                 -- exact keyword in cell text
  , arity :: Int
  , bankOk :: Bank -> Boolean
  , bankErr :: String              -- human description for the failure message
  , params :: Array ParamSpec
  }

allFamilies :: Array FamilySpec
allFamilies =
  [ polyLfoSpec
  , polyClockSpec
  , polyEnvSpec
  , polyEuclidSpec
  , polyEuclidPairsSpec
  , polyRandSpec
  ]

polyLfoSpec :: FamilySpec
polyLfoSpec =
  { family: PFPolyLfo
  , verb: "polylfo"
  , arity: 8
  , bankOk: \b -> case b of
      BankGt _ -> false
      _ -> true
  , bankErr: "polylfo needs a CV-capable bank (main or cv*); got gt*"
  , params:
      [ { cellName: "ratios", envName: "ratio", shape: ShNumber }
      , { cellName: "shapes", envName: "shape", shape: ShToken ["sin","sqr","tri","saw","rnd","nse"] }
      , { cellName: "ranges", envName: "range", shape: ShToken outputRangeTokens }
      ]
      -- `ranges` is the 8-vector per-slot output-range form (modular-
      -- synth-idiomatic `+/-5v` / `+5v` / etc.). The `range <label>`
      -- singleton continuation (handled in polySignalForP) is the
      -- shortcut for "all 8 jacks the same"; per-slot ranges and
      -- envelope-level range are both accepted by fh2-config, with
      -- per-slot winning per slot it covers.
      --
      -- Polarity used to live here as a per-slot enum. It moved to
      -- the output-range concept on 2026-05-12; the FH-2 hardware has
      -- a per-jack Output Range byte downstream of the LFO subsystem,
      -- which is the right place to express polarity. See
      -- calypso/docs/fh2-config-migration-2026-05-12.md.
  }

-- | The output-range token vocabulary. `±5v` is the canonical short
-- | form for bipolar 5V; `+/-5v` and `pm5v` are accepted aliases that
-- | `canonicaliseRangeToken` normalises to `±5v` at parse time so the
-- | AST and autoformat output stay canonical. The verbose `bipolar5v`
-- | / `unipolar*v` forms are also accepted (no canonicalisation —
-- | they aren't covered by the s/+\\/-/±/ substitution). fh2-config's
-- | `parseOutputRange` is authoritative.
outputRangeTokens :: Array String
outputRangeTokens =
  [ "±5v", "+/-5v", "+10v", "+5v", "+1v", "+8v"
  , "bipolar5v", "unipolar10v", "unipolar5v", "unipolar1v", "unipolar8v"
  , "pm5v"
  ]

-- | Map alias forms to the canonical short form. The user-visible
-- | rule (per 2026-05-13 decision) is "± is a single character, prefer
-- | it over the ASCII `+/-` digraph everywhere in range specs." Applied
-- | at parse time so the AST stores `±5v` regardless of which form the
-- | user typed; autoformat-on-fire then echoes `±5v` back.
canonicaliseRangeToken :: String -> String
canonicaliseRangeToken = case _ of
  "+/-5v" -> "±5v"
  s -> s

polyClockSpec :: FamilySpec
polyClockSpec =
  { family: PFPolyClock
  , verb: "polyclock"
  , arity: 8
  , bankOk: \_ -> true
  , bankErr: ""
  , params:
      [ { cellName: "base",       envName: "base",       shape: ShToken
            ["whole","half","quarter","qt","8th","8t","16th","16t","32nd","32t","64t"] }
      , { cellName: "multiplier", envName: "multiplier", shape: ShInt }
      , { cellName: "pulseWidth", envName: "pulseWidth", shape: ShInt }
      , { cellName: "phase",      envName: "phase",      shape: ShInt }
      ]
  }

polyEnvSpec :: FamilySpec
polyEnvSpec =
  { family: PFPolyEnv
  , verb: "polyenv"
  , arity: 8
  , bankOk: \b -> case b of
      BankGt _ -> false
      _ -> true
  , bankErr: "polyenv needs a CV-capable bank (main or cv*); got gt*"
  , params:
      [ { cellName: "attack",       envName: "attack",       shape: ShInt }
      , { cellName: "decay",        envName: "decay",        shape: ShInt }
      , { cellName: "sustain",      envName: "sustain",      shape: ShInt }
      , { cellName: "release",      envName: "release",      shape: ShInt }
      , { cellName: "attackShape",  envName: "attackShape",  shape: ShInt }
      , { cellName: "decayShape",   envName: "decayShape",   shape: ShInt }
      , { cellName: "releaseShape", envName: "releaseShape", shape: ShInt }
      , { cellName: "randomDepth",  envName: "randomDepth",  shape: ShInt }
      , { cellName: "ranges",       envName: "range",        shape: ShToken outputRangeTokens }
      ]
  }

-- Shared by polyeuclid (8 slots) and polyeuclid-pairs (4 slots).
euclidParams :: Array ParamSpec
euclidParams =
  [ { cellName: "beats",      envName: "beats",      shape: ShInt }
  , { cellName: "steps",      envName: "steps",      shape: ShInt }
  , { cellName: "rate",       envName: "rate",       shape: ShInt }
  , { cellName: "accentRate", envName: "accentRate", shape: ShInt }
  ]

polyEuclidSpec :: FamilySpec
polyEuclidSpec =
  { family: PFPolyEuclid
  , verb: "polyeuclid"
  , arity: 8
  , bankOk: \_ -> true
  , bankErr: ""
  , params: euclidParams
  }

polyEuclidPairsSpec :: FamilySpec
polyEuclidPairsSpec =
  { family: PFPolyEuclidPairs
  , verb: "polyeuclid-pairs"
  , arity: 4
  , bankOk: \_ -> true
  , bankErr: ""
  , params: euclidParams
  }

polyRandSpec :: FamilySpec
polyRandSpec =
  { family: PFPolyRand
  , verb: "polyrand"
  , arity: 8
  , bankOk: \b -> case b of
      BankGt _ -> false
      _ -> true
  , bankErr: "polyrand needs a CV-capable bank (main or cv*); got gt*"
  , params:
      [ { cellName: "direction",  envName: "direction",  shape: ShToken ["stop","fwd","bwd"] }
      , { cellName: "length",     envName: "length",     shape: ShInt }
      , { cellName: "randomness", envName: "randomness", shape: ShInt }
      , { cellName: "rate",       envName: "rate",       shape: ShInt }
      , { cellName: "attenuator", envName: "attenuator", shape: ShInt }
      , { cellName: "scale",      envName: "scale",      shape: ShToken
            ["unq","chromatic","major","minor","triad"] }
      , { cellName: "key",        envName: "key",        shape: ShToken
            ["c","c#","d","d#","e","f","f#","g","g#","a","a#","b"] }
      , { cellName: "gateLength", envName: "gateLength", shape: ShInt }
      , { cellName: "ranges",     envName: "range",      shape: ShToken outputRangeTokens }
      ]
  }

-- | Try each family in turn; the verb keyword is the discriminator.
polySignalConfigP :: Parser String PolySignalConfig
polySignalConfigP = choice $ map (try <<< polySignalForP) allFamilies

-- | Parse one family's block: declaration + zero-or-more continuation
-- | lines. Continuation lines are introduced by a trailing `<>` marker
-- | at end of the previous line (Tidal-flavoured "and also"):
-- |
-- |   polylfo myLFO main             <>
-- |     ratios [1, 2, 4, 8]          <>
-- |     shapes [tri, tri, tri, tri]
-- |
-- | Two kinds of continuation content:
-- |   * `range <label>` — sets envelope-level outputRange (singleton)
-- |   * `<param> [...]` — parameter sweep (8-vector for most families,
-- |                       4-vector for polyeuclid-pairs)
-- |
-- | The block ends at the first line WITHOUT a trailing `<>`. This is
-- | syntactic (not heuristic) — stale/typo continuation lines fall
-- | outside the block cleanly rather than fragmenting it.
-- |
-- | (`<>` is a syntactic continuation marker here, not a strict-monoid
-- | combine — the verb line is a header, duplicate params raise an
-- | error rather than being combined. Read it as "and also".)
polySignalForP :: FamilySpec -> Parser String PolySignalConfig
polySignalForP spec = do
  _ <- keyword spec.verb
  alias <- identP
  _ <- hspace1
  bank <- bankTokenP
  unless (spec.bankOk bank) $
    fail spec.bankErr
  cont <- maybeContinuationMarker
  blockLines <- if cont then consumeContinuationLines spec else pure []
  let { outputRange, paramLines } = partitionBlockLines blockLines
  slots <- case transposeToSlots spec paramLines of
    Left err -> fail err
    Right ss -> pure ss
  pure { alias, family: spec.family, bank, outputRange, slots }

-- | After whatever just parsed, optionally consume a `<>` continuation
-- | marker + the cross-line whitespace that follows it. Returns whether
-- | the marker was found.
-- |
-- | The marker must appear on the same line as the preceding content
-- | (trailing form). `<>` on its own line at the start of a new line
-- | is NOT recognised — keep it trailing for readability.
maybeContinuationMarker :: Parser String Boolean
maybeContinuationMarker = do
  _ <- hspace
  found <- optionMaybe (try (string "<>"))
  case found of
    Just _ -> do
      skipInterLineFiller
      pure true
    Nothing -> pure false

-- | Consume one continuation line and recurse if the line ends with a
-- | marker. Always returns at least one line — call this only after
-- | seeing a continuation marker.
consumeContinuationLines :: FamilySpec -> Parser String (Array BlockLine)
consumeContinuationLines spec = do
  line <- rangeOrParamLineP spec
  cont <- maybeContinuationMarker
  if cont
    then do
      rest <- consumeContinuationLines spec
      pure (Array.cons line rest)
    else pure [line]

-- | A continuation line is either a `range <label>` singleton or a
-- | `<param> [...]` 8-vector. The parser tries `range` first because
-- | `range` would otherwise be rejected as an unknown parameter name.
data BlockLine
  = BlRange String
  | BlParam { name :: String, values :: Array PolyValue }

rangeOrParamLineP :: FamilySpec -> Parser String BlockLine
rangeOrParamLineP spec =
  accentOffLineP spec
    <|> try rangeLineP
    <|> (BlParam <$> paramLineP spec)

-- | `accent off` — polyeuclidpairs-only block-line that silences every
-- | accent jack. Sugars to `accentRate [0, 0, 0, 0]` at parse time; the
-- | pretty-printer detects the same shape and re-emits `accent off` on
-- | autoformat, so round-trip is preserved without an AST field.
-- |
-- | The cell-text `accent off` form exists because `accentRate 0` is
-- | now rejected by `paramLineP` for polyeuclidpairs — silencing is
-- | the user's intent often enough that the literal-zero shape is a
-- | footgun (does 0 mean "every step" or "no steps"?). `accent off`
-- | is unambiguous.
-- |
-- | The prefix `accent` + whitespace + `off` is parsed inside `try` so
-- | that "accentRate" (the parameter name) and "accent" variants like
-- | `accent maybe` backtrack cleanly to let `paramLineP` handle them.
-- | Once the prefix is committed, the family check fires as a *hard*
-- | error so the user sees the specific message instead of a generic
-- | "not a polyeuclid parameter: 'accent'" fall-through.
accentOffLineP :: FamilySpec -> Parser String BlockLine
accentOffLineP spec = do
  _ <- try do
    skipInterLineFiller
    _ <- string "accent"
    _ <- hspace1
    _ <- string "off"
    pure unit
  if spec.family /= PFPolyEuclidPairs
    then fail "`accent off` is only valid in polyeuclid-pairs"
    else pure (BlParam { name: "accentRate"
                       , values: Array.replicate 4 (PVInt 0)
                       })

rangeLineP :: Parser String BlockLine
rangeLineP = do
  skipInterLineFiller
  _ <- string "range"
  _ <- hspace1
  -- Same token vocabulary as the per-slot `ranges` 8-vector, so we
  -- accept modular-synth-idiomatic tokens like `±5v`, `+/-5v` and
  -- `+5v`. `identP` here would reject anything starting with `+`
  -- or `±`. Validate against the canonical token list so an unknown
  -- label fails at parse time with a useful message rather than
  -- being passed through to fh2-config for a late rejection.
  label <- valueTokenP
  if label `F.elem` outputRangeTokens
    then pure (BlRange (canonicaliseRangeToken label))
    else fail $ "unknown range token '" <> label <> "' (expected: "
                <> Str.joinWith " / " outputRangeTokens <> ")"

partitionBlockLines
  :: Array BlockLine
  -> { outputRange :: Maybe String
     , paramLines :: Array { name :: String, values :: Array PolyValue }
     }
partitionBlockLines lines =
  let step acc line = case line of
        BlRange r -> acc { outputRange = Just r }
        BlParam p -> acc { paramLines = Array.snoc acc.paramLines p }
  in Array.foldl step { outputRange: Nothing, paramLines: [] } lines

-- | One continuation line: param-name + bracketed value list. Wrapped
-- | in `try`: a line whose first identifier doesn't match any of the
-- | family's parameter names backtracks cleanly, ending the macro.
paramLineP :: FamilySpec -> Parser String { name :: String, values :: Array PolyValue }
paramLineP spec = do
  skipInterLineFiller
  name <- identP
  case findParam spec.params name of
    Nothing ->
      fail ("not a " <> spec.verb <> " parameter: '" <> name <> "'")
    Just ps -> do
      _ <- hspace1
      values <- valueListP ps.shape
      -- accentRate 0 silences accent jacks. In polyeuclid-pairs that's
      -- almost certainly not what the user meant (and if it is, the
      -- canonical spelling is `accent off`). In polyeuclid (gates-only)
      -- the accent jacks are inert so accentRate 0 is fine and is in
      -- fact the documented default.
      when (spec.family == PFPolyEuclidPairs
            && name == "accentRate"
            && Array.any isPVZero values) $
        fail $ "accentRate 0 silences accent jacks in polyeuclid-pairs"
            <> " — use `accent off` to silence all 4 pairs explicitly,"
            <> " or a small non-zero rate for rare accents."
      pure { name, values }
  where
  isPVZero = case _ of
    PVInt 0 -> true
    _ -> false

-- | Optional whitespace, newlines, and comments between continuation
-- | lines. Returns unit; consumes everything up to the next non-blank,
-- | non-comment character.
skipInterLineFiller :: Parser String Unit
skipInterLineFiller = void $ many $
  void (satisfy isFiller)
    <|> commentP
  where
  isFiller c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

-- | One bracketed `[v1, v2, ...]` value list. Whitespace and newlines
-- | allowed around values and commas.
valueListP :: ValueShape -> Parser String (Array PolyValue)
valueListP shape = do
  _ <- char '['
  _ <- skipInterLineFiller
  first <- valueP shape
  rest <- many $ try $ do
    _ <- skipInterLineFiller
    _ <- char ','
    _ <- skipInterLineFiller
    valueP shape
  _ <- skipInterLineFiller
  _ <- char ']'
  pure (Array.cons first rest)

-- | One value, validated against its shape.
valueP :: ValueShape -> Parser String PolyValue
valueP = case _ of
  ShInt -> PVInt <$> intDecimal
  ShNumber -> PVNumber <$> number
  ShToken allowed -> do
    word <- valueTokenP
    if word `F.elem` allowed
      then pure (PVToken (canonicaliseRangeToken word))
      else fail $ "unknown token '" <> word <> "' (expected: "
                  <> Str.joinWith " / " allowed <> ")"

-- | Token inside a value list. More permissive than `identP`:
-- |   * may start with a digit (`8th`, `16th`, `32nd`, …) — clock-base
-- |     tokens commonly do
-- |   * may start with `+` (`+5v`, `+10v`, `+/-5v`, …) — voltage-range
-- |     tokens use this modular-synth-idiomatic notation
-- |   * may start with `±` (`±5v`) — canonical bipolar range token
-- |   * `#` is allowed in the middle (`c#`, `f#`) — sharps for the
-- |     pitch-class vocabulary
-- |   * `/` is allowed in the middle (`+/-5v`) — legacy bipolar range
-- |     alias
-- |
-- | Used only inside `[...]` value lists; outside, `#` is the comment
-- | character per the existing grammar.
valueTokenP :: Parser String String
valueTokenP = do
  first <- satisfy (isTokenStartCP <<< codePointFromChar)
  rest <- optionMaybe (takeWhile1 isTokenRestCP)
  pure (SCU.singleton first <> case rest of
    Nothing -> ""
    Just r -> r)
  where
  isTokenStartCP cp = CP.isAlphaNum cp
    || cp == codePointFromChar '+'
    || cp == codePointFromChar '±'
  isTokenRestCP cp = isIdentRestCP cp
    || cp == codePointFromChar '#'
    || cp == codePointFromChar '+'
    || cp == codePointFromChar '/'

-- | Bank token: `main`, `cv<n>`, `gt<n>` (1-indexed user-facing →
-- | 0-indexed in the AST).
bankTokenP :: Parser String Bank
bankTokenP = do
  word <- identP
  case word of
    "main" -> pure BankMain
    _ -> case SCU.uncons word of
      Just { head: 'c', tail } | SCU.take 1 tail == "v" ->
        case parseSuffixInt (SCU.drop 1 tail) "cv" 1 7 of
          Right n -> pure (BankCv (n - 1))
          Left err -> fail err
      Just { head: 'g', tail } | SCU.take 1 tail == "t" ->
        case parseSuffixInt (SCU.drop 1 tail) "gt" 1 8 of
          Right n -> pure (BankGt (n - 1))
          Left err -> fail err
      _ -> fail ("expected bank token (main / cv1..cv7 / gt1..gt8), got '" <> word <> "'")
  where
  parseSuffixInt s prefix lo hi = case Int.fromString s of
    Just n | n >= lo && n <= hi -> Right n
    _ -> Left ("invalid " <> prefix <> " bank index '" <> s
               <> "' (expected " <> prefix <> show lo <> ".." <> prefix <> show hi <> ")")

-- | Look up a parameter spec by cell-text name.
findParam :: Array ParamSpec -> String -> Maybe ParamSpec
findParam params name = Array.find (\p -> p.cellName == name) params

-- | Transpose parameter-major lines into slot-major records. Errors:
-- |   * duplicate parameter line (same `name` appears twice)
-- |   * wrong list length (must equal `spec.arity`)
transposeToSlots
  :: FamilySpec
  -> Array { name :: String, values :: Array PolyValue }
  -> Either String (Array PolySlot)
transposeToSlots spec lines = do
  _ <- checkNoDuplicates lines
  _ <- traverse (checkLineArity spec) lines
  let slotIndices = Array.range 0 (spec.arity - 1)
  pure $ map (\i -> buildSlot spec lines i) slotIndices

-- | For one slot index, walk all parameter lines and collect (envName,
-- | value) pairs in family-declared parameter order. Parameters not
-- | mentioned in the cell text are omitted — fh2-config fills them
-- | from the family `defaultSlot`.
buildSlot
  :: FamilySpec
  -> Array { name :: String, values :: Array PolyValue }
  -> Int
  -> PolySlot
buildSlot spec lines slotIdx =
  Array.mapMaybe (\ps -> case Array.find (\l -> l.name == ps.cellName) lines of
    Nothing -> Nothing
    Just line -> case Array.index line.values slotIdx of
      Nothing -> Nothing
      Just v -> Just (Tuple ps.envName v)
  ) spec.params

checkNoDuplicates
  :: Array { name :: String, values :: Array PolyValue }
  -> Either String Unit
checkNoDuplicates lines =
  case Array.findIndex isDup (Array.mapWithIndex Tuple lines) of
    Nothing -> Right unit
    Just _ -> case findDupName lines of
      Just name -> Left $ "parameter '" <> name <> "' appears twice in this macro"
      Nothing -> Right unit
  where
  isDup (Tuple i (entry :: { name :: String, values :: Array PolyValue })) =
    F.elem entry.name (map _.name (Array.take i lines))
  findDupName ls = case Array.uncons ls of
    Nothing -> Nothing
    Just { head, tail } ->
      if F.elem head.name (map _.name tail)
        then Just head.name
        else findDupName tail

checkLineArity
  :: FamilySpec
  -> { name :: String, values :: Array PolyValue }
  -> Either String Unit
checkLineArity spec line =
  let n = Array.length line.values
  in if n == spec.arity
       then Right unit
       else Left $ spec.verb <> " '" <> line.name
                   <> "': expected " <> show spec.arity
                   <> " values, got " <> show n

-- ───────────────────────────────────────────────────────────────────
-- Polysignal block collapser — for wire serialisation
--
-- Cell text contains multi-line polysignal blocks:
--
--   polylfo myLFO main
--     ratios [1, 2, 4, 8, 1.3, 2.6, 5.2, 10.4]
--     shapes [tri, tri, tri, tri, tri, tri, tri, tri]
--
-- The Calypso wire protocol to purerl-tidal is one statement per
-- frame. So before firing, we collapse each polysignal block into a
-- single line of the form:
--
--   polysignal <json>
--
-- where the JSON is the envelope shape `fh2-config --apply-polysignal`
-- expects on stdin: `{"bank":..., "family":..., "slots":[...]}`.
-- Non-polysignal lines pass through unchanged.
--
-- The Erlang handler recognises the `polysignal ` prefix and shells
-- out to fh2-config with the JSON.
-- ───────────────────────────────────────────────────────────────────

-- | Walk an array of source lines (one per cell-text line) and collapse
-- | polysignal blocks into single `polysignal <json>` lines. If a block
-- | fails to parse, leaves its source lines untouched — the downstream
-- | parser will produce a clearer error than the collapser could.
collapsePolySignalBlocks :: Array String -> Array String
collapsePolySignalBlocks lines =
  map _.source (collapsePolySignalEntries (map (\s -> { lineNum: 0, source: s }) lines))

-- | Collapse polysignal blocks on `{lineNum, source}` entries, preserving
-- | the lineNum of the verb line for the collapsed entry. The frontend
-- | statement-splitters use this so error reports point at the verb line
-- | rather than at random continuation lines.
collapsePolySignalEntries
  :: Array { lineNum :: Int, source :: String }
  -> Array { lineNum :: Int, source :: String }
collapsePolySignalEntries entries = go [] entries
  where
  go acc remaining = case Array.uncons remaining of
    Nothing -> Array.reverse acc
    Just { head, tail } -> case familyForLine head.source of
      Nothing -> go (Array.cons head acc) tail
      Just spec ->
        let { block, rest } = collectBlock spec head tail
            joined = Str.joinWith "\n" (map _.source block)
        in case parseStatement joined of
          Right stmt -> case stmtToPolySignal stmt of
            Just cfg ->
              let wireLine = "polysignal " <> polySignalEnvelopeJson cfg
              in go (Array.cons { lineNum: head.lineNum, source: wireLine } acc) rest
            Nothing -> go (Array.cons head acc) tail
          Left _ -> go (Array.cons head acc) tail

  -- Block boundaries are decided by trailing `<>` on each line. The
  -- block consumes a line iff the PREVIOUS line ended with the marker.
  -- This is syntactic (not heuristic) so stale/typo continuation
  -- lines fall outside the block cleanly.
  collectBlock _spec firstEntry xs =
    let consume taken lastEntry rest =
          if not (endsWithMarker lastEntry) then
            { block: Array.reverse taken, rest }
          else case Array.uncons rest of
            Nothing -> { block: Array.reverse taken, rest: [] }
            Just { head, tail } ->
              consume (Array.cons head taken) head tail
    in consume [firstEntry] firstEntry xs

  endsWithMarker :: { lineNum :: Int, source :: String } -> Boolean
  endsWithMarker entry =
    case Str.stripSuffix (Str.Pattern "<>") (Str.trim entry.source) of
      Just _ -> true
      Nothing -> false

  familyForLine :: String -> Maybe FamilySpec
  familyForLine line = do
    word <- firstIdent line
    Array.find (\s -> s.verb == word) allFamilies

  stmtToPolySignal :: Statement -> Maybe PolySignalConfig
  stmtToPolySignal = case _ of
    StmtDeviceConfig (PolySignalCfg cfg) -> Just cfg
    _ -> Nothing

-- ───────────────────────────────────────────────────────────────────
-- Macro-verb block collapser — for wire serialisation
--
-- Cell text contains multi-line macro blocks such as:
--
--   drumkit kitA [bd sn hh cp]
--     gates gt0
--     pitch main
--     ch 10
--
-- Unlike polysignal blocks, there's no JSON-envelope transformation
-- on this side — the Erlang-side parser handles the joined source as
-- whitespace-tokenised text. The collapser's only job is to bundle
-- the multi-line block into one wire frame.
--
-- Same trailing-`<>` continuation convention as polysignals: a line
-- is consumed iff the PREVIOUS line ended with `<>`. Trailing
-- markers are stripped on join so the wire-format reads cleanly.
-- ───────────────────────────────────────────────────────────────────

-- | Verbs whose multi-line cell blocks are collapsed into a single
-- | wire frame for purerl-tidal. Single-line cells pass through
-- | as no-ops (no trailing `<>`, no block to collect).
macroVerbs :: Array String
macroVerbs =
  [ "drumkit"
  , "kit"
  , "yarns"
  , "chord"
  , "mutes"
  , "veils"
  ]

-- | Collapse macro-verb blocks (drumkit / kit / yarns / chord /
-- | mutes / veils). Preserves the verb-line lineNum for error
-- | reporting and strips trailing `<>` continuation markers as it
-- | joins. Lines whose verb isn't in `macroVerbs` pass through
-- | unchanged.
collapseMacroEntries
  :: Array { lineNum :: Int, source :: String }
  -> Array { lineNum :: Int, source :: String }
collapseMacroEntries entries = go [] entries
  where
  go acc remaining = case Array.uncons remaining of
    Nothing -> Array.reverse acc
    Just { head, tail } -> case macroVerbForLine head.source of
      Nothing -> go (Array.cons head acc) tail
      Just _ ->
        let { block, rest } = collectBlock head tail
            joined = Str.joinWith " "
              (map (stripTrailingMarker <<< _.source) block)
        in go (Array.cons { lineNum: head.lineNum, source: joined } acc)
              rest

  -- Same block-collection convention as the polysignal collapser:
  -- consume the next line iff the PREVIOUS line ended with `<>`.
  collectBlock firstEntry xs =
    let consume taken lastEntry rest =
          if not (endsWithMarker lastEntry) then
            { block: Array.reverse taken, rest }
          else case Array.uncons rest of
            Nothing -> { block: Array.reverse taken, rest: [] }
            Just { head, tail } ->
              consume (Array.cons head taken) head tail
    in consume [firstEntry] firstEntry xs

  endsWithMarker :: { lineNum :: Int, source :: String } -> Boolean
  endsWithMarker entry =
    case Str.stripSuffix (Str.Pattern "<>") (Str.trim entry.source) of
      Just _ -> true
      Nothing -> false

  -- Strip a trailing `<>` (with optional surrounding whitespace) so
  -- the joined wire text reads as plain tokens. `<>` on a line by
  -- itself becomes empty here, which is harmless under whitespace
  -- tokenisation on the Erlang side.
  stripTrailingMarker s =
    case Str.stripSuffix (Str.Pattern "<>") (Str.trim s) of
      Just stripped -> Str.trim stripped
      Nothing -> Str.trim s

  macroVerbForLine line = do
    word <- firstIdent line
    if Array.elem word macroVerbs then Just word else Nothing

-- | First whitespace-delimited word of a source line, stripped of
-- | leading whitespace.
firstIdent :: String -> Maybe String
firstIdent s =
  let trimmed = Str.trim s
  in if Str.null trimmed
       then Nothing
       else case Array.head (Str.split (Str.Pattern " ") trimmed) of
         Just w -> Just w
         Nothing -> Nothing

-- | Encode a `PolySignalConfig` to the JSON envelope shape
-- | `fh2-config --apply-polysignal` reads on stdin. This is different
-- | from the AST's Argonaut codec (which uses tagged-sum encodings for
-- | round-trip identity); the envelope has flat unwrapped values.
-- | `outputRange` is omitted from the wire when Nothing — fh2-config
-- | treats absence as "leave the bank's existing output ranges alone".
polySignalEnvelopeJson :: PolySignalConfig -> String
polySignalEnvelopeJson cfg =
  "{\"bank\":\"" <> bankToWire cfg.bank
    <> "\",\"family\":\"" <> familyToWire cfg.family
    <> "\"" <> aliasField cfg.alias
    <> rangeField cfg.outputRange
    <> ",\"slots\":[" <> Str.joinWith "," (map slotToJson cfg.slots) <> "]}"
  where
  rangeField = case _ of
    Nothing -> ""
    Just r -> ",\"outputRange\":\"" <> r <> "\""

  -- | Emit the cell-text owner name (`polylfo myLFO main` → "myLFO")
  -- | as the JSON envelope's `alias` field.  Port-claims-design step
  -- | 4b — the daemon uses this as the `OwnerId` for the polysignal
  -- | claim, so re-firing the same alias is a same-owner update and
  -- | firing under a new alias is partial-conflict against existing
  -- | claims on overlapping slots.  Empty when the parser produced
  -- | no name; the daemon then derives `<family>-<bank>` as a
  -- | back-compat stable identity.
  aliasField a
    | a == "" = ""
    | otherwise = ",\"alias\":\"" <> a <> "\""

bankToWire :: Bank -> String
bankToWire = case _ of
  BankMain -> "main"
  BankCv n -> "cv" <> show n
  BankGt n -> "gt" <> show n

-- | Cell-text rendering of a Bank — 1-indexed, mirroring the parser
-- | which accepts `cv1`/`gt1` for the first expander. The AST itself
-- | is 0-indexed (`BankCv 0` = first FHX-8CV), and `bankToWire` keeps
-- | that 0-indexed form for the JSON envelope to fh2-config. Use this
-- | function whenever you're producing text the user will read or
-- | re-parse — most importantly `prettyPolySignal`'s autoformat output.
bankToCellText :: Bank -> String
bankToCellText = case _ of
  BankMain -> "main"
  BankCv n -> "cv" <> show (n + 1)
  BankGt n -> "gt" <> show (n + 1)

familyToWire :: PolyFamily -> String
familyToWire = case _ of
  PFPolyLfo         -> "polylfo"
  PFPolyClock       -> "polyclock"
  PFPolyEnv         -> "polyenv"
  PFPolyEuclid      -> "polyeuclid"
  PFPolyEuclidPairs -> "polyeuclid-pairs"
  PFPolyRand        -> "polyrand"

slotToJson :: PolySlot -> String
slotToJson slot =
  "{" <> Str.joinWith ","
          (map (\(Tuple name pv) -> "\"" <> name <> "\":" <> pvToJson pv) slot)
      <> "}"

pvToJson :: PolyValue -> String
pvToJson = case _ of
  PVInt n -> show n
  PVNumber n -> show n
  PVToken s -> "\"" <> s <> "\""

-- ───────────────────────────────────────────────────────────────────
-- Pretty-printer for polysignal blocks
-- ───────────────────────────────────────────────────────────────────
--
-- Round-trips through the parser: `parse >>> pretty >>> parse` yields
-- the same `PolySignalConfig`. Used by the cell-fire path to canonicalise
-- cell text on commit — column-aligned value vectors, explicit `<>`
-- continuation markers on every line except the last.

-- | Look up the FamilySpec for a family. Total — there's one spec
-- | per constructor — but kept as a case to stay future-proof if
-- | new families land.
familySpecFor :: PolyFamily -> FamilySpec
familySpecFor = case _ of
  PFPolyLfo         -> polyLfoSpec
  PFPolyClock       -> polyClockSpec
  PFPolyEnv         -> polyEnvSpec
  PFPolyEuclid      -> polyEuclidSpec
  PFPolyEuclidPairs -> polyEuclidPairsSpec
  PFPolyRand        -> polyRandSpec

-- | Map an envName (AST/wire form, e.g. `ratio`) back to the cellName
-- | (user-facing form, e.g. `ratios`). Falls through to the envName
-- | when the family has no rename for that param — the two are
-- | identical for most params anyway.
envToCellName :: FamilySpec -> String -> String
envToCellName spec env =
  case Array.find (\p -> p.envName == env) spec.params of
    Just p -> p.cellName
    Nothing -> env

-- | Re-emit a `PolySignalConfig` as canonical cell text. The output
-- | starts with the verb-line header, then optionally a `range`
-- | singleton, then one line per parameter name (in slot 0's
-- | declaration order). Values within each parameter row are
-- | column-aligned: every column is padded to the widest rendered
-- | value at that slot index, computed across all parameter rows so
-- | numbers and tokens line up vertically.
prettyPolySignal :: PolySignalConfig -> String
prettyPolySignal cfg =
  let
    headerLine = familyToWire cfg.family <> " " <> cfg.alias <> " " <> bankToCellText cfg.bank
    rangeLine = map (\r -> "  range " <> r) cfg.outputRange
    -- Polyeuclid-pairs with all-zero accentRate slots is the wire shape
    -- produced by the cell-text `accent off` sugar — re-emit that
    -- canonical form (and drop the accentRate row) for clean round-trip.
    accentOffShortcut = cfg.family == PFPolyEuclidPairs
      && all (\slot -> case lookupParam "accentRate" slot of
                Just (PVInt 0) -> true
                _ -> false) cfg.slots
      && not (Array.null cfg.slots)
    accentOffLine = if accentOffShortcut then ["  accent off"] else []
    -- Param names come from slot 0; the parser produces same-key
    -- slots across the bank so this is sufficient. AST keys are the
    -- envName form (singular: `ratio`, `shape`); translate back to
    -- the cellName form (plural: `ratios`, `shapes`) for the user.
    spec = familySpecFor cfg.family
    paramNames = case Array.head cfg.slots of
      Nothing -> []
      Just s0 -> map fst (Array.filter (\(Tuple n _) ->
        -- When we'd emit `accent off`, drop the accentRate row from the
        -- per-param sweep so both forms aren't shown for the same data.
        not (accentOffShortcut && n == "accentRate")) s0)
    paramRows = map (\name ->
      { name: envToCellName spec name
      , values: map (\slot -> renderPolyValue (lookupParam name slot)) cfg.slots
      }) paramNames
    colCount = Array.length cfg.slots
    -- Per-column width across every parameter row, so the columns
    -- line up vertically even when one row has a long token and
    -- another has a short integer at the same slot index.
    colWidths = map (\i ->
      foldl max 1
        (Array.mapMaybe (\row -> Str.length <$> Array.index row.values i) paramRows)
      ) (Array.range 0 (colCount - 1))
    paramLines = map (renderParamRow colWidths) paramRows
    allLines = [headerLine]
      <> (maybe [] (\r -> [r]) rangeLine)
      <> accentOffLine
      <> paramLines
  in joinWithContinuations allLines

-- | Render `[v0, v1, ..., vN]` with each value followed by `, ` and
-- | right-padded to its column width. The comma hugs its own value
-- | (reads as "this value, next value") instead of drifting away from
-- | the value into the gap. The closing `]` sits flush against the
-- | last value (no trailing separator) but the last column is still
-- | padded to width so brackets align vertically across rows.
renderParamRow :: Array Int -> { name :: String, values :: Array String } -> String
renderParamRow colWidths row =
  "  " <> row.name <> " ["
    <> Str.joinWith "" (Array.mapWithIndex renderCell row.values)
    <> "]"
  where
  lastIdx = Array.length row.values - 1
  renderCell i v =
    let width = fromMaybe 0 (Array.index colWidths i)
        separator = if i == lastIdx then "" else ", "
    in padRight (width + Str.length separator) (v <> separator)

renderPolyValue :: Maybe PolyValue -> String
renderPolyValue = case _ of
  Nothing -> "?"
  Just (PVInt n) -> show n
  Just (PVNumber n) -> showNumberCompact n
  Just (PVToken s) -> s

-- | PureScript's `show 1.0` emits "1.0" which is fine but slightly
-- | noisier than the bare integer form the user types. Trim the
-- | trailing `.0` for whole numbers; leave fractional values alone.
showNumberCompact :: Number -> String
showNumberCompact n =
  let s = show n
  in case Str.stripSuffix (Str.Pattern ".0") s of
    Just s' -> s'
    Nothing -> s

lookupParam :: String -> PolySlot -> Maybe PolyValue
lookupParam name slot = map snd $ Array.find ((_ == name) <<< fst) slot

padRight :: Int -> String -> String
padRight n s = s <> SCU.fromCharArray (Array.replicate (max 0 (n - Str.length s)) ' ')

-- | Glue lines with `\n` and append a column-aligned `<>` marker to
-- | every line except the last. The marker placement matches the
-- | grammar — the parser requires `<>` end-of-line to extend a block
-- | past its header, and we want the formatted output to round-trip
-- | cleanly back to the same AST. Marker column is the max line
-- | width + 4 spaces of gap.
joinWithContinuations :: Array String -> String
joinWithContinuations ls = case Array.unsnoc ls of
  Nothing -> ""
  Just { init, last } | Array.null init -> last
  Just { init, last } ->
    let maxLen = foldl max 0 (map Str.length (init <> [last]))
        gap = 4
        withMarkers = map (\s -> padRight maxLen s <> SCU.fromCharArray (Array.replicate gap ' ') <> "<>") init
    in Str.joinWith "\n" (withMarkers <> [last])

-- | Try to autoformat a cell's text as a polysignal block. Succeeds
-- | only when the cell parses cleanly as *exactly one* polysignal
-- | statement; returns Nothing for any other content (multi-statement
-- | cells, non-polysignal cells, parse errors). The caller decides
-- | what to do on Nothing — typically: skip autoformat and fire the
-- | original text as-is.
autoformatPolySignalCell :: String -> Maybe String
autoformatPolySignalCell src = case parseComposition src of
  Left _ -> Nothing
  Right (Composition stmts) -> case stmts of
    [StmtDeviceConfig (PolySignalCfg cfg)] -> Just (prettyPolySignal cfg)
    _ -> Nothing
