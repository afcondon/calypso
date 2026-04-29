-- | Build the autocomplete dictionary the CodeMirror autocomplete
-- | extension consumes.  Combines:
-- |
-- |   * static keywords (`load`, `hush`, `bind`, …)
-- |   * mini-notation operators (cosmetic-only — they're punctuation,
-- |     but listing them surfaces the grammar in the popup)
-- |   * setup-file names (so `load <Tab>` suggests `laplace`, `qd`, …)
-- |   * binding names from every parsed setup file (so `lap`,
-- |     `laplace-resonator-decay`, … all autocomplete at top level)
-- |
-- | The output is a plain record array — JSON-shaped, ready for the
-- | JS-side autocompletion source to consume without further
-- | translation.
module Calypso.Frontend.Completion
  ( Completion
  , completionsFromVocabulary
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldMap)
import Data.Maybe (Maybe(..))

import Calypso.Vocabulary
  ( Binding(..)
  , BindingKind(..)
  , SetupFile(..)
  , Vocabulary(..)
  )

-- | Mirror the JS-side `Completion` shape — see CodeMirror.js's
-- | `vocabularyCompletionSource`.  `kind` maps to CodeMirror's
-- | `Completion.type`: "keyword" / "function" / "variable" /
-- | "namespace" / "operator".
type Completion =
  { label :: String
  , kind :: String
  , detail :: String
  , info :: String
  }

-- | Collected from the inline grammar comment in
-- | `purerl-tidal/src/Tidal/Parse/Combinators.purs` — these are the
-- | top-level command words and pattern-side keywords.
staticKeywords :: Array Completion
staticKeywords =
  [ kw "load" "load <name>" "Read setup/<name>.tidal and evaluate each line."
  , kw "bind" "bind <name> <kind> <device> ..." "Declare a pattern lane."
  , kw "midi-device" "midi-device <alias> \"<port>\"" "Declare a MIDI output device."
  , kw "midi-note" "midi-note <device> <ch> <note> <vel> <dur>" "MIDI note binding kind."
  , kw "midi-cc" "midi-cc <device> <ch> <cc>" "MIDI CC binding kind."
  , kw "hush" "hush" "Stop all running patterns."
  , kw "gate" "gate <ch> ..." "Gate pattern lane (CV/Gate path)."
  , kw "cv" "cv <ch> ..." "CV pattern lane."
  ]
  where
    kw label detail info = { label, kind: "keyword", detail, info }

-- | Mini-notation operators.  Listed mostly for discoverability —
-- | autocompleting `*` from punctuation is unusual, but these show up
-- | in the popup when explicitly invoked (Ctrl-Space).
miniNotationOperators :: Array Completion
miniNotationOperators =
  [ op "*" "x*n" "Repeat x n times within its slot."
  , op "/" "x/n" "Slow x by factor n."
  , op "@" "x@n" "Elongate x by ratio n."
  , op "!" "x!n" "Replicate x n times (each its own slot)."
  , op "?" "x?" "Drop x with 50% probability per cycle."
  , op "[]" "[a b c]" "Group: subpatterns nest into one slot."
  , op "{}" "{a, b, c}" "Polymeter: parallel patterns of differing lengths."
  , op "<>" "<a b c>" "Alternate: one element per cycle in turn."
  , op "()" "(k, n)" "Euclidean rhythm: k hits across n steps."
  , op "," "a, b" "Stack: layer parallel patterns."
  , op "|" "a | b" "Choose: pick one of the alternatives at random."
  ]
  where
    op label detail info = { label, kind: "operator", detail, info }

-- | Build completions from one parsed setup file: one for the file
-- | name itself (the `load <name>` target), plus one per binding.
fromSetupFile :: SetupFile -> Array Completion
fromSetupFile (SetupFile sf) =
  let
    portStr = case sf.port of
      Just p -> "\"" <> p <> "\""
      Nothing -> "(no port)"
    bindingCount = Array.length sf.bindings
    fileEntry =
      { label: sf.name
      , kind: "namespace"
      , detail: "load " <> sf.name <> " — " <> portStr
      , info: show bindingCount <> " binding" <> (if bindingCount == 1 then "" else "s")
      }
  in
    Array.cons fileEntry (map fromBinding sf.bindings)

fromBinding :: Binding -> Completion
fromBinding (Binding b) =
  { label: b.name
  , kind: case b.kind of
      MidiNote -> "function"
      MidiCc -> "variable"
  , detail: bindingDetail b
  , info: bindingInfo b
  }

bindingDetail :: forall r. { kind :: BindingKind, device :: String, channel :: Int, number :: Int | r } -> String
bindingDetail b = case b.kind of
  MidiNote -> "note → " <> b.device <> " ch" <> show b.channel <> " (default " <> show b.number <> ")"
  MidiCc -> "cc " <> show b.number <> " → " <> b.device <> " ch" <> show b.channel

bindingInfo :: forall r. { kind :: BindingKind, extras :: Array Int | r } -> String
bindingInfo b = case b.kind of
  MidiNote -> case b.extras of
    [vel, dur] -> "vel " <> show vel <> ", dur " <> show dur <> "ms"
    _ -> ""
  MidiCc -> ""

completionsFromVocabulary :: Vocabulary -> Array Completion
completionsFromVocabulary (Vocabulary v) =
  staticKeywords
    <> miniNotationOperators
    <> foldMap fromSetupFile v.setupFiles
