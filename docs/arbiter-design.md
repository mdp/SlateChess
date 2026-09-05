# Arbiter — Design Contract

*Status: chosen direction, 2026-08-31. Rooted in
[`docs/architecture-review.md`](architecture-review.md) candidate #1
(mid-grill). Vocabulary per `CONTEXT.md` and `LANGUAGE.md`.*

*Implementation: all six migration stages below are landed (island +
spec, App wiring, wholesale port, search machine, stragglers, lint gate)
as of 2026-08-31; the tree lints clean and `spec/arbiter_spec.lua`
pins the machine. See `CHANGELOG.md` for the sequence.*

## What and why

`core/` gains one deep module — the **Arbiter** — that owns game-flow
orchestration and derived-state derivation. Today that job is a hand-rolled
convention scattered across ≥10 sequences in `app.lua` (start, reset,
finish, undo/redo pairs, PGN-load callback, settings onApply, flip) plus two
writing directly from `ui/settings_dialog.lua`. Every one re-derives a
*different subset* of derived state in a *different order*, none of it is
host-testable, and the last batch of changes there reached the Kindle
broken.

The Arbiter is the state-transition funnel `CONTEXT.md` always claimed.
Rules stay behind **Game** (ADR-0001): the Arbiter adjudicates the
meta-game — whose face bottoms the board, whose Clock runs, whether the
Engine should move, when a search result is stale, who wins on time — never
legality.

## Shape: Design A + four grafts

Chosen shape is Design A — a minimal, stateful machine with one verb
(`transition(event)`), one read (`view()`), and composition over
injection — grafted with:

1. **Flat, ordered effects** (from C/D) — a single effect list whose
   cross-kind order is canonical, not parallel arrays that lose ordering.
2. **Id-keyed search correlation** (from D) — every `go` emits an id; the
   engine bestmove echoes it; stale ids are dropped. Replaces the `_go_kind`
   routing and the single guard-line stale-bestmove protection.
3. **One view snapshot** (from D) — `view()` returns one model table the App
   renders against, collapsing the 12 `updateNotation` call sites'
   descendants.
4. **Lint gate on `core/`** (from B) — luacheck std whitelist so `os.*`,
   `math.random` (outside the injected `deps.rng`), and
   `require("ui/...")` fail `make lint` before reaching a device.

Scope: this subsumes architecture-review **candidate #4** (the search
state machine is the Arbiter's machine — splitting it later would force two
modules to share `pending`/token state across an interface) and takes over
the *parts* of **#3** (settings keys/defaults owned once) and **#5**
(orientation derived once, consumed by every widget) that are derivation,
not geometry.

## Interface

```lua
local Arbiter = require("core.arbiter")

local ar = Arbiter:new(cfg, deps)   -- compose once
local fx = ar:transition(event)     -- reducer: adopt new state, emit effects
local v  = ar:view()                -- pure projection of state, fresh each call
```

### Constructor

- `cfg` — one-time snapshot read from the settings store by the App:
  roles (`human_white`, `human_black`), `timed` + time control
  (`time_base_*`, `time_incr_*`), engine limits (`skill_level`,
  `engine_depth`, `engine_movetime`, `blunder_chance`, `min_move_delay`),
  display prefs (`flip_board`, `rotate_top_pieces`, `show_eval`,
  `show_hints`, `figurine_pgn`, `thinking_indicator`, board flag subset),
  **Restore** payload (`saved_pgn`, `saved_time_*`, `saved_running`), and
  the parsed opening **Book**.
- `deps` — exactly `{ now = function() -> seconds, rng = function() -> [0,1) }`.
  The only injected impurities, matching ADR-0002's existing Clock/Blunder
  injection.
- **Composed, never injected:** `Game`, `Clock`, `Blunder`, `Eval`,
  `Openings` are `require`d directly (dependency category 1). The vendored
  rules engine stays sealed behind **Game**.

