# Fractal Zoom — design brainstorm

**Date:** 2026-05-16
**Status:** exploratory — capture of a brainstorm, no commitments
**Companion to:** `edsl-design-space-2026-05-15.md` (discrete features list)

> *Brian Eno, "Fractal Zoom", from Nerve Net (1992). Andrew called
> the name a good omen.*

---

## The catalyst

After today's typeful-cues / arm-elimination perf work landed, the
next obvious territory is "PureScript controlling compositional
aspects — from the frontend or in some conductor process on the
backend."

Andrew framed it not as a coding question but as a design one:

> *What I'm essentially looking for here is some kind of seamless,
> fractal approach to live-coding that lets you code the kind of
> intricate detail that Tidal is so good at but also works on
> longer time scales to provide both compositional and generative
> music.*

The temptation as a programmer is to immediately reach for
"Generative = `Aff`, Compositional = declarative interpreter."
Andrew wanted to resist that pull during brainstorm — design first,
implementation later.

The initial response sketched three implementation shapes
(declarative pieces / conductor-function / hybrid) and asked which
to start on. Andrew set that aside: *blue-sky first*.

---

## The seamless-and-fractal principle

What might "seamless and fractal" mean concretely?

Tidal's superpower at the event level is that everything is
`Pattern a`. Events combine into bars, bars into cycles — and the
same combinators (`every`, `rev`, `fast`, `jux`, `slow`) work at
every scale you can reach with that substrate.

If we mean it for live-coding-at-large, the principle is something
like: **the same substrate keeps working as you zoom out**. A bar is
a tiny piece. A piece is just a longer pattern. A 30-minute set is
a longer pattern still. Nothing changes about how you *think*, only
about what's playing.

This rules a lot out. It says: no separate vocabulary for
"sections" vs "cues" vs "pieces" if it can be avoided. No mode
switch when you graduate from improvising to composing.

---

## Four lenses on what fractal-and-seamless might require

### Lens A — Time as a first-class transformation

In Tidal, `every 4 rev pat` does something at every 4th cycle. What
if `every` were just a special case of operating on *time*, and you
could write `accelerate (curve 0.5 1.5 16) pat` or `stretch arc piece`?

Once time is a value you can transform, *composition collapses into
pattern manipulation*. A "verse → chorus" transition becomes a
stretch + a key shift + a density change applied to whatever was
playing. The compositional vocabulary reduces to a small set of
time/space transforms.

### Lens B — Patterns of patterns

Today a cue is `Pattern String`. What if `Pattern Cue` were a thing
— a higher-order pattern whose "events" are cues to arm? Then
arrangement is just `Pattern (Pattern a)`. The conductor is what
flattens the outer pattern by arming its events at their start
times.

The combinators still work: `every 8 rev arrangement` reverses your
verse-chorus structure every 8 cycles. Generative arrangements
emerge by mixing random patterns into the outer level.

### Lens C — Score as the missing primitive

Today there are *patterns* (small) and *cues* (per-voice patterns)
but nothing in between cues and "the whole piece." A `Score` could
be a pattern of `(voice, cue, time-range)` events — first-class.

Live-coding is the degenerate case where you write the score in
real-time by hand. Composed-but-improvised is a partial score with
holes the conductor fills. Generative is a score that's evaluated
lazily.

### Lens D — The Curator model

A piece isn't a tree but a **library + a curator**. The library is
a pool of cues, sections, motifs. The curator is a function
`LiveState -> NextThing` — looks at what's playing, how long, live
controls, randomness, and picks what to do next.

Where the "generative = Aff" intuition lives cleanly: the curator
is the thing that has effects (samples randomness, reads live
state, picks). But it doesn't have to *live* in `Aff` — it could be
a deterministic function whose only input is `(time, randomSeed,
liveControls)`, which keeps composability.

Pleasant property: an entirely pre-composed piece is just a curator
that always returns the same sequence. So the same surface handles
both ends of the comp-gen spectrum.

---

## Where the generative/compositional split might dissolve

Andrew named "Generative = `Aff`, Compositional = declarative
interpreter" as his default intuition. The brainstorm suggested
that's the wrong cut.

A better cut: **early-decided vs late-decided**. A composed piece
pre-decides everything. A generative piece defers decisions until
the moment they're needed. Both are *the same shape of artifact*;
they differ in *when* values get computed.

