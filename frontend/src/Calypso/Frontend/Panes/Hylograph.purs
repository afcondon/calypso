module Calypso.Frontend.Panes.Hylograph where

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Calypso.Frontend.Shell.Types (Action, Slots, State)

-- | Hylograph pane.  Reserved for the upcoming pattern visualiser
-- | (Asteroids/Battlezone vector aesthetic).  Placeholder until that
-- | lands — the previous reference-panel content (Vocabulary, Mini-
-- | notation, Replies) has been promoted to top-level panes of its
-- | own, addressable via Cmd-3..5.
renderHylographColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderHylographColumn _ =
  HH.section [ HP.class_ (H.ClassName "pane pane-hylograph") ]
    [ HH.div [ HP.class_ (H.ClassName "hylograph-placeholder") ]
        [ HH.div [ HP.class_ (H.ClassName "hylograph-placeholder-title") ]
            [ HH.text "Hylograph" ]
        , HH.div [ HP.class_ (H.ClassName "hylograph-placeholder-body muted") ]
            [ HH.text "Pattern visualiser coming soon." ]
        ]
    ]
