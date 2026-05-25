# Twister surface — design spec v2 (2026-05-25)

Supersedes [`twister-surface-spec-2026-05-24.md`](./twister-surface-spec-2026-05-24.md).
The v1 draft modelled a per-machine surface with multiple bespoke templates
(TwoByEight / FugueFour / TB-303 / …). Two evenings of synthesis with
Andrew collapsed that into a single configurable sequencer plus a fixed
Twister mapping. v2 captures the new design.

Sibling docs: [`scenes-and-shared-state.md`](./scenes-and-shared-state.md),
the per-machine engine docs in `purerl-tidal/docs/`.

---

## 1. Why a unified sequencer

The substrate the rig already has (live-control bus, Twister knob-press
bank-select, voice gen_servers, per-cell parameter arrays) is rich enough
that **one configurable sequencer subsumes everything** the inspiration
machines do — René, Fugue Machine, Metropolix, TB-303 — and extends each
significantly because the grid is *live* (Twister-sweepable) and parameters
that one source machine doesn't have are always available from the others.

Stop modelling separate templates. Build *one* engine, parameterised at
session-load by:

- **V** — number of voices (output destinations).
- **P** — number of playheads per voice.
- Per-voice **grid prefix** declarations (which bus-key prefix each voice
  reads from — share vs own grid is naming, not engine support).
- Per-playhead controls (direction, speed, transposition, on/off, range).

The (V, P) configurations map cleanly to the inspirations:

| (V, P) | What you get                                          |
|--------|-------------------------------------------------------|
| (1, 1) | TB-303-flavoured mono                                 |
| (2, 1) | René twin tracks                                      |
| (1, 4) | Fugue Machine                                         |
| (2, 2) | Metropolix-adjacent                                   |
| (2, 4) | 8 playheads through 2 voices' grids — the new thing  |

The engine doesn't know about the inspirations. It runs the (V, P)
configuration with whatever per-cell + per-playhead + per-voice
parameters are declared.

---

## 2. Vocabulary (locked)

- **Voice** = an output destination. MIDI channel, CV route — what you'd
  put on a different Live track or send to a different synth.
- **Playhead** = a cursor that traverses a 16-cell grid, with its own
  direction / speed / transposition / on-off / range.
- **Grid** = a bundle of 16-element parameter arrays (notes, gate, skip,
  glide, velocity, mod₁…modₙ, probability, ratchet, …) held in named
  bus-key prefixes.
- **Bus prefix** = a string identifier (`shared`, `voiceA`, `bassline`, …)
  that names a grid. Multiple voices may declare the same prefix → shared
  grid. Per-field prefix overrides allow partial sharing.

The (V, P) configuration says nothing about *what* the parameters mean;
that's the realm of the bus-prefix conventions and the Twister substrate
mapping. Voices and playheads are abstract relationships.

---

## 3. Constraints (settled)

- **MFT hardware**: no dedicated hw-bank buttons. Knob-press on channel 2
  is the canonical bank-select gesture. Six side-buttons, one broken.
- **`sweepCells "prefix" min max`** is the universal "this bank sweeps 16
  cells of one parameter" macro (Slab 6.0).
- **Calypso frontend owns Twister state.** BEAM stays oblivious. Every
  knob turn translates to a named `set-control` on the live-control bus.
- **One machine surface at a time.** The Twister talks to the unified
  sequencer (Odonus, post-synthesis). Other machine surfaces — Balistes,
  Vetula, Selene — will get their own substrate work and possibly their
  own Twister bindings, but that's separate.
- **Bus naming convention**: `<prefix>.<param><cellIdx>` — e.g. for grid
  prefix `shared` the bus key for cell 5's note is `shared.note5`. Matches
  `liveIntArrayOr` / `liveBoolArrayOr` readers in `Tidal.LiveControl`.

---

## 4. Architecture (three layers)

