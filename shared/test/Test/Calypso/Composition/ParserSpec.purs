module Test.Calypso.Composition.ParserSpec (parserSpec) where

import Prelude

import Calypso.Composition
  ( Bank(..)
  , Binding(..)
  , Composition(..)
  , DeviceConfig(..)
  , PolyFamily(..)
  , PolySignalConfig
  , PolySlot
  , PolyValue(..)
  , Statement(..)
  )
import Calypso.Composition.Parser (parseComposition, parseStatement, prettyPolySignal)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), contains) as Str
import Data.Tuple (Tuple(..), snd)
import Parsing (parseErrorMessage)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

parserSpec :: Spec Unit
parserSpec = describe "Calypso.Composition.Parser" do
  outputRangeCanonicalisation
  accentOffPolyEuclidPairs
  baseShape
  latShortFormSpec
  tiderlPhase1Spec

-- | Phase 1 of the .tiderl format: bpm / link-sync / control / tag /
-- | cue declarations on top of the existing devices+bindings grammar.
-- | Design doc: docs/tiderl-format-design-2026-05-14.md.
-- |
-- | Statement doesn't derive Show, so the tests pattern-match rather
-- | than using shouldEqual directly. shouldEqual on extracted fields
-- | gives readable diffs when something is off.
tiderlPhase1Spec :: Spec Unit
tiderlPhase1Spec = describe "tiderl phase-1 statements" do
  describe "bpm" do
    it "parses `bpm 124`" do
      case parseFirst "bpm 124\n" of
        Right (StmtBpm n) -> n `shouldEqual` 124.0
        other -> failWith "StmtBpm 124.0" other
    it "parses fractional bpm" do
      case parseFirst "bpm 123.5\n" of
        Right (StmtBpm n) -> n `shouldEqual` 123.5
        other -> failWith "StmtBpm 123.5" other

  describe "link sync" do
    it "parses `link sync on`" do
      case parseFirst "link sync on\n" of
        Right (StmtLinkSync b) -> b `shouldEqual` true
        other -> failWith "StmtLinkSync true" other
    it "parses `link sync off`" do
      case parseFirst "link sync off\n" of
        Right (StmtLinkSync b) -> b `shouldEqual` false
        other -> failWith "StmtLinkSync false" other
    it "rejects `link sync maybe`" do
      case parseFirst "link sync maybe\n" of
        Left _ -> pure unit
        Right _ -> fail "expected parse fail"

  describe "control" do
    it "parses `control bass-amp = 0.85`" do
      case parseFirst "control bass-amp = 0.85\n" of
        Right (StmtControl r) -> do
          r.name `shouldEqual` "bass-amp"
          r.value `shouldEqual` 0.85
        other -> failWith "StmtControl" other
    it "parses integer values" do
      case parseFirst "control intensity = 3\n" of
        Right (StmtControl r) -> do
          r.name `shouldEqual` "intensity"
          r.value `shouldEqual` 3.0
        other -> failWith "StmtControl" other

  describe "tag" do
    it "parses `tag fill = off`" do
      case parseFirst "tag fill = off\n" of
        Right (StmtTag r) -> do
          r.name `shouldEqual` "fill"
          r.defaultValue `shouldEqual` "off"
        other -> failWith "StmtTag fill" other
    it "parses `tag section = verse`" do
      case parseFirst "tag section = verse\n" of
        Right (StmtTag r) -> do
          r.name `shouldEqual` "section"
          r.defaultValue `shouldEqual` "verse"
        other -> failWith "StmtTag section" other

  describe "cue" do
    it "parses a bare cue with no metadata" do
      case parseFirst "cue d1 = mini \"x ~ x ~\"\n" of
        Right (StmtCue r) -> do
          r.id `shouldEqual` "d1"
          r.mvoice `shouldEqual` Nothing
          r.tvoice `shouldEqual` Nothing
          r.whenTag `shouldEqual` Nothing
          r.body `shouldEqual` "mini \"x ~ x ~\""
        other -> failWith "StmtCue d1" other
    it "parses cue with mvoice + tvoice metadata" do
      case parseFirst "cue d1 [mvoice=drums tvoice=qd1] = mini \"x ~\"\n" of
        Right (StmtCue r) -> do
          r.id `shouldEqual` "d1"
          r.mvoice `shouldEqual` Just "drums"
          r.tvoice `shouldEqual` Just "qd1"
          r.whenTag `shouldEqual` Nothing
          r.body `shouldEqual` "mini \"x ~\""
        other -> failWith "StmtCue d1 [meta]" other
    it "parses cue with when= gate" do
      case parseFirst "cue d-fill [mvoice=drums tvoice=qd2 when=fill] = mini \"x x x x\"\n" of
        Right (StmtCue r) -> do
          r.id `shouldEqual` "d-fill"
          r.whenTag `shouldEqual` Just "fill"
          r.body `shouldEqual` "mini \"x x x x\""
        other -> failWith "StmtCue d-fill" other
    it "preserves complex body text verbatim" do
      let body = "every 4 rev (mini \"c2 e2 g2 ~ b2 ~ g2 e2\") # gain (live \"amp\")"
      case parseFirst ("cue b1 [mvoice=bass tvoice=cip-pitch] = " <> body <> "\n") of
        Right (StmtCue r) -> do
          r.id `shouldEqual` "b1"
          r.mvoice `shouldEqual` Just "bass"
          r.tvoice `shouldEqual` Just "cip-pitch"
          r.body `shouldEqual` body
        other -> failWith "StmtCue b1" other

  describe "mixed file" do
    it "parses a small .tiderl-shaped composition" do
      let src =
            "bpm 124\n"
              <> "link sync on\n"
              <> "midi fh2 \"FH-2\"\n"
              <> "midi-note qd1 fh2 14 60 100 50\n"
              <> "control bass-amp = 0.85\n"
              <> "tag fill = off\n"
              <> "cue d1 [mvoice=drums tvoice=qd1] = mini \"x ~ x ~\"\n"
      case parseComposition src of
        Left e -> fail $ "parse failed: " <> parseErrorMessage e
        Right (Composition stmts) ->
          Array.length stmts `shouldEqual` 7
  where
  parseFirst :: String -> Either String Statement
  parseFirst src = case parseComposition src of
    Left e -> Left (parseErrorMessage e)
    Right (Composition stmts) -> case Array.head stmts of
      Just s -> Right s
      Nothing -> Left "no statements parsed"

  failWith :: forall a. String -> Either String Statement -> _ Unit
  failWith expected actual = fail $ "expected " <> expected <> ", got: " <> shortDesc actual

  shortDesc :: Either String Statement -> String
  shortDesc = case _ of
    Left e -> "Left " <> e
    Right s -> "Right " <> describeStmt s

  describeStmt :: Statement -> String
  describeStmt = case _ of
    StmtDevice _       -> "StmtDevice"
    StmtDeviceConfig _ -> "StmtDeviceConfig"
    StmtBinding _      -> "StmtBinding"
    StmtBpm n          -> "StmtBpm " <> show n
    StmtLinkSync b     -> "StmtLinkSync " <> show b
    StmtControl _      -> "StmtControl"
    StmtTag _          -> "StmtTag"
    StmtCue _          -> "StmtCue"

