# Plan — Hylograph-simulation integration for Atelier's force column

**Date:** 2026-04-20
**Status:** proposal, awaiting sign-off before implementation
**Context:** friction #6 + #8 from the world-bubbles pair session (Marginalia project 173). Currently Atelier's `ForceRender` is an ad-hoc record consumed by a hand-written d3-force shim in `RenderView.js`. Goal: replace that shim with `hylograph-simulation`'s declarative force DSL so the Builder writes `manyBody "charge" # withStrength (static (-30.0))` rather than asking Atelier to extend its own schema each time a new force is needed.

## Why now

The Builder reached the end of useful iteration when the ForceRender variant couldn't be configured (no `forceX`/`forceY`/`cluster`). Two ways forward:

- **Extend Atelier's `ForceRender` record field-by-field** — each new d3-force capability requires an Atelier code change, a new constructor in a bespoke `ForceConfig` ADT, and hand-written d3 wiring. Low per-step cost, but drifts into maintaining a parallel universe of force primitives.
- **Route through `hylograph-simulation`** — Atelier exposes the same force vocabulary a standalone Hylograph demo (e.g. Force Playground) uses. Engine is already proven swappable (D3 ↔ WASM). When hylograph-simulation gains a force, Atelier gains it too.

Route through. That's the point of having the library.

## Scope for v1 (this plan)

Decisions already taken with Andrew:

1. **Curated force subset** for v1: `ManyBody`, `Collide`, `Link`, `Center`, `PositionX`, `PositionY`. `Radial` deferred. Nothing in the data model precludes adding it later.
2. **Node shape stays small.** Atelier's `ForceNode { id, radius, fill, label }` remains the user-facing type. Main-thread adapter wraps each into `SimulationNode row` before feeding hylograph. No extensible-row rope for the user to hang themselves with.
3. **Engine hardcoded to `D3`** in v1. `SimulationConfig.engine` is a field we set, so switching later is one line.
4. **Rendering via HATS** to an SVG container in the render row. Mirrors Force Playground's pattern. This replaces the current d3-force imperative shim.
5. **Simulation runs on the main thread** in v1. Cell execution stays in the Worker; the cell emits a data value (not a function-laden Setup); main thread translates to hylograph's DSL on receive. V2 may relocate the simulation into a dedicated Worker — flagged as an open question below.

## Data model

Atelier gains a data ADT mirroring `hylograph-simulation`'s force list. The ADT is JSON-codec-friendly (no functions), so it travels cleanly through the Worker→main emit channel.

In `runtime-workspace/src/Playground/Runtime.purs` (alongside existing `ForceNode`, `ForceLink`, `ForceRender`):

```purescript
data ForceSpec
  = ManyBody   { name :: String, strength :: Number }
  | Collide    { name :: String, radius :: Number, strength :: Number }
  | Link       { name :: String, distance :: Number, strength :: Number }
  | Center     { name :: String, x :: Number, y :: Number }
  | PositionX  { name :: String, x :: Number, strength :: Number }
  | PositionY  { name :: String, y :: Number, strength :: Number }
  -- future: | Radial { name, strength, x, y, radius :: Number }

newtype ForceRender = ForceRender
  { nodes  :: Array ForceNode
  , links  :: Array ForceLink
  , width  :: Number
  , height :: Number
  , forces :: Array ForceSpec      -- new
  }
```

`ToPlaygroundValue ForceSpec` serialises each constructor the same way `Maybe`/`Either` do: `PVCtor "ManyBody" [ PVRecord [...] ]`. No new wire machinery required.

**User-facing style.** A cell builds the value like any other record:

```purescript
ForceRender
  { width: 800.0
  , height: 800.0
  , nodes: map toNode countries
  , links: []
  , forces:
      [ ManyBody  { name: "charge",    strength: -30.0 }
      , Collide   { name: "collision", radius: 10.0, strength: 0.7 }
      , PositionX { name: "fx",        x: 400.0, strength: 0.05 }
      , PositionY { name: "fy",        y: 400.0, strength: 0.05 }
      ]
  }
```

