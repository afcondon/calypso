# Twister surface — design spec (draft, 2026-05-24)

The Midifighter Twister is the principal hardware controller for the
purerl-tidal rig. This spec describes the surface we want to build on top
of the Slab 6.0 substrate (knob-press bank-select + `sweepCells` DSL). It's
a draft for conversation — surfacing contradictions and proposing
innovations rather than locking decisions.

Sibling docs: [`scenes-and-shared-state.md`](./scenes-and-shared-state.md),
the per-machine engine docs in `purerl-tidal/docs/`.

---

## 1. Design problem

We have **16 RGB push-encoders + 6 side-buttons (one broken)** mediating a
session whose musical material is parametrically rich:

- **Odonus** — 16-cell René-style sequencer. Per-cell: note, gate, skip,
  glide, probability, velocity, mod, ratchet. Two simultaneous voices is
  the natural minimum; four (à la Fugue Machine) is the stretch goal.
- **Balistes** — 16-step polyrhythmic drum machine, post-merge of Grids +
  Repetitor. Per-track: density, fill, swing, phase-offset.
- **Vetula** — chord player. Per-position: chord choice, voicing, voice-
  leading hints, register.
- **Selene** — polysignal generator. Per-slot: shape, rate, depth, phase.

The surface has to:

- Stay **per-machine** at any given moment (Twister talks to *one* machine
  per session).
- Surface up to 16 banks of parameters for that machine.
- Keep the user **centered** — never "what mode am I in / which bank am I
  on / what does this knob currently do?". LED programmability is our
  primary tool here.
- Support multiple **topology templates** per machine (a single Odonus
  session might be 2×8, another 4×4 Fugue, another TB-303 single-voice).
- Tolerate the side-button budget: 5 working buttons, weak tactile feel,
  reserved for low-frequency global verbs.

---

## 2. Constraints (settled)

- **MFT hardware** has no dedicated hw-bank buttons. Knob-press on channel
  2 is the canonical bank-select gesture. (Memory:
  `reference_mft_twister_hardware_reality`.)
- **`sweepCells "prefix" min max`** is the universal "this bank sweeps
  16 cells of one parameter" macro.
- **Calypso frontend owns Twister state.** BEAM stays oblivious — every
  knob turn translates to a named `set-control` on the live-control bus.
- **One machine per session.** The frontend's bank table is declared at
  session-load time; doesn't try to interleave machines.
- **Bus naming convention**: `<machine>.<param><cellIdx>` (e.g.
  `odonus.note0`..`odonus.note15`, matching `liveIntArrayOr` /
  `liveBoolArrayOr` readers).

---

## 3. The first contradiction to resolve: bank-select vs binary-toggle

Andrew's framing — *"maybe it's a bit waste to have 16 knobs for gates and
skips"* — surfaces a clean design tension:

- **Knob-press = bank-select** (current substrate). Fine for parameter
  banks where each cell needs a value.
- **Knob-press = per-cell binary toggle** (for gate / skip / accent /
  slide banks). Saves the rotation entirely; each knob is a button.

Both gestures use the same physical action. We can't have both as the
default.

### Proposed resolution: **Edit-mode / Bank-select-mode toggle**

Two modes, distinguished by LED state. A dedicated side button (one of the
working five — call it the **MENU button**) flips between them.

| Mode              | Knob-turn                    | Knob-press                          | LED state                          |
|-------------------|------------------------------|-------------------------------------|------------------------------------|
| **Edit (default)**| Set current bank's cell value| Action depends on bank type (below) | Rings show cell values             |
| **Bank-select**   | (ignored / fine-tune later?) | Jump to that bank's edit mode       | Rings show bank-identity colors    |

Bank types within edit mode:

| Bank type        | Knob-turn               | Knob-press                              |
|------------------|-------------------------|-----------------------------------------|
| **Continuous**   | Set cell value          | Reset cell to default (or jump-to-mid?) |
| **Binary**       | (ignored)               | Toggle cell                             |
| **Cyclic (N)**   | (ignored or step?)      | Step to next of N states                |

This is essentially Elektron's "FUNC + button" idiom adapted: the friction
goes on the *bank-switching gesture*, which is lower-frequency than the
*editing gesture*. The trade is one tap (MENU) before each bank switch.

