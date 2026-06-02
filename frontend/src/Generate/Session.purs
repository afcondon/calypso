-- | The combinatorial generator: a Draw -> a Calypso.Generated.Session module
-- | string, ready to POST to /session-source (build+load) and play via
-- | `play-piece piece`.
-- |
-- | NOT 1:1. The whole draw feeds a shared pool of musical *dimensions*
-- | (`dimensionsFromDraw`); the voices are then *phenotyped* from that vector —
-- | no card owns a voice. `generateParts` exposes the phenotyped voices as
-- | structured data so the UI can render them as cards (the "second tray");
-- | `generateModule` serialises them to a Calypso session module.
module Generate.Session
  ( Dimensions
  , GenPart
  , dimensionsFromDraw
  , generateParts
  , generateModule
  ) where

import Prelude

import Data.Array (mapWithIndex, range, (!!))
import Data.Array as Array
import Data.Cards (rankToInt)
import Data.Foldable (sum)
import Data.FullBloom (Card(..))
import Data.Maybe (fromMaybe, maybe)
import Data.String.Common (joinWith)
import Manifest.Build (Draw, euclidPlace, tempoFromMajor)

-- | The musical DNA the whole draw expresses.
type Dimensions =
  { scaleVal :: String
  , bpm :: Int
  , voiceCount :: Int
  , density :: Int
  , entropy :: Int
  , sync :: Int
  , drawn :: Array String
  }

-- | One phenotyped voice — structured so the UI can render it as a card.
type GenPart =
  { name :: String         -- "part0"
  , voiceToken :: String   -- "vBass" (the typed VoiceName for the module decl)
  , instrument :: String   -- "bass1"
  , channel :: Int         -- 1
  , expr :: String         -- the eDSL expression body
  }

scaleValueFor :: Int -> String
scaleValueFor = case _ of
  0 -> "cMajor"
  1 -> "cMajor"
  2 -> "cHarmonicMinor"
  3 -> "cMajor"
  4 -> "cMajor"
  5 -> "cDorian"
  6 -> "cMajor"
  7 -> "cMixolydian"
  8 -> "cMajorPentatonic"
  9 -> "cAeolian"
  10 -> "cPhrygianDominant"
  11 -> "cLydian"
  12 -> "cMelodicMinor"
  13 -> "cPhrygian"
  14 -> "cMajor"
  15 -> "cLocrian"
  16 -> "cLocrian"
  17 -> "cLydian"
  18 -> "cHarmonicMinor"
  19 -> "cMajor"
  20 -> "cMixolydian"
  21 -> "cMajor"
  _ -> "cMinor"

chaoticArcana :: Int -> Boolean
chaoticArcana n = n == 10 || n == 15 || n == 16 || n == 18

-- | Combinatorial aggregation — every drawn card touches several dimensions.
dimensionsFromDraw :: Draw -> Dimensions
dimensionsFromDraw draw =
  let
    majNum = maybe 7 _.num draw.major
    ranks = map (\m -> rankToInt m.rank) draw.minors
    rankSum = sum ranks
    oracleSum = sum (map _.rank draw.oracles)
    total = majNum + rankSum + oracleSum

    voiceCount = clamp 1 4 (if Array.length draw.minors == 0 then 1 else Array.length draw.minors)
    -- Density spans the full 1..8 across draws (not pinned to the rank avg).
    density = clamp 1 8 (1 + (rankSum + oracleSum) `mod` 8)
    chaosBonus = if chaoticArcana majNum then 2 else 0
    entropy = clamp 0 3 (chaosBonus + (oracleSum + Array.length draw.oracles) / 2)
    sync = total `mod` 8
  in
    { scaleVal: scaleValueFor majNum
    , bpm: (tempoFromMajor majNum).bpm
    , voiceCount
    , density
    , entropy
    , sync
    , drawn: drawLabels draw
    }

voiceNames :: Array String
voiceNames = [ "vBass", "vFugue", "vUpper", "vHeld1" ]

