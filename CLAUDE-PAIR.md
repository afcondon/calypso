# Claude-pair API

*An experimental surface so a second Claude session can drive
Atelier alongside the human.*

This document is the brief another Claude should read when dropped
into a project where Atelier is running. It describes what Atelier
is, what it can do for you, and how to interact with it.

## What this is for

Atelier is a typed PureScript scratchpad framed as **a REPL for
agents with a window for humans**. Three-column browser UI (module
editor | cells | values+types gutter) backed by a local HTTP server
that drives the PureScript toolchain. The human's browser is a
transparent observation pane; you, the agent, are the primary
driver via HTTP. Both clients *can* write, but the expectation is
that you do most of the authoring and the human observes, steers,
vetoes — or sketches pseudo-signatures and intent that you realise.
Auto-compile reflects your changes live in their window.

Your value proposition: you can propose typed sketches, probe
behaviours, and answer questions with live witnesses instead of
text — and the human sees everything happen in a surface they're
already looking at.

(The codebase is still called `purescript-playground` on disk and
the PureScript namespace is `Playground.*` — those are historical;
the product is "Atelier.")

## Running assumptions

- Backend at `http://localhost:3050`, frontend at
  `http://localhost:3051`. The human's browser points at the
  frontend; you talk HTTP to the backend.
- Three runtime adapters are available (browser Worker, Node child,
  Purerl BEAM). The session carries a `runtime` field you should
  respect when proposing code.
- The Playground auto-compiles ~400ms after any edit. Every change
  you make via the API triggers a recompile; you get types, values,
  and errors back in the response.
- Session state is not persisted across server restarts. This is a
  workspace, not a database.

## Workflows you should reach for

1. **"Sketch an implementation."** Use `POST /session/module` to
   define a function; `POST /session/cells` to add probes that
   exercise it; read `/session` on the next turn to see types +
   results. Iterate without round-tripping through the human's
   attention.

2. **"What's the type of X?"** Use `POST /ide/type` with a name —
   faster than reasoning about the code, authoritative.

3. **"Find a function with this signature."** Use `POST /ide/search`
   with a type signature string — `purs ide` has the lookup; don't
   guess names.

4. **"Observe what the human is trying."** `GET /session` before
   answering a question. Cells they've added, errors they're hitting
   — all right there.

5. **"Propose a data model."** Write `data` decls via
   `POST /session/module`, add cells that construct values, read
   back the inferred types. The types make the model concrete.

6. **"Port a snippet."** Write it directly into the module editor.
   Iterate on compile errors without bothering the human. Hand off
   once it builds.

7. **"Explain a library function."** Add a cell with a canonical
   example. The human sees it evaluate. Beats a prose explanation.

## API

All endpoints serve JSON (`Content-Type: application/json`). CORS
is `*`. There is no auth — this is a local-only tool for now.

### Read

`GET /session` — current session snapshot. Returns:

```json
{
  "runtime": "browser" | "node" | "purerl",
  "module": { "source": "module Scratch where\n..." },
  "cells": [ { "id": "c1", "kind": "expr", "source": "..." }, ... ],
  "types":  [ { "id": "c1", "signature": "Int" }, ... ],
  "cellLines": [ { "id": "c1", "startLine": 18, "endLine": 18 }, ... ],
  "errors":   [ { "code": "...", "filename": "...", "position": {...}, "message": "..." }, ... ],
  "warnings": [ ... ],
  "js":     null | "<bundled JS>",
  "emits":  [ { "id": "c1", "value": "<JSON-encoded PlaygroundValue>" }, ... ],
  "runtimeLabel": "Browser (Web Worker)" | ...
}
```

Note: `GET /session` returns the last compiled state. It does NOT
force a recompile. To force a recompile, use `POST /session/compile`.

### Emit wire format

Each entry in `emits` is `{ id, value }` where `value` is a JSON **string** containing an encoded `PlaygroundValue`. The envelope is always a primitive, an array, or one of these tagged objects:

```
null
true/false
42 / 3.14
"hello"
[ <value>, ... ]
{ "$ctor": "Just",   "args": [ <value> ] }   // structured constructor
{ "$ctor": "Africa", "args": [] }            // nullary constructor
{ "$record": { "field1": <value>, ... } }    // record
{ "$raw":   "SomeShowOutput" }               // fallback — couldn't decompose
```

What gets what:

