---
name: calypso-propose
description: Post an edit proposal to a running Calypso (live-coding) session — anyone, including AI agents like you, can propose changes; the human at the Calypso tab accepts or rejects each hunk. Use when someone asks you to "add X to the running composition", "spin up a setup from these tarot cards", "clean up cell c2", or otherwise modify the live-coded music being shaped in their browser.
---

# calypso-propose — author edit proposals to a running Calypso

Calypso is the live-coding webapp at `~/work/afc-work/music/tidal/calypso/`.
A human edits a `.tidal`-shaped composition in one pane and live-runnable
cells in another, firing them at a `purerl-tidal` daemon on Mod-Enter.
Collaboration shape: anyone (including AI agents) can **post edit proposals**;
only the holder of the **Pen** (the on-page approver role) merges them.

Your role from a Claude Code session: take a request like *"add Autechre
beats to the running algorave"* or *"draw three tarot cards and spin a
setup"*, read the current Calypso state, build a structured proposal,
and POST it.  The page renders your proposal as inline ghost text with
✓/✗ buttons; the human reviews and merges the hunks they like.

Use this skill when:
- The user asks you to **add to**, **modify**, or **clean up** the
  composition or cells of a running Calypso.
- The user names a generative source (tarot cards, a track to riff
  on, a mood) and asks you to "spin a setup" — produce a composition
  body or a starter cell.
- The user wants you to **propose** rather than to discuss — proposals
  are non-blocking; the human can ignore them.

Don't use this skill when:
- The user asks how to manually use Calypso (refer them to
  `README.md` and `docs/`).
- The user asks you to start or stop Calypso (different concern;
  `make start` / `make stop` from the repo root).

## Pre-flight

Calypso runs on **`localhost:3060`** (HTTP API) and **`localhost:3061`**
(frontend bundle host).  Before posting, confirm the server is up:

```bash
curl -fsS http://localhost:3060/health
```

If that fails, ask the user to `cd music/tidal/calypso && make start`.
You don't start Calypso yourself — it requires `purerl-tidal` running
separately on `:3012` to actually fire patterns; only the human knows
the rig state.

## The flow

1. **Read current state** — including the **`sourceHash`**, which is
   the SHA-1 of the module source that the server expects in your
   proposal's `basedOn` field.  Don't compute the hash yourself; the
   server's hash is authoritative.

   ```python
   import json, urllib.request
   with urllib.request.urlopen("http://localhost:3060/session") as r:
       snap = json.load(r)
   module_source = snap["module"]["source"]
   source_hash = snap["sourceHash"]
   cells = snap["cells"]   # array of {id, kind, source, form}
   ```

