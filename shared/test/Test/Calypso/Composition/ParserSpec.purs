module Test.Calypso.Composition.ParserSpec (parserSpec) where

import Prelude

import Calypso.Composition
  ( Bank(..)
  , DeviceConfig(..)
  , PolyFamily(..)
  , PolySignalConfig
  , PolySlot
  , PolyValue(..)
  , Statement(..)
  )
import Calypso.Composition.Parser (parseStatement, prettyPolySignal)
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
