module Playground.Server.Adapter.BrowserWorker
  ( browserWorker
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Data.Argonaut.Core (Json)
import Effect (Effect)

import Playground.Server.Adapter (Adapter)

-- | Bundles the synthesised sources via `spago bundle -p <packageName>`
-- | with the browser platform. Frontend executes the resulting JS in a
-- | Web Worker via a Blob URL.
foreign import _bundle
  :: String -> String -> String -> String -> Effect (Promise Json)

browserWorker :: Adapter
browserWorker =
  { name: "browser-worker"
  , bundle: \workspaceDir packageName userSrc mainSrc ->
      toAffE (_bundle workspaceDir packageName userSrc mainSrc)
  }