2. **Decide what to change** — read the source, draft your hunks.
   Each hunk is a contiguous diff against `module_source` (or a
   cell's `source`).

3. **POST the proposal**:

   ```python
   body = json.dumps({
     "author": "claude-code:<session-tag>",   # free-form, no auth
     "target": {"type": "module"},            # or {"type": "cell", "id": "c2"}
     "basedOn": source_hash,                  # from step 1
     "hunks": [
       {
         "startLine": 11,                     # 1-based, against basedOn source
         "removed": [],                       # lines to remove (may be empty)
         "added": ["load qd", "load rample"], # lines to add (may be empty)
       },
       # ...more hunks; non-overlapping, in source order
     ],
     "prompt": "add QD + Rample loads",       # optional but RECOMMENDED
                                               # — shown to the human in the
                                               # ghost-text header
   }).encode()
   req = urllib.request.Request(
     "http://localhost:3060/proposals",
     data=body, headers={"Content-Type": "application/json"}, method="POST",
   )
   with urllib.request.urlopen(req) as r:
     created = json.load(r)
     # `created["id"]` is the server-minted ProposalId you'd need
     # if you ever want to withdraw it.
   ```

4. **Tell the human what you did** — concisely.  "Posted a 2-hunk
   proposal targeting the composition: adds QD and Rample loads at
   line 11."  They'll see the ghost text in the page; you don't need
   to describe each hunk.

## Proposal shape, in detail

```
{
  author     : String        # free-form identifier of the proposer
  target     : { type: "module" }
             | { type: "cell", id: <cell id> }
  basedOn    : String        # SHA-1 hex of the target source at proposal time
  hunks      : Array Hunk    # see below
  prompt     : String?       # optional human-readable intent
}

Hunk =
{
  startLine : Int            # 1-based, line where the hunk applies
  removed   : Array String   # lines being replaced (empty for pure insertion)
  added     : Array String   # new lines (empty for pure deletion)
}
```

### Hunk semantics

A hunk replaces lines `[startLine .. startLine + len(removed) - 1]` with
the contents of `added`.  Some shapes:

- **Pure insertion before line N**: `{ startLine: N, removed: [], added: [...] }`
- **Pure insertion at end of source**: `{ startLine: <last+1>, removed: [], added: [...] }`
- **Pure deletion of lines [N..M]**: `{ startLine: N, removed: <those lines>, added: [] }`
- **Replacement**: full removed + added arrays.

`startLine` indexes the **basedOn source** — not the current source
of the page if it has drifted since you read it.  The server's
acceptance check enforces this via the SHA-1 match.  If you read
state, the user types something while you're composing the proposal,
and you POST anyway, the server returns 409 RebaseNeeded; tell the
human and start over.

### Multi-hunk ordering

Hunks within a proposal must be **non-overlapping and in source
order** (sorted by startLine).  Each hunk's startLine is interpreted
against the **original** basedOn source, not against the source
after earlier hunks land — accept doesn't compose hunks atomically;
each is its own independent acceptance.

If you find yourself wanting overlapping or interleaved hunks, that's
a sign you should send a single bigger replacement hunk instead.

## Examples

### Add a load line to the composition

User: *"Add `load garbage` to the running composition."*

```python
import json, urllib.request

with urllib.request.urlopen("http://localhost:3060/session") as r:
    snap = json.load(r)

# Find a sensible insertion point — end of the source.
lines = snap["module"]["source"].split("\n")
end_line = len(lines) + 1   # 1-based; one past the last

body = json.dumps({
  "author": "claude-code:music-tidal",
  "target": {"type": "module"},
  "basedOn": snap["sourceHash"],
  "hunks": [
    {"startLine": end_line, "removed": [], "added": ["load garbage"]},
  ],
  "prompt": "add `load garbage` at end",
}).encode()

req = urllib.request.Request(
  "http://localhost:3060/proposals",
  data=body, headers={"Content-Type": "application/json"}, method="POST",
)
with urllib.request.urlopen(req) as r:
  print("posted:", json.load(r)["id"][:8])
```

### Replace a cell's body

User: *"Rewrite cell c2 to play bd*4 instead of whatever it has."*

```python
import json, urllib.request

with urllib.request.urlopen("http://localhost:3060/session") as r:
    snap = json.load(r)

# Find the cell.
cell = next((c for c in snap["cells"] if c["id"] == "c2"), None)
if cell is None:
    raise SystemExit("no cell c2 in current session")

# Hash the cell source to set basedOn.  We can't read it from /session
# directly; do it ourselves.  (TODO: server will eventually return per-
# cell hashes alongside the module's; for now this is the recipe.)
import hashlib
cell_hash = hashlib.sha1(cell["source"].encode("utf-8")).hexdigest()

old_lines = cell["source"].split("\n")
body = json.dumps({
  "author": "claude-code:music-tidal",
  "target": {"type": "cell", "id": "c2"},
  "basedOn": cell_hash,
  "hunks": [
    {
      "startLine": 1,
      "removed": old_lines,
      "added": ['d1 $ s "bd*4"'],
    },
  ],
  "prompt": "replace c2 with simple kick pattern",
}).encode()

req = urllib.request.Request(
  "http://localhost:3060/proposals",
  data=body, headers={"Content-Type": "application/json"}, method="POST",
)
with urllib.request.urlopen(req) as r:
  print("posted:", json.load(r)["id"][:8])
```

### Tarot-driven composition spin

User: *"I drew The Tower, Eight of Swords, The Fool. Spin me a setup."*

You can interpret the cards however the moment suggests — there's no
fixed mapping.  The output is a series of hunks against the
composition (and possibly cells).  Treat the cards as an evocation,
not an algorithm.  Document the card→decision reasoning in the
`prompt` so the human can read it on the proposal:

```python
prompt = (
  "Tower → unstable rhythm, hard hits; "
  "Eight of Swords → mostly muted/restricted patterns; "
  "Fool → keep it loose, don't over-commit"
)
# ...build hunks as appropriate; POST as above
```

## The /proposals API surface

| Method | Path                                       | Auth          | Effect                                                                 |
|--------|--------------------------------------------|---------------|------------------------------------------------------------------------|
| POST   | `/proposals`                               | none          | Create a proposal; broadcasts ProposalAdded                            |
| GET    | `/proposals`                               | none          | List current proposals (sorted by createdAt)                           |
| POST   | `/proposals/:id/hunks/:idx/accept`         | Pen-required  | Apply the hunk; broadcasts Snapshot + ProposalUpdated/Retired          |
| POST   | `/proposals/:id/hunks/:idx/reject`         | Pen-required  | Drop the hunk without source change                                    |
| DELETE | `/proposals/:id`                           | none          | Withdraw the proposal entirely (proposer-side cancel)                  |

You as a proposer only ever need POST `/proposals`.  Accept/reject
happen in the browser when the human clicks ✓ / ✗.

## Troubleshooting

**`409 RebaseNeeded` on accept**: the source moved between when you
read it and when the user accepted.  The proposal stays in the
queue until someone explicitly rejects or withdraws it; the simplest
recovery is to withdraw and re-author against the fresh sourceHash.

**`409 pen-held` on accept**: the human doesn't currently hold the
Pen.  Tell them to take it (the title-pen button at top-left of the
page) and try again.

**Proposal posted but doesn't appear**: check that the user is
looking at the right tab (`http://localhost:3061`), and that the
WebSocket is still connected (the title shows "you hold the pen"
or similar; "observing" or "unclaimed" means the connection is
alive but they don't hold the Pen).

**Composition body is empty / hashes mismatch silently**: the
seeded body may have trailing whitespace.  Use the server's
`sourceHash`, never recompute the hash bash-side (`$(cmd)` strips
trailing newlines and the recomputed hash will differ).  Python's
`hashlib.sha1(s.encode("utf-8")).hexdigest()` matches the server.

## Pointers

- `docs/atelier-vs-calypso.md` — design context for the
  proposal-vs-write collaboration model.
- `shared/src/Calypso/Proposal.purs` — canonical type definitions.
- `server/src/Calypso/Server/Proposals.purs` — store + business
  logic.
- `server/src/Calypso/Server/Main.purs` — HTTP route handlers.
