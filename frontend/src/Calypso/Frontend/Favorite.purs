-- | Frontend-side favorites: fetch the list from `GET /favorites` and
-- | look up a favorite by key.  Replaces the Atelier-shaped
-- | `Calypso.Frontend.Starter` (which hardcoded PureScript starter
-- | content); favorites are pulled from `~/.calypso/favorites/` on the
-- | server, so anything the user drops there is immediately
-- | available in the dropdown after a reload.
module Calypso.Frontend.Favorite
  ( fetchFavorites
  , findByKey
  ) where

import Prelude

import Affjax.ResponseFormat as RF
import Affjax.Web (defaultRequest, request) as AX
import Data.Array as Array
import Data.Codec.Argonaut as CA
import Data.Either (Either(..))
import Data.HTTP.Method (Method(..))
import Data.Maybe (Maybe)
import Effect.Aff (Aff)

import Calypso.Favorite (Favorite(..), favoritesCodec)
import Calypso.Frontend.Config (backendUrl)

-- | Fetch the favorites list from the backend.  On any transport or
-- | decode failure returns `[]` so the dropdown silently degrades to
-- | empty rather than blocking page hydration.
fetchFavorites :: Aff (Array Favorite)
fetchFavorites = do
  result <- AX.request $ AX.defaultRequest
    { method = Left GET
    , url = backendUrl <> "/favorites"
    , responseFormat = RF.json
    }
  pure case result of
    Left _ -> []
    Right { body } -> case CA.decode favoritesCodec body of
      Left _ -> []
      Right favs -> favs

findByKey :: String -> Array Favorite -> Maybe Favorite
findByKey k = Array.find (\(Favorite f) -> f.key == k)