```
┌──────────────────────────────────────────────────────────┐
│ Layer 3 — Per-session declaration (the DSL)             │
│   declares: voices, playheads-per-voice, grid prefixes,  │
│             initial grid contents                        │
└──────────────────────────┬───────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│ Layer 2 — Unified sequencer engine                       │
│   walks V × P playheads through declared grids;         │
│   emits MIDI / CV per voice's destination               │
└──────────────────────────┬───────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│ Layer 1 — Substrate (Slab 6.0)                           │
│   knob-press bank-select, set-control wire path,        │
│   sweepCells macro, control-bus ETS                     │
│   *plus* the fixed Twister mapping (§7) and LED         │
│   choreography (§8) which are also substrate-fixed      │
└──────────────────────────────────────────────────────────┘
```

The session layer is small and declarative. The engine is one
implementation. The substrate is what Slab 6.0 built, extended with the
fixed surface mapping.

---

## 5. The unified sequencer engine

### 5.1 Configuration

Each voice declares:

- **destination** — `iac ch1`, `cvRouter gate3 voct4`, etc.
- **grid prefix(es)** — one default, optional per-field overrides.
- **heads** — number of playheads.
- **per-playhead arrays** — direction, speed, transposition, on/off, range.

Each grid is a flat 16-cell record of per-cell arrays:

- `notes` :: `Array Int` (16)
- `gate` :: `Array Boolean` (16)
- `skip` :: `Array Boolean` (16)
- `glide` :: `Array Boolean` (16)
- `velocity` :: `Array Int` (16)
- `mod1`, `mod2`, `mod3`, `mod4` :: `Array Int` (16) — CC-routable mods
- `probability` :: `Array Number` (16)
- `ratchet` :: `Array Int` (16)

Cells live on the bus at `<prefix>.<param><cellIdx>` (e.g. `shared.mod1.7`).
Source-text defaults can be declared in a `grid <prefix>` block (§9);
unset values use type defaults (notes = 60, gate = true, skip = false, etc.).

### 5.2 Playhead state

Per playhead, per voice:

| Field          | Type                  | Default | Notes                              |
|----------------|-----------------------|---------|------------------------------------|
| `direction`    | `fwd \| back \| pend` | `fwd`   | pend = pendulum (fwd to end, back to start) |
| `speed`        | `Number` (multiplier) | `1.0`   | of master clock; 2 = double-time   |
| `transp`       | `Int` (semitones)     | `0`     | added to grid note before emit     |
| `mute`         | `Boolean`             | `false` | per-playhead, performance-toggleable |
| `range`        | `(Int, Int)`          | `(0,15)`| start/end cell inclusive           |

The engine maintains a cursor per playhead, advances it on each tick (or
external clock pulse), and emits a note for the current cell through the
voice's destination — applying transposition, gate/skip/glide/probability/
ratchet semantics already defined for Odonus.

### 5.3 Forgiving array semantics

Per-playhead arrays (`dir`, `speed`, `transp`, etc.) are zipped against
`heads`. The shortest of (`heads`, array length) wins; surplus is dropped,
shortfall is filled with defaults. No length-mismatch errors.

```
heads 4   transp [0, 7]
  → heads 0 and 1 get transp 0 and 7
  → heads 2 and 3 get default transp 0
```

If `heads` is omitted, default is 1 — surplus array entries dropped.

### 5.4 Clock sources

Default: every playhead's speed is a multiplier of the **master clock**
(BPM via Ableton Link). Keeps playheads phase-locked, which is what makes
multi-playhead fugue-style configurations musical.

**Escape valve**: a playhead can override its clock source to any
live-bus signal — e.g. `clockSource gateFromBus "rhythmBank.0"` makes
that playhead clocked by a virtual Euclidean rhythm instead of the
master. Opt-in for the wild case; default is phase-locked.

---

## 6. Sharing via bus-prefix naming

There's no special engine support for "shared grid" vs "per-voice grid."
The distinction is a *naming choice*:

```purescript
voice A  grid shared    -- A reads shared.note*, shared.vel*, ...
voice B  grid shared    -- B reads the same → they share
voice C  grid voiceC    -- C reads voiceC.note*, ... → independent
```

`set-control shared.note5 67` reaches every voice that reads from
`shared.note*`, because that's how the live-control bus works.

### Per-field sharing falls out