Benefit: muscle memory becomes unambiguous. Every knob action *in the
current mode* does one thing, and the LEDs make the mode-distinction
obvious.

### Alternative — knob-press double-tap as bank-select

Single press = action (per bank type), double-press (within 300ms) =
bank-select. No mode toggle, no side button.

Trade-off: gesture timing replaces an explicit mode. Risk: misfires (you
intended a double-tap, got a single-tap). Probably worse than the MENU
button for live use.

### Alternative — bank-select knob is always present

Reserve one knob (e.g. top-left) permanently as "bank-select-knob": its
turn = scroll through banks, press = nothing or a reset verb. Costs one
cell across every bank, but no modes.

Worth discussing.

---

## 4. Core architecture (proposed)

Three layers, separable for clarity:

```
┌─────────────────────────────────────────────────────┐
│ Session layer                                       │
│   declares: "this Odonus session uses TwoByEight   │
│             template, voice A = odonus1, voice B = │
│             odonus2"                               │
└─────────────────────┬───────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────┐
│ Template layer                                      │
│   declares: TwoByEight binds knob 0..7 to voice A's │
│             8 banks, knob 8..15 to voice B's        │
│             8 banks; bank order is fixed            │
└─────────────────────┬───────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────┐
│ Substrate layer (Slab 6.0)                          │
│   `Array (Maybe Controller)`, knob-press dispatch,  │
│   sweepCells macro, set-control wire path           │
└─────────────────────────────────────────────────────┘
```

The session layer is small and declarative — `template: TwoByEight, voices:
["odonus1", "odonus2"]`. The template layer expands that to the
substrate's `Array (Maybe Controller)`. The substrate is what landed in
Slab 6.0.

**Why three layers**: the template is the *reusable* part. A 2×8 template
should work for any Odonus session, parameterised by the voice names.
Sessions declare *which* template they use and *how it's wired*; they
don't redeclare 16 banks every time.

---

## 5. Topology templates

### 5.1 Odonus TwoByEight (2 voices × 8 banks)

Knob layout (the 4×4 physical grid):

```
  ┌────┬────┬────┬────┐
  │ N  │ G  │ S  │ Gl │   row 0 — voice A
  │ V  │ M  │ P  │ R  │   row 1 — voice A
  ├────┼────┼────┼────┤
  │ N  │ G  │ S  │ Gl │   row 2 — voice B
  │ V  │ M  │ P  │ R  │   row 3 — voice B
  └────┴────┴────┴────┘
   knob press to enter bank →
```

| Code | Bank             | Type       | Bus key                 |
|------|------------------|------------|-------------------------|
| N    | Note             | continuous | `odonus<v>.note<0..15>` |
| G    | Gate             | binary     | `odonus<v>.gate<0..15>` |
| S    | Skip             | binary     | `odonus<v>.skip<0..15>` |
| Gl   | Glide            | binary     | `odonus<v>.glide<0..15>`|
| V    | Velocity         | continuous | `odonus<v>.vel<0..15>`  |
| M    | Mod (CC1)        | continuous | `odonus<v>.mod<0..15>`  |
| P    | Probability      | continuous | `odonus<v>.prob<0..15>` |
| R    | Ratchet          | cyclic (8) | `odonus<v>.rat<0..15>`  |

Where `<v>` is `1` or `2` (voice A or B).

### 5.2 Odonus TwoByEightWithGlobals (2 × 7 + 2 globals)

Steal one bank from each voice (Mod is the easiest victim) and replace
with two globals:

| Code | Bank           | Scope        | Type       |
|------|----------------|--------------|------------|
| Ps   | Pattern select | both voices  | cyclic     |
| Tr   | Transpose      | both voices  | continuous |

The two "lost" mod banks aren't really lost — Mod-CC is still bindable as
a deep parameter (e.g. Vetula's chord substitution slot in a future
template), just not on the Twister surface here.

### 5.3 Odonus FugueFour (4 voices × 4 banks)

Knob layout:

```
  ┌────┬────┬────┬────┐
  │ N  │ G  │ S  │ R  │   voice A (4 banks each)
  ├────┼────┼────┼────┤
  │ N  │ G  │ S  │ R  │   voice B
  ├────┼────┼────┼────┤
  │ N  │ G  │ S  │ R  │   voice C
  ├────┼────┼────┼────┤
  │ N  │ G  │ S  │ R  │   voice D
  └────┴────┴────┴────┘
```

