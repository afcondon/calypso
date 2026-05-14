# Shell.purs refactor plan (2026-05-14)

Goal: split the 3492-line `frontend/src/Calypso/Frontend/Shell.purs` monolith into per-pane modules. Remove the legacy Cells pane as part of the work.

This doc captures the survey + execution plan. Written before surgery so it survives any context compaction and so future-Claude (or anyone) can pick up cleanly mid-flight.

## What's in Shell.purs today

### High-level structure

| Lines | What |
|---|---|
| 1–500 | Imports, type definitions (`CellRec`, `Section`, `ColumnKey`, `ColumnVisibility`, helpers) |
| 346–490 | `type State` (the main record) |
| 491–505 | `type Slots` (existing child components) |
| 506–640 | `data Action` ADT |
| 641–~1940 | `handleAction` (~1300 lines, ~80 action arms) |
| 1949–2315 | Top-bar / header / widget render functions (10 of them) |
| 2316–3416 | Per-pane render functions (8 panes) |
| 3416–end | Misc (renderErrorPanel, utility renders) |

### The 8 panes (ColumnKey + render functions)

| ColumnKey | Render function | Lines | Notes |
|---|---|---|---|
| `KeyComposition` | `renderCompositionColumn` | 2316–2358 | Module source editor; uses CodeMirror slot |
| `KeyCells` | `renderCellsColumn` + `renderCellRow` | 2359–2473 | **LEGACY — DELETE during refactor** |
| `KeyHylograph` | `renderHylographColumn` + `renderHylographRow` | 2474–2488, 3404–3415 | Placeholder for pattern visualiser |
| `KeyReplies` | `renderRepliesColumn` | 2489–2540 | Daemon reply log |
| `KeyVocabulary` | `renderVocabularyColumn` + `renderVocabularyBody` | 2541–2558 | Auto-derived vocab reference |
| `KeyMiniNotation` | `renderMiniNotationColumn` | 2559–2584 | Mini-notation cheatsheet |
| `KeyVoiceCells` | `renderVoiceCellsColumn` | 2585–3354 | **~770 lines — the primary editing surface; biggest single chunk** |
| `KeyConfig` | `renderConfigColumn` + `renderSetupFile` + `renderBinding` | 3355–3403 | Read-only StateBus snapshot |

### The 10 top-bar / widget render functions

| Function | Lines | Purpose |
|---|---|---|
| `renderPenBanner` | 1949 | "Pen" banner (collaboration indicator?) |
| `renderClkReminder` | 1967 | Clock-source toast (first-fire-per-session) |
| `renderSettingsPanel` | 1988 | Settings popover |
| `renderHeader` | 1997 | Topbar container |
| `renderBpmWidget` | 2199 | BPM input + commit |
| `renderTitlePen` | 2214 | Title strip with Pen indicator |
| `renderViewToggle` | 2255 | Pane visibility toggle bar |
| `renderFavoritesDropdown` | 2275 | Favourites dropdown |
| `renderFavoriteOption` | 2302 | Single favourite option in dropdown |
| `renderErrorPanel` | 3416 | Compile/runtime error display |

### The State record (line 346)

Large flat record. Some fields used by one pane only, others cross-cutting. Notable groups:

- **Composition-specific**: `moduleSource`, `compositionStatus`, `compositionFireLines`
- **Cells/Voice Cells**: `cells`, `nextCellId`, `cellResults`, `cellRanges`, `cellTypes` (and per-card UI state: `stackOrder`, `fannedStack`, `editingCard`, `colorPickerOpen`, etc. — many fields)
- **Vocabulary**: `vocabulary`, `completions`
- **Favourites**: `favorites`, `favoriteKey`, `favoriteMenuOpen`
- **Transport / runtime**: `runtime`, `transportError`, `runtimeError`
- **Config snapshot**: `configSnapshot`, `tvoiceTypeByName`
- **UI state**: `settingsOpen`, `compiling`, `errors`, `warnings`, `clkReminder`, `clkReminderShown`
- **Pane visibility**: implicit via URL query, materialised as `ColumnVisibility`

This record is the main coupling point. Any refactor strategy has to decide what to do with it.

## Decomposition strategy — two options

### Option A: True Halogen child components

Each pane becomes a separate Halogen component:

- Own `State` (subset of the global state, what the pane actually needs)
- Own `Action` (input messages, including state-syncs from parent)
- Own `Output` (events the pane emits up to Shell)
- Own `Render`
- Wired into Shell via Halogen `Slots` + `slot` calls

Pros:
- Real isolation; panes are independently understandable, testable, evolvable
- Future-flexible; a pane could in principle be hot-swapped or A/B'd
- Each pane's state lives where it's used; no temptation to reach across

Cons:
- Substantial up-front surgery on `State` (partition into per-pane records + cross-cutting shared state)
- All inter-pane communication moves through `Output` events / parent-driven `Input` updates
- More code overall (Halogen component boilerplate per pane)
- Hard to do incrementally — partial migration leaves a state model in two shapes

### Option B: Extract per-pane render functions into modules

Each pane gets a module that exports `render :: State -> H.ComponentHTML Action Slots m`. Same `State`, same `Action`, same `Slots`. Just the *render functions* extracted into named files.

Pros:
- Minimal disruption — Shell stays the coordinator, imports per-pane renderers
- Fast to execute (per-pane extraction is mechanical)
- Easy to do incrementally and verify each step

Cons:
- Not "real" Halogen decomposition — panes still share the same monolithic State
- Coupling stays high; the refactor is a file-split, not an architectural improvement
- The 3492 lines becomes 8 files of ~400 lines each, but the global State type and Action ADT stay where they are

### Recommended: Option C — Phase 1 = Option B, Phase 2 = Option A

Do Option B first as the immediate refactor. Get a clean per-pane module layout where each pane's render lives in its own file. Action handling stays in Shell. State stays shared.

