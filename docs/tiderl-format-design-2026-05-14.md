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
bpm 124

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

Composition and cards are projections of the *authored* state — the
text and what it encodes. Hylograph is a projection of the *runtime*
state — what's actually playing right now:

- Same voice identities (each `bind` / `cue` resolves to a runtime
  voice).
- Augmented with live event traces (current arc position, recent
  emits, armed-but-not-firing status, etc.).
- Edits to composition or cards re-flow the static layout; runtime
  events animate over the top.

Hylograph never edits the file. It reads, visualises, and surfaces
"what's happening." The third lens.

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
