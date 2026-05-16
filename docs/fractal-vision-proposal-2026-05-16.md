# The Fractal Vision — proposal

**Date:** 2026-05-16
**Status:** proposal (positive vision; coherence check before writing code)
**Distillation of:** `fractal-zoom-design-2026-05-16.md` (brainstorm + marginalia)

---

## What we're building

A live-coding environment in which **the same substrate scales from
individual notes up through patterns, cues, sections, pieces, and
generative compositional engines** — without the user ever crossing
a conceptual boundary. Tidal users live at the floor; composers
live in the middle; generative artists and music-theoretic
rule-system explorers live at the ceiling. All of them write the
same kind of artifact in the same surface, just with different
content.

The system aspires to be for the Pattern what Ableton is for the
audio/MIDI clip — a definitive home — while reaching into a
generative territory Ableton handles poorly. The compositional
intelligence layer (rules-as-pattern-producers — tintinnabuli,
counterpoint, bebop, Fugue Machine, LLM-shelling) is the
centerpiece, not a bolt-on.

---

## The substrate

### Pattern as the universal type

`Pattern` is the one mental object that scales. It's what Tidal
users already think in. It's what we build everything else from.

- A note is a value: `Note`
- A bar of notes is `Pattern Note`
- A cue is `Pattern Note` (or `Pattern String` for mini-notation tokens)
- A section is `Pattern (Pattern Note)` — a pattern whose events are
  themselves patterns to play within their slots
- A piece is `Pattern (Pattern (Pattern Note))` — a pattern of
  sections of cues
- A set is `Pattern⁴ Note`

Same type at every scale. The combinators a Tidal user already
knows (`every`, `rev`, `fast`, `slow`, `jux`, `cat`, `stack`) keep
working at every level — they're polymorphic over the inner type.

### Pattern is a Monad

The structural justification for "same type at every scale":

```
pure :: a -> Pattern a            -- the once-per-cycle pattern
join :: Pattern (Pattern a) -> Pattern a    -- the conductor
```

`join` is the conductor operation: for each event in the outer
pattern (whose value is a sub-pattern), play that inner pattern
within the event's time window. The standard reading is `innerJoin`
— sub-patterns scale into their outer slots.

This is not a metaphor. The mechanical operation IS the algebraic
one. It's why patterns-of-patterns compose at all.

The monad instance gives us, for free:

- `do`-notation for sequencing patterns
- `replicateM`, `sequence`, `traverse`, `mapM`
- Reader / State / Writer transformers if we want to thread context

Probabilistic composition becomes a `do`-block:

```purescript
piece :: Pattern Note
piece = do
  voice    <- verseMelody
  ornament <- pickFrom [trill, mordent, turn]
  ornament voice
```

"For each note in the verse melody, pick an ornament and apply it."

### Pattern is also a Comonad

For *evaluation*, the dual structure matters:

```
extract :: Pattern a -> a                    -- sample at current time
extend  :: Pattern a -> (Pattern a -> b) -> Pattern b   -- context-aware transform
```

Comonad is the natural shape for "what is this pattern saying right
now" queries — the Hylograph view's "what's about to happen" stream
is fundamentally a comonadic extract over time. Monad is for
composition; Comonad is for evaluation. Both belong.

### Pitches are degree-by-default

The same abstraction principle Tidal uses for time (cycle-relative,
not wall-clock-absolute) applied to pitch: **pitches are scale-degree
by default; absolute pitches are a rendering concern.**

`Pitch` is a variant:

```purescript
data Pitch
  = Degree    Int       -- "the third of whatever scale is active"
  | Chromatic Int       -- "MIDI 67, regardless of scale"
  | Sample    String    -- "kick drum — neither pitched nor diatonic"
```

The vast majority of pattern combinators don't touch pitches at all
— they operate on time structure (`every`, `rev`, `fast`, `slow`,
`jux`, `cat`, `stack`) — and work identically across all variants.

Pitch-aware operations dispatch on variant:

