-- | Card -> JamManifest builders.
-- |
-- | These recast the keepable parts of the original `Data.Decisions` mappings
-- | (Major Arcana -> scale; rank -> magnitude; suit -> role; Oracle suit ->
-- | relationship) as **per-slot** pure functions, so the freeze-&-re-roll loop
-- | can regenerate one slot of a reading in isolation. The arbitrary
-- | modular-arithmetic hashing of the original is dropped.
-- |
-- | A `scale` value here is a bare mode name from purerl-tidal's registry
-- | vocabulary (e.g. "phrygian", "harmonic-minor"); Calypso composes
-- | `tonic-mode` (e.g. "e-phrygian") when lowering, constructing the scale if
-- | that exact root/mode combo isn't pre-registered.
module Manifest.Build
  ( suitToRole
  , roleName
  , defaultTarget
  , keyFromMajor
  , majorMode
  , majorTonic
  , tempoFromMajor
  , pitchClassToken
  , activity
  , euclidBits
  , euclidPlace
  , voiceFromMinor
  , relKindFromOracle
  , relationshipFromOracle
  , Draw
  , assemble
  ) where

import Prelude

import Data.Array as Array
import Data.Cards (Rank, rankToInt)
import Data.FullBloom (Card(..), OracleSuit(..), Suit(..), label)
import Data.Int (toNumber)
import Data.JamManifest (JamManifest, Key, RelKind(..), Relationship, Role(..), Target(..), Tempo, Voice, PatternSpace(..))
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String.Common (joinWith)

-------------------------------------------------------------------------------
-- Suit -> musical role (the four suits are already elemental)
-------------------------------------------------------------------------------

-- | Coins=earth=foundation, Cups=water=harmony, Swords=air=lead, Wands=fire=drive.
suitToRole :: Suit -> Role
suitToRole = case _ of
  Coins -> Bass
  Cups -> Harmony
  Swords -> Lead
  Wands -> Rhythm

roleName :: Role -> String
roleName = case _ of
  Bass -> "bass"
  Harmony -> "harmony"
  Lead -> "lead"
  Rhythm -> "rhythm"
  Texture -> "texture"

-- | Default audible target so a skeleton sounds within seconds: percussion to
-- | SuperDirt samples, pitched parts to soft-synth MIDI channels. Re-routing a
-- | voice to ES-9 Gate/CV is an opt-in move made after the idea is playing.
defaultTarget :: Role -> Target
defaultTarget = case _ of
  Rhythm -> Dirt "drum"
  Bass -> Midi 1
  Harmony -> Midi 2
  Lead -> Midi 3
  Texture -> Dirt "arpy"

-------------------------------------------------------------------------------
-- Major Arcana -> key + tempo (the semantic part of the original, kept)
-------------------------------------------------------------------------------

-- | Card energy -> scale mode. All names are bare modes present in
-- | purerl-tidal's scale registry vocabulary. Mirrors the spirit of the
-- | original `majorArcanaToScale` table.
majorMode :: Int -> String
majorMode = case _ of
  0 -> "major"             -- Fool — open
  1 -> "major"             -- Magician — confident
  2 -> "harmonic-minor"    -- High Priestess — mysterious
  3 -> "major"             -- Empress — nurturing
  4 -> "major"             -- Emperor — authoritative
  5 -> "dorian"            -- Hierophant — church modes
  6 -> "major"             -- Lovers — romantic
  7 -> "mixolydian"        -- Chariot — driving
  8 -> "major-pentatonic"  -- Strength — simple, powerful
  9 -> "aeolian"           -- Hermit — introspective
  10 -> "phrygian-dominant" -- Wheel of Fortune — exotic, turning
  11 -> "lydian"           -- Justice — bright, clear
  12 -> "melodic-minor"    -- Hanged Man — suspended
  13 -> "phrygian"         -- Death — dark
  14 -> "major"            -- Temperance — balanced
  15 -> "locrian"          -- Devil — diminished feel
  16 -> "locrian"          -- Tower — chaotic, unstable
  17 -> "lydian"           -- Star — hopeful, bright
  18 -> "harmonic-minor"   -- Moon — nocturnal
  19 -> "major"            -- Sun — joyful
  20 -> "mixolydian"       -- Judgement — resolution
  21 -> "major"            -- World — complete
  _ -> "major"