The 4 banks per voice are the **essential** set (note, gate, skip,
ratchet). Probability / velocity / mod / glide aren't on the Twister in
this template — they're left at session defaults or live-coded.

**Convergence with Thread 4**: this template *is* the Fugue Machine
sequencer. The 4 voices share a `playheads` array against a common
16-cell grid, per the project_odonus_fugue_machine_merge memory.

### 5.4 TB-303 mode

Single voice. 16-step bassline-style. Banks:

| Code | Bank           | Type            | Notes                        |
|------|----------------|-----------------|------------------------------|
| N    | Note           | continuous      | semitone-quantised pitch     |
| A    | Accent         | binary          |                              |
| Sl   | Slide          | binary          | glide to next note           |
| O    | Octave         | cyclic (3)      | down / unison / up           |
| R    | Rest           | binary          | distinct from "skip"; this  |
|      |                |                 | step takes time but silent   |
| G    | Gate length    | continuous      | short / medium / long        |

Six banks. The remaining 10 knobs are free — could carry a second voice's
banks (basslines often come in pairs — 303A + 303B over the same Live
project), or globals (filter cutoff, resonance, env-mod, accent-amount).

**Note on Odonus uplift required**: TB-303 mode wants `accent`, `slide`,
`octave-shift`, `rest`, `gate-length` as per-cell arrays. None exist on
Odonus today. Either add them (Odonus grows) or build a separate `TB303`
machine that shares Odonus's traversal engine.

### 5.5 Balistes (placeholder — needs audit)

Drum machine surface. Tentative banks per track (Bd, Sd, Hh):
- density, fill amount, swing, phase, accent pattern

Probably 5×3 = 15 banks for 3 tracks, leaving one for globals. Or
2 voices × 8 banks where each "voice" is two tracks. Pending Balistes
audit after Repetitor merge lands.

### 5.6 Vetula and Selene (placeholders)

Both pending the same audit. Vetula's "chord" is a higher-arity
parameter than Odonus's "note" — voicings, register, leading hints. Will
benefit from cyclic and continuous banks together.

---

## 6. LED choreography — the "stay centered" tool

We have abundant LED real estate. Used right, every glance at the Twister
answers three questions immediately:

1. **What mode am I in?** (edit vs bank-select)
2. **What bank am I on?** (which of up to 16)
3. **What's each cell currently set to?** (per-knob value)

### 6.1 Ring + indicator LED budget

Per knob:
- **RGB ring**: 11 segments, programmable color + fill. Used for cell
  *value* (continuous) or cell *state* (binary cells lit/unlit).
