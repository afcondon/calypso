-- | Canonical serializer for the Calypso composition grammar.
-- |
-- | `serializeComposition` is the inverse of `parseComposition` from
-- | `Calypso.Composition.Parser`: emits each statement in source order
-- | using a canonical form per statement kind. Round-trip property:
-- |
-- |   parseComposition (serializeComposition ast) ≡ Right ast
-- |
-- | The current implementation is "one statement per logical block,
-- | joined by newlines" — no section headers, no reordering. Section
-- | grouping (`-- # Devices`, `-- # Cues`, …) is a Phase-4 UX concern
-- | layered on top.
-- |
-- | Polysignal blocks delegate to `prettyPolySignal` (already canonical
-- | via the autoformat-on-fire path).
module Calypso.Composition.Serializer
  ( serializeComposition
  , serializeStatement
  ) where

import Prelude

import Calypso.Composition
  ( Binding(..)
  , Composition(..)
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
  , RootDevice
  , Statement(..)
  )
import Calypso.Composition.Parser (prettyPolySignal)
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll, split, stripPrefix, trim) as Str
import Data.Tuple (Tuple(..))

-- ───────────────────────────────────────────────────────────────────
-- Public API
-- ───────────────────────────────────────────────────────────────────

-- | Render a whole composition as a `\n`-separated string. No trailing
-- | newline — callers append one if their downstream surface expects it.
-- |
-- | Walks the statement list and inserts `section <mvoice>` headers
-- | whenever a StmtCue's mvoice differs from the running section.
-- | Cues themselves get either the level-2 named form (`<tv> = body`)
-- | or the legacy `cue <id> [meta] = body` form depending on whether
-- | the cue's id matches its tvoice; see `renderCue` for the rule.
serializeComposition :: Composition -> String
serializeComposition (Composition stmts) =
  Str.joinWith "\n" (Array.reverse (_.lines (Array.foldl step initState stmts)))
  where
  initState = { section: Nothing, lines: [] }
  step state stmt = case stmt of
    StmtCue c ->
      let
        stateAfterHeader = case c.mvoice of
          Just mv | Just mv /= state.section ->
            { section: Just mv
            , lines: Array.cons ("section " <> mv) state.lines
            }
          _ -> state
        cueText = renderCue { underSection: stateAfterHeader.section } c
      in stateAfterHeader { lines = Array.cons cueText stateAfterHeader.lines }
    _ -> state { lines = Array.cons (serializeStatement stmt) state.lines }

-- | Render one statement to its canonical text form. Multi-line forms
-- | (polysignal blocks, multi-line cue bodies) emit embedded newlines.
serializeStatement :: Statement -> String
serializeStatement = case _ of
  StmtBpm n -> "bpm " <> renderNumber n
  StmtLinkSync b -> "link sync " <> if b then "on" else "off"
  StmtControl c -> "control " <> c.name <> " = " <> renderNumber c.value
  StmtTag t -> "tag " <> t.name <> " = " <> t.defaultValue
  -- Standalone-statement rendering: no enclosing section, so we
  -- keep mvoice in the metadata. Used by serializeStatement callers
  -- that don't have section context. `serializeComposition` calls
  -- renderCue directly with the running section, dropping redundant
  -- mvoice metadata when the section header already provides it.
  StmtCue c -> renderCue { underSection: Nothing } c
  StmtSection name -> "section " <> name
  StmtDevice d -> renderDevice d
  StmtDeviceConfig dc -> renderDeviceConfig dc
  StmtBinding b -> renderBinding b

-- ───────────────────────────────────────────────────────────────────
-- Numbers
-- ───────────────────────────────────────────────────────────────────

-- | Render a `Number` as the user would type it: integer when whole,
-- | otherwise plain decimal. Matches the parser's `number` combinator
-- | so round-trip is preserved.
renderNumber :: Number -> String
renderNumber n =
  let s = show n
  in case Str.split (Str.Pattern ".") s of
    [whole, "0"] -> whole
    _ -> s

