module Calypso.Frontend.Panes.Config where

import Prelude

import Data.Maybe (Maybe(..))
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import Calypso.Frontend.Config (prettyPrintJson)
import Calypso.Frontend.Shell.Types (Action(..), Slots, State)

renderConfigColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderConfigColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-config") ]
    [ HH.div [ HP.class_ (H.ClassName "config-toolbar") ]
        [ HH.button
            [ HP.class_ (H.ClassName "config-refresh-btn")
            , HE.onClick \_ -> RefreshConfigState
            , HP.title "Re-fetch state from purerl-tidal"
            ]
            [ HH.text "↻ refresh" ]
        ]
    , HH.pre [ HP.class_ (H.ClassName "config-body") ]
        [ HH.text body ]
    ]
  where
    body = case state.configSnapshot of
      Nothing -> "(no snapshot yet — click ↻ refresh)"
      Just s -> prettyPrintJson s
