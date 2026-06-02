module Data.Cards where

import Prelude

import Data.Array (filter, uncons, any)
import Data.Maybe (Maybe(..))
import Data.String as String

-- | Which deck a card belongs to
data Deck = Botanica | Supra | Pagan
derive instance eqDeck :: Eq Deck
derive instance ordDeck :: Ord Deck

instance showDeck :: Show Deck where
  show Botanica = "Botanica"
  show Supra = "Supra (Elements)"
  show Pagan = "Pagan (Greek)"

-- | Standard suits for traditional decks
data Suit = Wands | Cups | Swords | Pentacles
derive instance eqSuit :: Eq Suit
derive instance ordSuit :: Ord Suit

instance showSuit :: Show Suit where
  show Wands = "Wands"
  show Cups = "Cups"
  show Swords = "Swords"
  show Pentacles = "Pentacles"

-- | Rank for numbered/court cards
data Rank
  = Ace | Two | Three | Four | Five | Six | Seven
  | Eight | Nine | Ten | Page | Knight | Queen | King
derive instance eqRank :: Eq Rank
derive instance ordRank :: Ord Rank

instance showRank :: Show Rank where
  show Ace = "Ace"
  show Two = "II"
  show Three = "III"
  show Four = "IV"
  show Five = "V"
  show Six = "VI"
  show Seven = "VII"
  show Eight = "VIII"
  show Nine = "IX"
  show Ten = "X"
  show Page = "Page"
  show Knight = "Knight"
  show Queen = "Queen"
  show King = "King"

rankToInt :: Rank -> Int
rankToInt = case _ of
  Ace -> 1
  Two -> 2
  Three -> 3
  Four -> 4
  Five -> 5
  Six -> 6
  Seven -> 7
  Eight -> 8
  Nine -> 9
  Ten -> 10
  Page -> 11
  Knight -> 12
  Queen -> 13
  King -> 14

-- | Card types across all decks
data CardType
  = MajorArcana Int String           -- Number and name (0-21 for standard, plus extras)
  | MinorArcana Suit Rank            -- Standard suit cards
  | LunaCard String                  -- Pagan deck special cards
  | ElementCard Int String           -- Supra deck (atomic number, element name)
  | ElementSeries String             -- Lanthanides/Actinides grouped

derive instance eqCardType :: Eq CardType

instance showCardType :: Show CardType where
  show (MajorArcana n name) = show n <> " - " <> name
  show (MinorArcana suit rank) = show rank <> " of " <> show suit
  show (LunaCard name) = "Luna: " <> name
  show (ElementCard n name) = show n <> ". " <> name
  show (ElementSeries name) = name <> " Series"

-- | A card with its deck membership
type Card =
  { cardType :: CardType
  , deck :: Deck
  , searchTerms :: Array String  -- For fuzzy matching
  }

-- | Create a card with search terms
mkCard :: Deck -> CardType -> Array String -> Card
mkCard deck cardType extraTerms =
  { cardType
  , deck
  , searchTerms: [ cardTypeName cardType ] <> extraTerms
  }
  where
    cardTypeName = case _ of
      MajorArcana _ name -> name
      MinorArcana suit rank -> show rank <> " of " <> show suit
      LunaCard name -> name
      ElementCard _ name -> name
      ElementSeries name -> name

-- | Search cards by query string
searchCards :: String -> Array Card -> Array Card
searchCards query cards =
  if String.null query then cards
  else filter (matchesQuery (String.toLower query)) cards
  where
    matchesQuery q card =
      let terms = map String.toLower card.searchTerms
          name = String.toLower $ show card.cardType
      in containsAny q terms || String.contains (String.Pattern q) name

    containsAny q terms = any (\t -> String.contains (String.Pattern q) t) terms

-- | Filter cards by deck
cardsForDeck :: Deck -> Array Card -> Array Card
cardsForDeck d = filter (\c -> c.deck == d)