instruments :: Array String
instruments = [ "bass1", "bass2", "bass3", "bass4" ]

-- | Per-voice degree pools, spread across octaves (higher degree = higher
-- | register) so the voices occupy distinct registers.
degreePools :: Array (Array String)
degreePools =
  [ [ "1", "5", "1", "-2" ]      -- bass: low roots/fifths
  , [ "8", "5", "10", "8" ]      -- mid
  , [ "12", "10", "15", "12" ]   -- upper
  , [ "8", "9", "10", "11", "12" ] -- melodic, high
  ]

wrapperPool :: Array String
wrapperPool = [ "rev", "every 3 rev", "every 4 rev", "slow (r 2)", "fast (r 2)" ]

wrappersFor :: Dimensions -> Int -> Array String
wrappersFor d i =
  if d.entropy <= 0 then []
  else map (\k -> fromMaybe "rev" (wrapperPool !! ((i + k) `mod` Array.length wrapperPool)))
    (range 0 (d.entropy - 1))

applyWrappers :: Array String -> String -> String
applyWrappers ws body = Array.foldr (\w acc -> w <> " (" <> acc <> ")") body ws

mkGenPart :: Dimensions -> Int -> GenPart
mkGenPart d i =
  let
    vn = fromMaybe "vBass" (voiceNames !! i)
    inst = fromMaybe "bass1" (instruments !! i)
    pool = fromMaybe [ "1", "5" ] (degreePools !! i)
    hits = clamp 1 8 (d.density - i)
    pat = euclidPlace hits 8 pool
    body = "inKey " <> d.scaleVal <> " (degree \"" <> pat <> "\")"
    expr = applyWrappers (wrappersFor d i) body
  in
    { name: "part" <> show i, voiceToken: vn, instrument: inst, channel: i + 1, expr }

-- | The phenotyped voices for a draw (the "second tray").
generateParts :: Draw -> Array GenPart
generateParts draw =
  let d = dimensionsFromDraw draw
  in mapWithIndex (\i _ -> mkGenPart d i) (range 1 d.voiceCount)

partDecl :: GenPart -> String
partDecl gp =
  gp.name <> " :: PitchedPart PitchedNote12\n"
    <> gp.name <> " = on " <> gp.voiceToken <> " " <> gp.instrument <> " (" <> gp.expr <> ")\n"

-- | Serialise a draw to a Calypso.Generated.Session module.
generateModule :: Draw -> String
generateModule draw =
  let
    d = dimensionsFromDraw draw
    parts = generateParts draw
    partDecls = joinWith "\n" (map partDecl parts)
    armList = joinWith ", " (map (\p -> "armPart " <> p.name) parts)
    partList = joinWith ", " (map _.name parts)
    provenance = "-- tarot draw: " <> joinWith " | " d.drawn <> "\n"
      <> "-- dims: scale=" <> d.scaleVal <> " bpm=" <> show d.bpm
      <> " voices=" <> show d.voiceCount <> " density=" <> show d.density
      <> " entropy=" <> show d.entropy <> "\n"
  in
    "module Calypso.Generated.Session where\n\n"
      <> "import Calypso.Prelude\n"
      <> "import Studio (iac, bass1, bass2, bass3, bass4)\n\n"
      <> provenance <> "\n"
      <> partDecls <> "\n"
      <> "piece :: Section\n"
      <> "piece = stack [ " <> armList <> " ]\n\n"
      <> "session :: Session\n"
      <> "session = Session\n"
      <> "  { devices:     [iac]\n"
      <> "  , instruments: [bass1, bass2, bass3, bass4]\n"
      <> "  , drumKits:    []\n"
      <> "  , parts:       eraseAll [ " <> partList <> " ]\n"
      <> "  }\n"

drawLabels :: Draw -> Array String
drawLabels draw =
  maybe [] (\m -> [ show (Major m.num m.name) ]) draw.major
    <> map (\m -> show (Minor m.suit m.rank)) draw.minors
    <> map (\o -> show (Oracle o.suit o.rank)) draw.oracles
