# Atelier vs Calypso — two surfaces, two models

A short reference for the design conversation around ShapedSteer's
"Grand Unified Theory."  Calypso started as a fork of Atelier (the
PureScript Playground); after roughly a dozen surgical commits the two
have diverged enough to be useful as **paired design probes**.  Probing
multiple specific environments against each other is cheaper than
trying to derive the unified surface from first principles.

## Side-by-side

| Axis                      | Atelier                                          | Calypso                                                |
|---------------------------|--------------------------------------------------|--------------------------------------------------------|
| **What's the artifact?**  | Compiled JS + typed values                       | A running audio system (purerl-tidal daemon state)     |
| **Where does eval live?** | Inside the app (Web Worker / Node child process) | External long-running daemon over a WebSocket          |
| **Compile step?**         | Yes (trypurescript, full PS toolchain)           | None — source goes verbatim to the daemon              |
| **Type system?**          | Rich, with hover/in-scope/inferred sigs          | Absent                                                 |
| **Eval trigger?**         | Auto-debounced on every keystroke                | Explicit fire (Mod-Enter); typing only persists state  |
| **Cell semantics?**       | Synthesised into a Main.purs alongside module    | Independent statements fired one at a time             |
| **Module/composition?**   | Source of truth for compile                      | Durable scaffolding (config + score) for ephemeral cells |
| **Value rendering?**      | `PlaygroundValue` ADT → ValueView Halogen        | Reply text from the daemon; pattern viz later          |
| **IDE features?**         | purs-ide hover types, completion, search         | None                                                   |
| **Multi-session?**        | `/workspaces` partitioning                       | Single session                                         |
| **Collaboration?**        | Conch — exclusive single writer                  | Pen — single approver, anyone (incl. AI) proposes      |
| **Persistence?**          | calypso-session.json per workspace               | calypso-session.json + `~/.calypso/favorites/`         |

## Axes that drop out

Reading down the table, the differences group into a smaller number
of design axes that a unified engine would have to parameterise over:

1. **Eval locus.**  In-app sandbox vs external runtime.  Spreadsheets
   evaluate in-app; build systems shell out; live-coding drives a
   stateful daemon.  The locus determines what "value" means and
   whether it round-trips structurally or only as text.

2. **Eval trigger.**  Auto-on-edit vs explicit fire vs periodic.
   Auto matches "the artifact is the result of pure functions on
   inputs" (spreadsheet, viz tool).  Explicit matches "the artifact
   is the running state of a system" (live-coding, build).
   Periodic is the third common case (dashboards, watch-mode tests).

3. **Durable vs ephemeral layers.**  Calypso's composition pane
   carries `-- @scale` and device bindings — the durable scaffolding
   that *all* ephemeral cells run against.  Atelier doesn't separate;
   the module *is* the cells' substrate but it's also being recompiled
   each keystroke.  Spreadsheets blend the two into a single grid;
   notebooks have an implicit "kernel state = durable, cell output =
   ephemeral" split that the UI rarely surfaces well.

4. **Collaboration model.**  Single-writer with turn-passing (conch),
   single-approver with open proposers (pen), free-for-all with CRDT
   merge, branch-and-merge (git-shaped).  The choice depends on the
   blast radius of an edit: live audio wants tighter gates than a
   collaborative spreadsheet does.

5. **Value space.**  Typed structured values, untyped JSON, plain
   text, side-effects-only.  Drives everything about how results
   render and whether one cell can consume another's output.

6. **Authorship metadata.**  Atelier had one author (the human at the
   keyboard).  Calypso's pen+proposals model makes "who wrote this
   line" a first-class concern, with implications for trust tiers,
   audit, and replay.  An engine that treats authors as anonymous
   has thrown information away.

## Implication for ShapedSteer

A unified engine probably wants to make these axes *configurable per
node-kind* rather than picking one set globally.  A spreadsheet sheet
and a live-coding cell aren't "the same thing with different render
templates" — they're different choices on at least axes 1, 2, and 5.
Trying to flatten them onto one set of defaults is what makes
existing notebook tools feel awkward when used outside their home
domain.

The minimum viable factoring (subject to revision):

- A node has a **kind** (spreadsheet-cell, build-target,
  livecoding-fire-line, viz-render, …).
- Kind selects defaults for eval-locus, eval-trigger, value-space.
- A document is a **graph of nodes of mixed kinds**.  This is where
  ShapedSteer's "typed DAG workbench" framing earns its keep — the
  edges are the integration points between kinds.
- Cross-kind edges force the question "what can a livecoding cell
  receive from a spreadsheet cell?" — and the answer probably
  involves a small number of kind-pair adapters rather than a
  universal value type.

## What's worth doing next

More probes before generalising.  Candidates:

- A spreadsheet-shaped probe (auto-eval, structured values,
  formula-bar editing).
- A build-system probe (DAG + cached outputs + explicit fire).
- A data-viz probe (pure transforms over tables, render is the
  output).

Each one will surface another axis or sharpen one of the existing
ones.  The Grand Unified Theory works better when assembled from
six honest probes than designed from three.
