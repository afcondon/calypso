module Playground.Server.Adapter.PurerlBEAM
  ( purerlBEAM
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Data.Argonaut.Core (Json)
import Effect (Effect)

import Playground.Server.Adapter (Adapter)

-- | Compiles synthesised sources via `spago build` (purs-backend-erl
-- | backend) → `erlc` → runs the result under `erl`, captures JSONL
-- | emissions from stdout. Different runtime-workspace from the JS
-- | adapters because the Purerl package set is separate.
foreign import _bundle
  :: String -> String -> String -> String -> Effect (Promise Json)

purerlBEAM :: Adapter
purerlBEAM =
  { name: "purerl"
  -- PurerlBEAM has its own top-level workspace (`runtime-workspace-purerl`)
  -- and isn't multi-workspace-aware in phase 1. The workspaceDir and
  -- packageName args are accepted for interface uniformity but ignored
  -- by the JS FFI, which still hardcodes its own project root and name.
  , bundle: \workspaceDir packageName userSrc mainSrc ->
      toAffE (_bundle workspaceDir packageName userSrc mainSrc)
  }
