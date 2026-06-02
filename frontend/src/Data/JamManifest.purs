-- | The contract between tarot-music and Calypso.
-- |
-- | A reading produces a `JamManifest` — musical *intent* expressed as
-- | mini-notation + PureScript transforms/structure + optional virtual-module
-- | specs. tarot-music builds it from drawn cards; Calypso lowers it into a
-- | playable session (module source + voice cells) and applies it to the engine.
-- |
-- | This module is the typed shape only. The JSON codec (the actual wire form)
-- | and the card -> manifest builders live in sibling modules.
-- |
-- | See DESIGN.md for the full rationale.
module Data.JamManifest where

import Prelude

import Data.Maybe (Maybe)

-- | A complete reading, ready to hand to Calypso.
type JamManifest =
  { meta :: Meta
  , tempo :: Tempo
  , key :: Key
  , voices :: Array Voice
  , relationships :: Array Relationship
  , modules :: Array VirtualModule   -- ES-9/FH-2; schema only for now, lowering deferred
  , structure :: Maybe Structure
  }

type Meta =
  { source :: String            -- which deck, e.g. "Full Bloom"
  , drawnCards :: Array String   -- human-readable provenance, for display + cell comments
  }

type Tempo =
  { bpm :: Int
  , feel :: Maybe String         -- annotation, e.g. "heavy, transformative"
  }

type Key =
  { tonic :: String              -- note name: "c", "fs", "bb"
  , scale :: String              -- purerl-tidal scale-registry name, e.g. "phrygian"
  }

-- | A single voice/part. `pattern` + `transforms` is the structured path;
-- | `code` is a raw PureScript escape hatch that overrides them when present.
type Voice =
  { name :: String               -- "bass", "lead", "kick"
  , role :: Role
  , pattern :: String            -- mini-notation core
  , transforms :: Array String   -- PureScript combinators applied outward, e.g. ["every 4 rev", "fast 2"]
  , code :: Maybe String         -- raw PureScript cell body; overrides pattern+transforms
  , space :: PatternSpace
  , target :: Target
  , controls :: Array Control    -- live-control bus seeds
  }

type Control =
  { name :: String
  , value :: Number
  }

-- | Which musical dimension a voice occupies. Derived from the card suit
-- | (Coins->Bass, Cups->Harmony, Swords->Lead, Wands->Rhythm); Texture is spare.
data Role = Bass | Harmony | Lead | Rhythm | Texture

derive instance eqRole :: Eq Role
derive instance ordRole :: Ord Role

instance showRole :: Show Role where
  show = case _ of
    Bass -> "Bass"
    Harmony -> "Harmony"
    Lead -> "Lead"
    Rhythm -> "Rhythm"
    Texture -> "Texture"

-- | How the tokens in `pattern` are interpreted.
data PatternSpace
  = Degree     -- scale degrees, rendered through the active scale
  | Token      -- sample/instrument names ("bd sn hh")
  | Chromatic  -- raw note names / MIDI

derive instance eqPatternSpace :: Eq PatternSpace
derive instance ordPatternSpace :: Ord PatternSpace

instance showPatternSpace :: Show PatternSpace where
  show = case _ of
    Degree -> "Degree"
    Token -> "Token"
    Chromatic -> "Chromatic"

-- | Where a voice sounds. Default to an audible target (Dirt/Midi) so a
-- | skeleton plays within seconds of drawing; Gate/CV are opt-in re-routings
-- | to the modular made after the idea is already audible.
data Target
  = Dirt String              -- SuperDirt sample bank, e.g. "bd", "arpy"
  | Midi Int                 -- soft synth on a MIDI channel
  | Gate Int                 -- ES-9 gate jack
  | CV Int                   -- ES-9 CV bus, V/oct

derive instance eqTarget :: Eq Target

instance showTarget :: Show Target where
  show = case _ of
    Dirt bank -> "Dirt " <> bank
    Midi ch -> "Midi ch" <> show ch
    Gate jack -> "Gate " <> show jack
    CV bus -> "CV " <> show bus

-- | An inter-voice relationship, drawn from an Oracle suit. The marquee new
-- | layer: how two parts relate, which the rig can express concretely.
type Relationship =
  { kind :: RelKind
  , from :: String           -- voice name
  , to :: String             -- voice name
  , intensity :: Number      -- 0..1, from the oracle card's rank
  }

-- | The three Full Bloom Oracle suits as relationship dynamics.
data RelKind
  = Mutualist   -- Pollinators: both voices reinforce (shared clock, complementary euclids)
  | Parasite    -- Nectar Robbers: `from` exploits `to` (duck/re-pitch); `to` defends
  | Carrier     -- Seed Carriers: a motif is handed from `from` to `to` and develops

derive instance eqRelKind :: Eq RelKind
derive instance ordRelKind :: Ord RelKind

instance showRelKind :: Show RelKind where
  show = case _ of
    Mutualist -> "Mutualist"
    Parasite -> "Parasite"
    Carrier -> "Carrier"

-- | Overall structure: named sections plus an optional PureScript arrangement.
type Structure =
  { sections :: Array String       -- e.g. ["intro", "build", "drop"]
  , arrangement :: Maybe String     -- optional PureScript conductor/arrangement expression
  }

-- | Virtual modules mirror the es9-daemon `apply-polysignal` envelope exactly.
-- | Carried in the manifest for forward-compatibility; Calypso lowering deferred.
data VirtualModule
  = PolyLFO { alias :: String, bank :: String, outputRange :: String, slots :: Array LfoSlot }
  | PolyClock { alias :: String, bank :: String, outputRange :: String, slots :: Array ClockSlot }
  | PolyEuclid { alias :: String, bank :: String, outputRange :: String, slots :: Array EuclidSlot }
  | PolyPresetNote { alias :: String, bank :: String, slots :: Array PresetNoteSlot }

type LfoSlot =
  { rate :: Number
  , phase :: Number
  , level :: Number
  , sin :: Number
  , sqr :: Number
  , tri :: Number
  , saw :: Number
  , rnd :: Number
  , nse :: Number
  }

type ClockSlot =
  { base :: String           -- "whole" | "half" | "quarter" | "8th" | "16th" | triplet tokens
  , multiplier :: Int
  , pulseWidth :: Int         -- 0..100
  , phase :: Int              -- degrees
  }

type EuclidSlot =
  { beats :: Int
  , steps :: Int
  , rate :: Int               -- subdivisions per beat
  }

type PresetNoteSlot =
  { note :: Int               -- MIDI note number
  }
