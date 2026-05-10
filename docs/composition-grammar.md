# Calypso composition grammar (routing)

This is the textual grammar for the **routing** portion of a Calypso
session — the part that declares physical devices, configures their
internals, and names pattern-bindings against them. The musical
structure (scales, scenes, progressions), runtime state (bpm, mute,
solo), and live-control defaults live elsewhere.

## Purpose

A composition file answers two questions:

1. **What's connected to the rig?** — devices, declared by type and
   alias. Root devices have a port name; expanders declare a parent.
2. **What names dispatch where?** — bindings, declared as
   `<verb> <name> <device-alias> <args>`. The verb describes the
   signal kind (`gate`, `cv`, `midi-note`, …); the device-alias picks
   the instance; the device-type determines the wire protocol.

Parsed correctly, the file produces a tree of devices with bindings as
labelled leaves — directly renderable as a rig diagram.

## Lexical

- Lines are processed independently. Continuation across newlines is
  not supported in v1.
- **Whitespace** between tokens is one or more spaces or tabs.
- **Comments** start with `#` or `--` and run to end of line. Whole-
  line comments and trailing comments both work.
- **Blank lines** are ignored.
- **Identifiers** (verbs, aliases, modes) match `[a-zA-Z][a-zA-Z0-9_-]*`.
- **Integers**: decimal, no separator.
- **Numbers**: decimal, optional `.` and fractional part. `-` for negative.
- **Strings**: double-quoted; backslash-escape `\"` and `\\`. Used for
  device port names that contain spaces.
- **`key=value`** pairs (used in `osc` decls, `fh2-config`): no
  whitespace around `=`. Values are bare-word identifiers, integers,
  numbers, or quoted strings. Compound references like
  `out=ftrig:0` are bare-word with a colon.

## Statements

Three kinds, in any order: **device declarations**, **device-internal
config**, **bindings**.

### Device declarations

Root devices (have their own physical port):

```
<type> <alias> <port-string> [latency <ms>]
```

| Type      | Port shape                         | Notes                          |
|-----------|------------------------------------|--------------------------------|
| `midi`    | CoreMIDI port name (string)        | latency optional, applies globally |
| `es9`     | CoreAudio device name (string)     | The audio interface cv-router opens |
| `fh2`     | CoreMIDI port name (string)        | FH-2 is also a MIDI port; `latency` applies to MIDI sends |
| `yarns`   | CoreMIDI port name (string)        |                                |
| `osc`     | `host=<host> port=<int>`           | Future: SuperDirt, OSC-listening peers |

Examples:
```
midi   live   "IAC Driver Tidal"
midi   fh2-a  "FH-2"   latency 5
es9    main   "ES-9"
fh2    a      "FH-2"   latency 5
yarns  yarn1  "Yarns"
osc    sd     host=127.0.0.1 port=57120
```

Expander devices (no port; declare a parent via `on <alias>`):

```
<type> <alias> on <parent-alias>
```

| Type        | Parent-type required | Notes                                   |
|-------------|----------------------|-----------------------------------------|
| `es5`       | `es9`                | ES-5 hangs off an ES-9 via ADAT         |
| `esx-8gt`   | `es5`                | 8-channel gate expander on ES-5         |
| `esx-8cv`   | `es5`                | 8-channel CV expander on ES-5           |
| `fhx-8gt`   | `fh2`                | 8-channel gate expander on FH-2         |

Examples:
```
es5      panel    on main
esx-8gt  xgates   on panel
esx-8cv  modcv    on panel
fhx-8gt  ftrig    on a
```

### Device-internal config

Currently only FH-2 voices, which have configurable wire-mode (gate /
envelope / cv / trigger) per voice. The leading `fh2-config <alias>:`
prefix scopes the configuration to a specific FH-2 instance.

```
fh2-config <alias>:envelope voice=<int> out=<out-ref> ch=<int>
fh2-config <alias>:gate     voice=<int> out=<out-ref> ch=<int>
```

