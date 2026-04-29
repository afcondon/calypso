-- | Drives a force simulation for a single Atelier render row by
-- | handing pre-decoded node/link/force data to
-- | `hylograph-simulation`'s `runSimulation`, subscribing to Tick
-- | events, and pushing each tick's `{id,x,y}` snapshot back to the
-- | JS caller so it can update the SVG DOM.
-- |
-- | Called from RenderView.js via the compiled `runAtelierForce`
-- | export. The JS side is responsible for: parsing the incoming
-- | PlaygroundValue JSON, unwrapping `$record` / `$ctor` envelopes,
-- | building the SVG scaffold (circles + lines + container id), and
-- | applying each tick callback's positions to those elements. This
-- | module owns the simulation lifecycle and the translation from
-- | Atelier's `AtelierForceSpec` vocabulary into hylograph's Setup
-- | DSL (`manyBody` / `collide` / `link` / `center` / `positionX` /
-- | `positionY` with their `withStrength` / `withRadius` / etc.
-- | combinators).
module Playground.Frontend.ForceSim
  ( JsNode
  , JsLink
  , JsForce
  , JsPosition
  , runAtelierForce
  ) where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe, toNullable)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Uncurried (EffectFn1, EffectFn5, mkEffectFn5, runEffectFn1)
import Hylograph.ForceEngine.Setup (ForceConfig)
import Hylograph.Simulation
  ( Engine(..)
  , SimulationEvent(..)
  , center
  , collide
  , link
  , manyBody
  , positionX
  , positionY
  , runSimulation
  , setup
  , static
  , subscribe
  , withDistance
  , withRadius
  , withStrength
  , withX
  , withY
  )

-- Shapes matching the JS objects the caller constructs. JS is
-- responsible for filling these out of the PlaygroundValue
-- envelope — PS never touches the raw JSON.
type JsNode =
  { id :: String
  , radius :: Number
  , fill :: String
  , label :: String
  }

type JsLink =
  { source :: String
  , target :: String
  }

-- Flattened force-spec descriptor. The JS side extracts `kind` from
-- `$ctor` and populates the relevant numeric fields; others are
-- left `null`. Saves us a trip through Foreign in the PS layer.
type JsForce =
  { kind :: String
  , name :: String
  , strength :: Nullable Number
  , radius :: Nullable Number
  , distance :: Nullable Number
  , x :: Nullable Number
  , y :: Nullable Number
  }

type JsPosition =
  { id :: String
  , x :: Number
  , y :: Number
  }

-- Row layered on top of hylograph's `SimulationNode` base. We carry
-- the original String id so the tick callback can key back into the
-- JS-side SVG elements without needing a parallel index.
type AtelierRow =
  ( originalId :: String
  , radius :: Number
  , fill :: String
  , label :: String
  )

type AtelierNode = Record
  ( id :: Int
  , x :: Number
  , y :: Number
  , vx :: Number
  , vy :: Number
  , fx :: Nullable Number
  , fy :: Nullable Number
  | AtelierRow
  )

-- | Entry point called from RenderView.js. Builds hylograph's
-- | simulation from the decoded inputs, subscribes to Tick events,
-- | and returns an `Effect` cleanup (unsubscribe + handle.stop).
-- |
-- | Compiled to a 5-argument JS function via `EffectFn5`; the JS
-- | caller invokes it directly (no currying) and receives the
-- | cleanup as `() => undefined` — call it once to tear down.
runAtelierForce
  :: EffectFn5
       (Array JsNode)
       (Array JsLink)
       (Array JsForce)
       String                                 -- container CSS selector
       (EffectFn1 (Array JsPosition) Unit)    -- tick callback
       (Effect Unit)                          -- cleanup
runAtelierForce = mkEffectFn5 \jsNodes jsLinks jsForces selector tickCb -> do
  let
    -- Sequential int ids match the nodes' position in the array;
    -- link source/target get resolved through this map.
    idMap :: Map.Map String Int
    idMap = Map.fromFoldable
      (Array.mapWithIndex (\i n -> Tuple n.id i) jsNodes)

    atelierNodes :: Array AtelierNode
    atelierNodes = Array.mapWithIndex
      (\i n ->
        { id: i
        , x: 0.0
        , y: 0.0
        , vx: 0.0
        , vy: 0.0
        , fx: toNullable Nothing
        , fy: toNullable Nothing
        , originalId: n.id
        , radius: n.radius
        , fill: n.fill
        , label: n.label
        })
      jsNodes

    simLinks :: Array { source :: Int, target :: Int }
    simLinks = Array.mapMaybe
      (\l -> do
        s <- Map.lookup l.source idMap
        t <- Map.lookup l.target idMap
        pure { source: s, target: t })
      jsLinks

    forceConfigs = Array.mapMaybe translateForce jsForces
    atelierSetup = setup "atelier" forceConfigs

  { handle, events } <- runSimulation
    { engine: D3
    , setup: atelierSetup
    , nodes: atelierNodes
    , links: simLinks
    , container: selector
    , alphaMin: 0.001
    }

  unsubscribe <- subscribe events case _ of
    Tick _ -> do
      ns <- handle.getNodes
      let
        positions :: Array JsPosition
        positions = map
          (\n -> { id: n.originalId, x: n.x, y: n.y })
          ns
      runEffectFn1 tickCb positions
    _ -> pure unit

  pure do
    unsubscribe
    handle.stop

-- Translate one AtelierForceSpec-shaped descriptor into a hylograph
-- ForceConfig. Unknown kinds are skipped (Nothing) so a newer
-- Runtime.purs can ship forces this frontend doesn't yet handle
-- without crashing the simulation.
translateForce
  :: JsForce
  -> Maybe (ForceConfig AtelierNode)
translateForce f = case f.kind of
  "ManyBody" ->
    Just (manyBody f.name # withStrength (static (num f.strength 0.0)))
  "Collide" ->
    Just
      ( collide f.name
          # withRadius (static (num f.radius 1.0))
          # withStrength (static (num f.strength 1.0))
      )
  "Link" ->
    Just
      ( link f.name
          # withDistance (static (num f.distance 30.0))
          # withStrength (static (num f.strength 1.0))
      )
  "Center" ->
    Just
      ( center f.name
          # withX (static (num f.x 0.0))
          # withY (static (num f.y 0.0))
      )
  "PositionX" ->
    Just
      ( positionX f.name
          # withX (static (num f.x 0.0))
          # withStrength (static (num f.strength 0.1))
      )
  "PositionY" ->
    Just
      ( positionY f.name
          # withY (static (num f.y 0.0))
          # withStrength (static (num f.strength 0.1))
      )
  _ -> Nothing

num :: Nullable Number -> Number -> Number
num n fallback = case toMaybe n of
  Just v -> v
  Nothing -> fallback
