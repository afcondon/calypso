# Calypso — frontend wiring (next session brief)

This is a hand-off document for the next pair-evaluation session. The
server-side surgery is done; the frontend still believes it's Atelier
and needs to be turned around to match the Tidal model.

## Where we are

Eight commits, server end-to-end working. `make build` is clean.
`node server/run.js` boots on :3060 and proxies cell text to a
running purerl-tidal at `ws://localhost:3012/ws`.

Quickest end-to-end probe (with purerl-tidal running):

```
curl -s -X POST http://localhost:3060/eval \
  -H 'Content-Type: application/json' \
  -d '{"source":"hush","imports":[]}'
# → {"errors":[],"value":"OK: hush","warnings":[]}
```

The server's `/session` returns the new Tidal-shaped initial state —
a comment header with `-- @scale` and `-- @progression` directives,
and a `load rample / load qd / load laplace / load turnado` block
showing the canonical vocabulary load.

## What the frontend needs to become

A three-pane workshop, collapsible:

  ┌──────────────────┬──────────────────┬──────────────────┐
  │  composition     │  cells           │  hylograph       │
  │  (the .tidal     │  (live-runnable  │  (pattern        │
  │   module — the   │   expressions —  │   visualization, │
  │   bones of the   │   cmd-enter to   │   sourced from   │
  │   piece)         │   fire)          │   tilted-radio)  │
  └──────────────────┴──────────────────┴──────────────────┘
                          (sonic output is invisible — the rig)

The composition pane is "between config and score" — initially the
device bindings (which already exist as `purerl-tidal/setup/*.tidal`),
accreting scale / chord / melodic-line directives via `-- @` comments
that the typographic layer renders as proper set type.

Cells panel is conventional CodeMirror cells. Cell-to-composition
graduation is just Cmd-C / Cmd-V for now — no fancy promote gesture.

## What to keep from Atelier's frontend

Verbatim:
- `Calypso.Frontend.Shell` — the panel layout machinery
- `Calypso.Frontend.CodeMirror.{purs,js}` — editor integration
- `Calypso.Frontend.Editor` — module pane editor
- `Calypso.Frontend.WsClient.{purs,js}` — conch sync
- `Calypso.Frontend.Starter` — the cells panel infrastructure

Mostly:
- `Calypso.Frontend.Main` — entrypoint; needs minor surgery for
  default panel visibility, app title, etc.

## What to strip

Aggressively:
- `Calypso.Frontend.SigilView.{purs,js}` — Sigil-rendered type
  tooltips. Calypso has no types to render. Delete the module;
  drop `sigil` from frontend/spago.yaml.
- `Calypso.Frontend.InScope` — types-in-scope panel. Same reason.
- `Calypso.Frontend.Worker.{purs,js}` — runs compiled JS in a Web
  Worker. Calypso doesn't compile or execute code in the browser;
  the runtime is purerl-tidal at the other end of the WebSocket.
- `Calypso.Frontend.Value` and `Calypso.Frontend.ValueView` — these
  render `PlaygroundValue` (structured PS values). Calypso's eval
  responses are simpler: just the daemon's reply text. Replace
  with a tiny `TidalCellResult` view that shows the OK/ERR status
  + the reply line. Comes back richer in step 5 with a parsed
  mini-notation AST.
- `Calypso.Frontend.RenderView.{purs,js}` — Hylograph library render
  surface for showcased PS values. Keep the rendering primitives
  but rewire to render Tidal patterns instead.
- `Calypso.Frontend.ForceSim` — d3-force visualization, Atelier-
  showcase content. Drop unless the hylograph pane needs it.
- `Calypso.Frontend.FormCell` — typed-record form-cell editor.
  Atelier-shaped, no Tidal use case.

## What's new

- A pattern-AST parser. Cell text → mini-notation AST (cycles, polys,
  rests, named tokens). Atelier had no parsing on the frontend; this
  is needed for the Hylograph pane and for hover affordances.
- A typographic layer for `-- @` directives extracted from the
  composition module. Two starter directives are seeded in the
  initial module; render `@scale`, `@progression`, etc. as proper
  set type alongside the comment-encoded source. Future directives:
  `@section`, `@melody`, `@tempo`, etc.
- The Hylograph pane itself. Render targets:
  1. The cell's parsed pattern as a cycle visualization (rings,
     durations, accent positions)
  2. Active patterns running on the daemon (live state)
  3. Eventually: tilted-radio's rendering primitives extended.

## Open design tensions (carrying forward)

- **Re-execution semantics**: when a session loads, do its cells
  re-run automatically? Atelier's PS Adapter would re-evaluate. For
  Tidal, re-running cells means firing them at the daemon — which
  starts patterns playing audibly. So probably no auto-rerun on
  session load; cells are inert until explicitly fired. (Confirmed
  with Andrew.)
- **State boundary**: the daemon's running pattern state is owned
  by purerl-tidal, not by Calypso's session. Loading a Calypso
  composition doesn't reset the daemon. `hush` is the manual reset.
- **Library scope**: deferred. Andrew is happy with Cmd-C/Cmd-V
  cell→composition graduation for now.

## Server-side housekeeping that wasn't done

- `Main.purs` is still 925-ish lines with all the Atelier routes
  present (`/session/compile`, `/session/types`, `/ide/*`,
  `/workspaces/*`). Many return empty/no-op responses. Slim to the
  Calypso-only set when convenient — drop the dead routes, retire
  the `WorkspaceMgr` and `Ide` stubs. Single-session model means
  the workspace-Map → single-store simplification.
- `CompileResponse` wire shape (in `shared/src/Calypso/Session.purs`)
  still has compile-shaped fields (`js`, `types`, `cellLines`,
  `emits`). Trim to a `TidalSnapshot` shape when the frontend's
  ready.
- `EvalRequest.imports` is meaningless for Tidal but still in the
  type. Drop when the wire-shape pass happens.

These don't block the frontend session — leave them for a focused
cleanup pass after the frontend is wired through. The current shape
has been verified end-to-end.

## Useful starting reads (in order)

1. `README.md` — quick orientation
2. This document — design state
3. `server/src/Calypso/Server/Adapter/PurerlTidalWS.purs` — the only
   live path; understand `sendCell` and `TidalReply`.
4. `server/src/Calypso/Server/Session.purs` (`evaluate`) — how cells
   reach the daemon
5. `frontend/src/Calypso/Frontend/Main.purs` and `Shell.purs` — start
   here for the frontend rewiring
6. Marginalia #192 (`romeo-sierra-yankee-uniform`) — the running
   notebook with per-commit state
