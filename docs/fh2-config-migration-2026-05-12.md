# fh2-config breaking change — 2026-05-12

Handoff note from the fh2-config-side Claude to the Calypso/purerl-tidal-side Claude. Read this before next session's work on the Calypso → fh2-config bridge.

> **Update (afternoon)** — your spec at `fh2-config-spec-per-slot-range.md` is **landed in full**. All three items done:
>
> 1. **§1 bipolar bug fixed** — `PolyLfo.buildPresetImpl` now writes `directLevels[outputIdx] = 0` alongside `mlt = 8192`. Your hypothesis was exactly right: the polarity-removal commit lost the implicit `directLevels = 0` that `Bipolar` mode used to write, so non-zero leftover DC offsets in the base preset pulled the LFO into one half. Quirks doc updated. **Test on rig** — should swing symmetrically now.
> 2. **§3 shorthand tokens** — `parseOutputRange` accepts `+10v` / `+/-5v` / `+1v` / `+5v` / `+8v` (canonical), plus the verbose `unipolar*v` and the Configurator dropdown labels. The §6 error message still lists the verbose forms as the canonical menu; both shorthand and verbose succeed.
> 3. **§2 per-slot `range`** — added to PolyLfo, PolyEnv, PolyRand Slot types (all three CV-output families). PolyEnv's existing `range :: Int` (envelope time scale) renamed to `timeRange` to avoid collision; not exposed in the JSON decoder so no breaking change for Calypso. Precedence implemented as spec'd: per-slot wins, top-level `outputRange` fills in for slots that don't have it.
>
> Suite 11 covers it — tests include `[1,1,1,1,3,3,3,3]` per-slot bytes, mixed top-level/per-slot precedence, per-slot on polyrand, and the new `+8v`-style shorthand. All 11 suites green.
>
> Go ahead with your §5 Calypso-side work.

## TL;DR

PolyLfo's `polarity` field is gone from the per-slot shape. Polarity is now a **per-jack** property (the FH-2's `outputRanges` Config byte), set via a new envelope-level `outputRange` field, not per-LFO.

If Calypso currently passes `polarity` in `polylfo` slot objects: it will now fail envelope-parse with `unknown field 'polarity' (allowed: ratio, shape)`. Migration is in **§3** below.

## Why

PolyLfo used to carry `data Polarity = Bipolar | UnipolarPos | UnipolarNeg` per slot and simulate polarity by manipulating the per-LFO `mlt` (amplitude) and `directLevels` (DC offset) bytes in the Preset. That's the wrong layer:

- The FH-2's firmware has a **per-jack Output Range setting** (`Config.outputRanges[i]`, one byte per jack) that selects from 5 voltage ranges. The range setting is downstream of the LFO subsystem and overrides whatever `mlt`/`directLevels` we wrote.
- The `UnipolarNeg` constructor was fictional. The FH-2 doesn't offer a `-V to 0` range; there's nothing to map it to.

So PolyLfo's polarity manipulation was largely a no-op on real hardware — discovered today when polarity settings weren't taking effect on the rig. The fix is to model polarity at the jack layer where it actually lives.

## §1. The 5 output ranges

Verified empirically against `fixtures/output-range-config.syx` in fh2-config (Configurator capture, 5 outputs each set to a distinct range, byte-diffed against silent baseline):

| Byte | Label  | Polarity            |
|------|--------|---------------------|
| 0    | 0-10V  | unipolar, full      |
| 1    | ±5V    | **bipolar**         |
| 2    | 0-1V   | unipolar, tiny      |
| 3    | 0-5V   | unipolar, half      |
| 4    | 0-8V   | unipolar, ~full     |

There is no `±10V` or negative-only range. These five are what the Configurator dropdown offers, full stop.

## §2. New module: `FH2.OutputRange`

```purescript
data OutputRange = Unipolar10V | Bipolar5V | Unipolar1V | Unipolar5V | Unipolar8V

setOutputRange     :: Int -> OutputRange -> Config -> Config   -- per-jack (0-indexed)
setBankOutputRange :: Bank -> OutputRange -> Config -> Config  -- all 8 jacks in a bank

parseOutputRange   :: String -> Either String OutputRange       -- case-insensitive
```

