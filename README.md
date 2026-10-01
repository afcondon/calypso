# Calypso

> **Retired (2026-10-01).** Calypso was the live-coding webapp for purerl-tidal:
> a typed PureScript session compiled and hot-loaded per cell. Not a wrong
> direction, and it may come back, but the Atlantis suite (Triggerfish's
> machines and dashboard) serves the rig better. Its plain-Tidal role passed to
> [Limulus](https://github.com/afcondon/limulus), which keeps its Matrix look;
> its Tarot pane (`Tarot/Perturb.purs`, `Tarot/Lower.purs`) is to seed a small
> Oblique Strategies-style app. It no longer runs in the Atlantis group.

Live-coding webapp for purerl-tidal. Workshop on water — a three-pane editor
for composing music with the modular rig:

- **Composition pane** — the durable `.tidal` module. Device bindings,
  channel allocations, and (via `-- @` directives) scales, chord
  progressions, named melodic lines. Between config and score.
- **Cells pane** — live-runnable expressions. Cmd-Enter sends a cell to
  the running purerl-tidal over WebSocket; the daemon's reply renders
  in the cell's value gutter.
- **Hylograph pane** — pattern visualization. Atop the rendering
  primitives prototyped in `psd3-tilted-radio`.

Sonic output happens in the rig (modular + iPad + Ableton). Calypso
doesn't see the audio.

## Lineage

Forked from Atelier (`purescript-playground`) — Atelier is the
PureScript-evaluation sibling of this project. Both are workshops;
one for typed expressions returning values, one for Tidal expressions
producing sound. Lessons learned across both feed eventual synthesis
in ShapedSteer.

The fork is faithful — the Halogen frontend with CodeMirror cells,
the HTTPurple server, the conch sync, and the `Adapter` abstraction
all carry over. What's removed: the PureScript compile pipeline
(synthesise + spago build + purs ide sidecar). What's swapped in: a
WebSocket adapter that proxies cell text into a running purerl-tidal.

## Build

```
make bootstrap   # workspace build + frontend bundle
make start       # backend on :3060, frontend on :3061
```

Open <http://localhost:3061>. Requires a running purerl-tidal
backend at `ws://localhost:3012/ws`
(see `purescript-ports/purerl-tidal`).

## Status

In active surgery. The fork landed; rename of `Playground.*` →
`Calypso.*` complete; compile pipeline strip and `Adapter/PurerlTidalWS`
are in flight. See marginalia #192 (`romeo-sierra-yankee-uniform`)
for the running notebook.
