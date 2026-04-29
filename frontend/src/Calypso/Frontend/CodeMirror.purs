module Calypso.Frontend.CodeMirror
  ( EditorView
  , ErrorSpan
  , createEditor
  , getContent
  , setContent
  , destroy
  , setErrors
  , setEditable
  ) where

import Prelude

import Effect (Effect)
import Effect.Uncurried (EffectFn1, mkEffectFn1)
import Web.DOM (Element)

foreign import data EditorView :: Type

type ErrorSpan =
  { startLine :: Int
  , startColumn :: Int
  , endLine :: Int
  , endColumn :: Int
  , message :: String
  }

foreign import _createEditor
  :: Element
  -> String
  -> EffectFn1 String Unit       -- doc-change callback
  -> EffectFn1 String Unit       -- submit callback (Mod-Enter)
  -> EffectFn1 String String     -- type-string -> tooltip HTML (unused)
  -> Effect EditorView

foreign import _getContent :: EditorView -> Effect String

foreign import _setContent :: EditorView -> String -> Effect Unit

foreign import _destroy :: EditorView -> Effect Unit

foreign import _setErrors :: EditorView -> Array ErrorSpan -> Effect Unit

foreign import _setEditable :: EditorView -> Boolean -> Effect Unit

-- | Hover-tooltip renderer.  Calypso has no types to render in
-- | tooltips, so this is a plain-code fallback.  Kept on the FFI
-- | surface because the JS bridge still expects a callback.
createEditor
  :: Element
  -> String
  -> (String -> Effect Unit)
  -> (String -> Effect Unit)
  -> Effect EditorView
createEditor el initialDoc onChange onSubmit =
  _createEditor el initialDoc
    (mkEffectFn1 onChange)
    (mkEffectFn1 onSubmit)
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
