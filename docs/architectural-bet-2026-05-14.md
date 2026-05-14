# Calypso architectural bet (2026-05-14)

The shape Calypso is converging toward, and why. Written after a long architecture conversation that surfaced exploratory-stage baggage and named the strategic position we're betting on. This document is **prescriptive** for the work ahead — when in doubt, decisions should align with what's stated here, or this doc should be updated to acknowledge a change of direction.

## The bet, in one sentence

> We can make a music-making environment that feels as much like live-coding as Tidal does, without access to a true REPL like GHCi.

Said another way: we accept that the code-eval loop will be slower than OG-Tidal's <200ms cadence, and we make that acceptable by **distributing musical expressivity across the rig** rather than concentrating it all in the text editor.

## The three compensations

1. **Hands-on rig.** Modular synth knobs, iPad controllers, pedalboards, MIDI surfaces. Continuous-axis musical change (filter cutoff, LFO rate, FX wet, gain shaping) happens at hand-speed — never gated by the code path.

2. **Cue/play model.** Pre-compile expressions; perform by choosing between staged cues. DJ-style. Latency on a fresh `cue` is tolerable because firing a *staged* cue is sub-millisecond.

3. **Warm compiler.** Cue compile itself targets ~500ms steady-state (not OG-Tidal-fast, but fast enough that ad-hoc cuing during performance is a deliberate beat, not a system stall).

The bet pays off if all three carry their weight. If any one fails, performance feels stuttery. None of them is optional in this framing.

## What this means for the code path

**Verbs are control. PureScript is music.** A clean separation, enforced architecturally:

| Surface | What it does | Where it's parsed | Latency budget |
|---|---|---|---|
| Verbs | Setup, register bindings, configure hardware, transport, live controls | Hand-written Erlang dispatcher (`Handler.erl`) | sub-ms to ~10ms |
| PureScript via `cue` | Patterns, transformations, anything musical | Real spago/purs-backend-erl/erlc/hot-load | ~500ms post-warm-compiler (~7s today) |

**No third language.** No "looks like PureScript but isn't." No backend escape hatches that parse strings into Patterns without going through the compile pipeline. Anything musical is PureScript or doesn't run.

The exact words: *one road from musical intent to running sound.*

## What this rules out — and why

Three things that exist in the code today but don't survive this bet:

### Tidal.Expr / the `:` operator

The hand-rolled expression parser in `purerl-tidal/src/Tidal/Expr.purs` (`bass :rev "c4*4"`-style cells). 908 lines of PureScript + ~200 lines of Erlang dispatch in Handler.erl.

**Why it loses:** false friend. A `rev` in a cue body is real PureScript; a `rev` in a `:` expression is `EVar "rev"` resolved against a fixed table. Same name, different semantics. The vocabulary overlaps with `Tidal.Cell.Prelude` but isn't identical, and the AST (`EVar | ENum | EStr | EApp | EList | ETag`) lacks lambdas and let-bindings. Anyone reading the code today has to mentally track which language a given line is in.

**Origin:** the AST grew during exploration to dodge compile latency. The motivation was real (~7s per cue felt unacceptable). With warm-compiler bringing that to ~500ms, the workaround's cost (a parallel language to maintain forever) exceeds its benefit.

### Path 4: bare-string mini-notation dispatch

The `<binding> "<pattern>"` shortcut (e.g., `bass "c2 ~ c2 ~"`) where the pattern body is parsed by Erlang at the wire boundary and installed without ever touching PureScript.

**Why it loses:** trojan horse. Every escape-hatch shortcut in this codebase exists because the host language was too slow to use directly. If we close `:` but leave path 4, the next time someone says *"but `mini "bd sn"` compiles in 500ms, let me just add a quick shortcut for THIS one case..."* there's precedent. Bypass-by-parsing becomes a pattern of escape.

**Cost of keeping it:** ~zero in code. Cost of removing it: every musical statement now goes through the compile pipeline. That's the point — it forces #11 to be honest.

### The legacy Cells pane in Calypso

Pre-Voice-Cells UI in `Shell.purs`. Voice Cells supersedes it. Fires the same `FireCell` action; the legacy pane is rendered redundancy.

**Why it loses:** Pure UI subtraction with no cost. Removed as part of the Shell.purs refactor.

## What this requires

### `#11 warm-compiler` becomes the critical path

Pre-this-bet, #11 looked like a quality-of-life improvement orthogonal to other work. Post-this-bet, #11 *is* the engineering foundation under everything. Without it:

- Live coding feels broken (no fast eval at any granularity)
- Cue/play feels broken (pre-staging takes seconds per variation)
- The bet doesn't hold

Whatever it takes to get cue to ~500ms steady-state — hot compile pool, shared spago state, incremental purs-backend-erl emission, all of it — is in scope.

### Cell-fire defaults to cue

After the `:` and path-4 removals, the cell-fire path has two cases:

```
cell content starts with a known verb → dispatch verb
otherwise                            → wrap in `cue <body>` + `play-armed <mvoice> <module>`
```

The frontend handles the wrapping. From the user's perspective, "type expression, hit fire, hear it" is restored — under the new timing regime. The OG-Tidal mental model is preserved; the implementation differs.

### The cue/play UI must be genuinely DJ-grade

Stage cuing, A/B armed-state visibility, clear "this is loaded but not playing" vs "this is playing now" indication, sub-100ms switch between staged variants. The Voice Cells pane is the foundation; demoability hinges on how good this becomes.

This is principally a UX problem, not an engineering one. Live-coding music software has rarely had real DJ-grade staging affordances — most performers either type live or rely on external clip launchers. Calypso has the opportunity to do this well, and the bet's third leg leans on it.

## Failure modes

The bet could fail in three ways. Worth being honest about them:

1. **Cue compile doesn't get to 500ms.** Hard floor we don't yet know. If the floor is 2-3s, performance feels stuttery. Mitigation: the slotted-literals plan (`purerl-tidal/docs/slotted-literals-plan.md`) sidesteps recompile for string-content edits; if needed it could be implemented to bring the common case to ~zero.

2. **The hands-on rig doesn't carry as much expressivity as hoped.** Knob-turning and pedal-stomping is a different gesture from typing `slow 2`. Some performers, some pieces, the rig genuinely isn't enough. Mitigation: musicianship problem more than engineering; addressed by choice of rig and piece, not by code.

3. **Cue/play feels too heavy.** Pre-staging variants is more deliberate than improvising live. If pieces want fluid moment-to-moment evolution where staging breaks the flow, the bet's framing is wrong. Mitigation: harder. Probably means accepting that Calypso is good for some performance practices and not others, and being honest about which.

## How this compares to alternatives we're rejecting

| Direction | Why we're not taking it |
|---|---|
| Build a faster eval interpreter for PureScript (extend Tidal.Expr to support lambdas, let-bindings, etc.) | Reintroduces the "looks like PS but isn't" trap. Different semantics from the cue path. Maintenance burden grows with each combinator added. Type system gets lost. |
| Add more backend-side shortcut parsers when specific cases are slow | Trojan horse pattern. Every shortcut sets up the next shortcut. The language unity erodes case by case. |
| Live with 7s cue and don't try to get faster | Untenable for performance. The bet on cue/play assumes the cue itself takes ~hundreds of ms, not ~seconds. |
| Drop PureScript entirely and use a simpler runtime DSL | Loses the type-checked composition, the existing combinator library, the eDSL nature that maps cleanly to Pattern algebra. Big language-design step backward. |
| Replicate OG-Tidal's eval model directly (run a PureScript REPL hot in BEAM) | Doesn't exist; would be a massive engineering project; probably not faster than warm-compiler purs-backend-erl anyway. |

## Deferred work tied to this bet

- **Slotted literals** — `purerl-tidal/docs/slotted-literals-plan.md`. Fast string-content updates without recompile. Mitigation for failure mode 1 above. Don't implement until playing-time evidence shows it's needed.
- **Round-tripping code ↔ cards** — `#10` in the task list. Verbs round-trip through the existing `Calypso.Composition.Parser` AST; cue bodies round-trip text-verbatim. Design pass needed.

## Open empirical questions

These get answered by performance practice, not by engineering speculation:

1. How fast does cue actually need to feel for the bet to hold?
2. Does the rig carry enough expressivity for the pieces Andrew wants to perform?
3. Where does the line fall between "stage in advance" and "improvise live" for a given piece?
4. What's the right cue/play UI vocabulary (single armed slot per mvoice? A/B/C stages? crossfades?)?

The doc gets revisited as those questions get answers.

## Status of related docs

- `card-language-investigation-2026-05-14.md` — describes what IS (the three-language situation). This doc describes what WILL BE.
- `slotted-literals-plan.md` (in purerl-tidal) — deferred mitigation for failure mode 1.
- `fh2-fold-in-plan.md` (in purerl-tidal) — abandoned for different reasons (trapdoor decision), no relationship to this bet.
- Future `cue-warming-plan.md` — does not yet exist; would be the design doc for #11, the critical path.