Pure deferred computation in PureScript is just laziness +
randomness threading. You don't necessarily need `Aff` — you need a
"reader for live state" + a deterministic random stream. (Effects
return when you want IO-style live-controls or *external* randomness
like microphone level, but that's a feature, not the foundation.)

The compositional/generative split becomes a *per-decision attribute*:
"at this point in the piece, the next cue is decided early (always
`chorus1`)" vs "decided late (whichever of these three has been
used least)."

---

## The visualization is load-bearing, not decorative

Possibly the hardest thing the design has to do.

If a piece spans 4 minutes and the conductor picks events at
runtime, you can't audit what's happening from the cue cards alone.
You need a view that shows:

- where you are in the piece
- what's about to happen
- what the curator is *about to* decide
- which knobs/randomness fed the decision

That's the F5 Hylograph-pane direction. For generative + composed
pieces, visualization isn't decoration — it's the load-bearing
surface. You can't compose what you can't see.

---

## The widened frame — many users, each finding their sweet spot

Andrew widened the frame substantially:

> *Aspirationally I'd like this to at least demonstrate that
> live-coding could extend fractally on one axis and into
> generative music on another. I.e. a tool for LOTS of people to
> use, each person finding their sweet spot. I think the best
> tools, Ableton would be a good example, have that ability to
> encompass many user models without dissolving into a puddle of
> modal complexity.*

This isn't bespoke software for one user. It's a tool whose core
must be coherent and small, but which lets users settle at very
different points on the fractal/generative axes without being
forced through modes they don't care about.

### What Ableton actually does

Ableton's trick isn't "lots of features." It's that a beginner and a
film composer use the *same system* even though they touch wildly
different surfaces. Three structural moves make that work:

1. **One mental object, multiple surfaces.** A clip is a clip.
   Session view fires it; arrangement view places it on a timeline;
   piano roll edits its content; mixer sees its track. The clip
   itself doesn't know which surface you're using.
2. **Layers compose, layers don't gate.** You can use session view
   only, forever. You can graduate to arrangement view without
   unlearning anything.
3. **Progressive disclosure via tiny syntactic moves.** Follow
   actions, scenes, automation lanes — each is a single small
   concept added to the same substrate. None requires reframing.

Notice what Ableton DOESN'T do: it doesn't have a "generative mode"
or a "compositional mode." Those *emerge* from how you use the same
pieces.

### Implication

**There has to be one mental object that scales — and it has to be
the same object Tidal users already think in.**

That's `Pattern`. Tidal users live there. If `Pattern` *also*
describes sections, pieces, sets — then they're literally writing
the same kind of thing at every scale, just with different content.
No second concept to learn.

So Lens B ("patterns of patterns") isn't just an option — it might
be the *structural requirement* for the multi-user goal. The
combinators they already know keep working as they zoom out. The
vocabulary doesn't grow with the scale; only the content does.

The Curator framing (Lens D) is *one possible upper layer* — opt-in.
It can't be the foundation, because most users won't want it.

---

## A layered model (sketch, not commitment)

**Layer 0 — Cues (Tidal-tight floor).** Type a pattern, arm it on a
voice, hear it. We have this today. A user can live here forever
and have a fully functional tool. *Sweet spot: Tidal users,
knob-twiddlers.*

**Layer 1 — Cue follow-actions + scenes.** Stolen wholesale from
Ableton. Each cue can declare "after N cycles, do X" where X might
be silence / arm another cue / pick from a set. Scenes are named
horizontal slices. *Single tiny syntactic addition; massive
expressive payoff.* This is where local generativity enters —
Markov-chain compositions emerge from follow-actions alone.
*Sweet spot: live-coders who want sectional behavior without
writing a piece.*

**Layer 2 — Pattern timeline (arrangement view).** A
`Pattern (Voice, Cue)` — when does each cue start, on which voice.
Same `Pattern` type as Layer 0; combinators still work. A 1-minute
piece is `slow 60 arrangementPattern`. *Sweet spot: composers who
want to write pieces but think in patterns.*

**Layer 3 — Curator / explicit conductor.** An effectful function
deciding what to arm next. Only loaded if the user writes one.
*Sweet spot: generative artists, Eno-style rule writers, performers
who want responsive pieces.*

**Layer 4 — Hylograph Score view.** Whatever's playing — single cue,
follow-action chain, arrangement pattern, curator output — gets
rendered to a unified piano-roll-like surface so the user can SEE
what's about to happen. *Sweet spot: everyone, regardless of how
they got here.*