A voice can override individual field prefixes:

```purescript
voice A  grid shared
  velPrefix voiceA       -- melody shared, dynamics independent
  modPrefix shared
```

This is *more* than any inspiration machine offers: classical-fugue voices
share a subject but have independent articulation. We get it for free
from the architecture.

### Fork and merge

Two natural performance verbs:

- **Fork** — bulk-copy bus values from prefix X to prefix Y, then rebind
  voice's prefix to Y. The shared grid keeps evolving without the fork;
  the fork freezes at the moment and diverges.
- **Merge** — rebind a voice to read from a different prefix. Old prefix's
  bus state lingers, unread.

Both are session-level operations. Likely Calypso-side verbs (cell-text
or pane buttons), not Twister side-buttons — see the scene model below
for the related "named bus snapshot" pattern.

### Source, bus, scenes — three places state lives

A clean mental model that falls out of the bus-prefix architecture:

- **Source text** = persistent intent. Declared in the voice card / grid
  block: `notes [[60, 62, ...]]` etc. Survives restarts. Authoritative
  for "what this session is supposed to do."
- **Bus state** = transient working memory. The ETS-backed live-control
  bus. Twister sweeps land here. The engine reads from here every step.
  Diverges from source text the moment a knob is touched.
- **Scene-cards** = named snapshots of bus state, the bridge between the
  two. A Calypso card kind sibling to voice-cards: holds a manifest of
  `(prefix, param, [cellValues])` tuples.

#### Save = "snapshot bus into a new named scene-card"

Calypso reads current bus state (for some set of prefixes — by default,
all of them) and writes a new scene-card into the composition pane with
those values inlined. The user is forced to name the card; the
discipline of naming is built into the gesture.

#### Restore = "fire the scene-card"

Firing a scene-card issues bulk `set-control` writes back to the bus.
The currently-running voices read the new values on their next step.
No engine support needed beyond what the bus already does.

Implications:

- **Scenes are discoverable** — they appear as cards in the pane, not as
  hidden Twister memory slots.
- **Scenes are editable** — hand-edit the inlined values to tweak a
  saved state without re-capturing.
- **Scenes are diffable** — two scene-cards side-by-side show what
  differs between two states of the session.
- **Scenes are combinable** — firing two scene-cards back-to-back layers
  their effects on the bus (the second overwrites the first only where
  they overlap).
- **The Twister surface budget is preserved** — scene save / restore
  doesn't need a side-button; it lives where session structure already
  lives.

Out of scope for first slab; tracked separately because it's a Calypso
card-kind extension, not a Twister substrate change.

---

## 7. The fixed Twister surface

**Key design call**: the knob-to-bank mapping is a **constant of the
system**, not declared per session. Knob 0 press always enters the
Notes bank; knob 1 press always enters Velocity; etc. The user's muscle
memory of "which knob does what" persists across every session.

The session declares voices, heads, grids — but not what each knob
controls. The substrate handles the Twister; sessions handle the
musical content.

### 7.1 The 16 rotary banks

| Knob | Bank          | Archetype | Targets                              |
|------|---------------|-----------|--------------------------------------|
| 0    | notes         | Cell      | current voice's grid (notes array)  |
| 1    | velocity      | Cell      | current voice's grid                 |
| 2    | probability   | Cell      | current voice's grid                 |
| 3    | ratchet       | Cell      | current voice's grid                 |
| 4    | mod1          | Cell      | current voice's grid                 |
| 5    | mod2          | Cell      | current voice's grid                 |
| 6    | mod3          | Cell      | current voice's grid                 |
| 7    | mod4          | Cell      | current voice's grid                 |
| 8    | direction     | Playhead  | current voice's playheads            |
| 9    | speed         | Playhead  | current voice's playheads            |
| 10   | transposition | Playhead  | current voice's playheads            |
| 11   | range-start   | Playhead  | current voice's playheads            |
| 12   | range-end     | Playhead  | current voice's playheads            |
| 13   | (open)        |           |                                      |
| 14   | (open)        |           |                                      |
| 15   | (open)        |           |                                      |

