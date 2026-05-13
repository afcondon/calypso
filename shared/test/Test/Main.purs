module Test.Main where

import Prelude

import Effect (Effect)
import Effect.Aff (launchAff_)
import Test.Spec.Reporter.Console (consoleReporter)
import Test.Spec.Runner (runSpec)

import Test.Calypso.Composition.ParserSpec (parserSpec)

main :: Effect Unit
main = launchAff_ $ void $ runSpec [consoleReporter] do
  parserSpec