### State and view: React-style separation

State and view are two pure layers, shaped like a reducer and a renderer.

- **State** (`core/arbiter.lua` internals) holds only ground truth — what
  cannot be derived: the composed `Game`/`Clock`, roles, `running`, the
  search record, pending launches, engine readiness, the settings snapshot.
  `running` mirrors the Clock's own accounting (the one conjunction today
  written at 7 App sites). Nothing derived is ever cached in state.
- **View** — `view()` is a *pure projection* `state → view model`, computed
  fresh on every call, never stored. All content (SAN lines, eval text,
  hints, opening name, captured counts, clock strings) is produced here by
  mapping state — never by transition writers emitting presentation
  strings, never by widgets deriving. The App's render adapter is a dumb
  map from view model to widgets: props in, render.
- **Re-render is a diff (reconciliation).** The transition compares the
  previous view model with the new one and emits `repaint{target}` only for
  what changed (`board`, `clocks`, `notation`, `layout`). Event handlers
  never say "repaint clocks" — the projection diff does. Incremental e-ink
  repaint (the ghosting concern) falls out for free and can never drift
  from the logic.

Because the view is a pure function of state, every flow is spec'd as two
assertions: the emitted effect list and the projected view model. Specs
never reach for machine internals.

### Events (`transition(event)`)

| Event | Payload | Meaning |
|---|---|---|
| `start` | `restore = {pgn, t_w, t_b, running} \| nil` | boot; fresh or restored game |
| `reset` | — | new game / Continue-after-game-over |
| `resume` | — | restart play after a reset when a computer is on move (nothing if a human is on move) |
| `human_move` | `{from, to, promotion?}` | human or promotion completion |
| `pgn_loaded` | `{pgn}` | PGN file loaded (already read by App) |
| `undo` / `redo` | `{all?}` | take back / redo move(s) |
| `settings` | `{changes = {...}}` | one submitted draft from any settings dialog |
| `flip_toggle` | — | flip Board preference |
| `engine_ready` | — | uciok |
| `engine_restart` | — | diagnostics restart: clear the outstanding search, drop to `"starting"` |
| `engine_info` | `{line}` | UCI info line (eval/hints capture) |
| `engine_bestmove` | `{id, move}` | go id echo + move/analysis result |
| `engine_failed` | `{reason}` | process_error / uci_timeout |
| `search_timeout` | `{detail}` | go_timeout |
| `scheduled` | `{token}` | a timer the machine asked for fired back |
| `save_requested` | — | exit: persist Restore keys |

Stale events (bestmove/timeout/failure after undo, reset, resign) are
dropped by `id`/`ply`/`token` — a tested behaviour, not a guard line.

### Effects (`view()` + emitted list)

`transition` returns a flat, ordered list, canonical across kinds:

```
[persist*] [uci*] [cancel*] [schedule*] [repaint*] [announce*]
```

Order within a kind is preserved; cross-kind order is load-bearing
(`cancel` before its replacement `schedule`; `persist` before a repaint
that reads the setting).

- `{kind="persist", key, value}` — settings write (the only writer of
  settings keys).
- `{kind="uci", cmd="setoption"|"ucinewgame"|"position"|"go"|"stop"|
  "isready"|"quit", ...}` — engine command; `go` carries an `id` echoed
  back by `engine_bestmove`.
- `{kind="schedule", token, delay}` — App schedules and re-enters
  `{kind="scheduled", token}`; the machine validates the token against its
  registry, so cancellation is `cancel` effects and stale firings are
  no-ops. The App never decides *which* closure to cancel.
- `{kind="cancel", token}`.
- `{kind="repaint", target="board"|"clocks"|"notation"|"layout"|"all"}`
  — derived from the old-vs-new view diff (React-style reconciliation),
  never decided by event handlers.
- `{kind="announce", announce_kind="game_over"|"engine_failed"|"error", text}`.