- **Scalars** (Int, Number, Boolean, String, Char, Unit) → primitive JSON.
- **Array, Maybe, Either, Tuple** → `PVArray` / `PVCtor`. These are hand-written instances.
- **Records** → `{ "$record": { ... } }`. Automatic via `RowToList` — no user work needed.
- **Nullary constructors** (e.g. `Africa`, `LT`, `None`) → `{ "$ctor": name, "args": [] }`. The runtime inspects the Show output; if it's a bare capitalised identifier it treats it as a nullary ctor.
- **Multi-arg user ADTs** without a hand-written `ToPlaygroundValue` instance → `{ "$raw": "..." }` (surface-syntax string). This is the one "still dumb" case — if you want structure, write or derive the instance. (A `Generic`-based fallback is planned.)

So an `emits` entry for a cell returning `Array { avgDensity :: Number, name :: String }` comes through as a parseable JSON tree you can walk field-by-field. Cell-composes-with-cell works because the runtime values do, and now the JSON surface agrees.

`GET /session/types` — narrower read. Returns just `{ "types": [ { "id": "c1", "signature": "Int" }, ... ] }` with no `js`, no `emits`, no module/cell source. Use this when you're iterating on types and don't want the full snapshot on every round-trip.

`POST /ide/type` — body `{ "query": "map" }` → `{ "hits": [ { "identifier", "moduleName", "typeSignature" }, ... ] }`. Useful for "what's the type of map?"

`POST /ide/complete` — same shape; returns prefix-completion candidates.

`POST /ide/search` — NEW. Body `{ "query": "Array a -> Maybe a" }` → `{ "hits": [...] }`. Finds functions by (approximate) type signature.

### Write — session shape

Every write triggers a recompile. The response body is the full new session snapshot (same shape as `GET /session`), so you can observe the outcome in one round-trip.

`POST /session/module` — replace the module source entirely. Body:
```json
{ "source": "module Scratch where\nimport Prelude\n\nfoo :: Int\nfoo = 42\n" }
```

`PATCH /session/module` — structured edit, no need to GET → string-replace → POST the whole body. Body must contain exactly one of:

```json
{ "addImport": "Data.Array" }
{ "addImport": { "module": "Data.Array", "alias": "Array" } }
{ "addImport": { "module": "Data.Number", "names": ["sqrt", "pi"] } }
{ "addImport": { "module": "Data.Array", "alias": "A", "names": ["length", "take"] } }
```
Inserts an import after the last existing import (or after the `module ... where` header if none). The string form becomes `import X`; the object form combines into `import M (names) as A` (either `alias` or `names` may be omitted). No-op if any form of that module is already imported — to change an existing import's alias or names, use `replaceRange`.

```json
{ "appendBody": "\nfoo :: Int\nfoo = 42\n" }
```
Appends to the end of the module source, with a separating newline if the source doesn't already end in one.

```json
{ "replaceRange": { "startLine": 6, "endLine": 7, "text": "foo :: Int\nfoo = 99" } }
```
Replaces lines `[startLine, endLine]` (1-indexed, inclusive) with `text`. `text` may itself contain newlines (multi-line replacement). Out-of-bounds ranges return `BadRequest` in the response's `errors` field without modifying state.

`POST /session/cells` — append a cell. Body:
```json
{ "source": "foo + 1", "kind": "expr" }
```
Returns the new session including the added cell's id.

`PATCH /session/cells/:id` — edit a cell. Body: partial record, e.g.:
```json
{ "source": "foo * 2" }
{ "kind": "let" }
{ "source": "xs = [1,2,3]", "kind": "let" }
```

`DELETE /session/cells/:id` — remove a cell.

`POST /session/runtime` — switch adapter. Body `{ "runtime": "node" }`.

`POST /session/compile` — force a recompile with the current state. Useful after a runtime switch or if you just want fresh types.

### Snapshots — export / import

`POST /session/export` — returns a minimal session descriptor suitable for re-importing:
```json
{
  "runtime": "browser",
  "module": { "source": "module Scratch where\n..." },
  "cells":  [ { "source": "foo + 1", "kind": "expr" }, ... ]
}
```
No `js`, no `types`, no `emits` — just the authoring shape. Use this to checkpoint a session before a risky edit, or to capture a state you want to replay later.

