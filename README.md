# Atelier

*A REPL for agents, with a window for humans.*

A browser-based PureScript scratchpad modelled originally on Manuel
Chakravarty's *Haskell for Mac*, but reframed after its first live
Claude-pair evaluation as an HTTP-driven typed workspace where a
Claude session does the writing and the browser UI is the human's
observation pane. Module on the left, a column of cells in the
middle, gutter on the right with inferred type + rendered value per
cell — all updating live whether you type in the browser or POST
over HTTP.

See [`PLAN.md`](./PLAN.md) for the design, milestones, and phases A–E.
See [`CLAUDE-PAIR.md`](./CLAUDE-PAIR.md) for the brief another Claude
session reads before driving the tool.

Directory name and internal PureScript namespace (`Playground.*`) are
historical — "Atelier" is the product identity; the codebase rename
is deferred.

**Status:** Phase 1 + Phase 2 MVP working end-to-end. Auto-compiles,
per-cell types (rendered via [`purescript-sigil`](https://github.com/afcondon/purescript-sigil)),
per-cell values with structured records and constructors, inline
error squiggles, and three runtime adapters (browser Worker, Node
child-process, Purerl BEAM). Claude-pair HTTP API shipped 2026-04-18.
Unadvertised while it stabilises.

## Layout

```
frontend/           Halogen + CodeMirror 6 + Sigil
server/             HTTPurple backend (synthesis, spago driver, purs ide sidecar)
shared/             Request/response codecs used by both sides
runtime-workspace/  Modern spago workspace the backend compiles user code against
                    (src/Main.purs and src/Playground/User.purs are rewritten
                    on every /session/compile)
spago.yaml          Workspace root — pins registry 73.3.0
Makefile            Orchestration
```

## Prereqs

- `purs` 0.15.x (we use `0.15.15`) and modern `spago` (1.x) on `$PATH`.
- Node 18+ (we use 22.x).
- A local npm install for CodeMirror 6 + http-server (`npm install` at
  the repo root).

No external compile service. We drive `purs` / `spago` ourselves
against `runtime-workspace/`.

## Running locally

```
make bootstrap   # one-time: workspace build + frontend bundle
make start       # backend on :3050, frontend on :3051
                 # backend also spawns `purs ide server` on :4242
make stop        # kill all three
```

Then open http://localhost:3051.

On first `/session/compile` the backend lazy-spawns `purs ide server`
(it then serves every subsequent compile's type queries). The sidecar
dies when the backend dies — `lsof -i :4242` after `make stop` is
clean.

## What's done

- **M0** scaffolding, marginalia registrations, GitHub repo at
  `afcondon/purescript-playground`.
- **M1** runtime workspace (pinned `registry: 73.3.0`) + backend
  `/session/compile` + frontend POSTs a fixed payload.
- **M2** CodeMirror 6 editors (module + one per cell), cell data model
  with add/remove, real synthesis from request body (`Playground/User.purs`
  + synthesised `Main.purs`), debounced auto-compile.
- **M3** Web Worker execution via Blob-URL inline worker, per-cell
  emissions, timeout + termination, gutter renders `cellId = value`.
- **M4** `purs ide server` sidecar managed by the backend, type
  queries per cell, Sigil renders each inferred type in the gutter.
- **M5** dedicated bottom error panel (transport + compile),
  fading gutter while a compile is in flight, last-good values
  stay visible.

## What's deferred

- Inline error attribution (errors mapped back to originating cell /
  line) — Phase 2.
- Richer value rendering for records, arrays-of-records, Maybe/Either
  via Sigil — Phase 2.
- URL-shareable state, multi-module, file tree, persistence —
  Phase 3.
- Claude panel as a fourth column — Phase 4.
- Upstream trypurescript modernisation PR — optional follow-up.
