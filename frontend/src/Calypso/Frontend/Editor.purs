module Calypso.Frontend.Editor
  ( component
  , Input
  , Output(..)
  , Query(..)
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import Web.HTML.HTMLElement (toElement)

import Calypso.Frontend.CodeMirror (EditorView)
import Calypso.Frontend.CodeMirror as CM
import Calypso.Frontend.Completion (Completion)
import Calypso.Proposal (Proposal, ProposalId)

type Input =
  { initialDoc :: String
  , tag :: String
  , vocabulary :: Array Completion
  }

-- | Editor outputs.  `Changed` fires on every document edit (parent
-- | typically debounces and persists).  `Submitted` fires on the
-- | explicit fire gesture (Mod-Enter): the cell or composition body
-- | should be sent to the daemon.  `AcceptHunkO` / `RejectHunkO`
-- | fire when the user clicks the corresponding ghost-line button
-- | inside the editor; the parent translates them into HTTP calls
-- | against /proposals/:id/hunks/:idx/{accept,reject}.
data Output
  = Changed String
  | Submitted String
  | AcceptHunkO ProposalId Int
  | RejectHunkO ProposalId Int

-- | External queries: replace content (unused now), push a list of
-- | inline error spans to be decorated on the editor, toggle whether
-- | the view accepts user input, push the current pending-proposals
-- | list (this editor only renders the slice for its own target).
data Query a
  = ReplaceContent String a
  | SetErrors (Array CM.ErrorSpan) a
  | SetEditable Boolean a
  | SetProposals (Array Proposal) a
  | SetVocabulary (Array Completion) a

data Action
  = Initialise
  | Finalise
  | UpdateInput Input
  | HandleChange String
  | HandleSubmit String
  | HandleAccept ProposalId Int
  | HandleReject ProposalId Int

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
        { emitter: changeEmitter, listener: changeListener } <- liftEffect HS.create
        _ <- H.subscribe (HandleChange <$> changeEmitter)
        { emitter: submitEmitter, listener: submitListener } <- liftEffect HS.create
        _ <- H.subscribe (HandleSubmit <$> submitEmitter)
        { emitter: acceptEmitter, listener: acceptListener } <- liftEffect HS.create
        _ <- H.subscribe ((\(Tuple pid idx) -> HandleAccept pid idx) <$> acceptEmitter)
        { emitter: rejectEmitter, listener: rejectListener } <- liftEffect HS.create
        _ <- H.subscribe ((\(Tuple pid idx) -> HandleReject pid idx) <$> rejectEmitter)
        view <- liftEffect $
          CM.createEditor el state.input.initialDoc
            (HS.notify changeListener)
            (HS.notify submitListener)
            (\pid idx -> HS.notify acceptListener (Tuple pid idx))
            (\pid idx -> HS.notify rejectListener (Tuple pid idx))
        liftEffect (CM.setVocabulary view state.input.vocabulary)
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
    -- Push vocabulary down whenever the parent's array changes
    -- (typically once, after the initial /vocabulary fetch settles).
    -- Array equality is cheap given completion counts in the low
    -- hundreds; if this becomes a hot path we can hash + version.
    when (input.vocabulary /= state.input.vocabulary) do
      case state.view of
        Just view -> liftEffect (CM.setVocabulary view input.vocabulary)
        Nothing -> pure unit
      H.modify_ _ { input = input }
  HandleChange content -> do
    H.modify_ _ { currentDoc = content }
    H.raise (Changed content)
  HandleSubmit content ->
    H.raise (Submitted content)
  HandleAccept pid idx -> H.raise (AcceptHunkO pid idx)
  HandleReject pid idx -> H.raise (RejectHunkO pid idx)

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
  SetProposals proposals next -> do
    state <- H.get
    case state.view of
      Just view -> do
        liftEffect (CM.setProposals view proposals)
        pure (Just next)
      Nothing -> pure (Just next)
  SetVocabulary completions next -> do
    state <- H.get
    case state.view of
      Just view -> do
        liftEffect (CM.setVocabulary view completions)
        pure (Just next)
      Nothing -> pure (Just next)
