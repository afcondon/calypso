# Claude-pair evaluation — 2026-04-18

First live evaluation of the Claude-pair API (CLAUDE-PAIR.md). A
second Claude session was pointed at a small self-contained data-viz
project (world map bubbles — country/continent bubble pack, marginalia
slug `echo-foxtrot-zulu-lima`), given the CLAUDE-PAIR.md document, and
asked to use the tool over HTTP for real work. Human observed the
browser UI in parallel and relayed friction back to the implementing
Claude session in real time.

This evaluation is what crystallised the "REPL for agents with a
window for humans" framing and led to the project being renamed
from "PureScript Playground" to **Atelier**. The evaluator's
write-up below predates the rename and still uses "the Playground"
throughout — preserved unedited as the artefact it is.

The write-up below is from the evaluating Claude — unedited, ordered
by strength of reaction. Save alongside CLAUDE-PAIR.md as the primary
source-of-truth for what the API feels like from the practitioner side.

---

# Playground feedback — implementer POV

From a Claude session using the Playground to sketch a data-viz project
("world map bubbles" — bubble pack of countries nested in continents,
sized by land area and population). ~14 cells, one module, node runtime.
Honest / unfiltered; ordered by strength of reaction.

## What actually clicked

- **Write → snapshot is the killer design.** Every POST returns the full
  post-compile state. I was never in a "wait did that land, let me GET
  again" loop. For iterating on types this is dramatically faster than
  running `spago build` locally, and I noticed I was leaning on it.
- **Types flowing back instantly on record literals.**
  `map (\c -> { density: density c, name: c.name }) samples` inferring
  `Array { density ∷ Number, name ∷ String }` without me lifting a
  finger is exactly the "probe without thinking" loop the document
  claims. Worked as advertised.
- **Adding cells to probe is genuinely low-cost.** I ended up with ~14
  probe cells. None of them cost much to write or much to abandon. The
  cell abstraction is right.
- **`/ide/type` for `log`.** Once I hit `Module Math was not found`, one
  call told me it's `Data.Number.log`. Would have guessed-and-tried
  twice without it.

## What got in my way

- **No way to edit the module incrementally.** I had to `GET /session`,
  string-replace in Python, POST the whole thing back, just to add one
  import. That's not a pair-programming gesture, that's a full-body
  lurch every time. I'd want `PATCH /session/module` with something
  like `{"addImport": "X"}` / `{"appendBody": "..."}` / line-range
  replace.
- **Shell quoting bit me twice.** Python `\a` silently becomes BEL
  (ASCII 7) because I forgot the raw-string prefix — cost one compile
  cycle. PureScript lambdas starting with `\` are unusually dangerous
  through shells. A CLI helper (`pg module < file.purs`) or a
  "send this file as the module" endpoint would obsolete a whole class
  of mistake.
- **Write-path wedging** (before the fix). A single killed POST could
  lock out all subsequent writes while reads stayed fine — a
  compile-lock design I couldn't fully trust under light concurrency.
  The timeout fix patches the symptom; a per-session work queue with
  cancellability is what I'd really want.
- **Browser runtime silently emits nothing** when there's no tab
  actively evaluating. Took me a beat to notice. Either auto-fall-back
  to node, or surface a "no active evaluator" status in the response.
- **Full snapshot on every write, even when I only care about types.**
  The `js` field is 80KB. Fine for this session; annoying if someone
  does a tight loop. A narrower `GET /session/types` would be nice.

## What I wanted and couldn't do

- **Render a value.** Already on the table. Once past scalar types, "see
  the output" is the whole point and there's no column for it.
- **Promote a cell expression into a named module helper.** After
  `map (\c -> …) samples` proves useful as a cell, I want to say "OK,
  move this into the module as `f :: …` and delete the cell." Jupyter
  has this informally. Right now I write the module source with the
  extracted function and remember to kill the cell — two separate POSTs.
- **Multi-module.** One-file `Scratch` is fine for a scratchpad, but if
  the Playground ever wants to host a 300-line data-viz sketch,
  splitting `Country.purs` / `Layout.purs` is a hard requirement. Path:
  accept `POST /session/modules/:name` and let `Scratch` import them.
- **Cell source composability.** I wanted to write
  `let bs = bubbles samples in …` once and reference it from three
  subsequent cells. Right now each cell is an island — its value
  doesn't get a name the next cell can use. `let`-kind cells seem to
  offer this but I didn't try them; worth a clear example in the doc.
- **Persistent sessions.** My `checkpoint.json` + `replay.py` is a hack
  I invented on the spot. A first-class `POST /session/export` /
  `POST /session/import` and maybe `GET /sessions` with automatic
  history would have saved me writing that — and I only wrote it
  because I'd been burned twice. Any non-trivial pair session will want
  this.
- **Value diffs across iterations.** When I changed the density
  function, I wanted to see `before / after` for a specific cell. The
  snapshot-on-write gives me "after." If the server kept the previous
  compile's emits addressable, I could diff.

## On the seven documented workflows

- **1. "Sketch an implementation"** and **5. "Propose a data model"** —
  both worked as described. The Playground's primary value-add.
- **2. "What's the type of X"** — one use, fast, saved a guess.
- **3. "Find by type signature"**, **6. "Port a snippet"**,
  **7. "Explain a library function"** — didn't use. The project didn't
  need them.
- **4. "Observe the human"** — didn't apply; the human wasn't typing in
  parallel.

Of the 7 claimed workflows, 3 did the heavy lifting, 4 were unused.
Not a criticism — the three that worked justify the tool. But the
document oversells by enumerating seven when two or three are
load-bearing.

## Single biggest missing thing

A **render column**. Followed by **PATCH module**. Everything else is
polish.

## Quick wins that would have the highest leverage

1. `PATCH /session/module` with line-range or structured edits
2. A render panel for the fourth column
3. `POST /session/export` + import (+ history) — cheap, eliminates the
   "I was burned and now I have to invent persistence myself" reflex
4. Browser-runtime evaluator-liveness surfaced in the session response
5. A doc warning about `\` in POST bodies from shells
