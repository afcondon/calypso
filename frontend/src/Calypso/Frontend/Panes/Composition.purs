module Calypso.Frontend.Panes.Composition where

import Prelude

import Data.Array as Array
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
  , extractSectionNames
  , tvoiceTypeShortClass
  )

renderCompositionColumn :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
renderCompositionColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-composition") ]
    [ HH.div [ HP.class_ (H.ClassName "pane-toolbar") ]
        ( [ HH.button
              [ HP.class_ (H.ClassName "fire-btn fire-btn-typeful")
              , HE.onClick \_ -> FireTypefulComposition state.moduleSource
              , HP.title "Compile and hot-load the composition as a typeful PureScript session (Mod-Enter)"
              ]
              [ HH.text "▶ run" ]
          , HH.button
              [ HP.class_ (H.ClassName "fire-btn")
              , HE.onClick \_ -> LoadWorkspace
              , HP.title "Load a calypso-session.json from disk"
              ]
              [ HH.text "↥ load…" ]
          ]
          <> sectionButtons state.moduleSource
          <> [ case state.compositionStatus of
                 Just msg ->
                   HH.span [ HP.class_ (H.ClassName "fire-status") ]
                     [ HH.text msg ]
                 Nothing -> HH.text ""
             ]
        )
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

  -- One ▶ button per detected `<name> :: Section` declaration, plus
  -- a single ⏹ stop-piece button when at least one section exists.
  -- Buttons send `play-piece <name>` / `stop-piece` through /eval.
  sectionButtons src =
    case extractSectionNames src of
      [] -> []
      names ->
        map sectionPlayBtn names
          <> [ HH.button
                 [ HP.class_ (H.ClassName "fire-btn")
                 , HE.onClick \_ -> StopPiece
                 , HP.title "Clear the conductor (stop-piece); voices keep their current patterns"
                 ]
                 [ HH.text "⏹ stop piece" ]
             ]

  sectionPlayBtn name =
    HH.button
      [ HP.class_ (H.ClassName "fire-btn fire-btn-typeful")
      , HE.onClick \_ -> PlayPiece name
      , HP.title ("Hand " <> name <> " to the conductor (play-piece). Run the composition first.")
      ]
      [ HH.text ("▶ " <> name) ]

  compositionOutput = case _ of
    Editor.Changed src -> ModuleChanged src
    Editor.Submitted src -> FireTypefulComposition src
    Editor.AcceptHunkO pid idx -> AcceptHunk pid idx
    Editor.RejectHunkO pid idx -> RejectHunk pid idx
    Editor.MoveRequested -> DemoteCursorLineToCell
