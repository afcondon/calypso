# `.tiderl` format + Model B architecture (2026-05-14)

**Status:** DRAFT. Companion to the architectural-bet doc; this is the
data-model piece that the bet doesn't address. Land this, and the
composition pane / cards / hylograph become three lenses on a single
textual source of truth.

## The bet

> A `.tiderl` file is the canonical state of a Calypso workspace.
> Composition pane, Voice Cells, and Hylograph are projections of the
> same AST. The live-coding contract — *the file is the music* — is
> preserved end-to-end, even with the rich card-stacking surface.

This replaces today's split where composition holds devices/bindings/
polysignals and cards hold patterns/verb-cells. Both surfaces become
views of one file; closing a card hides a lens without losing data;
promoting a scratch card writes it into the file; round-tripping is
automatic because both sides share an AST.

## Why a new format

`.tidal` is a poor fit for what Calypso actually compiles. The
grammar already diverges substantially:

- Device declarations (`midi`, `es9`, `fh2`, expander chains)
- Typed bindings (`midi-note`, `cv`, `cv-cont`, `gate`, `midi-cc`,
  `midi-cc-cont`) with device aliases + latency clauses
- Polysignal blocks with `<>` continuation markers and 8-slot vectors
- Latency aliasing (`lat` ≡ `latency`)
- Soon: `cue` declarations carrying cards, `control` declarations for
  the live-control bus, eventual structural-composition primitives
  (`arrange`, sections, BPM patterns)

Pragma-comments-on-top would be the apologetic path. First-class
grammar is the honest one. Calling the format `.tiderl` (tidal + erl,
naming the bridge to purerl-tidal) declares the divergence cleanly and
unblocks grammar work that's currently held back by "but Tidal does X."

**Extension:** `.tiderl`. Alternatives considered: `.calypso`,
`.tdl`, `.tide`. `.tiderl` reads instantly to anyone who's worked
with purerl-tidal; the others lose the rig-control specificity.

## File structure

Canonical order, with section header comments. Each section folds
independently in the composition pane.

```
-- # Transport
bpm 124            -- default tempo (yields to Link mesh when peers present)
link sync on       -- follow Link broadcasts; `link sync off` forces local bpm

-- # Devices
midi fh2     "FH-2"
midi fh2-qd  "FH-2" lat 69
midi live    "IAC Driver Tidal" lat 30
es9  es9     "ES-9"

-- # Bindings
midi-note qd1 fh2-qd 14 60 100 50
midi-note qd2 fh2-qd 15 60 100 50
cv      cip-pitch es9 0 voct
cv-cont cip-damp  es9 1
gate    cip-gate  fh2 0

-- # Polysignals
polylfo banks cv1                                                <>
  ratios [1,     2,     3,     5,     1.3,   2.6,   5.2,   10.4] <>
  shapes [tri,   tri,   sin,   sin,   saw,   saw,   sqr,   sqr ] <>
  ranges [±5v,   ±5v,   ±5v,   ±5v,   +5v,   +5v,   +5v,   +5v ]

-- # Controls
control bass-amp   = 0.85
control filter-mod = 0.60

-- # Tags
tag fill    = off
tag section = verse

-- # Cues
cue d-qd1-a [mvoice=drums tvoice=qd1]
  mini "x ~ ~ ~ x ~ x ~"

cue d-qd1-b [mvoice=drums tvoice=qd1]
  every 8 rev (mini "x ~ x x x ~ ~ x")

cue d-qd2-a [mvoice=drums tvoice=qd2]
  every 4 (fast 2) (mini "~ ~ x ~ ~ ~ x ~")

cue b-pitch-a [mvoice=bass tvoice=cip-pitch]
  mini "c2 e2 g2 ~ b2 ~ g2 e2"
```

Section header form: `-- # <name>`. The leading `-- #` is comment
syntax in both Tidal and `.tiderl`, so an unaware reader sees comments;
Calypso's parser tags each as a fold-region boundary.

## Grammar additions

### `cue <id> [<kv-pairs>]` — card declaration