Banks 13-15 are reserved for future assignment. Pressing them is a no-op
until they're assigned; no obligation to fill them.

### 7.2 The side-button banks

Three side-button-banks on the right side, all targeting binary per-cell
properties on the current voice's grid:

| Side button     | Bank   | Targets                              |
|-----------------|--------|--------------------------------------|
| R-top           | Gate   | current voice's grid (gate array)   |
| R-middle        | Skip   | current voice's grid                 |
| R-bottom        | Glide  | current voice's grid                 |

In a side-button-bank, knob-turn is ignored; knob-press toggles the
corresponding cell's boolean. Press the same side button again → return
to the rotary bank you were in.

### 7.3 The side-button verbs (left side)

| Side button     | Verb                    | Notes                              |
|-----------------|-------------------------|------------------------------------|
| L-top           | (broken)                | Unassigned.                        |
| L-middle        | (open)                  | Reserved for future global verb.  |
| L-bottom        | **Voice-select**        | Cycles current voice (A → B → A). LED = current voice's hue. No-op when V=1. |

PANIC and SCENE both live on the Calypso pane side, not the Twister.
Scene save/restore in particular is better handled as a card-kind in
Calypso (see §11 — the bus/source/scene relationship); the Twister
budget stays for performance gestures.

### 7.4 Current voice + current playhead

Two implicit pieces of state the surface tracks:

- **Current voice** — incremented by L-bottom button. The Cell-bank knobs
  (0–7) target this voice's grid. The Playhead-bank knobs (8–12) target
  this voice's playheads. The side-button-banks (Gate, Skip, Glide)
  target this voice's grid.
- **Current bank** — incremented by knob-press. Determines which
  parameter the 16 knob-turns currently edit.

No "current playhead" state at the surface level — region-banks lay out
all the current voice's playheads simultaneously, one slot per playhead.

---

## 8. LED choreography

Three independent visual channels, each answering one question at a
glance:

| Channel                  | Encodes              | Where shown                          |
|--------------------------|----------------------|--------------------------------------|
| **Hue** (per knob)       | Which bank           | Each ring + bank-home indicator      |
| **Voice indicator**      | Which voice          | L-bottom side-button LED only        |
| **Fill** (ring segments) | Cell value           | Each knob's ring segment count       |

The user's mental decoding is consistent everywhere: *the ring color
tells me which bank; the L-bottom LED tells me which voice; the ring
fills tell me each cell's value*.

The MFT firmware exposes ~20 distinct LED colors — far more than there
are voices in a typical session (1-4). Using color for voice would burn
the channel's information capacity. Instead, **color encodes bank**
(13-16 distinct identities, learnable across sessions) and voice info
moves to the dedicated side-button LED.

### 8.1 Bank color

Each rotary bank has a fixed, distinct hue across all sessions. The user
learns "the green knobs are Notes, the yellow knobs are Velocity,
the magenta knobs are Probability" once, and that muscle memory holds
forever. Candidate palette (from the MFT swatches):

| Knob | Bank          | Color           |
|------|---------------|-----------------|
| 0    | Notes         | Bright green    |
| 1    | Velocity      | Yellow          |
| 2    | Probability   | Magenta         |
| 3    | Ratchet       | Orange          |
| 4    | Mod1          | Cyan            |
| 5    | Mod2          | Light blue      |
| 6    | Mod3          | Blue            |
| 7    | Mod4          | Indigo          |
| 8    | Direction     | Purple          |
| 9    | Speed         | Hot pink        |
| 10   | Transposition | Red             |
| 11   | Range-start   | Lime            |
| 12   | Range-end     | Chartreuse      |
| 13-15| (open)        | (dark)          |

The mod cluster (Mod1-4 → cyan / light blue / blue / indigo) sits in one
hue family, so the eye recognises "mod-region" at a glance without
having to name the specific mod knob.

Side-button-banks (Gate / Skip / Glide) get their own palette slots; the
side-button LED lights in that hue when active, and the rings inherit
the same hue while in that mode.

### 8.2 Voice indicator

