# Polysignals grammar — design draft (2026-05-12)

Tidal-facing grammar for FH-2 **polysignals** — block-statement
configurations that drive 8 parallel signals (CVs or gates) on one
FH-2 panel. Six families: polylfo, polyclock, polyenv, polyeuclid,
polyeuclid-pairs, polyrand. Replaces the placeholder `fh2-mode
<alias>:<name>` verb with a per-family verb and parameter-major
continuation lines.

**Terminology.** A *polysignal* is the category — a multi-output
autonomous FH-2 panel configuration. Each polysignal belongs to one
of six *families* (the verbs above). Polysignals do not accept Tidal
patterns; once configured they emit autonomously from the FH-2's
internal clock + state. Distinct from *tvoices* (`midi-note`,
`gate`, `cv`, `midi-cc-cont`, `cv-cont`), which are pattern-target
bindings.

Context: yesterday's session (2026-05-11) built the FH-2 mode library
in `fh2-config` — five conceptual families with named variants
(`ochd`, `pnw`, `fibonacci`, etc.) and a bank-aware solver
(`BankMain`, `BankCv n`, `BankGt n`) that places a polysignal onto a
specific panel and rejects bank-incompatible role kinds at solve
time. The Tidal grammar for naming and configuring these was
deferred. This is that grammar.

## Authoring goals

1. **Live-coding friendly**: edit one line, re-fire, hear it. No
   PureScript-shaped record literals; flat parameter-major lists.
2. **Family is the unit of meaning**: the verb names the family, not
   a specific named mode. Named modes (`ochd`, `pnw`, …) dissolve into
   plain parameter sweeps — they remain useful at the `fh2-config`
   CLI as canned configurations, but the Tidal surface doesn't expose
   them.
3. **Bank explicit**: which panel hosts the polysignal is part of the
   declaration. CV-only families on a gate-only bank fail at parse-or-
   handler time, not at runtime.
4. **Atomic re-fire**: every fire pushes the complete preset for that
   polysignal down to the FH-2. No incremental parameter updates. The cell
   text IS the state — unspecified parameters fill from family
   defaults.

## The verbs

One verb per family. The verb name is also the family name.

| Verb              | Bank kinds        | Slots | Notes                                                  |
|-------------------|-------------------|-------|--------------------------------------------------------|
| `polylfo`         | `main`, `cv*`     | 8     | 8 LFOs, per-slot rate/wave + envelope-level `range`    |
| `polyclock`       | `main`, `cv*`, `gt*` | 8  | 8 clock dividers, per-slot base/multiplier/skip        |
| `polyenv`         | `main`, `cv*`     | 8     | 8 MCV-bound envelopes (one MCV per slot)               |
| `polyeuclid`      | `main`, `cv*`, `gt*` | 8  | 8 Euclidean gate generators                            |
| `polyeuclidpairs` | `main`, `cv*`, `gt*` | 4 pairs | 4 (beat, accent) gate pairs on 8 outputs            |
| `polyrand`        | `main`, `cv*`     | 8     | 8 shift-register-random CV generators                  |

The bank token grammar (from `FH2.Roles`, **1-indexed user-facing**):

| Token         | AST              | Start jack | CV? | Gate? |
|---------------|------------------|------------|-----|-------|
| `main`        | `BankMain`       | 1          | ✓   | ✓     |
| `cv1`, `cv2`, … | `BankCv 0`, `BankCv 1`, … | 9, 17, …  | ✓   | ✓     |
| `gt1`, `gt2`, … | `BankGt 0`, `BankGt 1`, … | 65, 73, … | ✗   | ✓     |

Parser translates `cvN`/`gtN` → `BankCv (N-1)` / `BankGt (N-1)` once.
AST stays 0-indexed (matches `FH2.Roles`); cell text stays 1-indexed
(matches humans + module silkscreens).

## Cell-text per family

Each polysignal is a block statement: a declaration line (`<verb> <alias>
<bank>`) followed by zero or more parameter lines, with each line of the
block (declaration *and* every continuation) terminated by a trailing
**`<>` continuation marker** — except the last, which has no marker.