-- | Regression for the `lat` vs `latency` keyword: every setup file
-- | and the daemon's `midi-device` arm use `lat`, but Calypso's
-- | grammar used to require `latency` (silent parse failure surfaced
-- | as no card-coloring on cip-gate).
latShortFormSpec :: Spec Unit
latShortFormSpec = describe "lat short-form latency keyword" do
  it "accepts `lat N` after a midi device declaration" do
    case parseComposition "midi fh2 \"FH-2\" lat 69\n" of
      Left e -> fail $ "midi+lat failed: " <> parseErrorMessage e
      Right _ -> pure unit
  it "accepts `latency N` after a midi device declaration" do
    case parseComposition "midi fh2 \"FH-2\" latency 69\n" of
      Left e -> fail $ "midi+latency failed: " <> parseErrorMessage e
      Right _ -> pure unit
  it "parses a gate binding embedded in a multi-device composition" do
    let src =
          "midi fh2     \"FH-2\"\n"
            <> "midi fh2-qd  \"FH-2\" lat 69\n"
            <> "es9  es9     \"ES-9\"\n"
            <> "gate cip-gate fh2 0\n"
    case parseComposition src of
      Left e -> fail $ "parse failed: " <> parseErrorMessage e
      Right (Composition stmts) -> do
        let gateName = Array.findMap extractGateName stmts
        gateName `shouldEqual` Just "cip-gate"
  where
  extractGateName = case _ of
    StmtBinding (BindGate b) -> Just b.name
    _ -> Nothing

