module Playground.Frontend.Value
  ( PlaygroundValue(..)
  , parse
  , encode
  ) where

import Prelude

import Control.Alt ((<|>))
import Data.Argonaut.Core (Json, stringify)
import Data.Argonaut.Core as AJ
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object

-- | Structured cell values arriving from the runtime. Wire format is
-- | agreed with `Playground.Runtime.PlaygroundValue` (in the runtime
-- | workspace) — see its encode function for the canonical shape.
data PlaygroundValue
  = PVNull
  | PVBool Boolean
  | PVNumber Number
  | PVString String
  | PVArray (Array PlaygroundValue)
  | PVCtor String (Array PlaygroundValue)
  | PVRecord (Array (Tuple String PlaygroundValue))
  | PVRaw String

-- | Parse a JSON string coming from the emit channel. Anything that
-- | doesn't round-trip cleanly falls through to `PVRaw` so we never
-- | lose the value — it just renders as plain text instead of a
-- | typographic structure.
parse :: String -> PlaygroundValue
parse s = case jsonParser s of
  Left _ -> PVRaw s
  Right json -> case fromJson json of
    Just v -> v
    Nothing -> PVRaw s

-- | Re-serialise a parsed value back to JSON. Mirror of the runtime's
-- | encode; used by the render column to hand a single JSON blob to its
-- | JS dispatch layer instead of walking a PureScript ADT in FFI.
encode :: PlaygroundValue -> String
encode = stringify <<< toJson

toJson :: PlaygroundValue -> Json
toJson = case _ of
  PVNull -> AJ.jsonNull
  PVBool b -> AJ.fromBoolean b
  PVNumber n -> AJ.fromNumber n
  PVString s -> AJ.fromString s
  PVArray xs -> AJ.fromArray (map toJson xs)
  PVCtor name args -> AJ.fromObject $ Object.fromFoldable
    [ Tuple "$ctor" (AJ.fromString name)
    , Tuple "args" (AJ.fromArray (map toJson args))
    ]
  PVRecord fields -> AJ.fromObject $ Object.singleton "$record"
    (AJ.fromObject (Object.fromFoldable (map (\(Tuple k v) -> Tuple k (toJson v)) fields)))
  PVRaw s -> AJ.fromObject (Object.singleton "$raw" (AJ.fromString s))

fromJson :: Json -> Maybe PlaygroundValue
fromJson j =
  caseNull
    <|> caseBool
    <|> caseNumber
    <|> caseString
    <|> caseArray
    <|> caseObject
  where
  caseNull = if AJ.isNull j then Just PVNull else Nothing
  caseBool = PVBool <$> AJ.toBoolean j
  caseNumber = PVNumber <$> AJ.toNumber j
  caseString = PVString <$> AJ.toString j
  caseArray = (AJ.toArray j) >>= \xs -> PVArray <$> traverse fromJson xs
  caseObject = AJ.toObject j >>= fromObject

fromObject :: Object Json -> Maybe PlaygroundValue
fromObject o =
  -- { "$ctor": "Name", "args": [...] }
  case Object.lookup "$ctor" o, Object.lookup "args" o of
    Just cj, Just aj
      | Just name <- AJ.toString cj
      , Just args <- AJ.toArray aj ->
          PVCtor name <$> traverse fromJson args
    _, _ ->
      -- { "$record": { "field1": <value>, "field2": <value>, ... } }
      case Object.lookup "$record" o of
        Just rj | Just inner <- AJ.toObject rj ->
          PVRecord <$> traverse decodeField (Object.toUnfoldable inner)
        _ ->
          -- { "$raw": "string" }
          case Object.lookup "$raw" o of
            Just rj | Just s <- AJ.toString rj -> Just (PVRaw s)
            _ -> Nothing
  where
  decodeField (Tuple k v) = Tuple k <$> fromJson v
