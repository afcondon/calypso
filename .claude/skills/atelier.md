---
name: atelier
description: Compile, type-check, or evaluate a PureScript expression without setting up a project — POST a snippet to the local Atelier server and get back the value or the compile errors. Use when you want to know what a PureScript expression evaluates to, whether a snippet type-checks, what error a piece of code produces, or how a library function behaves.
---

# Atelier — PureScript eval-as-a-service

Atelier is a local PureScript scratchpad running as an HTTP API on
this machine. It holds a pre-built spago workspace, a `purs ide`
sidecar, and bundle+run adapters. The **`/eval` endpoint** lets you
hand it a PureScript expression and get back the value (or the
compile errors) without creating a project, writing `spago.yaml`, or
waiting for a cold build. First call is sub-second; the registry
package set is already compiled.

**Use this skill when:**
- Someone asks what a PureScript expression evaluates to.
- You want to check whether a snippet type-checks before committing to it.
- You need to see the exact compiler error for a piece of code.
- You want to try a library function — `Data.Array.sortBy`, `Data.Map.fromFoldable`, etc. — without opening an editor.

## Where it runs

- **API base URL**: `http://localhost:3050`
- **Frontend (optional, for humans)**: `http://localhost:3051`
- **Source**: `~/work/afc-work/purescript-playground/`

Health check before your first call:

```
curl -s http://localhost:3050/health
# → "ok"
```

If it isn't responding, start it:

```
cd ~/work/afc-work/purescript-playground && make start
```

## `POST /eval` — the primary endpoint

Request body:

```json
{
  "source":  "<a PureScript expression>",
  "imports": ["Data.Array as Array", "Data.Maybe (Maybe(..))"]
}
```

- `source` is a **single expression**, not a module, not a statement.
  `1 + 2`, `Array.length xs`, `{ x: 1 }`. No `let`, no `where`, no `module` header.
- `imports` (optional, defaults to `[]`) is an array of strings spliced
  verbatim into the module as `import <string>` lines. Write full import
  specs — `"Data.Array as Array"`, `"Data.Maybe (Maybe(..))"`, or a bare
  `"Prelude"` (Prelude is imported for you already). One entry per
  import line.
- No query parameters for the usual case. (Advanced: `?workspace=<id>`
  runs the expression in the context of another workspace's module
  state — see "Workspaces" below. Almost no agent use cases need this.)

**`Prelude`, `Data.Array as Array`, `Data.Maybe (Maybe(..))`, `Data.Either (Either(..))`, `Data.Tuple (Tuple(..))`, `Effect`, `Effect.Aff`** are auto-imported by the synthesis layer — you can use `Array.length`, `Just`, `Right`, `Tuple` without declaring imports. Anything else you need, add to `imports`.

Response body:

```json
{
  "value":    <Json — see "Value encoding" below, or absent>,
  "errors":   [<CompileError>, ...],
  "warnings": [<CompileError>, ...]
}
```

A successful eval has `errors: []` and a `value` field. A failed
compile has `value: null` (or absent) and one or more entries in
`errors`. `warnings` are advisory — ImplicitImport / UnusedImport /
etc. from upstream libraries.

`CompileError` shape:

```json
{
  "code":     "TypesDoNotUnify" | "UnknownName" | "Transport" | ...,
  "message":  "<human-readable text, usually multi-line>",
  "filename": "<relative path or null>",
  "position": { "startLine": N, "startColumn": N, "endLine": N, "endColumn": N } | null
}
```

### Worked examples

```
# Simple arithmetic.
curl -s -X POST http://localhost:3050/eval \
  -H 'Content-Type: application/json' \
  -d '{"source":"1 + 2"}'
# → {"value":3,"errors":[],"warnings":[]}

# A library function with an explicit import.
curl -s -X POST http://localhost:3050/eval \
  -H 'Content-Type: application/json' \
  -d '{"source":"Array.sortBy (\\a b -> compare b a) [3,1,4,1,5,9,2,6]",
       "imports":["Data.Array as Array"]}'
# → {"value":[9,6,5,4,3,2,1,1],"errors":[],"warnings":[]}

# Intentional type error — you get the compiler's exact message.
curl -s -X POST http://localhost:3050/eval \
  -H 'Content-Type: application/json' \
  -d '{"source":"1 + \"hello\""}'
# → {"value":null,"errors":[{"code":"TypesDoNotUnify",
#                            "message":"Could not match type String with type Int ...",
#                            "filename":"runtime-workspace/workspaces/eval-scratch/src/Main.purs",
#                            "position":{"startLine":17,...}}],
#     "warnings":[]}
```

### Value encoding

Values are emitted via the Atelier runtime's `ToPlaygroundValue`
class. The JSON shape:

| PureScript source       | JSON value                                  |
|-------------------------|---------------------------------------------|
| `Int`, `Number`         | `3`, `3.14`                                 |
| `Boolean`               | `true` / `false`                            |
| `String`                | `"..."`                                     |
| `Array a`               | `[...]`                                     |
| Record `{x: 1, y: "a"}` | `{"$record": {"x": 1, "y": "a"}}`           |
| ADT ctor `Just 42`      | `{"$ctor": "Just", "args": [42]}`           |
| Unsupported type        | `null` (and an error in `errors` telling you why) |

For ADTs to render, the constructor has to be in scope — either
imported (e.g. `Data.Maybe (Maybe(..))`) or auto-imported. If the
expression's type doesn't have a `ToPlaygroundValue` instance you'll
see a `NoInstanceFound` error rather than a silent failure.