-- ──────────────────────────────────────────────────────────────────────
-- ±5v canonicalisation (Task 11)
-- ──────────────────────────────────────────────────────────────────────

outputRangeCanonicalisation :: Spec Unit
outputRangeCanonicalisation = describe "outputRange canonicalisation" do
  describe "singleton `range <token>` continuation" do
    it "accepts ±5v as the canonical bipolar token" do
      polysignalOutputRange "polylfo myLFO main <>\n  range ±5v"
        `shouldEqual` Right (Just "±5v")

    it "canonicalises +/-5v → ±5v at parse time" do
      polysignalOutputRange "polylfo myLFO main <>\n  range +/-5v"
        `shouldEqual` Right (Just "±5v")

    it "leaves bipolar5v as-is (no canonicalisation for verbose form)" do
      polysignalOutputRange "polylfo myLFO main <>\n  range bipolar5v"
        `shouldEqual` Right (Just "bipolar5v")

    it "leaves pm5v as-is" do
      polysignalOutputRange "polylfo myLFO main <>\n  range pm5v"
        `shouldEqual` Right (Just "pm5v")

    it "rejects an unknown range token" do
      case polysignalOutputRange "polylfo myLFO main <>\n  range +6v" of
        Left _ -> pure unit
        Right r -> fail $ "expected parse failure, got: " <> show r

  describe "per-slot `ranges [...]` 8-vector" do
    it "canonicalises every +/-5v in the list to ±5v" do
      let s = "polylfo myLFO main <>\n"
              <> "  ratios [1, 2, 4, 8, 1.3, 2.6, 5.2, 10.4] <>\n"
              <> "  ranges [+/-5v, +/-5v, +/-5v, +/-5v, +5v, +5v, +5v, +5v]"
      case polysignalParse s of
        Left e -> fail $ "parse failed: " <> e
        Right cfg -> do
          slotRangeTokenAt 0 cfg `shouldEqual` Just "±5v"
          slotRangeTokenAt 3 cfg `shouldEqual` Just "±5v"
          slotRangeTokenAt 4 cfg `shouldEqual` Just "+5v"
          slotRangeTokenAt 7 cfg `shouldEqual` Just "+5v"

  describe "pretty-printer round-trip" do
    it "emits ±5v after parsing +/-5v" do
      let s = "polylfo myLFO main <>\n  range +/-5v"
      case polysignalParse s of
        Left e -> fail $ "parse failed: " <> e
        Right cfg -> do
          let pretty = prettyPolySignal cfg
          Str.contains (Str.Pattern "±5v") pretty `shouldEqual` true
          Str.contains (Str.Pattern "+/-5v") pretty `shouldEqual` false

-- ──────────────────────────────────────────────────────────────────────
-- `accent off` and rejection of accentRate 0 in polyeuclid-pairs (Task 13)
-- ──────────────────────────────────────────────────────────────────────

accentOffPolyEuclidPairs :: Spec Unit
accentOffPolyEuclidPairs = describe "polyeuclid-pairs accent silencing" do
  describe "`accent off` block-line" do
    it "is accepted in polyeuclid-pairs and silences all 4 pairs" do
      let s = "polyeuclid-pairs myPair gt1 <>\n"
              <> "  beats [3, 5, 4, 7] <>\n"
              <> "  steps [8, 8, 8, 16] <>\n"
              <> "  rate  [12, 12, 12, 12] <>\n"
              <> "  accent off"
      case polysignalParse s of
        Left e -> fail $ "parse failed: " <> e
        Right cfg -> do
          Array.length cfg.slots `shouldEqual` 4
          slotAccentRateAt 0 cfg `shouldEqual` Just (PVInt 0)
          slotAccentRateAt 3 cfg `shouldEqual` Just (PVInt 0)

    it "is rejected in polyeuclid (gates-only — accent jacks inert there)" do
      case polysignalParse "polyeuclid myEuc gt1 <>\n  accent off" of
        Left _ -> pure unit   -- specific message lost in family-choice cascade
        Right r -> fail $ "expected parse failure, got: " <> show r

  describe "accentRate 0 rejection in polyeuclid-pairs" do
    it "rejects accentRate when any pair value is 0" do
      let s = "polyeuclid-pairs myPair gt1 <>\n"
              <> "  beats [3, 5, 4, 7] <>\n"
              <> "  steps [8, 8, 8, 16] <>\n"
              <> "  rate  [12, 12, 12, 12] <>\n"
              <> "  accentRate [12, 0, 12, 12]"
      case polysignalParse s of
        Left _ -> pure unit   -- specific message lost in family-choice cascade
        Right r -> fail $ "expected parse failure, got: " <> show r

    it "accepts accentRate [0, 0, 0, 0, 0, 0, 0, 0] in polyeuclid (default rate)" do
      let s = "polyeuclid myEuc gt1 <>\n"
              <> "  beats [3, 3, 3, 3, 3, 3, 3, 3] <>\n"
              <> "  steps [8, 8, 8, 8, 8, 8, 8, 8] <>\n"
              <> "  rate  [12, 12, 12, 12, 12, 12, 12, 12] <>\n"
              <> "  accentRate [0, 0, 0, 0, 0, 0, 0, 0]"
      case polysignalParse s of
        Left e -> fail $ "expected parse to succeed (accentRate 0 is fine in gates-only polyeuclid), got: " <> e
        Right _ -> pure unit

  describe "pretty-printer round-trip" do
    it "re-emits `accent off` and omits the accentRate row" do
      let s = "polyeuclid-pairs myPair gt1 <>\n"
              <> "  beats [3, 5, 4, 7] <>\n"
              <> "  steps [8, 8, 8, 16] <>\n"
              <> "  rate  [12, 12, 12, 12] <>\n"
              <> "  accent off"
      case polysignalParse s of
        Left e -> fail $ "parse failed: " <> e
        Right cfg -> do
          let pretty = prettyPolySignal cfg
          Str.contains (Str.Pattern "accent off") pretty `shouldEqual` true
          Str.contains (Str.Pattern "accentRate") pretty `shouldEqual` false

