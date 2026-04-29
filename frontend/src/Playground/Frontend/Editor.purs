module Playground.Frontend.Editor
  ( component
  , Input
  , Output(..)
  , Query(..)
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import Web.HTML.HTMLElement (toElement)

import Playground.Frontend.CodeMirror (EditorView)
import Playground.Frontend.CodeMirror as CM

type Input = { initialDoc :: String, tag :: String }

-- | The editor raises this on every document change. Parents debounce.
data Output = Changed String

-- | External queries: replace content (unused now), push a list of
-- | inline error spans to be decorated on the editor, toggle
-- | whether the view accepts user input.
data Query a
  = ReplaceContent String a
  | SetErrors (Array CM.ErrorSpan) a
  | SetEditable Boolean a

data Action
  = Initialise
  | Finalise
  | UpdateInput Input
  | HandleChange String

-- `currentDoc` tracks what we believe is presently in the CM6 view so
-- we can distinguish 'parent re-rendered with the source we already
-- told them about' (skip) from 'parent loaded a starter with different
-- content' (overwrite the view).
type State =
  { input :: Input
  , view :: Maybe EditorView
  , currentDoc :: String
  }

containerRef :: H.RefLabel
containerRef = H.RefLabel "cm-host"

component :: forall m. MonadAff m => H.Component Query Input Output m
component = H.mkComponent
  { initialState: \input -> { input, view: Nothing, currentDoc: input.initialDoc }
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction
      , handleQuery = handleQuery
      , receive = \input -> Just (UpdateInput input)
      , initialize = Just Initialise
      , finalize = Just Finalise
      }
  }

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div
    [ HP.ref containerRef
    , HP.class_ (H.ClassName ("cm-host cm-host-" <> state.input.tag))
    ]
    []

handleAction
  :: forall m
   . MonadAff m
  => Action
  -> H.HalogenM State Action () Output m Unit
handleAction = case _ of
  Initialise -> do
    state <- H.get
    mEl <- H.getHTMLElementRef containerRef
    case mEl of
      Nothing -> pure unit
      Just htmlEl -> do
        let el = toElement htmlEl
        { emitter, listener } <- liftEffect HS.create
        _ <- H.subscribe (HandleChange <$> emitter)
        view <- liftEffect $
          CM.createEditor el state.input.initialDoc (HS.notify listener)
        H.modify_ _ { view = Just view }
  Finalise -> do
    state <- H.get
    case state.view of
      Just view -> liftEffect (CM.destroy view)
      Nothing -> pure unit
  UpdateInput input -> do
    state <- H.get
    -- Only overwrite the editor's content if the new initialDoc
    -- differs from what we believe is already there. Prevents
    -- clobbering live typing: after HandleChange, currentDoc matches
    -- the user's input; the parent's next render will pass the same
    -- content back, and we correctly skip.
    when (input.initialDoc /= state.currentDoc) do
      case state.view of
        Just view -> liftEffect (CM.setContent view input.initialDoc)
        Nothing -> pure unit
      H.modify_ _ { currentDoc = input.initialDoc }
    -- `tag` is constant per slot, so we only need to store `input`
    -- when it actually changed. Halogen hands us a fresh record on
    -- every parent render; if we blindly stored it, Editor would
    -- re-render on every keystroke even when nothing had changed.
    when (input.tag /= state.input.tag) do
      H.modify_ _ { input = input }
  HandleChange content -> do
    H.modify_ _ { currentDoc = content }
    H.raise (Changed content)

handleQuery
  :: forall m a
   . MonadAff m
  => Query a
  -> H.HalogenM State Action () Output m (Maybe a)
handleQuery = case _ of
  ReplaceContent content next -> do
    state <- H.get
    case state.view of
      Just view -> do
        liftEffect (CM.setContent view content)
        pure (Just next)
      Nothing -> pure (Just next)
  SetErrors spans next -> do
    state <- H.get
    case state.view of
      Just view -> do
        liftEffect (CM.setErrors view spans)
        pure (Just next)
      Nothing -> pure (Just next)
  SetEditable editable next -> do
    state <- H.get
    case state.view of
      Just view -> do
        liftEffect (CM.setEditable view editable)
        pure (Just next)
      Nothing -> pure (Just next)
