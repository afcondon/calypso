# Cue grammar evolution: toward music-foremost (2026-05-15)

**Status:** DRAFT. Companion to `tiderl-format-design-2026-05-14.md`. Today's
form (`cue cell-013 [mvoice=bass tvoice=cip-damp] = mini "..."`) achieves
1:1 commensurability but at the cost of heavy metadata on every line. This
doc explores how to push toward the impossible-dream north star:

> "nothing but music notation" + "round-tripping to cards" + "great error messages"

The three constraints over-constrain — perfect satisfaction is impossible.
The goal is to slide closer to the corner without sacrificing the others.

## What the file shows today

```
cue cell-001 [mvoice=setup]                        = fh2-gate 4 69 14
cue cell-005 [mvoice=drums tvoice=qd1]             = mini "x ~ ~ ~ x ~ x ~"
cue cell-006 [mvoice=drums tvoice=qd2]             = every 4 (fast 2) (mini "~ ~ x ~ ~ ~ x ~")
cue cell-009 [mvoice=drums tvoice=qd1]             = every 8 rev (mini "x ~ x x x ~ ~ x")
cue cell-013 [mvoice=bass  tvoice=cip-damp]        = mini "0.2 0.3 0.5 0.7 0.8 0.7 0.5 0.3"
cue cell-027 [mvoice=ctrl]                         = set-control bass-amp 0.85
```

Each line carries ~50 chars of bookkeeping and ~20 chars of music.
The repeated `mvoice=`/`tvoice=` labels add ~10 chars/line of pure noise.
Auto-generated ids (`cell-005`) carry no information.

## Information that must remain visible

The file is the source of truth. Anything the cards view shows must be
expressible in the source. What is the cards view actually showing?

1. **Card grouping by mvoice** — drums column, bass column, etc.
2. **Card binding** — every card targets a `tvoice` (the registered
   binding name), drives the card colour and type-of-content.
3. **Card content** — the music expression itself.
4. **Card ordering within the stack** — first-fired, second-fired, …
   (today defined by `mvoiceOrder` state on the frontend).
5. **Card identity** — for references from `arrange`-style structural
   composition (future work).

Things the file *doesn't* need to carry verbatim:
- The `cue` keyword (every line is a cue; the keyword is redundant)
- The labelled metadata (`mvoice=`/`tvoice=`) — positional or
  structural form expresses the same info
- The `=` separator (whitespace + indentation already separates header
  from body in the indented-continuation form)
- Auto-generated ids (`cell-005` carries no info; only matters when the
  user gives a cue a meaningful name)

## Three concrete grammar levels

Each is fully expressive (no info hidden), but each strips more
bookkeeping than the last.

### Level 1 — light cleanup, today's grammar evolved

Drop the `cue` keyword. Replace labelled metadata with positional.
Keep multi-line indented body as canonical.

```
cell-001 [setup]                        fh2-gate 4 69 14
cell-005 [drums qd1]                    mini "x ~ ~ ~ x ~ x ~"
cell-006 [drums qd2]                    every 4 (fast 2) (mini "~ ~ x ~ ~ ~ x ~")
cell-009 [drums qd1]                    every 8 rev (mini "x ~ x x x ~ ~ x")
cell-013 [bass  cip-damp]               mini "0.2 0.3 0.5 0.7 0.8 0.7 0.5 0.3"
cell-027 [ctrl]                         set-control bass-amp 0.85
```

Wins:
- ~20 chars saved per line; readability up significantly
- No grammar surgery beyond parser tweaks
- Round-trip unchanged; cards unaffected
- Parse-error surface tiny

Limits:
- Auto-generated ids still uninformative
- `[bass cip-damp]` is positional — order matters; mvoice always first
- Doesn't pull us toward types

### Level 2 — mvoice in section headers, named cues

Mvoice becomes a section header (`# Drums`); the tvoice IS the name.
Multiple cards under same tvoice = multiple `=` lines, auto-numbered.

