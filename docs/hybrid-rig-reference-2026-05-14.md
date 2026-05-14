# Hybrid rig reference (2026-05-14)

A hypothetical four-voice live-coding setup, used here as a *language
expressivity test*. Not wired to a real rig yet. The point is to see
whether the post-path-2/4 cell language covers every kind of musical
intent we want to express.

## The four voices

| mvoice | sound source           | path                                | binding kind     |
|--------|------------------------|-------------------------------------|------------------|
| drums  | QuadDrum               | FH-2 main 5-8 → QD trigger inputs   | midi-note × 4    |
| bass   | Cursus Iteritas Percido| ES-9 buses 0..7 (1 V/oct + 7 CV mod)| cv × 8 + gate    |
| pad    | Ableton (Drum/Inst)    | IAC Driver Tidal ch 4 (chordal)     | midi-note (chord)|
| lead   | Laplace (iPad)         | AUDIO4c USB2 ch 1                   | midi-note + ccs  |

Plus a handful of autonomous **polysignal** cells driving the FH-2's
own LFOs / envelopes / clocks — modulation that doesn't go through
the pattern dispatcher at all.

---

## Composition pane (module.source)

The setup block. Devices, bindings, claims — anything that names the
hardware. Fires verbatim through `▶ fire` (each statement dispatched
as a verb).

```
-- Tempo first; everything downstream syncs against this via Link.
bpm 124

-- ── Devices ────────────────────────────────────────────────────────
-- FH-2 has two aliases: the bare port for control verbs, and
-- a `lat`-stamped alias for any binding whose timing has been
-- calibrated against Live's grid.
midi-device fh2       "FH-2"
midi-device fh2-qd    "FH-2"               lat 69
midi-device live      "IAC Driver Tidal"   lat 30
midi-device laplace   "AUDIO4c USB2"

-- ── Drumkit: QuadDrum, triggered from FH-2 main 5-8 ────────────────
-- Same layout as `load qd` but inlined here so the test is
-- self-contained. fh2-gate sets up the trigger MCVs (one per
-- voice); the bindings dispatch via short MIDI notes on the
-- per-voice channels.
fh2-gate 4 69 14
fh2-gate 5 70 15
fh2-gate 6 71 16
fh2-gate 7 72 17

bind qd1   midi-note  fh2-qd  14  60  100  50
bind qd2   midi-note  fh2-qd  15  60  100  50
bind qd3   midi-note  fh2-qd  16  60  100  50
bind qd4   midi-note  fh2-qd  17  60  100  50

-- ── Bass: CIP, pitch + 7 mod CVs via ES-9 ──────────────────────────
-- ES-9 buses 0..7 map to ES-9 jacks 1..8 (cv-router handles the
-- physical layout). Bus 0 is V/oct; 1..7 modulate CIP's exposed
-- panel CVs (Damp / Sharp / Bend / Fold / Bias / FM / Vol).
-- `cv` is discrete (sample-accurate per-tick re-emit); `cv-cont`
-- is sustained (good for slow modulators that should hold between
-- events).
bind cip-pitch   cv       0     -- V/oct
bind cip-damp    cv-cont  1
bind cip-sharp   cv-cont  2
bind cip-bend    cv-cont  3
bind cip-fold    cv-cont  4
bind cip-bias    cv-cont  5
bind cip-fm      cv-cont  6
bind cip-vol     cv-cont  7

-- Gate for the CIP envelope. FH-2 main jack 1 is free in our
-- allocation; emit a gate there to trigger the CIP amp.
gate cip-gate    fh2      0

-- ── Pad: Ableton Drum/Instrument Rack on IAC ch 4 ──────────────────
-- Chordal: one binding that takes a pattern of *chord-shaped*
-- tokens (e.g. "c4'maj7 g3'min7 a3'min7 f3'maj7"). Tidal's
-- apostrophe-chord syntax explodes each token into simultaneous
-- note events.
bind pad         midi-note  live  4  60  100  600

-- ── Lead: Laplace (iPad) on AUDIO4c USB2 ch 1 ──────────────────────
-- Note trigger + four CC modulations (filter / resonance / drive
-- / mod-wheel-style mod). All on ch 1.
bind lap         midi-note  laplace  1  60  100  200
bind lap-cutoff  midi-cc    laplace  1  74
bind lap-reso    midi-cc    laplace  1  71
bind lap-drive   midi-cc    laplace  1  77
bind lap-mod     midi-cc    laplace  1  1

-- ── Autonomous polysignals on FH-2 ─────────────────────────────────
-- These don't take pattern input — once fired, the FH-2 generates
-- the signal itself from its internal clock. Cells that need
-- runtime change still fire (the polysignal block reloads), but
-- there's no per-event dispatch.

-- 8 LFOs on the FHX-8CV expander (cv1 bank): paired ratios for
-- modulation across the bass + drum chain. Bipolar ±5V — patch
-- to any modulation destination.
polylfo banks cv1                                                <>
  ratios [1,     2,     3,     5,     1.3,   2.6,   5.2,   10.4] <>
  shapes [tri,   tri,   sin,   sin,   saw,   saw,   sqr,   sqr ] <>
  ranges [±5v,   ±5v,   ±5v,   ±5v,   +5v,   +5v,   +5v,   +5v ]

-- A polyclock on the FHX-8GT expander (gt1 bank): 8 gate outputs
-- running at related subdivisions. Use for clocking external
-- sequencers, slow shuffles, polymetric textures.
polyclock pulses gt1                                          <>
  base       [quarter, 8th, 16th, 8th, quarter, 8th, 16th, 8th] <>
  multiplier [1,       1,   1,    3,   1,       1,   1,    5  ] <>
  pulseWidth [12,      12,  12,   24,  12,      12,  12,   24 ] <>
  phase      [0,       0,   0,    0,   12,      12,  12,   12 ]
```

