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
  , Fh2ModeConfig
  , PolySignalConfig
  , PolyFamily(..)
  , Bank(..)
  , PolyValue(..)
  , PolySlot
  , OutRef(..)
  , Binding(..)
  , MidiNoteBinding
  , MidiCcBinding
  , GateBinding
  , CvBinding
  , CvMode(..)
  , ControlStmt
  , TagStmt
  , CueStmt
  , compositionCodec
  , statementCodec
  , deviceCodec
  , bindingCodec
  , controlStmtCodec
  , tagStmtCodec
  , cueStmtCodec
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Codec as Codec
import Data.Codec.Argonaut (JsonCodec, JsonDecodeError)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Common as CAC
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
  -- Phase 1 additions for .tiderl model (2026-05-14):
  | StmtBpm Number                  -- ^ `bpm <n>` — default tempo
  | StmtLinkSync Boolean            -- ^ `link sync on|off` — follow Link
  | StmtControl ControlStmt         -- ^ `control <name> = <value>`
  | StmtTag TagStmt                 -- ^ `tag <name> = <default>`
  | StmtCue CueStmt                 -- ^ `cue <id> [<meta>] = <body>`
  -- Level 2 grammar additions (2026-05-15):
  | StmtSection String              -- ^ `# <Name>` section header; sets
                                    --   the mvoice context for subsequent
                                    --   `<tvoice> = <body>` declarations

derive instance eqStatement :: Eq Statement

-- | Body of a `control <name> = <value>` declaration (initial value
-- | for the live-control bus). Numeric only in v1.
type ControlStmt =
  { name :: String
  , value :: Number
  }

controlStmtCodec :: JsonCodec ControlStmt
controlStmtCodec = CAR.object "ControlStmt"
  { name: CA.string
  , value: CA.number
  }

-- | Body of a `tag <name> = <default>` declaration. Default value is
-- | a string ("on" / "off" / "verse" / "chorus" / etc.); booleans
-- | are spelled as the strings "on"/"off". Type-richer tags
-- | (ADT-shaped) are a future direction; v1 is strings only.
type TagStmt =
  { name :: String
  , defaultValue :: String
  }

tagStmtCodec :: JsonCodec TagStmt
tagStmtCodec = CAR.object "TagStmt"
  { name: CA.string
  , defaultValue: CA.string
  }

-- | Body of a `cue <id> [<meta>] = <body>` declaration. The cue is
-- | the file-textual form of a Voice Cells card. Body is stored
-- | verbatim — parsing the body as PureScript happens later in the
-- | cue compile pipeline, not here.
type CueStmt =
  { id :: String
  , mvoice :: Maybe String
  , tvoice :: Maybe String
  , whenTag :: Maybe String     -- ^ `when=<tag>` — card-level gate
  , body :: String
  }

cueStmtCodec :: JsonCodec CueStmt
cueStmtCodec = CAR.object "CueStmt"
  { id: CA.string
  , mvoice: CAR.optional CA.string
  , tvoice: CAR.optional CA.string
  , whenTag: CAR.optional CA.string
  , body: CA.string
  }

data StatementTag
  = TagDevice | TagDeviceConfig | TagBinding
  | TagBpm | TagLinkSync | TagControl | TagTag | TagCue | TagSection

derive instance eqStatementTag :: Eq StatementTag