The L-bottom side-button LED shows the current voice's color. Voice
colors come from a *separate* palette slot, chosen to be visually
distinct from any bank color (so the L-bottom LED can't be confused
with a ring reflection):

- Voice A — pure red
- Voice B — pure blue
- Voice C — pure orange
- Voice D — white
- (extensible)

When V=1, voice-select is a no-op and the L-bottom LED holds the single
voice's color permanently.

### 8.3 Bank-home indicator

You enter bank N by pressing knob N. The indicator LED above knob N
stays steady-bright (in **the bank's color**) for as long as you're in
that bank. The other 15 indicators are dim or off.

*Your own gesture is the cue* — no decoding, no chart, just "the knob I
pressed is glowing in the bank's color."

When a side-button-bank is active, no rotary-bank indicator is bright
(the active bank isn't on a knob). The side-button's own LED is lit
instead. The visual signature is then triple-redundant:

- All ring fills are at 0 or 127 (no mid-fills, because binary)
- No knob's indicator is steady-bright
- One side-button LED is lit (R-top / R-middle / R-bottom)

Gate vs Skip vs Glide are distinguished by *which* side-button LED is
lit (their position is the signal); they may also carry distinct hues
in the side-button LED.

### 8.3 Ring fill (cell value)

Per knob, the ring's segment count reflects its cell's current value:

- **Cell-bank** (continuous): segments = ⌈value / max × 11⌉.
- **Cell-bank** (cyclic, e.g. ratchet 1-8): segments = ⌈value / 8 × 11⌉.
- **Side-button-bank** (binary): all 11 segments lit or all dark.
- **Playhead-bank** (e.g. direction across N playheads): each used slot's
  ring shows that playhead's value; unused slots dark.

### 8.4 Playhead transit (indicator LED)

In addition to the bank-home indicator, each playhead's *currently-playing
cell* briefly flashes that cell's indicator LED. With multiple playheads
in flight, multiple indicators flash. Each flash is brief (~50ms) and
dim relative to the bank-home indicator, so they coexist without
ambiguity.

**Edge case**: if a playhead's current cell happens to be the bank-home
knob, the brief flash brightens further on top of the steady bank-home
indicator, then drops back. Cause-effect visible regardless.

### 8.5 Update cadence

- **Knob movement**: echo to its own ring immediately (local optimistic
  paint), reconciled with bus state on next sync tick.
- **Bus state changes**: 30 Hz debounced flush from Calypso state to
  Twister Web MIDI Out.
- **Playhead transits**: pushed from BEAM via dedicated `playhead-tick`
  WS event, no polling.

---

## 9. The declarative surface (DSL)

Following the polysignal grammar's lead: block headers, `<>` continuation
markers, tabular per-row arrays, no-noise visual layout.

### 9.1 Smallest interesting session — TB-303-like mono

```
sequencer bassline                                <>
  voice A  iac ch3                                <>
    heads 1
```

That's the whole declaration. One voice, one playhead, default
direction/speed/transposition/range. The grid lives at default prefix
`voiceA.*`; cells start at type defaults (notes = 60, gate = true, etc.).
The Twister wires up automatically.

### 9.2 Fugue Machine — one voice, four playheads, shared grid with explicit notes

```
sequencer fugueDemo                                <>
  grid shared                                      <>
    notes [[60, 62, 64, 65],                       <>
           [67, 69, 71, 72],                       <>
           [74, 76, 77, 79],                       <>
           [81, 83, 84, 86]]                       <>
  voice A  iac ch1  grid shared                    <>
    heads 4                                        <>
    dir    [fwd,  fwd,  back, pend]                <>
    speed  [1,    2,    1,    1   ]                <>
    transp [0,    7,    12,   -5  ]
```

The 4×4 source layout for `notes` matches the Twister's physical 4×4 layout
— top-left cell of the source = top-left knob on the device. Reading order
= physical order = bus key order (`shared.note0` is top-left, `shared.note15`
is bottom-right).

Internally the parser flattens row-major to a 16-element array; the
4×4 shape is source-text + pretty-print convention.

### 9.3 Twin fugue — two voices, two playheads each, sharing one grid

```
sequencer twinFugue                                <>
  grid shared                                      <>
    notes [[60, 62, 64, 65],                       <>
           [67, 69, 71, 72],                       <>
           [74, 76, 77, 79],                       <>
           [81, 83, 84, 86]]                       <>
  voice A  iac ch1  grid shared                    <>
    heads 2  transp [0, 7]                         <>
  voice B  iac ch2  grid shared                    <>
    heads 2  transp [12, -5]
```

Both voices read the same `shared.*` bus keys. Twister knob 0 (Notes)
sweep affects both voices simultaneously — the unison-with-counterpoint
flavour. Twister side-button R-top (Gate) toggles cells for the current
voice — so you can mute one voice's gates while leaving the other intact.

### 9.4 Partial sharing — shared melody, independent dynamics

```
sequencer expressiveTwin                           <>
  grid shared                                      <>
    notes [[60, 62, 64, 65],                       <>
           [67, 69, 71, 72],                       <>
           [74, 76, 77, 79],                       <>
           [81, 83, 84, 86]]                       <>
  voice A  iac ch1                                 <>
    notePrefix shared                              <>
    velPrefix  voiceA                              <>
    modPrefix  shared                              <>
    heads 2  transp [0, 7]                         <>
  voice B  iac ch2                                 <>
    notePrefix shared                              <>
    velPrefix  voiceB                              <>
    modPrefix  shared                              <>
    heads 2  transp [12, -5]
```

A and B share melody and mods (any Twister sweep on Notes/Mod1-4
cascades to both) but maintain independent velocity (each voice's
Velocity bank writes to its own prefix).

### 9.5 Grammar summary

- **Block header**: `<kind> <name> <inline params> <>`
- **Continuation lines**: indented one step, end with `<>` (or no marker
  if last line of block)
- **Inline params on header**: space-separated `key value` pairs
- **Multi-value params**: `key [v1, v2, ...]` arrays (single-line or
  visually-formatted across multiple lines as in §9.2)
- **Per-cell grid arrays**: `[[r0c0,r0c1,r0c2,r0c3], [r1c0,...], ...]` —
  4×4 nested array, parser flattens row-major

Polysignal-grammar rules carried over:

- Stale/typo'd lines fall outside the block rather than silently
  fragmenting it (the `<>` is load-bearing).
- Duplicate parameter assignments raise an error (the chain is "and
  also", not semigroup append).

### 9.6 What's deliberately not in the DSL

- **No Twister mapping per session** — fixed in §7.
- **No LED color overrides** — fixed in §8 (voice tint, bank-home, ring
  fill).
- **No mode toggles or modifier keys** — the surface is single-mode.

---

## 10. Bank archetypes (substrate concept)

The Twister surface has three kinds of bank. The key distinction:
**does the bank always have 16 active knobs, or does it adapt to the
session's (V, P) configuration?**

| Archetype       | Knob-turn          | Knob-press     | LED rings                                | Used for                                  |
|-----------------|--------------------|----------------|------------------------------------------|-------------------------------------------|
| **Cell-bank**   | Set cell value     | (bank-select)  | All 16 in bank's color; per-cell fill   | 16 cells of one parameter                 |
| **Playhead-bank**| Set playhead value| (bank-select)  | First P in bank's color; rest dark      | Per-playhead value (direction, speed, …)  |
| **Binary-bank** (side-button-only) | (ignored) | Toggle cell | All 16 in bank's color; all-or-nothing fill | 16 binary cells (gate, skip, glide)   |

### Cell-bank

Knob N always maps to cell N's value. Same shape every session. Example:
Notes bank — knob 0 controls `<currentVoice.grid>.note0`, knob 15
controls `<currentVoice.grid>.note15`. This is what `sweepCells`
produces and what Slab 6.0 already supports.

### Playhead-bank

Knob N maps to playhead N's value, for N < P. Knobs at indices ≥ P stay
dark. So if the current voice has 4 playheads, knobs 0–3 are lit (in the
bank's color, fill = each playhead's value), knobs 4–15 are dark.
Switching to a voice with 2 playheads dims knobs 2–15.

Banks 8–12 (Direction, Speed, Transposition, Range-start, Range-end)
all share this shape — they're all per-playhead values, just for
different parameters.

### Binary-bank

Side-button-only entry (R-top / R-middle / R-bottom). All 16 knobs each
toggle one cell's boolean. Knob-turn is ignored. Used for Gate, Skip,
Glide. The all-extremes ring pattern (each ring 0 or 127) plus the lit
side-button LED makes the mode visually unambiguous.

### Future archetypes (deferred)

- **Selector-bank** — one or two cells highlighted, knob-press
  designates. Useful for sequence start/end markers as a single bank
  rather than two separate Playhead-banks.
- **Voice-bank** — like Playhead-bank but slots per voice instead of
  per playhead. Knobs 0..V−1 lit, rest dark. Useful for per-voice
  parameters like ADSR if those land on the Twister later.

---

## 11. Param uplift required on Odonus

To realise the fixed Twister surface, Odonus needs to lift several
registration-time-only fields to `Array (Pattern X)`:

| Field   | Current             | Required                   | Used by Twister bank   |
|---------|---------------------|----------------------------|------------------------|
| `gate`  | `Array Boolean`     | `Array (Pattern Boolean)`  | side-button R-top      |
| `glide` | `Array Boolean`     | `Array (Pattern Boolean)`  | side-button R-bottom   |
| `vel`   | scalar `Int`        | `Array (Pattern Int)`      | knob 1                 |
| `mod1`  | (does not exist)    | `Array (Pattern Int)`      | knob 4                 |
| `mod2`  | (does not exist)    | `Array (Pattern Int)`      | knob 5                 |
| `mod3`  | (does not exist)    | `Array (Pattern Int)`      | knob 6                 |
| `mod4`  | (does not exist)    | `Array (Pattern Int)`      | knob 7                 |

Already lifted (Threads 1-3): `skip`, `notes`, `ratchet`, `probability`.

Multi-playhead support (Thread 4 / §5.2 here):
- Add per-playhead state to the voice gen_server.
- Lift `dir`, `speed`, `transp`, `mute`, `range` to per-playhead arrays.
- Currently single-playhead — Thread 4 work hasn't started yet.

The mod CCs need a per-rig mapping (Studio.purs declaration) — task #151's
"Per-rig CC/CV translation layer."

---

## 12. Slab plan forward

Pre-requisites (foundation):

- **Slab 6.1** — Odonus param uplift (`gate`, `glide`, `vel` to `Array
  (Pattern X)`). Foundation for everything else.
- **Slab 6.2** — Multi-playhead engine (Thread 4 work). Voice gen_server
  walks K playheads against one grid, applies per-playhead direction/
  speed/transposition.

Twister substrate slabs (in order):

- **Slab 6.3** — Fixed Twister mapping. Replaces the PoC Bindings.purs
  with the §7 table. Banks 0-7 wire to `sweepCells` on current voice's
  grid; banks 8-12 wire to Playhead-bank readers; side-button-banks wire to
  Gate/Skip/Glide.
- **Slab 6.4** — Voice-select side-button. State machine for "current
  voice"; cycles A/B/…; updates LED tint across all rings.
- **Slab 6.5** — Bank-home indicator. Track current bank in frontend
  state; paint bank-home indicator LED on press.
- **Slab 6.6** — Side-button-banks (Gate / Skip / Glide). Mode tracker;
  press-to-toggle dispatch; LED state for "in side-button-bank".
- **Slab 6.7** — Playhead-transit indicators. BEAM pushes `playhead-tick`
  events; frontend brief-flashes the corresponding indicator LED.

Calypso-side slabs:

- **Slab 6.8** — Scene-card kind. Calypso card type that holds a bus
  snapshot manifest; pane button "Snapshot current bus → new named
  scene-card"; fire-card writes manifest values back to the bus via
  bulk `set-control`. (Replaces the older "scene on a Twister
  side-button" plan.)
- **Slab 6.9** — DSL parser. Polysignal-grammar parsing extended to the
  `sequencer` / `grid` / `voice` block kinds.
- **Slab 6.10** — Session library. Update existing sessions to use the
  new DSL (or wrap them).

Out-of-scope for this slab series (future):

- Mod3/Mod4 banks until Odonus's mod uplift lands.
- Fork / merge verbs (§6).
- TB-303-specific surface (accent / slide / octave). These extensions to
  Odonus come later.
- Banks 13-15 — left open.
- Vetula / Balistes / Selene Twister surfaces — separate spec work each.

---

## 13. What lives where

| Concern                          | Location                                                             |
|----------------------------------|----------------------------------------------------------------------|
| Substrate (Slab 6.0)             | `calypso/frontend/src/Calypso/Frontend/Controller.purs`              |
| Fixed bank mapping (§7)          | `calypso/frontend/src/Calypso/Frontend/Controller/Bindings.purs`     |
| LED output (Slab 6.5-6.7)        | `calypso/frontend/src/Calypso/Frontend/Controller/Leds.purs` *(new)*  |
| DSL parser                       | `calypso/shared/src/Calypso/Composition/Parser.purs` (extend)        |
| Sequencer engine (Layer 2)       | `purerl-tidal/src/Tidal/Odonus.purs` + `odonus_voice.erl` (extend)   |
| Per-playhead state               | `purerl-tidal/src/odonus_voice.erl` (extend gen_server state)        |
| Scene state                      | `tidal_control_bus` ETS + Handler WS verbs (`scene-save`, `scene-restore`) |
| This spec                        | this file                                                            |

---

## 14. What we're explicitly not doing

- **No custom Twister mapping per session.** The surface is constant.
- **No mode toggle / modifier keys** beyond the side-button-banks.
- **No DAW-style copy-paste** between cells. Maybe later.
- **No MIDI Learn.** Bindings are declarative in the substrate, not
  learned from gestures.
- **No "remember last bank per voice" cross-voice memory.** Current bank
  is global to the surface; switching voices doesn't reset it. (Could
  add later.)
- **No TB-303-specific banks at first.** Accent / slide / octave would
  extend the fixed mapping; deferred until we know we want them
  universal.

---

## 15. Open questions / future considerations

**Q1.** Banks 13-15 — leave open for now. Candidates for later: scale-
select, swing, clock-source override.

**Q2.** Range-start / range-end (banks 11, 12) — should range be per
playhead (each playhead has its own start/end of the grid) or per voice
(all playheads of a voice share a range)? Lean: **per playhead** —
matches the disciplined-default of speed-as-multiplier from §5.4 (each
playhead has its own everything). Per-voice variant possible later via
sharing pattern.

**Q3.** When you switch voices, does current bank persist? Lean: **yes,
persist**. You were just editing Notes for voice A; you switch to voice
B; you stay in Notes (now editing B's notes). Less reset, faster
A/B comparison.

**Q4.** Voice color — fixed palette (A=red, B=blue, C=orange, D=white)
or session-declarable (`color red` in voice header)? Lean: **fixed
default with session override**. A 4-voice palette is small; the user
learns it once. Session-level override is opt-in for sessions that
want a specific mnemonic (e.g. "bass voice in deep red").

**Q5.** Cyclic banks (direction, range states) — how does knob-turn
behave for a 3-state cyclic value? Lean: **0..127 maps to N states via
floor**, so the knob sweeps smoothly between states. Ring fill quantises
to the state boundary so visual feedback is integer-aligned.

**Q6.** Playhead-transit edge case where the playhead is at the bank-home
knob — already addressed in §8.4 (transit brightens on top of bank-home).

---

## 16. Cross-referenced design memories

- `project_unified_sequencer_synthesis` — the architectural call.
- `project_twister_16bank_sequencer_surface` — original vision.
- `project_twister_scene_restore` — scene save/restore design.
- `reference_mft_twister_hardware_reality` — knob-press substrate; MFT has
  no hw-bank buttons.
- `project_odonus_fugue_machine_merge` — Thread 4 multi-playhead.
- `reference_polysignal_continuation_marker` — `<>` line continuation
  grammar.
- `project_twister_surface_design_model` — v1's pre-synthesis design.
