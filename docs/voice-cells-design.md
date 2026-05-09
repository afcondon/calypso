# Voice-Cells Calypso redesign

Brainstormed 2026-05-08 (between Andrew + Claude) on the branch
`voice-cells` after the per-voice supervision tree landed in
purerl-tidal (tag `voice-tree-2026-05-08`). This document captures
the conversation so the thinking isn't lost; it's intentionally
expansive and not yet a build plan. Decisions still pending are
flagged inline.

## Vision

Calypso shifts from a free-form-text-cells editor to a
**voice-oriented** workspace. The cell becomes the atomic unit, and
the cell *is* a voice — one cell ↔ one bound name in the rig ↔ one
`tidal_voice` gen_server in purerl-tidal ↔ (later, with a compile
pipeline) one generated PureScript module + .beam.

This sets up the longer-term direction of moving from "interpret the
DSL at runtime" to "compile each voice to its own PureScript module
and hot-reload." The per-voice supervision tree is the runtime
foundation; this UI is the authoring surface.

## The three orthogonal axes

A cell carries three independent classification axes:

1. **Voice kind** — derivable from the binding's PrimAction shape.
   VCO / sound-source, LFO / continuous modulator, envelope shaper,
   gate trigger, MIDI CC, FH-2 trigger, etc.
2. **Machine** — which physical destination the voice talks to.
   FH-2, Yarns, ES-9, MIDI external (Ableton / AUM / specific synth),
   cv-router, etc. Mostly derivable from the device alias used in
   the binding.
3. **Musical bundle** — the conceptual "instrument": *the lead*,
   *the bass*, *the pad*, *the drums*. A bundle gathers voices of
   different kinds and machines into one mental unit. **User-
   assigned**, not derivable. An LFO can sit in the "bass" bundle
   because that's how the musician thinks of it, but is freely
   re-routable to any destination.

The axes are **orthogonal**: the bass bundle's cutoff LFO is in the
LFO kind, on the FH-2 machine, in the bass bundle. Same cell, three
classifications, all true at once.

## Visual encoding

Three visual channels for three axes — so cells stay identifiable
when re-clustered:

| Visual property | Axis            | Example                                  |
|-----------------|-----------------|------------------------------------------|
| **Color**       | Musical bundle  | bass=blue, pad=purple, lead=green, …     |
| **Shape**       | Voice kind      | △ VCO, ◇ LFO, ⬡ CC, ▢ trigger, ⬢ env    |
| **Border style**| Machine         | solid=FH-2, double=Yarns, dashed=ES-9, … |

A "bass-cutoff LFO routed through FH-2" is then a **diamond**
(LFO), **blue** (bass bundle), **solid border** (FH-2). When you
re-cluster by machine, all FH-2 cells gather; bass-cutoff stays a
blue-diamond-solid in its new home, so your eye doesn't lose it.

The 1980s vector-graphics aesthetic Calypso already has lends
itself naturally to shape-coded primitives — Tempest, Battlezone,
Robotron-style bright wireframe polygons on dark background. Cells
render as outlined geometric shapes; they glow on activity. Not
sacred — could be reskinned without affecting the encoding.

## The "undifferentiated mass + cluster lens" UX

The cells are **not** in a fixed column structure. They live in an
undifferentiated 2D field that the user re-clusters by selecting an
axis as the lens:

- Cluster by **bundle** → bass / pad / lead / drums / FH-2-raw groups
- Cluster by **machine** → FH-2 / Yarns / ES-9 / MIDI-external groups
- Cluster by **voice kind** → VCOs / LFOs / triggers / envelopes groups

Switching lens regroups visually but preserves color/shape/border
on each cell, so re-orientation is fluid.

### Folding

Per-cluster fold (collapse/expand) is a strong affordance. With
30+ cells across a session, the focal need shifts moment-to-moment:
"working on bass right now → fold all non-bass clusters" or
"diagnosing an FH-2 issue → fold all non-FH-2 clusters."

**Fold state is ephemeral** — UI session preference, not persisted
in the .tidal. What the user folds is "what they're not paying
attention to right now," not a property of the composition. The
*lens choice* might persist (last-used clustering); per-cluster
fold state probably should not.

## .tidal as source of truth

A strong principle: whatever the UI looks like, **conceptually
there is still one single .tidal file** representing the current
state of the rig. The UI is a *view* over that file:

- vim-editable outside Calypso
- `git diff`-friendly
- Shareable as a gist / setup file
- `load <name>` round-trips with no data loss
- Fed line-by-line to the WS handler at fire time

