-- | Frontend-side vocabulary: fetch the parsed setup-file index from
-- | `GET /vocabulary`.  The result drives autocomplete (binding +
-- | device names) and the reference panel.
-- |
-- | On any transport or decode failure we return an empty vocabulary
-- | rather than block page hydration — the editor must remain
-- | usable even if the server can't reach the setup directory.
module Calypso.Frontend.Vocabulary
  ( fetchVocabulary
  , emptyVocabulary
  ) where

import Prelude

import Affjax.ResponseFormat as RF
import Affjax.Web (defaultRequest, request) as AX
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.HTTP.Method (Method(..))
import Effect.Aff (Aff)

import Calypso.Frontend.Config (backendUrl)
import Calypso.Vocabulary (Vocabulary(..), vocabularyCodec)

emptyVocabulary :: Vocabulary
emptyVocabulary = Vocabulary { setupFiles: [] }

fetchVocabulary :: Aff Vocabulary
fetchVocabulary = do
  result <- AX.request $ AX.defaultRequest
    { method = Left GET
    , url = backendUrl <> "/vocabulary"
    , responseFormat = RF.json
    }
  pure case result of
    Left _ -> emptyVocabulary
    Right { body } -> case CA.decode vocabularyCodec body of
      Left _ -> emptyVocabulary
      Right v -> v
