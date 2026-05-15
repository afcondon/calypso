# Typeful cues — design pause point (2026-05-15)

We're between design phases on the typeful-cues feature branch. No
code on the Calypso side yet; the next gating question moved into a
companion repo, `purerl-leaf-edit-benchmark`, which measures whether
the compilation strategy this design assumes is achievable in
practice. When that comes back with numbers, this picks up again.

## What's settled architecturally

### The leaf invariant
Tvoices never refer to each other or share state. A cue body targets
exactly one binding (the cue's destination). This is a ground-truth
architectural commitment, not an aspiration — Andrew's mental model
is that cues are leaves on the dependency tree, full stop.

The leaf invariant is the lynchpin: it's what makes any per-tvoice
slicing strategy *safe*. Without it, hot-swapping one cue could
break another.

### Two-tier compilation
The .tiderl file is one PureScript module to humans and to spago —
that's where the typecheck win lives. But operationally it
decomposes into two kinds of compilation artefact at the daemon:

- **Baseline module** (`calypso_session@ps.beam`) — devices,
  bindings, polysignals, controls. Reloaded only when the
  baseline-level decls change.
- **Per-voice deploy modules** (`calypso_voice_<tvoice>@ps.beam`) —
  one per tvoice, each a tiny synthesised wrapper that exposes an
  `armed/0` function returning a `Pattern`, importing the baseline
  for binding references. Reloaded only when that specific cue's
  RHS changes.

Per-voice module **names** (not module **versions**) sidestep
BEAM's two-versions-per-module-name code-server limit. Each voice's
deploy artefact lives independently; loading a new `calypso_voice_qd1`
doesn't touch `calypso_voice_qd2`. No diffing, no shared mutable
state — just structural knowledge that this edit affected qd1's
slice.

### Cue type (simplified vs original sketch)
One phantom Symbol for mvoice. Tvoice is just a PureScript
declaration name — uniqueness comes for free from module scope; no
need to lift it into a Symbol.

```purescript
data Cue (mvoice :: Symbol) = Cue
  { destination :: Binding   -- existential over MidiNote/Cv/Gate/...
  , body        :: Pattern
  }

qd1 :: MidiNote
qd1 = midiNote fh2qd 14 60 100 50

qd1A :: Cue "drums"
qd1A = cue qd1 (mini "x ~ ~ ~ x ~ x ~")

qd1B :: Cue "drums"
qd1B = cue qd1 (every 8 rev (mini "x ~ x x x ~ ~ x"))
```

The daemon reads `destination` from the compiled `qd1A` value at
extract time to know which voice wrapper to emit. The mvoice
Symbol stays type-level because it's a free-form grouping label
that benefits from autocomplete and from being visible in error
messages.

This is materially simpler than the earlier dual-Symbol sketch
(`Cue (mvoice :: Symbol) (tvoice :: Symbol) (a :: Type)`). Tvoice
errors become normal "name not in scope" diagnostics; only mvoice
needs custom Prim.TypeError treatment if any.

### Compilation contract
- **Editor**: whole .tiderl typechecks as one PS module. LSP,
  errors, autocomplete, refactor-rename all work at file-level
  granularity.
- **Runtime**: per-voice deploy module per gen_server, hot-loaded
  independently. The voice gen_server's existing Erlang loop calls
  `calypso_voice_<tvoice>@ps:armed/0` to get pattern data — no
  "main" needed on the PureScript side.

## The gating question — ANSWERED (2026-05-15)

The benchmark (`purerl-leaf-edit-benchmark` #208) found the
incremental hook: **`purs-backend-erl --filter <prefix>` combined
with `rm output-erl/build.txt`** scopes emit to the dependency
closure of the filtered modules. For a one-leaf edit:

- 0.31s for backend-erl to emit Leaves.Leaf001's dep closure
  (33 modules) vs 1.22s for the full 242-module emit
- Plus content-hash dedup before `erlc` (0.18s for one .beam)
- Plus BEAM `code:load_binary` (~150 µs)
- **Total: ~0.6s edit-to-running**

Comfortably in live-coding range. **The architecture is
green-lighted.**

Full numbers and methodology in
`purerl-leaf-edit-benchmark/docs/findings.md`.

The warm-toolchain investigation (Calypso task #11; benchmark
task #20) is deferred — would push latency further (~0.2s) but
no longer gating. Pick up only if 0.6s proves uncomfortable in
real use.

## Path forward when this resumes

The benchmark green-lit the architecture. Next steps:

1. **Cue Prelude sketch** (no code; design conversation): the
   `Binding` existential, the `IsBinding` typeclass, the `cue`
   smart constructor, what `MidiNote`/`Cv`/`Gate` look like as
   PureScript types. What does Calypso.Prelude expose? How does
   a `Pattern` compose (mini-notation parser → `Pattern`)? What
   surface do `every`, `rev`, `jux` etc. take?

2. **Feature branch on Calypso**: spin up a `typeful-cues`
   branch. Initial scaffolding: a `Calypso.Prelude` module in
   `shared/`, the synthetic `CalypsoVoice_<tvoice>` wrapper
   generator on the daemon side, the wire protocol additions
   (`SetSession :: String` + `ArmCue :: String -> String`).

3. **Pipeline integration**: wire up `rm build.txt && spago build
   --backend-args="--filter <prefix>"` into the daemon's hot path.
   Add content-hash dedup before `erlc`. Test the end-to-end
   timing matches the benchmark prediction (~0.6s).

4. **Migrate one example session** from Level 2 to Level 3 and
   confirm the round-trip works. Compare typeful diagnostics vs
   today's bespoke parser errors.

Throughout: **Level 2 (landed at `c82e14e`) remains the stable
backstop**. Level 3 is the typed-uplift, not a replacement; if
anything goes wrong, the main branch keeps working.

## Related docs

- `docs/cue-grammar-evolution-2026-05-15.md` — the three-level
  grammar design (Level 1, Level 2, Level 3 sketch). Level 3 is
  what this handoff covers in more detail.
- `docs/tiderl-format-design-2026-05-14.md` — the .tiderl-as-file
  Model B design that Level 3 manifests; composition as canonical,
  cards as projections.
- `docs/architectural-bet-2026-05-14.md` — the cue/play-armed bet
  that motivated the .tiderl reckoning.

## Memory entries written during this design pass

None yet on this particular thread — the design conversation is
captured in this doc rather than in memory because it's
project-specific and self-contained here. If `purerl-leaf-edit-
benchmark` produces findings worth distilling into a memory entry
(e.g. "purs-backend-erl incremental emit is achievable via X"),
that's the moment to write one.
