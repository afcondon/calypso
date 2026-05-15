# Typeful cues — implementation plan (2026-05-15)

The architecture green-lit by the `purerl-leaf-edit-benchmark` finding.
This is the implementation plan: what to build, in what order, across
Calypso and purerl-tidal.

## Vision

A `.tiderl` file is a **real PureScript module**. The user authors
devices, bindings, polysignals, controls, tags, and cues as ordinary
PureScript declarations. The type system enforces "cue body targets a
real binding," "control name matches a declared control," and so on.
Calypso reads the file, projects it into the composition pane / cards
/ hylograph; the daemon compiles it through purs / purs-backend-erl /
erlc and hot-loads per-voice deploy modules into BEAM.

The leaf invariant (tvoices never reference each other) shapes the
runtime: one cue edit produces one new `.erl`, one new `.beam`, one
`code:load_binary`, one gen_server swap on cycle boundary. End-to-end
latency: ~0.6s per cue edit, measured.

## Constraints

- **Level 2 stays operational on `main`.** Anything we ship here is a
  feature branch until proven; the production rig must keep working.
- **Per-voice deploy modules have unique names.** No two voices share
  a Module name in BEAM's code server (only the BASELINE is shared).
- **The hot path is the cue edit.** Baseline edits accept a ~2s
  stall; cue edits target sub-second.
- **No daemonisation of purs-backend-erl** in this round. Task #20
  remains deferred.
- **Composition pane does NOT compile on every keystroke.** Compile
  happens on explicit fire, not on edit. Andrew's call: cue/play is
  the live-coding contract.

## System overview

```
┌─────────────────────────────────────────────────────────────────────┐
│ Calypso webapp (browser)                                            │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐                 │
│  │ Composition  │ │ Cards (Voice │ │ Hylograph    │                 │
│  │ pane         │ │ Cells)       │ │              │                 │
│  │ (PS source)  │ │ (projection) │ │ (projection) │                 │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘                 │
│         │                │                │                         │
│         └────────────────┼────────────────┘                         │
│                          │ (Halogen state: AST + dirty card bodies) │
└──────────────────────────┼──────────────────────────────────────────┘
                           │ WebSocket (Calypso protocol v2)
                           │   SetSession(source)
                           │   ArmCue(name)
                           │   FireBaseline / state / config / bpm
┌──────────────────────────▼──────────────────────────────────────────┐
│ Calypso daemon (Node + HTTPurple)                                   │
│  - Owns the `.tiderl` file on disk                                  │
│  - Orchestrates: write file → purs compile → backend-erl --filter   │
│    → content-hash → erlc → ship .beam binary over WS                │
│  - Synthesises voice-wrapper modules per armed cue                  │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ WebSocket (purerl-tidal protocol)
                           │   LoadBaselineBeam(binary)
                           │   LoadVoiceBeam(tvoice, binary)
                           │   ArmVoice(tvoice, fun-ref)
┌──────────────────────────▼──────────────────────────────────────────┐
│ purerl-tidal (BEAM)                                                 │
│  - Per-voice supervisor tree (one gen_server per tvoice)            │
│  - StateBus (controls + tags, ETS-backed)                           │
│  - MIDI scheduler                                                   │
│  - code:load_binary for hot-load                                    │
└─────────────────────────────────────────────────────────────────────┘
```

## The `.tiderl` module format

### Filename and module naming

- Files end in `.tiderl` (the user-facing extension).
- The PureScript module name is fixed: `CalypsoSession`. (Files are
  per-session but the module name is constant; the daemon places
  exactly one session into the build at a time.)
- File header is the PureScript module declaration:
  ```purescript
  module CalypsoSession where
  import Calypso.Prelude
  ```

### Declarations

Five kinds of top-level declarations:

1. **Devices** — typed handle to a physical MIDI/CV destination.
   ```purescript
   fh2    :: MidiDevice
   fh2    = midiDevice "FH-2"

   fh2qd  :: MidiDevice
   fh2qd  = midiDevice "FH-2" `withLat` 69
   ```