A Tidal user touches Layer 0 only. A scene-launcher touches 0+1. A
composer 0+2. A generative artist 0+3. A performer 0+4 (sees the
structure, doesn't author it).

---

## Ableton-tricks worth stealing

Tiny and high-leverage:

- **Follow actions.** "After this cue plays N times, do X with
  probability p." Local rule, global structure emerges. Smallest
  possible compositional surface.
- **Scenes.** A named row that fires multiple cues at once.
  Arrangement without timeline.
- **Clip launch quantization.** "Arm doesn't take effect until next
  bar." We have something like this implicit in pattern phase;
  making it explicit per-arm would matter for compositional control.
- **One-shot vs looping cues.** A cue that fires once and stops vs
  loops forever. Useful for fills and one-shot stings vs sustained
  patterns.
- **Returns / sends.** Live-control busses with named targets,
  addressable from any cue. We have a control bus; named-target
  routing would be the polish.

---

## Fractal axis vs generative axis — orthogonal, not aligned

Two axes:

- **Fractal** — same idea at every time scale (event ↔ bar ↔ piece).
- **Generative** — automation, randomness, rule-driven composition.

In the layered model they become independent:

- Fractal-deep without generative: Layer 0 + 2 (Tidal at events,
  Tidal-shaped patterns at piece scale, everything pre-composed).
- Generative without fractal-deep: Layer 0 + 3 (curator over today's
  cue surface, no piece-scale patterns).
- Both: Layer 0 + 2 + 3 (composed skeleton, generative fills).
- Neither: Layer 0 alone is a fine place to live.

Treating them as independent dimensions matches the "lots of people,
each finding their sweet spot" framing better than treating them as
a single ladder.

---

## Two fresh provocations (Andrew, 2026-05-16 afternoon)

### Ableton handles generative music poorly — that's design space, not the ceiling

Andrew's pushback:

> *I don't think Ableton handles generative music at all well, no
> accident that people gravitate to modular for that, IMO. Of
> course, you CAN do it with chain actions and so on but it's
> clearly a bolt-on, it's VERY non-fractal, only applies to little
> sequences of loops practically speaking.*

This is sharp and changes the reference points significantly.

Ableton's follow-actions and chains are LOCAL rules — each clip
decides what it does after it ends. To get GLOBAL generative
structure (whole-piece evolution, long arcs, cross-track
coordination) you have to assemble it by hand from local rules. It
doesn't scale. It can't see itself.

Modular synthesizers are the opposite: generativity is **substrate-
native**. Any CV signal can drive any parameter. A slow random walk
on one module modulates the cutoff on another, which gates a third,
which clocks a fourth. The patching IS the composition. There's no
"generative mode" — every voltage in the system is a potential
source of generative structure.

The implication for our design:

**Ableton's follow-actions are a useful trick to steal but not the
ceiling.** The real reference point for the generative axis is
modular — where any signal can drive any selector and generativity
emerges from the substrate, not from a special feature.

Concrete shape: if `Pattern Cycles -> Cue` is a thing (a
pattern-driven cue selector), then generative composition IS pattern
composition. The same `Pattern` substrate that picks notes can pick
cues. No bolt-on. Cross-track generative coordination is a single
shared `Pattern` flowing to multiple voices' selectors.

That's structurally analogous to a modular's "one LFO into N
parameter inputs" — except the LFO is a pattern, and the parameter
inputs are cue-selectors.

This argues strongly for Lens B (patterns of patterns) as the
generative substrate too — not just the fractal substrate. **One
mechanism, both axes.**

### Semantic zoom — three surfaces, isomorphisms between them

Andrew's structural sketch:

> *Fractal surface + Hylograph makes me think — semantic zoom.
> That sort of suggests to me that we'd have a series of
> isomorphisms — file to cards to Hylograph, but the cards view
> would include patterns of patterns but all flat, and in the
> Hylograph view the patterns of patterns would show containment.*

This is potentially the key design idea for the whole effort.

Three surfaces of the same underlying value:

| Surface | Time | Structure | Spatial layout |
|---------|------|-----------|----------------|
| **File** (Session.purs) | one-shot read | implicit (indent / declaration order) | linear text |
| **Cards** | continuous edit | flat — all entities side-by-side | grid |
| **Hylograph** | continuous view | containment — patterns of patterns shown as nesting | graph |

Each is a different *projection* of the same underlying value
(probably the typed Session). The semantic-zoom move:

- **Zoom out in Hylograph** → see piece structure (sections as boxes,
  the score as a timeline)
- **Zoom in** → see one section (cues inside it)
- **Zoom further** → see one cue (the pattern inside it)
- **Zoom further** → see one bar (events inside it)

Same kind of content at every zoom level — actually fractal in the
Mandelbrot sense, not just metaphorically.

What's powerful about the isomorphism framing: **the surfaces are
interchangeable**. The user can edit in any surface, and changes
propagate to the others. A text-only Tidal user lives in the file.
A visual composer lives in Hylograph. A live-coder lives in cards.
The same artifact persists across all three.

Open design questions this raises:

- **Are cards really flat?** Today the cards grid is per-voice
  columns. If sections become a thing, do sections replace columns,
  co-exist with them (section × voice matrix), or become a
  card-attribute (section as a tag/colour)? The cards-view-is-flat
  assertion deserves stress-testing.
- **What semantics zoom?** Pure spatial zoom is one option (camera
  metaphor). Semantic zoom usually means *different content at
  different zooms* — at piece scale you see section boxes, at
  section scale you see cue cards, at cue scale you see the
  pattern. That's not pure zoom — it's a series of jumps between
  abstraction levels with continuous transitions.
- **The Hylograph containment view as score view.** If patterns of
  patterns show as containment, then a Score (Lens C) is *exactly*
  what Hylograph renders at the outer level. The "Score primitive"
  and "Hylograph view" might be the same thing under two names.
- **Time AND structure.** Hylograph's containment is spatial. But
  Score is temporal — patterns play out across time. The view
  needs both: contain spatially, advance temporally. Piano-roll
  with hierarchical groupings is a candidate.

A nice property: this design *unifies* what looked like two
separate concerns (the visualization for generative pieces, and the
multi-user reach). Both are addressed by the same isomorphism. Text
user → file. Card user → cards. Visual user → Hylograph. Generative
piece author → Hylograph (with semantic zoom revealing rule
structure, not just events).

---

## What the constraints rule out (and that's information)

Taking the multi-user + isomorphism framing seriously narrows the
design space:

- **Types that don't ALSO benefit Layer 0 users are suspect.** A
  `Section` type that Tidal-only users would never use is a smell.
  If it's worth having, it should appear naturally at Layer 0 too
  (probably as just another `Pattern`).
- **No bifurcated grammars.** No "Tidal grammar for cues, different
  grammar for pieces." If `every 4 rev` works on a cue, it must
  work on a piece.
- **No mode switches in the UI.** Calypso's pane structure already
  aligns with this — adding panes is additive, not modal.
- **No "ambient generative" bolt-on.** If generative composition
  needs a separate mechanism from regular pattern composition,
  we've duplicated Ableton's mistake. Same substrate must handle
  both.
- **No views that are read-only.** Each of file/cards/Hylograph
  must be editable for the isomorphism to hold. Hylograph-as-
  passive-display is a tempting half-step but breaks the
  symmetry.

---

## Open questions to sit with

- Is "patterns of patterns" actually sufficient as the universal
  substrate, or are there structures (continuous CV modulation,
  long-form gestural curves, state machines) that don't fit?
- What's the relationship between **score** (when things play) and
  **structure** (containment hierarchy)? Are they the same axis or
  orthogonal?
- The Curator (Lens D) is appealing but might not survive the
  isomorphism constraint: a curator is a function, not data. Can it
  be projected to all three surfaces? Or is it a fundamentally
  different beast that has to live alongside?
- Cards-flat vs cards-grouped-by-section is a real design question.
  Andrew's instinct said flat — worth pulling on why.
- Modular composition uses **continuous signals** for slow
  modulation (random walks, slow LFOs into structure-defining
  parameters). Patterns are discrete by nature. How does continuous
  modulation fit the pattern substrate? (Tidal has `cosine`,
  `saw` etc. for continuous patterns — maybe enough?)
- What about pieces that *change their own rules over time* (rule
  evolution, self-modifying scores)? Out of scope or natural
  extension?

---

## What's next

Not code. Andrew said this needs to sit for a while. Sitting is the
work right now.

When we do come back to it, the questions to bring code thinking to
are probably:

1. Does `Pattern (Pattern a)` actually compose the way the
   brainstorm assumes? Try writing a tiny piece-as-pattern by hand
   and see what breaks.
2. The isomorphism file ↔ cards ↔ Hylograph: what's the underlying
   value that all three project from? Sketch its type.
3. Is there a 30-minute "minimal modular-style generative" exercise
   we can do with `Pattern (Pattern a)` + a single random source
   that proves the substrate is enough?

But not today. Coffee first.