`POST /session/import` — accepts the same descriptor and **replaces the entire session** with it. Body shape:
```json
{
  "runtime": "browser",
  "module": { "source": "..." },
  "cells":  [ { "source": "...", "kind": "expr" }, ... ]
}
```
One recompile, one response — the full new snapshot. Useful for seeding a starter state, rolling back, or priming a session with a prepared dataset as a PureScript literal.

### Write — dry-run / preview

`?preview=true` on a write endpoint evaluates the write against the current session and returns what the compile result would be, but **does not apply** the change (no persisted state mutation, no broadcast). Supported on:

- `POST /session/module?preview=true` — preview a full module replacement
- `PATCH /session/module?preview=true` — preview a structured patch
- `POST /session/cells?preview=true` — preview appending a new cell
- `PATCH /session/cells/:id?preview=true` — preview a cell edit
- `DELETE /session/cells/:id?preview=true` — preview removing a cell

Use previews to validate a sketch before disturbing the human's editor. They're also free of the conch (see below) so you can probe even while someone else is authoring.

### Push — live updates via WebSocket

The frontend subscribes to a WebSocket at `ws://<host>:3050/session/ws`. Every accepted mutation (your write or the human's) fans out a snapshot to all subscribers *except* the current conch holder — they already have the state they just wrote, and excluding them prevents their in-flight typing from getting clobbered by its own echo. Updates arrive in the browser within tens of milliseconds, not a poll tick.

#### Frame types

Server → client:

- `Welcome` — fires once per connection, immediately after handshake. Carries your assigned `SubscriberId` (needed for HTTP writes), the current conch state, and the current session snapshot. Treat this as initial hydration.

  ```json
  { "type": "welcome",
    "yourId": "sub-abc…",
    "conch":  { "holder": "sub-xyz…" | null, "lastActivityAt": 1776... },
    "snapshot": { /* full CompileResponse */ } }
  ```

- `Snapshot` — fires after every mutating write the server accepts. Same shape as `GET /session`'s body.

  ```json
  { "type": "snapshot",
    "conch":  { "holder": "...", "lastActivityAt": ... },
    "snapshot": { /* CompileResponse */ } }
  ```

- `ConchUpdate` — pure conch-state transition (someone took it, yielded it, was kicked by `force-conch`, or disconnected). No snapshot.

  ```json
  { "type": "conch",
    "conch": { "holder": "..." | null, "lastActivityAt": ... } }
  ```

Client → server:

- `{ "type": "request-conch" }` — ask for write permission. Granted immediately if nobody holds it; silently denied otherwise (no explicit reply — read the next `ConchUpdate` and see whether you became the holder).
- `{ "type": "yield-conch" }` — release a conch you're holding.
- `{ "type": "force-conch" }` — take the conch from a holder who has been idle past the server's threshold (60s by default). No-op otherwise.
- `{ "type": "heartbeat" }` — touch `lastActivityAt` so you're not eligible for `force-conch` during a long thinking pause. **Either a WS `heartbeat` or any accepted HTTP write resets the 60s idle window** — whichever reaches the server first restarts the timer. If you have active HTTP writes in flight you don't also need to send `heartbeat`; it's only needed during long pauses with no writes.

### Authorisation — the conch + `X-Atelier-Subscriber-Id`

Mutating HTTP endpoints (`POST /session/compile`, `POST /session/module`, `PATCH /session/module`, `POST /session/cells`, `PATCH /session/cells/:id`, `DELETE /session/cells/:id`, `POST /session/runtime`, `POST /session/import`) now require the conch.

On every write include the header:

```
X-Atelier-Subscriber-Id: <your SubscriberId from the Welcome frame>
```

If you're not the holder (or nobody is), the server replies 409 with:

```json
{ "error": "conch-held", "holder": "sub-xyz…" | null, "lastActivityAt": ... }
```

The fix is to send `request-conch` over your WS and wait for a `ConchUpdate` where `holder == yourId`, then retry the HTTP write.

**Reads and previews don't need the conch.** `GET /session`, `GET /session/types`, `GET /session/export`, `?preview=true` variants of any write endpoint (module + cell), and `/ide/*` queries all stay open to any subscriber — you can explore freely in Observe mode without taking the conch.

### Minimal agent loop

```
1. Open WS to ws://…:3050/session/ws.
2. On Welcome: store yourId + conch.
3. Send request-conch. Wait for a ConchUpdate with holder == yourId.
4. Issue HTTP writes with X-Atelier-Subscriber-Id: <yourId>.
5. Listen for Snapshot frames while you work — that's how the human
   and any other viewers see your writes.
6. When you're done with a burst, send yield-conch so the human
   (or another agent) can take over without waiting for the 60s
   idle timeout.
```

## Etiquette

- **The conch is how you negotiate writes.** The browser UI has a three-state indicator: "● You have the conch" (human is authoring; their edits are flowing), "○ Unclaimed" (nobody holds it — take it if you want to write), "○ Observing" (someone else holds it — request it or, if they've been idle >60s, force-take). The same rules apply to you: request before writing, yield when you pause, prefer polite request over force except when the holder has clearly walked away.
- **When the human is holding the conch, don't request it reflexively.** Wait for them to yield, or at least explain what you're about to write and ask them to hand off.
- **`?preview=true` is free of the conch.** Any amount of preview probing is fair game even while someone else is authoring — it's the low-friction way to try an edit on the side.
- **Don't thrash the module editor while the human is typing there.** Even when you hold the conch, a large rewrite mid-keystroke is rude. Prefer `?preview=true` first, or tell the human what you're about to do.
- **Prefer adding cells over editing the module.** Cells are cheap experiments; the module is their codebase-in-miniature.
- **If the human has set a runtime (especially Purerl), stay in its package set.** Don't add an `import Effect.Aff` to a Purerl module — it won't compile.
- **Errors are signal, not failure.** Your write endpoint can produce a response with errors; the human sees them on the squiggle line. If your proposal fails to compile, read the error and iterate, don't just post again.

## Caveats this document won't catch

- The Playground hasn't been run against a large real project yet. Package-set binding is designed but not yet shipped. Full-project binding (cells importing user modules) is further out.
- `purs ide` is a subprocess of the backend; the first type query after backend boot has a ~2s warm-up. Subsequent queries are ~50ms.
- The `js` field in a session snapshot is large (kilobytes) for a non-trivial compile. If you're round-tripping state a lot, use `GET /session/types` for the narrower read.
- **The render column paints per-cell, not per-session.** Every expr-cell has its own render surface aligned to its row. If two cells emit renderable values (say c3 emits an SVG string and c5 emits a `ForceRender`), both paint simultaneously — there is no arbitration, no "which cell wins". Render contracts today: a `String` starting with `<svg` → `innerHTML` of the row; a `Playground.Runtime.ForceRender` value → animated d3-force simulation (see below); anything else → the row stays blank (the value still appears in the values column and its type in the gutter).
- `ForceRender` takes an explicit `forces :: Array AtelierForceSpec` — the simulation has no implicit defaults. Declare each force you want:

  ```purescript
  import Playground.Runtime (ForceRender(..), AtelierForceSpec(..))

  demo = ForceRender
    { nodes:  [ { id: "a", radius: 8.0, fill: "#c74e4e", label: "A" }, ... ]
    , links:  [ { source: "a", target: "b" }, ... ]
    , width:  800.0
    , height: 800.0
    , forces:
        [ ManyBody  { name: "charge",    strength: -30.0 }
        , Collide   { name: "collision", radius: 10.0, strength: 0.7 }
        , Link      { name: "links",     distance: 40.0, strength: 0.4 }
        , Center    { name: "centre",    x: 400.0, y: 400.0 }
        , PositionX { name: "fx",        x: 400.0, strength: 0.05 }
        , PositionY { name: "fy",        y: 400.0, strength: 0.05 }
        ]
    }
  ```

  Forces available in v1: `ManyBody`, `Collide`, `Link`, `Center`, `PositionX`, `PositionY`. Each carries a `name` (for disambiguation) plus its own parameters. Omit a force family if you don't want it — an empty `forces: []` means the simulation runs without any force pulling the nodes, so they stay put.

- Multiple independent render panels per cell (e.g. side-by-side comparisons, HATS-driven Hylograph-libs rendering) are not shipped yet.

## The evaluation the human and I are trying to run

A fresh Claude session should be given a PureScript project and this document, and asked to do real work — read the human's intent, propose sketches, verify types, hand off to them. We want to know:

- Which of the 7 workflows above actually helped? Which didn't?
- What felt natural? What felt clunky?
- What couldn't you do that you wanted to?
- What would you add to this API after a session?

Report back to the human. That's the feedback loop.