```
cue <id> [<key>=<value> ...]
  <body>...
```

- `id` is a user-supplied identifier, unique within the file.
- Metadata kwargs in brackets: `mvoice=<label>`, `tvoice=<binding>`,
  optionally `author=<who>`, `comment=<short>`, `status=<scratch|live>`.
- Body is the cell source, indented under the header. Multi-line bodies
  continue at the same indent.

Examples:

```
cue d-qd1-a [mvoice=drums tvoice=qd1]
  mini "x ~ ~ ~ x ~ x ~"

cue ctrl-set-bass [mvoice=ctrl]
  set-control bass-amp 0.85

cue p-lfo-banks [mvoice=poly tvoice=banks]
  polylfo banks cv1 <>
    ratios [1, 2, 3, 5, 1.3, 2.6, 5.2, 10.4] <>
    shapes [tri, tri, sin, sin, saw, saw, sqr, sqr]
```

The body's first word is what `isVerbCell` reads to decide dispatch:
verb bodies dispatch as verbs, music bodies wrap in cue+play-armed.
That logic stays exactly as it is today; only the carrier changes.

### `control <name> = <value>` — initial live-control values

```
control bass-amp   = 0.85
control filter-mod = 0.60
```

Declarative form for live-control-bus values. On session load, the
runtime installs these as starting values. The existing `set-control
<name> <value>` verb (firable from a card) updates them at runtime.
Distinction: `control` is in the file (declarative); `set-control` is
a verb (imperative side effect, lives in a card).

### Future: structural composition (placeholder)

The grammar should reserve room for:

```
-- # Structure  (future, not yet implemented)
section verse  = arrange [d-qd1-a, b-pitch-a, p-pad-1 * 4]
section chorus = arrange [d-qd1-b, b-pitch-a * 2, p-pad-1, p-lead-a]
piece          = [verse, chorus, verse, chorus, chorus, outro]
```

Cards reference each other by id. `arrange` / `timeCat` / `*` are
combinators in the existing branched-pattern work. Not blocking
this design; the file structure leaves a `Structure` section where
this lands.

## Tags and conditional composition (forward-looking)