renderLatency :: Maybe Latency -> String
renderLatency = case _ of
  Nothing -> ""
  Just n -> " lat " <> renderNumber n

-- ───────────────────────────────────────────────────────────────────
-- Cue
-- ───────────────────────────────────────────────────────────────────

-- | Cue rendering picks one of three forms by cascading preferences:
-- |
-- |   1. Level-2 named form `<tvoice>[:suffix] = body` when the cue's id
-- |      matches its tvoice (either exactly, or as `tvoice:suffix`). The
-- |      mvoice is supplied by the enclosing `section` header.
-- |   2. Legacy `cue <id> [meta] = body` when (1) doesn't apply.
-- |
-- | Plus body wrapping: single-line bodies inline after `=`, multi-line
-- | bodies on indented continuation lines.
-- |
-- | `ctx.underSection` is the mvoice of the most recently emitted
-- | `section` header (Nothing for top-level / no section yet). When the
-- | cue's mvoice matches it, we drop the redundant `mvoice=` from any
-- | emitted metadata; the section header is doing that work.
renderCue :: { underSection :: Maybe String } -> CueStmt -> String
renderCue ctx c =
  case namedFormHeader c of
    Just header -> renderBodyAfter header c.body
    Nothing -> renderLegacy ctx c

-- | If the cue's id is `tvoice` or `tvoice:suffix`, return the
-- | corresponding header text. Used to detect when the level-2 named
-- | form is applicable.
namedFormHeader :: CueStmt -> Maybe String
namedFormHeader c = case c.tvoice of
  Nothing -> Nothing
  Just tv
    | c.id == tv -> Just tv
    | otherwise -> case Str.stripPrefix (Str.Pattern (tv <> ":")) c.id of
        Just _ -> Just c.id   -- id IS "tvoice:suffix"
        Nothing -> Nothing

renderLegacy :: { underSection :: Maybe String } -> CueStmt -> String
renderLegacy ctx c =
  let header = "cue " <> c.id <> renderCueMeta ctx c
  in renderBodyAfter header c.body

renderBodyAfter :: String -> String -> String
renderBodyAfter header body =
  let bodyLines = Str.split (Str.Pattern "\n") body
  in case Array.length bodyLines of
    1 -> header <> " = " <> Str.trim body
    _ -> header <> "\n" <> Str.joinWith "\n" (map (\l -> "  " <> l) bodyLines)

-- | Bracket metadata for the legacy `cue <id> [meta] = body` form.
-- | Drops `mvoice=...` when it equals the enclosing section so the
-- | section header does the work. Tvoice and when-tag are preserved
-- | verbatim; they're cue-specific.
renderCueMeta :: { underSection :: Maybe String } -> CueStmt -> String
renderCueMeta ctx c =
  let
    mvoicePart = case c.mvoice of
      Just mv | Just mv /= ctx.underSection -> Just ("mvoice=" <> mv)
      _ -> Nothing
    pairs = Array.catMaybes
      [ mvoicePart
      , map (\v -> "tvoice=" <> v) c.tvoice
      , map (\v -> "when=" <> v) c.whenTag
      ]
  in case Array.length pairs of
    0 -> ""
    _ -> " [" <> Str.joinWith " " pairs <> "]"

-- ───────────────────────────────────────────────────────────────────
-- Devices
-- ───────────────────────────────────────────────────────────────────

renderDevice :: Device -> String
renderDevice = case _ of
  DevMidi r   -> renderRoot "midi"  r
  DevEs9 r    -> renderRoot "es9"   r
  DevFh2 r    -> renderRoot "fh2"   r
  DevYarns r  -> renderRoot "yarns" r
  DevOsc r    -> renderOsc r
  DevEs5 e    -> renderExpander "es5"     e
  DevEsx8Gt e -> renderExpander "esx-8gt" e
  DevEsx8Cv e -> renderExpander "esx-8cv" e
  DevFhx8Gt e -> renderExpander "fhx-8gt" e

renderRoot :: String -> RootDevice -> String
renderRoot kw r =
  kw <> " " <> r.alias <> " \"" <> escapePortString r.port <> "\"" <> renderLatency r.latency

