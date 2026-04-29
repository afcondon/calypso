module Playground.Frontend.CodeMirror
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

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Uncurried (EffectFn1, mkEffectFn1)
import Web.DOM (Element)

import Sigil.Html (renderBody)
import Sigil.Parse (parseToRenderType)

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
  -> EffectFn1 String String     -- type-string -> Sigil HTML (for hover)
  -> Effect EditorView

foreign import _getContent :: EditorView -> Effect String

foreign import _setContent :: EditorView -> String -> Effect Unit

foreign import _destroy :: EditorView -> Effect Unit

foreign import _setErrors :: EditorView -> Array ErrorSpan -> Effect Unit

foreign import _setEditable :: EditorView -> Boolean -> Effect Unit

-- | Hover-tooltip renderer: parses a `purs ide` type string and emits
-- | Sigil HTML. JS calls this synchronously from the hover callback;
-- | falls back to a plain `<code>` if Sigil can't parse the input.
renderTypeHtml :: String -> String
renderTypeHtml typeStr = case parseToRenderType typeStr of
  Just ast -> renderBody { ast }
  Nothing ->
    "<code class=\"cm-tooltip-fallback\">" <> typeStr <> "</code>"

createEditor
  :: Element
  -> String
  -> (String -> Effect Unit)
  -> Effect EditorView
createEditor el initialDoc onChange =
  _createEditor el initialDoc
    (mkEffectFn1 onChange)
    (mkEffectFn1 (\s -> pure (renderTypeHtml s)))

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
