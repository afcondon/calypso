module Calypso.Frontend.Panes.Composition where

import Prelude

import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import Calypso.Frontend.Editor as Editor
import Calypso.Frontend.Shell.Types
  ( Action(..)
  , Slots
  , State
  , TvoiceType
  , _moduleEditor
  , tvoiceTypeShortClass
  )

renderCompositionColumn :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderCompositionColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-composition") ]
    [ HH.div [ HP.class_ (H.ClassName "pane-toolbar") ]
        [ HH.button
            [ HP.class_ (H.ClassName "fire-btn")
            , HE.onClick \_ -> FireComposition state.moduleSource
            , HP.title "Fire the whole composition (Mod-Enter inside the editor)"
            ]
            [ HH.text "▶ fire" ]
        , HH.button
            [ HP.class_ (H.ClassName "fire-btn")
            , HE.onClick \_ -> LoadWorkspace
            , HP.title "Load a calypso-session.json from disk"
            ]
            [ HH.text "↥ load…" ]
        , HH.button
            [ HP.class_ (H.ClassName "fire-btn")
            , HE.onClick \_ -> DemoteCursorLineToCell
            , HP.title "Make the line under the cursor into a new cell (line stays in composition)"
            ]
            [ HH.text "↧ make cell" ]
        , case state.compositionStatus of
            Just msg ->
              HH.span [ HP.class_ (H.ClassName "fire-status") ]
                [ HH.text msg ]
            Nothing -> HH.text ""
        ]
    , HH.slot _moduleEditor unit Editor.component
        { initialDoc: state.moduleSource
        , tag: "module"
        , vocabulary: state.completions
        , tvoiceColors: tvoiceColorEntries state.tvoiceTypes
        }
        compositionOutput
    ]
  where
  tvoiceColorEntries :: Map.Map String TvoiceType -> Array { tvoice :: String, klass :: String }
  tvoiceColorEntries m =
    map (\(Tuple k v) -> { tvoice: k, klass: tvoiceTypeShortClass v })
        (Map.toUnfoldable m :: Array (Tuple String TvoiceType))

  compositionOutput = case _ of
    Editor.Changed src -> ModuleChanged src
    Editor.Submitted src -> FireComposition src
    Editor.AcceptHunkO pid idx -> AcceptHunk pid idx
    Editor.RejectHunkO pid idx -> RejectHunk pid idx
    Editor.MoveRequested -> DemoteCursorLineToCell
