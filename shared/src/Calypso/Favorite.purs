-- | Favorites: durable composition-pane templates the user keeps in
-- | `~/.calypso/favorites/`.  Each `.tidal` file in that directory
-- | becomes one entry; the dropdown lists them and clicking loads the
-- | file body into the composition pane (cells stay empty — favorites
-- | are templates, not full sessions).
module Calypso.Favorite
  ( Favorite(..)
  , favoriteCodec
  , favoritesCodec
  ) where

import Prelude

import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Maybe (Maybe(..))

newtype Favorite = Favorite
  { key :: String     -- stable id; the filename without extension
  , label :: String   -- display name; the filename without extension
  , body :: String    -- the file's text content
  }

favoriteCodec :: JsonCodec Favorite
favoriteCodec = CA.prismaticCodec "Favorite" (Just <<< Favorite) un $
  CAR.object "Favorite"
    { key: CA.string
    , label: CA.string
    , body: CA.string
    }
  where un (Favorite r) = r

favoritesCodec :: JsonCodec (Array Favorite)
favoritesCodec = CA.array favoriteCodec
