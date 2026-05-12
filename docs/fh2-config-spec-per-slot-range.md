# fh2-config spec — per-slot range + bipolar fix (2026-05-12)

Handoff from the Calypso-side Claude to the fh2-config-side Claude.
Three pieces of work, ordered by load-bearing-ness. Done with these,
the polysignal live-coding loop is functionally complete.

## §1. Debug: bipolar5v output is -5..0V, not -5..+5V

**Observed on rig:** firing a polylfo with `outputRange: "bipolar5v"`
produces LEDs in the blue (negative) half only, not full bipolar
swing. The bytes are written, fh2-config reports success, but the
LFO is asymmetric.

**Hypothesis** (to verify): `PolyLfo.buildPresetImpl` writes
`lfos[i].mlt = 8192` but doesn't touch `directLevels[i]`. The base
preset's `directLevels[i]` may carry a non-zero (negative) DC offset
that pulls the LFO into the negative half. The old `polarityToMltDc
Bipolar` used to write `directLevels[i] = 0` alongside `mlt = 8192`;
that piece was lost in the polarity removal.

**Quick test:** add `directLevels[outputIdx] = 0` to
`buildPresetImpl` alongside the `mlt` write, rebuild, fire the same
cell. If LFOs become symmetric around 0V, hypothesis confirmed.

**Fix location:** `src/FH2/Modes/PolyLfo.purs` around the `apply rec
p` clause that writes `p.lfos`.

Probably 3 lines: `Array.updateAt outputIdx 0 p.directLevels`
threaded into the result. May need an additional check on the wire
encoding of `directLevels` (signed 14-bit vs unsigned 14-bit
midpoint) — if `0` doesn't centre, try `8192`.

If polyenv / polyrand also use `directLevels`, same treatment likely
applies. (Lower urgency — Andrew hasn't tested those on rig yet.)

## §2. Per-slot `range` field for polysignal envelopes

Currently the envelope has top-level `outputRange` that sets all 8
jacks of the bank to the same range. Andrew wants per-jack control —
each output independently rangeable.

This matches the FH-2 hardware model (per-jack byte in
`Config.outputRanges[i]`) and aligns with the polysignal grammar's
8-vector affordance shape (8 ratios, 8 shapes, 8 ranges).

### Envelope shape

Add an optional `range` field per slot. When present, the slot's
assigned jack gets its output-range byte set as part of the macro's
buildConfig.

```json
{ "bank": "main",
  "family": "polylfo",
  "slots": [
    { "ratio": 1,   "shape": "tri", "range": "+/-5v" },
    { "ratio": 2,   "shape": "tri", "range": "+/-5v" },
    { "ratio": 4,   "shape": "tri", "range": "+/-5v" },
    { "ratio": 8,   "shape": "tri", "range": "+/-5v" },
    { "ratio": 1.3, "shape": "tri", "range": "+5v"   },
    { "ratio": 2.6, "shape": "tri", "range": "+5v"   },
    { "ratio": 5.2, "shape": "tri", "range": "+5v"   },
    { "ratio": 10.4,"shape": "tri", "range": "+5v"   }
  ]
}
```

### Backwards compatibility

The existing top-level `outputRange` field stays as a "set all 8 the
same" shortcut. If both are specified, per-slot wins for slots that
have it; the top-level fills in for slots that don't. Single-call
semantics.

Calypso will emit per-slot `range` when the user wrote the 8-vector
`ranges [..]` continuation, and top-level `outputRange` when the
user wrote the singleton `range <label>` continuation. They never
both appear from Calypso's output, but the precedence rule above
keeps hand-written JSON envelopes well-defined.

### Implementation sketch

In `FH2.PolyBank.decodeLfoSlot`:

```purescript
decodeLfoSlot json = do
  assertKnownKeys json ["ratio", "shape", "range"]   -- add "range"
  ratio <- optField json "ratio" 1.0          asNumber
  wave  <- optField json "shape" PolyLfo.Tri  asWave
  range <- optField json "range" Nothing      (map Just <<< asOutputRange)
  pure { ratio, wave, range }                        -- threads to Slot
```

`PolyLfo.Slot` gains `range :: Maybe OutputRange`. `buildConfig`
calls `setOutputRange jack r cfg` for each slot whose `range` is
`Just _`.

For polyenv and polyrand (also CV-output families), same shape:
optional per-slot `range` that the family's buildConfig writes via
`setOutputRange`. polyclock / polyeuclid / polyeuclid-pairs emit
gates and don't need it.

## §3. Voltage-shorthand aliases for `parseOutputRange`

Andrew prefers modular-synth-idiomatic short labels in cell text.
Add these to `parseOutputRange` as aliases for the existing
canonical names:

| Token       | Range            |
|-------------|------------------|
| `+/-5v`     | Bipolar5V *(already accepted)* |
| `+10v`      | Unipolar10V *(new)* |
| `+5v`       | Unipolar5V *(new)* |
| `+1v`       | Unipolar1V *(new)* |
| `+8v`       | Unipolar8V *(new)* |

The existing verbose names (`bipolar5v`, `unipolar10v`, etc.) stay
accepted as fallback aliases.

These will become the canonical cell-text form. Reads naturally:
`+5v` = "zero to plus five volts unipolar", `+/-5v` = "plus-or-minus
five volts bipolar".

## §4. Things that *don't* change

- The `--apply-polysignal` and `--apply-polysignal-offline` CLI verbs
  — unchanged.
- The envelope's `bank` / `family` / `slots` structure — unchanged.
- The top-level `outputRange` field — unchanged (becomes the "all 8
  the same" shortcut; per-slot `range` is the precise tool).
- Other families' slot shapes — unchanged. `range` is additive.

## §5. Calypso-side changes (FYI only — I'll do these after you land §1–§3)

1. Extend `valueTokenP` to accept `+`, `/` as valid token chars (the
   `-` already passes). Lets `+/-5v`, `+10v`, etc. parse as tokens
   inside ShToken value lists.
2. Add `ranges` (8-vector ShToken) to `polyLfoSpec.params`. Token
   vocabulary: `+/-5v`, `+10v`, `+5v`, `+1v`, `+8v` + verbose fallbacks.
3. Update wire-envelope JSON serialiser to emit per-slot `range`
   when the cell provides `ranges`, and continue emitting top-level
   `outputRange` when the cell provides `range` singleton.
4. Update `docs/polysignals-grammar.md` range vocab table with the
   new shorthand.

## §6. Order

1. §1 first (the bipolar bug blocks everything visible on rig).
2. §3 next (trivial alias addition).
3. §2 last (slot-shape change, biggest piece).

When §1+§3 are in, Andrew can verify on rig with the existing
top-level `outputRange` shape using new tokens. Once §2 lands, I
flip Calypso to per-slot and we walk the live-coding loop.
