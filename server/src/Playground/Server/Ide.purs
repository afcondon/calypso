module Playground.Server.Ide
  ( queryType
  , queryComplete
  , queryCellTypes
  , querySearch
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Data.Argonaut.Core (stringify)
import Data.Codec.Argonaut as CA
import Effect (Effect)
import Effect.Aff (Aff)

import Playground.Session (CellType, IdeHit)

-- | Look up the type(s) of a given identifier. Returns an array because
-- | the same name may resolve in more than one module.
foreign import _queryType :: String -> Effect (Promise (Array IdeHit))

-- | Completion candidates matching a prefix.
foreign import _queryComplete :: String -> Effect (Promise (Array IdeHit))

-- | Find-by-type: approximate match against a type signature string.
foreign import _querySearch :: String -> Effect (Promise (Array IdeHit))

-- | Look up types for a batch of cell ids (pre-synthesis naming — the
-- | underlying lookup prepends `cell_`). Used by the compile pipeline to
-- | populate the response's per-cell types.
foreign import _queryCellTypes :: String -> Effect (Promise (Array CellType))

queryType :: String -> Aff (Array IdeHit)
queryType q = toAffE (_queryType q)

queryComplete :: String -> Aff (Array IdeHit)
queryComplete q = toAffE (_queryComplete q)

querySearch :: String -> Aff (Array IdeHit)
querySearch q = toAffE (_querySearch q)

-- Takes an Array of cell ids; encodes to JSON to cross the FFI
-- boundary, then the JS side JSON.parse's the list.
queryCellTypes :: Array String -> Aff (Array CellType)
queryCellTypes ids =
  let idsJson = stringify (CA.encode (CA.array CA.string) ids)
  in toAffE (_queryCellTypes idsJson)
