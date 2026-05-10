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
  ) where

import Prelude

import Calypso.Composition
  ( Binding(..)
  , Composition(..)
  , CvBinding
  , CvMode(..)
  , Device(..)
  , DeviceConfig(..)
  , ExpanderDevice
  , Fh2VoiceConfig
  , Fh2VoiceMode(..)
  , GateBinding
  , Latency
  , MidiCcBinding
  , MidiNoteBinding
  , OscDevice
  , OutRef(..)
  , RootDevice
  , Statement(..)
  )
import Control.Alt ((<|>))
import Data.Array (many)
import Data.CodePoint.Unicode as CP
import Data.Either (Either)
import Data.Maybe (Maybe(..))
import Data.String (CodePoint, codePointFromChar)
import Data.String.CodeUnits as SCU
import Parsing (ParseError, Parser, fail, runParser)
import Parsing.Combinators (choice, optionMaybe, try)
import Parsing.String (char, eof, satisfy, string)
import Parsing.String.Basic (intDecimal, number, takeWhile1)

-- ───────────────────────────────────────────────────────────────────
-- Public entry points
-- ───────────────────────────────────────────────────────────────────

parseComposition :: String -> Either ParseError Composition
parseComposition input = runParser input compositionP

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

-- | Optional `latency N` clause.
latencyClauseP :: Parser String (Maybe Latency)
latencyClauseP = optionMaybe (try (hspace1 *> keyword "latency" *> number))

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
  [ try (StmtBinding <$> bindingP)
  , try (StmtDeviceConfig <$> deviceConfigP)
  , StmtDevice <$> deviceP
  ] <* hspace <* optionMaybe commentP

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
deviceConfigP = Fh2VoiceCfg <$> fh2ConfigP

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