-- ──────────────────────────────────────────────────────────────────────
-- Base shape sanity (the small layer beneath the ±5v changes)
-- ──────────────────────────────────────────────────────────────────────

baseShape :: Spec Unit
baseShape = describe "base polysignal shape" do
  it "parses a bare polylfo header on main bank" do
    case polysignalParse "polylfo myLFO main" of
      Left e -> fail $ "parse failed: " <> e
      Right cfg -> do
        cfg.family `shouldEqual` PFPolyLfo
        cfg.bank `shouldEqual` BankMain
        cfg.alias `shouldEqual` "myLFO"
        cfg.outputRange `shouldEqual` Nothing

  it "parses a bare polyclock header on gt1 bank (0-indexed in AST)" do
    case polysignalParse "polyclock myClk gt1" of
      Left e -> fail $ "parse failed: " <> e
      Right cfg -> do
        cfg.family `shouldEqual` PFPolyClock
        cfg.bank `shouldEqual` BankGt 0

  it "rejects polylfo on a gt bank (CV-only family)" do
    case polysignalParse "polylfo bad gt1" of
      Left _ -> pure unit
      Right r -> fail $ "expected parse failure, got: " <> show r

-- ──────────────────────────────────────────────────────────────────────
-- Helpers
-- ──────────────────────────────────────────────────────────────────────

-- | Parse cell text expected to be a polysignal block. Either returns
-- | the parsed config or a stringified parse error.
polysignalParse :: String -> Either String PolySignalConfig
polysignalParse s = case parseStatement s of
  Right (StmtDeviceConfig (PolySignalCfg cfg)) -> Right cfg
  Right _ -> Left "expected a PolySignalCfg statement"
  Left e -> Left (parseErrorMessage e)

-- | Convenience: extract just the envelope-level outputRange.
polysignalOutputRange :: String -> Either String (Maybe String)
polysignalOutputRange s = (\cfg -> cfg.outputRange) <$> polysignalParse s

-- | Look up the `range` field of the slot at index `i` and extract its
-- | token string. Returns Nothing if missing or stored as a non-token
-- | value (which shouldn't happen for `range`).
slotRangeTokenAt :: Int -> PolySignalConfig -> Maybe String
slotRangeTokenAt i cfg = do
  slot <- Array.index cfg.slots i
  v <- lookupParam "range" slot
  case v of
    PVToken s -> Just s
    _ -> Nothing

lookupParam :: String -> PolySlot -> Maybe PolyValue
lookupParam k = map snd <<< Array.find (\(Tuple n _) -> n == k)

-- | Look up the accentRate value of the slot at index `i`.
slotAccentRateAt :: Int -> PolySignalConfig -> Maybe PolyValue
slotAccentRateAt i cfg = do
  slot <- Array.index cfg.slots i
  lookupParam "accentRate" slot