`<out-ref>` is one of:
- A bare integer `N`: the FH-2's own MCV output N (0–7).
- A compound `<expander-alias>:<int>`: an output on an attached
  expander, e.g. `out=ftrig:0` for FHX-8GT slot 0.

Examples:
```
fh2-config a:envelope voice=0 out=1     ch=10
fh2-config a:gate     voice=4 out=ftrig:0 ch=14
```

### Bindings

Each binding gives a name to a pattern-lane targeting a specific
output on a specific device.

```
<verb> <name> <device-alias> <protocol-args> [latency <ms>]
```

The verb determines what protocol fires; the device-alias picks the
instance; the protocol-args depend on the verb.

#### MIDI verbs

```
midi-note     <name> <device> <ch> <note> <vel> <dur> [latency <ms>]
midi-cc       <name> <device> <ch> <cc>             [latency <ms>]
midi-cc-cont  <name> <device> <ch> <cc>             [latency <ms>]
```

`<device>` must be of type `midi`, `fh2`, or `yarns` (anything that
exposes a CoreMIDI port).

`midi-note` fires per-event MIDI note-on + note-off after `<dur>` ms.
`midi-cc` fires discrete MIDI CC values (pattern element → 0–127).
`midi-cc-cont` continuously streams a CC value at the clock tick rate
(used for sweeps, LFOs, envelopes).

#### Gate verbs

```
gate <name> <device> <channel> [latency <ms>]
```

`<device>` must be of type `es9`, `es5`, `esx-8gt`, `fh2`, or `fhx-8gt`
(anything that exposes binary trigger outputs). Channel-numbering is
0-indexed within that device.

Behind the scenes the dispatcher picks the wire protocol:
- `es9` → cv-router gate channel (`/tidal/gate/<ch>` OSC)
- `es5` → ES-5 panel bit (Silent Way encoded into the audio stream)
- `esx-8gt` → ESX-8GT bit (Silent Way through ES-5)
- `fh2` → MIDI note on the FH-2 voice's configured channel
  (requires a prior `fh2-config <alias>:gate voice=N …` for the
  target voice). The dispatcher reads that config to know which
  channel + note to send.
- `fhx-8gt` → as `fh2` but the configured voice's `out=ftrig:N` is
  what addresses this slot.

#### CV verbs

```
cv <name> <device> <bus-or-slot> <mode> [latency <ms>]
```

`<device>` must be of type `es9`, `esx-8cv`, `fh2`, or `yarns`.

`<mode>` is **required** — one of:
- `voct` — V/oct pitch encoding
- `literal` — raw value 0..1 → 0..10v (cv-router default range)
- `sample-map` — discrete sample-slot index, encoded as voltage
  steps the destination module interprets (e.g. QuadDrum, Rample)

#### OSC verbs

Reserved for SuperDirt and similar future targets. v1 grammar accepts
them syntactically but the dispatcher is not yet wired.

```
dirt <name> <device> orbit=<int>           # SuperDirt
osc-msg <name> <device> "<path>"           # generic OSC
```

## Verb / device-type compatibility

| Verb           | Compatible device types                      |
|----------------|----------------------------------------------|
| `midi-note`    | `midi`, `fh2`, `yarns`                       |
| `midi-cc`      | `midi`, `fh2`, `yarns`                       |
| `midi-cc-cont` | `midi`, `fh2`, `yarns`                       |
| `gate`         | `es9`, `es5`, `esx-8gt`, `fh2`, `fhx-8gt`    |
| `cv`           | `es9`, `esx-8cv`, `fh2`, `yarns`             |
| `dirt`         | `osc` (SuperDirt-shaped)                     |
| `osc-msg`      | `osc`                                        |

Parser raises a clear error when a binding's verb doesn't match its
device's type.

## Aliases

Aliases live in a single global namespace. No two devices share an
alias. Aliases match `[a-zA-Z][a-zA-Z0-9_-]*` and are user-chosen.

