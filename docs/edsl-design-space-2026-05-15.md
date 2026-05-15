# eDSL design space — directions opened up by typeful-cues

**Date:** 2026-05-15 (end-of-day brainstorm, after Phase 4 + naming-slab landed)
**Status:** exploratory — captures directions, not commitments
**Companion to:** `typeful-cues-plan-2026-05-15.md`, `typeful-cues-handoff-2026-05-15.md`

## What changed today

The composition surface is now a real PureScript module
(`Calypso.Generated.Session`). `Cue "mvoice"` declarations are real
typed values; `Channel` is a data constructor; the BEAM walker
registers devices and channels into the dispatcher by tuple-tag. The
end-to-end loop is audio-confirmed against Ableton Live.

The framing-shift this opens up: **the language we used to author cells
is no longer a hand-rolled mini-DSL parsed by a custom parser. It's a
Turing-complete language with our DSL embedded inside it.** Everything
PureScript can do is now reachable from a `.tiderl` file.

The rest of this document is the brain-dump of what that unlocks,
ordered roughly by how concrete each idea is.

## Concrete near-term picks

### `Studio.purs` for rig declarations

Every piece currently re-declares `fh2 = MidiDevice "FH-2" 0`,
`iac = MidiDevice "IAC Driver Tidal" 30`, etc. Move these to a
shared `Studio.purs`:

```purescript
module Studio where
import Calypso.Prelude

fh2   = MidiDevice "FH-2" 0
fh2qd = MidiDevice "FH-2" 69
iac   = MidiDevice "IAC Driver Tidal" 30

qd1   = Channel fh2qd 14 60 100 50
qd2   = Channel fh2qd 15 60 100 50
bass1 = Channel iac 1 36 100 50
```

A piece file becomes:

```purescript
module Calypso.Generated.Session where
import Calypso.Prelude
import Studio

qd1A :: Cue "drums"
qd1A = on qd1 (mini "bd bd ~ ~ bd ~ bd ~")
…
```

Small, mechanical, high payoff: every piece is shorter and the rig
becomes a single source of truth that travels across sessions.

### Hylograph pane as Session visualization

The Hylograph pane in Calypso has been a placeholder. **This is what
it's for.** A `Session` is a value; we can render it as:

- piano-roll preview of all cues at a chosen point in time
- dependency graph (which cues touch which channels / which channels
  go to which device)
- timeline view (when do cues fire over a cycle / multiple cycles)
- mixer view (channel → device routing)
- live MIDI/CV scope (what's actually flowing right now)

This is the bridge between Andrew's music and visualization domains
that purerl-tidal has always been positioned as. The Hylograph
libraries are right there.

### Save card pattern as a named pattern

We've talked about saving a card's edited body back into the `.tiderl`
source. The eDSL version extends this: a card's pattern body can be
*promoted* into a named pattern declaration in a personal library.

```
-- Card body, edited from:
qd1A = on qd1 (mini "bd ~ bd bd bd ~ ~ bd")

-- "Save as named pattern" → prompts for a name, e.g. "drumnbass1":
-- Produces in MyDrums.purs:
drumnbass1 :: Pattern String
drumnbass1 = mini "bd ~ bd bd bd ~ ~ bd"

-- And rewrites the cue to reference it:
qd1A = on qd1 drumnbass1
```

Workflow value: you discover a pattern improvisationally, then preserve
it by name for future pieces. The library grows organically from
performance, not from up-front design.

Tension: cards now reference named patterns whose bodies aren't
visible in the card. Need a UX answer (peek-on-hover, click-to-expand,
or a dedicated **Patterns library** pane).

### Save card back to `.tiderl`

Distinct from save-as-named: just push the edited card body into the
corresponding cue declaration in the composition source. Already
flagged before today; the eDSL doesn't change the mechanism but does
clarify what's being written (a real PS expression, not a wire-format
string).

## Personal libraries

Once `Studio.purs` lands as a precedent, more libraries follow:

- `MyDrums.purs` — named drum patterns (`drumnbass1`, `boomBap`,
  `breakcore`, …)
- `MyBass.purs` — bass riffs, walking-bass generators
- `MyHarmony.purs` — chord progressions, voicing helpers
- `MyRhythm.purs` — polymeter/polyrhythm combinators

Each is an ordinary PS module. Sessions import what they need. The
collection grows over time and is portable across pieces.

This is also the natural home for **algorithmic builders**:
`transpose`, `diatonic`, `arpeggiate`, `voice`, etc.
(See [[feedback-transpose-via-scale-and-offset]] for the
scale-and-offset rather than chromatic-semitone API.)

## Parameterised pieces

A piece doesn't have to be a `Session` value — it can be a *function*:

```purescript
myPiece :: Tempo -> Key -> Variation -> Session
myPiece bpm key var = …
```

Same composed material played in B minor at 92 BPM tonight, F minor at
110 tomorrow. Same piece with variation A vs variation B for a
different texture.

Combined with non-deterministic triggers and frontend coordination,
this gives "play multiple times with textural variation" naturally —
the piece function takes a `Variation` parameter, the coordinator
sweeps through values, the rest plays out.

