# FH-2 Rich Interface — Plan / Spec

A focused-session plan for extending Calypso's control over the FH-2
from "gate / envelope / FHX-8GT gate" (what we have today) to the
breadth of what the FH-2 can do: per-output MIDI-CC routing, internal
LFOs, fixed offsets, summing, and per-output mode selection — all
declared in the composition pane's routing grammar and persisted via
`fh2-config`.

This doc is structured to be **self-contained for another Claude to
execute**: it points at every relevant file, every existing memory
entry, every existing module, and describes the deltas needed at each
layer.

## Motivation

Calypso's current FH-2 surface covers exactly three modes (gate,
envelope, FHX-8GT-gate). These are sufficient for percussion-style
triggering but leave most of the FH-2's capability unexposed. The FH-2
is one of the most feature-dense modules on the rig and a focused
session opening it up is high-leverage — the rest of the modular voice
graph hangs off its outputs.

The session has a **double scope**: implementation work (CLI + daemon +
routing-grammar) and **interface design**. Andrew wants the language
surface in Tidal/Calypso to be as rich as we can make it without
overshooting. Some verb shapes are proposed below; iterate on them
before committing to encoding.

## Current state (what's already there — DO NOT re-implement)

### fh2-config (PureScript, `~/work/afc-work/music/expert-sleepers/fh2-config`)

**Has:**

- Round-trip SysEx codec (Decode.purs / Encode.purs) for the FH-2's
  full config — MCVs (16 × 32 bytes), Mapping table (32 rows),
  preset items, global config bytes. (`src/FH2/Types.purs` for the
  full type schema; `src/FH2/Decode.purs` and `Encode.purs` for the
  wire codec.)
- A `.fh2` text DSL with a parser (Parser.purs) + pretty-printer
  (Pretty.purs) that round-trips through Config.
- A daemon (`src/FH2/Daemon.purs`) listening on Unix socket
  `~/.fh2/control.sock` for short-line commands; this is the fast
  path that purerl-tidal already shells to (~10 ms vs ~7 s for
  cold `spago run`). The daemon command set is small —
  `SetGate`, `SetEnvelope`, `SetEnvelopeWithCcs`, `SetAdsrCcs`,
  `EnableMcv`. Each command performs a read-modify-write SysEx round
  trip with pacing (memory:
  `reference_es9_sysex_pacing.md` — same lesson applies).
- Composable mutation combinators in `src/FH2/Combinator.purs`:
  `withMcv`, `configureMcv`, `setCcMapping`, ADSR helpers,
  `clearAllMcvs`, `encodeMidiChannel`. **These are the substrate;
  most of the work here is just plumbing them through the daemon
  and CLI.**
- A test fixture set at `fixtures/`.

**Memory pointers:**

- `reference_fh2_config_protocol.md` — section layout, MCV fields,
  ES-9 pattern to follow
- `reference_fh2_config_daemon.md` — Unix socket, ~10 ms per write
- `reference_fh2_runtime_quirks.md` — note-off form, phantom CV slot,
  ADSR via CC
- `reference_es9_sysex_pacing.md` — needs ~50 ms gap between
  consecutive SysEx requests

### Calypso routing grammar (`purerl-tidal/src/Tidal/WebSocket/Handler.erl`)

Today's `fh2-config` verb supports two modes:

```
fh2-config <alias>:gate     voice=N out=O ch=K
fh2-config <alias>:envelope voice=N out=O ch=K
```

…where `out` can be a literal jack (1-8) or `<expander-alias>:<slot>`
(resolves to legacy output 65+ for FHX-8GT). The parser is in
Handler.erl's `parse_fh2_config_kvs` (line ~1245). The dispatch arm
in handle_pattern_message shells to `fh2_set_envelope` / `fh2_set_gate`
(via the daemon).

### purerl-tidal dispatch