---

## Drums mvoice cells

Stack of music cells with `mvoice=drums`. Each card's tvoice points
at one of the four qd bindings. Cell bodies are PureScript `Pattern
String` expressions — under the new regime `▶ fire` wraps them in
`cue` + `play-armed`.

**Card 1**  *tvoice=qd1* (kick)
```purescript
mini "x ~ ~ ~ x ~ x ~"
```

**Card 2**  *tvoice=qd2* (snare)
```purescript
every 4 (fast 2) (mini "~ ~ x ~ ~ ~ x ~")
```

**Card 3**  *tvoice=qd3* (closed hat)
```purescript
fast 2 (mini "x*8")
```

**Card 4**  *tvoice=qd4* (clap)
```purescript
mini "~ ~ ~ ~ x(3,8)"
```

**Card 5**  *tvoice=qd1* (variant — A/B for cue/play DJ-style)
```purescript
every 8 rev (mini "x ~ x x x ~ ~ x")
```

---

## Bass mvoice cells

Stack with `mvoice=bass`. Pitch + amp gate + a CV-modulation
substack. All point to the cip-* bindings.

**Card 1**  *tvoice=cip-pitch* (V/oct melodic line)
```purescript
mini "c2 e2 g2 ~ b2 ~ g2 e2"
```

**Card 2**  *tvoice=cip-pitch* (variation: rev every 4 bars)
```purescript
every 4 rev (slow 2 (mini "c2 g2 e2 c3"))
```

**Card 3**  *tvoice=cip-gate* (amp gate — what gets struck)
```purescript
mini "x ~ x ~ x x ~ x"
```

---

## Bass-mod mvoice (CV modulation substack)

Same physical voice family, different mvoice label so the cards
stack independently. Each card drives one of the seven CIP
parameter CVs.

**Card 1**  *tvoice=cip-damp* (damping — slow sweep)
```purescript
mini "0.2 0.3 0.5 0.7 0.8 0.7 0.5 0.3"
```

**Card 2**  *tvoice=cip-fold* (wave-folding — sparse accents)
```purescript
every 3 (fast 2) (mini "0.1 0.1 0.1 0.6")
```

**Card 3**  *tvoice=cip-fm* (FM index — gestural)
```purescript
mini "0.0 0.0 0.4 0.0 0.0 0.8 0.0 0.2"
```

**Card 4**  *tvoice=cip-bias* (slow bias)
```purescript
slow 4 (mini "0.4 0.5 0.6 0.5")
```

