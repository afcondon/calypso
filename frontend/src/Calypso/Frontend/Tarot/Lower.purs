-- | Lowering: a `JamManifest` (from the Arcana generator) -> a
-- | `Calypso.Generated.Session` PureScript module string, ready to POST to
-- | /session-source (build + hot-load) and play via `play-piece piece`.
-- |
-- | This lives on the *Calypso* side of the boundary: Arcana owns cards ->
-- | manifest and knows nothing of Calypso's composition grammar; Calypso owns
-- | the lowering, device bindings and cell shape. Mirrors the proven idiom in
-- | Sessions/Fugue and the legacy Generate.Session.generateModule.
-- |
-- | What lowers today:
-- |   * **Pitched (Midi) voices** → `PitchedPart`s on the iac soft-synth
-- |     instruments bass1..bass4 by MIDI channel.
-- |   * **Percussion (Dirt) voices** → one combined `DrumPart` on `vDrums`,
-- |     dispatched through a `midiDrumKit` on **iac channel 10** (the demo
-- |     Ableton drum channel) — GM note map (bd 36, sn 38, hh 42, …). All the
-- |     genre's drum voices are stacked into a single part so they layer on one
-- |     supervised voice and share one feel. (SuperDirt is a later, less
-- |     self-contained option; MIDI→Ableton keeps testing in one box.)
-- |   * Gate/CV (ES-9/FH-2 modular) voices are still skipped — no modular target
-- |     is wired from here yet.
-- |
-- | The key is snapped to a c-rooted scale because the engine's scale registry
-- | only reliably carries c-rooted root/mode combos.
module Calypso.Frontend.Tarot.Lower (manifestToModule) where

import Prelude

import Data.Array (filter, mapWithIndex, null, (!!))
import Data.Array as Array
import Data.Foldable (any)
import Data.Int (round)
import Data.JamManifest (JamManifest, PatternSpace(..), Target(..), Voice)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String.Common (joinWith)

-- | JamManifest mode name -> c-rooted Tidal.Scales identifier.
-- |
-- | Constrained to the scales the *engine's* `Calypso.Prelude` actually
-- | re-exports (a selective subset of `Tidal.Scales`) — emitting a name the
-- | generated module can't resolve is a compile error at /session-source time,
-- | not here. Names outside that set fall back to the nearest available scale:
-- | phrygian-dominant → `cPhrygianDomLT` (the exported variant), pentatonics →
-- | their parent diatonic, anything unknown → `cAeolian`.
scaleIdent :: String -> String
scaleIdent = case _ of
  "major" -> "cMajor"
  "aeolian" -> "cAeolian"
  "minor" -> "cAeolian"
  "dorian" -> "cDorian"
  "phrygian" -> "cPhrygian"
  "lydian" -> "cLydian"
  "mixolydian" -> "cMixolydian"
  "locrian" -> "cLocrian"
  "harmonic-minor" -> "cHarmonicMinor"
  "harmonic-major" -> "cHarmonicMajor"
  "melodic-minor" -> "cMelodicMinor"
  "phrygian-dominant" -> "cPhrygianDomLT"
  "major-pentatonic" -> "cMajor"
  "minor-pentatonic" -> "cAeolian"
  "chromatic" -> "cChromatic"
  _ -> "cAeolian"

-- | The MIDI drum kit emitted into every drumful session: iac channel 10, a
-- | General-MIDI hit table covering the tokens the genre priors use (bd/sn/hh/
-- | cp/rim) plus the common extras. Token → (note, velocity, durMs).
drumKitDecl :: String
drumKitDecl =
  "drumsKit :: DrumKit\n"
    <> "drumsKit = midiDrumKit iac 10\n"
    <> "  [ hit \"bd\" 36 100 50\n"
    <> "  , hit \"sn\" 38 100 50\n"
    <> "  , hit \"rim\" 37 90 30\n"
    <> "  , hit \"cp\" 39 100 30\n"
    <> "  , hit \"hh\" 42 80 30\n"
    <> "  , hit \"oh\" 46 80 60\n"
    <> "  , hit \"shaker\" 82 70 25\n"
    <> "  , hit \"perc\" 64 90 40\n"
    <> "  , hit \"ride\" 51 80 50\n"
    <> "  , hit \"crash\" 49 90 80\n"
    <> "  , hit \"lt\" 45 100 40\n"
    <> "  , hit \"mt\" 47 100 40\n"
    <> "  , hit \"ht\" 50 100 40\n"
    <> "  , hit \"cr\" 49 90 80\n"
    <> "  , hit \"rd\" 51 80 60\n"
    <> "  ]\n"

-- | Per-part supervision names from Tidal.Voices (cycled if >4 pitched parts).
voiceNames :: Array String
voiceNames = [ "vBass", "vFugue", "vUpper", "vHeld1" ]

instrumentForChannel :: Int -> String
instrumentForChannel ch = "bass" <> show (clamp 1 4 ch)

isPitched :: Voice -> Boolean
isPitched v = case v.target of
  Midi _ -> true
  _ -> false

isDrum :: Voice -> Boolean
isDrum v = case v.target of
  Dirt _ -> true
  _ -> false