`midi-cc-cont` already dispatches host CC streams to any MIDI device
alias (memory: `project_purerl_tidal_revival.md`,
`reference_purerl_tidal_live_config.md`). The continuous-binding
play-armed bridge landed 2026-05-10 (task #145). So sending CC to the
FH-2 from a cell already works; the missing piece is **the FH-2's own
internal routing for that incoming CC**.

## Target capabilities

In priority order. Items 1-3 are the must-haves for the session. Items
4+ are stretch goals; if there's time, great, otherwise leave as
follow-up.

### 1. Direct CC → CV output mapping (Mapping table)

The FH-2 has a 32-row Mapping table where each row says "MIDI CC C on
ch K → output O". This is the cleanest CC-driven CV path and is what
`fh2lfo` in the megatest workspace needs. (`setCcMapping` in
Combinator.purs already exists; we just need to expose it.)

**Proposed verb:**

```
fh2-config <alias>:cc ch=K cc=C out=O [slot=S]
```

- `slot` is optional; if absent, the next free row in the mapping
  table is used. Slot management requires reading current state.
- `out` follows the same convention as `gate/envelope`: literal 1-8 for
  panel jacks, `<expander-alias>:<slot>` for expander jacks.

### 2. Internal LFO output

The FH-2 has free-running LFOs that can be assigned to outputs. Each
LFO has rate, shape, and depth — possibly modulable by CC. (Verify
against the FH-2 manual and Combinator.purs to confirm exactly which
LFO parameters exist and which can be CC-bound.)

**Proposed verb:**

```
fh2-config <alias>:lfo out=O rate=R [shape=sine|saw|tri|square] [depth=D]
fh2-config <alias>:lfo out=O ch=K cc-rate=C1 [cc-depth=C2]   -- CC-bound variants
```

The CC-bound form would create a Mapping-table entry that targets the
LFO's rate (or depth) parameter rather than an output.

### 3. Constant offset output

A fixed DC voltage on an output. Useful for biasing other modules,
tuning offsets, etc.

**Proposed verb:**

```
fh2-config <alias>:offset out=O value=V
```

Where `value` is a number in the FH-2's CV unit convention (verify —
likely 0..1 → 0..5V, or -1..1 → ±5V).

### 4. Per-output mode setting (stretch)

The FH-2 may support setting an output's mode directly without going
through MCV: e.g. "this output is a pitch CV from ch K", "this output
is a gate from ch K", etc. If the FH-2 exposes this and Combinator
already wraps it, expose it.

**Proposed verb:**

```
fh2-config <alias>:out=O mode=<pitch|velocity|aftertouch|pitchbend|gate|trigger> ch=K
```

### 5. Output composition / summing (stretch — verify FH-2 support)

Andrew mentioned "outputs can be composed of inputs". Confirm what
this means at the FH-2 level — does an output have multiple input
slots that sum, or is "composition" achieved by routing multiple
Mapping rows to the same output (which the firmware sums)?

If true sum-of-sources is a thing, propose:

```
fh2-config <alias>:sum out=O sources=[<source-spec>, ...]
```

Source-spec needs design; probably tagged forms like
`{ kind: cc, ch: K, cc: C }`, `{ kind: lfo, idx: N }`,
`{ kind: const, value: V }`.

If composition is really just multiple Mapping rows to one output,
declare it via repeated `fh2-config <alias>:cc out=O ...` verbs and
document that they accumulate.

## Implementation plan

### Phase 0 — Research (30 min)

Before writing any code:

1. Read the FH-2 manual (or `expert-sleepers/fh2-config/README.md`)
   for the canonical feature list. Confirm what's actually
   configurable via SysEx vs only on the module's UI.
2. Read `src/FH2/Combinator.purs` end-to-end. Find every helper that
   exists but isn't reachable from the CLI today. (`setCcMapping`,
   `withMcv`, ADSR helpers — and possibly more for LFO / offset /
   per-output mode.)
3. Read `src/FH2/Types.purs` for the wire-level field schema.
   Specifically: what fields control LFO rate/shape/depth? What field
   selects an output's input source? What does `mcv_VC = 1` (CV-output
   enable) actually depend on for its value source?
