-- | Round-trip property tests for the canonical serializer:
-- |
-- |   parseComposition (serializeComposition ast) ≡ Right ast
-- |
-- | We don't have generators wired up for AST values, so the tests
-- | hand-construct a representative `Composition` value per statement
-- | kind, serialise it, re-parse, and check Eq against the original.
-- | This is the moral equivalent of a property test for the cases we
-- | actually emit on the write-back path.
module Test.Calypso.Composition.SerializerSpec (serializerSpec) where

import Prelude

import Calypso.Composition
  ( Bank(..)
  , Binding(..)
  , Composition(..)
  , CvMode(..)
  , Device(..)
  , DeviceConfig(..)
  , Fh2VoiceMode(..)
  , OutRef(..)
  , PolyFamily(..)
  , PolyValue(..)
  , Statement(..)
  )
import Calypso.Composition.Parser (parseComposition)
import Calypso.Composition.Serializer (serializeComposition, serializeStatement)
import Control.Monad.Error.Class (class MonadThrow)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect.Aff (Error)
import Parsing (parseErrorMessage)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

serializerSpec :: Spec Unit
serializerSpec = describe "Calypso.Composition.Serializer" do
  describe "round-trip per statement kind" do
    it "bpm" do
      roundTrip (Composition [StmtBpm 124.0])

    it "bpm fractional" do
      roundTrip (Composition [StmtBpm 123.5])

    it "link sync on/off" do
      roundTrip (Composition [StmtLinkSync true])
      roundTrip (Composition [StmtLinkSync false])

    it "control" do
      roundTrip (Composition [StmtControl { name: "bass-amp", value: 0.85 }])

    it "tag" do
      roundTrip (Composition [StmtTag { name: "fill", defaultValue: "off" }])

    it "cue single-line inline form" do
      roundTrip (Composition [StmtCue
        { id: "d1"
        , mvoice: Just "drums"
        , tvoice: Just "qd1"
        , whenTag: Nothing
        , body: "mini \"x ~ x ~\""
        }])

    it "cue with when=tag gate" do
      roundTrip (Composition [StmtCue
        { id: "d-fill"
        , mvoice: Just "drums"
        , tvoice: Just "qd2"
        , whenTag: Just "fill"
        , body: "mini \"x x x x\""
        }])

    it "cue multi-line indented body" do
      roundTrip (Composition [StmtCue
        { id: "p1"
        , mvoice: Just "poly"
        , tvoice: Just "banks"
        , whenTag: Nothing
        , body: "polylfo banks main <>\n  ratios [1, 2, 4, 8]\n  shapes [tri, tri, tri, tri]"
        }])

    it "midi device with latency" do
      roundTrip (Composition [StmtDevice (DevMidi
        { alias: "fh2", port: "FH-2", latency: Just 69.0 })])

    it "es9 device without latency" do
      roundTrip (Composition [StmtDevice (DevEs9
        { alias: "es9", port: "ES-9", latency: Nothing })])

    it "expander device" do
      roundTrip (Composition [StmtDevice (DevEs5
        { alias: "es5", parent: "es9" })])

    it "osc device" do
      roundTrip (Composition [StmtDevice (DevOsc
        { alias: "router", host: "127.0.0.1", port: 57120 })])

    it "midi-note binding with lat" do
      roundTrip (Composition [StmtBinding (BindMidiNote
        { name: "qd1", device: "fh2-qd", channel: 14, note: 60
        , velocity: 100, durationMs: 50, latency: Just 30.0 })])

    it "gate binding" do
      roundTrip (Composition [StmtBinding (BindGate
        { name: "cip-gate", device: "fh2", channel: 0, latency: Nothing })])

    it "cv voct binding" do
      roundTrip (Composition [StmtBinding (BindCv
        { name: "cip-pitch", device: "es9", busOrSlot: 0
        , mode: CvVoct, latency: Nothing })])

    it "cv-cont binding" do
      roundTrip (Composition [StmtBinding (BindCvCont
        { name: "cip-damp", device: "es9", busOrSlot: 1
        , mode: CvLiteral, latency: Nothing })])

    it "midi-cc binding" do
      roundTrip (Composition [StmtBinding (BindMidiCc
        { name: "mod", device: "live", channel: 1, cc: 17, latency: Nothing })])

    it "fh2-config voice statement" do
      roundTrip (Composition [StmtDeviceConfig (Fh2VoiceCfg
        { device: "fh2", mode: Fh2Gate, voice: 0, out: OutLocal 1, channel: 14 })])

    it "fh2-mode statement" do
      roundTrip (Composition [StmtDeviceConfig (Fh2ModeCfg
        { device: "fh2", modeName: "ochd" })])

    it "polysignal block via prettyPolySignal" do
      let cfg =
            { alias: "banks"
            , family: PFPolyLfo
            , bank: BankMain
            , outputRange: Nothing
            , slots:
                [ [Tuple "ratio" (PVNumber 1.0), Tuple "shape" (PVToken "tri")]
                , [Tuple "ratio" (PVNumber 2.0), Tuple "shape" (PVToken "tri")]
                , [Tuple "ratio" (PVNumber 4.0), Tuple "shape" (PVToken "sin")]
                , [Tuple "ratio" (PVNumber 8.0), Tuple "shape" (PVToken "sin")]
                , [Tuple "ratio" (PVNumber 1.3), Tuple "shape" (PVToken "saw")]
                , [Tuple "ratio" (PVNumber 2.6), Tuple "shape" (PVToken "saw")]
                , [Tuple "ratio" (PVNumber 5.2), Tuple "shape" (PVToken "sqr")]
                , [Tuple "ratio" (PVNumber 10.4), Tuple "shape" (PVToken "sqr")]
                ]
            }
      roundTrip (Composition [StmtDeviceConfig (PolySignalCfg cfg)])

  describe "round-trip composite" do
    it "round-trips a small .tiderl-shaped file" do
      let ast = Composition
            [ StmtBpm 124.0
            , StmtLinkSync true
            , StmtDevice (DevMidi
                { alias: "fh2", port: "FH-2", latency: Nothing })
            , StmtDevice (DevMidi
                { alias: "fh2-qd", port: "FH-2", latency: Just 69.0 })
            , StmtDevice (DevEs9
                { alias: "es9", port: "ES-9", latency: Nothing })
            , StmtBinding (BindMidiNote
                { name: "qd1", device: "fh2-qd", channel: 14, note: 60
                , velocity: 100, durationMs: 50, latency: Nothing })
            , StmtBinding (BindGate
                { name: "cip-gate", device: "fh2", channel: 0, latency: Nothing })
            , StmtControl { name: "bass-amp", value: 0.85 }
            , StmtTag { name: "fill", defaultValue: "off" }
            , StmtCue
                { id: "d1", mvoice: Just "drums", tvoice: Just "qd1"
                , whenTag: Nothing, body: "mini \"x ~ x ~\""
                }
            , StmtCue
                { id: "b1", mvoice: Just "bass", tvoice: Just "cip-pitch"
                , whenTag: Nothing
                , body: "every 4 rev (mini \"c2 e2 g2 ~ b2 ~ g2 e2\")"
                }
            ]
      roundTrip ast

  describe "canonical-form sanity checks" do
    it "bpm renders as a bare integer for whole numbers" do
      serializeStatement (StmtBpm 124.0) `shouldEqual` "bpm 124"

    it "bpm renders as decimal for fractional numbers" do
      serializeStatement (StmtBpm 123.5) `shouldEqual` "bpm 123.5"

    it "control renders with `=` and a space on each side" do
      serializeStatement (StmtControl { name: "x", value: 0.5 })
        `shouldEqual` "control x = 0.5"

    it "cue single-line uses inline `=` form" do
      serializeStatement (StmtCue
        { id: "d1", mvoice: Just "drums", tvoice: Just "qd1"
        , whenTag: Nothing, body: "mini \"x ~\""
        })
        `shouldEqual` "cue d1 [mvoice=drums tvoice=qd1] = mini \"x ~\""

    it "cue multi-line uses indented continuation" do
      serializeStatement (StmtCue
        { id: "p1", mvoice: Nothing, tvoice: Nothing
        , whenTag: Nothing, body: "line one\nline two"
        })
        `shouldEqual` "cue p1\n  line one\n  line two"

-- | Serialize, re-parse, assert AST equality.
-- |
-- | `Composition` doesn't derive `Show`, so we can't use `shouldEqual`
-- | directly. Compare via `Eq` and fail with the serialized form as
-- | context — that's the most actionable diagnostic anyway, since the
-- | divergence will show up in the round-tripped text.
roundTrip :: forall m. MonadThrow Error m => Composition -> m Unit
roundTrip ast =
  let serialized = serializeComposition ast
  in case parseComposition serialized of
    Left e -> fail $ "re-parse failed: " <> parseErrorMessage e
              <> "\n\nserialized:\n" <> serialized
    Right ast' ->
      if ast' == ast
        then pure unit
        else fail $ "round-trip mismatch.\n\nserialized:\n" <> serialized
                <> "\n\nre-serialized:\n" <> serializeComposition ast'