```
polylfo myLFO main      <>
  ratios [1, 2, 4, 8]   <>
  shapes [tri, …]
```

Read `<>` as "and also" — the next line contributes more parameters to
the same polysignal. The block ends at the first line *without* the
marker. This is syntactic (not heuristic): a stale or typo'd
continuation line falls cleanly outside the block rather than silently
fragmenting it.

(`<>` is a syntactic continuation marker, not a strict-monoid combine
— the declaration line is a header, duplicate parameter assignments
raise an error rather than being combined silently. Treat the chain as
"and also", not as semigroup append.)

One cell typically holds one polysignal per alias, though multiple
aliases can coexist in one cell (for multi-panel rigs).

### polylfo
```
polylfo myLFO main                                                <>
  ratios [1,     2,     4,     8,     1.3,   2.6,   5.2,   10.4 ] <>
  shapes [tri,   tri,   tri,   tri,   tri,   tri,   tri,   tri  ] <>
  ranges [+/-5v, +/-5v, +/-5v, +/-5v, +5v,   +5v,   +5v,   +5v  ]
```

Parameters:
- `ratios` :: 8× `Number` — rate relative to the slowest slot.
  Defaults to `[1, 2, 3, 4, 5, 6, 7, 8]` (linear) if omitted.
- `shapes` :: 8× wave token (`sin`, `sqr`, `tri`, `saw`, `rnd`,
  `nse`). Defaults to all `tri`.
- `ranges` :: 8× output-range token — per-output voltage range. See
  the range vocabulary section. Omit to leave the bank's existing
  ranges untouched.

For the common "all 8 the same range" case, use the envelope-level
`range <label>` singleton (see below) instead of writing the same
label 8 times in `ranges`.

`ochd` and friends become starting points to copy into a cell: type
`polylfo myLFO main` + paste the ratios row from the docs.

### polyclock
```
polyclock myClk gt1                                       <>
  base       [quarter, 8th, 16th, 8th, quarter, 8th, 16th, 8th] <>
  multiplier [1,       1,   1,    3,   1,       1,   1,    5  ] <>
  pulseWidth [0,       0,   0,    20,  0,       0,   0,    40 ] <>
  phase      [0,       0,   0,    0,   12,      12,  12,   12 ]
```

Parameters:
- `base` :: 8× `BaseDuration` token (`whole`, `half`, `quarter`,
  `qt`, `8th`, `8t`, `16th`, `16t`, `32nd`, `32t`, `64t`). Defaults
  to all `quarter`.
- `multiplier` :: 8× `Int` 1..127. Defaults to all `1`.
- `pulseWidth` :: 8× `Int` 0..127 — pulse length in ms; 0 = 50% PW.
  Internal slot field `length_`.
- `phase` :: 8× `Int` 0..127 — phase advance in 24ppqn pulses.
  Internal slot field `shift`.

Deferred: `skip` (Pam's-style probabilistic mute — likely belongs in
the controller-side mute path anyway, not the Tidal language).

### polyenv
```
polyenv myEnv main                              <>
  attack      [0,   0,   16,  16,  32,  32,  64,  64]  <>
  decay       [32,  64,  32,  64,  32,  64,  32,  64]  <>
  sustain     [0,   0,   64,  64,  100, 100, 127, 127] <>
  release     [32,  64,  32,  64,  32,  64,  32,  64]  <>
  randomDepth [0,   16,  0,   16,  0,   16,  0,   16]
```

Parameters:
- `attack`, `decay`, `sustain`, `release` :: 8× `Int` 0..127.
- `attackShape`, `decayShape`, `releaseShape` :: 8× `Int` 0..127 —
  stage-curve shape bytes. Default 64.
- `randomDepth` :: 8× `Int` 0..127 — per-trigger random offset.

Deferred (defaults work): `depth`, `range`, `velDepth`. The
`defaultSlot` matches the FH-2's own factory baseline so unspecified
envelopes still fire cleanly.

All default to the family's `defaultSlot` (mostly 64 — neutral).

