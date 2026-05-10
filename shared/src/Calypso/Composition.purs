-- | AST for the Calypso composition grammar (the routing portion of a
-- | session: device declarations, device-internal config, and bindings).
-- |
-- | See `docs/composition-grammar.md` for the spec.  This module owns
-- | the typed shape; `Calypso.Composition.Parser` parses text into it,
-- | and the JSON codecs below carry it across the HTTP wire.
module Calypso.Composition
  ( Composition(..)
  , Statement(..)
  , Device(..)
  , Latency
  , RootDevice
  , ExpanderDevice
  , OscDevice
  , DeviceConfig(..)
  , Fh2VoiceConfig
  , Fh2VoiceMode(..)
  , OutRef(..)
  , Binding(..)
  , MidiNoteBinding
  , MidiCcBinding
  , GateBinding
  , CvBinding
  , CvMode(..)
  , compositionCodec
  , statementCodec
  , deviceCodec
  , bindingCodec
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Codec as Codec
import Data.Codec.Argonaut (JsonCodec, JsonDecodeError)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Codec.Argonaut.Sum as CAS
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))

-- ───────────────────────────────────────────────────────────────────
-- Top-level
-- ───────────────────────────────────────────────────────────────────

-- | A whole composition file, parsed.  Statements appear in source
-- | order; resolution (alias lookups, parent walks) is up to the
-- | consumer.
newtype Composition = Composition (Array Statement)

derive newtype instance eqComposition :: Eq Composition

compositionCodec :: JsonCodec Composition
compositionCodec = CA.prismaticCodec "Composition"
  (\arr -> Just (Composition arr))
  (\(Composition arr) -> arr)
  (CA.array statementCodec)

-- | One statement.  Each grammar production gets its own constructor.
data Statement
  = StmtDevice Device
  | StmtDeviceConfig DeviceConfig
  | StmtBinding Binding

derive instance eqStatement :: Eq Statement

data StatementTag = TagDevice | TagDeviceConfig | TagBinding

derive instance eqStatementTag :: Eq StatementTag

statementCodec :: JsonCodec Statement
statementCodec = CAS.taggedSum "Statement" printTag parseTag decodeBy encodeBy
  where
  printTag = case _ of
    TagDevice -> "device"
    TagDeviceConfig -> "deviceConfig"
    TagBinding -> "binding"
  parseTag = case _ of
    "device" -> Just TagDevice
    "deviceConfig" -> Just TagDeviceConfig
    "binding" -> Just TagBinding
    _ -> Nothing
  decodeBy :: StatementTag -> Either Statement (Json -> Either JsonDecodeError Statement)
  decodeBy = case _ of
    TagDevice       -> Right (map StmtDevice       <<< Codec.decode deviceCodec)
    TagDeviceConfig -> Right (map StmtDeviceConfig <<< Codec.decode deviceConfigCodec)
    TagBinding      -> Right (map StmtBinding      <<< Codec.decode bindingCodec)
  encodeBy :: Statement -> Tuple StatementTag (Maybe Json)
  encodeBy = case _ of
    StmtDevice d       -> Tuple TagDevice       (Just (Codec.encode deviceCodec d))
    StmtDeviceConfig c -> Tuple TagDeviceConfig (Just (Codec.encode deviceConfigCodec c))
    StmtBinding b      -> Tuple TagBinding      (Just (Codec.encode bindingCodec b))

-- ───────────────────────────────────────────────────────────────────
-- Devices
-- ───────────────────────────────────────────────────────────────────

-- | Latency in milliseconds (non-negative).  Optional on every device
-- | and binding declaration; default 0 when absent.
type Latency = Number

-- | Root device record — has a port name.  Used by `midi`, `es9`,
-- | `fh2`, `yarns`.
type RootDevice =
  { alias :: String
  , port :: String
  , latency :: Maybe Latency
  }

-- | Expander record — declares its parent's alias instead of a port.
-- | Used by `es5`, `esx-8gt`, `esx-8cv`, `fhx-8gt`.  Parent-type
-- | compatibility is checked by a follow-up resolver, not the parser.
type ExpanderDevice =
  { alias :: String
  , parent :: String
  }

-- | OSC target — host + port instead of a CoreMIDI/CoreAudio name.
type OscDevice =
  { alias :: String
  , host :: String
  , port :: Int
  }