`view()` returns one model table — a pure projection of state, computed
fresh on every call (never cached):

```lua
{ face_color,          -- side the board renders for; follows the mover
                       -- only in hvh with flip_pieces_each_turn on
  flipped,             -- black's side at the bottom?
  white_at_bottom,
  rotate_top_pieces,   -- hvh: on unless flip_pieces_each_turn; else pref
  running,
  whose_clock,         -- nil | color
  clock_active_color,  -- nil | color
  engine_should_move,
  engine_state,        -- "starting" | "ready" | "failed"
  thinking,            -- thinking indicator visible? (3s reveal latch)
  game_over,           -- status \| nil
  notation_lines,      -- two history rows of SAN text
  eval_text,           -- eval line (advantage + opening name)
  hints_text,          -- Engine Hints line
  captured,            -- {white, black} taken-piece counts
  clock_times,         -- {white, black} remaining
  can_undo, can_redo }
```

(vs. the early sketch's nested `notation` object: the implementation
flattens the notation block into `notation_lines` / `eval_text` /
`hints_text` / `captured`, since the render adapter splats exactly those
strings.)

## Invariants a caller must know

1. **Single writer.** After `new`, nothing mutates the **Game**, the
   **Clock**, or derived state except `transition`. Dialogs submit drafts;
   they never write `parent.*` or call App re-derivation methods.
2. **Total and deterministic.** `transition` never raises, never performs
   IO; effects are a pure function of `(state, event, deps.now, deps.rng)`.
   Host tests control all four.
3. **UCI ordering is causal** — `setoption → ucinewgame → position →
   isready → go`; **one `go` at a time**. A search wanted while analysis
   holds the engine becomes a deduped retry `schedule`, never a second go.
4. **Stale events are dropped by identity** — `id` (go), `ply` (eval
   commit), `token` (timers). Late bestmove/timeout/failure after
   undo/reset are no-ops.
5. **No silent dead engine.** Every position-changing transition re-derives
   `engine_should_move`; a flip to true with the engine not yet handshaken
   sets a *pending launch* drained on `engine_ready`. (Fixes the load-PGN
   dead-position bug by construction.)
6. **Clock exists iff timed.** `view().clock_times` is nil-safe; the Clock
   is only ever re-based when the time control actually changed (roles-only
   applies preserve remaining time).
7. **Effects are canonical-ordered** and the App applies them in order.
8. **Promotion** is resolved by the board before the event; the Arbiter
   never opens dialogs.
9. **`pgn_loaded` failure is atomic** — returns the old game intact
   (`ok=false` surfaced as an `announce`).
10. **View is a pure projection.** `view()` maps state → view model,
    computed fresh every call, never cached — derived state cannot go
    stale, and repaint targets come from diffing consecutive projections.

## What the implementation hides

- **The single derivation step** — the ≥10 divergent sequences collapse
  into one internal transition: mutate by the event's meaning, derive
  everything, diff old vs new view, emit effects.
- **The view projection** — `project(state)` is a separate pure function
  mapping state → view model; all content strings are produced here, so
  transition writers emit nothing presentational and widgets derive
  nothing.
- **The search state machine** — the 8 loose App fields (`engine_busy`,
  `_go_kind`, `_analysis_active`, `_analysis_ply`, `_search_ply`,
  `_search_retry`, `_search_started_at`, `_search_watchdog`, plus dead
  `_pending_launch`) fuse into one record `{id, kind="search"|"analysis",
  ply, started_at}` + the token registry. Retry-vs-analysis backoff
  (0.3s), watchdog budget (`timed and 30 or movetime+6`), give-up
  escalation, `MIN_ENGINE_MOVE_DELAY` pacing, and the 3s thinking reveal
  are machine constants.
- **Clock tick / flag-fall policy** — when a clock runs, the 1s ticker is
  a machine `schedule`; `expired()` triggers the finish sequence and the
  "wins on time" announce.
