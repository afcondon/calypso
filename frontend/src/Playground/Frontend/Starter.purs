module Playground.Frontend.Starter
  ( Starter
  , Compat
  , starters
  , defaultStarter
  , compatFor
  , findByKey
  ) where

import Prelude

import Data.Array (find) as Array
import Data.Maybe (Maybe(..), fromMaybe)

-- | Runtime-compatibility flags per-starter. Users are free to pick a
-- | starter that doesn't match the current runtime — the compile
-- | fails naturally, which is a useful reveal (e.g. "Aff isn't in
-- | Purerl's package set, here's the actual message the compiler
-- | gives you").
type Compat =
  { browser :: Boolean
  , node :: Boolean
  , purerl :: Boolean
  }

-- | One named starter: module source + cell list + which runtimes
-- | it's known to compile on. `key` is a stable id we use to look
-- | up the starter on selection; `label` is what appears in the UI.
type Starter =
  { key :: String
  , label :: String
  , description :: String
  , compat :: Compat
  , moduleSource :: String
  , cells :: Array { id :: String, kind :: String, source :: String }
  }

compatFor :: String -> Compat -> Boolean
compatFor runtime c = case runtime of
  "browser" -> c.browser
  "node" -> c.node
  "purerl" -> c.purerl
  _ -> false

findByKey :: String -> Maybe Starter
findByKey k = Array.find (\s -> s.key == k) starters

defaultStarter :: Starter
defaultStarter = fromMaybe (unsafeHead starters) (findByKey "monads")
  where
  -- `starters` is non-empty by construction; the Maybe is just to
  -- keep the compiler happy about the key lookup.
  unsafeHead = case _ of
    [] -> { key: "empty", label: "—", description: ""
          , compat: { browser: false, node: false, purerl: false }
          , moduleSource: "module Scratch where\n\nimport Prelude\n"
          , cells: []
          }
    xs -> case Array.find (const true) xs of
      Just s -> s
      Nothing -> unsafeHead []

-- ============================================================
-- Starters
-- ============================================================

starters :: Array Starter
starters =
  [ monadsCross
  , monadsWithAff
  , erlangProcesses
  ]

-- ---- 1. Cross-runtime: Maybe / Array / Either ----
monadsCross :: Starter
monadsCross =
  { key: "monads"
  , label: "Monads: Maybe / Array / Either"
  , description: "Five cells showing do/>>= equivalence and three Monad instances — the same do-shape over uncertainty, non-determinism, error-or-result."
  , compat: { browser: true, node: true, purerl: true }
  , moduleSource:
      "module Scratch where\n\n\
      \import Prelude\n\n\
      \import Data.Maybe (Maybe(..))\n\n\
      \-- Safe division: Nothing on divide-by-zero, Just q otherwise.\n\
      \divSafe :: Int -> Int -> Maybe Int\n\
      \divSafe _ 0 = Nothing\n\
      \divSafe n d = Just (n / d)\n"
  , cells:
      [ { id: "c1", kind: "expr"
        , source: "divSafe 100 5"
        }
      , { id: "c2", kind: "expr"
        , source:
            "do\n\
            \  a <- divSafe 100 5\n\
            \  b <- divSafe 200 a\n\
            \  pure (a + b)"
        }
      , { id: "c3", kind: "expr"
        , source:
            "divSafe 100 5 >>= \\a ->\n\
            \  divSafe 200 a >>= \\b ->\n\
            \    pure (a + b)"
        }
      , { id: "c4", kind: "expr"
        , source:
            "do\n\
            \  x <- [1, 2, 3]\n\
            \  y <- [10, 20]\n\
            \  pure (x + y)"
        }
      , { id: "c5", kind: "expr"
        , source:
            "do\n\
            \  x <- (Right 10 :: Either String Int)\n\
            \  y <- Right 20\n\
            \  pure (x + y)"
        }
      ]
  }

-- ---- 3. Purerl: Erlang processes ----
erlangProcesses :: Starter
erlangProcesses =
  { key: "erlang-processes"
  , label: "Erlang processes (BEAM)"
  , description: "Concurrency via typed processes + message passing — not Aff. Purerl-only; erl-process isn't in the JS package set."
  , compat: { browser: false, node: false, purerl: true }
  , moduleSource:
      "module Scratch where\n\n\
      \import Prelude\n\n\
      \import Effect (Effect)\n\
      \import Effect.Class (liftEffect)\n\
      \import Erl.Process (Process, ProcessM, receive, self, spawn, unsafeRunProcessM, (!))\n\n\
      \-- Echoes whatever it receives back to its spawner.\n\
      \echoActor :: Process Int -> ProcessM Int Unit\n\
      \echoActor parent = do\n\
      \  msg <- receive\n\
      \  liftEffect (parent ! msg)\n\n\
      \-- Spawn echoActor, send it 42, wait for the reply.\n\
      \roundTrip :: Effect Int\n\
      \roundTrip = unsafeRunProcessM do\n\
      \  me <- self\n\
      \  child <- liftEffect (spawn (echoActor me))\n\
      \  liftEffect (child ! 42)\n\
      \  receive\n\n\
      \-- Stateful counter actor: Add / Subtract / Query.\n\
      \data Msg = Add Int | Subtract Int | Query (Process Int)\n\n\
      \counter :: Int -> ProcessM Msg Unit\n\
      \counter n = receive >>= case _ of\n\
      \  Add m -> counter (n + m)\n\
      \  Subtract m -> counter (n - m)\n\
      \  Query reply -> liftEffect (reply ! n)\n\n\
      \runCounter :: Effect Int\n\
      \runCounter = unsafeRunProcessM do\n\
      \  me <- self\n\
      \  c <- liftEffect (spawn (counter 0))\n\
      \  liftEffect do\n\
      \    c ! Add 10\n\
      \    c ! Add 5\n\
      \    c ! Subtract 3\n\
      \    c ! Query me\n\
      \  receive\n"
  , cells:
      [ { id: "c1", kind: "expr"
        , source: "roundTrip"
        }
      , { id: "c2", kind: "expr"
        , source: "runCounter"
        }
      ]
  }

-- ---- 2. Browser/Node: Monads + Aff ----
monadsWithAff :: Starter
monadsWithAff =
  { key: "monads-aff"
  , label: "Monads + Aff"
  , description: "Extends the Monads demo with an Aff cell — the same do-shape, this time async. Works identically on Browser and Node; Purerl has no Aff (BEAM concurrency is the process model)."
  , compat: { browser: true, node: true, purerl: false }
  , moduleSource:
      "module Scratch where\n\n\
      \import Prelude\n\n\
      \import Data.Maybe (Maybe(..))\n\
      \import Data.Time.Duration (Milliseconds(..))\n\
      \import Effect.Aff (Aff, delay)\n\n\
      \divSafe :: Int -> Int -> Maybe Int\n\
      \divSafe _ 0 = Nothing\n\
      \divSafe n d = Just (n / d)\n\n\
      \timedSum :: Aff Int\n\
      \timedSum = do\n\
      \  delay (Milliseconds 25.0)\n\
      \  pure 100\n"
  , cells:
      (monadsCross.cells) <>
      [ { id: "c6", kind: "expr"
        , source:
            "do\n\
            \  a <- timedSum\n\
            \  b <- timedSum\n\
            \  pure (a + b)"
        }
      ]
  }