```
# Setup
qd1-gate = fh2-gate 4 69 14
qd2-gate = fh2-gate 5 70 15

# Drums
qd1 = mini "x ~ ~ ~ x ~ x ~"
qd1 = every 8 rev (mini "x ~ x x x ~ ~ x")
qd2 = every 4 (fast 2) (mini "~ ~ x ~ ~ ~ x ~")
qd3 = fast 2 (mini "x*8")
qd4 = mini "~ ~ ~ ~ x(3,8)"

# Bass
cip-pitch = mini "c2 e2 g2 ~ b2 ~ g2 e2"
cip-pitch = every 4 rev (slow 2 (mini "c2 g2 e2 c3"))
cip-gate  = mini "x ~ x ~ x x ~ x"
cip-damp  = mini "0.2 0.3 0.5 0.7 0.8 0.7 0.5 0.3"
cip-fm    = mini "0.0 0.0 0.4 0.0 0.0 0.8 0.0 0.2"

# Ctrl
bass-amp   <- 0.85         # `<-` reserved for set-control
filter-mod <- 0.6
```

Wins:
- File reads like a music score: voice headings + named patterns
- Mvoice metadata gone — implicit from section
- Multiple cards under same tvoice handled by repeated `=`
- The "card identity" comes from `tvoice:index` (`cip-pitch:1`, `cip-pitch:2`)
  — only surfaced when explicitly referenced

Limits:
- Section headers are NEW syntax (parser work)
- Multiple same-name declarations is non-traditional (parser+resolver work)
- `<-` for set-control is a small grammar addition
- Ids are implicit; explicit-id form needed for `arrange [...]`-style references
  (e.g. `cip-pitch:2` or `cip-pitch@a`)

Migration: cell-NNN ids carry no useful info; on migration we
auto-generate names like `qd1:a`/`qd1:b` from the wire cells.

### Level 3 — real PureScript with phantom-typed cues

The file IS PureScript. Cues are typed declarations. The compiler
type-checks the binding correspondence.

```purescript
module Calypso.Session where

import Calypso.Cue (Cue, mini, every, fast, rev, slow)
import Calypso.Live (set, control)
import Calypso.Patterns (Note, Cv, Gate)

-- # Drums

qd1A :: Cue "drums" "qd1" Note
qd1A = mini "x ~ ~ ~ x ~ x ~"

qd1B :: Cue "drums" "qd1" Note
qd1B = every 8 rev (mini "x ~ x x x ~ ~ x")

qd2A :: Cue "drums" "qd2" Note
qd2A = every 4 (fast 2) (mini "~ ~ x ~ ~ ~ x ~")

-- # Bass

bassPitchA :: Cue "bass" "cip-pitch" Cv
bassPitchA = mini "c2 e2 g2 ~ b2 ~ g2 e2"

bassGate :: Cue "bass" "cip-gate" Gate
bassGate = mini "x ~ x ~ x x ~ x"

bassFm :: Cue "bass" "cip-fm" Cv
bassFm = mini "0.0 0.0 0.4 0.0 0.0 0.8 0.0 0.2"

-- # Ctrl

bassAmp :: Live "bass-amp" Number
bassAmp = set 0.85
```

`Cue (mvoice :: Symbol) (tvoice :: Symbol) (a :: Type)` is a phantom-typed
wrapper. The compiler enforces:

- `qd1` exists as a binding (compile error if not declared)
- The binding's type matches the cue's third type parameter
  (`Cue "drums" "qd1" Gate` against a `midi-note` binding → type error)
- The body produces values of that type
- Structural-composition functions like `arrange :: forall m tv a. Array (Cue m tv a) -> ...`
  enforce mvoice-homogeneity at type level

Wins:
- File IS PureScript; one compile pipeline (purerl-tidal already exists)
- Type errors are real type errors with great messages
- Type-driven autocomplete in CodeMirror via the existing LSP
- The pattern combinator algebra (`every`, `rev`, `fast`) is already typed
- Music expressions read very close to "just music"

