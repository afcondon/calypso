module Playground.Frontend.InScope
  ( InScope
  , forRuntime
  ) where

import Prelude

-- | What's in scope for a given runtime: the imports every cell gets
-- | for free (so users don't need to re-import them in their module to
-- | reference from cells), a curated shortlist of packages the user
-- | can pull into their own module, and any runtime-specific caveats.
type InScope =
  { runtimeLabel :: String
  , autoImports :: Array String
  , highlightedPackages :: Array String
  , notes :: Array String
  }

forRuntime :: String -> InScope
forRuntime = case _ of
  "node" -> nodeScope
  "purerl" -> purerlScope
  _ -> browserScope

browserScope :: InScope
browserScope =
  { runtimeLabel: "Browser (Web Worker)"
  , autoImports:
      [ "Prelude"
      , "Data.Array as Array"
      , "Data.Either (Either(..))"
      , "Data.Maybe (Maybe(..))"
      , "Data.Tuple (Tuple(..))"
      , "Effect (Effect)"
      , "Effect.Aff (runAff_)"
      , "Effect.Class (liftEffect)"
      , "Playground.Runtime (toPlaygroundValue, emit, done)"
      ]
  , highlightedPackages:
      [ "aff", "affjax", "affjax-web", "arrays", "argonaut", "either"
      , "foldable-traversable", "integers", "maybe", "numbers"
      , "ordered-collections", "parsing", "random", "strings"
      , "transformers", "tuples"
      , "hylograph-graph", "hylograph-layout", "hylograph-transitions"
      ]
  , notes:
      [ "Cells run in a Web Worker; no DOM access, but setTimeout + Aff.delay work."
      , "fetch is available for HTTP; affjax wraps it."
      , "Hylograph layout algorithms are available (DataViz.Layout.Hierarchy.Pack, .Treemap, .Tree, Sankey, Chord, ...) — pure PureScript, Worker-safe."
      , "Return `Playground.Runtime.ForceRender {...}` or a string starting with `<svg` to have the value drawn in the Render column."
      ]
  }

nodeScope :: InScope
nodeScope =
  { runtimeLabel: "Node (child-process)"
  , autoImports: browserScope.autoImports
  , highlightedPackages:
      browserScope.highlightedPackages
        <> [ "node-fs", "node-buffer", "node-child-process", "node-stream" ]
  , notes:
      [ "Cells run in a fresh Node child-process; full stdlib access (FS, sockets, DBs, native modules)."
      , "Stdout captured as the emit channel — logs appear inline."
      ]
  }

purerlScope :: InScope
purerlScope =
  { runtimeLabel: "Purerl (BEAM)"
  , autoImports:
      [ "Prelude"
      , "Data.Array as Array"
      , "Data.Either (Either(..))"
      , "Data.Maybe (Maybe(..))"
      , "Data.Tuple (Tuple(..))"
      , "Effect (Effect)"
      , "Playground.Runtime (toPlaygroundValue, emit, done)"
      ]
  , highlightedPackages:
      [ "arrays", "console", "effect", "either", "erl-atom", "erl-binary"
      , "erl-kernel", "erl-lists", "erl-maps", "erl-process", "erl-tuples"
      , "foldable-traversable", "integers", "maybe", "ordered-collections"
      , "parsing", "prelude", "strings", "tuples"
      ]
  , notes:
      [ "No Effect.Aff — concurrency is the BEAM process model (erl-process)."
      , "Cells that import Aff will fail to compile with an honest 'Module not found'."
      , "Compiles via purs-backend-erl → erlc → erl."
      ]
  }