2. **Bindings** — addressable destinations within a device.
   ```purescript
   qd1 :: MidiNote
   qd1 = midiNote fh2qd { ch: 14, note: 60, vel: 100, dur: 50 }

   cipPitch :: Cv
   cipPitch = cv es9 0 Voct
   ```

3. **Polysignals** — config blocks that drive autonomous hardware
   (FH-2 polyfamilies).
   ```purescript
   banks :: Polysignal
   banks = polylfo "cv1"
     { ratios = [1.0, 2.0, 3.0, 5.0, 1.3, 2.6, 5.2, 10.4]
     , shapes = [Tri, Tri, Sin, Sin, Saw, Saw, Sqr, Sqr]
     , ranges = [Bi5, Bi5, Bi5, Bi5, Uni5, Uni5, Uni5, Uni5]
     }
   ```

4. **Controls / tags** — declared default values for the live-control
   and tag buses. The Symbol name is type-level for cross-checking.
   ```purescript
   bassAmp   :: Control "bass-amp"
   bassAmp   = control 0.85

   fillTag   :: Tag "fill"
   fillTag   = tag Off
   ```

5. **Cues** — pattern values bound to a destination, grouped by mvoice.
   ```purescript
   qd1A :: Cue "drums"
   qd1A = on qd1 (mini "x ~ ~ ~ x ~ x ~")

   qd1B :: Cue "drums"
   qd1B = on qd1 (every 8 rev (mini "x ~ x x x ~ ~ x"))

   cipPitchA :: Cue "bass"
   cipPitchA = on cipPitch (mini "c2 e2 g2 ~ b2 ~ g2 e2")
   ```

The mvoice Symbol is purely type-level metadata; cues with the same
mvoice show up in the same stack in the cards view.

### Reserved cue identifiers

The daemon discovers cues by looking for top-level values whose type
unifies with `Cue mvoice` for some Symbol `mvoice`. No magic naming;
just type-directed discovery.

## Calypso.Prelude — the DSL surface