- **Diatonic transpose** (`+3`): works on `Degree`, no-op on
  `Chromatic` and `Sample`.
- **Chromatic transpose** (`+7 semitones`): works on `Chromatic`;
  lifts `Degree` into `Chromatic` first.
- **Modulation** (change scale context): re-renders `Degree`
  pitches; `Chromatic` and `Sample` unchanged.

The rendering boundary from scale-degree to absolute pitch is
small and explicit:

```purescript
inKey :: Scale -> Pattern Pitch -> Pattern Pitch
```

`inKey cMixolydian (d "1 5 b7")` is a fully-rendered chromatic
pattern in C Mixolydian. Modulation from verse to chorus is just
swapping the `inKey` wrapper:

```purescript
verse  = inKey cMixolydian (d "1 3 5 6")
chorus = inKey aHarmonicMinor (d "1 3 5 6")  -- same melody, different mode
```

**Why this matters at the substrate level.** Counterpoint rules
talk about scale-degree relationships (parallel fifths, contrary
motion). Tintinnabuli works in degree space (snap to triad
members). Fugue Machine's tape heads use diatonic offsets. LLM
prompts producing music in a mode work better in degree space.
Modes with characteristic tones (Mixolydian's ♭7, Harmonic Minor's
augmented-second leap) survive transposition only when pitches are
relative to the mode, not absolute.

The math of music theory was invented in degree space. Our
substrate matches the math.

### The parser triad

User-facing surface for pitch input:

```
n  "c4 e4 g4"      -- chromatic notes (mini-notation alias: mini)
d  "1 3 5"         -- scale degrees in current key
s  "bd sn cp"      -- drum samples (Tidal's existing convention)
```

Three parsers, three semantic spaces, all returning `Pattern Pitch`.
`mini` stays as an alias for `n` for back-compat.

Conscious choice: Strudel overloads `n` for both pitch tokens and
sample-bank indices. We do not — `n` parses pitch tokens only;
sample-bank indexing goes through `s` with bank notation. We're
fine diverging from Strudel here.

A `dc` Nashville-numeral chord parser (`dc "I IV ii V"`) is a
natural fast-follow, slotted in once we settle on a chord
representation. Not in the precursor scope.

### Continuous signals as sampled FRP

LFOs, slow modulators, ramps — these are continuous functions of
time, sampled by the pattern query at the query rate. `sine`,
`saw`, `cosine` are already this in Tidal: queries against
continuous functions.

Same `Pattern Number` substrate covers:

- Discrete sample-and-hold (`"0 0.5 1 0.5"`)
- Continuous LFOs (`sine`, `saw`)
- Slow modulators (`slow 16 sine`)
- Random walks (mild extension: deterministic-given-seed)

No separate signal type needed.

---

## The surfaces

The system has three editing/viewing surfaces, all **projections of
one underlying value**: the typed Session (a graph of cues,
sections, pieces, and the references between them).

| Surface | What you see | When to use it |
|---------|--------------|----------------|
| **File** (Session.purs) | linear text, full PS source | text-driven workflow; full programming power; version control |
| **Cards** | flat grid, every entity as a card, mvoice-stacks as loose grouping | live performance; fast firing; per-cue editing |
| **Hylograph** | graph with containment; semantic zoom across scales | seeing structure; visualizing generative engines; composing whole pieces |

Critical property: **projections, not isomorphisms**. The
underlying value can have shared references (the same cue used in
multiple sections), and each surface renders shared references in
its own way. Cards may show the same cue twice in different
contexts. Hylograph may render containment without copies. The file
shows the cue declared once and referenced elsewhere.

Editing happens in any surface. Edits modify the underlying value.
Projections re-derive.

### Semantic zoom

Hylograph supports continuous zoom across scales:

- Max zoom-out: the piece — sections as boxes, the score as a
  timeline
- Mid zoom: one section — cues inside it
- Closer zoom: one cue — the pattern inside it
- Max zoom-in: one bar — events inside it