## Type discipline

Beyond `Cue "mvoice"`:

- **Patterns indexed by scale/key**: `Pattern (Note CMajor)` and
  `Pattern (Note AMinor)` don't mix without explicit transposition.
  Compile-time wrong-key prevention.
- **Units as newtypes**: `BPM`, `Hz`, `Ms`, `Cycles`. Can't pass a
  velocity where a duration is expected.
- **`Playable` as a typeclass**: a `Session` is `Playable` only if all
  referenced devices are declared, no channels are double-bound,
  latency budgets sum within tolerance. The compiler refuses to load a
  broken piece.

The most intellectually exciting but easy to over-engineer. Worth
doing eventually, not first — adopt incrementally as specific bugs
make the type discipline worth its weight.

## Composition-scale structure

Today combinators like `every` and `rev` operate inside a single Cue's
pattern body. Open question: how to apply them to *groups* of patterns
— a "section" or "piece" — without breaking the current per-voice
gen_server architecture.

Two candidate paths:

- **Backend-side composition module.** A PS module that declares
  piece structure, compiles and loads onto the BEAM as a coordinator.
  A "piece" gen_server above the voices. (Andrew: "not sure about
  this but i'll throw it out there.")
- **Frontend-as-coordinator.** Calypso programmatically arms voices
  in sequence, runs the time-flow logic in the browser, sends arm
  commands as time progresses.

Both are worth sketching before committing. The frontend path aligns
with [[project-purerl-tidal-compositional-direction]]'s
non-deterministic triggers (Calypso has to be a controller anyway for
graph/tree/random-driven arming).

## Introspection beyond visualization

A `Session` is a value, so we can derive any view:

- **Validation views**: which cues are unreachable from any
  variation? Which channels have no cue assigned?
- **Coverage views**: what fraction of an arrangement uses each tvoice?
- **Diff views**: what changed between version N and N+1 of the
  composition? (Halfway to time-travel debugging.)
- **Export views**: render the Session as a static MIDI file,
  generate a lead sheet, emit Live ALS clips.

The Live-ALS export is interesting: it would let pieces be staged in
Live for recording, then re-imported as a reference.

## DSL within DSL

PS can host sub-languages:

- **Chord progressions**: `progression "i iv VI v"` parsed into a
  typed `Pattern Chord`.
- **Rhythm grammars**: a more compact specification than raw
  mini-notation for specific contexts.
- **Voicing rules**: declarative SATB or modular-voicing constraints.

### Tarot-music finally lands

The tarot-music project has been an "aspirational join-up". With the
eDSL, the tarot reader emits a **typeful** Session value (or a Section
fragment), not a wire-format string. The mapping from a card to a
musical decision becomes a typed function:

```purescript
mapCard :: Card -> SessionFragment
```

The reader is just a PS function. The generated piece is a real
typed Session. The crossover is no longer aspirational.

## Probabilistic and constraint-based generation

- `Pattern (Distribution a)` for genuinely stochastic patterns,
  sampled at query time. Distinct from `dejaVu`'s sample-then-cache.
- Constraint-based: given a progression + style rules, search for a
  satisfying pattern. PureScript can host this directly; falling back
  to Z3 via FFI is overkill for music-sized problems.

Both fit the "non-deterministic triggers" thread: a piece declares
constraints, the runtime fills in the details, each performance is
different.

## The higher-level live-coding framing

Andrew's framing today: *"the whole thing evolving to a sort of
higher level version of live-coding."* The shape this brainstorm
suggests:

- Pieces are functions, not scripts.
- Patterns are values, named and reusable, growing into a personal
  library over time.
- The rig is declared once (`Studio.purs`), reused across pieces.
- Composition structure is type-checked; broken pieces don't load.
- Performance combines authored structure with non-deterministic
  fills, parameterisation over key/tempo/variation, and live tweaks
  via the control bus.
- The frontend is a controller, not just an editor: it arms cues,
  drives variations, visualizes the running session.

This is meaningfully different from TidalCycles' "type into a buffer,
fire a line" loop. It's closer to **composed-but-improvised
performance** of a typed musical work — which matches Andrew's
modular-synth-recording workflow.

## Naming-slab residue

- `mini` rename candidate: `n` (notes/notation, one-letter idiom).
  Today blocked by `Tidal.Pattern.Types.pattern` colliding with
  `pattern` as a name. Free `pattern` by renaming the low-level
  constructor, or claim `n` outright.

## What to pick first

Subjective ranking by near-term payoff vs effort:

1. **`Studio.purs`** — small, mechanical, immediately cleans up every
   piece file.
2. **Save card body as named pattern** — extends the existing
   save-card-back idea; unlocks the personal-library workflow.
3. **Hylograph pane as Session visualization** — the placeholder pane
   finally earns its keep; serves the composed-but-improvised
   workflow directly.
4. **Performance** (warm-compiler latency) — task #11/#20 already
   queued.
5. **Composition-scale structure** — bigger, design-heavy, but the
   one that turns the system from "patterns" into "pieces".

Type discipline, sub-DSLs, constraint solving — fascinating but
expensive. Wait until a specific need pulls them in.