### What `/eval` *doesn't* do (yet)

- **No type field in the response.** The `purs ide` sidecar currently
  runs against the repo root's `output/` and can't see the per-
  workspace externs the eval-scratch compile produces, so surfacing a
  type would be unreliable. If you need the type, eyeball the
  expression or bounce the result off Claude reasoning. A future
  phase will fix this.
- **No state across calls.** Every `/eval` replaces the eval-scratch
  module and cells entirely. You cannot define a helper in one call
  and use it in the next. For multi-step exploration, either stuff
  everything into `source` (use a `let ... in ...`) or use the
  workspace API below.
- **Node runtime only.** Emits are captured server-side. If you ask
  for something that expects a DOM, it won't run.
- **Single expression per call**, so no `do`-block orchestration
  unless you wrap it.

## Workspaces — only when you need state

Skip this section unless `/eval` on its own isn't enough.

Each Atelier workspace is an isolated spago package with its own
`Playground.User` module. Lifecycle:

```
GET    /workspaces                → { "workspaces": ["main", "eval-scratch", ...] }
POST   /workspaces                → create, body: { "id": "my-scratch" }
DELETE /workspaces/<id>           → remove (main and eval-scratch are reserved)
```

Any `/eval` or `/session/*` endpoint accepts `?workspace=<id>` to
target a specific workspace; without the param, reads go to `main`
and `/eval` goes to `eval-scratch`. `main` is the human's live
session — **don't `POST /session/*` against it** without holding the
conch (see below); you'll clobber or race with whatever the person
at the browser tab is doing.

Typical agent pattern: **create a short-lived scratch, eval against
it, delete.**

```
curl -s -X POST localhost:3050/workspaces -d '{"id":"my-probe"}' -H 'Content-Type: application/json'
curl -s -X POST "localhost:3050/eval?workspace=my-probe" \
  -H 'Content-Type: application/json' \
  -d '{"source":"...","imports":[...]}'
curl -s -X DELETE localhost:3050/workspaces/my-probe
```

Workspace ids must match `[A-Za-z0-9_-]+`. First compile in a fresh
workspace takes a few seconds (the registry package set has to be
copied into its `output/`); subsequent compiles are sub-second.

## `/session/*` — only for driving the human's tab

Atelier's browser UI talks to `/session/module`, `/session/cells`,
`/session/compile`, etc. These **mutate** the session state and
broadcast snapshots to connected browser tabs. An agent almost never
wants to write here — use `/eval` instead.

If you genuinely need to write to a session (e.g. to seed the
human's tab with some content), two options:

1. **Read-only preview mode.** Add `?preview=true` to any
   `/session/module` or `/session/cells` endpoint. The server
   compiles against the proposed change but does **not** persist it or
   broadcast it. No conch needed. Useful for "what would this look
   like without touching state?"

2. **The conch protocol.** `/session/*` mutating writes require the
   caller to hold the conch — a single-writer token the server grants
   over WebSocket. Full dance: open WS to `/session/ws` → receive
   `{type:"welcome", yourId:"..."}` → send
   `{type:"request-conch"}` → wait for
   `{type:"conch", conch:{holder:"<yourId>"}}` → POST with
   `X-Atelier-Subscriber-Id: <yourId>` header → send
   `{type:"yield-conch"}` when done. **Don't take the conch
   out from under a live tab** — a human is usually holding it. If
   you need this, ask first.

A working reference implementation of the conch dance in Node is
kept at `/tmp/import-snapshot.js` in fresh sessions; adapt from
there.

## Common errors & their meanings

- **`code:"Transport"`** — the spago build itself failed (network
  issue, corrupted output dir, etc.). Message contains raw spago
  stderr. Usually transient; retry once, then investigate.
- **`code:"TypesDoNotUnify"`** — standard PureScript type error.
  Position points into `runtime-workspace/workspaces/<id>/src/Main.purs`;
  the cell expression is on the line with `cell_eval = ...`.
- **`code:"NoInstanceFound"` mentioning `ToPlaygroundValue`** — your
  expression has a type Atelier doesn't know how to serialise.
  Usually means you returned a function, an `Effect a`, an `Aff a`
  whose `a` isn't serialisable, or some other opaque type. Surface
  the error and reconsider what the caller actually wants to see.
- **`code:"UnknownName"`** — missing import. Add it to `imports` in
  the request.
- **Error filename `"Playground.User.purs"` at line 3 mentioning
  `Prelude`** — safe to ignore; it's an auto-import hygiene warning
  for the synthesised module, not the user's code.

## Don'ts

- **Don't hit `/session/*` mutating endpoints against `main`.**
  That's the human's workspace. Use `/eval` against `eval-scratch`
  (the default) or your own scratch.
- **Don't rely on `types` in any response.** It's populated
  best-effort from `purs ide` and is empty for non-`main`
  workspaces. Today, trust `errors` and `value`; ignore `types`.
- **Don't take the conch without asking.** It's a human-interactive
  token. If a human is driving a tab, they're holding it.

(Restarting the server is fine — session state is persisted to
`<workspaceDir>/atelier-session.json` on every mutation and loaded
back on boot, so `main`'s content survives a restart.)

## Phase status (as of 2026-04-21)

Shipped: `/eval`, multi-workspace `?workspace=<id>`, workspace CRUD,
node-runtime emit capture. Not yet shipped: server-side types in
`/eval` response (purs-ide repointing), CLI wrappers, richer value
encoding for common library types (Map, Set, NonEmpty). Report
friction — this is exactly the kind of feedback the backend needs to
evolve.