channelOf :: Voice -> Int
channelOf v = case v.target of
  Midi ch -> ch
  _ -> 1

innerExpr :: String -> Voice -> String
innerExpr cScale v = case v.space of
  Degree -> "inKey " <> cScale <> " (degree \"" <> v.pattern <> "\")"
  _ -> "mini \"" <> v.pattern <> "\""

applyTransforms :: Array String -> String -> String
applyTransforms ts body = Array.foldr (\t acc -> t <> " (" <> acc <> ")") body ts

-- | Wrap an expression in the engine's native swing when the track has a feel
-- | (`swing > 0`) and this part opts in. The shared `swing` (depth, 0..1) and
-- | `swingN` (subdivision) come from the manifest's Tempo, so every swung part
-- | gets the *identical* `swingByR` call → one coherent feel. `swingByR num den
-- | n` delays the back-half of each 1/n slice by `num/den` slice-units; we map
-- | depth → num/96 with num = round(depth*32) (so depth/3; depth 1.0 ≈ Tidal's
-- | hard swing). The integer form means the generated module never emits
-- | `Rational` arithmetic (not in scope under `Calypso.Prelude`). Unswung parts
-- | pass through untouched — and the clock, upstream of any pattern, never swings.
swingWrap :: Number -> Int -> Boolean -> String -> String
swingWrap swing swingN doSwing body
  | doSwing && swing > 0.0 =
      let k = max 1 (round (swing * 32.0))
      in "swingByR " <> show k <> " 96 " <> show swingN <> " (" <> body <> ")"
  | otherwise = body

exprFor :: Number -> Int -> String -> Voice -> String
exprFor swing swingN cScale v =
  swingWrap swing swingN v.swung case v.code of
    Just c -> c
    Nothing -> applyTransforms v.transforms (innerExpr cScale v)

manifestToModule :: JamManifest -> String
manifestToModule m =
  let
    cScale = scaleIdent m.key.scale
    swing = m.tempo.swing
    swingN = m.tempo.swingN

    -- Pitched (Midi) voices → PitchedParts on bass1..4.
    pitched = filter isPitched m.voices
    pPartName i = "part" <> show i
    pDecl i v =
      let
        vn = fromMaybe "vBass" (voiceNames !! (i `mod` 4))
        inst = instrumentForChannel (channelOf v)
      in
        pPartName i <> " :: PitchedPart PitchedNote12\n"
          <> pPartName i <> " = on " <> vn <> " " <> inst <> " (" <> exprFor swing swingN cScale v <> ")\n"
    pDecls = mapWithIndex pDecl pitched
    pNames = mapWithIndex (\i _ -> pPartName i) pitched

    -- Dirt voices → one combined DrumPart on vDrums (layers stacked, one feel).
    drums = filter isDrum m.voices
    hasDrums = not (null drums)
    drumSwung = any _.swung drums
    drumLayer v = "toPattern (drum \"" <> v.pattern <> "\")"
    -- One physical line: the voice-cell extractor pairs `partN ::` with a single
    -- `partN = …` line, so a multi-line RHS would truncate in the editable cell.
    drumBody = "stack [ " <> joinWith ", " (map drumLayer drums) <> " ]"
    drumDecl =
      "partDrums :: DrumPart\n"
        <> "partDrums = on vDrums drumsKit (" <> swingWrap swing swingN drumSwung drumBody <> ")\n"

    -- Assemble: pitched decls, then the drum decl + kit if any drums.
    allDecls = joinWith "\n" pDecls
      <> (if hasDrums then "\n" <> drumDecl else "")
    arms = (map (\n -> "armPart " <> n) pNames)
      <> (if hasDrums then [ "armPart partDrums" ] else [])
    -- Pitched and drum parts have different types, so each kind gets its own
    -- `eraseAll`, joined by `<+>` (cf. Sessions/Fugue).
    partsBag = case null pitched, hasDrums of
      false, true -> "eraseAll [ " <> joinWith ", " pNames <> " ] <+> eraseAll [ partDrums ]"
      false, false -> "eraseAll [ " <> joinWith ", " pNames <> " ]"
      true, true -> "eraseAll [ partDrums ]"
      true, false -> "eraseAll [ ]"
    drumKitsBag = if hasDrums then "[drumsKit]" else "[]"
    kitDecl = if hasDrums then drumKitDecl <> "\n" else ""
    prov = "-- " <> m.meta.source <> "\n-- " <> joinWith " | " m.meta.drawnCards <> "\n"
  in
    "module Calypso.Generated.Session where\n\n"
      <> "import Calypso.Prelude\n"
      <> "import Studio (iac, bass1, bass2, bass3, bass4)\n\n"
      <> prov
      <> "\n"
      <> kitDecl
      <> allDecls
      <> "\n"
      <> "piece :: Section\n"
      <> "piece = stack [ " <> joinWith ", " arms <> " ]\n\n"
      <> "session :: Session\n"
      <> "session = Session\n"
      <> "  { devices:     [iac]\n"
      <> "  , instruments: [bass1, bass2, bass3, bass4]\n"
      <> "  , drumKits:    " <> drumKitsBag <> "\n"
      <> "  , parts:       " <> partsBag <> "\n"
      <> "  }\n"