Limits:
- BIG move; weeks not hours
- PureScript identifier rules — no dashes, so `cip-pitch` → `cipPitch`
- Devices/bindings need PureScript-shaped declarations too
- The compile pipeline becomes the gatekeeper for any file change
  (could be slow if not warm-compiled; #11 becomes blocking)
- Migration touches every artifact in the project

## Symbols and the type-signature dream

The user's instinct — putting mvoice/tvoice as type-level Symbols —
is the right one. It pulls *all* of the following correctness through
one constraint:

```purescript
qd1A :: Cue "drums" "qd1" Note
```

- "drums" must be a declared mvoice (or freely declared on first use)
- "qd1" must be a binding registered in the devices/bindings block
- `Note` is the binding's content type
- The body must produce a `Pattern Note`

This is more rigour than the current dynamic system. It catches typos
(`tvoice=qd11` vs `tvoice=qd1`) at compile time rather than at first-fire.

It also makes `arrange` and `tag` mechanisms simpler to express
correctly:

```purescript
verseDrums :: Arrangement "drums"
verseDrums = arrange [qd1A, qd1B, qd2A]

verse :: Arrangement (Union "drums" (Union "bass" "pad"))
verse = stack [verseDrums, verseBass, versePad]
```

The compiler ensures you don't accidentally mix mvoice scopes in
unexpected ways. (`Union` is hand-waved; the actual encoding would
need work.)

## Set-control and tags

Both fit naturally at level 3 via separate type wrappers:

```purescript
bassAmp :: Live "bass-amp" Number   -- live-control bus slot
bassAmp = set 0.85

fill :: Tag "fill" Bool             -- runtime tag
fill = tag false
```

`Live`/`Tag` are distinct from `Cue` so the same typeclass machinery
that prevents you from putting a `set-control` cell where a music cue
goes can be expressed structurally.

## My recommendation: stage it

**Stage 1 (this week):** level 2.

Section headers + named cues + auto-suffixed multiplicity. This buys
~80% of the readability win at a fraction of the cost. Concretely:

- Parser extension: `# Section` header → mvoice context for subsequent
  declarations
- Parser extension: `<ident> = <body>` cue form (no `cue` keyword)
- Tag-cue-id auto-derivation: `qd1` becomes `qd1:a`, second `qd1` becomes
  `qd1:b`, etc.; explicit form `qd1:a = …` always works
- Section-header → mvoice mapping at parse time
- Serializer: emit the new form by default
- Migration: convert level-1 / current form on hydrate

**Stage 2 (later — coupled to warm-compiler work, #11):** level 3.

Once #11 (warm purerl-tidal compile) makes type-check feedback feel
live, move the cue language onto real PureScript with phantom-typed
Cue/Live/Tag. The user's session is a real `.purs` file. Type errors
arrive in <100ms.

The bridge between stages: level 2's identifiers map cleanly to level 3
identifiers (`qd1:a` → `qd1A`, `cip-pitch` → `cipPitch`). Section
headers map to comment-anchored mvoice declarations or proper
PureScript namespacing. The two stages are linearly progressive.

## Open questions

1. **Naming of multi-card-per-tvoice**: `qd1:a`/`qd1:b`/`qd1:c` or
   `qd1@a`/`qd1@b`? The `:` form reads like a music notation
   articulation. The `@` form reads like a position marker. I lean `:`.

2. **Explicit vs implicit ids on save**: when only one card per tvoice
   exists, do we save `qd1 = ...` (implicit `:a`) or `qd1:a = ...`?
   Implicit is cleaner; explicit is referencable. Probably: keep
   implicit unless something references it by name (then the serializer
   adds the suffix).

3. **set-control vs cue distinction**: is `<-` worth the new syntax, or
   should set-controls remain `set-control bass-amp 0.85` (without an
   ident on the lhs)? At level 3 they're a different type anyway. At
   level 2, `<-` carries weight; maybe overkill.

4. **Should sections also constrain bindings?** Right now bindings are
   global. A `# Bindings: Drums` section that scopes which bindings are
   in scope for which mvoice would be more rigorous but adds friction.
   Probably no — bindings stay global.

5. **What about devices?** Devices stay where they are at the top of
   the file; they're rig wiring, not music. No section grouping needed.

6. **The composition pane's expectation**: the user can edit anything
   in the file. If they delete a section header, do the cues underneath
   "fall up" into the previous section's mvoice? Or become orphaned?
   Probably: orphaned cues get mvoice `<orphan>` until the user assigns
   one. The cards view shows them in an explicit "unassigned" column.