The cell metadata (bundle, optional id, etc.) rides in **pragma
comments** — `-- @bundle bass` etc. Anything that doesn't
understand pragmas just sees comments. Calypso parses the pragmas
and uses them for clustering / coloring / id-tracking; the rest of
the toolchain (vim, git, `load`) sees plain text.

Calypso already has a pragma convention (`-- @bpm 120`-style); the
extension here is a small vocabulary of cell-metadata pragmas:

```
-- @id bass-cutoff
-- @bundle bass
bind bass-cutoff midi-cc-cont fh2 1 74
bass-cutoff :slow 4 sine
```

Voice kind and machine can usually be *derived* from the binding,
so the user doesn't have to author them. Bundle is the only
genuinely user-assigned axis.

### Linear-order vs cluster-order

The .tidal file's linear order = the firing order when `load` plays
it back. Clustering in the UI is a **read-only view**; it doesn't
clobber file order.

There can be a separate explicit user action: "rewrite the file in
cluster order." Useful occasionally; not a side effect of switching
lens.

## Stable cell identity + content hashing

Each cell has a **stable id** that persists across edits. The id is
the "card" in the Time Machine card-stack metaphor. Either an
auto-generated UUID or a human-readable name (the binding name is a
natural default — `bass-cutoff`, `lead`, etc.).

The cell's *content* (its expression text, after the pragmas) gets
**content-hashed**. Edit history per id is a sequence of (timestamp,
hash, text) tuples. The content hash IS the cell's identity-in-time.

### Where the history lives

Two viable storage options (not exclusive):

1. **git** — the .tidal file gets committed per save; a small
   "extract cell by id from every historical commit" tool
   synthesizes per-cell timelines on demand. Free, git-native,
   coarse granularity (per-commit).
2. **Sidecar SQLite** — a row per save, keyed by (cell-id, hash,
   timestamp, text). Sub-commit granularity (every keystroke pause,
   if you want); persists across `git stash`. Cheap to implement.

Coarse + fine layered: git for cross-session permanence, sidecar
for in-session scrubbing.

## Time Machine UI

