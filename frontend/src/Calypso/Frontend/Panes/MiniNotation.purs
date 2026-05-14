module Calypso.Frontend.Panes.MiniNotation where

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Calypso.Frontend.Primer as Primer
import Calypso.Frontend.Shell.Types (Action, Slots, State)

renderMiniNotationColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderMiniNotationColumn _ =
  HH.section [ HP.class_ (H.ClassName "pane pane-mini-notation") ]
    [ Primer.renderMiniNotation ]
