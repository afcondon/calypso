# Claude-pair evaluation — design ideas

Running log of design ideas surfacing while a second Claude drives
Atelier over the HTTP API. Kept separate from PLAN.md because these
are raw observations: some may contradict each other, some may be
abandoned after reflection. Review all at the end of the evaluation,
fold the surviving ones into PLAN.md.

(Originally captured while the tool was still called "PureScript
Playground." Renamed to Atelier 2026-04-18.)

**Primary artefact:** [CLAUDE-PAIR-EVAL-2026-04-18.md](./CLAUDE-PAIR-EVAL-2026-04-18.md)
— the evaluating Claude's write-up. This file here captures the
*live-observed* design ideas (raised by the human watching the browser
while the eval ran); the artefact file captures the *practitioner-POV*
ideas (raised by the Claude actually using the API).

## 2026-04-18

### Scratch mode vs Project mode

**Observation trigger:** first live Claude-pair session, with other
Claude working on a small self-contained data-viz project (world map
bubbles, slug `echo-foxtrot-zulu-lima`).

**Idea:** distinguish two top-level modes:

- **Scratch mode** (what we have today): single synthesized module +
  cells, starter dropdown, runtime is freely switchable across
  browser/node/purerl.
- **Project mode:** bind to a real PureScript project on disk.
  - "Pick and stick" a backend — runtime is locked by the project's
    spago workspace (you don't get to toggle browser/node/purerl
    against a project that only builds one target).
  - The **starter dropdown is replaced by a module selector** — either
    a list of the project's existing modules or a file picker rooted
    at the project's src/.
  - Presumably the Module column shows the selected project module
    (read from disk) and the Cells column lets you experiment against
    whatever scope that module exports.

**Relationship to existing deferred work:** overlaps with
"project-context binding (Phase 1)" in the compacted plan, which was
scoped to package-set binding only. This proposal goes further — not
just "use the project's dependencies" but "navigate the project's
modules as the primary surface."

**Open questions (to resolve on review):**

- In Project mode, is the Cells column cells-against-a-module, or
  does it become something closer to a REPL transcript?
- Does Project mode allow *editing* project modules and writing them
  back, or is it read-only + scratch-cells?
- How does the Claude-pair API distinguish project-mode writes from
  scratch-mode writes? (Different endpoints? Or a mode field on the
  session?)

### Session mutex needs bracket semantics + IDE-query timeout

**Observation trigger:** backend POSTs hung indefinitely mid-session.
GET remained fast (doesn't take the lock). Root cause: the shared
`purs ide server` subprocess got into a bad state where new `purs ide
client` queries would connect but never get a response. The
compile-time type-query step in `Ide.js` has no timeout, so
`compileNow` in `Session.withUpdate` never returned — `AVar.put`
never fired — mutex held forever — all subsequent writes queued
behind it.

Unwedged manually by killing the stuck ide server + client, which
the `on('exit')` handler in `Ide.js` correctly respawns. Session
state was preserved because we didn't restart the backend.

**Real fixes (deferred until after eval):**

1. `Ide.js`'s `clientCall` needs a timeout (e.g. 5s). On timeout,
   kill the subprocess and reject — the caller already has a
   try/catch that returns `[]`, so the compile completes with no
   inline types rather than wedging the whole session.
2. `Session.withUpdate` needs bracket/finally semantics so the
   `AVar.put` releases the lock even when `compileNow` throws or
   hangs indefinitely.
3. Possibly: health-check or ping the ide server periodically and
   respawn it proactively on unresponsiveness, rather than relying
   on individual query timeouts to surface the problem.

These are reliability fixes, not feature work; safe to land
whenever.

### Landed: records + nullary ADTs serialise structurally

Wire format now includes `{"$record":{...}}` for records (via
`RowToList` — automatic for any record type) and `{"$ctor":name,"args":[]}`
for nullary constructors (via a Show-output heuristic — bare
upper-case identifiers get treated as nullary ctors).

**Still `$raw` for now:** multi-arg user ADTs that don't have a
hand-written `ToPlaygroundValue` instance. `Maybe`, `Either`, and
`Tuple` are hand-written and structured. For other user ADTs, a
`Generic`-based fallback would complete the picture — but PureScript
instance chains don't fall through on constraint failure, so we'd
need either (a) a Generic instance ordered before Show that
constraint-fails for non-Generic types (requires verifying
instance-chain semantics empirically), or (b) an explicit escape
hatch like `fromGeneric` that users wire into a bespoke
`ToPlaygroundValue` instance. Worth revisiting if this shows up as
a real friction in evaluation.

## 2026-04-19

Reactions to PLAN.md after the rename and the Phases A–E framing
landed. None of these are commitments — they're sharpenings and
forward looks that surfaced in the post-eval design conversation.

### UI delivery — two independent knobs, not two modes

**Observation trigger:** thinking about how Atelier would scale to
larger projects + an editor-of-choice.

**Idea:** the UI is not "scratchpad mode vs project mode" as a
single switch — it's two *independent* choices:

- **Code source**: Atelier-owned module column (today's three-
  column layout) vs. editor-owned (sidecar — user's editor holds
  the source; Atelier shows two columns: cells + values/types).
- **Viz pane**: present vs. absent, driven by the active cell's
  declared representation kind (Phase B).

Four configurations including "sidecar + viz," which is probably
the ShapedSteer-adjacent sweet spot — user iterates on a data viz
in their editor; Atelier shows cell probes against the project +
a Hylograph render pane.

**Sidecar rough sketch**: backend watches project files on disk;
module column disappears from the UI; cells run in scope of
whichever module the user has focused. Eliminates the "module
column race against the human" problem entirely — human edits in
their editor, agent writes via the API, both reconciled by the
filesystem.

Open questions: does the sidecar talk LSP to the editor or just
file-watch? How does the agent know which module is "active"?
Do we keep the three-column standalone mode, or generalise to
"sidecar always on, standalone watches a tmpdir"?

### Cells ↔ ShapedSteer nodes correspondence

**Observation trigger:** mapping Atelier's evolution against
ShapedSteer's vision.

**Idea:** today's Atelier cell is the *degenerate case* of a
ShapedSteer node:

- Atelier cell: implicit scope (whatever the module exports),
  emits a value, no declared inputs.
- ShapedSteer node: declared typed inputs, declared typed output,
  scope = explicit input list.

Each phase adds explicitness: today, scope is implicit; Phase B,
output representation declared; ShapedSteer, inputs declared too.
The progression is continuous, not a leap. (PLAN.md Phase E
section sharpened to reflect this.)

### Representation tag = render contract AND wiring contract

**Observation trigger:** asking whether Phase B's representations
are just for rendering.

**Idea:** the representation tag does double duty:

- *Render contract*: the viz pane knows how to display
  `image/svg+xml`, `text/x-hats+json`, etc.
- *Wiring contract*: a future DAG cell consuming
  `text/x-bar-chart-data+json` plugs into anything producing it,
  *regardless of the underlying PureScript type*.

PureScript type is the cell's *internal* implementation;
representation tag is the *interchange* type. Two cells with
different PS types can both produce `text/x-graph+json` and be
DAG-compatible without sharing a typeclass.

Implication: Phase B isn't "add a viz pane" — it's introducing
the type system the ShapedSteer DAG (Phase E) will run on.
Probably wants a registered namespace
(`application/x-hylograph.bar-chart-data+json` or similar) plus
pluggable renderers + codecs per representation. (PLAN.md Phase B
section sharpened to reflect this.)

### `purs ide rebuild` as a Phase A perf lever

**Observation trigger:** VS Code's PureScript extension is snappy;
Atelier full-recompiles via `spago bundle` on every write.

**Idea:** `purs ide` already supports single-module incremental
rebuild via the `rebuild` command. We use it for type queries but
not for compilation. For module-only edits, `purs ide rebuild
Main.purs` skips the full bundle and just produces updated
externs + JS for the changed module.

Constraint: we still need a runnable JS bundle for the
Worker/Node executor, so a full bundle is required *eventually*.
But it could happen async, off the hot path — return types
immediately, update the value pane when the bundle is ready.
Splits the response: agent gets type feedback in <100ms, render
pane updates a beat later.

Belongs in Phase A as a perf option; pairs naturally with Phase D
(multi-module) where incremental matters more.

### Promotion paths as a first-class design principle

**Observation trigger:** thinking about what Atelier feeds into
when it stops being a scratchpad.

**Idea:** Atelier already conceptually has two promotion paths
but they're implicit. Worth elevating to design principle:

- **Cell → red/green test.** A cell `f 21 == 42` is a test
  assertion in disguise. The Phase A "promote cell → module
  function" affordance generalises to "promote cell → test in
  some target project's test/ tree."
- **Module → project source.** The Atelier module is scratch;
  once it's earned its place, it becomes a real module in some
  target project under `src/`.

Both promotions need a *target* — which project? Phase D's
project-context binding answers this. Once you're bound to a
project, "promote" has a destination.

Connects to the existing "Rapid development environment with
AI-mediated lift" framing in PLAN.md.

### Unison atomization — research note (not roadmap)

**Observation trigger:** broad design thinking about what makes
Atelier feel different.

**Idea (research, not roadmap):** Unison content-addresses every
definition by the hash of its normalised AST. No file imports —
named pointers to hashes. This makes replay deterministic, value
diffs trivial (other Claude wanted these), and naming churn-free
(rename ≠ propagation; hash is the ID, name is a label).

Atelier won't turn PureScript into Unison. But for export/import
(Phase A), value-diffs (other Claude's ask), and DAG node
addressing (ShapedSteer), treating cells as content-addressed by
their AST hash is worth keeping in mind. Cell-id today is
frontend-assigned; cell-id later could be hash-of-content + a
generational suffix for repeats.
