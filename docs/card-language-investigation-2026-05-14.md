# Card-side language — what's actually PureScript, what's parsed

**2026-05-14 investigation, in support of round-tripping design + Shell.purs refactor.**

**Revised 2026-05-14 (same day) — the original draft missed the `:` operator path and overcounted the role of parsing. See "Three language paths" below; the prior draft folded paths 2 and 3 together as 'parsed DSL' which was wrong.**

## TL;DR

Cards do NOT speak a single language. Three distinct paths run through Calypso → purerl-tidal, only **one** of which compiles real PureScript:

1. **Verb-prefixed DSL** — hand-parsed in `Handler.erl`. ~95% of card lines. Sub-ms to ~10ms.
2. **`:` operator (Tidal.Expr)** — a tiny custom expression DSL with **PS-flavoured syntax**, parsed + dispatched against a fixed combinator vocabulary. Looks like PureScript but isn't. No lambdas, no let-bindings, no type classes. Fast (no compile).
3. **`cue <body>` → `play-armed`** — the only path that runs real PureScript. Body is wrapped in a `Tidal.Generated.M<hash>` module template, spago-builds, purs-backend-erl emits, erlc compiles, BEAM hot-loads. ~7s today.

Andrew's recollection of writing PureScript lambdas in cells must have been via path (3). Tidal.Expr's AST (path 2) has **no lambda constructor**:

```purescript
data Expr
  = EVar String           -- bare identifier
  | ENum Rational         -- numeric literal
  | EStr String           -- mini-notation string ("bd sn")
  | EApp Expr (Array Expr) -- function application
  | EList (Array Expr)    -- bracketed list (fan-out spec)
  | ETag String Expr      -- "name:expr" voice-tag
```

Function application via `EApp` is the closest path 2 gets to embedding — `rev "c4"` parses as `EApp (EVar "rev") [EStr "c4"]`, and `rev` is then resolved against a fixed table imported from `Tidal.Pattern.Core` (rev, slow, fast, every, palindrome, jux, mult, alternate, crossfade, gate, …). Outside that table you can't reach.

## The wire path, end to end

```
[user edits a card]
       │
       │ Cmd-Enter / Cue / Play click → action FireCell cellId src
       │
       ▼
[Shell.purs:782] FireCell handler
       │  autoformat polysignal blocks; maybe show clk reminder
       ▼
[Shell.purs:1374] cellStatements src
       │  split on "\n"; strip "--" comments; drop empty lines
       │  collapse multi-line <> blocks (polysignal, macro)
       │  → Array { lineNum, source }   (one statement per element)
       ▼
[Shell.purs:1427] fireCellStatements
       │  POST /eval { source } per statement
       ▼
[Calypso server] Adapter/PurerlTidalWS.js
       │  one statement per WS text frame to ws://localhost:3012/ws
       ▼
[purerl-tidal Handler.erl :: handle_pattern_message]
       │
       │  case try_parse_prefixed(Text) of
       │
       ├──── PATH 1: VERB MATCHED ─────────────────────────────────────
       │     midi-device / midi-note / midi-cc-cont / gate / cv /
       │     cv-cont / bind / unbind / hush / log-level / load /
       │     set-control / polysignal / drumkit / chord / yarns /
       │     fh2-* / bpm / state / config / play-armed / cue
       │
       │     Each verb has its own dispatch arm. polysignal/drumkit/
       │     chord/yarns forward JSON to the fh2-config daemon over
       │     Unix socket. set-control writes ETS. bpm broadcasts via
       │     OSC to link-spike. Most are sub-ms to ~10ms; some
       │     (fh2-envelope SysEx) spawn into the background.
       │
       │     The `cue` verb is special — see PATH 3.
       │
       └──── none → unprefixed line ──────────────────────────────────
             case Text of
             │
             ├──── PATH 2a: ":<expr>"  (Tidal.Expr, multi-voice) ──
             │     handle_multi_expr(ExprSrc, …)
             │     Voice tags inside the fan-out spec name bindings
             │     directly. Each voice flows to its own destination.
             │     Tidal.Expr.parseExpr → evalMulti →
             │     dispatch per (voice-name, Pattern) tuple.
             │
             ├──── PATH 2b: "<binding> :<expr>" (Tidal.Expr, single)
             │     handle_play_by_name_expr(Word, ExprSrc, …)
             │     Look up Word in tidal_dispatcher binding table;
             │     Tidal.Expr.parseEvalPattern → Pattern → install
             │     into voice tree via tidal_voice_sup:set_voice_pat.
             │
             └──── PATH 4: "<binding> <pattern>"  (mini-notation) ──
                   safe_parse(Rest) — parse the mini-notation pattern;
                   look up binding; tidal_voice_sup:set_voice. No
                   PureScript anywhere. Just pattern dispatch.

       │
       │  Each path produces a reply line "OK …" or "ERR …".
       ▼
[adapter] reply → Shell.purs → state.cellResults[cellId] → rendered.
```