renderExpander :: String -> ExpanderDevice -> String
renderExpander kw e =
  kw <> " " <> e.alias <> " on " <> e.parent

renderOsc :: OscDevice -> String
renderOsc o =
  "osc " <> o.alias <> " host=" <> o.host <> " port=" <> show o.port

-- | The port string is captured by `stringLit`, which accepts `\"` and
-- | `\\` escapes. Round-trip: any `"` or `\` inside the alias must be
-- | re-escaped on emit. CoreMIDI port names don't contain these in
-- | practice but the codec must be honest.
escapePortString :: String -> String
escapePortString s =
  let withBackslash = Str.replaceAll (Str.Pattern "\\") (Str.Replacement "\\\\") s
  in Str.replaceAll (Str.Pattern "\"") (Str.Replacement "\\\"") withBackslash

-- ───────────────────────────────────────────────────────────────────
-- Device-internal config
-- ───────────────────────────────────────────────────────────────────

renderDeviceConfig :: DeviceConfig -> String
renderDeviceConfig = case _ of
  Fh2VoiceCfg c -> renderFh2VoiceCfg c
  Fh2ModeCfg c -> renderFh2ModeCfg c
  PolySignalCfg c -> prettyPolySignal c

renderFh2VoiceCfg :: Fh2VoiceConfig -> String
renderFh2VoiceCfg c =
  "fh2-config " <> c.device <> ":" <> renderFh2VoiceMode c.mode
    <> " voice=" <> show c.voice
    <> " out=" <> renderOutRef c.out
    <> " ch=" <> show c.channel

renderFh2VoiceMode :: Fh2VoiceMode -> String
renderFh2VoiceMode = case _ of
  Fh2Envelope -> "envelope"
  Fh2Gate -> "gate"

renderFh2ModeCfg :: Fh2ModeConfig -> String
renderFh2ModeCfg c =
  "fh2-mode " <> c.device <> ":" <> c.modeName

renderOutRef :: OutRef -> String
renderOutRef = case _ of
  OutLocal n -> show n
  OutExpander alias slot -> alias <> ":" <> show slot

-- ───────────────────────────────────────────────────────────────────
-- Bindings
-- ───────────────────────────────────────────────────────────────────

renderBinding :: Binding -> String
renderBinding = case _ of
  BindMidiNote b   -> renderMidiNote b
  BindMidiCc b     -> renderMidiCc "midi-cc" b
  BindMidiCcCont b -> renderMidiCc "midi-cc-cont" b
  BindGate b       -> renderGate b
  BindCv b         -> renderCv b
  BindCvCont b     -> renderCvCont b

renderMidiNote :: MidiNoteBinding -> String
renderMidiNote b =
  "midi-note " <> b.name <> " " <> b.device <> " "
    <> show b.channel <> " "
    <> show b.note <> " "
    <> show b.velocity <> " "
    <> show b.durationMs
    <> renderLatency b.latency

renderMidiCc :: String -> MidiCcBinding -> String
renderMidiCc kw b =
  kw <> " " <> b.name <> " " <> b.device <> " "
    <> show b.channel <> " "
    <> show b.cc
    <> renderLatency b.latency

renderGate :: GateBinding -> String
renderGate b =
  "gate " <> b.name <> " " <> b.device <> " "
    <> show b.channel
    <> renderLatency b.latency

renderCv :: CvBinding -> String
renderCv b =
  "cv " <> b.name <> " " <> b.device <> " "
    <> show b.busOrSlot <> " "
    <> renderCvMode b.mode
    <> renderLatency b.latency

renderCvCont :: CvBinding -> String
renderCvCont b =
  "cv-cont " <> b.name <> " " <> b.device <> " "
    <> show b.busOrSlot
    <> renderLatency b.latency

renderCvMode :: CvMode -> String
renderCvMode = case _ of
  CvVoct -> "voct"
  CvLiteral -> "literal"
  CvSampleMap -> "sample-map"
