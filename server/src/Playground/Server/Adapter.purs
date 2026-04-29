module Playground.Server.Adapter
  ( Adapter
  , BundleOutcome
  ) where

import Data.Argonaut.Core (Json)
import Effect.Aff (Aff)

-- | An adapter knows how to take the two synthesised sources (User.purs
-- | + Main.purs) and produce a deliverable for its host runtime.
-- |
-- | Today the only implementation is `Adapter.BrowserWorker`, which
-- | bundles via `spago bundle` and returns JS bytes the frontend
-- | executes in a Web Worker. Future adapters: `Adapter.NodeProcess`
-- | (same bundle, executed in a Node child), `Adapter.PurerlBEAM`
-- | (different spago backend, different output shape).
-- |
-- | The `name` is how the frontend identifies which executor to wire up
-- | for the returned artefact — currently unused (we only have one
-- | adapter), but the field exists so we don't have to rev the codec
-- | when alternates land.
-- |
-- | `bundle` takes a workspace directory (absolute path) so multiple
-- | concurrent compiles against different workspaces don't stomp each
-- | other's sources or `output/` cache, plus the package name spago
-- | should target — every workspace has its own uniquely-named spago
-- | package (the outer workspace sees them all, so `-p <name>` has to
-- | disambiguate). The adapter writes `<workspaceDir>/src/*` and
-- | reads back `<workspaceDir>/output/*`.
type Adapter =
  { name :: String
  , bundle :: String -> String -> String -> String -> Aff Json
  }

-- | Shape the adapter returns (as Json on the wire; decoded by
-- | Compile.purs into a typed record). Documented here as prose so every
-- | adapter matches the same contract.
-- |
-- |   { js       :: Maybe String         -- bundled JS on success, null on failure
-- |   , warnings :: Array CompileError   -- filtered, structured
-- |   , errors   :: Array CompileError   -- structured; empty iff js is Just
-- |   , cellIds  :: Array String         -- extracted for post-bundle type queries
-- |   }
type BundleOutcome =
  { js :: String
  , warnings :: Array Json
  , errors :: Array Json
  , cellIds :: Array String
  }
