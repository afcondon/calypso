-- | Mini-notation primer: a short reference for the pattern
-- | language inside `"..."` strings.  Curated rather than exhaustive
-- | — covers the operators in purerl-tidal's grammar
-- | (`Tidal/Parse/Combinators.purs:9-15`) with one-line explanations
-- | and example fragments the user can lift directly into a cell.
-- |
-- | Source for the prose: TidalCycles' upstream `book/index.md`,
-- | transcribed and condensed for at-a-glance reading inside the
-- | reference panel.  The intent is "Ctrl-F-able while live-coding",
-- | not "tutorial".
module Calypso.Frontend.Primer
  ( renderMiniNotation
  ) where

import Prelude

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

renderMiniNotation :: forall action slots m. H.ComponentHTML action slots m
renderMiniNotation =
  HH.div [ HP.class_ (H.ClassName "primer") ]
    [ overviewBlock
    , sequencesBlock
    , restsBlock
    , groupingBlock
    , stackBlock
    , polymeterBlock
    , alternateBlock
    , repeatBlock
    , slowBlock
    , replicateBlock
    , elongateBlock
    , randomBlock
    , euclideanBlock
    , chooseBlock
    , extensionsBlock
    ]

-- ============================================================
-- Helpers
-- ============================================================

section
  :: forall action slots m
   . String
  -> Array (H.ComponentHTML action slots m)
  -> H.ComponentHTML action slots m
section title body =
  HH.section [ HP.class_ (H.ClassName "primer-section") ]
    ( [ HH.h3 [ HP.class_ (H.ClassName "primer-h") ] [ HH.text title ] ]
        <> body
    )

para :: forall action slots m. String -> H.ComponentHTML action slots m
para t = HH.p [ HP.class_ (H.ClassName "primer-p") ] [ HH.text t ]

code :: forall action slots m. String -> H.ComponentHTML action slots m
code s =
  HH.pre [ HP.class_ (H.ClassName "primer-code") ]
    [ HH.code_ [ HH.text s ] ]

opLine
  :: forall action slots m
   . String
  -> String
  -> String
  -> H.ComponentHTML action slots m
opLine glyph grammar example =
  HH.div [ HP.class_ (H.ClassName "primer-op") ]
    [ HH.span [ HP.class_ (H.ClassName "primer-op-glyph") ] [ HH.text glyph ]
    , HH.span [ HP.class_ (H.ClassName "primer-op-grammar") ] [ HH.text grammar ]
    , HH.code [ HP.class_ (H.ClassName "primer-op-example") ] [ HH.text example ]
    ]

-- ============================================================
-- Sections
-- ============================================================

overviewBlock :: forall action slots m. H.ComponentHTML action slots m
overviewBlock = section "Overview"
  [ para "Mini-notation is the pattern language inside double-quoted \
         \strings.  Tokens fill the cycle — four tokens means each \
         \plays for a quarter of a cycle, eight means an eighth, and \
         \so on.  Operators below modify how tokens are spread and \
         \layered."
  , para "Examples below assume a `lap` binding (notes to Laplace) \
         \and a `bd` lane.  Substitute the bindings you have loaded."
  ]

sequencesBlock :: forall action slots m. H.ComponentHTML action slots m
sequencesBlock = section "Sequences"
  [ para "Listed tokens play in turn, evenly spaced across one cycle."
  , code "lap \"c4 e4 g4 c5\""
  , para "More tokens means each one is shorter; the cycle length \
         \stays constant."
  , code "lap \"c4 e4 g4 c5 d5 g4 e4 c4\""
  ]

restsBlock :: forall action slots m. H.ComponentHTML action slots m
restsBlock = section "Rests"
  [ para "A tilde leaves the slot empty — a rest of the slot's full \
         \duration."
  , opLine "~" "rest" "lap \"c4 ~ e4 ~\""
  ]