(PATH 3 — `cue` — diverges inside `try_parse_prefixed` and is the only verb that does the spago/purs-backend-erl/erlc/code:load_file pipeline. See its own section below.)

## Three language paths in detail

### Path 1 — Verb-prefixed DSL (Handler.erl)

Hand-written Erlang in `src/Tidal/WebSocket/Handler.erl` (2593 lines). The PureScript `Handler.purs` is a 12-line placeholder so the foreign Erlang file lands in `output-erl/`.

Verbs cover: device aliases, MIDI binding declarations (`midi-note`, `midi-cc-cont`, `gate`, `cv`, `cv-cont`), generic `bind` / `unbind`, transport (`bpm`, `hush`, `log-level`, `state`, `config`), per-device hardware claims (`polysignal`, `drumkit`, `chord`, `yarns`, `fh2-envelope`, `fh2-gate`), live-control (`set-control`), file-based scene `load`, and `cue` / `play-armed`.

Latency: sub-ms for in-purerl-tidal operations; ~10ms when a verb forwards JSON to the fh2-config daemon over the Unix socket; ~7s when a verb shells out to fh2-config CLI (without the daemon, but the daemon is the default).

### Path 2 — `:` operator (Tidal.Expr)

A **tiny custom expression DSL** parsed by `Tidal.Expr.parseExpr`. AST has six constructors (above). Combinator vocabulary is whatever `Tidal.Expr` imports from `Tidal.Pattern.Core` and `Tidal.Pattern.Branched` — currently:

- Single-voice transformations: `id`, `rev`, `slow`, `fast`, `palindrome`, `every`, `iter`, `off`, `brak`, `stutter`, `ply`, `segment`, `irand`, `linger`, `compress`, `zoom`, `trunc`, `rotL`, `rotR`
- Wave functions: `sine`, `cosine`, `saw`, `isaw`, `tri`, `square`, `rand`, `expSaw`, `iexpSaw`, `logSaw`, `ilogSaw`, `range`
- Branched fork/merge: `jux`, `mult`, `alternate`, `crossfade`, `gate`

Fan-out specs use bracketed-list syntax with voice tags: `[L:id, R:rev]`, `[a:id, b:rev]`, `[pad:false, lead:true]`. Per the file header doc: **partial application is "not yet"** — `[harm:slow 2]` doesn't parse. Combinator names must be bare.

What this path is good for: applying a curated set of transformations to mini-notation patterns at sub-100ms latency, with no compile step.

What it's NOT: a host-language evaluator. You can't define helper functions, can't use lambdas, can't add new combinators without changing `Tidal.Expr`'s code and rebuilding purerl-tidal.

### Path 3 — `cue <body>` + `play-armed` (real PureScript)

The verb `cue <body>` calls `tidal_compiler:compile_and_load(Body, Hash)` (Handler.erl:820). That function:

1. Wraps `Body` in a `Tidal.Generated.M<hash>.purs` template (imports `Tidal.Cell.Prelude`, defines `pattern = <Body>`).
2. `spago build` — purs compiles to corefn.
3. `purs-backend-erl` re-emits all 371 modules (per memory `reference_purs_backend_erl_incremental_emit` — the 7s floor).
4. `erlc` compiles the generated .erl.
5. `code:load_file/1` hot-loads the new BEAM.
6. Reply: `OK: cue Tidal.Generated.M<hash>`.

Subsequently `play-armed <mvoiceName> <moduleName>` installs `Module:pattern/0` into the named voice's gen_server. ~ms.

This is the **only path where real PureScript runs**. Lambdas, let-bindings, type classes, helper definitions, anything in PS — all fair game.

Cache hits short-circuit: if the hash matches an already-loaded module, no re-compile.

### Path 4 — Named-binding mini-notation dispatch

The `<binding> <pattern>` form (Handler.erl:990): `bass "c2 ~ c2 ~"`, `kick "bd*4"`. The pattern body is parsed by `safe_parse` (mini-notation parser) and dispatched against the binding's voice. No PureScript at all. Sub-ms.

