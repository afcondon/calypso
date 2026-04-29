module Playground.Frontend.Main where

import Prelude

import Effect (Effect)
import Halogen.Aff as HA
import Halogen.VDom.Driver (runUI)

import Playground.Frontend.Shell as Shell

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  _ <- runUI Shell.component unit body
  pure unit
