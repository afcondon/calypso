module Calypso.Frontend.Panes.Replies where

import Prelude

import Data.Array (mapWithIndex)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Calypso.Frontend.Shell.Types (Action, CellRec, Slots, State, cellColorClass)

-- | Replies pane — per-cell most-recent reply from the daemon, plus
-- | the most recent composition fire's per-statement results.
-- | Was a tab inside Hylograph; promoted to a top-level pane (Cmd-3)
-- | so you can keep an eye on firings without displacing the editor.
renderRepliesColumn :: forall m. State -> H.ComponentHTML Action Slots m
renderRepliesColumn state =
  HH.section [ HP.class_ (H.ClassName "pane pane-replies") ]
    ( compositionSection <> cellsSection )
  where
  compositionSection =
    if Array.null state.compositionFireLines
      then []
      else
        [ HH.div [ HP.class_ (H.ClassName "replies-section") ]
            ( [ HH.div [ HP.class_ (H.ClassName "replies-section-header") ]
                  [ HH.text "▶ composition" ]
              ] <> map renderFireLine state.compositionFireLines
            )
        ]
  cellsSection =
    [ HH.div [ HP.class_ (H.ClassName "replies-section") ]
        ( [ HH.div [ HP.class_ (H.ClassName "replies-section-header") ]
              [ HH.text "cells" ]
          ] <> Array.catMaybes (mapWithIndex maybeRow state.cells)
        )
    ]
  maybeRow idx c =
    if c.kind == "expr" then Just (renderHylographRow state idx c) else Nothing

-- | One row in the composition fire results — line number, source
-- | preview, and the daemon's reply (or transport error) coloured
-- | green for success, red for failure.
renderFireLine
  :: forall m
   . { lineNum :: Int, source :: String, reply :: Either String String }
  -> H.ComponentHTML Action Slots m
renderFireLine r =
  let
    cls = case r.reply of
      Right _ -> "replies-fire-row replies-fire-ok"
      Left _ -> "replies-fire-row replies-fire-err"
    replyText = case r.reply of
      Right s -> s
      Left e -> e
  in
    HH.div [ HP.class_ (H.ClassName cls) ]
      [ HH.span [ HP.class_ (H.ClassName "replies-fire-linenum") ]
          [ HH.text (show r.lineNum) ]
      , HH.span [ HP.class_ (H.ClassName "replies-fire-source") ]
          [ HH.text r.source ]
      , HH.pre [ HP.class_ (H.ClassName "replies-fire-reply") ]
          [ HH.text replyText ]
      ]

-- | Row in the cells section — cell id + the daemon's most recent
-- | reply (or an em-dash if nothing's been fired yet).
renderHylographRow :: forall m. State -> Int -> CellRec -> H.ComponentHTML Action Slots m
renderHylographRow state idx c =
  HH.div [ HP.class_ (H.ClassName ("hylograph-row " <> cellColorClass idx)) ]
    [ HH.span [ HP.class_ (H.ClassName "hylograph-cell-id") ] [ HH.text c.id ]
    , case Map.lookup c.id state.cellResults of
        Just reply ->
          HH.pre [ HP.class_ (H.ClassName "hylograph-reply") ]
            [ HH.text reply ]
        Nothing ->
          HH.span [ HP.class_ (H.ClassName "muted") ] [ HH.text "—" ]
    ]