The parser builds a map `alias → device-decl` on first pass; bindings
on second pass resolve their device-alias against this map.

## Latency

Optional on every device-decl and binding-decl. Trailing `latency <ms>`
clause, where `<ms>` is a non-negative integer or decimal. Per-binding
latency stacks on top of device-level latency (additive).

## Complete example

```
# ─── devices ──────────────────────────────────────────
midi      live    "IAC Driver Tidal"
midi      fh2-a   "FH-2"     latency 5
es9       main    "ES-9"
es5       es5-1   on main
esx-8gt   xgates  on es5-1
esx-8cv   modcv   on es5-1
fh2       a       "FH-2"     latency 5
fhx-8gt   ftrig   on a
yarns     yarn1   "Yarns"
osc       sd      host=127.0.0.1 port=57120

# ─── device-internal config ───────────────────────────
fh2-config a:envelope voice=0 out=1     ch=10
fh2-config a:gate     voice=4 out=ftrig:0 ch=14

# ─── bindings ─────────────────────────────────────────
midi-note     bass         live   1 36 100 240
midi-cc       bass-cutoff  live   1 74
midi-cc-cont  bass-mod     live   1 71
gate          kick         main   0
gate          blip         es5-1  0
gate          gx-trig      xgates 0
gate          plaits-trig  a      4
gate          ftx          ftrig  0
cv            plaits-pitch main   15 voct
cv            plaits-mod   main   14 literal
cv            rample-pad   main   12 sample-map
cv            multi-cv     modcv  3  literal
cv            yarns-pitch  yarn1  0  voct
midi-note     plaits-trig  yarn1  1 60 100 50
```

## Migration from the legacy grammar

The legacy grammar (purerl-tidal `setup/*.tidal` files) used:
- `midi-device <alias> <port> [lat <ms>]` instead of `midi …`.
- `bind <name> <action> <args>` instead of `<action> <name> …`.
- Bare `gate <ch>` / `cv <bus>` with implicit single-ES-9.
- `lat` instead of `latency`.
- `fh2-envelope <v> <out> <ch>` / `fh2-gate <v> <out> <ch>` as flat
  verbs without the `<alias>:` device prefix.

A one-shot migrator parses the legacy form and emits the new grammar:

| Legacy                                | New                                       |
|---------------------------------------|-------------------------------------------|
| `midi-device live "IAC..." lat 5`     | `midi live "IAC..." latency 5`            |
| `bind bass midi-note live 1 36 100 240` | `midi-note bass live 1 36 100 240`      |
| `bind kick gate 0`                    | `gate kick <es9-alias> 0` (alias inferred from context) |
| `bind cv 15 voct`                     | `cv <name> <es9-alias> 15 voct`           |
| `fh2-envelope 0 1 10`                 | `fh2-config <alias>:envelope voice=0 out=1 ch=10` |
| `fh2-gate 4 69 14`                    | `fh2-config <alias>:gate voice=4 out=69 ch=14` |

The legacy form has no concept of multiple ES-9 / FH-2 instances, so
the migrator emits a single `es9 main "ES-9"` and `fh2 a "FH-2"` if
those device types are referenced.

## Design notes

- **Comments are not preserved on save.** Calypso never re-serializes
  the file as a whole — the user's edits in the Composition pane go
  through directly as text. Parser is read-only at runtime; serializer
  is used only by the migrator.
- **Order matters for dispatch resolution.** A binding referencing a
  device alias requires that alias to have been declared earlier in
  the file. Likewise, an `fh2-config a:gate` referencing
  `out=ftrig:0` requires `ftrig` to be declared earlier.
- **No looping or branching.** The grammar is purely declarative.
- **The file is for routing, not music.** Musical structure (scales,
  scenes, progressions, melodic ideas) goes in a separate file or a
  separate section to be defined later. Runtime state (bpm, mute,
  solo) likewise.