### polyeuclid
```
polyeuclid myEuc gt1              <>
  beats      [3,  5,  4,  7,  3,  5,  4,  7 ] <>
  steps      [8,  8,  8,  16, 16, 16, 16, 16] <>
  rate       [12, 12, 12, 12, 6,  6,  6,  6 ] <>
  accentRate [0,  0,  0,  0,  0,  0,  0,  0 ]
```

Parameters:
- `beats` :: 8× `Int` 0..32. Internal slot field `pulses`.
- `steps` :: 8× `Int` 0..32.
- `rate` :: 8× `Int` 0..127 — firmware-side time-scale byte
  (Preset Tool's Rate column). Default 12.
- `accentRate` :: 8× `Int` 0..127. Default 0. Matters only for
  polyeuclidpairs; in the gates-only variant accent jacks are
  inert.

Deferred: `rotation`, `gateLength`, `reset`. Reset is per-trigger
behaviour rather than per-slot config — it needs its own design
(input/trigger plumbing) and isn't fit for the parameter-major
form.

### polyeuclidpairs
```
polyeuclidpairs myPair gt1     <>
  beats      [3,  5,  4,  7 ]  <>
  steps      [8,  8,  8,  16]  <>
  rate       [12, 12, 12, 12]  <>
  accentRate [12, 12, 12, 12]
```

Same parameter set as polyeuclid (single `Slot` type internally), but
**4-vectors not 8-vectors** — pairs are the unit. Each pair drives
two adjacent jacks (gate + accent).

**Layout question (fh2-config concern, not Calypso):** yesterday's
implementation lays out adjacent pairs on the jacks (`gate→start+2N`,
`accent→start+2N+1`, so jack 1=e1 gate, jack 2=e1 accent, …). Andrew's
preference is split-half-half: 4 beats on the top half of the panel
(`e1..e4` on jacks `start..start+3`), 4 accents on the bottom half
(`accent1..accent4` on jacks `start+4..start+7`). On `gt1` (FHX-8GT in a
line) this reads top-to-bottom as `e1, e2, e3, e4, accent1, accent2,
accent3, accent4`; on `main` (4×2 panel layout) the left column is
beats and the right is accents, so pairs read horizontally. This is a
change to `FH2.Modes.PolyEuclid.purs` `roleNamesPairs` + assignment
logic; **flagged as a follow-up, not blocking the grammar work**.

### polyrand
```
polyrand myRand cv1                                                            <>
  direction  [fwd, fwd, fwd, fwd, bwd, bwd, fwd, fwd]                          <>
  length     [8,   8,   16,  16,  8,   8,   16,  16 ]                          <>
  randomness [64,  64,  32,  32,  64,  64,  100, 100]                          <>
  rate       [6,   12,  6,   12,  6,   12,  6,   12 ]                          <>
  attenuator [127, 127, 64,  64,  127, 127, 64,  64 ]                          <>
  scale      [major, major, minor, minor, chromatic, chromatic, triad, triad]  <>
  key        [c,   c,   c,   c,   c,   c,   c,   c  ]
```

Parameters:
- `direction` :: 8× token (`stop`, `fwd`, `bwd`) or Int. **Load-
  bearing**: the FH-2 firmware silently produces nothing if
  direction is `stop`. Default `fwd`.
- `length` :: 8× `Int` 1..127 — shift-register pattern length in
  clock pulses (= sequence length). Default 8.
- `randomness` :: 8× `Int` 0..127 — bit-flip probability; **non-
  monotonic**: 64 = 50% (most random), 0 or 127 = locked. Default 64.
- `rate` :: 8× `Int` 0..127 — clock rate in 24ppqn ticks; 0 = use
  Clock source. Default 6.
- `attenuator` :: 8× `Int` 0..127 — max CV amplitude (127 = full
  output range). Default 127.
- `scale` :: 8× token (`unq`, `chromatic`, `major`, `minor`,
  `triad`, …) or Int. Default `unq`.
- `key` :: 8× note token (`c`, `c#`, `d`, …, `b`) or Int. Default
  `c`. Only meaningful when scale ≠ `unq`.
- `gateLength` :: 8× `Int` 0..127 — Change/Trigger gate length;
  0 = global default. Default 0.

## Envelope-level `range` continuation

Any polysignal block can include an optional `range <label>`
continuation line. It sets the **output voltage range** (and thus
polarity) for the bank's 8 panel jacks. Single-token argument, not an
8-vector — every jack in the bank shares the same range.

```
polylfo myLFO main                              <>
  range bipolar5v                               <>
  ratios [1, 2, 4, 8, 1.3, 2.6, 5.2, 10.4]      <>
  shapes [tri, tri, tri, tri, tri, tri, tri, tri]
```

Labels (verified empirically against FH-2 hardware capture):

| Canonical (short) | Verbose alias | Range            |
|-------------------|---------------|------------------|
| `+10v`            | `unipolar10v` | unipolar, full   |
| `+/-5v`           | `bipolar5v` (also `pm5v`) | **bipolar** |
| `+1v`             | `unipolar1v`  | unipolar, tiny   |
| `+5v`             | `unipolar5v`  | unipolar, half   |
| `+8v`             | `unipolar8v`  | unipolar, ~full  |

The `+Nv` shorthand reads naturally — `+5v` says "zero to plus five
volts unipolar", `+/-5v` says "plus or minus five volts bipolar". Both
the short and verbose forms parse equivalently; the short form is
canonical for cell text. fh2-config's `parseOutputRange` is
authoritative on the supported labels; Calypso ships the token
verbatim.

Omitting `range` leaves the bank's existing output ranges untouched.

`range` doesn't make sense for `gt*` banks (gate outputs emit fixed-
level pulses with no voltage range). fh2-config rejects that
combination.