`Calypso.Prelude` is a new PureScript module living in purerl-tidal's
spago workspace (since that's where the build happens). It exposes:

### Types

```purescript
-- Hardware devices
data MidiDevice
data Es9Device
data Fh2Device

-- Bindings (destinations within a device)
data MidiNote  -- a (ch, note, vel, dur) tuple on a MidiDevice
data MidiCc    -- a CC slot on a MidiDevice
data Cv        -- a CV jack on an Es9Device
data Gate      -- a Gate jack on an Fh2Device

-- Existential binding for cue destinations
data Binding   -- holds any of {MidiNote, MidiCc, Cv, Gate}

-- Patterns
data Pattern   -- query-time stream of events

-- Cues
data Cue (mvoice :: Symbol) = Cue
  { destination :: Binding
  , body        :: Pattern
  }

-- Live-control names (type-level for cross-check)
data Control (name :: Symbol)
data Tag (name :: Symbol)

-- Polysignals
data Polysignal
```

### Constructors

```purescript
-- Devices
midiDevice :: String -> MidiDevice
es9Device  :: String -> Es9Device
fh2Device  :: String -> Fh2Device

-- Latency tweaking
withLat    :: forall d. d -> Int -> d   -- typeclass-overloaded

-- Bindings
midiNote :: MidiDevice -> { ch :: Int, note :: Int, vel :: Int, dur :: Int } -> MidiNote
cv       :: Es9Device  -> Int -> CvRange -> Cv
gate     :: Fh2Device  -> Int -> Gate

-- Binding → existential
class IsBinding b where
  toBinding :: b -> Binding

-- Cue smart constructor
on :: forall b mv. IsBinding b => b -> Pattern -> Cue mv
on b p = Cue { destination: toBinding b, body: p }

-- Convenience: mvoice-explicit helpers if users want them
drumsCue :: forall b. IsBinding b => b -> Pattern -> Cue "drums"
bassCue  :: forall b. IsBinding b => b -> Pattern -> Cue "bass"
-- etc., user can define their own

-- Controls / tags
control :: forall name. Number -> Control name
tag     :: forall name. TagValue -> Tag name

-- Polysignals (six families)
polylfo, polyclock, polyenv, polyeuclid, polyeuclidPairs, polyrand
  :: String -> PolysignalConfig -> Polysignal
```

### Pattern combinators

The mini-notation parser becomes a PureScript function:

```purescript
mini :: String -> Pattern
```

Pattern operators (everything purerl-tidal already has):

```purescript
every     :: Int -> (Pattern -> Pattern) -> Pattern -> Pattern
rev       :: Pattern -> Pattern
fast      :: Number -> Pattern -> Pattern
slow      :: Number -> Pattern -> Pattern
stack     :: Array Pattern -> Pattern
cat       :: Array Pattern -> Pattern
jux       :: (Pattern -> Pattern) -> Pattern -> Pattern  -- specialized for fork/merge
silence   :: Pattern
-- ... and many more
```

Live-control consumption:

```purescript
live      :: forall name. Control name -> Pattern   -- Pattern of Number
                                                     -- emits current value
liveT     :: forall name. Tag name -> Pattern       -- Pattern of TagValue
```

The Symbol-typed `Control`/`Tag` arguments give us static
cross-checking — `live bassAmp` works iff `bassAmp` was declared.

## Compile pipeline (daemon-side)

The Calypso daemon owns this orchestration. Triggered on `ArmCue
<name>` from the frontend.

### Disk layout

```
purerl-tidal/                            # spago workspace
├── spago.yaml
├── src/
│   ├── Calypso/Prelude.purs             # the DSL (Calypso.Prelude)
│   ├── Calypso/Prelude/*.purs           # internals
│   ├── Tidal/...                        # existing scheduler
│   └── ...
├── session/                             # daemon-managed
│   ├── CalypsoSession.purs              # the current .tiderl, as a PS module
│   └── Voices/                          # synthesized per-arm wrappers
│       ├── Qd1.purs                     # exposes armed/0 returning a Cue
│       ├── Qd2.purs
│       └── CipPitch.purs
├── output/                              # purs corefn
├── output-erl/                          # purs-backend-erl .erl
└── ebin/                                # erlc beam
```

The `session/` directory is daemon-mediated: users edit the .tiderl
in the Calypso frontend, the daemon writes it as `CalypsoSession.purs`,
synthesises and updates `Voices/*.purs`, and runs the build pipeline.
The session directory is part of the spago build (`src` in spago.yaml).

### Per-cue arm pipeline

When the frontend sends `ArmCue qd1A`:

1. **Update voice wrapper.** Daemon writes
   `session/Voices/Qd1.purs`:
   ```purescript
   module CalypsoVoice.Qd1 where
   import CalypsoSession (qd1A)
   armed :: Cue "drums"
   armed = qd1A
   ```
   (When re-arming `qd1B`, just rewrite this with `qd1B` instead.)

2. **Run `purs compile`** to update affected corefns. Incremental;
   only what changed.

3. **`rm output-erl/build.txt && purs-backend-erl --filter CalypsoVoice.Qd1`**
   — emits the dep closure (Qd1 + CalypsoSession + Calypso.Prelude +
   …). Measured ~0.3s on the benchmark project; expected similar here
   because the leaves are still essentially trivial.

4. **Content-hash the resulting .erl files** against the previous
   manifest. Only `.erl` files whose md5 changed go to erlc. For a
   pure cue-body edit, this is exactly one `.erl`.

5. **`erlc -disable-feature maybe_expr`** on the content-changed .erl(s).
   ~0.18s per file.

6. **Read the resulting `.beam` binaries.** Ship them to purerl-tidal
   over the wire.

7. **Daemon updates its manifest** for next iteration.

### Per-baseline edit pipeline

When the frontend sends `SetSession <source>` and the diff includes
non-cue declarations (devices, bindings, polysignals, controls, tags):

1. Write `CalypsoSession.purs` to disk.
2. Run the same pipeline, but with `--filter CalypsoSession`. This
   re-emits CalypsoSession and everything that depends on it (which
   is every voice wrapper).
3. Content-hash everything, erlc what changed, ship all changed .beam
   to purerl-tidal.
4. purerl-tidal hot-loads baseline + all affected voice modules.
5. ~2s expected. Acceptable for infrequent baseline edits.

### `SetSession` for non-arming edits

When the user edits the file without arming anything (typing in the
composition pane, dragging a card edit into the file), the daemon
should **not** auto-compile. The compile happens at fire time. The
file just gets parsed (PureScript-aware, but possibly via a
lightweight in-browser parser) for the AST projection that drives
cards / hylograph.

This is the user's "cue/play, not keystroke" stance.

## Voice wrapper synthesis

Each armed cue gets a synthetic wrapper module. The wrappers are
trivial — one declaration each:

```purescript
module CalypsoVoice.Qd1 where
import CalypsoSession (qd1A)
armed = qd1A
```

Wrapper module naming: `CalypsoVoice.<TitleCase tvoice>`. E.g.
`CalypsoVoice.Qd1`, `CalypsoVoice.CipPitch`. The tvoice → module
name mapping is mechanical: take the binding name from
`armed.destination` at the value level (via reflection on the
`Cue`'s destination field), title-case it.

Multiple cues can target the same tvoice (`qd1A`, `qd1B`, `qd1C`).
Only one is armed at a time. The wrapper always points to the
currently-armed cue; switching cues rewrites the wrapper.

The wrapper module's BEAM name (e.g. `calypso_voice_qd1@ps`) is the
**stable** identity that purerl-tidal's voice gen_server hot-loads
from. Voice "qd1" always reads `calypso_voice_qd1@ps:armed/0`,
regardless of which underlying cue is currently armed.

## BEAM runtime & hot-load

### Voice supervisor tree

Each binding (qd1, qd2, cipPitch, …) corresponds to one
gen_server registered under its binding name. Spawned at session
load from the baseline's binding declarations. Existing
purerl-tidal infrastructure; per-voice refactor (project memory
`project_per_voice_refactor`) is the substrate.

### Hot-load message

```
{:swap_pattern, ModuleAtom}
```

The gen_server captures a fun: `fun ModuleAtom:armed/0` and uses
that for pattern queries. On `:swap_pattern`, it captures a new
fun from the same module name (post-`code:load_binary`).

Old fun keeps running until the next cycle boundary. New fun
takes effect on the next query. No race condition because
gen_server is single-threaded; the swap is atomic with respect to
pattern queries.

### Baseline init

The baseline module, when loaded, needs to execute its effects —
register devices, spawn voices, install polysignals, seed
controls/tags. PureScript declarations are pure; effects are
explicit.

Two design choices:

**Option A: declarations are values; runtime walks them.**

```purescript
-- in CalypsoSession.purs
session :: Session
session = Session
  { devices: [fh2, fh2qd, live, es9]
  , bindings: [Bind qd1, Bind qd2, Bind cipPitch, …]
  , polysignals: [banks]
  , controls: [Ctrl bassAmp, Ctrl filterMod]
  , tags: [Tag fillTag]
  , cues: [Cue qd1A, Cue qd1B, …]   -- not "armed"; just listed
  }
```

The Erlang runtime, on baseline load, calls
`calypso_session@ps:session/0` to get the Session value, walks it,
performs all the effectful work.

**Option B: declarations register themselves via FFI.**

Each `midiDevice "FH-2"` call invokes an Erlang FFI function that
registers the device immediately. PureScript declarations have
`unsafePerformEffect` under the hood. Cleaner from the user's view
(no `session` value to assemble) but smelly from a PureScript-style
point of view.

**Decision: Option A.** The user writes pure declarations; the
Erlang runtime walks the Session value. This matches PureScript
idiom and gives us a single point of truth for "what's in this
session."

The Session value is constructed by the user via a top-level
`session :: Session` declaration. We provide helpers:

```purescript
defSession :: SessionBuilder -> Session
defSession b = b emptySession

devices    :: Array Device     -> SessionBuilder
bindings   :: Array Binding    -> SessionBuilder
cues       :: Array AnyCue     -> SessionBuilder
-- etc.
```

So a typical file ends with:

```purescript
session :: Session
session = defSession $
  devices    [fh2, fh2qd, live, es9] <>
  bindings   [bind qd1, bind qd2, bind cipPitch] <>
  controls   [bassAmp, filterMod] <>
  cues       [cue qd1A, cue qd1B, cue cipPitchA]
```

(Or auto-discovery if PureScript metaprogramming permits — `<Generic>`
or row-types — but the explicit form is safe and clear for v1.)

## Frontend changes

### Composition pane

- Switch CodeMirror language from `tiderl-haskellish` to
  `purescript` (existing CodeMirror PS mode, or a Tree-sitter
  PureScript grammar).
- Add a lightweight in-browser PS parser to extract the cue
  declarations (their names, mvoices, body text spans). Don't run
  typechecking — that's the daemon's job. Just structural parsing.
- The parser produces the projection that drives the cards view.

### Cards (Voice Cells)

Card == one cue declaration in the AST. The card's title is the
declaration name. The body text is the RHS as a string slice. The
mvoice is read from the declaration's type Symbol (or, if the user
omitted the type, from the declared `Cue mv` constructor on the
RHS — same info, just typed inline).

Card edit semantics unchanged from Model B: live edit goes into
`liveSource`; promote substitutes the RHS into the file source.

### Hylograph

Reads the parsed Session: voices from `bindings`, cue references
from `cues`. Animations from runtime state via WS push.

### Wire protocol changes

New messages:

```
SetSession (source :: String)             -- frontend → daemon
ArmCue     (name :: String)               -- frontend → daemon
FireBaseline                              -- frontend → daemon
CompileError (errors :: Array CompileError) -- daemon → frontend
SessionLoaded ()                          -- daemon → frontend, after baseline load
VoiceArmed (tvoice :: String)             -- daemon → frontend
```

The daemon owns the file on disk and the compile state; the frontend
just edits + fires.

Existing `Eval` / `BPM` / `SetControl` messages stay.

## Migration from Level 2

Level 2 sessions are valid `.tiderl` text but not valid PureScript.
We need an automatic migration.

### The shape of the migration

Level 2:
```
midi fh2 "FH-2"
midi fh2-qd "FH-2" lat 69
midi-note qd1 fh2-qd 14 60 100 50

section drums
qd1A = mini "x ~ ~ ~ x ~ x ~"
qd1B = every 8 rev (mini "x ~ x x x ~ ~ x")
```

Level 3 (target):
```purescript
module CalypsoSession where
import Calypso.Prelude

fh2 = midiDevice "FH-2"
fh2qd = midiDevice "FH-2" `withLat` 69
qd1 = midiNote fh2qd { ch: 14, note: 60, vel: 100, dur: 50 }

qd1A :: Cue "drums"
qd1A = on qd1 (mini "x ~ ~ ~ x ~ x ~")
qd1B :: Cue "drums"
qd1B = on qd1 (every 8 rev (mini "x ~ x x x ~ ~ x"))

session :: Session
session = defSession $ ...
```

A one-time `migrate-to-tiderl3` CLI tool reads a Level 2 file,
parses it with the existing Calypso.Composition.Parser, and emits
the Level 3 PS module. Idempotent: running on an already-Level-3
file is a no-op (detected via the `module` keyword).

### Coexistence

For one release cycle: both `.tiderl` (Level 2) and `.tiderl.purs`
files are loadable. New sessions are Level 3 by default. Old
sessions get migrated on first save. After one release: Level 2
support is dropped.

## Implementation phases

**Phase 1: `Calypso.Prelude` in purerl-tidal.**

- New module `src/Calypso/Prelude.purs` and supporting types.
- Reuse purerl-tidal's existing `Tidal.Pattern`, `Tidal.AST`,
  `Tidal.MiniNotation.parse` under the hood.
- Add the `Cue`, `Session`, `Binding` types.
- Add the smart constructors (`on`, `cue`, `defSession`, …).
- Unit tests for round-trip and type-correctness.

Deliverable: a hand-written `CalypsoSession.purs` that compiles
under purerl-tidal's spago workspace and produces working output.

**Phase 2: Wrapper synthesis + compile pipeline.**

- Build the Calypso daemon's `SessionBuilder` module that:
  - Writes `session/CalypsoSession.purs` from incoming source
  - Synthesises `session/Voices/*.purs` from armed-cue metadata
  - Orchestrates `purs compile && rm build.txt && purs-backend-erl --filter ...`
  - Content-hashes `.erl` outputs against the manifest
  - Erlc's the changed ones
  - Reads resulting .beam binaries
- Hand-write a test `CalypsoSession.purs` and verify end-to-end
  timing matches benchmark prediction.

Deliverable: a script that runs end-to-end from "user fires qd1A"
to "qd1's gen_server has new pattern" in under 1s.

**Phase 3: purerl-tidal hot-load wiring.**

- Adjust the per-voice gen_server to accept `{:swap_pattern, Module}`.
- Add daemon-side WS messages `LoadBaselineBeam` and `LoadVoiceBeam`.
- Voice gen_server captures fun-ref, swaps on cycle boundary.
- Baseline-load path: receives baseline .beam, calls its `session/0`,
  walks the Session value, performs registration effects.

Deliverable: an end-to-end live-coding session using only the new
path, side-by-side with the Level 2 path (still on main).

**Phase 4: Calypso frontend integration.**

- Switch composition-pane CodeMirror mode to PureScript.
- In-browser PS parser for AST projection.
- Update card view to consume the new AST shape.
- Wire `ArmCue` / `SetSession` messages.
- Compile-error display in the composition pane gutter.

Deliverable: A user can edit a `.tiderl` file in the composition
pane, fire a cue, and hear sound — all via the typeful path.

**Phase 5: Migration tool + Level 2 → Level 3.**

- Write the `migrate-to-tiderl3` CLI.
- Test on the existing rig setup files.
- Coexistence period: both formats loadable.

Deliverable: existing sessions migrate cleanly; one release cycle
of coexistence; then drop Level 2.

**Phase 6: Polish.**

- LSP integration in CodeMirror (cclsp wrapper for type errors,
  hover, completion).
- Compile-error reporting with line numbers in the composition
  pane.
- Cue type signature autocomplete.
- Hover docs for Calypso.Prelude functions.

Deliverable: editing `.tiderl` feels like editing PureScript in a
real IDE — completions, type info, errors inline.

## Open questions

1. **Where does Calypso.Prelude live?** Proposed: in
   `purerl-tidal/src/Calypso/Prelude.purs`. The daemon's session
   files are also under purerl-tidal's spago workspace. Calypso's
   own frontend/backend codebase doesn't need to import
   Calypso.Prelude — it just talks WS to the daemon. Confirm.

2. **mini-notation parsing — runtime or compile-time?** Today
   purerl-tidal parses at runtime. With typeful cues, `mini "x ~ ~"`
   is a PureScript function call producing a `Pattern`. The parsing
   happens at WHEN — at module load time? At cycle query time?

   Probably runtime (at first cycle query), matching today's
   behaviour. Compile-time parsing (a Template-Haskell-style
   approach) would catch typos but PureScript doesn't have that
   facility.

3. **Custom Symbols for tvoices vs the binding-value flow.**
   The handoff doc settled on tvoice-as-binding (value-level
   identity). But for the **wrapper module name**, we need to
   reflect the tvoice as a string. That happens at session-load
   time when the daemon walks the Session value and notes which
   bindings exist; the wrapper synthesis uses those strings. No
   type-level Symbol for tvoice required.

4. **What does `withLat` look like for the type system?** The
   handoff sketch has `qd1 = midiNote fh2qd 14 60 100 50` and
   `fh2qd = midiDevice "FH-2" \`withLat\` 69`. PureScript-y way:
   either a typeclass `class HasLat a where withLat :: a -> Int -> a`,
   or device-specific helpers. Either works; lean on the typeclass.

5. **Section headers in Level 3?** Level 2 has `section drums`.
   Level 3 has cues typed `Cue "drums"`. The card view groups by
   the Symbol. But does the composition pane need section comments
   for readability? Probably just `-- # Drums` as conventional
   PureScript comments. Calypso parses them as fold-region
   boundaries (same as Level 2).

6. **What about the `<-` set-control shorthand?** Level 2 has
   `bass-amp <- 0.85`. Level 3 just uses the typed `Control`
   declaration: `bassAmp = control 0.85`. The shorthand can't
   sensibly survive into PureScript syntax. The Level 3 form is
   one extra word but type-checked.

7. **Polysignal grammar in PureScript syntax** is the biggest
   ergonomic question. Level 2's `<>` continuation form is gone.
   Level 3 would have a record with array fields (sketched above).
   This is more verbose; needs careful design to keep it editable.
   Sub-design pass during phase 1.

8. **REPL-style ad-hoc evaluation.** Today users can fire one-off
   verb cells (`bpm 124`, `state`, `config foo`) without those
   being in the file. In Level 3, do those become PureScript
   expressions evaluated in the daemon's repl, or stay as Level 2
   wire-syntax verbs sent directly? Probably the latter — Level 3
   is about **declarative session content**; ad-hoc verbs are
   imperative and have a separate path.

## Risk register

| Risk                                       | Mitigation                            |
|--------------------------------------------|---------------------------------------|
| Polysignal record syntax is too verbose    | Sub-design in phase 1; can ship Level 2 polysignal block as comment-elided text alongside the typed form during transition |
| mini-notation runtime parsing is slow      | Existing purerl-tidal already does this; not a regression |
| Per-voice gen_server refactor incomplete   | Phase 3 depends on it; track via `project_per_voice_refactor` |
| spago build orchestration brittle          | Phase 2 isolates this; if blocked, fall back to running spago build full instead of --filter |
| CodeMirror PureScript mode rough           | Phase 4 might need custom highlighting; CodeMirror's PS mode is functional but not great |
| Migration tool misses edge cases           | Run on every existing session file; manual review before drop of Level 2 |

## Naming / Branch strategy

- **Calypso feature branch:** `typeful-cues` (off `main` at `c82e14e`).
- **purerl-tidal feature branch:** `typeful-cues` (off whatever's
  current main).
- Both branches developed in parallel; cross-repo dependencies
  managed via filesystem paths (already the case for spago).
- When both ready: merge purerl-tidal first (it's the substrate),
  then Calypso.

## Success criteria

When this lands on main:

1. A user can author a `.tiderl` session, fire a cue from a card,
   and hear sound — entirely via the typeful path.
2. End-to-end edit-to-running latency is ≤ 1s on the canonical
   rig setup (the benchmark predicts ~0.6s; allow margin).
3. Type errors in the .tiderl file surface in the composition pane
   gutter with line numbers.
4. Existing Level 2 sessions migrate without manual intervention.
5. Live coding a real performance (i.e., Andrew uses this for
   actual rig work) feels at least as good as Level 2 did.

## What this enables (looking forward)

- **LSP-quality editor**: autocomplete on `every`, `rev`, `fast`,
  binding names; type info on hover; rename refactoring.
- **Cross-checked controls**: `live bassAmp` doesn't compile if
  `bassAmp` isn't declared. Typo-resistant.
- **Composable abstraction**: users can write helper functions
  in the .tiderl, not just at-the-leaves cue bodies.
  ```purescript
  myKick :: Cue "drums"
  myKick = on qd1 (mini "x ~ ~ ~ x ~ x ~")

  doubleIt :: Cue "drums" -> Cue "drums"
  doubleIt c = c { body = fast 2.0 c.body }

  qd1A = doubleIt myKick
  ```
- **A path to Hylograph editing**: hylograph's graphical
  manipulations become real `Cue` value transformations, not
  text edits.
- **Tags-as-ADTs**: when stringly-typed tags hurt enough, we have
  a path to typed tag enums.
- **The polyfacetic REPL vision**: this is the substrate. Multiple
  vocabulary surfaces (mini-notation, polysignals, tag-driven
  branching) all live in one type-checked module.
