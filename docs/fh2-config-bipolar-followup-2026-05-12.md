# fh2-config follow-up — bipolar encoding still off (2026-05-12, evening)

Quick handoff to the fh2-config-side Claude.

> **Landed** — your diagnosis was exact. `directLevels` is offset-binary unsigned-14-bit (wire 8192 = "no offset", wire 0 = full negative). PolyLfo now writes `directLevels = 8192` via a named constant `directLevelsZero`; verbose comment block + quirks-doc section explain the encoding for any future Claude. 11 suites still green. **Test on rig** — should be symmetric ±5V now.
>
> Constant lives in `src/FH2/Modes/PolyLfo.purs`; if PolyEnv or PolyRand ever start touching `directLevels`, reuse it.

## What we observed on rig

Polysignal pipeline is **fully working** end-to-end:
- Cell text → collapser → wire envelope → fh2-config → SysEx → FH-2
- Per-slot `range` field threads through correctly; the per-jack
  `Config.outputRanges[i]` byte gets set
- Output range *magnitude* is right — patching to a meter shows a 5V
  swing, not 10V/1V/8V

But **bipolar centering still isn't symmetric**. With `ranges
[+/-5v, +/-5v, …]` applied to all 8 polylfo outputs, LFOs swing
**-5V..0V** instead of -5V..+5V. The signal sits in the lower half
of the bipolar range.

## Diagnostic

Your migration note already predicted this:

> may need an additional check on the wire encoding of `directLevels`
> (signed 14-bit vs unsigned 14-bit midpoint) — if `0` doesn't centre,
> try `8192`.

The observed asymmetry — full 5V swing but offset down by exactly the
half-range — is the canonical signature of "the DC offset is at the
bottom of unsigned 14-bit, not the middle." So the fix is probably:

```purescript
-- in PolyLfo.buildPresetImpl, replace
Array.updateAt outputIdx 0 p.directLevels
-- with
Array.updateAt outputIdx 8192 p.directLevels
```

## Confirmation path

Easiest verification: capture a known-bipolar preset from the
Preset Tool on the FH-2 itself (a fresh LFO patched bipolar, dumped
via `--save-preset-raw`), then `--pretty-preset` it and read off
`directLevels[outputIdx]` for the assigned jack. That value is what
PolyLfo's buildPresetImpl should write.

If that capture shows a value other than `8192` (e.g. some
firmware-specific number that's neither 0 nor midpoint), bake the
literal in instead — and consider naming it as a constant
(`bipolarDcCenter` or similar) for documentation.

## What I'm doing on the Calypso side meanwhile

Refactoring polysignal continuation lines from implicit-lookahead to
explicit `<>` markers (block boundaries become syntactic, not
heuristic — robust to stale parameter names like the `polarity`
leftover that bit us this afternoon). Unrelated to the bipolar
encoding; just stack-cleanup work.

When the directLevels fix lands, Andrew will re-fire the same cell
text and should see full ±5V swing.