- **UCI option policy** — the skill-20/MultiPV-2 analysis vs
  skill-degraded/MultiPV-1 move-search split; engines missing multipv tokens
  is sealed inside (routed by `kind`, never a raw flag).
- **Pending-launch memory** — computer on move while `engine_state ~=
  "ready"` → remembered; drained on `engine_ready`. Restore and PGN load
  get the same treatment, once.
- **Persistence** — keys, defaults, validation for all 24 settings keys,
  owned once; writes leave as `persist` effects on the transitions that
  must write.
- **Eval/hint capture and ply-guarded commit** — `engine_info` lines parse
  only while a matching search is outstanding and commit only if the ply
  still matches.
- **Blunder application** — `applyEngineMove`'s maybe-Weaken-then-play
  moves in, host-testable with scripted `deps.rng`.

## What the App keeps (adapters)

- The engine **process** lifecycle (spawn, SIGTERM→SIGKILL teardown) and
  the engine-adapter: apply `uci` effects to `UCIEngine`, forward engine
  events as `transition` events, echo the `go` id on bestmove.
- The **scheduler** adapter: `schedule`/`cancel` effects → token→timer map,
  re-entering `{kind="scheduled", token}`.
- The **persist** adapter (`setSetting` / flush).
- The **repaint** adapter: render widgets from `view()`; `relayout` rebuilds
  geometry via `ui/layout.lua`.
- The **announce** adapter: game-over ConfirmBox ("Continue" →
  `{kind="reset"}`), engine-failure, error messages, about/promotion
  dialogs.
- All file IO, widget painting, and dialogs that read files (load/save PGN,
  promotion) stay App-side; the Arbiter receives only the parsed content.

## Tests (`spec/arbiter_spec.lua`)

Driven through the same seam as production: real `Game`/`Clock`, recording
effect list, stepped `now`, scripted `rng`, manual `scheduled` re-entry.
Assertions on the projected view model and the emitted effect list,
including repaint targets (asserting the diff — e.g. a move repaints
`board`+`notation`, not `clocks`, when untimed).

The three live bugs become regression specs first:

1. `pgn_loaded` with the computer to move **does not sit dead** — emits
   `go` now, or a pending launch drained by `engine_ready`.
2. `settings` that only change roles **keep clock remaining times**.
3. Difficulty preset mid-game **reaches the Blunder** (the stale
   `weakening` field dies).

Plus: start ordering (uciok → options → ucinewgame → position → go), one-go-
at-a-time (search behind analysis → retry), stale bestmove after undo
dropped, undo returns abandoned time, flag finishes cleanly, hvh piece
orientation (face + flip derivations, `flip_pieces_each_turn` opt-in to the
per-turn pivot), restore-with-engine-not-ready drains on uciok.

## Migration sequencing (each stage green before the next)

1. **Land the island.** `core/arbiter.lua` + `spec/arbiter_spec.lua` green
   against a transcript of *current app.lua behavior* (the migration net) —
   no app.lua changes yet.
2. **Point the inbound wires.** Engine handlers → `transition` events;
   board tap → `human_move`. Old orchestrators still run; nothing is
   deleted yet.
3. **Port flows wholesale, delete old bodies in the same commit:**
   settings applies (kills the dialog controllers), undo/redo, reset/
   finish, restore.
4. **Search machine last** (biggest blast radius: `wireEngineHandlers`,
   `launchSearch`, `launchAnalysis`, watchdogs, thinking indicator).
5. **Delete the stragglers** — `restoreGameState`, the PGN-load callback,
   `toggleBoardFlip`'s rebuild, `saveGameState`, and debris
   (`_pending_launch`, dead fields).
6. **Add the lint gate** to `core/` before the island lands, so every step
   already runs under it.

Hard rule learned from the revert: **no batch — including this one —
reaches the Kindle without a green `make test` under the new surface, and
never while old orchestration still coexists untested.**