Visualizes the per-cell hash chain with the receding-card-stack
metaphor (Apple's Time Machine for Finder). For a focused cell, you
flip backwards through past versions, scrubbing time. Each card is
one historical (text, hash) pair; the current one is in the front.

Old versions don't pollute the current .tidal — they're only
visible when the Time Machine UI is open.

## Where this connects to per-voice compiled modules (purerl-tidal)

This is the payoff that makes the hash-addressing more than a
filing trick.

Once purerl-tidal grows a compile pipeline (per the
`per-voice-refactor` direction), each cell-version's content hash
becomes the *name* of a generated PureScript module:
`Tidal.Voice.Generated.Cell_<hash>`. Identical content → identical
hash → existing .beam in the cache, **no recompile needed**.

Edit-and-revert lands on a hash you've seen before; the voice
gen_server's module pointer just swaps to the cached .beam. Time
Machine flip-back is *literally* "rebind voice to module
`Cell_<old-hash>`" — instantaneous, no recompile, because the old
code is still loaded (or one `code:load_file` away from the
compile cache).

So:
- **single .tidal file** = current cross-section (UI surface for
  the spatial axis)
- **per-cell hash chain** = temporal axis (UI surface: Time Machine
  card-stack)
- **content-addressed compiled modules** = runtime cache (no UI;
  pure infrastructure)

All three project onto the same underlying graph of
(cell-id, hash, content) triples.

## Decisions (2026-05-08, follow-up)

1. **Cell ↔ voice cardinality.** Cell is the *authoring* unit; voice
   is the *runtime* unit. Usually 1:1, but 1:N is supported for
   drum-machine-class devices (Patterning, Rample, QuadDrum, Digitakt,
   SuperDirt). A multi-voice cell is just a multi-statement block
   between pragma headers; one cell id, multiple `tidal_voice`
   gen_servers fire from it. Hash + Time Machine operate at cell
   granularity (flipping back rolls all the drum tracks together —
   correct for kit programming).

2. **Compile latency.** ~1.5s acceptable with cue-and-play; below
   ~500ms unlocks type-and-fire. Drives the compile pipeline design
   in purerl-tidal but doesn't gate the UI prototype.

3. **Pragma minimalism.** Just `@id` and `@bundle`. Kind + machine
   re-derived from the binding's PrimAction / device alias. For
   multi-voice cells, kind/machine become summaries ("mostly
   triggers, all FH-2"); slight fuzz, workable.

4. **Free positioning + decks; layout NOT persisted.** Cells sit on
   a 2D canvas, free positioning. Decks (stack-in-space) compose
   alongside Time Machine (stack-in-time); both use the card
   metaphor, both are about cards-on-a-desktop. Long-term:
   Tarot Music integration — tarot cards as their own deck on the
   same surface, performance-projection-friendly. **Layout is
   in-session only for now**: positions don't persist between
   sessions, and don't survive a pivot/cluster. Sidecar / pragma
   persistence is deferred until prototype use surfaces the actual
   needs.

5. **New view, no deletion.** Voice-cells lands as an additional
   top-level pane (Cmd-8 or similar). Existing seven panes
   (composition, cells, Vocabulary, Mini-notation, Replies, Config,
   Hylograph) all stay. We migrate features INTO voice-cells over
   time rather than out-and-then-back.

## Refinements

- **Config cells form a separate clump that never gets the pivot-
  table treatment.** Rig-config statements (`bind`, `unbind`,
  `midi-device`, `fh2-envelope`, `fh2-gate`) are setup, not music;
  they don't participate in cluster-by-bundle / cluster-by-machine
  views. They sit in a fixed config zone (typically the top of
  the .tidal). Music cells (`<name> "<pattern>"`, `<name> :<expr>`,
  `fh2-shape`, `bpm`, `hush`) are the ones on the canvas.
  Detection is by first-non-pragma-statement prefix; no pragma
  needed to declare config-vs-music.

## Direction shift (later 2026-05-08)

After landing the drag-and-drop deck prototype, the design pivoted
toward a **HyperCard / vector-poker-game** aesthetic — "weird mix
of HyperCard and Tempest/Battlezone, vector graphics poker game
from an alternative universe 1982." The pivot:

- **Drop the pivot-table model.** No clustering by machine / kind
  / bundle as switchable lenses. The single grouping that matters
  is the user-defined "musical voice" stack. Machine and kind are
  derivable and surface only as hints (icons), not as group axes.
- **Drop drag-and-drop.** Each card has a **colour picker** (a
  3×3 grid popover) that assigns it to a stack. All cards in a
  stack share the same colour; that's the visual identity of the
  stack. Picker has 9 cells: 1 "no stack" + 8 stack colours.
- **Cards look like cards.** Rounded corners, structured face:
  header (stack-coloured background, BLACK text on top for high
  contrast — playing-card title-bar feel) carries a type icon +
  voice name + colour-swatch trigger; body shows expression
  preview; footer carries cue + play affordances.
- **Type → icon, not colour.** Triangle (melodic), square
  (trigger), diamond (LFO/modulator), hex (CC), envelope-shape,
  lightning (FH-2 trigger). Derivable from binding shape; placed
  in the header as a small geometric primitive.
- **Cue + play on every card.** Two affordances. In the
  prototype both fire immediately (no compile pipeline yet); the
  visual separation prepares the slot for future "cue =
  compile-and-arm-for-bar; play = fire-now" semantics.
- **Fan-out per stack.** Each stack has a fan affordance ("⋯")
  that spreads its cards in a 2-column grid for editing. Z-lifted
  above other stacks with a backdrop glow, so it reads as
  "modal-ish but not really." Restack button ("▣") collapses
  back to the overlapping stack.
- **Config stack remains special.** Separate top zone, no
  picker, single fire button (no cue/play distinction).

The aesthetic might continue to evolve toward Hylograph-rendered
geometry rather than HTML/CSS once the interaction model
stabilises, but Halogen/HTML is the prototype substrate.

## Future: SVG cards with flip-to-back

Once the interaction model stabilises, redo card rendering in SVG.
Two payoffs:

1. **Vector quality at all sizes.** Cards shape-cleanly at any zoom
  without antialiasing artefacts; the geometric primitives in the
  type icons can be real SVG paths rather than Unicode glyphs.
2. **Flip-to-back animation.** Each card has a *front* (current
  surface: header / body / footer with the expression text) and a
  *back* (a live visualisation — the pattern's events on a cycle
  ring, the LFO's curve, the FH-2 envelope shape, etc.). A 3D
  flip transition swaps front for back; the back is interactive
  (drag the cycle ring, scrub the envelope curve, etc.) and the
  changes propagate back through the same WS verbs.

This is plausibly the bridge between the cell metaphor and the
"data-flow computing surfaces with live feedback" aspiration —
the back of the card IS the visualisation, and the visualisation
IS the live mutation surface.

## Future: config sub-stacks

The config pseudo-stack currently mixes `bind`, `midi-device`,
`fh2-envelope`, `bpm`, `log-level` etc. into one collapsed pile.
When that pile gets long it might be worth splitting into multiple
config stacks by verb category (devices / bindings / FH-2 setup /
runtime config). Open question whether one "config zone" with
multiple stacks reads better than one stack with sorted contents.
Deferred until the prototype gets enough config cells to feel the
pain.

## Day 1 progress (2026-05-08)

Prototype scaffolding landed across the day in roughly four phases:

1. **Two-zone layout, lone cards.** Static visual encoding, no
   grouping. Pane wired up at Cmd-8 reusing existing `state.cells`.
2. **Drag-and-drop decks.** Drag a card onto another to form a
   deck; cycle / explode toolbar buttons. *Discarded next phase.*
3. **Card v2 + colour picker.** Header / body / footer card
   structure, 9-swatch picker popover assigns to a stack, fan-out
   into 2-column grid. Vector-poker-game aesthetic locked in.
4. **Header-click stack control + vertical fan.** Front-card
   header click fans; back-card header click brings to front; any
   header click in a fanned stack restacks. Fan-out is now a
   single vertical column — header colour + vertical alignment
   carry group identity, no wrapping border / backdrop needed.
   Config pre-stacked inline among music stacks. Cards bigger,
   stacks distributed evenly across the canvas.

What works: stack assignment is fluid (pick a colour, card joins
that stack); fan-out / restack is one click on the header;
config visually distinct (dashed amber); cue + play affordances
on every music card; type icons (▲ ◇ ⬡ ⚡ ✦ ⚙ ♩ ■) infer from cell
content.

What hasn't been done: in-card editing, persistence of stack
assignment across sessions, picker dismiss-on-outside-click,
Tidal-line wrapping inside the card body, the SVG flip-to-back
visualisation idea, hooking the cards' `cue` button to a
real cue-and-play queue (today both buttons → FireCell).

## Open question for next session: in-card editing

Each card today shows a 4-line preview of the cell's expression.
Editing still happens in the existing Cells pane. The next
question is: how does in-card editing work?

Three plausible directions:

1. **Click-to-grow (double-dimensions).** Click anywhere in the
   card body to enter edit mode; the card grows to ~28rem × ~2×
   height (quadrupling its area). Other stacks reflow around the
   focused card. Fits the HyperCard "card-as-primary-spatial-
   object" framing — the card grows because it's now the active
   surface. Click outside / Esc / fire to commit and shrink back.
2. **Smart in-place editing.** Card body becomes editable with
   line-wrapping / code-folding to keep the existing footprint.
   Less dramatic; cards stay the same size; might not give enough
   room for long expressions.
3. **Pop-to-side-panel / modal.** Click → expression opens in a
   side panel (or modal) with a full editor. Cleanest separation;
   breaks the "stay on the canvas" feel.

Andrew's instinct: option 1 (click to grow) is worth trying
first. Decision deferred to next session; flag the existing
CodeMirror-backed Editor.purs as reusable for whichever path we
pick.

## Suggested first concrete moves

Once decisions on the open questions land, plausible build order:

1. **Pragma vocabulary** — extend Calypso's existing pragma parser
   for `@id`, `@bundle`. (Cheap; unlocks the metadata layer.)
2. **Cell extraction** — parse the .tidal file into a list of
   `Cell { id, bundle, body, … }` records.
3. **Visual encoding renderer** — given a cell's binding +
   bundle, render the geometric primitive (color/shape/border).
4. **Cluster lens** — UI control + group-by logic over the cell
   list.
5. **Folding** — per-cluster collapse/expand, ephemeral state.
6. **Sidecar history** — write (id, hash, text, ts) on save.
7. **Time Machine UI** — receding-card visualizer over the per-id
   hash chain.

These are independently shippable — the design admits a gradual
migration from today's text-cells to the voice-cells surface.

## Aesthetic note

The 80s vector-graphics aesthetic isn't load-bearing — it's a
stylistic choice that happens to map well to shape-coded
primitives. The encoding (color = bundle, shape = kind, border =
machine) works in any aesthetic. Re-skinning to a softer / more
modern look would be a CSS swap, not an architectural change.
