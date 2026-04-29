module Playground.Server.Compile
  ( compile
  , compileSources
  ) where

import Prelude

import Data.Argonaut.Core (stringify)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect.Aff (Aff)

import Playground.Server.Adapter (Adapter)
import Playground.Server.Ide as Ide
import Playground.Session
  ( Cell
  , CellEmit
  , CellRange
  , CompileError(..)
  , CompileResponse(..)
  , UserModule
  , cellEmitCodec
  , compileErrorCodec
  , compileResponseCodec
  , nullableStringCodec
  )

-- | Intermediate record an Adapter returns over the FFI.
type BuildResult =
  { js :: Maybe String
  , warnings :: Array CompileError
  , errors :: Array CompileError
  , cellIds :: Array String
  , emits :: Array CellEmit
  }

buildResultCodec :: CA.JsonCodec BuildResult
buildResultCodec = CAR.object "BuildResult"
  { js: nullableStringCodec
  , warnings: CA.array compileErrorCodec
  , errors: CA.array compileErrorCodec
  , cellIds: CA.array CA.string
  , emits: CA.array cellEmitCodec
  }

mkTransportError :: String -> CompileError
mkTransportError msg = CompileError
  { code: "Transport"
  , filename: Nothing
  , position: Nothing
  , message: msg
  }

-- | Typed compile: runs the adapter + Ide query, returns a
-- | structured CompileResponse. Used by Session.purs so we can
-- | cache the typed snapshot.
compile
  :: Adapter
  -> String
  -> String
  -> { userSource :: String
     , mainSource :: String
     , cellLines :: Array CellRange
     , module :: UserModule
     , cells :: Array Cell
     }
  -> Aff CompileResponse
compile adapter workspaceDir packageName s = do
  raw <- adapter.bundle workspaceDir packageName s.userSource s.mainSource
  case CA.decode buildResultCodec raw of
    Left e ->
      pure $ CompileResponse
        { js: Nothing
        , warnings: []
        , errors:
            [ mkTransportError
                ("adapter " <> adapter.name <> " returned undecodable BuildResult: " <> CA.printJsonDecodeError e)
            ]
        , types: []
        , cellLines: s.cellLines
        , emits: []
        , runtime: adapter.name
        , "module": s."module"
        , cells: s.cells
        }
    Right r -> do
      types <-
        if adapter.name == "purerl" then pure []
        else case r.js of
          Just _ -> Ide.queryCellTypes r.cellIds
          Nothing ->
            if not (null r.errors) then pure []
            else Ide.queryCellTypes r.cellIds
      pure $ CompileResponse
        { js: r.js
        , warnings: r.warnings
        , errors: r.errors
        , types
        , cellLines: s.cellLines
        , emits: r.emits
        , runtime: adapter.name
        , "module": s."module"
        , cells: s.cells
        }
  where
  null xs = case xs of
    [] -> true
    _ -> false

-- | HTTP-path version: same shape as before (returns a JSON string)
-- | kept for the POST /session/compile handler in Main.purs that
-- | historically wrapped the adapter result into JSON. New code
-- | should prefer `compile` and stringify where needed.
compileSources
  :: Adapter
  -> String
  -> String
  -> { userSource :: String
     , mainSource :: String
     , cellLines :: Array CellRange
     , module :: UserModule
     , cells :: Array Cell
     }
  -> Aff String
compileSources adapter workspaceDir packageName s = do
  resp <- compile adapter workspaceDir packageName s
  pure (stringify (CA.encode compileResponseCodec resp))
