module Playground.Frontend.RenderView
  ( component
  , Input
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Web.DOM.Element (Element)
import Web.HTML.HTMLElement (toElement)

type Input = { json :: String }

type State = Input

data Action = Render | SetInput Input | Finalize

foreign import _renderInto :: Element -> String -> Effect Unit
foreign import _cleanup :: Element -> Effect Unit

containerRef :: H.RefLabel
containerRef = H.RefLabel "render-view"

component :: forall q o m. MonadAff m => H.Component q Input o m
component = H.mkComponent
  { initialState: identity
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction
      , initialize = Just Render
      , finalize = Just Finalize
      , receive = \input -> Just (SetInput input)
      }
  }
  where
  -- Container is imperatively managed; Halogen's VDom won't touch the
  -- children we mount via FFI (SVG + d3-force node elements).
  render _ =
    HH.div
      [ HP.ref containerRef
      , HP.class_ (H.ClassName "render-view")
      ]
      []

  handleAction = case _ of
    SetInput input -> do
      state <- H.get
      -- Re-parse + re-simulate is expensive; skip when input unchanged.
      when (input.json /= state.json) do
        H.put input
        handleAction Render
    Render -> do
      state <- H.get
      mEl <- H.getHTMLElementRef containerRef
      case mEl of
        Nothing -> pure unit
        Just htmlEl ->
          liftEffect (_renderInto (toElement htmlEl) state.json)
    Finalize -> do
      mEl <- H.getHTMLElementRef containerRef
      case mEl of
        Nothing -> pure unit
        Just htmlEl ->
          liftEffect (_cleanup (toElement htmlEl))
