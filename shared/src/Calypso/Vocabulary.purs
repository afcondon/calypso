-- | The "vocabulary" available to the live-coder: every binding (and
-- | the device it's bound to) declared in the purerl-tidal setup
-- | files at `<beam-cwd>/setup/*.tidal`.
-- |
-- | Calypso parses these files and surfaces the result via
-- | `GET /vocabulary` so the frontend can autocomplete identifiers,
-- | render the reference-panel device→bindings index, and (eventually)
-- | filter suggestions by which `load <name>` calls are in the current
-- | composition.
module Calypso.Vocabulary
  ( Vocabulary(..)
  , SetupFile(..)
  , Binding(..)
  , BindingKind(..)
  , vocabularyCodec
  , bindingKindToString
  , bindingKindFromString
  ) where

import Prelude

import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Compat as CAC
import Data.Codec.Argonaut.Record as CAR
import Data.Maybe (Maybe(..))
import Data.Profunctor (dimap)

-- | One `.tidal` file in the setup directory.  `name` is the stem
-- | (e.g. `laplace` for `setup/laplace.tidal`) — what `load <name>`
-- | references.  `device` and `port` come from the file's
-- | `midi-device` declaration; `bindings` from each `bind` line.
newtype SetupFile = SetupFile
  { name :: String
  , device :: Maybe String
  , port :: Maybe String
  , bindings :: Array Binding
  }

derive instance Eq SetupFile

-- | One `bind <name> midi-(note|cc) <device> ...` line.  We only
-- | model what autocomplete + the reference panel need; if the
-- | line has trailing fields we don't understand we keep them in
-- | `extras` rather than fail the parse.
newtype Binding = Binding
  { name :: String
  , kind :: BindingKind
  , device :: String
  , channel :: Int
  , number :: Int
  , extras :: Array Int
  }

derive instance Eq Binding

data BindingKind = MidiNote | MidiCc

derive instance Eq BindingKind

bindingKindToString :: BindingKind -> String
bindingKindToString = case _ of
  MidiNote -> "midi-note"
  MidiCc -> "midi-cc"

bindingKindFromString :: String -> Maybe BindingKind
bindingKindFromString = case _ of
  "midi-note" -> Just MidiNote
  "midi-cc" -> Just MidiCc
  _ -> Nothing

newtype Vocabulary = Vocabulary
  { setupFiles :: Array SetupFile
  }

derive instance Eq Vocabulary

-- ============================================================
-- Codecs
-- ============================================================

bindingKindCodec :: JsonCodec BindingKind
bindingKindCodec = CA.prismaticCodec "BindingKind"
  bindingKindFromString
  bindingKindToString
  CA.string

bindingCodec :: JsonCodec Binding
bindingCodec = dimap un Binding $
  CAR.object "Binding"
    { name: CA.string
    , kind: bindingKindCodec
    , device: CA.string
    , channel: CA.int
    , number: CA.int
    , extras: CA.array CA.int
    }
  where un (Binding r) = r

setupFileCodec :: JsonCodec SetupFile
setupFileCodec = dimap un SetupFile $
  CAR.object "SetupFile"
    { name: CA.string
    , device: CAC.maybe CA.string
    , port: CAC.maybe CA.string
    , bindings: CA.array bindingCodec
    }
  where un (SetupFile r) = r

vocabularyCodec :: JsonCodec Vocabulary
vocabularyCodec = dimap un Vocabulary $
  CAR.object "Vocabulary"
    { setupFiles: CA.array setupFileCodec
    }
  where un (Vocabulary r) = r
