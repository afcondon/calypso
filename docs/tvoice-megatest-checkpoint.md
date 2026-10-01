# tvoice Megatest — Checkpoint (2026-05-11)

Live walk of the `runtime-workspace/workspaces/tvoice-test/` workspace —
one card per dispatch path the system can reach. Used to validate every
tvoice type Calypso speaks against the actual modular rig + Live.

## How to resume

1. **Boot order**
   1. cv-router on (`~/work/afc-work/music/expert-sleepers/cv-router`)
   2. link-spike on (`~/work/afc-work/music/link-spike`) — handles
      CoreMIDI dispatch; restart if you've added/renamed MIDI ports
      since it started (destination cache is not auto-refreshed —
      memory: `reference_link_spike_destination_cache_stale.md`)
   3. fh2-config daemon (if testing FH-2 cards):
      `cd ~/work/afc-work/music/expert-sleepers/fh2-config && spago run -- --daemon`
   4. purerl-tidal via deepstar — `make start` orphans BEAMs (memory:
      `feedback_use_deepstar_dont_bash_launch.md`)
   5. Calypso server (SDI lazy-spawns on first request to `:3060/3061`)

2. **Load workspace**
   - Calypso UI: click `↥ load…`, pick
     `runtime-workspace/workspaces/tvoice-test/calypso-session.json`
   - Hit `▶ fire` on the composition pane (registers all device
     aliases + bindings on the daemon)
   - Reply pane should show ~25 lines of `OK: ...`; no `ERR:` lines
     for any device/binding declaration

3. **Test a card**
   - Click on the card to open the modal
   - Click `cue` (compiles cell source to BEAM module)
   - Click `▶` (play-armed installs on the named tvoice)
   - Verify the expected behaviour on rig / Live

## Bus assignments (ES-9 panel jacks)

| jack | bus | binding   | role            |
|------|-----|-----------|-----------------|
| 1    | 8   | `kick`    | drum trigger    |
| 2    | 9   | `snare`   | drum trigger    |
| 3    | 10  | `leadCv`  | lead V/oct      |
| 4    | 11  | `bassP`   | bass V/oct      |
| 5    | 12  | `synth1g` | synth1 trigger  |
| 6    | 13  | `synth1p` | synth1 V/oct    |
| 7    | 14  | `es9lfo`  | continuous CV   |
| 8    | 15  | —         | free            |

## Test results

✅ = end-to-end validated on the rig; ⏭ = skipped or deferred;
⏸ = gap (no dispatch path yet); — = not tested yet

| #   | Card / tvoice    | Verb shape                         | Status     | Notes |
|-----|------------------|------------------------------------|------------|-------|
| 1   | bass / `bass`    | `midi-note bass iac 1 36 100 200`  | ✅ working | MIDI to Live via IAC ch 1; pattern's note token (e.g. `c2`) overrides the binding's literal note |
| 2   | bass / `mod`     | `midi-cc-cont mod iac 1 1`         | ✅ working | host LFO via IAC CC1 |
| 3   | (MIDI LFO)       | —                                  | ⏭ subsumed | same path as 2 |
| 4   | lead / `leadCv`  | `cv leadCv es9 10 voct`            | ✅ working | uncalibrated by ear; pitches sound right |
| 5   | fh2 / `fh2lfo`   | `midi-cc-cont fh2lfo fh2 14 1`     | ⏸ partial  | dispatch confirmed (CC reaches FH-2 port); end-to-end CV-on-jack pending **FH-2 internal-routing CLI work** — see `fh2-rich-interface-plan.md` |
| 6   | drums / `kick`   | `gate kick es9 8`                  | ✅ working | QuadDrum, Plaits, Iteritas Alia |
| 7a  | synth1 / `synth1g` | `gate synth1g es9 12`            | ✅ working | Plaits, Iteritas Alia |
| 7b  | synth1 / `synth1p` | `cv synth1p es9 13 voct`         | ✅ working | Plaits, Iteritas Alia; shares cell source with 7a (one melodic line, two tvoices) |
| 8   | bass-cv / `bassP` | `cv bassP es9 11 voct`            | ⏭ skipped  | redundant with 4 |
| 9   | drums / `snare`  | `gate snare es9 9`                 | ⏭ skipped  | redundant with 6 |
| 10  | lfo / `es9lfo`   | `cv-cont es9lfo es9 14`            | ✅ working | host LFO via cv-router direct bus to jack 7 |
| 11  | clock / `clock`  | `gate clock es5 0`                 | ✅ working | ES-5 panel gate 1 |
| 12  | (ESX V/oct)      | —                                  | ⏸ gap      | legacy `esx` action is literal-only; no V/oct mode threading |
| 13  | (ESX LFO)        | —                                  | ⏸ gap      | needs `ContESX` ContDest variant + `esx-cont` verb |
| —   | fh2 / `fh2env`   | `gate fh2env fh2 1`                | ✅ working | FH-2 envelope mode (voice 1 → out 1, ch 11) |
| —   | fh2 / `fh2gate`  | `gate fh2gate fh2 2`               | ✅ working | FH-2 gate mode (voice 2 → out 2, ch 12) |
| —   | fh2 / `fhxgate`  | `gate fhxgate fh2 3`               | ✅ working | FH-2 → FHX-8GT slot 1 (voice 3 → fhx:1, ch 13) |