Same kind of content at every zoom level. Same combinators apply.
Andrew called this the Fractal Zoom — after Eno's track from Nerve
Net. A good omen.

---

## The layers

Users settle at different layers without crossing conceptual
boundaries.

### Layer 0 — Cues

Type a pattern, arm it on a voice, hear it. Tidal-tight. Today's
floor. A user can live here forever and have a fully functional
tool.

### Layer 2 — Pattern timeline (arrangement)

Write `Pattern (Voice, Cue)` — when does each cue start, on which
voice. The same `Pattern` type as Layer 0; the same combinators
still work. A 4-minute piece is `slow 240 arrangementPattern`.
A "verse, chorus, verse, chorus, bridge, chorus" piece is
`cat [verse, chorus, verse, chorus, bridge, chorus]`.

This layer is where composed-but-static pieces live.

### Layer 3 — Compositional intelligence

The heart of the vision. Rules, constraints, templates, AI — all
expressed as **pattern producers**.

The architectural property: every Layer 3 mechanism produces a
`Pattern`, indistinguishable downstream from a hand-written one.
Four canonical shapes:

**Mechanical 1→1 transformation** (Pärt's tintinnabuli):
```purescript
tintinnabuli :: Triad -> Position -> Pattern Pitch -> Pattern Pitch
```
Given an M-voice and a triad + position, the T-voice is determined.
The companion voice IS a function of the first.

**Mechanical 1→N transformation** (Alexandernaut's Fugue Machine):
```purescript
fugueMachine :: Array TapeHead -> Pattern Pitch -> Pattern Pitch
```
A source melody, multiple "tape heads" each with direction / rate /
diatonic-offset / phase-shift parameters. The result is a stack of
derived voices in polymeter, all reading the same source through
different lenses. Modulation = re-`inKey` the whole result.

**Constrained generation** (species counterpoint):
```purescript
counterpoint :: Species -> CantusFirmus -> Aff (Pattern Pitch)
```
Multiple voices must satisfy a system of rules. Generate-and-check
or constraint-solve. `Aff` is honest — search is effectful (random
seeds, time bounds).

**Template + contextual filling** (bebop over changes):
```purescript
bebop :: BebopVocabulary -> ChordChanges -> Aff (Pattern Pitch)
```
A library of idiomatic figures applied to a harmonic context, with
chord-tone targeting on strong beats.

**LLM-shelling** sits naturally in the same family:
```purescript
askLLM :: PieceContext -> Prompt -> Aff (Pattern Pitch)
```

All shapes share `… -> [Aff] Pattern Pitch`. The downstream consumer
doesn't know or care which mechanism produced the pattern.

The user can write `tintinnabuli` for one voice, `fugueMachine
heads` for another, `askLLM "make this funkier"` for a third,
mini-notation for a fourth. They compose, because they all flow
through the same substrate.

This is the layer that gives us **substrate-native generativity**.
Generative composition isn't a special feature; it's "any
`Context -> Pattern Pitch` value, plugged in anywhere a
`Pattern Pitch` is expected." Cross-voice coordination is one
shared `Pattern` flowing into multiple producers' contexts —
structurally analogous to one modular LFO feeding N parameter
inputs.

**A meta-observation worth surfacing.** Each of these shapes is a
*compositional vocabulary expressed as a UI over the same
substrate*. Fugue Machine isn't a new computational model — it's a
specific parameter-record-driven UI over operations that already
exist in `Pattern Pitch`. Tintinnabuli isn't a new model either —
it's degree-snap. The same will be true of other tools we might
absorb (step sequencers, piano-roll editors, chord-progression
grids, etc.). The substrate is universal; the vocabularies are
many.

### Layer 4 — Hylograph score view

The visualization layer. Whatever's playing — single cue, arranged
timeline, Layer 3 generative output — gets rendered to a unified
score view with semantic zoom.

For Layer 3 specifically, Hylograph also renders **rule structure**
— the user sees not just *what* is playing but *why* the rule system
made this decision (with knob inputs, randomness contributions,
counterpoint constraint violations highlighted, etc.).

You can't compose what you can't see. For generative pieces,
visualization is load-bearing.

---

## Type machinery the vision relies on

Available because we're an eDSL hosted in PureScript.

### Foundational

- **Pattern as Monad** — patterns-of-patterns flatten via `join`;
  the conductor IS `join`. Without this, fractal nesting doesn't
  compose.
- **Pitches as a tagged variant** (`Degree` / `Chromatic` /
  `Sample`) — substrate-level support for scale-relative
  composition. Without this, every diatonic operation has to
  plumb scale context through itself.
- **Phantom-typed cues** (`Cue (mvoice :: Symbol)`) — shipped
  today. Compile-time voice routing.

### Force-multiplying

- **Comonad on Pattern** — natural shape for "what's playing now"
  queries; the basis of the Hylograph's live-render stream.
- **Effect typing for Layer 3** — `Context -> Pattern` for pure
  rules; `Context -> Aff Pattern` for search / LLM. The effect row
  classifies generator shapes.

### Speculative (defer until value is proven)

- **Type-level scale on `Degree`** — `Pattern (Pitch CMajor)` vs
  `Pattern (Pitch DDorian)` enforcing scale-correctness at compile
  time. Adds friction; revisit if mode-mixing bugs accumulate.
- **Free-monad encoding of patterns** — would let us inspect
  patterns as data before running, useful for Hylograph rendering
  of generative engines. Could replace direct pattern values if
  visualization needs become demanding.
- **Lenses / optics** — for surgical access into nested patterns.
  Natural for `Pattern (Pattern (Pattern a))` traversal.

---

## Cross-cutting properties

These are constraints the design holds itself to:

1. **One mental object.** `Pattern` everywhere. Same type, same
   combinators, every scale.
2. **Pitches are scale-degree by default.** Absolute pitch is a
   rendering concern.
3. **Projections share an underlying value.** All surfaces edit the
   same Session. References are first-class; copies aren't forced.
4. **Layers compose; layers don't gate.** A Layer 0 user never has
   to know Layers 2/3/4 exist. Each layer is additive.
5. **Layer 3 outputs are Patterns.** Generative producers and
   hand-written cues are interchangeable in any consumer.
6. **Generative is substrate-native, not a feature.** Pattern-driven
   selectors give us modular-style generativity in the substrate.
7. **Vocabularies are UIs over the substrate.** Fugue Machine,
   tintinnabuli, Nashville chords, piano-roll, etc. all reduce to
   operations on `Pattern Pitch`.
8. **Visualization is load-bearing.** Especially for Layers 2-3, the
   Hylograph score view is the surface the user composes against.
9. **Continuous and discrete signals share substrate.** `Pattern a`
   covers both; queries sample what they need at the rate they need.

---

## Build sequence

Four steps in dependency order. Each is the smallest unit that
proves a substrate decision; each lays the ground for the next.

### MVP-1: Degree-default pitch substrate *(precursor)*

The first session. Cheap, foundational, unblocks everything else.

What it ships:

- `Pitch = Degree Int | Chromatic Int | Sample String` variant
- `n "c4 e4 g4"` parser (chromatic notes; `mini` is its alias)
- `d "1 3 5"` parser (scale degrees)
- `Scale` record with constants (`cMajor`, `aMinor`, `cMixolydian`,
  `aHarmonicMinor`, `dDorian`, ...)
- `inKey :: Scale -> Pattern Pitch -> Pattern Pitch` — the
  degree-to-chromatic rendering boundary
- Variant-aware `transposeDiatonic` / `transposeChromatic`
- Scheduler that errors helpfully on an unwrapped `Degree` pattern
- A demo Session that uses `inKey cMixolydian` end-to-end

What it explicitly defers: altered degrees (`b3`, `#5`),
microtonal scales, Nashville chords (`dc`), auto-modulation
patterns, UI key indicator.

Estimated scope: 4-6 hours of focused work.

### MVP-2: `Pattern (Pattern a)` end-to-end

A small section-as-pattern: a `Pattern (Cue "drums")` with two
events — verse-cue at cycle 0, chorus-cue at cycle 8. The
conductor (the BEAM-side flattener) listens to this outer pattern
and fires arms at the right cycles. Audible end-to-end.

What this proves: the monadic substrate works in practice. If we
can fire an arm command from an outer pattern's event, we can
build the whole compositional vocabulary on this foundation.

What it needs:

- A `Pattern (Cue mvoice)` value in `Calypso.Generated.Session`
- A BEAM-side conductor gen_server that queries the pattern at
  each tick and fires arms when events come due
- A "play piece" wire verb that takes a top-level pattern name
- Frontend: a button on the composition pane (next to ▶ run) that
  fires "play piece <name>"

Cleaner with MVP-1 in place — the verse/chorus pair stays in mode
under transposition.

Estimated scope: a few days of focused work.

### MVP-3: Tintinnabuli as the first Layer 3 generator

Pärt's tintinnabuli is the cleanest rule-system case study:
mechanical, unambiguous, well-understood. With MVP-1 done it's
roughly:

```purescript
tintinnabuli :: Triad -> Position -> Pattern Pitch -> Pattern Pitch
tintinnabuli triad pos = map (snapTo triad pos)
```

Used in a cue:

```purescript
mvoice :: Cue "lead"
mvoice = on lead (d "1 2 3 2 1 -1 1")

tvoice :: Cue "echo"
tvoice = on echo (tintinnabuli cTriad Above1 (cueBody mvoice))
```

What this proves: rule systems integrate seamlessly with hand-written
cues. The two voices play together; the second IS derived from the
first. Substrate-native compositional intelligence in action.

Estimated scope: a half-day. Tests the `Pattern Pitch` substrate
more than the architecture.

### MVP-4: Fugue Machine

Multi-voice rule system stress-test:

```purescript
data TapeHead = TapeHead
  { direction :: Direction
  , rate      :: Rational
  , offset    :: DiatonicSteps
  , phaseShift :: Cycles
  }

fugueMachine :: Array TapeHead -> Pattern Pitch -> Pattern Pitch
```

Source melody fanned into N derived voices in polymeter. Modulate
the result by changing the `inKey` wrapper; all voices stay
in-mode by construction.

What this proves: parametric-record-driven UIs over the substrate
work. Establishes the pattern for absorbing other compositional
tools as Layer 3 vocabularies.

Particularly satisfying because Fugue Machine is well-known and
muscle-memory-familiar to musicians — the "does this *feel right*?"
test is easy to apply.

Estimated scope: a day, mostly UI/visualization work once the
underlying transforms (`rev`, `fast`/`slow`, `transposeDiatonic`,
phase-shift) are ready.

---

## Closing

This vision picks one bet: **`Pattern` as the universal substrate,
with pitches scale-degree by default, extended via its monadic
structure, evaluated via its comonadic structure, projected through
three surfaces from a single shared value, with compositional
intelligence as a first-class layer of pattern producers.**

If the bet is right, we have a system that scales from "type and
hear" to "compose a generative piece governed by counterpoint
rules" without the user crossing a single conceptual boundary. Same
language, same combinators, same surfaces — different content at
different scales.

Each MVP is positioned to expose a leak in the abstraction if one
exists. MVP-1 stress-tests the degree-substrate; MVP-2 stress-tests
the monadic flattening; MVP-3 stress-tests the rule-system →
pattern boundary; MVP-4 stress-tests the parametric-vocabulary
absorption. Real bugs surface fast; real wins compound.

The path forward: build MVP-1 → MVP-2 → MVP-3 → MVP-4, react after
each, then choose which Layer 3 vocabulary (counterpoint? bebop?
LLM?) or which Layer 4 visualization to expand into next. Each
subsequent step still passes the cross-cutting property tests
above.
