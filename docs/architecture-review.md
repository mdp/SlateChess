# Architecture Review — Deepening Opportunities

*2026-08-31, post-revert (`106dbf5`). Triggered by the failed strip/mode/refresh
batch: orchestration changes shipped to the Kindle that no test could catch.
Vocabulary follows `LANGUAGE.md` (module, interface, seam, adapter, deep,
shallow, locality, leverage); domain terms follow `CONTEXT.md`.*

## Headline

`CONTEXT.md`'s core invariant — *"the App owns all state transitions: every
change funnels through one transition step, which then derives everything
else"* — is **aspirational, not real**. There are ≥10 hand-rolled orchestration
sequences in `app.lua`, each deriving a different subset of derived state in a
different order, and two of the heaviest live inside dialogs, not the App at
all. That is the terrain where the revert happened, and it is all outside the
ADR-0002 test surface.

## Map of reality (summary)

- `app.lua` is 1,948 lines / ~55 methods. The "transition funnel" is
  re-implemented by hand in ≥10 places: `startGame`, `resetGame`,
  `finishGame`'s ConfirmBox, `handleUndoMove`/`handleRedoMove` (near-identical
  copy-pasted blocks), the PGN-load PathChooser callback, the settings
  `onApply` closure, `toggleBoardFlip`, and three engine event handlers.
- **Second controllers:** `ui/settings_dialog.lua` (lines 473–548, 645–693)
  writes 22 settings keys plus `parent.*` fields directly and drives layout
  rebuilds; `ui/interface_dialog.lua` does the same. A PathChooser callback
  inside `openLoadPgnDialog` is a third.
- **Known casualties in the current tree:**
  - PGN load never calls `launchComputerMove` — a loaded position with the
    computer to move sits dead.
  - Settings apply wipes the clock unconditionally (role-only change loses
    remaining time).
  - Difficulty presets mid-game write to `self.parent.weakening`
    (settings_dialog.lua:539) — a field name that no longer exists (App's
    field is `blunderer`), so the change is a silent no-op until next
    `startGame`.
  - Rotate-top-pieces is derived in **three places with three different
    formulas**: app.lua:1137 (raw setting), app.lua:813 (hvh-forced, via a
    direct field write that skips the board's own setter), and
    interface_dialog.lua:130 (hand-rolled hvh check).
- **Testing reality:** 8 spec files, ~90 `it()` blocks — all on `core/` and
  the pure sliver of `engine/`. Zero tests touch `app.lua`, `ui/board.lua`,
  `ui/settings_dialog.lua`, or the process-backed half of `engine/uci.lua`.
  The logic that just broke has 0% coverage; CI runs only `make test` +
  `make lint`. `player_strip_spec.lua` proves host-testing a UI widget with
  stubs is feasible and already done once.
- **Ghosting has architectural roots:** `board.lua` calls
  `setDirty("all", "ui")` from 8 sites (any selection repaints the whole
  screen), `Board:setFlipped` rebuilds the entire ButtonTable via full
  `init()` and callers still re-repaint after it, and `updateNotation` has 12
  call sites re-deriving independently.

---

## Candidates

### 1. Make the transition funnel real: a host-testable Game Presenter

**Files:** `app.lua` (~470 lines of orchestration), `ui/settings_dialog.lua`
(473–548, 645–693), `app.lua:1745–1777`.

**Problem:** Every entry point — start, reset, undo, redo, PGN load, settings
apply, engine handshake, bestmove — re-implements its own derive-and-repaint
sequence, each a different subset in a different order. None of it is
testable: ADR-0002 puts app.lua outside the test surface, so the logic that
keeps biting has zero coverage while the pure parts have 90 green specs.

**Solution:** Extract the orchestration into one deep, pure-Lua module (lives
in `core/`, satisfying ADR-0002): events in (`human_move`, `engine_bestmove`,
`undo`, `reset`, `mode_change`, `clock_flag`, …), one derivation step out —
face color, flip, rotate-top-pieces, whose clock runs, engine-should-move —
plus **effects** (UCI commands, repaints, scheduling, persistence) emitted
through injected adapters. KOReader specifics (`UIManager`, widgets, engine
process) become adapters at the seam. The 8 scattered search-flag fields
(`_go_kind`, `engine_busy`, `_analysis_active`, `_search_ply`, …) are the
machine's state and move wholesale. Divergent re-derivations (the three
rotate-top-pieces formulas) collapse to one.

**Benefits:** Locality — every bug from the last week becomes one fix in one
file, covered by `make test` on the host. Leverage — app.lua shrinks to
wiring; dialogs stop being controllers. The interface is the test surface, so
flip/mode/reset regressions become spec failures before install.

### 2. Board stops being a half-engine: rules logic out of the renderer

**Files:** `ui/board.lua` (963 lines), `core/game.lua`, `CONTEXT.md`
invariants.

**Problem:** `board.lua` violates two documented invariants: it requires the
vendored rules engine directly (`board.lua:6` — "never required directly by
UI code") and it **mutates game state** (`game:playMove`, board.lua:485 —
"UI widgets do not mutate game state"). It contains a 65-line re-implementation
of piece movement for all six piece types (`getOpponentPotentialMoves`,
692–756) that can silently drift from the real rules engine — a shallow module
whose interface is as complex as the thing it duplicates.

