-- | Lowering: a `JamManifest` (from the Arcana generator) -> a
-- | `Calypso.Generated.Session` PureScript module string, ready to POST to
-- | /session-source (build + hot-load) and play via `play-piece piece`.
-- |
-- | This lives on the *Calypso* side of the boundary: Arcana owns cards ->
-- | manifest and knows nothing of Calypso's composition grammar; Calypso owns
-- | the lowering, device bindings and cell shape. Mirrors the proven idiom in
-- | Sessions/Fugue and the legacy Generate.Session.generateModule.
-- |
-- | Stage-1 limitations (honest): only **pitched (Midi) voices** become parts —
-- | they map to the iac soft-synth instruments bass1..bass4 by MIDI channel.
-- | Percussion (Dirt) voices are skipped (they need a drum kit / SuperDirt path
-- | that isn't wired yet), so dub techno plays its harmonic core without the
-- | kick, while Pärt — being all pitched — plays in full. The key is snapped to
-- | a c-rooted scale because the engine's scale registry only reliably carries
-- | c-rooted root/mode combos.
module Calypso.Frontend.Tarot.Lower (manifestToModule) where

import Prelude

import Data.Array (filter, mapWithIndex, (!!))
import Data.Array as Array
import Data.JamManifest (JamManifest, PatternSpace(..), Target(..), Voice)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String.Common (joinWith)

-- | JamManifest mode name -> c-rooted Tidal.Scales identifier.
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
  "melodic-minor" -> "cMelodicMinor"
  "phrygian-dominant" -> "cPhrygianDominant"
  "major-pentatonic" -> "cMajorPentatonic"
  _ -> "cAeolian"

-- | Per-part supervision names from Tidal.Voices (cycled if >4 parts).
voiceNames :: Array String
voiceNames = [ "vBass", "vFugue", "vUpper", "vHeld1" ]

instrumentForChannel :: Int -> String
instrumentForChannel ch = "bass" <> show (clamp 1 4 ch)

isPitched :: Voice -> Boolean
isPitched v = case v.target of
  Midi _ -> true
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

exprFor :: String -> Voice -> String
exprFor cScale v = case v.code of
  Just c -> c
  Nothing -> applyTransforms v.transforms (innerExpr cScale v)

manifestToModule :: JamManifest -> String
manifestToModule m =
  let
    cScale = scaleIdent m.key.scale
    pitched = filter isPitched m.voices
    partName i = "part" <> show i
    decl i v =
      let
        vn = fromMaybe "vBass" (voiceNames !! (i `mod` 4))
        inst = instrumentForChannel (channelOf v)
      in
        partName i <> " :: PitchedPart PitchedNote12\n"
          <> partName i <> " = on " <> vn <> " " <> inst <> " (" <> exprFor cScale v <> ")\n"
    decls = joinWith "\n" (mapWithIndex decl pitched)
    arms = joinWith ", " (mapWithIndex (\i _ -> "armPart " <> partName i) pitched)
    parts = joinWith ", " (mapWithIndex (\i _ -> partName i) pitched)
    prov = "-- " <> m.meta.source <> "\n-- " <> joinWith " | " m.meta.drawnCards <> "\n"
  in
    "module Calypso.Generated.Session where\n\n"
      <> "import Calypso.Prelude\n"
      <> "import Studio (iac, bass1, bass2, bass3, bass4)\n\n"
      <> prov
      <> "\n"
      <> decls
      <> "\n"
      <> "piece :: Section\n"
      <> "piece = stack [ " <> arms <> " ]\n\n"
      <> "session :: Session\n"
      <> "session = Session\n"
      <> "  { devices:     [iac]\n"
      <> "  , instruments: [bass1, bass2, bass3, bass4]\n"
      <> "  , drumKits:    []\n"
      <> "  , parts:       eraseAll [ " <> parts <> " ]\n"
      <> "  }\n"