Then, as a separate later effort (out of scope for this session), migrate each pane to a true child component (Option A) — extracting its slice of State, its own Action sub-ADT, its Output events. This can happen pane-by-pane over multiple sessions, prioritising panes that benefit most from isolation (Voice Cells especially — it's the biggest and most actively evolving).

**Why C over A directly:** The State record's shape isn't yet clear enough to partition cleanly. Voice Cells has lots of UI state today; some of it may want to live in Shell (e.g., armed-module tracking that affects Replies pane). Until we work in the code post-extraction, we don't have the seam-evidence to do A confidently. Option B gives us the per-pane visibility without committing to a state shape that may shift.

**Why C over B alone:** Without an eventual Phase 2, "Halogen components" remain in name only — they're just render functions in different files. That's still better than the monolith but doesn't capture the user's intent of true isolation.

## Phase 1 execution sequence

Each step is one commit. Build verified after each.

### Step 1 — Delete the legacy Cells pane (pure subtraction)

- Remove `KeyCells` from `ColumnKey` and `allColumnKeys`
- Remove `showCells` from `ColumnVisibility`, `allVisible`, `defaultVisibility`
- Remove the corresponding cases from `isVisible`, `toggleKey`, `columnKeyLabel`, `columnKeyToken`, `visibilityFromHide`, `hideFromVisibility`
- Delete `renderCellsColumn` and `renderCellRow` (lines 2359–2473)
- Remove the call site in the main `render` function
- Remove any `KeyCells`-specific keyboard shortcut handling
- Build + check that Voice Cells still renders the cells correctly (it's already the canonical view)

**Estimate:** 1 commit, ~30 lines of code touched (subtraction), ~115 lines deleted.

### Step 2 — Establish the new module structure

Create the directory and an initial empty barrel:

```
frontend/src/Calypso/Frontend/Panes/
  ├─ Composition.purs
  ├─ Replies.purs
  ├─ Vocabulary.purs
  ├─ MiniNotation.purs
  ├─ Hylograph.purs
  ├─ Config.purs
  └─ VoiceCells.purs
```

Plus a sibling `Widgets/` dir for the top-bar / header chunks:

```
frontend/src/Calypso/Frontend/Widgets/
  ├─ Header.purs        -- renderHeader + topbar container
  ├─ TitlePen.purs      -- renderTitlePen
  ├─ BpmWidget.purs     -- renderBpmWidget
  ├─ ViewToggle.purs    -- renderViewToggle
  ├─ Favorites.purs     -- renderFavoritesDropdown + renderFavoriteOption
  ├─ PenBanner.purs     -- renderPenBanner
  ├─ ClkReminder.purs   -- renderClkReminder
  ├─ Settings.purs      -- renderSettingsPanel
  └─ ErrorPanel.purs    -- renderErrorPanel
```

(Naming is a sketch; can iterate as we go.)

In each new module: `module Calypso.Frontend.Panes.<Name> (render) where` + the relevant imports + the function copied verbatim from Shell.purs. No semantic change.

In Shell.purs: import the new module's `render` and call it.

**Critical:** every pane's render function references `State`, `Action`, `Slots` — these stay defined in Shell.purs (or in a new `Calypso.Frontend.Shell.Types` module). The per-pane modules import them; they don't redefine.

**Estimate:** 7 pane modules + 9 widget modules = 16 commits if extracted individually, or 2 commits (one for panes, one for widgets) if batched. Recommend individual: each commit small, easy to verify.

### Step 3 — Move shared types into a Types module

After extracting renders, Shell.purs imports its own `State` / `Action` / `Slots` definitions from the new pane modules. The natural next step: lift those into `Calypso.Frontend.Shell.Types` so the dependency direction is clear (Types → panes → Shell, not panes → Shell circularly).

**Estimate:** 1 commit. Mechanical.

### Step 4 — End-state verification

After all extractions:
- `Shell.purs` shrinks to: `module Calypso.Frontend.Shell` + the coordinating component definition + `handleAction` + glue. Probably ~1500 lines (handleAction stays the giant chunk, but is at least no longer interleaved with rendering).
- Each `Panes/*.purs` is 50–800 lines (Voice Cells the outlier).
- Each `Widgets/*.purs` is 20–150 lines.
- `Shell/Types.purs` is ~200 lines.
- Total LOC roughly the same; locality is dramatically better.

## Risks

**Build breakage between extractions.** Each step compiles before moving on. If a step breaks, fix or revert before the next.

**Slots type coupling.** The `Slots` type uses Halogen `SProxy` keys and may reference component types from `Editor.purs`, `CodeMirror.purs`, etc. Extracted pane renders still need to mention these slots. Likely won't cause a problem but worth being alert during Step 2.

**Action ADT coupling.** Every pane render emits actions via `HE.onClick \_ -> Action`. The `Action` ADT stays in Shell (or Types). Pane modules import it. No semantic change but lots of import lines.

**Voice Cells is huge.** 770 lines is the biggest single extraction. Worth its own commit and careful verification. May benefit from being split internally (cards, stacks, modal editor wiring) as a follow-up, but that's beyond Phase 1.

## What Phase 2 (later, not now) would look like

Per-pane true child components, in an order driven by need-for-isolation:

1. **Voice Cells** first — most state, most active evolution, biggest payoff from isolation. Likely needs its own `Output` events (cell-fire, cell-cue, cell-edit-open) that Shell consumes and dispatches to the runtime.
2. **Composition** — second-largest editing surface; state interaction with Replies via the per-line fire log.
3. **Config** — read-mostly; small Output surface; easy migration target.
4. **Replies, Vocabulary, MiniNotation, Hylograph** — display-only; small state; low payoff but easy.

Each Phase 2 step is a separate session (or multiple). Not in scope today.

## Test plan

The Calypso build is `make bootstrap` (per `README.md`). After each extraction step:

```
cd /Users/afc/work/afc-work/music/live-coding/calypso
spago build       # PureScript compile
spago bundle     # frontend bundle (if reordering matters)
```

Then bounce Calypso (kill backend pids, hit `:3061` to respawn) and verify the UI looks unchanged.

Visual smoke test: every pane should render exactly as before. Cmd-1..Cmd-8 keyboard shortcuts still work. View-toggle bar still toggles. No console errors.

## What's not in scope

- Phase 2 (true child components)
- Action ADT cleanup (some action arms are likely dead; not pruning during the move)
- State record reorganisation (stays flat for now)
- handleAction refactor (stays a single big function in Shell)
- Tidal.Expr removal (separate work, separate doc)
- Path-4 removal (separate work, separate doc)
- Any behavioural change at all (this is purely a code-organisation refactor)

The goal is to land Phase 1 cleanly so that subsequent work (Phase 2, Tidal.Expr removal, the round-tripping design, etc.) has a less daunting code surface to operate on.
