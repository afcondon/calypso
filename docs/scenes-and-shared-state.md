# Compositional structure across cells — design options

Status: open question parked 2026-05-09 immediately after the
`cells-as-purescript-2026-05-09` milestone landed.  Captures the
conversation Andrew and I had at the end of that session so a future
pass can pick it up cold.

## The tension

After PR3 + Phase 1 (cell prelude with mini-notation parity), every
voice card is an immutable hashed module with its own pattern.  That's
beautiful for atomicity, hot-load, and history — but **it atomises
the whole musical surface**.  Every tvoice is a disconnected atom:

- A "kick" cell knows nothing about a "bass" cell.
- "Chorus" and "verse" don't exist as concepts in the system.
- Section changes (verse → chorus → bridge) have nowhere to live —
  they're a compositional concept that has no representation.

If you want all the basslines, drum patterns, lead lines, and pads to
"respond" to a section change, today you have to:

1. Re-cue a different version of every cell manually, or
2. Hardcode each cell to its section variant ("bass-verse",
   "bass-chorus", etc.) as separate cards.

Andrew's observation: *"we've atomised and disconnected all these
lines... but we want to bring in macro, compositional changes in some
ways"*.

## Three directions

These are not mutually exclusive — but they're substantively different
in shape, cost, and what they unlock.  Worth understanding all three
before committing.

### Direction A — code pane as a shared PureScript module

**Idea.**  The composition pane stops being a `.tidal` config file
and becomes `Session.purs` (or similar).  It compiles like any other
PureScript module and exports values that cells can import.

```purescript
-- code pane:
module Session where
chorusScale = mixolydian
verseScale = dorian
bassRoots = [c2, e2, a2, g2]
versePitches = [...]

-- a cell:
quantize Session.chorusScale (degrees [0, 2, 4, 7])
```

**Mechanics.**  Re-firing the code pane recompiles `Session`.  That
invalidates every cell that imports it (purs externs / corefn
dependency walk).  Each dependent cell needs re-cuing — at today's
~7s cold compile cost per cell, that's painful for a 6-tvoice
session.  PR4's daemon path would dramatically reduce this.

**Strengths.**
- Maximum expressiveness — anything you can write in PureScript is
  shareable.
- Type safety across the cell/session boundary.
- Lifts naturally out of Phase 3a (scales/chords in scope) — the
  same idea, but user-defined.

**Weaknesses.**
- Recompile budget hostile to live use until daemon lands.
- "What invalidates what" needs careful UX — if the user changes one
  constant in `Session`, what re-arms?

**When it's right.**  Studio-style preparation.  You define the
session's vocabulary up front, then the cells consume it.  Less
about live-reactive structure, more about structured authoring.

### Direction B — runtime-mutable state cells observe

**Idea.**  Session state lives in a runtime store (a gen_server, an
ETS row, whatever).  Cells declare what state they observe.  Pattern
queries read fresh state on each event.  State changes via a verb
(`set-state currentScale dorian`).  Patterns naturally produce
different events the next cycle.  No recompile.

**Mechanics.**  The Pattern abstraction needs to be state-aware
(or we layer a wrapper above it).  Today
`Pattern a = Pattern (State -> Array (Event a))` where State is the
query window.  We'd need session state in scope at query time —
either embedded in the State type, or threaded through a reader-style
context.

**Strengths.**
- No recompile cost.
- True live-reactivity — patterns *react* to state changes during a
  single fire, not just at re-arming time.
- Composable with existing cells without redefinition.

**Weaknesses.**
- Architecturally the deepest of the three.  Touches Pattern,
  Voice, the dispatcher.
- "What state is in scope" is a real design question (every cell
  sees everything?  Per-cell observation declarations?).
- Surfacing "what state matters right now" to the UI is non-trivial.

**When it's right.**  When you genuinely need patterns to respond
mid-cycle to state changes — modulating, filtering, gate density,
pitch envelope responding to performance gestures.

### Direction C — scene/clip-launcher arming

**Idea.**  Cells stay self-contained, but each cell is *tagged* with
one or more scene labels.  A "scene" is a named subset of armed-
modules-per-mvoice.  Triggering a scene fires `play-armed` for every
member.  Verse and chorus are scenes; the *which cells are armed*
changes, but the cells themselves don't.

**Mechanics.**  Pure UI/UX feature on top of the existing arming
infrastructure.  Add scene metadata to cells (probably a multi-tag,
since one cell could legitimately belong to multiple scenes —
"intro", "outro", "all").  Add a scene-fire gesture that batches
`play-armed` for every tagged cell.

**Strengths.**
- Closest to Ableton clip launcher / Bitwig-launcher / OG live-coding
  gestures.
- Composes beautifully with the "alternative repertoire within a
  stack" framing from the earlier voice-cells design — each card is
  already a scene member candidate.
- No recompile cost; reuses everything.
- Lightweight: tag, list, fire.  Probably a day's work.