- **Indicator LED** (above the knob): single, programmable color. Used
  for cell *identity / metadata* (e.g. "this is the currently-playing
  cell").

Side buttons each have their own LED — used for mode and global state.

### 6.2 Color palette (proposed)

Identity hues for the 16 banks of a TwoByEight template (just an
illustration; real values are 0..127 on Twister's hue ring):

```
Voice A         Voice B
N    red        N    salmon
G    orange     G    coral
S    yellow     S    amber
Gl   lime       Gl   chartreuse
V    green      V    emerald
M    teal       M    cyan
P    blue       P    sky
R    indigo     R    violet
```

Two halves (warm / cool by voice), one continuum within each voice (the
"parameter family"). Pattern recognition does the work — you learn "red-
ish = note, blue-ish = probability" without consulting a chart.

### 6.3 Per-mode LED state

**Edit mode (continuous bank)** — e.g. Note bank:
- Each ring color = the bank's hue (red), saturated.
- Each ring fill = cell value scaled to ring segments.
- Indicator LEDs: dim by default, **bright on the currently-playing
  cell** (engine reports its position via a separate WS event).

**Edit mode (binary bank)** — e.g. Gate bank:
- Ring color = bank's hue (orange).
- Ring fully lit if cell `true`, dark if `false`.
- Indicator LED: same playhead indicator as above.

**Edit mode (cyclic bank)** — e.g. Ratchet bank, 8 states:
- Ring color = bank's hue.
- Ring fill = ⌈cellValue / 8 × 11⌉ segments. Quantised.
- Indicator LED: playhead.

**Bank-select mode**:
- All 16 rings show their *bank's identity color* at low saturation.
- The currently-active bank's knob flashes (1 Hz pulse) at full
  saturation.
- All cell information temporarily hidden — you're picking a bank, not
  editing.
- Press a knob → mode auto-flips back to Edit on that bank.

### 6.4 Side-button LEDs

5 working buttons. Proposed assignment:

| Button       | LED meaning                                | Action          |
|--------------|--------------------------------------------|-----------------|
| **MENU**     | Lit = bank-select mode, dark = edit mode  | Toggle mode     |
| **SCENE**    | Color = last-restored scene's color       | Tap = restore baseline; long-press = capture (scene-save) |
| **PANIC**    | Off normally, red flash on panic          | All-notes-off + clear bus |
| **(spare 1)**| Reserved for global verb tbd               |                 |
| **(spare 2)**| Reserved for global verb tbd               |                 |

The broken sixth button is unassigned.

### 6.5 Update cadence

The LED state has to feel responsive but not waste bus bandwidth. Pro­posal:

- **Knob movement** → echo to its own ring immediately (local optimistic
  paint, then reconcile with bus state on next sync tick).
- **Cell state from bus** → 30 Hz debounced flush from frontend state.
- **Playhead indicator** → push from BEAM via a dedicated WS event
  (`playhead-tick`), no polling.

---

## 7. Param uplift required on Odonus

To support TwoByEight, the following Odonus fields need to lift from
registration-time-only to `Array (Pattern X)`:

| Field   | Current shape       | New shape                  |
|---------|---------------------|----------------------------|
| `gate`  | `Array Boolean`     | `Array (Pattern Boolean)`  |
| `glide` | `Array Boolean`     | `Array (Pattern Boolean)`  |
| `vel`   | scalar `Int`        | `Array (Pattern Int)`      |
| `mod`   | (does not exist)    | `Array (Pattern Int)` new  |

`probability` and `ratchet` already lifted (Threads 2/3).

For TB-303 mode, additionally: `accent`, `slide`, `octave`, `rest`,
`gateLength`. Bigger uplift; might justify a separate `TB303` machine
sharing Odonus's traversal engine. Decision deferred.

---

## 8. Open contradictions / questions to resolve

**Q1.** Continuous-knob press: reset, jump-to-mid, or no-op?
Three useful options, none dominant. *Recommendation*: jump-to-mid (most
useful in performance), with a separate "double-press = reset to
default" hidden gesture for less-frequent use.

**Q2.** Within bank-select mode, does knob-turn do anything? *Recommend*:
no-op (keeps it pure). Could later become "scroll banks" for a future
>16-bank mode if we ever want that.

**Q3.** TB-303 mode — extend Odonus or new machine? Extending grows
Odonus's surface (8→13 per-cell arrays); new machine duplicates traversal
logic. *Lean*: extend Odonus, with optional bank visibility (TB-303 mode
hides probability/mod/etc. at the surface, Odonus keeps them all
internally). One implementation, multiple template-level UIs.

**Q4.** Currently-playing-cell indicator: does the engine push every
step? At high BPM × 16 cells × 30 ticks/cell that's a lot of WS frames.
*Suggested*: BEAM pushes only on cell-edge crossings (per step), not
sub-step ticks. ~8-16 Hz per voice is fine.

**Q5.** Bank-color identity across sessions: are colors fixed per
*parameter family* (Note is always red) or per *bank slot in this
template* (slot 0 is always red, regardless of which template)?
*Recommend*: by parameter family. Builds cross-session muscle memory.

**Q6.** Does turning a knob in a binary bank do anything? Continuous
quasi-toggle, or hard no-op? *Recommend*: hard no-op for clarity. (Avoids
the `outMin=0/outMax=1` rough-binary mess from Slab 6.0c.)

---

## 9. Innovations to consider (not yet committed)

### 9.1 Cell-focus inspector

Long-press a knob → enter "inspector mode" for that cell across *all*
banks. Now all 16 rings show *that cell's* values across the 16
parameter banks. Useful for "this cell is misbehaving, what are all its
params?". Exit by another long-press, or auto-exit on next knob-turn.

Cost: a new gesture (long-press has to be reserved). Reward: a powerful
diagnosis surface that wouldn't otherwise exist on hardware.

### 9.2 Two-axis ring encoding for Note bank

Note rings encode pitch in two dimensions:
- **Hue rotation** = pitch class (12 chroma colors around the ring).
- **Fill brightness** = octave height (low octave = dim, high = bright).

A single glance at the Note bank tells you the melody contour and the
chord coloring. Costs: a custom paint routine, color-blindness
accessibility concern.

### 9.3 Scene mode as a row of indicators

The 16 *indicator LEDs* above the knobs encode scene slots:
- Lit = scene captured.
- Bright = last-restored scene.
- Long-press SCENE button + knob N = save to slot N.
- SCENE + knob N tap = restore slot N.

Up to 16 named scenes per session, visually surfaced. Costs the
indicators for their primary "playhead" role unless we time-share —
playhead indicator only lights *one* knob at a time, so the other 15
indicators are scene slots.

### 9.4 Tempo-relative LFO on bank-identity hues

The bank-identity color slowly cycles through a narrow hue band at song
BPM. Reinforces "the rig is alive" and lets you feel tempo by glance.
Risk: visual noise if not subtle.

---

## 10. Slab plan forward (post-spec)

Assuming the spec gets agreement:

1. **Slab 6.1 — Template type + dispatcher**. PureScript types for
   `Template` and `BindingShape`; per-session declaration in the
   session library entry; template-expander into the
   `Array (Maybe Controller)` substrate.
2. **Slab 6.2 — Mode toggle + MENU button**. Wire one side button as the
   edit/bank-select toggle; LED state on the button reflects mode.
3. **Slab 6.3 — LED output path**. Web MIDI output to Twister; debounced
   30 Hz state sync; bank-identity-color palette.
4. **Slab 6.4 — Odonus param uplift**. Lift `gate`/`glide`/`vel`/`mod` to
   `Array (Pattern X)` (Thread 6's pending dependency).
5. **Slab 6.5 — TwoByEight template implementation**. The default Odonus
   surface.
6. **Slab 6.6 — Playhead indicator wire path**. BEAM → WS → Twister
   indicator LEDs.
7. **Slab 6.7 — Scene save/restore**. ETS snapshot + WS verbs (`scene-
   save` / `scene-restore`), SCENE button.
8. **Slab 6.8+** — Other templates (FugueFour, TB-303, Balistes, Vetula,
   Selene) as their machine audits land.

---

## 11. What lives where (file map)

| Concern                          | Location                                                             |
|----------------------------------|----------------------------------------------------------------------|
| Substrate (Slab 6.0)             | `calypso/frontend/src/Calypso/Frontend/Controller.purs`              |
| Template definitions             | `calypso/frontend/src/Calypso/Frontend/Controller/Templates.purs` *(new)* |
| Bank declarations per machine    | `calypso/frontend/src/Calypso/Frontend/Controller/Bindings/<Machine>.purs` *(new)* |
| LED output                       | `calypso/frontend/src/Calypso/Frontend/Controller/Leds.purs` *(new)*  |
| Scene state                      | shared with `tidal_control_bus`; verbs in BEAM Handler                |
| This spec                        | this file                                                            |

---

## 12. What we explicitly aren't doing

- No per-knob fine-mode / shift-mode beyond what Q1 (continuous-press)
  decides.
- No multi-machine surface (Twister talks to Odonus *or* Balistes, never
  both).
- No "remember last bank per machine" cross-session memory (could be
  added later, but starting simple).
- No DAW-style copy-paste between cells. Maybe Slab 6.9+.
- No MIDI Learn for ad-hoc CC bindings — bindings are declarative in
  source, not learned from the Twister.

---

## 13. Questions for you before next step

1. **The MENU button bank-select toggle** (§3) — viable, or push back?
   Alternatives are the always-on bank-select knob (§3 alt 2) or the
   double-tap (§3 alt 1).
2. **Continuous-knob press semantics** (Q1) — jump-to-mid / reset / no-
   op?
3. **TB-303 mode** (Q3) — extend Odonus or new machine?
4. **Bank-color by parameter family vs slot** (Q5) — preference?
5. **Are the four innovation proposals** (§9) interesting enough to spec
   into early slabs, or "later"?

When these settle, the slab plan in §10 is mostly mechanical to execute.