-- | Card number -> tonic (pitch class, mod 12).
majorTonic :: Int -> String
majorTonic num = pitchClassToken (num `mod` 12)

keyFromMajor :: Int -> Key
keyFromMajor num = { tonic: majorTonic num, scale: majorMode num }

-- | Card -> a representative BPM + feel annotation (midpoints of the original
-- | `majorArcanaToTempo` ranges).
tempoFromMajor :: Int -> Tempo
tempoFromMajor = case _ of
  0 -> { bpm: 110, feel: Just "free, follow intuition" }
  1 -> { bpm: 120, feel: Just "confident, medium energy" }
  2 -> { bpm: 65, feel: Just "slow, mysterious, spacious" }
  3 -> { bpm: 95, feel: Just "flowing, nurturing" }
  4 -> { bpm: 105, feel: Just "steady, authoritative march" }
  5 -> { bpm: 72, feel: Just "ceremonial, processional" }
  6 -> { bpm: 90, feel: Just "romantic, sensual" }
  7 -> { bpm: 135, feel: Just "driving, triumphant" }
  8 -> { bpm: 100, feel: Just "powerful, steady groove" }
  9 -> { bpm: 60, feel: Just "contemplative, sparse" }
  10 -> { bpm: 125, feel: Just "cyclical, building/falling" }
  11 -> { bpm: 108, feel: Just "measured, balanced" }
  12 -> { bpm: 55, feel: Just "suspended, floating" }
  13 -> { bpm: 85, feel: Just "heavy, transformative" }
  14 -> { bpm: 100, feel: Just "balanced, flowing" }
  15 -> { bpm: 115, feel: Just "dark, seductive groove" }
  16 -> { bpm: 150, feel: Just "chaotic, explosive" }
  17 -> { bpm: 80, feel: Just "hopeful, ethereal" }
  18 -> { bpm: 70, feel: Just "dreamy, nocturnal" }
  19 -> { bpm: 128, feel: Just "bright, energetic, joyful" }
  20 -> { bpm: 120, feel: Just "revelatory, building" }
  21 -> { bpm: 120, feel: Just "triumphant, complete" }
  _ -> { bpm: 100, feel: Nothing }

pitchClassToken :: Int -> String
pitchClassToken pc = case pc `mod` 12 of
  0 -> "c"
  1 -> "cs"
  2 -> "d"
  3 -> "ds"
  4 -> "e"
  5 -> "f"
  6 -> "fs"
  7 -> "g"
  8 -> "gs"
  9 -> "a"
  10 -> "as"
  _ -> "b"

-------------------------------------------------------------------------------
-- Minor Arcana -> a voice (suit = role, rank = density)
-------------------------------------------------------------------------------

-- | Rank -> activity: number of hits across an 8-step bar (1..8). Pips scale
-- | directly; court cards (Page..King) saturate at busy.
activity :: Rank -> Int
activity rank = clamp 1 8 (rankToInt rank)

-- | Euclidean (Bresenham) hit distribution — the same formula es9-daemon's
-- | polyeuclid uses, for consistency across the rig.
euclidBits :: Int -> Int -> Array Boolean
euclidBits beats steps =
  let s = max 1 steps
      b = clamp 0 s beats
  in map (\i -> (i * b) `mod` s < b) (Array.range 0 (s - 1))

-- | Place `values` (cycled) at the active euclidean steps, "~" elsewhere,
-- | producing a mini-notation sequence.
euclidPlace :: Int -> Int -> Array String -> String
euclidPlace beats steps values =
  let bits = euclidBits beats steps
      vlen = max 1 (Array.length values)
      step acc active =
        if active
          then acc { out = Array.snoc acc.out (fromMaybe "~" (Array.index values (acc.n `mod` vlen)))
                   , n = acc.n + 1 }
          else acc { out = Array.snoc acc.out "~" }
      result = Array.foldl step { out: [], n: 0 } bits
  in joinWith " " result.out

