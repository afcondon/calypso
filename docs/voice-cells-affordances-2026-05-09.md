# Voice Cells affordances queued

Status: parked 2026-05-09 at end of the live-control DEJA VU
session.  These are UX improvements to the Voice Cells pane —
backend-side substrate is already complete, the Voice Cells column
just needs UI surface for the new shapes.

## Andrew's queued list

1. **New-card creation gesture.**  Today cards seem to come into
   existence as cells get cued; there's no explicit "new empty
   card here" affordance.  Want one.

2. **Voice picker / dropdown for bound mvoice selection.**  The
   modal header's mvoice name is a free-text input today.  A
   dropdown populated from the registered bindings (the `state`
   verb's voices list) would prevent typos and surface what's
   actually wired.  Free-text fallback for new names still useful
   though — typing a not-yet-bound name and binding-on-the-fly
   should remain possible.

3. **Sort / separate by card type.**  Cards today are uniform
   colour-coded-by-mvoice stacks.  As we add new card types
   (control cards with sliders, scene cards, future Digitakt
   tracks, …) they shouldn't intermix freely with voice cells.
   Sort or separate columns / rows by type so the pane stays
   readable.

4. **Config cards always leftmost.**  When a card category is
   "config" (control sliders, scene selectors, etc.), pin them
   to the leftmost position in the row regardless of when they
   were created.  They're context for the voice cells to their
   right.

## What's already built that this UI would surface

The backend substrate for live-controlled parameters landed
2026-05-09 (DEJA VU as first consumer) — the BEAM accepts
`set-control <name> <value>` over WS and threads `live "name"`
into pattern queries.  All the affordances above are about giving
the user a UI knob/slider that emits the same `set-control`
verb instead of needing a wscat terminal.

A control card type with `(name :: String, value :: Number)` and
a slider that emits `set-control <name> <value>` on drag is the
minimum viable form.  See `purerl-tidal/docs/sequencer-vocabulary-
research-2026-05-09.md` for the broader vision (Digitakt-style
P-locks, Pam-style continuous mod, etc.) — all those would
similarly want their own card types and would benefit from the
sort/separate affordance.

## Implementation hints (rough)

- New `CardKind` variant in `Shell.purs` (sibling of voice-cell
  card)
- Render function with a slider input bound to a state field
  keyed by the card's name
- `Action` variant for slider drag (`UpdateControlValue String
  Number`); handler emits `WsClient.send websock $ "set-control "
  <> name <> " " <> show value`
- Throttle / debounce slider updates so we don't flood the WS
  on every pixel of mouse movement (~60 Hz might be fine; ~10
  Hz is fine if 60 feels coarse)
- Optional: read current value back from `state` snapshot to
  initialise the slider position when the card first renders
  (vs always starting at 0)
