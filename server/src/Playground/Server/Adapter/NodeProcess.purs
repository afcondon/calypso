module Playground.Server.Adapter.NodeProcess
  ( nodeProcess
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Data.Argonaut.Core (Json)
import Effect (Effect)

import Playground.Server.Adapter (Adapter)

-- | Bundles the synthesised sources for Node, spawns a node
-- | child-process, collects emissions from stdout (JSONL), returns
-- | them in the BuildResult's `emits` field. The bundle JS is not
-- | returned — execution has already happened server-side.
foreign import _bundle
  :: String -> String -> String -> String -> Effect (Promise Json)

nodeProcess :: Adapter
nodeProcess =
  { name: "node"
  , bundle: \workspaceDir packageName userSrc mainSrc ->
      toAffE (_bundle workspaceDir packageName userSrc mainSrc)
  }