voiceFromMinor :: Suit -> Rank -> Voice
voiceFromMinor suit rank =
  let role = suitToRole suit
      act = activity rank
  in
    { name: roleName role
    , role
    , pattern: patternFor role act
    , transforms: []
    , code: Nothing
    , space: spaceFor role
    , target: defaultTarget role
    , controls: []
    }

-- | Rhythm/Bass use the euclid operator directly (compact); Lead/Harmony place
-- | melodic/chordal degrees at euclidean positions.
patternFor :: Role -> Int -> String
patternFor role act = case role of
  Rhythm -> "bd(" <> show (max 1 act) <> ",8)"
  Bass -> "0(" <> show (max 1 act) <> ",8)"
  Lead -> euclidPlace act 8 [ "0", "2", "4", "2", "5" ]
  Harmony -> euclidPlace (max 1 (act / 2)) 8 [ "[0, 2, 4]" ]
  Texture -> euclidPlace (max 1 (act / 2)) 8 [ "0", "4" ]

spaceFor :: Role -> PatternSpace
spaceFor = case _ of
  Rhythm -> Token
  _ -> Degree

-------------------------------------------------------------------------------
-- Oracle -> an inter-voice relationship
-------------------------------------------------------------------------------

relKindFromOracle :: OracleSuit -> RelKind
relKindFromOracle = case _ of
  Pollinators -> Mutualist
  NectarRobbers -> Parasite
  SeedCarriers -> Carrier

-- | `from`/`to` are voice names; intensity comes from the oracle rank (1..11).
relationshipFromOracle :: OracleSuit -> Int -> String -> String -> Relationship
relationshipFromOracle suit rank from to =
  { kind: relKindFromOracle suit
  , from
  , to
  , intensity: toNumber (clamp 1 11 rank) / 11.0
  }

-------------------------------------------------------------------------------
-- Assembly
-------------------------------------------------------------------------------

-- | A reading's draw: an optional Major (sets key + tempo), some Minors (the
-- | voices), and some Oracles (relationships wired across consecutive voices).
type Draw =
  { major :: Maybe { num :: Int, name :: String }
  , minors :: Array { suit :: Suit, rank :: Rank }
  , oracles :: Array { suit :: OracleSuit, rank :: Int }
  }

assemble :: String -> Draw -> JamManifest
assemble source draw =
  let
    voices = map (\m -> voiceFromMinor m.suit m.rank) draw.minors
    names = map _.name voices
    nv = Array.length names
    -- wire oracle i between voice i and voice (i+1), cyclically
    relationships =
      if nv < 2 then []
      else Array.mapWithIndex
        ( \i o ->
            let from = fromMaybe "" (Array.index names (i `mod` nv))
                to = fromMaybe "" (Array.index names ((i + 1) `mod` nv))
            in relationshipFromOracle o.suit o.rank from to
        )
        draw.oracles
  in
    { meta:
        { source
        , drawnCards: drawLabels draw
        }
    , tempo: maybe defaultTempo (\m -> tempoFromMajor m.num) draw.major
    , key: maybe defaultKey (\m -> keyFromMajor m.num) draw.major
    , voices
    , relationships
    , modules: []
    , structure: Nothing
    }

defaultKey :: Key
defaultKey = { tonic: "c", scale: "minor" }

defaultTempo :: Tempo
defaultTempo = { bpm: 120, feel: Nothing }

drawLabels :: Draw -> Array String
drawLabels draw =
  maybe [] (\m -> [ label (Major m.num m.name) ]) draw.major
    <> map (\m -> label (Minor m.suit m.rank)) draw.minors
    <> map (\o -> label (Oracle o.suit o.rank)) draw.oracles