No `manyBody "charge" # withStrength (static (-30.0))` in cell code — that DSL lives main-thread-side. The mapping is 1:1 so cells feel equivalent without importing hylograph-simulation themselves.

## Transport

The cell runs in the Worker (browser runtime, unchanged). Its `ForceRender` value is serialised through `ToPlaygroundValue` into `PlaygroundValue` JSON, posted to the main thread. `RenderView.js` receives the JSON, matches `$ctor == "ForceRender"`, then for each entry in `forces[]` constructs the corresponding hylograph call.

## Main-thread translator (new FFI)

`RenderView.js` gets a small translator that turns each `ForceSpec` JSON case into a hylograph `Setup` entry. Pseudocode:

```js
function translateSpec(spec) {
  switch (spec.$ctor) {
    case "ManyBody":
      return HylographSimulation.manyBody(spec.args[0].name).withStrength(
        HylographSimulation.static_(spec.args[0].strength)
      );
    case "Collide":
      return HylographSimulation.collide(spec.args[0].name)
        .withRadius(HylographSimulation.static_(spec.args[0].radius))
        .withStrength(HylographSimulation.static_(spec.args[0].strength));
    // ... one case per ForceSpec constructor
  }
}

function renderForceRender(container, fr) {
  const simSetup = HylographSimulation.setup("atelier", fr.forces.map(translateSpec));
  const wrapped  = fr.nodes.map(n => ({ ...n, x: 0, y: 0, vx: 0, vy: 0, index: 0 }));
  const result = HylographSimulation.runSimulation({
    engine: "D3",
    setup: simSetup,
    nodes: wrapped,
    links: fr.links,
    container: `#${container.id}`,
    alphaMin: 0.001,
  });
  result.events.onTick(() => {
    const live = result.handle.getNodes();
    HATS.rerender(`#${container.id}`, svgTreeFor(live, fr));
  });
  return () => result.handle.stop();  // cleanup
}
```

A PureScript-side translator is nicer (type-safe) but adds a build dependency of the frontend on hylograph-simulation's types. Starting in JS keeps the change scoped to `RenderView.js` + its PureScript shim, which is a smaller patch.

Call Andrew's attention: PureScript-side translator vs JS-side translator is a choice I'd flag. JS is quicker; PureScript preserves type safety all the way through. **Leaning JS for v1, converting to PureScript later if types start drifting.**

## Rendering

Current `RenderView.js` inspects `$ctor`; for `ForceRender` it calls a tiny internal d3 simulation. That whole branch is replaced.

- **Mount:** SVG container created inside the render row (as today).
- **Sim lifecycle:** `runSimulation` on receive; `handle.stop()` on cleanup (`_cleanup` in `RenderView.purs`).
- **Frame:** HATS `rerender` on each `Tick`. Node tree = one `<circle>` per node with `cx`, `cy`, `r`, `fill`; link tree = one `<line>` per link.
- **Re-emits:** if the cell re-emits a new `ForceRender` (user edits the setup), stop the previous sim, start a new one. Same pattern as today's diff-check in `handleAction SetInput`.

## Files touched

| File | Change |
|------|--------|
| `runtime-workspace/spago.yaml` | Add `hylograph-simulation` + (likely) `hylograph-hats` to deps. Confirm they're in the registry set the workspace pins. |
| `runtime-workspace/src/Playground/Runtime.purs` | Add `ForceSpec` ADT; extend `ForceRender` with `forces` field; add `ToPlaygroundValue` instances. |
| `frontend/spago.yaml` | Same package additions if PureScript-side translator chosen; otherwise none (JS translator only needs the npm bundle). |
| `frontend/src/Playground/Frontend/RenderView.js` | Rip out the d3-force shim in the `ForceRender` branch; replace with `runSimulation` + HATS rendering. |
| `frontend/src/Playground/Frontend/RenderView.purs` | Likely no change (the FFI contract is `json: String` → `Effect Unit`, which covers both shims). |
| `CLAUDE-PAIR.md` | Document `ForceSpec` constructors and the "build a data value, main thread translates" story. |
| `world-map-bubbles/README.md` (optional) | Update to call out the new capability so a rerun hits it. |

## Test plan

1. **Unit**: cell source constructs a minimal `ForceRender` with one `ManyBody` and one `Collide`. Cell's type reads `ForceRender` cleanly. Sim starts, circles appear, come to rest. No console errors.
2. **Builder rerun**: re-run the world-map-bubbles Builder agent against the updated Atelier. Cell c5 (ForceRender variant, no hierarchy) gains `PositionX`/`PositionY` centering and stops drifting. That closes the open end of friction #8.
3. **Mode robustness**: toggle Drive/Observe during a live sim; sim keeps animating. Reload page; sim restarts cleanly.
4. **Cleanup**: remove the cell; sim stops, no leaked ticker.

## Path to v2 (what this design preserves)

- **Radial force**: one new `ForceSpec` constructor, one new case in the JS translator, one line in CLAUDE-PAIR.md. Nothing else moves.
- **WASM engine**: flip `engine: "D3"` to `engine: "WASM"` in the translator, or expose it as a new `ForceRender.engine` field. Shape-preserving.
- **Expressive node rows** (user-defined extra fields on `ForceNode`): lift `ForceNode` from a closed record to an open row (`ForceNode row = { id :: String, radius :: Number, fill :: String, label :: String | row }`). Existing cells keep compiling because their row adds no fields.
- **Sim-in-worker**: relocate `runSimulation` from the main thread into a dedicated Simulation Worker; render-thread subscribes to tick messages via postMessage. The cell itself stays in its own runtime worker, unaffected. That's the architecture the user flagged as ideal; deferred until we know the memory/CPU cost of N simulation workers alongside N cell workers.

## Resolved decisions (2026-04-20)

Answers from Andrew during plan review:

1. **JS translator for v1.** Accepted tech debt — upgrade to PureScript later if types start drifting.
2. **HATS is used inside the force-sim branch**, which means adding `hylograph-selection` (the HATS provider) as a frontend dependency. This infrastructure also sets up **v2: "HATS as peer output channel"** — a cell returning a HATS tree renders directly, peer to String-SVG and ForceRender. Scope preserved for a follow-on.
3. **Main-thread simulation for v1.** Accepted tech debt; worker-side simulation is the v2 target.
4. **Rename on Atelier side** — use `AtelierForceSpec` (or similar) for Atelier's ADT to avoid collision with hylograph-simulation's own `ForceSpec`. Hylograph-simulation's type stays as it is.

## v2 followups (shape preserved by v1)

- **HATS as peer output channel.** A cell that returns e.g. `HATS.Tree` or `Hylograph.Selection.Tree` renders directly via `HATS.rerender` into its render row. Peer to the `String (SVG)` and `ForceRender` contracts. Once `hylograph-selection` is bundled for the force-sim work, the only remaining lift is a new emit tag + a new case in `RenderView.js`. Worth calling out as friction #9 for Atelier's Toolmaker queue.
- **Radial force** (skipped from v1's curated subset).
- **Engine selector** (`D3 | WASM`) exposed on `AtelierForceRender`.
- **Extensible node rows** for user-defined `ForceNode` fields.
- **Simulation-in-worker** — relocate `runSimulation` into a dedicated Simulation Worker. Biggest open question is the memory/CPU cost of N sim workers alongside N cell workers; worth an exploratory prototype before committing.
- **PureScript-side translator** (replacing the v1 JS translator) for full type safety of `AtelierForceSpec → hylograph Setup`.

Estimated size: ~2–4h for v1 if `hylograph-simulation` + `hylograph-selection` drop into the package set cleanly; longer if the registry 73.3.0 set needs wrangling.