This is what the original main session JSON's cells were doing (`{"mvoice":"bass","tvoice":"bass","source":"mini \"c2 ~ c2 ~ d#2 ~ c2 c2\""}` — though note the use of `mini` there, which looks like Path 2's `EVar "mini"`; investigation needed if this works without a `:` prefix).

## What's actually PureScript

Real PureScript runs **only via path 3 (`cue`)**. Tidal.Expr's `:` operator looks like PureScript syntactically but is a parsed combinator subset. Mini-notation dispatch isn't PS.

The cell vocabulary exported by `Tidal.Cell.Prelude` is PS code, but users reach it only via `cue`. The Tidal.Expr path resolves a different (overlapping) vocabulary directly from `Tidal.Pattern.Core` etc., bypassing the cell-prelude layer.

## Implication for round-tripping (#10)

The composition pane uses `Calypso.Composition.Parser` (in `shared/`) which produces a typed AST covering: device declarations, bindings, fh2-config routing, polysignal blocks, macros (`drumkit`, `kit`, `chord`, `yarns`).

That parser does **not** today cover the `:` operator path or `cue` bodies. For round-tripping, you'd want to extend `Statement` to include these — possibly as opaque `RawPsExpr` and `CueBody` cases that the printer emits back verbatim, rather than trying to AST the PS bodies (since cue bodies are arbitrary PS, not a constrained DSL).

Treat path 2 the same: round-trip Tidal.Expr expressions by re-parsing and pretty-printing through `Tidal.Expr.parseExpr` (which Tidal.Expr already has). Pretty-printer would be new.

The polysignal autoformat path is the working proof-of-concept: cells that parse as a single polysignal block already do text → AST → pretty-text on every fire (Shell.purs:797). Extending to other verb families is incremental.

## Implication for the refactor (#8)

1. **The statement splitter / collapser belongs in `shared/`, not Shell.purs.** `cellStatements` (Shell.purs:1374) calls `Comp.collapsePolySignalEntries` + `Comp.collapseMacroEntries` (already in shared/). Pull the wrapper into shared/ alongside its dependencies.
2. **`Calypso.Composition.Parser` is already in shared/ with a test suite.** Refactor should make every pane that needs grammar awareness import it.
3. **The COMPOSITION-vs-CELLS distinction is wire-equivalent** at the purerl-tidal end. The UI split is purely Calypso-side concern.

## Implication for the legacy Cells pane removal

Voice Cells fires through the same `FireCell` action as the legacy Cells pane (Shell.purs:2437, 2918, 2926, 2932). Removing the legacy Cells pane is pure UI subtraction.

## Implication for warm-compiler (#11)

`#11` matters ONLY for path 3 (`cue`). Paths 1, 2, and 4 don't compile anything — they're already fast.

The right framing for `#11`: **how often does live coding actually require `cue`?**

- If most patterns can be expressed via path 2's combinator vocabulary, `cue` is rare and the 7s tax is tolerable.
- If users frequently need lambdas / helper definitions / fresh function bodies, `cue` is on the hot path and warming it (or pre-warming a compile pool) matters.

Two paths forward, possibly both:

- **Expand Tidal.Expr** — add more constructors (e.g., lambdas via a small interpreter step), more combinators, partial application. Pushes more flows off the compile path. Bounded by what we want users to write live without a real type checker.
- **Warm `cue`** — keep a hot `purs-backend-erl` daemon, share the compile cache, incremental emission rather than re-emitting all 371 modules. Targets the ~7s floor.

These are orthogonal — Tidal.Expr expansion makes `cue` less critical; warming `cue` makes it tolerable when used.

## Open questions for next session

1. **What about Andrew's recollection of writing PureScript lambdas in cells?** Tidal.Expr can't parse lambdas; if it happened, it was via `cue`. Worth confirming with a session-log search or asking him.
2. **Is path 4 (`<binding> <pattern>`) actually working in the current cells?** The original main session JSON had cells like `"mini \"c2 ~\""` — that's `mini` as the first word, which would resolve via Tidal.Expr's combinator table (path 2). Specifically check whether Calypso wraps cell sources with `:` or some default verb before sending, or whether Handler.erl has a special-case for cells starting with `mini`.
3. **Could the `:` operator be the default fire path?** Today users have to remember to type `:`. If unprefixed cells were auto-wrapped, the live-coding UX becomes "type PS-flavoured expressions, get fast feedback, fall back to `cue` when you need real PS."