**Card 5**  *tvoice=cip-vol* (volume articulation off the same gate)
```purescript
mini "1.0 0.6 1.0 0.6 1.0 0.8 0.6 1.0"
```

---

## Pad mvoice cells

Single tvoice `pad`. Chordal: Tidal's apostrophe-chord syntax expands
each token into simultaneous note events on the same MIDI channel
(Ableton's pad-rack track filters on ch 4).

**Card 1**  *tvoice=pad* (i-iv-v-i in minor)
```purescript
slow 4 (mini "c3'min7 f3'min7 g3'maj7 c3'min7")
```

**Card 2**  *tvoice=pad* (rev variation)
```purescript
slow 4 (rev (mini "c3'min7 f3'min7 g3'maj7 c3'min7"))
```

**Card 3**  *tvoice=pad* (denser figure for fills)
```purescript
slow 2 (mini "c3'min7 ~ f3'maj7 g3'sus4")
```

---

## Lead mvoice cells

`lead` mvoice has one note-firing tvoice (`lap`) plus four CC
modulation substacks (`lap-cutoff`, `lap-reso`, `lap-drive`,
`lap-mod`). Independent stacks because each binding produces a
distinct stream.

**Card 1**  *tvoice=lap* (melodic line)
```purescript
mini "c4 e4 g4 ~ b4 ~ a4 e4"
```

**Card 2**  *tvoice=lap* (octave-up variant)
```purescript
mini "c5 e5 g5 ~ b5 ~ a5 e5"
```

**Card 3**  *tvoice=lap-cutoff* (slow filter sweep)
```purescript
slow 4 (mini "0.3 0.5 0.7 0.5")
```

**Card 4**  *tvoice=lap-reso*
```purescript
mini "0.2 0.4 0.6 0.4"
```

**Card 5**  *tvoice=lap-drive*  (accent every 4)
```purescript
every 4 (fast 2) (mini "0.1 0.1 0.1 0.6")
```

**Card 6**  *tvoice=lap-mod* (gestural mod wheel)
```purescript
slow 8 (mini "0.0 0.3 0.7 1.0 0.7 0.3 0.0 0.0")
```

---

## Live-control bus demo

A separate substack demonstrating the runtime-mutable control bus
(`reference_purerl_tidal_live_control_substrate`). One cell sets a
control value via the `set-control` verb (a verb cell, so it fires
directly); another consumes that control inside a cued pattern via
`live "name"`. Edit the controller cell while the consumer is
playing — values flow through without recompile.

**Card 1**  *control-fire* (verb cell, mvoice=ctrl)
```
set-control bass-amp 0.85
```

**Card 2**  *control-fire* (verb cell, mvoice=ctrl)
```
set-control filter-mod 0.6
```

**Card 3**  *tvoice=cip-vol*  (music cell — references live control)
```purescript
slow 2 (mini "1.0 0.7 1.0 0.7") # gain (live "bass-amp")
```

**Card 4**  *tvoice=lap-cutoff* (music cell — references live control)
```purescript
slow 4 sine # range 0.2 (live "filter-mod")
```

> Note: `# gain` / `# range` continuous-form modulation here assumes
> the cue path lifts these correctly into the runtime pattern. If a
> param-attach with a `live "..."` mod source ends up needing
> grammar work to compose cleanly with `mini` patterns, that's a
> gap worth noting.

---

## What this exercises

- **Verb dispatch surface** — `bpm`, `midi-device`, `bind`,
  `fh2-gate`, `gate`, polysignal families (4 of 6 represented).
- **Cue/play-armed surface** — every music cell (~25 of them).
  Cold-compile cost (~7s today) applies to all; warm-compiler #11
  is the critical-path mitigation.
- **Pattern combinators** — `mini`, `fast`, `slow`, `rev`,
  `every`, apostrophe-chord syntax inside `mini`.
- **Numeric patterns** — string-form (`mini "0.2 0.5 0.7"`) flows
  through `patternStringToNumber` at install time for `cv`,
  `cv-cont`, `midi-cc` bindings.
- **Continuous oscillators** — `sine` referenced in card 4 of the
  live-control demo; range-scaling via `# range a b`.
- **Live controls** — `set-control` verb + `live "name"` inside
  cue bodies; mutate without recompile.
- **Multi-voice grouping by mvoice** — drums, bass, bass-mod, pad,
  lead, ctrl as separate stacks all in one composition.

---

## Examples that *aren't* here (worth deciding on)

These are the surfaces I had to skip or skirt; each is a candidate
for either "yes do this next" or "decide it's out of scope":

1. **`polyenv` triggered envelope on FH-2** — MCV-note-triggered ADSR
   driving CV outputs autonomously. Wasn't sure how the trigger
   source attaches (`fh2-envelope` declaration?), so skipped. Worth
   adding if you want MCV-driven amp / filter env on top of patterns.

2. **`polyeuclid` / `polyeuclid-pairs`** — autonomous Euclidean
   rhythm bank on FH-2 gates. Could replace the per-voice trigger
   bindings entirely for some rhythmic textures (let the FH-2 do
   the Euclidean math, not the host).

3. **`polyrand`** — random-rate gate generator. The 6th polysignal
   family, none represented above.

4. **Fan-out / branching** — `jux`, `mult`, `gate`,
   `crossfade`, `voiced`. Built in the `fork-merge-design` work and
   memorialised in `project_purerl_tidal_jux_design`. Today these
   live in `Tidal.Pattern.Branched` and are reachable from cue
   bodies — but I didn't include any in the cells. If you wanted to
   show stereo-style L/R splits, fan-out polyphony, etc., they slot
   right in.

5. **Continuous CV from oscillators directly** — `cv-cont` cells
   currently take `Pattern String` (token-form: `"0.1 0.3 0.5"`).
   The elegant form `range 0.0 1.0 sine` is `Pattern Number` and
   needs a compile-time type adapter (or a parallel cue path for
   numeric cells). This is a real expressivity gap if you want
   continuous shapes from cells rather than autonomous polysignals.

6. **Quantised transpose / scale** — per
   `feedback_transpose_via_scale_and_offset`, the right shape is
   `transpose chromatic 7 pat` / `transpose minor 2 pat`. Wasn't in
   the cells; would be useful for the bass + lead. If the surface
   isn't built yet, this is the natural next combinator.

7. **`drumkit` macro** — single-verb declaration that sets up bd /
   sn / hh / cp / etc. bindings + a kit dispatcher for the
   `<kit-name>` voice. Would compress the drumkit composition
   block; not here because it's a macro shortcut for what the
   per-binding form already does, and the explicit form reads
   clearer for a reference.

8. **Per-cell param specs (`# gain`, `# pan`, `# room`)** — Tidal
   idiom for sticking extra MIDI/CC modulation on a pattern. Used
   only in the live-control demo. A drumkit cell that says `mini
   "x ~ x ~" # gain (sine)` would show pattern-attached modulation
   in action. Question: does the cue path handle `#` cleanly when
   the RHS is `Pattern Number`? If not, that's another gap.

9. **`hush` / `silence`** — the panic stop. Wasn't in the cells
   because the test is "what fires", not "how to stop". Worth one
   verb cell at the top of each stack as the rig-bringup convention.

10. **Per-mvoice cells with **`bpm` overrides** or transport
    actions** — out of scope for this exercise but the `bpm <n>`
    verb route fires from anywhere. Could be a "Transport" mvoice
    distinct from "ctrl".

---

## On LFOs from FH-2

Yes — definitely worth showing, which is why a `polylfo` already lives
in the composition pane. The pattern of "polysignals for autonomous
modulation, cells for pattern dispatch" is the architectural shape
the FH-2 unlocks. Things worth adding to demonstrate the model more
fully:

- A `polyenv` declaration so the bass amp env is FH-2-side rather
  than a `cv-cont` cell driving an external VCA.
- A second `polylfo` on a different bank running at slower-than-
  tempo rates (modulation-pedal-style background drift).
- A `polyclock` slot that pulses an external Maths cycle on a third
  destination, mixing autonomous and pattern-driven rhythmic
  layers.

The expressive leverage from polysignals is that they're
*outside* the cue/play-armed cycle: editing them re-fires the
polysignal block but doesn't go through the PureScript compiler.
That's a meaningful latency advantage even after warm-compiler
lands. Worth treating polysignals as a first-class authoring
surface in the Voice Cells pane, not just a setup-block detail.
