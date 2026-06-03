-- | The Tarot pane — draw a Full Bloom spread, redraw/lock cards, and hear the
-- | combinatorial generator turn it into a playing jam. Styling deferred; this
-- | is the functional surface. The draw helpers (Effect, random) live here too;
-- | Shell's handleAction calls them and fires the generated session.
module Calypso.Frontend.Panes.Tarot
  ( renderTarotColumn
  , slotKeys
  , randomFullDraw
  , redrawSlot
  , redrawUnlocked
  , genreForDraw
  , seedFromDraw
  ) where

import Prelude

import Data.Array (mapWithIndex, modifyAt, uncons, (!!))
import Data.Int (fromString)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (stripPrefix)
import Data.String.Pattern (Pattern(..))
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Random (randomInt)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import Calypso.Frontend.Shell.Types (Action(..), Slots, State)
import Data.Cards (Rank(..), rankToInt)
import Data.Foldable (sum)
import Data.FullBloom (Card(..), OracleSuit(..), Suit(..))
import Generate.Genre (Genre, summarise)
import Generate.Genres.DubTechno (dubTechno)
import Generate.Genres.Part (part)
import Generate.Genres.House (house)
import Generate.Genres.Goa (goa)
import Generate.Genres.Dembow (dembow)
import Generate.Genres.Glass (glass)
import Generate.Genres.Miles (miles)
import Generate.Genres.Webern (webern)
import Generate.Genres.DeepTechHouse (deepTechHouse)
import Generate.Genres.RawDnB (rawDnB)
import Generate.Genres.IncessantDnB (incessantDnB)
import Generate.Genres.SubzeroTechno (subzeroTechno)
import Manifest.Build (Draw)

-- ---------------------------------------------------------------------------
-- Draw model — a fixed spread: 1 Major + 4 Minors (one per suit) + 1 Oracle.
-- ---------------------------------------------------------------------------

suitsOrder :: Array Suit
suitsOrder = [ Cups, Swords, Wands, Coins ]

oracleSuitsArr :: Array OracleSuit
oracleSuitsArr = [ Pollinators, NectarRobbers, SeedCarriers ]

allRanks :: Array Rank
allRanks =
  [ Ace, Two, Three, Four, Five, Six, Seven, Eight, Nine, Ten, Page, Knight, Queen, King ]

-- | Slot keys, in spread order. Used for redraw-all and lock toggling.
slotKeys :: Array String
slotKeys = [ "major", "m0", "m1", "m2", "m3", "o0" ]

majorName :: Int -> String
majorName = case _ of
  0 -> "The Fool"
  1 -> "The Magician"
  2 -> "The High Priestess"
  3 -> "The Empress"
  4 -> "The Emperor"
  5 -> "The Hierophant"
  6 -> "The Lovers"
  7 -> "The Chariot"
  8 -> "Strength"
  9 -> "The Hermit"
  10 -> "Wheel of Fortune"
  11 -> "Justice"
  12 -> "The Hanged Man"
  13 -> "Death"
  14 -> "Temperance"
  15 -> "The Devil"
  16 -> "The Tower"
  17 -> "The Star"
  18 -> "The Moon"
  19 -> "The Sun"
  20 -> "Judgement"
  _ -> "The World"

-- ---------------------------------------------------------------------------
-- Random draw helpers (Effect) — called from Shell.handleAction.
-- ---------------------------------------------------------------------------

randomRank :: Effect Rank
randomRank = do
  i <- randomInt 0 13
  pure (fromMaybe Ace (allRanks !! i))

randomMajorRec :: Effect { num :: Int, name :: String }
randomMajorRec = do
  n <- randomInt 0 21
  pure { num: n, name: majorName n }

randomOracleRec :: Effect { suit :: OracleSuit, rank :: Int }
randomOracleRec = do
  oi <- randomInt 0 2
  r <- randomInt 1 11
  pure { suit: fromMaybe Pollinators (oracleSuitsArr !! oi), rank: r }