**Weaknesses.**
- Doesn't unlock things A or B unlock — no shared *values*, no
  reactive patterns.  It's structural, not semantic.
- "What if I want both kick-A and kick-B in chorus" needs a clear
  semantic.  (One armed per mvoice; scene swaps the armed.)

**When it's right.**  When the gesture you want is "hit chorus and
six tvoices change pattern in lockstep".  Simplest path to *feel*
verse/chorus structure during play.

## Suggested ordering

Not committed; this is one reasonable phasing.

1. **Phase 3a now** (separate, tactical, ~5 min): scales / chords in
   scope.  Add `Tidal.Scales` and `Tidal.Chords` to the bulk re-
   exports of `Tidal.Cell.Prelude`.  Cells gain `dorian`, `minor7`,
   `noteInScale`, etc.  Bring closure to the question of "what's in
   scope today" before any structural moves.

2. **Direction C** as the next architectural move.  Tag cells with
   scene labels, scene-fire gesture.  Fully composes with the cards
   you already have; no recompile cost; matches live gestures.

3. **Direction A** when you've felt C's limits and have specific
   shared *values* you keep wanting to lift out (a key, a scale, a
   set of root notes).  By then, the daemon path (PR4) may have
   dropped the recompile cost enough to make A live-friendly.

4. **Direction B** if/when patterns-reacting-to-state during a single
   fire turns out to matter more than the workaround paths through
   A or C.

## Composition with what already exists

A few existing artefacts that any of these directions should fit
cleanly with:

- **Voice cells (PR3)** — outer stack = mvoice, cards in stack =
  alternative patterns for that mvoice.  Direction C makes "stack
  containing chorus-bass and verse-bass" a natural shape: each
  scene fire arms the right card.

- **Per-card history (this milestone)** — an automatic version log
  of one card's edits.  Orthogonal to scenes; a card might have
  100 history entries while only being tagged with "chorus".

- **Mvoice naming** — already explicit (input field).  Scenes would
  be a sibling concept (also explicit: tag input on the small
  card?).

- **Cell.Prelude** — Direction A is fundamentally a generalisation
  of the cell prelude pattern (a module cells import).  Phase 3a
  is the "static" version of A.

## Open implementation questions

Listed roughly in order of when they'd matter:

### For Direction C (closest to actionable)

- **Where do scene tags live?**  Per-cell metadata field (separate
  from source), comment directive (`-- @scene: chorus`), or a
  separate "scenes" view that owns the tagging?
- **One scene at a time, or layered?**  ("Verse" + "with-bridge-pad"
  fires both subsets?)
- **Empty-scene fire**: hush?  Or no-op?
- **Visual surface** in the modal / cards — a scene chip per tag?
  A scene-bar across the top of voice-cells column?  A separate
  toggleable column?
- **What about multi-card mvoices**: if a stack has three cards all
  tagged "chorus", what fires?  Most-recently-cued?  Most recent
  scene-fire winner?

### For Direction A

- **Recompile triggering**: explicit (`fire Session`) or automatic
  (file watcher)?
- **Cell invalidation**: do cells dependent on Session need explicit
  re-cuing, or auto-recue-on-Session-change?  The auto path needs
  the dependency graph from purs externs.
- **Hot-reload semantics**: if `chorusScale` changes from `dorian`
  to `mixolydian`, do the currently-playing cells switch on the
  next cycle, or stay on dorian until re-cued?

### For Direction B

- **What state is in scope per cell?**  All session state is
  promiscuous; per-cell observation lists is more disciplined.
- **Pattern type changes**: extend State, or layer above Pattern?
- **Update granularity**: per-event reads (state seen each tick),
  per-cycle reads (cached for the cycle), or per-fire reads
  (snapshotted at install)?

## Next-session pickup

If picking this up cold:

1. **Re-read the milestone** — `cells-as-purescript-2026-05-09` tag
   on both repos.  `purerl-tidal/docs/per-cell-compile-plan.md` is
   the engineering plan; `calypso/docs/voice-cells-design.md` is
   the UI plan.

2. **Andrew's instinct as of the parking** — undecided, taking time
   to think.  My read was that C is the most natural live-coding
   move and lightest weight; A is closest to his "shared module"
   thinking.  No commitment.

3. **Quick wins available without the big decision**:
   - **Phase 3a** (scales/chords in cell scope) — orthogonal,
     tactical, cheap.
   - **PR4 daemon** for purs-backend-erl re-emit cost — would make
     either A or "many small cells" much more tenable.
   - **mvoice / cellHistory persistence** across server restarts —
     deferred since the milestone.

4. **What we deliberately deferred**:
   - Phase 2 (host-language `:rev` / `:mult` / `jux` / fanout from
     Tidal.Expr in cell scope).
   - Promotion-from-cell-to-prelude (live UX for moving working
     experiments into shared vocabulary).
   - Any of the three directions above.