4. Confirm the wire-level encoding of MIDI channel + CC source in the
   Mapping rows. Existing comment in Combinator.purs:163-170 warns
   that field names don't match semantics:
   - wire `channel` = CC number
   - wire `number` = encoded channel + 11 (for MIDI port A — caveats
     noted, verify against `encodeMidiChannel`)
5. Decide LFO scope. The FH-2 may have multiple internal LFOs; check
   how many and whether they're addressable individually or via
   "first available slot".

### Phase 1 — Daemon protocol + CLI flags (1 hour)

For each new verb in priority order:

1. Add a new `DaemonCmd` variant in `src/FH2/Daemon.purs`
   (parsing + pretty-print + handler).
2. Add the corresponding `--set-cc-out` / `--set-lfo` / `--set-offset`
   etc. CLI flag in `src/Main.purs`.
3. Wire each to the existing combinator(s). For `cc`, that's
   `setCcMapping` + `encodeMidiChannel`. For `lfo`, may need a new
   combinator that wraps the LFO field writes. For `offset`, also
   likely a new combinator (a Mapping row with a `const` source).
4. Round-trip test: read current config, apply the new mode, write
   back, read again, confirm the SysEx round-trips correctly.

**Test discipline**: every new verb gets a fixture round-trip test in
`fh2-config/test/` (existing test layout convention). Don't merge
without it — FH-2 SysEx is unforgiving.

### Phase 2 — Calypso routing-grammar verbs (45 min)

In `purerl-tidal/src/Tidal/WebSocket/Handler.erl`:

1. Extend `parse_fh2_config_verb` (around line 1234) to parse new
   modes alongside `gate` / `envelope`. Each new mode produces a new
   tuple shape (e.g. `{fh2_cc, Ch, Cc, Out}`,
   `{fh2_lfo, Voice, Out, Rate, Shape, Depth}`).
2. Add handler arms in `handle_pattern_message` that shell out to the
   fh2-config daemon for each new tuple shape. Pattern: copy the
   `{fh2_gate, ...}` arm at line ~428 and adapt.
3. Add wrapper functions in Handler.erl mirroring `fh2_set_gate` /
   `fh2_set_envelope` (line ~1051+): `fh2_set_cc`, `fh2_set_lfo`,
   etc. Each tries the daemon first, falls back to spago shell-out
   on failure.

### Phase 3 — Composition AST + parser + frontend (45 min)

For the FH-2 verb extensions to be visible to the frontend's parser
and type-color extractor (memory: this matters; without it the
parser fails on unknown lines and ALL card colors drop):

1. In `calypso/shared/src/Calypso/Composition.purs`, extend the
   `DeviceConfig` shape (or whatever the `fh2-config` statement's AST
   is currently called) to carry the new modes.
2. In `calypso/shared/src/Calypso/Composition/Parser.purs`, extend
   the parser for the `fh2-config` verb to recognise new mode keywords
   (`cc`, `lfo`, `offset`, etc.) and parse the appropriate kv pairs.
3. Add codec entries in Composition.purs for the new AST shapes
   (the JSON wire format the persistence layer uses).