randomFullDraw :: Effect Draw
randomFullDraw = do
  m <- randomMajorRec
  minors <- traverse (\s -> randomRank <#> \r -> { suit: s, rank: r }) suitsOrder
  o <- randomOracleRec
  pure { major: Just m, minors, oracles: [ o ] }

minorIdx :: String -> Maybe Int
minorIdx key = stripPrefix (Pattern "m") key >>= fromString

-- | Re-roll a single slot, keeping everything else.
redrawSlot :: String -> Draw -> Effect Draw
redrawSlot key d
  | key == "major" = do
      m <- randomMajorRec
      pure d { major = Just m }
  | key == "o0" = do
      o <- randomOracleRec
      pure d { oracles = [ o ] }
  | otherwise = case minorIdx key of
      Just i -> do
        r <- randomRank
        pure d { minors = fromMaybe d.minors (modifyAt i (\mm -> mm { rank = r }) d.minors) }
      Nothing -> pure d

-- | Re-roll every slot not in the lock set.
redrawUnlocked :: Set String -> Draw -> Effect Draw
redrawUnlocked locks d0 = go slotKeys d0
  where
  go ks acc = case uncons ks of
    Nothing -> pure acc
    Just { head, tail } -> do
      acc' <- if Set.member head locks then pure acc else redrawSlot head acc
      go tail acc'

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

renderTarotColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderTarotColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-tarot") ]
    [ HH.div [ HP.class_ (H.ClassName "tarot-toolbar") ]
        [ btn "Deal" TarotDeal
        , btn "Redraw unlocked" TarotRedrawAll
        , btn "Hush" TarotHush
        ]
    , case state.tarotDraw of
        Nothing ->
          HH.p [ HP.class_ (H.ClassName "tarot-empty") ]
            [ HH.text "Draw a reading — it generates a Calypso session and plays it." ]
        Just d ->
          HH.div [ HP.class_ (H.ClassName "tarot-spread") ]
            ( ( case d.major of
                  Just mj ->
                    [ HH.div [ HP.class_ (H.ClassName "tarot-row tarot-row-sig") ]
                        [ renderCard state "major" (Major mj.num mj.name)
                            (Just ("significator → " <> (genreForDraw d).name))
                        ]
                    ]
                  Nothing -> []
              )
                <>
                  [ HH.div [ HP.class_ (H.ClassName "tarot-row tarot-row-minors") ]
                      ( mapWithIndex
                          (\i mm -> renderCard state ("m" <> show i) (Minor mm.suit mm.rank) Nothing)
                          d.minors
                      )
                  ]
                <>
                  ( case d.oracles !! 0 of
                      Just o ->
                        [ HH.div [ HP.class_ (H.ClassName "tarot-row tarot-row-oracle") ]
                            [ renderCard state "o0" (Oracle o.suit o.rank) (Just "oracle") ]
                        ]
                      Nothing -> []
                  )
            )
    , renderGenre state
    ]
  where
  btn lbl act =
    HH.button [ HP.class_ (H.ClassName "tarot-btn"), HE.onClick \_ -> act ] [ HH.text lbl ]

-- | A framed card in the dealt spread: a role tag (significator/oracle), the
-- | full-colour scan when available, the typographic face as fallback, and the
-- | per-card redraw/lock controls (revealed on hover).
renderCard
  :: forall m
   . State
  -> String
  -> Card
  -> Maybe String
  -> H.ComponentHTML Action Slots m
renderCard state key card mTag =
  let
    locked = Set.member key state.tarotLocks
    cls = "tarot-card"
      <> (if locked then " locked" else "")
      <> (if key == "major" then " significator" else "")
  in
    HH.div [ HP.class_ (H.ClassName cls) ]
      ( ( case mTag of
            Just t -> [ HH.div [ HP.class_ (H.ClassName "tarot-card-tag") ] [ HH.text t ] ]
            Nothing -> []
        )
          <> [ cardFace card ]
          <>
            ( case cardImageUrl card of
                Just url -> [ HH.img [ HP.class_ (H.ClassName "tarot-card-img"), HP.src url, HP.alt "" ] ]
                Nothing -> []
            )
          <>
            [ HH.div [ HP.class_ (H.ClassName "tarot-card-controls") ]
                [ HH.button
                    [ HP.title "redraw this card", HE.onClick \_ -> TarotRedraw key ]
                    [ HH.text "↻" ]
                , HH.button
                    [ HP.title (if locked then "unlock" else "lock")
                    , HE.onClick \_ -> TarotToggleLock key
                    ]
                    [ HH.text (if locked then "🔒" else "🔓") ]
                ]
            ]
      )

-- | Full-colour deck scan for a card: cards/card-NNN.jpg. These are a gitignored
-- | local extraction of the owned BOTANICA: Full Bloom deck (eventual home: the
-- | Mac Mini over Tailscale; other builders supply their own). Page order is
-- | canonical — Major 0..21, then Minor by suit (Cups/Swords/Wands/Coins,
-- | Ace..King), then Oracle (Pollinators/Nectar Robbers/Seed Carriers, 1..11).
-- | If a scan is absent the <img> simply fails and the typographic face shows.
cardImageUrl :: Card -> Maybe String
cardImageUrl card = Just ("cards/card-" <> pad3 (cardPage card) <> ".jpg")

cardPage :: Card -> Int
cardPage = case _ of
  Major m _ -> m + 1
  Minor suit rank -> 22 + suitOffset suit + rankToInt rank
  Oracle suit n -> 78 + oracleOffset suit + n

suitOffset :: Suit -> Int
suitOffset = case _ of
  Cups -> 0
  Swords -> 14
  Wands -> 28
  Coins -> 42

oracleOffset :: OracleSuit -> Int
oracleOffset = case _ of
  Pollinators -> 0
  NectarRobbers -> 11
  SeedCarriers -> 22

pad3 :: Int -> String
pad3 n
  | n < 10 = "00" <> show n
  | n < 100 = "0" <> show n
  | otherwise = show n

-- | The typographic card face — the fallback shown until a scan exists, and a
-- | legible card in its own right.
cardFace :: forall m. Card -> H.ComponentHTML Action Slots m
cardFace = case _ of
  Major n nm ->
    faceBox "tarot-face-major"
      [ line "tarot-face-numeral" (roman n)
      , line "tarot-face-name" nm
      , line "tarot-face-kind" "Major Arcana"
      ]
  Minor suit rank ->
    faceBox "tarot-face-minor"
      [ line "tarot-face-glyph" (suitGlyph suit)
      , line "tarot-face-numeral" (rankPip rank)
      , line "tarot-face-name" (show rank <> " of " <> show suit)
      ]
  Oracle suit n ->
    faceBox "tarot-face-oracle"
      [ line "tarot-face-glyph" (oracleGlyph suit)
      , line "tarot-face-numeral" (show n)
      , line "tarot-face-name" (show suit)
      ]
  where
  faceBox cls kids = HH.div [ HP.class_ (H.ClassName ("tarot-face " <> cls)) ] kids
  line cls t = HH.div [ HP.class_ (H.ClassName cls) ] [ HH.text t ]

roman :: Int -> String
roman = case _ of
  0 -> "0"
  1 -> "I"
  2 -> "II"
  3 -> "III"
  4 -> "IV"
  5 -> "V"
  6 -> "VI"
  7 -> "VII"
  8 -> "VIII"
  9 -> "IX"
  10 -> "X"
  11 -> "XI"
  12 -> "XII"
  13 -> "XIII"
  14 -> "XIV"
  15 -> "XV"
  16 -> "XVI"
  17 -> "XVII"
  18 -> "XVIII"
  19 -> "XIX"
  20 -> "XX"
  21 -> "XXI"
  _ -> "?"

rankPip :: Rank -> String
rankPip = case _ of
  Ace -> "A"
  Two -> "2"
  Three -> "3"
  Four -> "4"
  Five -> "5"
  Six -> "6"
  Seven -> "7"
  Eight -> "8"
  Nine -> "9"
  Ten -> "10"
  Page -> "P"
  Knight -> "Kn"
  Queen -> "Q"
  King -> "K"

suitGlyph :: Suit -> String
suitGlyph = case _ of
  Cups -> "♥"
  Swords -> "♠"
  Wands -> "♣"
  Coins -> "♦"

oracleGlyph :: OracleSuit -> String
oracleGlyph = case _ of
  Pollinators -> "✿"
  NectarRobbers -> "✸"
  SeedCarriers -> "❉"

-- | Significator → genre. The significator (the chosen Major arcana) selects
-- | the genre region; the rest of the draw only seeds within it. The mapping is
-- | thematic — each card's character points at a genre's mood (the Tower's
-- | sudden rupture → Webern's pointillism; the Moon's nocturnal depth → dub
-- | techno; the Sun's brightness → house). All nine authored priors appear.
genreForMajor :: Int -> Genre
genreForMajor = case _ of
  0 -> house         -- The Fool — bright, open, the dance floor's first step
  1 -> goa           -- The Magician — focused will, hypnotic ritual
  2 -> dubTechno     -- The High Priestess — mystery, cavernous depth
  3 -> glass         -- The Empress — abundance, generative bloom
  4 -> webern        -- The Emperor — order, serial rigour
  5 -> part          -- The Hierophant — sacred, liturgical
  6 -> dembow        -- The Lovers — sensual, the body's dance
  7 -> rawDnB        -- The Chariot — drive, speed, momentum
  8 -> deepTechHouse -- Strength — powerful, steady tech-house groove
  9 -> miles         -- The Hermit — introspective, the solo voice
  10 -> goa          -- Wheel of Fortune — cyclic, relentless turning
  11 -> miles        -- Justice — balance, swing, measured
  12 -> miles        -- The Hanged Man — suspended, modal stasis
  13 -> incessantDnB -- Death — intense, breakbeat transformation
  14 -> part          -- Temperance — balance, sacred restraint
  15 -> subzeroTechno -- The Devil — relentless, dark minimal techno
  16 -> webern       -- The Tower — sudden, fractured rupture
  17 -> glass        -- The Star — hope, flowing motion
  18 -> dubTechno    -- The Moon — nocturnal, subterranean
  19 -> house        -- The Sun — joyful, radiant
  20 -> part          -- Judgement — transcendent, choral
  21 -> glass        -- The World — completion, cyclical wholeness
  _ -> dubTechno     -- out of range: the deep default

genreForDraw :: Draw -> Genre
genreForDraw d = genreForMajor (maybe 7 _.num d.major)

-- | The rest of the draw supplies the deterministic sample seed, so the same
-- | cards always yield the same music — "the deck is the entropy source".
seedFromDraw :: Draw -> Int
seedFromDraw d =
  maybe 0 _.num d.major
    + sum (map (rankToInt <<< _.rank) d.minors)
    + sum (map _.rank d.oracles)

-- | The reading produced by a genre button: source line + the manifest summary
-- | (bpm, key, sections, and each voice's pattern). Distinct from the card draw
-- | above — genres aren't card-based yet (the significator wiring is stage 2).
renderGenre :: forall m. State -> H.ComponentHTML Action Slots m
renderGenre state = case state.tarotManifest of
  Nothing -> HH.text ""
  Just m ->
    HH.pre [ HP.class_ (H.ClassName "tarot-genre") ]
      [ HH.text (m.meta.source <> "\n" <> summarise m) ]