groupingBlock :: forall action slots m. H.ComponentHTML action slots m
groupingBlock = section "Grouping"
  [ para "Square brackets nest a sub-pattern into a single slot — \
         \its tokens are squashed to fit the slot's duration."
  , opLine "[ ]" "[a b c]" "lap \"c4 [e4 g4] c5\""
  , para "Groups can nest arbitrarily deep."
  , code "lap \"c4 [e4 [g4 b4]] c5\""
  ]

stackBlock :: forall action slots m. H.ComponentHTML action slots m
stackBlock = section "Stack (parallel)"
  [ para "A comma layers patterns — they all play at once, sharing \
         \the same time window."
  , opLine "," "[a, b]" "lap \"[c4 e4, g4 b4]\""
  , para "Layers fill whatever slot they're in.  Top-level stacks \
         \fill the whole cycle."
  ]

polymeterBlock :: forall action slots m. H.ComponentHTML action slots m
polymeterBlock = section "Polymeter"
  [ para "Curly braces match sub-pattern lengths event-by-event \
         \rather than squashing.  When sub-patterns have different \
         \lengths, leftover events appear on the next cycle."
  , opLine "{ }" "{a, b}" "lap \"{c4 e4 g4 c5, d4 g4}\""
  ]

alternateBlock :: forall action slots m. H.ComponentHTML action slots m
alternateBlock = section "Alternate"
  [ para "Angle brackets pick one element per cycle, in turn — \
         \cycling through the list."
  , opLine "< >" "<a b c>" "lap \"<c4 e4 g4>\""
  , para "Useful for chord progressions or one-per-bar variation."
  ]

repeatBlock :: forall action slots m. H.ComponentHTML action slots m
repeatBlock = section "Repeat (faster)"
  [ para "Multiply a token to repeat it inside its own slot — n \
         \copies fitting the same time window."
  , opLine "*" "x*n" "lap \"c4 e4*4 g4\""
  ]

slowBlock :: forall action slots m. H.ComponentHTML action slots m
slowBlock = section "Slow"
  [ para "Divide a token to stretch it across more than one slot's \
         \worth of time."
  , opLine "/" "x/n" "lap \"c4/2 e4 g4\""
  ]

replicateBlock :: forall action slots m. H.ComponentHTML action slots m
replicateBlock = section "Replicate"
  [ para "Bang replicates a token n times — each copy gets its own \
         \slot, so the cycle gets longer rather than the slot getting \
         \subdivided."
  , opLine "!" "x!n" "lap \"c4!3 e4\""
  ]

elongateBlock :: forall action slots m. H.ComponentHTML action slots m
elongateBlock = section "Elongate"
  [ para "Take up more space — `@n` makes a token last n times the \
         \default slot length."
  , opLine "@" "x@n" "lap \"c4@3 e4 g4\""
  ]

randomBlock :: forall action slots m. H.ComponentHTML action slots m
randomBlock = section "Random drop"
  [ para "Question mark drops the token from a cycle with 50% \
         \probability — quick variation without writing branches."
  , opLine "?" "x?" "lap \"c4 e4? g4 c5?\""
  ]

euclideanBlock :: forall action slots m. H.ComponentHTML action slots m
euclideanBlock = section "Euclidean"
  [ para "Bjorklund-style hits-across-steps.  `(k, n)` distributes \
         \k hits as evenly as possible across n steps."
  , opLine "( )" "x(k,n)" "lap \"c4(3,8)\""
  , para "An optional third argument rotates the pattern."
  , opLine "( , , )" "x(k,n,r)" "lap \"c4(3,8,2)\""
  ]

chooseBlock :: forall action slots m. H.ComponentHTML action slots m
chooseBlock = section "Choose"
  [ para "Pipe picks one of the alternatives at random per cycle."
  , opLine "|" "a | b" "lap \"c4 | e4 | g4\""
  ]

extensionsBlock :: forall action slots m. H.ComponentHTML action slots m
extensionsBlock = section "purerl-tidal extensions"
  [ para "purerl-tidal tracks upstream Tidal mini-notation closely. \
         \As deviations or extensions are catalogued, they'll appear \
         \here.  See `purerl-tidal/src/Tidal/Parse/Combinators.purs` \
         \for the authoritative grammar."
  ]