**Solution:** Extend the **Game facade** (already deep: position, history,
undo, PGN behind a small interface) with what the board needs: legal moves
from a square, squares attacked by a color, last-move/check data. The board
becomes a pure renderer: it reports a tap, renders what it's told, owns only
coordinate math and paint.

**Benefits:** Locality — rules changes can never desync between engine and
board because there is one implementation. Leverage — legality/attack logic
becomes host-testable through Game's existing spec. The renderer's interface
shrinks to "render position + decorations."

### 3. Settings: a schema module instead of 24 scattered keys and 5 write sites

**Files:** `app.lua` (338–372, 1706–1735), `ui/settings_dialog.lua` (3 write
clusters; interface keys written **twice in the same dialog**, 505–508 and
677–680), `ui/interface_dialog.lua`.

**Problem:** No key table exists; defaults are re-specified per read site
(`show_eval` default `true` appears 3×, `show_hints` default `false` 4×);
dialogs write 22 keys plus `parent.*` fields directly and then hand-trigger
partial re-derivations. This is why the settings dialog became a controller —
it has to know App internals to stay consistent. The stale `weakening` field
is a symptom: nothing pins names or defaults.

**Solution:** A deep settings module owning keys, defaults, types, and
persistence in one interface; dialogs edit a draft and submit one
`settings_change` event (which candidate 1's presenter consumes and derives
from). Delete the duplicated write clusters.

**Benefits:** Locality — a new setting is one line in the schema, not 5 sites.
Leverage — dialogs become trivial drafts; validation and migration live once.

### 4. Engine session: one state machine instead of 8 flags and raw UCI strings

**Files:** `app.lua:482–618, 1491–1601`, `engine/uci.lua`, `engine/process.lua`.

**Problem:** Search state is 8 loose App fields plus up to 4 concurrent
scheduled closures per search (retry, watchdog, inner give-up, delayed apply),
guarded only by comments. App bypasses the UCI event interface with raw
`engine.send("ucinewgame"/"isready"/setoption…)` at 6+ sites — the seam
`CONTEXT.md` mandates exists but leaks. Known hazards: `stop`→`ucinewgame`
pipelining is unguarded if the engine isn't handshaken; stale-bestmove
protection is a single guard line (app.lua:543).
`engine/process.lua` requires `ui/uimanager`, which is why only 5 tests exist
for this whole tier.

**Solution:** A deep engine-session module: interface is `new_game()`,
`analyze(position)`, `play(position, limits)` / `stop()`, with events out
(`bestmove`, `eval`, `ready`, `failed`). Internals own handshake state,
command queueing, timeouts, and engine protocol differences. An
in-process fake adapter for tests; the real process adapter for device.

**Benefits:** Locality — lifecycle bugs (double-search, stale bestmove,
mid-handshake sends) concentrate in one testable module. Leverage — App calls
three verbs; engine quirks stop leaking upward.

### 5. Orientation & geometry: five files to answer "which bracket is where"

**Files:** `app.lua:772–816, 849, 1027–1064`, `ui/board.lua:135, 863`,
`ui/player_strip.lua:62–83`, `ui/capture_gutter.lua:97–103`,
`ui/clock_panel.lua:87–95`, `ui/layout.lua`.

**Problem:** `layout.lua` is the model citizen (pure, spec'd) but the board
keeps its own fallback geometry path, and orientation is re-derived across
five widgets. `Board:setFlipped` does a full `init()` (rebuilds the entire
ButtonTable) and callers *still* re-repaint after it — double full-screen
repaints on e-ink, i.e. the ghosting has architectural roots, not just
dirty-flag fix roots.

**Solution:** One orientation value derived by the presenter (candidate 1)
becomes the single input; each widget is an adapter rendering for that
orientation. Board's fallback geometry dies; `setFlipped` repaints once.

**Benefits:** Locality — flip bugs land in one formula with one spec.
Leverage — widgets can't disagree about who's on top.

### 6. Debris sweep (quick wins, do anytime)

- `ui/overlay.lua` — fails the deletion test: required by nothing. Delete.
- `Eval.format` / `advantage_tag` / `capturedGlyphs` — production-dead but
  spec-pinned (tests defending dead code). Delete both sides.
- `clock_panel.fmt` duplicates `Clock.format` with a *different* format —
  pick one.
- `_pending_launch` (app.lua:601, 612) — written twice, read never. Delete.
- `ui/compat.lua`'s global monkey-patch of KOReader Button internals —
  fragile against upstream; revisit after 1–2.

---

## Sequencing

**Candidate 1 is the spine** — 3, 4, and 5 all plug into its event/effects
seam, and it is the direct answer to "how did a batch of untestable
orchestration changes reach the Kindle." Candidate 2 is the biggest
correctness win (rules drift). 6 is safe cleanup that shrinks the diff for
whichever big move comes next.

Nothing here contradicts ADR-0001 or ADR-0002 — both get *stronger* under
these changes.