statementCodec :: JsonCodec Statement
statementCodec = CAS.taggedSum "Statement" printTag parseTag decodeBy encodeBy
  where
  printTag = case _ of
    TagDevice -> "device"
    TagDeviceConfig -> "deviceConfig"
    TagBinding -> "binding"
    TagBpm -> "bpm"
    TagLinkSync -> "linkSync"
    TagControl -> "control"
    TagTag -> "tag"
    TagCue -> "cue"
    TagSection -> "section"
  parseTag = case _ of
    "device" -> Just TagDevice
    "deviceConfig" -> Just TagDeviceConfig
    "binding" -> Just TagBinding
    "bpm" -> Just TagBpm
    "linkSync" -> Just TagLinkSync
    "control" -> Just TagControl
    "tag" -> Just TagTag
    "cue" -> Just TagCue
    "section" -> Just TagSection
    _ -> Nothing
  decodeBy :: StatementTag -> Either Statement (Json -> Either JsonDecodeError Statement)
  decodeBy = case _ of
    TagDevice       -> Right (map StmtDevice       <<< Codec.decode deviceCodec)
    TagDeviceConfig -> Right (map StmtDeviceConfig <<< Codec.decode deviceConfigCodec)
    TagBinding      -> Right (map StmtBinding      <<< Codec.decode bindingCodec)
    TagBpm          -> Right (map StmtBpm          <<< Codec.decode CA.number)
    TagLinkSync     -> Right (map StmtLinkSync     <<< Codec.decode CA.boolean)
    TagControl      -> Right (map StmtControl      <<< Codec.decode controlStmtCodec)
    TagTag          -> Right (map StmtTag          <<< Codec.decode tagStmtCodec)
    TagCue          -> Right (map StmtCue          <<< Codec.decode cueStmtCodec)
    TagSection      -> Right (map StmtSection      <<< Codec.decode CA.string)
  encodeBy :: Statement -> Tuple StatementTag (Maybe Json)
  encodeBy = case _ of
    StmtDevice d       -> Tuple TagDevice       (Just (Codec.encode deviceCodec d))
    StmtDeviceConfig c -> Tuple TagDeviceConfig (Just (Codec.encode deviceConfigCodec c))
    StmtBinding b      -> Tuple TagBinding      (Just (Codec.encode bindingCodec b))
    StmtBpm n          -> Tuple TagBpm          (Just (Codec.encode CA.number n))
    StmtLinkSync b     -> Tuple TagLinkSync     (Just (Codec.encode CA.boolean b))
    StmtControl c      -> Tuple TagControl      (Just (Codec.encode controlStmtCodec c))
    StmtTag t          -> Tuple TagTag          (Just (Codec.encode tagStmtCodec t))
    StmtCue c          -> Tuple TagCue          (Just (Codec.encode cueStmtCodec c))
    StmtSection name   -> Tuple TagSection      (Just (Codec.encode CA.string name))

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

