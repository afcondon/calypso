module Calypso.Frontend.Panes.Vocabulary where

import Prelude

import Data.Maybe (Maybe(..))
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Calypso.Frontend.Shell.Types (Action, Slots, State)
import Calypso.Vocabulary as CV

-- | Vocabulary pane — devices and bindings parsed from purerl-tidal's
-- | setup/*.tidal files.  Browsable reference for the live-coder.
renderVocabularyColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderVocabularyColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-vocabulary") ]
    [ renderVocabularyBody state ]

renderVocabularyBody :: forall m. State -> H.ComponentHTML Action Slots m
renderVocabularyBody state =
  let CV.Vocabulary v = state.vocabulary
  in case v.setupFiles of
       [] ->
         HH.div [ HP.class_ (H.ClassName "vocabulary-empty") ]
           [ HH.text "No setup files found. Set $CALYPSO_TIDAL_SETUP_DIR or drop *.tidal files into the default purerl-tidal/setup/ directory." ]
       sfs ->
         HH.div [ HP.class_ (H.ClassName "vocabulary-list") ]
           (map renderSetupFile sfs)

renderSetupFile :: forall m. CV.SetupFile -> H.ComponentHTML Action Slots m
renderSetupFile (CV.SetupFile sf) =
  HH.div [ HP.class_ (H.ClassName "vocabulary-device") ]
    [ HH.div [ HP.class_ (H.ClassName "vocabulary-device-header") ]
        [ HH.span [ HP.class_ (H.ClassName "vocabulary-device-name") ]
            [ HH.text sf.name ]
        , case sf.port of
            Just p ->
              HH.span [ HP.class_ (H.ClassName "vocabulary-device-port") ]
                [ HH.text p ]
            Nothing -> HH.text ""
        ]
    , HH.ul [ HP.class_ (H.ClassName "vocabulary-bindings") ]
        (map renderBinding sf.bindings)
    ]

renderBinding :: forall m. CV.Binding -> H.ComponentHTML Action Slots m
renderBinding (CV.Binding b) =
  HH.li [ HP.class_ (H.ClassName "vocabulary-binding") ]
    [ HH.span [ HP.class_ (H.ClassName "vocabulary-binding-name") ]
        [ HH.text b.name ]
    , HH.span [ HP.class_ (H.ClassName "vocabulary-binding-detail") ]
        [ HH.text (bindingSummary b) ]
    ]

bindingSummary :: forall r. { kind :: CV.BindingKind, channel :: Int, number :: Int | r } -> String
bindingSummary b = case b.kind of
  CV.MidiNote -> "note ch" <> show b.channel <> " (default " <> show b.number <> ")"
  CV.MidiCc -> "cc " <> show b.number <> " ch" <> show b.channel
