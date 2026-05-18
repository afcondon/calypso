-- | Studio pane — Audio/MIDI-Setup-style read-only view of the rig.
-- |
-- | The Composition pane is the working surface (analogue: Logic /
-- | Ableton).  The Studio pane is what's plugged in (analogue: macOS
-- | Audio/MIDI Setup).  This pane does NOT edit anything; declarations
-- | live in the composition's Studio module on the purerl-tidal side
-- | and are surfaced here verbatim.
-- |
-- | Conflicts (duplicate MIDI claims and the like) are rendered AT
-- | THE TOP when present — they're the only thing in the pane that
-- | wants the eye urgently.
module Calypso.Frontend.Panes.Studio (renderStudioColumn) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as Str
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import Calypso.Frontend.Shell.Types (Action(..), Slots, State)
import Calypso.Frontend.Studio
  ( StudioConflict
  , StudioDevice
  , StudioDrumKit
  , StudioHit
  , StudioInstrument
  , StudioOwner
  , StudioSnapshot
  )

renderStudioColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderStudioColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-studio") ]
    [ studioHeader
    , case state.studioBuffer of
        Just buf -> editPanel buf
        Nothing -> body
    ]
  where
  body = case state.studio of
    Nothing -> notLoaded
    Just snap -> loaded snap

  studioHeader =
    HH.div [ HP.class_ (H.ClassName "studio-header") ]
      ([ HH.span [ HP.class_ (H.ClassName "studio-title") ]
            [ HH.text "Studio" ]
       ] <> headerButtons)

  headerButtons = case state.studioBuffer of
    Just _ ->
      -- In edit mode the refresh + edit buttons are hidden; cancel /
      -- save are inline below the textarea.
      []
    Nothing ->
      [ HH.button
          [ HP.class_ (H.ClassName "studio-refresh-btn")
          , HP.title "Open Studio.purs for editing (Workstream 2 fast pipeline)"
          , HE.onClick \_ -> StartEditStudio
          ]
          [ HH.text "📝 edit" ]
      , HH.button
          [ HP.class_ (H.ClassName "studio-refresh-btn")
          , HP.title "Re-fetch the Studio snapshot from the daemon"
          , HE.onClick \_ -> RefreshStudio
          ]
          [ HH.text "↻ refresh" ]
      ]

  -- Inline edit buffer.  Plain textarea (no syntax highlighting yet —
  -- a CodeMirror surface is the obvious upgrade once the fast pipeline
  -- is in steady use).  Save submits, Cancel drops the buffer.
  editPanel buf =
    HH.div [ HP.class_ (H.ClassName "studio-edit-panel") ]
      [ HH.textarea
          [ HP.class_ (H.ClassName "studio-edit-textarea")
          , HP.rows 30
          , HP.spellcheck false
          , HP.value buf
          , HE.onValueInput UpdateStudioBuffer
          ]
      , HH.div [ HP.class_ (H.ClassName "studio-edit-actions") ]
          [ HH.button
              [ HP.class_ (H.ClassName "studio-save-btn")
              , HE.onClick \_ -> SaveStudio
              , HP.title "POST /studio-source — write + build + reload-baseline (~700ms)"
              ]
              [ HH.text "💾 save Studio" ]
          , HH.button
              [ HP.class_ (H.ClassName "studio-cancel-btn")
              , HE.onClick \_ -> CancelEditStudio
              ]
              [ HH.text "cancel" ]
          , statusChip
          ]
      ]

  statusChip = case state.studioFireStatus of
    Nothing -> HH.text ""
    Just (Right { reply, totalMs }) ->
      HH.span [ HP.class_ (H.ClassName "studio-fire-ok") ]
        [ HH.text $ "OK (" <> show totalMs <> "ms) — " <> reply ]
    Just (Left err) ->
      HH.span [ HP.class_ (H.ClassName "studio-fire-err") ]
        [ HH.text $ "ERR: " <> err ]

  notLoaded =
    HH.div [ HP.class_ (H.ClassName "studio-empty muted") ]
      [ HH.text "Studio not loaded — click Refresh." ]

  loaded snap =
    let
      isEmpty =
        Array.null snap.devices
          && Array.null snap.instruments
          && Array.null snap.drumKits
          && Array.null snap.conflicts
    in
      if isEmpty
        then
          HH.div [ HP.class_ (H.ClassName "studio-empty muted") ]
            [ HH.text "(no Studio declarations found)" ]
        else
          HH.div [ HP.class_ (H.ClassName "studio-body") ]
            ( conflictsSection snap.conflicts
                <> devicesSection snap.devices
                <> instrumentsSection snap.instruments
                <> drumKitsSection snap.drumKits
            )

conflictsSection :: forall m. Array StudioConflict -> Array (H.ComponentHTML Action Slots m)
conflictsSection [] = []
conflictsSection conflicts =
  [ HH.div [ HP.class_ (H.ClassName "studio-section studio-section-conflicts") ]
      ( [ HH.div [ HP.class_ (H.ClassName "studio-section-header studio-section-header-warn") ]
            [ HH.text "Conflicts" ]
        ] <> map renderConflict conflicts
      )
  ]

renderConflict :: forall m. StudioConflict -> H.ComponentHTML Action Slots m
renderConflict c =
  HH.div [ HP.class_ (H.ClassName "studio-conflict-row") ]
    [ HH.div [ HP.class_ (H.ClassName "studio-conflict-message") ]
        [ HH.text c.message ]
    , HH.div [ HP.class_ (H.ClassName "studio-conflict-meta") ]
        [ HH.span [ HP.class_ (H.ClassName "studio-conflict-loc") ]
            [ HH.text (c.deviceAlias <> " ch " <> show c.channel) ]
        , HH.span [ HP.class_ (H.ClassName "studio-conflict-sep") ]
            [ HH.text " — " ]
        , HH.span [ HP.class_ (H.ClassName "studio-conflict-owners") ]
            [ HH.text (ownersText c.owners) ]
        ]
    ]

