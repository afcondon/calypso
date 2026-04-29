-- | Form-cells v1: display a record-of-primitives cell as a typed
-- | form instead of a code editor. The cell `source` stays
-- | authoritative — form edits regenerate it as a canonical record
-- | literal.
-- |
-- | v1 type vocabulary: `Number`, `Int`, `String`, `Boolean` only,
-- | and only at the top level of a record (no nesting, no sums, no
-- | arrays, no optionals). Anything outside that vocabulary returns
-- | `Nothing` from `analyseType`, which means the form toggle simply
-- | doesn't appear on the cell.
module Playground.Frontend.FormCell
  ( FieldKind(..)
  , FieldSpec
  , analyseType
  , parseRecordLiteral
  , printRecordLiteral
  , regenerateRecordSource
  , defaultValueFor
  , coerceFieldValue
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as Str
import Data.String.CodeUnits as SCU
import Data.String.Pattern (Pattern(..))
import Data.Tuple (Tuple(..))
import Sigil.Parse (parseToRenderType)
import Sigil.Types (RenderType(..))

-- | Primitive field kinds we know how to render and round-trip.
data FieldKind = FNumber | FInt | FString | FBoolean

derive instance Eq FieldKind

type FieldSpec = { name :: String, kind :: FieldKind }

-- | Parse a type signature string and report its fields if (and only
-- | if) it is a top-level record of supported primitives. Returns the
-- | fields in source order; returns `Nothing` for anything else.
analyseType :: String -> Maybe (Array FieldSpec)
analyseType raw = do
  ast <- parseToRenderType (Str.trim raw)
  fields <- case ast of
    TRecord rs Nothing -> Just rs
    TParens (TRecord rs Nothing) -> Just rs
    _ -> Nothing
  traverseSpecs fields
  where
  traverseSpecs rs = case Array.foldM step [] rs of
    Just specs -> Just (Array.reverse specs)
    Nothing -> Nothing
  step acc rf = do
    k <- kindFromRenderType rf.value
    Just (Array.cons { name: rf.label, kind: k } acc)

kindFromRenderType :: RenderType -> Maybe FieldKind
kindFromRenderType = case _ of
  TCon "Number" -> Just FNumber
  TCon "Int" -> Just FInt
  TCon "String" -> Just FString
  TCon "Boolean" -> Just FBoolean
  TParens t -> kindFromRenderType t
  _ -> Nothing

-- | A value to seed the form when no current source value can be
-- | parsed for a given field. Chosen to compile cleanly under each
-- | primitive type: `0.0` / `0` / `""` / `false`.
defaultValueFor :: FieldKind -> String
defaultValueFor = case _ of
  FNumber -> "0.0"
  FInt -> "0"
  FString -> ""
  FBoolean -> "false"

-- | Validate / normalise a user-typed value so the regenerated source
-- | type-checks. Numbers and ints ignore non-numeric input (return
-- | Nothing → caller falls back to the previous value); booleans
-- | accept "true"/"false"; strings pass through verbatim.
coerceFieldValue :: FieldKind -> String -> Maybe String
coerceFieldValue kind raw = case kind of
  FNumber ->
    -- Allow trailing `.` mid-typing ("1." → reformat to "1.0" only on
    -- regen; keep the user's literal characters during entry).
    if isNumberish raw then Just raw else Nothing
  FInt ->
    if isIntish raw then Just raw else Nothing
  FBoolean -> case raw of
    "true" -> Just "true"
    "false" -> Just "false"
    _ -> Nothing
  FString -> Just raw

isNumberish :: String -> Boolean
isNumberish s =
  let t = Str.trim s
  in t /= "" && Array.all isNumChar (SCU.toCharArray t)
  where
  isNumChar c =
    let n = SCU.singleton c
    in n == "-" || n == "+" || n == "." || n == "e" || n == "E"
       || (n >= "0" && n <= "9")

isIntish :: String -> Boolean
isIntish s =
  let t = Str.trim s
  in t /= "" && Array.all isIntChar (SCU.toCharArray t)
  where
  isIntChar c =
    let n = SCU.singleton c
    in n == "-" || n == "+" || (n >= "0" && n <= "9")

-- | Parse a record literal source like `{ a: 1.0, b: "hi", c: true }`
-- | into an association list (preserving order). Returns `Nothing` if
-- | the source isn't a single brace-delimited record literal.
-- |
-- | v1 scope: hand-rolled scanner. Handles unquoted keys, double-quoted
-- | string values (no escapes beyond `\"`), and bare numeric / boolean
-- | tokens. Whitespace flexible. Doesn't try to parse expressions on
-- | the right-hand side — anything that isn't a primitive literal
-- | comes back as the raw token (which may not coerce later, in which
-- | case the form just shows the field as empty).
parseRecordLiteral :: String -> Maybe (Array (Tuple String String))
parseRecordLiteral raw =
  let trimmed = Str.trim raw
  in case Str.stripPrefix (Pattern "{") trimmed of
       Nothing -> Nothing
       Just rest1 -> case Str.stripSuffix (Pattern "}") (Str.trim rest1) of
         Nothing -> Nothing
         Just inside ->
           let body = Str.trim inside
           in if body == ""
                then Just []
                else parseEntries body

parseEntries :: String -> Maybe (Array (Tuple String String))
parseEntries body =
  let segs = splitTopLevelCommas body
      parsed = map parseEntry segs
  in if Array.all isJustEntry parsed
       then Just (Array.mapMaybe identity parsed)
       else Nothing
  where
  isJustEntry = case _ of
    Just _ -> true
    Nothing -> false

parseEntry :: String -> Maybe (Tuple String String)
parseEntry raw =
  let s = Str.trim raw
  in case Str.indexOf (Pattern ":") s of
       Nothing -> Nothing
       Just i ->
         let key = Str.trim (Str.take i s)
             val = Str.trim (Str.drop (i + 1) s)
         in if key == "" then Nothing else Just (Tuple key (unquote val))

-- | Strip enclosing double-quotes from a string literal value, if
-- | present. Bare numeric / boolean tokens pass through unchanged.
unquote :: String -> String
unquote s = case Str.stripPrefix (Pattern "\"") s of
  Nothing -> s
  Just rest -> case Str.stripSuffix (Pattern "\"") rest of
    Nothing -> s
    Just inner -> inner

-- | Split a record body on top-level commas, ignoring commas inside
-- | matched braces / brackets / parens / double-quoted strings. v1 is
-- | flat, but the splitter is brace-aware so it doesn't break the day
-- | someone has a nested literal in their source.
splitTopLevelCommas :: String -> Array String
splitTopLevelCommas s =
  let chars = SCU.toCharArray s
  in splitGo chars 0 "" 0 false false []

splitGo
  :: Array Char
  -> Int
  -> String
  -> Int
  -> Boolean
  -> Boolean
  -> Array String
  -> Array String
splitGo chars idx current depth inString escape acc =
  case Array.index chars idx of
    Nothing ->
      let trimmed = Str.trim current
      in if trimmed == "" then acc else Array.snoc acc trimmed
    Just c ->
      let cs = SCU.singleton c
      in if escape
           then splitGo chars (idx + 1) (current <> cs) depth inString false acc
         else if inString
           then case cs of
             "\\" -> splitGo chars (idx + 1) (current <> cs) depth true true acc
             "\"" -> splitGo chars (idx + 1) (current <> cs) depth false false acc
             _ -> splitGo chars (idx + 1) (current <> cs) depth true false acc
         else case cs of
           "\"" -> splitGo chars (idx + 1) (current <> cs) depth true false acc
           "{" -> splitGo chars (idx + 1) (current <> cs) (depth + 1) false false acc
           "[" -> splitGo chars (idx + 1) (current <> cs) (depth + 1) false false acc
           "(" -> splitGo chars (idx + 1) (current <> cs) (depth + 1) false false acc
           "}" -> splitGo chars (idx + 1) (current <> cs) (depth - 1) false false acc
           "]" -> splitGo chars (idx + 1) (current <> cs) (depth - 1) false false acc
           ")" -> splitGo chars (idx + 1) (current <> cs) (depth - 1) false false acc
           "," ->
             if depth == 0
               then splitGo chars (idx + 1) "" 0 false false (Array.snoc acc (Str.trim current))
               else splitGo chars (idx + 1) (current <> cs) depth false false acc
           _ -> splitGo chars (idx + 1) (current <> cs) depth false false acc

-- | Print a list of (field-spec, raw value) back as a canonical
-- | PureScript record literal. Values are formatted per kind: numbers
-- | are normalised to include a decimal point ("1" → "1.0"), strings
-- | are double-quoted, ints / booleans are bare. The output uses
-- | single-line form for v1 — `{ a: 1.0, b: "hi", c: true }`.
printRecordLiteral :: Array { spec :: FieldSpec, raw :: String } -> String
printRecordLiteral entries =
  if Array.null entries
    then "{}"
    else
      let body = Str.joinWith ", " (map renderEntry entries)
      in "{ " <> body <> " }"
  where
  renderEntry e = e.spec.name <> ": " <> formatValue e.spec.kind e.raw

formatValue :: FieldKind -> String -> String
formatValue kind raw = case kind of
  FNumber ->
    let t = Str.trim raw
    in if t == "" then "0.0"
       else if Str.contains (Pattern ".") t || Str.contains (Pattern "e") t || Str.contains (Pattern "E") t
              then t
              else t <> ".0"
  FInt ->
    let t = Str.trim raw
    in if t == "" then "0" else t
  FString -> "\"" <> escapeString raw <> "\""
  FBoolean -> case Str.trim raw of
    "true" -> "true"
    _ -> "false"

escapeString :: String -> String
escapeString =
  Str.replaceAll (Pattern "\\") (replacement "\\\\")
    >>> Str.replaceAll (Pattern "\"") (replacement "\\\"")
  where
  replacement s = wrap s

-- Helper: Data.String.Replacement constructor lives behind a newtype;
-- we just need the type-aligned wrapper. Inline cast via FFI-free
-- wrapping isn't possible here, so use the imported newtype below.
wrap :: String -> Str.Replacement
wrap = Str.Replacement

-- | High-level glue used by the Action handler: given a cell's type,
-- | its current source, the field being edited, and the user's new
-- | input string, return the regenerated canonical source — or
-- | `Nothing` if the type isn't form-compatible or the input doesn't
-- | coerce cleanly.
regenerateRecordSource :: String -> String -> String -> String -> Maybe String
regenerateRecordSource typeStr currentSource field newRaw = do
  specs <- analyseType typeStr
  fieldSpec <- Array.find (\s -> s.name == field) specs
  coerced <- coerceFieldValue fieldSpec.kind newRaw
  let existing = fromMaybe [] (parseRecordLiteral currentSource)
      lookup name =
        case Array.find (\(Tuple k _) -> k == name) existing of
          Just (Tuple _ v) -> v
          Nothing -> defaultValueFor (fromMaybe FString (kindFor name specs))
      kindFor name ss = map _.kind (Array.find (\s -> s.name == name) ss)
      entries = map
        ( \s ->
            { spec: s
            , raw: if s.name == field then coerced else lookup s.name
            }
        )
        specs
  Just (printRecordLiteral entries)
