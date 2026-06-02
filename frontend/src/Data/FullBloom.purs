-- | The BOTANICA: Full Bloom deck (Kevin Jay Stanton / Beehive Books) as data.
-- |
-- | 111 cards: 22 Major Arcana + 56 Minor (suits Cups/Swords/Wands/**Coins** —
-- | Coins, not Pentacles) + 33 Oracle cards in 3 suits of 11 (Pollinators,
-- | Nectar Robbers, Seed Carriers). We do not model the divinatory meanings —
-- | the musical mappings are our own (see Manifest.Build).
-- |
-- | `Rank` is reused from Data.Cards (Ace..King); only the suit set differs
-- | (Coins). Oracle suits have 11 cards each, indexed 1..11, so they carry a
-- | plain Int rank rather than the 14-rank court structure.
module Data.FullBloom where

import Prelude

import Data.Cards (Rank)

-- | The four classical (elemental) suits of the Minor Arcana.
data Suit = Cups | Swords | Wands | Coins

derive instance eqSuit :: Eq Suit
derive instance ordSuit :: Ord Suit

instance showSuit :: Show Suit where
  show = case _ of
    Cups -> "Cups"
    Swords -> "Swords"
    Wands -> "Wands"
    Coins -> "Coins"

-- | The three Full Bloom Oracle suits — each a kind of plant/animal
-- | relationship, which we read as a relationship between musical parts.
data OracleSuit
  = Pollinators    -- symbiosis: all parties benefit
  | NectarRobbers  -- one party exploits the other; the other defends
  | SeedCarriers   -- growth & transference: two parties grow alongside

derive instance eqOracleSuit :: Eq OracleSuit
derive instance ordOracleSuit :: Ord OracleSuit

instance showOracleSuit :: Show OracleSuit where
  show = case _ of
    Pollinators -> "Pollinators"
    NectarRobbers -> "Nectar Robbers"
    SeedCarriers -> "Seed Carriers"

-- | A drawn card.
data Card
  = Major Int String       -- arcana number 0..21, card/plant name
  | Minor Suit Rank
  | Oracle OracleSuit Int   -- oracle rank 1..11

derive instance eqCard :: Eq Card

-- | Human-readable label, used for provenance and cell comments.
label :: Card -> String
label = case _ of
  Major n name -> show n <> " " <> name
  Minor suit rank -> show rank <> " of " <> show suit
  Oracle suit n -> show suit <> " " <> show n

instance showCard :: Show Card where
  show = label