ownersText :: Array StudioOwner -> String
ownersText owners =
  Str.joinWith ", " (map (\o -> o.kind <> ":" <> o.name) owners)

devicesSection :: forall m. Array StudioDevice -> Array (H.ComponentHTML Action Slots m)
devicesSection devices =
  [ HH.div [ HP.class_ (H.ClassName "studio-section") ]
      ( [ HH.div [ HP.class_ (H.ClassName "studio-section-header") ]
            [ HH.text "Devices" ]
        ] <>
          ( if Array.null devices
              then [ HH.div [ HP.class_ (H.ClassName "studio-empty-row muted") ]
                       [ HH.text "(none)" ]
                   ]
              else
                [ HH.div [ HP.class_ (H.ClassName "studio-table studio-table-devices") ]
                    ( [ deviceHeaderRow ] <> map renderDeviceRow devices )
                ]
          )
      )
  ]

deviceHeaderRow :: forall m. H.ComponentHTML Action Slots m
deviceHeaderRow =
  HH.div [ HP.class_ (H.ClassName "studio-row studio-row-head") ]
    [ HH.span [ HP.class_ (H.ClassName "studio-col studio-col-alias") ]
        [ HH.text "alias" ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-name") ]
        [ HH.text "name" ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-num") ]
        [ HH.text "latency (ms)" ]
    ]

renderDeviceRow :: forall m. StudioDevice -> H.ComponentHTML Action Slots m
renderDeviceRow d =
  HH.div [ HP.class_ (H.ClassName "studio-row") ]
    [ HH.span [ HP.class_ (H.ClassName "studio-col studio-col-alias") ]
        [ HH.text d.alias ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-name") ]
        [ HH.text d.name ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-num") ]
        [ HH.text (show d.latencyMs) ]
    ]

instrumentsSection :: forall m. Array StudioInstrument -> Array (H.ComponentHTML Action Slots m)
instrumentsSection instruments =
  [ HH.div [ HP.class_ (H.ClassName "studio-section") ]
      ( [ HH.div [ HP.class_ (H.ClassName "studio-section-header") ]
            [ HH.text "Instruments" ]
        ] <>
          ( if Array.null instruments
              then [ HH.div [ HP.class_ (H.ClassName "studio-empty-row muted") ]
                       [ HH.text "(none)" ]
                   ]
              else
                [ HH.div [ HP.class_ (H.ClassName "studio-table studio-table-instruments") ]
                    ( [ instrumentHeaderRow ] <> map renderInstrumentRow instruments )
                ]
          )
      )
  ]

instrumentHeaderRow :: forall m. H.ComponentHTML Action Slots m
instrumentHeaderRow =
  HH.div [ HP.class_ (H.ClassName "studio-row studio-row-head") ]
    [ HH.span [ HP.class_ (H.ClassName "studio-col studio-col-alias") ]
        [ HH.text "alias" ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-dev") ]
        [ HH.text "device" ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-num") ]
        [ HH.text "ch" ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-defs") ]
        [ HH.text "note/vel/dur" ]
    ]

renderInstrumentRow :: forall m. StudioInstrument -> H.ComponentHTML Action Slots m
renderInstrumentRow i =
  HH.div [ HP.class_ (H.ClassName "studio-row") ]
    [ HH.span [ HP.class_ (H.ClassName "studio-col studio-col-alias") ]
        [ HH.text i.alias ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-dev") ]
        [ HH.text i.deviceAlias ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-num") ]
        [ HH.text (show i.channel) ]
    , HH.span [ HP.class_ (H.ClassName "studio-col studio-col-defs") ]
        [ HH.text (show i.defNote <> "/" <> show i.defVel <> "/" <> show i.defDurMs) ]
    ]

drumKitsSection :: forall m. Array StudioDrumKit -> Array (H.ComponentHTML Action Slots m)
drumKitsSection drumKits =
  [ HH.div [ HP.class_ (H.ClassName "studio-section") ]
      ( [ HH.div [ HP.class_ (H.ClassName "studio-section-header") ]
            [ HH.text "Drum kits" ]
        ] <>
          ( if Array.null drumKits
              then [ HH.div [ HP.class_ (H.ClassName "studio-empty-row muted") ]
                       [ HH.text "(none)" ]
                   ]
              else map renderDrumKit drumKits
          )
      )
  ]

renderDrumKit :: forall m. StudioDrumKit -> H.ComponentHTML Action Slots m
renderDrumKit k =
  HH.div [ HP.class_ (H.ClassName "studio-drumkit") ]
    [ HH.div [ HP.class_ (H.ClassName "studio-drumkit-head") ]
        [ HH.span [ HP.class_ (H.ClassName "studio-col-alias") ]
            [ HH.text k.alias ]
        , HH.span [ HP.class_ (H.ClassName "studio-drumkit-meta muted") ]
            [ HH.text (k.deviceAlias <> " ch " <> show k.channel) ]
        ]
    , HH.div [ HP.class_ (H.ClassName "studio-drumkit-hits") ]
        [ HH.text (hitsText k.hits) ]
    ]

hitsText :: Array StudioHit -> String
hitsText hits =
  Str.joinWith ", "
    (map (\h -> h.name <> ":" <> show h.note <> "/" <> show h.vel <> "/" <> show h.durMs) hits)
