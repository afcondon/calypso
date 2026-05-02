module Calypso.Frontend.CodeMirror
  ( EditorView
  , ErrorSpan
  , createEditor
  , getContent
  , setContent
  , destroy
  , setErrors
  , setEditable
  , setProposals
  , setVocabulary
  , getCursorLine
  , getLineText
  ) where

import Prelude

import Data.Array (mapWithIndex)
import Data.Array as Array
import Data.Maybe (fromMaybe)
import Effect (Effect)
import Effect.Uncurried (EffectFn1, EffectFn2, mkEffectFn1, mkEffectFn2)
import Web.DOM (Element)

import Calypso.Frontend.Completion (Completion)
import Calypso.Proposal (Hunk(..), Proposal(..), ProposalId(..), unProposalId)

foreign import data EditorView :: Type

type ErrorSpan =
  { startLine :: Int
  , startColumn :: Int
  , endLine :: Int
  , endColumn :: Int
  , message :: String
  }

-- | JS-friendly per-hunk view used by the ghost-line rendering.  The
-- | JS doesn't need to know about ProposalTarget (the parent already
-- | filtered to the right editor) or createdAt or basedOn — those
-- | matter at the protocol layer, not the visual one.
type HunkView =
  { proposalId :: String
  , hunkIdx :: Int
  , author :: String
  , prompt :: String      -- empty string when no prompt was set
  , startLine :: Int
  , removed :: Array String
  , added :: Array String
  }

foreign import _createEditor
  :: Element
  -> String
  -> EffectFn1 String Unit       -- doc-change callback
  -> EffectFn1 String Unit       -- submit callback (Mod-Enter)
  -> EffectFn2 String Int Unit   -- accept-hunk callback (proposalId, hunkIdx)
  -> EffectFn2 String Int Unit   -- reject-hunk callback
  -> Effect Unit                 -- move callback (Mod-Shift-Enter)
  -> EffectFn1 String String     -- type-string -> tooltip HTML (unused)
  -> Effect EditorView

foreign import _getContent :: EditorView -> Effect String

foreign import _setContent :: EditorView -> String -> Effect Unit

foreign import _destroy :: EditorView -> Effect Unit

foreign import _setErrors :: EditorView -> Array ErrorSpan -> Effect Unit

foreign import _setEditable :: EditorView -> Boolean -> Effect Unit

foreign import _setProposals :: EditorView -> Array HunkView -> Effect Unit

foreign import _setVocabulary :: EditorView -> Array Completion -> Effect Unit

foreign import _getCursorLine :: EditorView -> Effect Int

foreign import _getLineText :: EditorView -> Int -> Effect String

setVocabulary :: EditorView -> Array Completion -> Effect Unit
setVocabulary = _setVocabulary

getCursorLine :: EditorView -> Effect Int
getCursorLine = _getCursorLine

getLineText :: EditorView -> Int -> Effect String
getLineText = _getLineText

createEditor
  :: Element
  -> String
  -> (String -> Effect Unit)
  -> (String -> Effect Unit)
  -> (ProposalId -> Int -> Effect Unit)
  -> (ProposalId -> Int -> Effect Unit)
  -> Effect Unit
  -> Effect EditorView
createEditor el initialDoc onChange onSubmit onAccept onReject onMove =
  _createEditor el initialDoc
    (mkEffectFn1 onChange)
    (mkEffectFn1 onSubmit)
    (mkEffectFn2 (\pidStr idx -> onAccept (ProposalId pidStr) idx))
    (mkEffectFn2 (\pidStr idx -> onReject (ProposalId pidStr) idx))
    onMove
    (mkEffectFn1 (\s -> pure ("<code class=\"cm-tooltip-fallback\">" <> s <> "</code>")))

setErrors :: EditorView -> Array ErrorSpan -> Effect Unit
setErrors = _setErrors

setEditable :: EditorView -> Boolean -> Effect Unit
setEditable = _setEditable

getContent :: EditorView -> Effect String
getContent = _getContent

setContent :: EditorView -> String -> Effect Unit
setContent = _setContent

destroy :: EditorView -> Effect Unit
destroy = _destroy

-- | Project proposals to JS-friendly per-hunk views and push them to
-- | the editor.  Caller has already filtered proposals to those
-- | targeting this editor; we don't re-check here.
setProposals :: EditorView -> Array Proposal -> Effect Unit
setProposals view proposals =
  _setProposals view (Array.concatMap hunksOf proposals)
  where
  hunksOf (Proposal p) =
    mapWithIndex
      (\i (Hunk h) ->
        { proposalId: unProposalId p.id
        , hunkIdx: i
        , author: p.author
        , prompt: fromMaybe "" p.prompt
        , startLine: h.startLine
        , removed: h.removed
        , added: h.added
        })
      p.hunks