-- | All device-declaration shapes in one ADT.
data Device
  = DevMidi    RootDevice
  | DevEs9     RootDevice
  | DevFh2     RootDevice
  | DevYarns   RootDevice
  | DevOsc     OscDevice
  | DevEs5     ExpanderDevice
  | DevEsx8Gt  ExpanderDevice
  | DevEsx8Cv  ExpanderDevice
  | DevFhx8Gt  ExpanderDevice

derive instance eqDevice :: Eq Device

data DeviceTag
  = TagMidi | TagEs9 | TagFh2 | TagYarns | TagOsc
  | TagEs5 | TagEsx8Gt | TagEsx8Cv | TagFhx8Gt

derive instance eqDeviceTag :: Eq DeviceTag

rootDeviceCodec :: JsonCodec RootDevice
rootDeviceCodec = CAR.object "RootDevice"
  { alias: CA.string
  , port: CA.string
  , latency: CAR.optional CA.number
  }

expanderDeviceCodec :: JsonCodec ExpanderDevice
expanderDeviceCodec = CAR.object "ExpanderDevice"
  { alias: CA.string
  , parent: CA.string
  }

oscDeviceCodec :: JsonCodec OscDevice
oscDeviceCodec = CAR.object "OscDevice"
  { alias: CA.string
  , host: CA.string
  , port: CA.int
  }

deviceCodec :: JsonCodec Device
deviceCodec = CAS.taggedSum "Device" printTag parseTag decodeBy encodeBy
  where
  printTag = case _ of
    TagMidi    -> "midi"
    TagEs9     -> "es9"
    TagFh2     -> "fh2"
    TagYarns   -> "yarns"
    TagOsc     -> "osc"
    TagEs5     -> "es5"
    TagEsx8Gt  -> "esx-8gt"
    TagEsx8Cv  -> "esx-8cv"
    TagFhx8Gt  -> "fhx-8gt"
  parseTag = case _ of
    "midi"    -> Just TagMidi
    "es9"     -> Just TagEs9
    "fh2"     -> Just TagFh2
    "yarns"   -> Just TagYarns
    "osc"     -> Just TagOsc
    "es5"     -> Just TagEs5
    "esx-8gt" -> Just TagEsx8Gt
    "esx-8cv" -> Just TagEsx8Cv
    "fhx-8gt" -> Just TagFhx8Gt
    _ -> Nothing
  decodeBy :: DeviceTag -> Either Device (Json -> Either JsonDecodeError Device)
  decodeBy = case _ of
    TagMidi    -> Right (map DevMidi    <<< Codec.decode rootDeviceCodec)
    TagEs9     -> Right (map DevEs9     <<< Codec.decode rootDeviceCodec)
    TagFh2     -> Right (map DevFh2     <<< Codec.decode rootDeviceCodec)
    TagYarns   -> Right (map DevYarns   <<< Codec.decode rootDeviceCodec)
    TagOsc     -> Right (map DevOsc     <<< Codec.decode oscDeviceCodec)
    TagEs5     -> Right (map DevEs5     <<< Codec.decode expanderDeviceCodec)
    TagEsx8Gt  -> Right (map DevEsx8Gt  <<< Codec.decode expanderDeviceCodec)
    TagEsx8Cv  -> Right (map DevEsx8Cv  <<< Codec.decode expanderDeviceCodec)
    TagFhx8Gt  -> Right (map DevFhx8Gt  <<< Codec.decode expanderDeviceCodec)
  encodeBy :: Device -> Tuple DeviceTag (Maybe Json)
  encodeBy = case _ of
    DevMidi   r -> Tuple TagMidi    (Just (Codec.encode rootDeviceCodec     r))
    DevEs9    r -> Tuple TagEs9     (Just (Codec.encode rootDeviceCodec     r))
    DevFh2    r -> Tuple TagFh2     (Just (Codec.encode rootDeviceCodec     r))
    DevYarns  r -> Tuple TagYarns   (Just (Codec.encode rootDeviceCodec     r))
    DevOsc    r -> Tuple TagOsc     (Just (Codec.encode oscDeviceCodec      r))
    DevEs5    r -> Tuple TagEs5     (Just (Codec.encode expanderDeviceCodec r))
    DevEsx8Gt r -> Tuple TagEsx8Gt  (Just (Codec.encode expanderDeviceCodec r))
    DevEsx8Cv r -> Tuple TagEsx8Cv  (Just (Codec.encode expanderDeviceCodec r))
    DevFhx8Gt r -> Tuple TagFhx8Gt  (Just (Codec.encode expanderDeviceCodec r))

-- ───────────────────────────────────────────────────────────────────
-- Device-internal config (FH-2 voice modes, today)
-- ───────────────────────────────────────────────────────────────────