4. Update `extractTvoiceTypesFromComposition` in
   `frontend/src/Calypso/Frontend/Shell.purs` if any of these verbs
   define new tvoices that need card colors. (CC mappings probably
   don't create new tvoices since they affect FH-2 internal routing;
   LFO output might, if a Tidal cell drives the LFO's rate via CC.)

### Phase 4 — Workspace + tvoice-test additions (15 min)

Add cards to `tvoice-test/calypso-session.json` exercising the new
verbs. Initially as TODO placeholders, then with real bindings as the
implementation lands. Examples:

```
# CC → output 5 (panel jack 5), on ch 14 CC 7
fh2-config fh2:cc ch=14 cc=7 out=5
midi-cc-cont fh2cc7 fh2 14 7
```

```
# Internal LFO on output 6 at ~1 Hz, sine
fh2-config fh2:lfo out=6 rate=0.5 shape=sine depth=1.0
```

```
# Fixed +1V offset on output 7
fh2-config fh2:offset out=7 value=0.2
```

### Phase 5 — On-rig validation (30 min)

For each new mode:

1. Fire the workspace; confirm the daemon's reply is `OK`.
2. Patch the relevant FH-2 jack to a scope or a known-good destination
   (VCO V/oct, VCA CV, filter cutoff).
3. Confirm the expected signal: static for offset, periodic for LFO,
   responsive-to-pattern for CC-driven.
4. Round-trip: re-read the FH-2 config (`fh2-config --live-read-raw`
   or via the daemon) and confirm the in-memory state matches what
   was pushed.

## Interface design — open questions for Andrew

These are the design calls that benefit most from interactive
discussion. The future Claude should NOT make these alone — flag and
ask, or revert to the most conservative reading.

1. **Slot management for the Mapping table.** Should `fh2-config
   <alias>:cc` auto-allocate the next free row, or require an explicit
   `slot=N`? Auto is friendlier but causes invisible state — repeating
   the same `cc` declaration creates a new row each time unless we
   dedup on (ch, cc, out).

2. **LFO addressability.** If the FH-2 has N LFOs, do we expose them
   by index (`lfo=0..N-1`) or by "next free"? If by index, what
   happens on collision (overwriting another voice's LFO)?

3. **Composability for output mode.** If both `fh2-config <alias>:cc
   out=5 ...` and `fh2-config <alias>:lfo out=5 ...` target jack 5,
   do they sum, or does the latter override the former? The FH-2's
   own behaviour will dictate, but we should document the resulting
   semantics clearly.

4. **CC-bound LFO parameters.** Should rate and depth be modulable by
   their own CCs? If so, that's a nested-pattern story: a cell
   dispatched to `lfoRate` CC modulates the rate of an LFO that's
   itself modulating some other CV. Worth exposing, but the verb
   grammar gets tangled — consider a two-step form:
   ```
   fh2-config fh2:lfo out=6 rate=0.5
   fh2-config fh2:cc ch=14 cc=20 out=lfo0:rate   # CC mod the LFO's rate
   ```
   …where `out=<lfo-ref>:<param>` is a new sink kind. Sketch only —
   needs discussion.

5. **Pattern Number scaling.** Cells emit Pattern Number in 0..1; the
   dispatcher scales to MIDI CC 0..127 for `midi-cc-cont`. For
   FH-2-internal CV ranges (which can be wider), do we want a
   per-binding scale parameter, or trust the FH-2's own scaling?

## Test plan

This belongs in the post-implementation merge:

1. Round-trip fh2-config fixture tests for every new verb (CI).
2. Update `tvoice-megatest-checkpoint.md` with cards for the new
   verbs, marking c5 (fh2lfo) as ✅ end-to-end after the CC mapping
   path lands.
3. Add a memory entry summarising the new FH-2 verbs and pointing at
   this plan.

## Out of scope for this session

- FH-2 input handling (analog ins as MIDI clock sources etc.)
- FH-2 preset save/restore beyond what fh2-config already does
- ESX-8CV LFO (it's a separate module; see
  `tvoice-megatest-checkpoint.md` items 12 / 13)
- Other ExpertSleepers modules (ES-3, FH-2 v2 future firmware)

## Hand-off note for a subagent / parallel Claude

If executing this as a standalone session, start with **Phase 0** and
report back what you find before committing to a verb grammar. The
proposed shapes in this doc are starting points, not commitments —
the FH-2's actual capability set may suggest a different grouping.

When you reach the "open questions" section above, do not guess —
write your best understanding back as a follow-up message and wait
for Andrew's call. He's likely to have strong opinions on slot
management and LFO addressability (memory:
`feedback_explicit_device_registration.md` — Andrew prefers explicit
over auto-magic).

Round-trip test discipline is mandatory: every config-mutating verb
gets a fixture test that proves it survives a SysEx push/read.
Half-an-hour spent on test scaffolding will save days of "why isn't
the rig responding" later.
