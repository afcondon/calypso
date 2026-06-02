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
import Data.Cards (Rank(..))
import Data.FullBloom (Card(..), OracleSuit(..), Suit(..), label)
import Generate.Session (dimensionsFromDraw)
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
          HH.div [ HP.class_ (H.ClassName "tarot-cards") ]
            ( [ renderCard state "major" (majorLabel d) ]
                <> mapWithIndex
                     (\i mm -> renderCard state ("m" <> show i) (label (Minor mm.suit mm.rank)))
                     d.minors
                <> ( case d.oracles !! 0 of
                       Just o -> [ renderCard state "o0" (label (Oracle o.suit o.rank)) ]
                       Nothing -> []
                   )
            )
    , renderDims state
    ]
  where
  btn lbl act =
    HH.button [ HP.class_ (H.ClassName "tarot-btn"), HE.onClick \_ -> act ] [ HH.text lbl ]

  majorLabel d = maybe "(no major)" (\mj -> label (Major mj.num mj.name)) d.major

renderCard :: forall m. State -> String -> String -> H.ComponentHTML Action Slots m
renderCard state key lbl =
  let locked = Set.member key state.tarotLocks
  in
    HH.div
      [ HP.class_ (H.ClassName ("tarot-card" <> if locked then " locked" else "")) ]
      [ HH.div [ HP.class_ (H.ClassName "tarot-card-label") ] [ HH.text lbl ]
      , HH.div [ HP.class_ (H.ClassName "tarot-card-actions") ]
          [ HH.button
              [ HP.class_ (H.ClassName "tarot-card-redraw")
              , HP.title "redraw this card"
              , HE.onClick \_ -> TarotRedraw key
              ]
              [ HH.text "↻" ]
          , HH.button
              [ HP.class_ (H.ClassName "tarot-card-lock")
              , HP.title (if locked then "unlock" else "lock")
              , HE.onClick \_ -> TarotToggleLock key
              ]
              [ HH.text (if locked then "🔒" else "🔓") ]
          ]
      ]

renderDims :: forall m. State -> H.ComponentHTML Action Slots m
renderDims state = case state.tarotDraw of
  Nothing -> HH.text ""
  Just d ->
    let dims = dimensionsFromDraw d
    in
      HH.div [ HP.class_ (H.ClassName "tarot-dims") ]
        [ HH.text $
            "scale " <> dims.scaleVal
              <> "  ·  " <> show dims.bpm <> " bpm"
              <> "  ·  " <> show dims.voiceCount <> " voices"
              <> "  ·  density " <> show dims.density
              <> "  ·  entropy " <> show dims.entropy
        ]
