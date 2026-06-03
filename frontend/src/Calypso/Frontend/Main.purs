module Calypso.Frontend.Main where

import Prelude

import Effect (Effect)
import Effect.Console as Console
import Halogen.Aff as HA
import Halogen.VDom.Driver (runUI)

import Calypso.Frontend.Shell as Shell

main :: Effect Unit
main = do
  Console.log "★ CALYPSO frontend booted ★"
  HA.runHalogenAff do
    body <- HA.awaitBody
    _ <- runUI Shell.component unit body
    pure unit