-- | Whole-rig mode change: names a mode from the fh2-config mode
-- | library (Ochd, Pam's New Workout, …) to apply to the addressed
-- | FH-2 alias. Distinct from `Fh2VoiceCfg`, which is per-voice wiring;
-- | this swaps the entire (Config, Preset) pair in one statement.
type Fh2ModeConfig =
  { device :: String      -- alias of the FH-2 device
  , modeName :: String    -- e.g. "ochd", "pnw" — looked up by fh2-config
  }

fh2ModeConfigCodec :: JsonCodec Fh2ModeConfig
fh2ModeConfigCodec = CAR.object "Fh2ModeConfig"
  { device: CA.string
  , modeName: CA.string
  }

-- | Output bank addressing for poly-family macros — matches the FH-2
-- | rig topology (main FH-2 panel + up to 7 FHX-8CV + up to 8 FHX-8GT
-- | expanders). Mirrors `FH2.Roles.Bank` in `fh2-config`; encoded as a
-- | small string ("main"/"cv0"/"gt1"/…) for human-readable JSON.
-- |
-- | Cell-text input is 1-indexed (`cv1`, `gt1` — first expander) but
-- | the AST is 0-indexed throughout (`BankCv 0`, `BankGt 0`). The
-- | parser translates once at the cell boundary.
data Bank
  = BankMain
  | BankCv Int     -- 0-indexed: BankCv 0 = first FHX-8CV
  | BankGt Int     -- 0-indexed: BankGt 0 = first FHX-8GT

derive instance eqBank :: Eq Bank

instance showBank :: Show Bank where
  show BankMain    = "BankMain"
  show (BankCv n)  = "BankCv " <> show n
  show (BankGt n)  = "BankGt " <> show n

-- | The six poly-family verbs supported by the cell-text grammar. Each
-- | dictates which parameter names the slot decoder will accept (the
-- | per-family vocabulary lives in `fh2-config`'s `FH2.PolyBank`).
data PolyFamily
  = PFPolyLfo
  | PFPolyClock
  | PFPolyEnv
  | PFPolyEuclid
  | PFPolyEuclidPairs
  | PFPolyRand

derive instance eqPolyFamily :: Eq PolyFamily

instance showPolyFamily :: Show PolyFamily where
  show PFPolyLfo         = "PFPolyLfo"
  show PFPolyClock       = "PFPolyClock"
  show PFPolyEnv         = "PFPolyEnv"
  show PFPolyEuclid      = "PFPolyEuclid"
  show PFPolyEuclidPairs = "PFPolyEuclidPairs"
  show PFPolyRand        = "PFPolyRand"

-- | One slot-major parameter value. Slots are opaque on the Calypso
-- | side — we don't typecheck per-family parameter sets here, only
-- | preserve enough type info to round-trip values through JSON and
-- | encode them into the fh2-config envelope shape.
data PolyValue
  = PVInt Int
  | PVNumber Number
  | PVToken String     -- enum token like "tri", "fwd", "c#"

derive instance eqPolyValue :: Eq PolyValue

instance showPolyValue :: Show PolyValue where
  show (PVInt n)    = "PVInt " <> show n
  show (PVNumber x) = "PVNumber " <> show x
  show (PVToken s)  = "PVToken " <> show s

-- | One slot — the parameters for one output (or pair, in
-- | `polyeuclid-pairs`). Stored as an ordered list of (name, value)
-- | pairs rather than a Map so source order survives round-trips and
-- | duplicate-key inputs can be flagged.
type PolySlot = Array (Tuple String PolyValue)

-- | A whole poly-family macro: alias of the target FH-2, family
-- | (verb), bank (panel), output range (optional voltage swing for
-- | the bank's 8 jacks), and an array of slots — 8 for most families,
-- | 4 for `polyeuclid-pairs`. Arity validation happens at parse time
-- | and at the `fh2-config` decoder.
-- |
-- | `outputRange` is an opaque string label (`"bipolar5v"`,
-- | `"unipolar5v"`, …) — fh2-config's `FH2.OutputRange.parseOutputRange`
-- | is authoritative on the supported vocabulary. Calypso stays
-- | label-agnostic so the parser doesn't need updating when fh2-config
-- | adds new range names.
type PolySignalConfig =
  { alias :: String
  , family :: PolyFamily
  , bank :: Bank
  , outputRange :: Maybe String
  , slots :: Array PolySlot
  }

bankCodec :: JsonCodec Bank
bankCodec = CAS.taggedSum "Bank" printTag parseTag decodeBy encodeBy
  where
  printTag = case _ of
    TagBankMain -> "main"
    TagBankCv   -> "cv"
    TagBankGt   -> "gt"
  parseTag = case _ of
    "main" -> Just TagBankMain
    "cv"   -> Just TagBankCv
    "gt"   -> Just TagBankGt
    _ -> Nothing
  decodeBy = case _ of
    TagBankMain -> Left BankMain
    TagBankCv   -> Right (map BankCv <<< Codec.decode CA.int)
    TagBankGt   -> Right (map BankGt <<< Codec.decode CA.int)
  encodeBy = case _ of
    BankMain  -> Tuple TagBankMain Nothing
    BankCv n  -> Tuple TagBankCv   (Just (Codec.encode CA.int n))
    BankGt n  -> Tuple TagBankGt   (Just (Codec.encode CA.int n))

data BankTag = TagBankMain | TagBankCv | TagBankGt

derive instance eqBankTag :: Eq BankTag

polyFamilyCodec :: JsonCodec PolyFamily
polyFamilyCodec = CAS.enumSum printFamily parseFamily
  where
  printFamily = case _ of
    PFPolyLfo         -> "polylfo"
    PFPolyClock       -> "polyclock"
    PFPolyEnv         -> "polyenv"
    PFPolyEuclid      -> "polyeuclid"
    PFPolyEuclidPairs -> "polyeuclid-pairs"
    PFPolyRand        -> "polyrand"
  parseFamily = case _ of
    "polylfo"          -> Just PFPolyLfo
    "polyclock"        -> Just PFPolyClock
    "polyenv"          -> Just PFPolyEnv
    "polyeuclid"       -> Just PFPolyEuclid
    "polyeuclid-pairs" -> Just PFPolyEuclidPairs
    "polyrand"         -> Just PFPolyRand
    _ -> Nothing

polyValueCodec :: JsonCodec PolyValue
polyValueCodec = CAS.taggedSum "PolyValue" printTag parseTag decodeBy encodeBy
  where
  printTag = case _ of
    TagPvInt    -> "int"
    TagPvNumber -> "number"
    TagPvToken  -> "token"
  parseTag = case _ of
    "int"    -> Just TagPvInt
    "number" -> Just TagPvNumber
    "token"  -> Just TagPvToken
    _ -> Nothing
  decodeBy = case _ of
    TagPvInt    -> Right (map PVInt    <<< Codec.decode CA.int)
    TagPvNumber -> Right (map PVNumber <<< Codec.decode CA.number)
    TagPvToken  -> Right (map PVToken  <<< Codec.decode CA.string)
  encodeBy = case _ of
    PVInt    n -> Tuple TagPvInt    (Just (Codec.encode CA.int    n))
    PVNumber n -> Tuple TagPvNumber (Just (Codec.encode CA.number n))
    PVToken  s -> Tuple TagPvToken  (Just (Codec.encode CA.string s))

data PolyValueTag = TagPvInt | TagPvNumber | TagPvToken

derive instance eqPolyValueTag :: Eq PolyValueTag

-- | Codec for one slot: an array of (name, value) pairs. Each pair is
-- | encoded as a 2-element JSON array `[name, value]` so source order
-- | survives.
polySlotCodec :: JsonCodec PolySlot
polySlotCodec = CA.array (CAC.tuple CA.string polyValueCodec)

polySignalConfigCodec :: JsonCodec PolySignalConfig
polySignalConfigCodec = CAR.object "PolySignalConfig"
  { alias: CA.string
  , family: polyFamilyCodec
  , bank: bankCodec
  , outputRange: CAR.optional CA.string
  , slots: CA.array polySlotCodec
  }

data DeviceConfig
  = Fh2VoiceCfg Fh2VoiceConfig
  | Fh2ModeCfg Fh2ModeConfig
  | PolySignalCfg PolySignalConfig

derive instance eqDeviceConfig :: Eq DeviceConfig

data DeviceConfigTag = TagFh2Voice | TagFh2Mode | TagPolySignal

derive instance eqDeviceConfigTag :: Eq DeviceConfigTag

deviceConfigCodec :: JsonCodec DeviceConfig
deviceConfigCodec = CAS.taggedSum "DeviceConfig" printTag parseTag decodeBy encodeBy
  where
  printTag = case _ of
    TagFh2Voice  -> "fh2Voice"
    TagFh2Mode   -> "fh2Mode"
    TagPolySignal -> "polySignal"
  parseTag = case _ of
    "fh2Voice"  -> Just TagFh2Voice
    "fh2Mode"   -> Just TagFh2Mode
    "polySignal" -> Just TagPolySignal
    _ -> Nothing
  decodeBy :: DeviceConfigTag -> Either DeviceConfig (Json -> Either JsonDecodeError DeviceConfig)
  decodeBy = case _ of
    TagFh2Voice  -> Right (map Fh2VoiceCfg  <<< Codec.decode fh2VoiceConfigCodec)
    TagFh2Mode   -> Right (map Fh2ModeCfg   <<< Codec.decode fh2ModeConfigCodec)
    TagPolySignal -> Right (map PolySignalCfg <<< Codec.decode polySignalConfigCodec)
  encodeBy :: DeviceConfig -> Tuple DeviceConfigTag (Maybe Json)
  encodeBy = case _ of
    Fh2VoiceCfg  c -> Tuple TagFh2Voice  (Just (Codec.encode fh2VoiceConfigCodec  c))
    Fh2ModeCfg   c -> Tuple TagFh2Mode   (Just (Codec.encode fh2ModeConfigCodec   c))
    PolySignalCfg c -> Tuple TagPolySignal (Just (Codec.encode polySignalConfigCodec c))

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
  -- | `cv-cont`: continuous-CV binding. Reuses CvBinding's shape;
  -- | the `mode` field is meaningless for cv-cont (always literal)
  -- | and its value is ignored on the wire and during dispatch.
  | BindCvCont     CvBinding

derive instance eqBinding :: Eq Binding

data BindingTag
  = TagMidiNote
  | TagMidiCc
  | TagMidiCcCont
  | TagGate
  | TagCv
  | TagCvCont

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
    TagCvCont     -> "cv-cont"
  parseTag = case _ of
    "midi-note"    -> Just TagMidiNote
    "midi-cc"      -> Just TagMidiCc
    "midi-cc-cont" -> Just TagMidiCcCont
    "gate"         -> Just TagGate
    "cv"           -> Just TagCv
    "cv-cont"      -> Just TagCvCont
    _ -> Nothing
  decodeBy :: BindingTag -> Either Binding (Json -> Either JsonDecodeError Binding)
  decodeBy = case _ of
    TagMidiNote   -> Right (map BindMidiNote   <<< Codec.decode midiNoteBindingCodec)
    TagMidiCc     -> Right (map BindMidiCc     <<< Codec.decode midiCcBindingCodec)
    TagMidiCcCont -> Right (map BindMidiCcCont <<< Codec.decode midiCcBindingCodec)
    TagGate       -> Right (map BindGate       <<< Codec.decode gateBindingCodec)
    TagCv         -> Right (map BindCv         <<< Codec.decode cvBindingCodec)
    TagCvCont     -> Right (map BindCvCont     <<< Codec.decode cvBindingCodec)
  encodeBy :: Binding -> Tuple BindingTag (Maybe Json)
  encodeBy = case _ of
    BindMidiNote   r -> Tuple TagMidiNote   (Just (Codec.encode midiNoteBindingCodec r))
    BindMidiCc     r -> Tuple TagMidiCc     (Just (Codec.encode midiCcBindingCodec   r))
    BindMidiCcCont r -> Tuple TagMidiCcCont (Just (Codec.encode midiCcBindingCodec   r))
    BindGate       r -> Tuple TagGate       (Just (Codec.encode gateBindingCodec     r))
    BindCv         r -> Tuple TagCv         (Just (Codec.encode cvBindingCodec       r))
    BindCvCont     r -> Tuple TagCvCont     (Just (Codec.encode cvBindingCodec       r))