## Token vocabularies

These are the enum-style tokens the parser recognises. Each maps to a
PureScript value at AST-build time.

- **wave**: `sin`, `sqr`, `tri`, `saw`, `rnd`, `nse`
- **base** (clock): `whole`, `half`, `quarter`, `qt`, `8th`, `8t`,
  `16th`, `16t`, `32nd`, `32t`, `64t`
- **direction** (SRR): `stop`, `fwd`, `bwd`
- **scale** (SRR): `unq`, `chromatic`, `major`, `minor`, `triad`,
  + further values per firmware (≈ 18 scales total)
- **note** (SRR root): `c`, `c#`, `d`, `d#`, `e`, `f`, `f#`, `g`,
  `g#`, `a`, `a#`, `b`
- **range** (envelope-level): see table above; opaque string passed
  through to fh2-config.

Capitalisation: lowercase preferred for cell text (live-coding
friendly), case-insensitive at parse time.

## AST

New module `Calypso.Composition.PolyFamily` (or inline in
`Composition.purs` if compactness wins).

```purescript
data PolyFamily
  = PFPolyLfo
  | PFPolyClock
  | PFPolyEnv
  | PFPolyEuclid
  | PFPolyEuclidPairs
  | PFPolyRand

data Bank
  = BankMain
  | BankCv Int   -- 0-indexed
  | BankGt Int

type PolySignal =
  { alias    :: String
  , family   :: PolyFamily
  , bank     :: Bank
  , slots    :: Array PolySlot      -- length depends on family arity
  }

-- One slot in opaque form, sent verbatim to fh2-config. The parser
-- transposes parameter-major cell text into slot-major records here.
type PolySlot = Map String PolyValue

data PolyValue
  = PVInt Int
  | PVNumber Number
  | PVToken String         -- 'tri', 'fwd', 'c#', etc — fh2-config decodes
```

Replaces the existing `Fh2ModeCfg` constructor on `DeviceConfig` with
`PolySignalCfg PolySignal` (or keeps both during transition).

