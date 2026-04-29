-- | Vocabulary discovery: parses every `.tidal` file in the
-- | purerl-tidal setup directory (typically
-- | `~/work/afc-work/purescript-ports/purerl-tidal/setup`) and surfaces
-- | the declared `midi-device` aliases and `bind` lines.
-- |
-- | Calypso uses the result for autocompletion (binding names appear
-- | in the editor) and for the reference panel (browsable
-- | device→bindings index).
-- |
-- | The setup dir is configurable via the `CALYPSO_TIDAL_SETUP_DIR`
-- | environment variable; if unset, defaults to the canonical path
-- | for this rig.  If the directory doesn't exist, we return an empty
-- | vocabulary rather than fail — first-run shouldn't be loud.
module Calypso.Server.Vocabulary
  ( vocabularyDir
  , listVocabulary
  , parseSetupFile
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.String as Str
import Data.String.Pattern (Pattern(..))
import Data.Traversable (for)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff as Aff
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FSA
import Node.Path as Path
import Node.Process as Process

import Calypso.Vocabulary
  ( Binding(..)
  , BindingKind
  , SetupFile(..)
  , Vocabulary(..)
  , bindingKindFromString
  )

-- | Resolve the setup directory.  `$CALYPSO_TIDAL_SETUP_DIR` wins; if
-- | unset, fall back to the canonical rig path under `$HOME`.
vocabularyDir :: Effect String
vocabularyDir = do
  override <- Process.lookupEnv "CALYPSO_TIDAL_SETUP_DIR"
  case override of
    Just d | not (Str.null d) -> pure d
    _ -> do
      home <- Process.lookupEnv "HOME"
      let base = case home of
            Just h | not (Str.null h) -> h
            _ -> "."
      pure $ Path.concat
        [ base, "work", "afc-work", "purescript-ports", "purerl-tidal", "setup" ]

-- | List vocabulary parsed from every `*.tidal` file in the setup
-- | directory.  Unreadable directory → empty vocabulary.  Per-file
-- | read errors collapse to "no bindings" for that file rather than
-- | aborting the whole listing.
listVocabulary :: String -> Aff Vocabulary
listVocabulary dir = do
  files <- listTidalFiles dir
  setupFiles <- for files \fname -> do
    let path = Path.concat [ dir, fname ]
        name = stripDotTidal fname
    body <- readTextOrEmpty path
    pure (parseSetupFile name body)
  pure (Vocabulary { setupFiles })

-- ============================================================
-- Parser
-- ============================================================

-- | Parse one setup file's contents into a `SetupFile`.  Comment and
-- | blank lines are skipped.  `midi-device` declares the alias + port;
-- | `bind` lines populate `bindings`.  Unrecognized lines are ignored
-- | silently — keeps the parser lenient against future setup-file
-- | features we haven't modelled yet.
parseSetupFile :: String -> String -> SetupFile
parseSetupFile name body =
  let lines = Str.split (Pattern "\n") body
      acc = foldl step initial lines
  in SetupFile
       { name
       , device: acc.device
       , port: acc.port
       , bindings: Array.reverse acc.bindings
       }
  where
    initial = { device: Nothing :: Maybe String, port: Nothing :: Maybe String, bindings: [] :: Array Binding }
    step a rawLine =
      let line = Str.trim rawLine
      in if Str.null line then a
         else if Str.take 2 line == "--" then a
         else case parseMidiDevice line of
           Just dev -> a { device = Just dev.alias, port = Just dev.port }
           Nothing -> case parseBind line of
             Just b -> a { bindings = Array.cons b a.bindings }
             Nothing -> a

parseMidiDevice :: String -> Maybe { alias :: String, port :: String }
parseMidiDevice line = do
  rest <- Str.stripPrefix (Pattern "midi-device ") line
  let trimmed = Str.trim rest
  i <- Str.indexOf (Pattern " ") trimmed
  let alias = Str.take i trimmed
      remainder = Str.trim (Str.drop i trimmed)
      port = stripQuotes remainder
  pure { alias, port }

parseBind :: String -> Maybe Binding
parseBind line = do
  rest <- Str.stripPrefix (Pattern "bind ") line
  let toks = wordsOf rest
  bindFromTokens toks

bindFromTokens :: Array String -> Maybe Binding
bindFromTokens toks = case toks of
  [n, kindStr, dev, chS, numS] -> do
    kind <- bindingKindFromString kindStr
    ch <- Int.fromString chS
    num <- Int.fromString numS
    pure $ mkBinding n kind dev ch num []
  [n, kindStr, dev, chS, numS, e1] -> do
    kind <- bindingKindFromString kindStr
    ch <- Int.fromString chS
    num <- Int.fromString numS
    x1 <- Int.fromString e1
    pure $ mkBinding n kind dev ch num [x1]
  [n, kindStr, dev, chS, numS, e1, e2] -> do
    kind <- bindingKindFromString kindStr
    ch <- Int.fromString chS
    num <- Int.fromString numS
    x1 <- Int.fromString e1
    x2 <- Int.fromString e2
    pure $ mkBinding n kind dev ch num [x1, x2]
  [n, kindStr, dev, chS, numS, e1, e2, e3] -> do
    kind <- bindingKindFromString kindStr
    ch <- Int.fromString chS
    num <- Int.fromString numS
    x1 <- Int.fromString e1
    x2 <- Int.fromString e2
    x3 <- Int.fromString e3
    pure $ mkBinding n kind dev ch num [x1, x2, x3]
  _ -> Nothing

mkBinding :: String -> BindingKind -> String -> Int -> Int -> Array Int -> Binding
mkBinding name kind device channel number extras =
  Binding { name, kind, device, channel, number, extras }

-- | Split on runs of whitespace (spaces and tabs).  Equivalent to
-- | shell `$str` word-splitting for this file format.
wordsOf :: String -> Array String
wordsOf =
  Str.replaceAll (Pattern "\t") (Str.Replacement " ")
    >>> Str.split (Pattern " ")
    >>> Array.filter (not <<< Str.null)

stripQuotes :: String -> String
stripQuotes s = case Str.stripPrefix (Pattern "\"") s of
  Just r -> case Str.stripSuffix (Pattern "\"") r of
    Just inner -> inner
    Nothing -> r
  Nothing -> s

-- ============================================================
-- Filesystem helpers (mirror Favorites.purs)
-- ============================================================

listTidalFiles :: String -> Aff (Array String)
listTidalFiles dir = do
  result <- Aff.attempt (FSA.readdir dir)
  let names = case result of
        Left _ -> []
        Right ns -> ns
  pure (Array.sort (Array.filter isTidalName names))

isTidalName :: String -> Boolean
isTidalName n = case Str.stripSuffix (Pattern ".tidal") n of
  Just _ -> true
  Nothing -> false

readTextOrEmpty :: String -> Aff String
readTextOrEmpty path = do
  result <- Aff.attempt (FSA.readTextFile UTF8 path)
  case result of
    Left e -> do
      liftEffect $ Console.warn $
        "vocabulary: reading " <> path <> " failed: " <> Aff.message e
      pure ""
    Right body -> pure body

stripDotTidal :: String -> String
stripDotTidal s = case Str.stripSuffix (Pattern ".tidal") s of
  Just rest -> rest
  Nothing -> s