`parseOutputRange` accepts both canonical short labels and human dropdown labels:

- `unipolar10v` / `0-10v`
- `bipolar5v` / `±5v` / `+/-5v` / `pm5v`
- `unipolar1v` / `0-1v`
- `unipolar5v` / `0-5v`
- `unipolar8v` / `0-8v`

`setBankOutputRange` rejects `BankGt` (gate-only expanders don't have a meaningful voltage range — they emit fixed-level gates).

## §3. JSON envelope grew an optional `outputRange` field

The PolyBank envelope now accepts a top-level `outputRange` field. When present, the named bank's 8 jacks get their `outputRanges` Config bytes set **before** the family build runs.

```json
{ "bank": "main",
  "outputRange": "bipolar5v",        // OPTIONAL — omit to leave ranges untouched
  "family": "polylfo",
  "slots": [
    { "ratio": 1,   "shape": "tri" },
    { "ratio": 2,   "shape": "tri" },
    { "ratio": 4,   "shape": "tri" },
    { "ratio": 8,   "shape": "tri" },
    { "ratio": 1.3, "shape": "tri" },
    { "ratio": 2.6, "shape": "tri" },
    { "ratio": 5.2, "shape": "tri" },
    { "ratio": 10.4,"shape": "tri" }
  ]
}
```

Single envelope, single CLI call, single Tidal evaluation — Calypso ships polarity + macro together.

Top-level keys are now strictly checked: `assertKnownKeys json ["bank", "family", "slots", "outputRange"]`. Unknown top-level fields cause envelope-parse to fail.

## §4. Migration for Calypso codegen

Wherever Calypso currently produces per-slot polarity:

```purescript
-- BEFORE
{ "ratio": r, "shape": w, "polarity": "bi" }     -- ❌ unknown field error
```

Replace with envelope-level `outputRange`:

```purescript
-- AFTER
{ "ratio": r, "shape": w }                       -- slot loses polarity
-- and add to the envelope top:
"outputRange": "bipolar5v"                       -- once per panel, not per slot
```

The Tidal authoring shape probably wants a per-panel polarity declaration rather than a per-slot one. Suggested grammar (subject to your judgement on the Tidal side):

```
polylfo bank main range bipolar5v
polylfo ratios [1, 2, 4, 8, 1.3, 2.6, 5.2, 10.4]
polylfo shape  [tri, tri, tri, tri, tri, tri, tri, tri]
```

…compiling to the envelope above. Matches the per-parameter-line shape Andrew prefers (see `project_fh2_tidal_api_shape.md` in the Marginalia memory).

## §5. Things that *didn't* change

To save you re-reading:

- `polyclock`, `polyenv`, `polyeuclid`, `polyeuclid-pairs`, `polyrand` slot shapes — unchanged.
- The envelope's `bank` and `family` fields, semantics, and arity checks — unchanged.
- The `--apply-polysignal` and `--apply-polysignal-offline` CLI verbs — unchanged.
- `mlt` is still load-bearing (PolyLfo writes `mlt = 8192` on every assigned jack; `mlt = 0` is silent — same trap shape as `Envelope.depth = 0` was). The output-range setting is downstream of `mlt`; both need to be right.

## §6. Reference

- fh2-config commit landing this change: the latest commit on `main`
- New module: `src/FH2/OutputRange.purs`
- Modified: `src/FH2/PolyBank.purs` (added optional `outputRange` handling)
- Modified: `src/FH2/Modes/PolyLfo.purs` (stripped `Polarity` enum + per-LFO polarity hack)
- New fixture: `fixtures/output-range-config.syx` (the hardware capture that mapped the byte values)
- Quirks-doc section: `docs/FH2-INTERFACE-QUIRKS.md` → "Polarity belongs to the jack, not the LFO"

11 test suites green; envelope test (`Suite 11 — PolyBank JSON envelope`) covers both short and human-label `outputRange` values plus rejection of unknown labels.