Reasoning: keep `PolySlot` opaque-Map-of-tokens on the Calypso side
rather than mirroring fh2-config's per-family typed Slot records. The
shape is *family-dependent* — polylfo has `ratio/wave/polarity`,
polyrand has `direction/randomness/rate/scale/key`. Calypso doesn't
need to know the family's parameter set ahead of time; it just needs
to ship name → value pairs that fh2-config decodes. This means
adding a new family doesn't touch Calypso unless its parameter set
introduces a new token *vocabulary* (e.g. a new enum the lexer
doesn't recognise yet). Atomic-write semantics make this safe: the
Erlang dispatcher ships the whole record on every fire.

## Parser strategy

Block-statement form with **lookahead-based continuation** (no
indent-significance):

```
<verb> <alias> <bank>
<param> [<value>, <value>, …]
<param> [<value>, <value>, …]
…
```

- Declaration line: verb (`polylfo` | `polyclock` | …), alias
  (identifier), bank (`main` | `cv1`..`cv7` | `gt1`..`gt7`).
- Continuation lines: parameter name (from family's known set),
  literal `[`-delimited list. The parser keeps consuming continuation
  lines until it hits a blank line, EOF, or a top-level verb token.
  **Indentation is not significant** — the autoformatter aligns
  visually but the parser is whitespace-agnostic.
- List length must equal family arity (8 for most, 4 for
  polyeuclidpairs). Mismatch → parse error.
- Bank validation: parser rejects CV-only families
  (`polylfo`, `polyenv`, `polyrand`) on `gt*` banks. Other
  combinations the solver in fh2-config handles.
- Unknown parameter names fail at parse time with the verb's known-
  parameters list in the error message.

The parameter-major → slot-major transpose happens in the parser. By
the time the AST hits the Handler, slots are records.

## Shell-out contract (fh2-config CLI evolution)

The existing `fh2-config --apply-mode-bank <bank> <name>` is for
*named* modes from the registry. The new flow ships explicit per-
slot data via **stdin JSON**:

```
echo '{"bank":"main","family":"polylfo","slots":[
        {"ratio":1, "wave":"tri", "polarity":"bi"},
        {"ratio":2, "wave":"tri", "polarity":"bi"},
        …
      ]}' | fh2-config --apply-polysignal
```

stdin (not argv) chosen because 8 slots × N parameters easily
exceeds argv quoting sanity. The Erlang dispatcher in purerl-tidal
opens a pipe to `fh2-config --apply-polysignal` and writes the JSON
payload.

Daemon protocol addition (landed 2026-05-12, Step 7): the daemon
accepts `apply-polysignal <json>` as a single-line command on
`~/.fh2/control.sock`. Measured ~8 ms round-trip vs the ~7 s
spago-boot CLI path, a ~700× speedup. Sequencing:

1. `Daemon.Command` gains `ApplyPolySignal String`. `parseCommand`
   uses `stripPrefix "apply-polysignal "` rather than space-splitting
   so the JSON's interior spaces don't shatter the line.
2. The dispatcher matches standalone CLI semantics: build
   `(defaultConfig, defaultPreset) → polysignal`, ship both via
   SysEx, refresh the Config cache. Preset isn't cached — `set-*`
   commands don't read it.
3. `Main.purs` routes `--apply-polysignal` through `viaDaemonOr` so
   the CLI tool itself transparently uses the daemon when one is up.
4. purerl-tidal's `fh2_apply_polysignal/1` tries `fh2_daemon_call/1`
   first and falls back to the spago shell-out path on
   `{error, _}` — same pattern as `fh2_set_envelope`,
   `fh2_set_gate`. The tempfile path remains the fallback.

## Erlang dispatch arm

In purerl-tidal's `tidal_websocket_handler.erl` (or wherever the
existing `Fh2VoiceCfg` arm lives — needs lookup), add a match for
`PolySignalCfg`:

```erlang
handle_device_config({poly_signal_cfg, #{alias := Alias,
                                         family := Family,
                                         bank := Bank,
                                         slots := Slots}}) ->
    Payload = jsx:encode(#{bank => bank_to_str(Bank),
                            family => family_to_str(Family),
                            slots => Slots}),
    fh2_daemon:send(<<"apply-polysignal ", Payload/binary, "\n">>),
    %% reply: OK or ERR per daemon contract
    …
```

The daemon already manages the FH-2 connection, so the Erlang side
doesn't need to know SysEx — just emit the line and forward the
reply.

## Column-alignment autoformat

Bonus polish from the live-coding-ergonomics conversation. **Runs on
fire, not on cue** — cue is too early (user may still be mid-edit
when checking compile errors); explicit-button is friction. Fire is
the natural "commit" moment.

Before fire:
```
polylfo myLFO main
ratios [1,1.41,2,2.83,4,5.66,8,11.3]
shapes [tri,sin,tri,sin,tri,sin,tri,sin]
```

After fire:
```
polylfo myLFO main
  ratios [1,    1.41, 2,    2.83, 4,    5.66, 8,    11.3]
  shapes [tri,  sin,  tri,  sin,  tri,  sin,  tri,  sin ]
```

Where it lives: a `prettyPolySignal` in the Composition parser/
pretty-printer (analogous to `fh2-config`'s text round-trip). On
fire, the cell text is parsed, re-printed canonical, and the
editor's buffer is replaced (`Editor.ReplaceContent` — same
mechanism the LoadWorkspace bug exposed).

## What's NOT in this design

- **No per-slot disable.** Mute/unmute control comes from a separate
  hardware controller path (Midifighter 3D / Launchpad → FH-2
  directly). Tidal doesn't know about it.
- **No named-mode shortcuts in Tidal.** `polylfo myLFO main; preset
  ochd` is not a thing. Copy the parameters from the canned mode
  docs and paste them in.
- **No deltas / partial updates.** Every fire is a full preset push.
  Cell text is canonical state.
- **No runtime-routable tvoice for these families.** polylfo,
  polyclock, polyrand are autonomous on the FH-2; once configured
  they run from the FH-2's master clock without further Tidal
  involvement. polyenv and polyeuclid(pairs) similarly autonomous
  for their internal mechanics — only polyenv's *triggers* might
  later want a separate per-MCV trigger arm (current `gate fh2env
  fh2 N` style). That's a follow-up, not in this design.

## Decisions (resolved 2026-05-12)

1. **Bank token indexing**: `cv1`/`gt1` user-facing, 0-indexed in AST.
2. **Continuation-line indent**: not significant; parser uses
   lookahead on known parameter-name tokens.
3. **Parameter naming**: camelCase to match house style.
4. **Note vocabulary for polyrand `key`**: pitch-class letters
   (`c`, `c#`, …, `b`).
5. **Shell-out**: stdin JSON.
6. **Daemon protocol addition**: landed 2026-05-12 — ~8 ms vs ~7 s,
   see Step 7 section above.
7. **Autoformat**: on fire only.
8. **Wrong list length**: error.
9. **polyeuclidpairs cell shape**: 4-vectors of `beats`, `steps`,
   `rate`, `accentBeats`, `accentRate`. Physical layout (half-half
   vs adjacent-pairs) is an fh2-config concern, flagged as a
   follow-up.
10. **`randomness` (polyrand)**: kept raw 0..127. The semantic is a
    centred-distribution (64 = max-random, 0 and 127 both = locked),
    not a monotonic probability, so the user gain from a fractional
    surface doesn't justify the parser work to expose distance-from-
    centre cleanly. Document the 64-is-max gotcha and move on.

## Implementation order

1. **fh2-config CLI**: add `--apply-polysignal` (stdin JSON), shipped
   alongside the existing `--apply-mode-bank`.
2. **Calypso shared/Composition**: add AST (`PolySignalCfg`,
   `PolyFamily`, `Bank`, opaque `PolySlot`) + codec.
3. **Calypso shared/Composition/Parser**: block-statement parser for
   each family verb; parameter-major → slot-major transpose;
   length-mismatch error reporting; bank-validation for CV-only
   families.
4. **Calypso frontend**: extend tvoice-color extractor for
   `PolySignalCfg` (or sibling polysignal-color); syntax highlighting
   for family verbs + token vocabularies.
5. **Autoformat on fire**: `prettyPolySignal` in the parser/pretty
   pair; wire into the fire path with `Editor.ReplaceContent`.
6. **purerl-tidal Handler.erl**: `PolySignalCfg` arm; shell-out via
   pipe to `fh2-config --apply-polysignal`.
7. **fh2-config daemon**: `apply-polysignal <json>` line-protocol
   command; switch Erlang dispatcher to prefer the daemon socket
   with CLI fallback.
8. **On-rig validation**: workspace with one cell per family, walk
   all five on hardware, document anything weird.