-- | Output reference inside an FH-2 config statement.  Either a bare
-- | local MCV slot (`out=1`) or an expander slot (`out=ftrig:0`).
data OutRef
  = OutLocal Int
  | OutExpander String Int

derive instance eqOutRef :: Eq OutRef

data OutRefTag = TagOutLocal | TagOutExpander

derive instance eqOutRefTag :: Eq OutRefTag

outExpanderRecCodec :: JsonCodec { alias :: String, slot :: Int }
outExpanderRecCodec = CAR.object "OutExpander"
  { alias: CA.string, slot: CA.int }

outRefCodec :: JsonCodec OutRef
outRefCodec = CAS.taggedSum "OutRef" printTag parseTag decodeBy encodeBy
  where
  printTag = case _ of
    TagOutLocal    -> "local"
    TagOutExpander -> "expander"
  parseTag = case _ of
    "local"    -> Just TagOutLocal
    "expander" -> Just TagOutExpander
    _ -> Nothing
  decodeBy :: OutRefTag -> Either OutRef (Json -> Either JsonDecodeError OutRef)
  decodeBy = case _ of
    TagOutLocal    -> Right (map OutLocal <<< Codec.decode CA.int)
    TagOutExpander -> Right \j -> do
      r <- Codec.decode outExpanderRecCodec j
      pure (OutExpander r.alias r.slot)
  encodeBy :: OutRef -> Tuple OutRefTag (Maybe Json)
  encodeBy = case _ of
    OutLocal i      -> Tuple TagOutLocal    (Just (Codec.encode CA.int i))
    OutExpander a s -> Tuple TagOutExpander (Just (Codec.encode outExpanderRecCodec { alias: a, slot: s }))

-- | Configurable wire-mode of an FH-2 voice.  v1 supports envelope and
-- | gate; cv-mode and trigger-mode arrive when wired.
data Fh2VoiceMode = Fh2Envelope | Fh2Gate

derive instance eqFh2VoiceMode :: Eq Fh2VoiceMode

fh2VoiceModeCodec :: JsonCodec Fh2VoiceMode
fh2VoiceModeCodec = CAS.enumSum printMode parseMode
  where
  printMode = case _ of
    Fh2Envelope -> "envelope"
    Fh2Gate     -> "gate"
  parseMode = case _ of
    "envelope" -> Just Fh2Envelope
    "gate"     -> Just Fh2Gate
    _ -> Nothing

type Fh2VoiceConfig =
  { device :: String
  , mode :: Fh2VoiceMode
  , voice :: Int
  , out :: OutRef
  , channel :: Int
  }

fh2VoiceConfigCodec :: JsonCodec Fh2VoiceConfig
fh2VoiceConfigCodec = CAR.object "Fh2VoiceConfig"
  { device: CA.string
  , mode: fh2VoiceModeCodec
  , voice: CA.int
  , out: outRefCodec
  , channel: CA.int
  }

data DeviceConfig = Fh2VoiceCfg Fh2VoiceConfig

derive instance eqDeviceConfig :: Eq DeviceConfig

data DeviceConfigTag = TagFh2Voice

derive instance eqDeviceConfigTag :: Eq DeviceConfigTag

deviceConfigCodec :: JsonCodec DeviceConfig
deviceConfigCodec = CAS.taggedSum "DeviceConfig" printTag parseTag decodeBy encodeBy
  where
  printTag _ = "fh2Voice"
  parseTag = case _ of
    "fh2Voice" -> Just TagFh2Voice
    _ -> Nothing
  decodeBy :: DeviceConfigTag -> Either DeviceConfig (Json -> Either JsonDecodeError DeviceConfig)
  decodeBy _ = Right (map Fh2VoiceCfg <<< Codec.decode fh2VoiceConfigCodec)
  encodeBy :: DeviceConfig -> Tuple DeviceConfigTag (Maybe Json)
  encodeBy (Fh2VoiceCfg c) = Tuple TagFh2Voice (Just (Codec.encode fh2VoiceConfigCodec c))

-- ───────────────────────────────────────────────────────────────────
-- Bindings
-- ───────────────────────────────────────────────────────────────────

type MidiNoteBinding =
  { name :: String
  , device :: String
  , channel :: Int
  , note :: Int
  , velocity :: Int
  , durationMs :: Int
  , latency :: Maybe Latency
  }

type MidiCcBinding =
  { name :: String
  , device :: String
  , channel :: Int
  , cc :: Int
  , latency :: Maybe Latency
  }