**Score: 11 paths validated end-to-end, 5 deferred for FH-2 / ESX
work, 2 redundancies skipped.**

## What this validated

Every dispatch arm the current code speaks is exercised at least once
on real hardware:

- MIDI note out via link-spike CoreMIDI bridge → IAC port
- ES-9 V/oct via cv-router `/cv` (sustained, V/oct-encoded)
- ES-9 cv-trig via cv-router `/cv/trig` (pulse, auto-decay)
- ES-5 panel gate via cv-router `/esx5gate`
- FH-2 envelope-mode trigger (via `fh2-config` + MIDI note dispatch)
- FH-2 gate-mode trigger (same path, different mode)
- FH-2 → FHX-8GT (chained-expander gate via voice-output 65+)
- Host-driven LFO via `midi-cc-cont` (Pattern Number per-event emit)
- Host-driven LFO via `cv-cont` (sustained-CV per-event emit)

The continuous-binding `play-armed` path was wired this session
(2026-05-10): `patternStringToNumber` in `Tidal.Pattern.Core` bridges
the Pattern String the cell always exports into the Pattern Number
that continuous voices need. The `cv-cont` routing-grammar verb was
added alongside (Handler.erl + Composition AST + Parser + frontend
type-color extractor).

## What's known-missing

These cards in the workspace are placeholders for work that's still gapped:

- **c13** — ESX-8CV V/oct CV: legacy `esx` action is literal-only.
  Mode threading needed.
- **c14** — ESX-8CV LFO: needs a `ContESX` ContDest variant alongside
  `ContMidiCC` and `ContCV`, plus an `esx-cont` routing-grammar verb.
  Touches Binding.purs, Dispatcher.purs (cv-router OSC for ESX), the
  Composition AST/Parser/codec stack, and the frontend type-color
  extractor.
- **c5 (fh2lfo)** — dispatch confirmed; end-to-end CV-on-jack pending
  the FH-2-rich-interface work in `fh2-rich-interface-plan.md`.

## Bugs found and fixed this session

For the audit trail, since this was a chunky session:

- `#` was stripped as a comment in cell text, breaking sharp-note
  tokens (`d#2` → `d`) and Tidal `# vel "..."` param-attach. Fix:
  separate `cellStatements` vs `compositionStatements`.
- IAC port name in workspace had parens (`IAC Driver (Tidal)`);
  macOS CoreMIDI names don't use parens. Fixed in workspace.
- `fh2` device declared with `midi` verb (alias type = midi) but
  `gate` verb expects alias type = fh2. Fixed in workspace.
- `LoadWorkspace` action updated session state and "lastSynced"
  fields but didn't push to the CodeMirror editor; subsequent `▶ fire`
  walked the editor's old buffer. Fix: explicit `Editor.ReplaceContent`
  push.
- `play-armed` only looked up discrete bindings; continuous ones
  reported "no binding" even though `midi-cc-cont` had registered
  them. Fix: fallback to `lookup_continuous_binding` with
  `Pattern String → Pattern Number` conversion via the new
  `patternStringToNumber` helper.

These are all locked in via memory entries (search for
`reference_calypso_module_vs_cell_comment_rules`,
`reference_macos_iac_port_naming`,
`feedback_halogen_codemirror_buffer_sync`).