A second composition vector — orthogonal to structural arrangement —
is **conditional dispatch based on tag state**. Inspired by Elektron's
"Fill" tagging (and Patterning's per-track tags): patterns can react
to runtime-mutable named flags, swapping their content based on what's
on/off right now. The format and runtime need to accommodate this
from the grammar's first design pass so we're not bolting it on later.

### Tags as runtime state

A *tag* is a named slot in the runtime control state, holding a
boolean or a short string value. Lives on the same substrate as the
live-control bus (`reference_purerl_tidal_live_control_substrate`),
extended with string-typed slots.

File grammar — declarative initial values:

```
-- # Tags
tag fill    = off
tag section = verse
tag double  = off
```

Runtime mutation via verbs (firable from cards, just like
`set-control`):

```
set-tag fill on
set-tag section chorus
set-tag double off
```

Toggle form for booleans: `toggle-tag fill`.

### Pattern-level conditional combinators

In cell bodies (cue bodies), Pattern combinators consult the tag bus
at query time:

```purescript
-- Boolean tag: pick between two patterns at every event
when (tag "fill") (mini "x x x x x x x x") (mini "x ~ x ~")

-- String tag: dispatch among many cases
byTag "section"
  [ "verse"  ~> mini "c2 e2 g2 ~ b2 ~ g2 e2"
  , "chorus" ~> mini "c3 g2 e3 c3 a2 g2 e2 c2"
  , "intro"  ~> silence
  ]

-- Common case: when a tag is on, layer additional events
withTag (tag "double") (\p -> stack [p, fast 2 p]) (mini "c2 e2 g2")
```

Backend implementation: extends the existing ETS-backed control bus
with a string-value variant. `tag` becomes a primitive that produces
a query-time-resolved `Pattern Boolean` or `Pattern String`. The
combinators (`when`, `byTag`, `withTag`) are pure Pattern algebra
over those primitives. **Only available in purerl-tidal-side
dispatch** — autonomous polysignals running on the FH-2 can't read
tag state because the FH-2 has no view of the bus.

### Card-level and stack-level tag conditioning

Beyond cue bodies, tags can gate cards and stacks themselves:

```
cue d-fill-a [mvoice=drums tvoice=qd2 when=fill]
  mini "x x x x x x x x"
```

When `fill` is off, this card is **muted** — clicking play does
nothing, the card is dimmed in the UI. When `fill` is on, it
fires normally. The runtime checks `when=<tag>` at play time and
skips the install if the tag's off.

Stack-level:

```
mvoice drums-fill [when=fill]
```

When `fill` is off, the entire `drums-fill` mvoice column is hidden
from the cards view and its contents are muted. When on, it appears.

This is the analogue of Elektron's Fill button at the
mvoice-stack scale: a whole alternate set of card-stacks that
materializes when its conditioning tag is on.

### Multi-level summary

| Level    | Mechanism                              | Granularity            |
|----------|----------------------------------------|------------------------|
| Pattern  | `when` / `byTag` / `withTag` in cue    | Per-event branching    |
| Card     | `when=<tag>` metadata on the cue       | Whole-card mute/active |
| Stack    | `when=<tag>` on the mvoice declaration | Whole-column mute/show |

All three read from the same tag namespace; the differences are
where the gate sits.

### What this enables

- **Verse/chorus song form** without leaving live-coding: tag a
  `section` value, write distinct patterns per section, switch with
  one `set-tag` fire.
- **Fills** at any scale: per-step inside a pattern, per-card,
  per-stack.
- **A/B/C variants** as cards-with-tags rather than separate cells.
- **Dynamics**: tag `intensity` = low/med/high, branch entire
  voicings.
- **Coordinated mute groups**: tag `bass-out` mutes the bass mvoice
  stack and any patterns that include bass triggers.

### Tags-as-ADTs (future direction, not v1)

The instinct: tags as a sum type with constructors carrying values
(`Section Verse | Section Chorus | Fill | Intensity Int`) would let
the type system catch typos and let tags carry richer state.
Tempting, but it pulls in a meaningful chunk of grammar work (ADT
declarations in the file, type-checking at parse time, exhaustive-
match warnings on `byTag`) that's hard to scope without first
seeing where stringly-typed pain actually emerges.

V1 stays with strings (with set-membership = boolean view). If we
find ourselves frequently mistyping tag names, accidentally pattern-
matching nonexistent values, or wanting tags to carry payloads
(e.g. `Intensity 7` rather than just an `intensity` tag and a
separate `intensity-value` slot), revisit. Until then: strings are
fine.

### What this does NOT do (out of scope here)

- **FH-2 polysignal conditioning** — polysignals run autonomously
  on the FH-2; there's no path to feed tag state to them. They
  remain "always firing, until re-configured." The way to gate a
  polysignal is to re-fire it with a different config (or with
  `silenceOnBank` set) — that's a `set-tag` → `re-fire-polysignal`
  cell chain, not an automatic tag reaction.
- **String tags with arbitrary keys** — initial scope is `on/off`
  booleans + a fixed enum of string values declared in the `# Tags`
  section. Open-ended string tags are a later step if the typed
  enum proves too rigid.

### File grammar additions for tags

```
-- # Tags
tag <name> = <default-value>           -- declaration

-- inside # Cues, metadata kwargs:
cue <id> [... when=<tag>]              -- card-level gate

-- inside # Stacks (new section, optional):
mvoice <name> [when=<tag>]             -- mvoice-level gate
```

`# Tags` section sits between `# Controls` and `# Cues`. `# Stacks`
is a new section that declares mvoice-level metadata (today there's
no place for "show all mvoices" config — mvoices exist implicitly as
the union of all cues' `mvoice` kwargs).

## Parser / serializer contract

**Round-trip property.** For any AST `a`:

```
parse (serialize a) ≡ a
```

**Canonical form property.** For any well-formed text `t`:

```
serialize (parse t) ≡ canonical(t)
```

…where `canonical(t)` collapses non-semantic variance (whitespace,
column alignment, ordering within a section).

Implementation:

- Single AST in `Calypso.Composition` carries every statement kind,
  including `Cue` and `Control`.
- `parseComposition :: String → Either ParseError Composition` extended
  to recognise new statement kinds.
- A new `serializeComposition :: Composition → String` (renamed /
  generalised from the existing polysignal autoformatter).
- `autoformatOnFire` becomes "serialize the whole composition, replace
  the editor's content". Today's polysignal-only autoformat is the
  natural starting point.

**Editor preservation.** Pretty-printing must not destroy user
formatting *within* a section (intra-statement whitespace, list
column-alignment in polysignals). The polysignal collapser already
treats vector column-alignment as canonical; we keep that contract
and don't reflow within-statement content. Across statements,
ordering follows the canonical section structure.

## Card lifecycle in Model B

Each card on the frontend carries two source strings:

```purescript
type CardState =
  { fileSource :: Maybe String  -- text as currently in the file
  , liveSource :: String         -- editor content
  , armedModule :: Maybe String  -- last successful cue
  , history :: Array {body, modul}
  , ...
  }
```

**States:**

| `fileSource` | `liveSource`  | meaning                                  |
|--------------|---------------|------------------------------------------|
| `Just s`     | `s`           | clean — file == card                     |
| `Just s`     | `s' ≠ s`      | dirty — card ahead of file               |
| `Nothing`    | `s`           | scratch — never written to file          |
| `Just s`     | `""`          | tombstone — file has it, card deleted    |

UI cues:
- Clean card: no marker.
- Dirty card: `*` after the title; subtle border accent.
- Scratch card: dashed border around the whole card (re-using the
  existing TvUnknown placeholder treatment), or a small "scratch" tag.

**Actions:**

- **Edit** → updates `liveSource`. Comparison vs `fileSource` drives
  the dirty marker.
- **Cue → Play** → fires the card. Doesn't touch `fileSource`.
- **Promote** → copies `liveSource` into the file (insert if scratch,
  replace if existing). `fileSource ← liveSource`. Marker clears.
- **Close** → hides the card from the cards view. Requires
  `fileSource = Just _` (i.e., file-card only). Tombstones still
  show in the file; closed-but-file-present cards can be re-opened.
- **Delete** → drops the card entirely. Removes the `cue` declaration
  from the file. Confirmation required for promoted cards.
- **Fetch** → opens a previously-closed file-card back into the cards
  view.

**Scratch cards:**

- Created via "+ new card" or "demote from composition" (extract a
  cursor-line from the composition pane into a new card).
- Cannot be closed (no file home to return to). Must promote or
  delete.
- Don't appear in the file until promoted.
- The two-tier interaction prevents accidental loss: nothing in the
  file disappears silently; nothing in cards-only gets "closed" into
  oblivion.

## Composition pane UX

**Foldable sections.** Each `-- # <name>` header is a fold control.
Default expanded. Per-section state persisted across sessions
(localStorage; survives reload).

**Cues section is special.** Sub-folded by `mvoice` so the cues
section reads as:

```
-- # Cues
  ▾ drums (3)
      cue d-qd1-a [mvoice=drums tvoice=qd1]
        mini "..."
      cue d-qd1-b [mvoice=drums tvoice=qd1]
        every 8 rev (mini "...")
      cue d-qd2-a [mvoice=drums tvoice=qd2]
        ...
  ▾ bass (8)
      cue b-pitch-a [mvoice=bass tvoice=cip-pitch]
        ...
  ▸ pad (3)
  ▸ lead (6)
  ▸ ctrl (4)
```

Click a sub-fold header → collapse/expand that mvoice's cues.

**Click-to-open-as-card.** Click any `cue <id>` line's gutter →
opens that card in the Voice Cells view (if closed) or focuses it
(if already open). Bidirectional: clicking the cards view's card
header could scroll the composition pane to that cue's declaration.

**The catalogue analogy.** Composition pane is the table of contents;
cards are the chapters you've pulled out to work on. Closing a card
puts it back in the catalogue; opening fetches it. The data never
moves, only the lens.

## Hylograph as the third lens

Composition and cards are projections of authored state; hylograph
sits on top with two distinct jobs:

**Job 1 — visualisation.** Reads the runtime state and shows what's
actually happening:

- Same voice identities as composition + cards (each `bind` / `cue`
  resolves to a runtime voice).
- Augmented with live event traces (current arc position, recent
  emits, armed-but-not-firing status, tag-state indicators, etc.).
- Edits to composition or cards re-flow the static layout; runtime
  events animate over the top.
- A "have you specified what you thought you specified?" affordance
  — the visual feedback loop that text doesn't give you.

**Job 2 — graphical editing.** Affordances that text can't give. We
don't yet know what specifically those affordances will be; the
tilted-radio prototype suggested some directions (drag-to-retime,
gestural input, point-and-click routing), but the substantive list
will emerge during construction rather than being designed up front.
What we DO commit to is the *flow direction* — hylograph-as-editor
operates on cards, never on the file. Specific edit primitives are
deliberately under-specified here.

The flow of edits:

```
text edit  →  composition AST  →  cards re-derived
card edit  →  in-memory card state  →  composition serialize on Promote
hylograph  →  in-memory card state  →  composition serialize on Promote
```

**Hylograph edits cards, not the file.** Same pattern as cards: edits
update the live working state; the file changes only when the user
explicitly promotes. This makes the three-way sync tractable —
composition is the canonical save layer, cards are the live working
layer, hylograph is a graphical lens on cards that produces
card-shaped edits.

When you drag a note in hylograph, the card's `liveSource` updates,
the card flips dirty, the composition pane's text view shows the
unchanged file source, the corresponding `cue` line gets a dirty
marker. Promote when you're happy; revert by re-fetching from
composition.

## Migration plan

Phased so the rig stays operational throughout.

**Phase 1: Grammar + AST extensions.** Add `Cue` and `Control`
statement kinds to `Calypso.Composition`. Update parser. Update
extractTvoiceTypesFromComposition to surface cue metadata. Build
canonical serializer. Round-trip tests in
`shared/test/.../ParserSpec.purs`.

**Phase 2: Model B switch.** Frontend stops carrying a separate
`cells :: Array Cell` in `State` — derives cards from the composition
AST's `Cue` statements instead. The wire shape `CompileRequest`
moves to a single `composition :: String` field; the `cells` array
becomes a compatibility-mode read-path that lifts old sessions into
the new model.

**Phase 3: JSON → flat file.** `calypso-session.json` (a JSON
wrapper around composition source + cells + runtime) becomes
`calypso-session.tiderl` (a flat text file). The runtime field
becomes a `-- @runtime=...` magic comment at the top, or a
`runtime <name>` statement. Loading either old or new format works
for one release cycle; the JSON wrapper is dropped after.

**Phase 4: Composition pane UX.** Foldable sections, click-to-open,
mvoice sub-folding, dirty markers, close/fetch buttons.

**Phase 5: Hylograph.** Reads composition state for voice identity;
overlays runtime traces from purerl-tidal's StateBus + per-voice
supervisor emits.

Phases 1–2 are roughly a week's focused work. Phase 3 is a few
days. Phase 4 is a week. Phase 5 is its own multi-week project.

## Open questions

1. **Card id format.** User-supplied identifiers (`d-qd1-a`) read
   cleanly in source but force a naming decision. Auto-generated
   ids (`cell-007`) are ergonomic but ugly. A middle path:
   default to `<mvoice>-<tvoice>-<letter>` and rename on demand.
   What's the right default?

   *(Tags add a wrinkle: if a card carries `when=<tag>` the id
   could fold that in, e.g. `d-qd2-fill-a`. Or keep id orthogonal
   to gate, so renaming a tag doesn't churn ids.)*

2. **Polysignals in the file: declarative or as cues?** Today a
   polysignal block fires via composition's `▶ fire`. If a user
   wraps the same polysignal in a `cue p-lfo-banks` card, does the
   declarative block move into the Cues section? Or do we let both
   forms coexist? Probably: declarative blocks in `# Polysignals`,
   cue-wrapped variants in `# Cues`, with the latter overriding when
   present. Needs concrete rule.

3. **`set-control` cells in the file.** Cards with `set-control`
   verbs ARE runtime side effects — they belong in `# Cues`, not in
   `# Controls`. But the muscle-memory says "they're setting a
   control value, surely they're declarative." Document the
   distinction clearly.

4. **Section ordering enforcement.** Strict (parser rejects out-of-
   order sections) or lenient (canonicalize at serialize time)?
   Probably lenient — easier for users editing freehand. The
   serializer always emits canonical order.

5. **Comment preservation.** User comments within a section need to
   round-trip. The polysignal autoformatter today doesn't preserve
   stray comments inside a block; we'll need to extend the AST to
   capture them as `Comment` nodes attached to following statements,
   or accept that comments outside section headers get lost on
   re-serialize. Trade-off: AST complexity vs UX surprise.

6. **Extension migration.** Rename `purerl-tidal/setup/*.tidal` to
   `*.tiderl` or leave as-is? The setup files use a strict subset of
   wire syntax (`bind <name> midi-note ...`); they're loaded by the
   daemon, not by Calypso, and the daemon doesn't care about the
   filename. Probably leave them as `.tidal` and only adopt `.tiderl`
   for Calypso-authored files. The grammars are equivalent at the
   subset; the extension just marks intent.

7. **Tag value types.** *Decided 2026-05-14: strings.* Tags are
   string-valued slots; "boolean" gates are really set-membership
   checks (`tagset contains "middle8"` is the boolean view). Strict
   typing via ADTs (`Section Verse`, `Fill`, etc.) is held as a
   future direction if stringly-typed pain emerges — see
   "Tags-as-ADTs" subsection. Not in v1.

8. **Tag reactivity model.** *Decided 2026-05-14: push.* On
   `set-tag`, the backend pushes the new state to all subscribers
   over the WS, voices re-evaluate immediately. Pull-from-bus
   semantics (the current live-control-bus model) is the
   implementation, push is the wire-level guarantee — clients see
   tag changes promptly, no polling.

   *Forward direction worth flagging:* **tags-as-patterns**. The
   real composition lever is setting tags *via a pattern*, e.g.
   `pattern-set-tag section "verse verse chorus chorus"` — the
   tag flips on cycle boundaries driven by the pattern. That's
   the same model as `cv-cont` but for tag values: a Pattern that
   emits tag-set events at scheduled times. Once that lands the
   structural-composition story gets meaningfully richer; the
   `# Structure` section can express form via tag-patterns rather
   than the more rigid `arrange [...]` form. Design pass when we
   build it.

9. **Polysignal tag-fire chain.** *Deferred 2026-05-14, aspirational.*
   Polysignals can't read tags reactively (FH-2 has no bus view),
   so the v1 substitute is a manual `set-tag` + follow-up
   `re-fire-polysignal` cell chain. Automating this — `on-tag fill
   = fire-polysignal polylfo-fast` style — is wanted long-term but
   not blocking; its own design pass when the time comes.

## Related docs

- `architectural-bet-2026-05-14.md` — the cue/play-armed bet that
  necessitated the cards-vs-composition reckoning.
- `card-language-investigation-2026-05-14.md` — the three-language
  situation in cells (pre-path-2/4 removal). Sets up the
  "what *is* the language?" question that .tiderl answers at the
  file level.
- `shell-refactor-plan-2026-05-14.md` — the Shell.purs refactor.
  Model B implementation will live in the per-pane modules already
  extracted plus new `Composition` work in `shared/`.
- `polysignals-grammar.md` — the existing polysignal grammar that
  the new card declarations should harmonise with stylistically
  (kwargs in brackets vs `<>` continuation lines are the two patterns
  that need to coexist).
- (Future) `cue-warming-plan.md` — warm-compiler work (#11). Model
  B + warm-compiler together are the two architectural pieces that
  make the cue/play-armed bet actually feel live.