type GateBinding =
  { name :: String
  , device :: String
  , channel :: Int
  , latency :: Maybe Latency
  }

-- | CV-binding mode.  Required on every `cv` statement (no implicit
-- | default).
data CvMode = CvVoct | CvLiteral | CvSampleMap

derive instance eqCvMode :: Eq CvMode

cvModeCodec :: JsonCodec CvMode
cvModeCodec = CAS.enumSum printMode parseMode
  where
  printMode = case _ of
    CvVoct      -> "voct"
    CvLiteral   -> "literal"
    CvSampleMap -> "sample-map"
  parseMode = case _ of
    "voct"       -> Just CvVoct
    "literal"    -> Just CvLiteral
    "sample-map" -> Just CvSampleMap
    _ -> Nothing

type CvBinding =
  { name :: String
  , device :: String
  , busOrSlot :: Int
  , mode :: CvMode
  , latency :: Maybe Latency
  }

data Binding
  = BindMidiNote   MidiNoteBinding
  | BindMidiCc     MidiCcBinding
  | BindMidiCcCont MidiCcBinding
  | BindGate       GateBinding
  | BindCv         CvBinding

derive instance eqBinding :: Eq Binding

data BindingTag
  = TagMidiNote
  | TagMidiCc
  | TagMidiCcCont
  | TagGate
  | TagCv

derive instance eqBindingTag :: Eq BindingTag

midiNoteBindingCodec :: JsonCodec MidiNoteBinding
midiNoteBindingCodec = CAR.object "MidiNoteBinding"
  { name: CA.string
  , device: CA.string
  , channel: CA.int
  , note: CA.int
  , velocity: CA.int
  , durationMs: CA.int
  , latency: CAR.optional CA.number
  }

midiCcBindingCodec :: JsonCodec MidiCcBinding
midiCcBindingCodec = CAR.object "MidiCcBinding"
  { name: CA.string
  , device: CA.string
  , channel: CA.int
  , cc: CA.int
  , latency: CAR.optional CA.number
  }

gateBindingCodec :: JsonCodec GateBinding
gateBindingCodec = CAR.object "GateBinding"
  { name: CA.string
  , device: CA.string
  , channel: CA.int
  , latency: CAR.optional CA.number
  }

cvBindingCodec :: JsonCodec CvBinding
cvBindingCodec = CAR.object "CvBinding"
  { name: CA.string
  , device: CA.string
  , busOrSlot: CA.int
  , mode: cvModeCodec
  , latency: CAR.optional CA.number
  }

bindingCodec :: JsonCodec Binding
bindingCodec = CAS.taggedSum "Binding" printTag parseTag decodeBy encodeBy
  where
  printTag = case _ of
    TagMidiNote   -> "midi-note"
    TagMidiCc     -> "midi-cc"
    TagMidiCcCont -> "midi-cc-cont"
    TagGate       -> "gate"
    TagCv         -> "cv"
  parseTag = case _ of
    "midi-note"    -> Just TagMidiNote
    "midi-cc"      -> Just TagMidiCc
    "midi-cc-cont" -> Just TagMidiCcCont
    "gate"         -> Just TagGate
    "cv"           -> Just TagCv
    _ -> Nothing
  decodeBy :: BindingTag -> Either Binding (Json -> Either JsonDecodeError Binding)
  decodeBy = case _ of
    TagMidiNote   -> Right (map BindMidiNote   <<< Codec.decode midiNoteBindingCodec)
    TagMidiCc     -> Right (map BindMidiCc     <<< Codec.decode midiCcBindingCodec)
    TagMidiCcCont -> Right (map BindMidiCcCont <<< Codec.decode midiCcBindingCodec)
    TagGate       -> Right (map BindGate       <<< Codec.decode gateBindingCodec)
    TagCv         -> Right (map BindCv         <<< Codec.decode cvBindingCodec)
  encodeBy :: Binding -> Tuple BindingTag (Maybe Json)
  encodeBy = case _ of
    BindMidiNote   r -> Tuple TagMidiNote   (Just (Codec.encode midiNoteBindingCodec r))
    BindMidiCc     r -> Tuple TagMidiCc     (Just (Codec.encode midiCcBindingCodec   r))
    BindMidiCcCont r -> Tuple TagMidiCcCont (Just (Codec.encode midiCcBindingCodec   r))
    BindGate       r -> Tuple TagGate       (Just (Codec.encode gateBindingCodec     r))
    BindCv         r -> Tuple TagCv         (Just (Codec.encode cvBindingCodec       r))
