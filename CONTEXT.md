# SlateChess — Domain Model

Chess for KOReader e-ink devices. This file defines the project's domain
language. Use these terms exactly in code, comments, tests, and discussion.

## Glossary

- **Game** — the single chess game the player interacts with: position,
  move history, undo/redo, and who controls which color. Lives in
  `core/game.lua` behind a small interface; the vendored rules engine
  (`chess/src/chess.lua`) is an implementation detail.
- **Rules engine** — the vendored, closure-based port of chess.js. Pure
  Lua. Never required directly by UI code; everything goes through **Game**.
- **Arbiter** — the pure, host-testable orchestration module
  (`core/arbiter.lua`). Owns all state transitions: every change (human
  move, engine event, undo, reset, settings draft, timer tick) funnels
  through one transition step, which derives everything else (Face color,
  board flip, whose Clock runs, whether the Engine should move) and emits
  effects the App performs. Rules stay behind the Game facade — the
  Arbiter adjudicates the meta-game, never legality.
- **App** — the full-screen widget (`app.lua`). Performs what the Arbiter
  emits (UCI commands, repaints, scheduling, persistence) and renders the
  Arbiter's view. It no longer owns orchestration.
- **Face color** — which side the board renders for. Derived state, never
  set ad hoc: in human-vs-human play the board faces the side to move;
  otherwise it faces the human (white by default). Computed by the App at
  every transition, applied to the board in one repaint.
- **Roles** — per-color Human/Computer designation. Stored on the Game and
  persisted in settings.
- **Engine** — a computer opponent speaking UCI. One spawned binary behind
  one interface (`engine/`): **Berserk** ships by default; a Stockfish binary
  dropped into `engines/` is honoured as a stronger fallback. The App never
  knows which is active.
- **UCI** — Universal Chess Interface protocol. `engine/uci.lua` is the
  client; the engine talks `position … moves`, `go`, `bestmove`.
- **Blunder** — deliberate move degradation for lower difficulty: with
  probability *p* the engine's move is replaced by a random legal move
  (`core/blunder.lua`).
- **Clock** — the chess clock (`core/clock.lua`): per-color base time plus
  Fischer increment. Pure accounting; the App owns scheduling and display.
  Games are **untimed by default**; a Clock only exists when the game is
  **timed**.
- **Book** — the opening book (`data/aperturas.json`, ECO entries). The App
  matches played SAN moves against it to label the position (`core/openings.lua`).
- **Move log** — the scrollable SAN move list under the board.
- **Eval** — the engine's score for the current position, shown under the
  move log. Parsed from UCI `info` lines (`core/eval.lua`), always shown
  from White's perspective.
- **Notation** — static coordinate labels (ranks left, files bottom,
  White's view). They never move or flip; the layout reserves mirrored
  zones so the board stays centered.
- **Restore** — resuming the last game at startup: saved PGN + clock
  remaining time + running flag, stored in KOReader settings.

## SlatePuzzle glossary

- **SlatePuzzle** — the companion plugin shipped from this repo
  (`slatepuzzle.koplugin`, staged by `tools/stage-puzzle.sh`). Same board
  and rules engine as SlateChess; the app (controller + view) is
  `puzzle/app.lua` (staged as `puzzle_app.lua` to dodge the KOReader
  `require("app")` collision). No engine: the opponent replies come from
  the puzzle's own solution line.
- **Puzzle** — the session state machine (`core/puzzle.lua`), the
  puzzle-sided counterpart of the Arbiter: one transition verb, one view,
  canonical effects. Validates the solver's plies against the Lichess
  solution, auto-plays the opponent's replies, counts wrong moves, and
  re-filters on settings changes. The player is always the **solver** (the
  side opposite the FEN's active color); the opponent's losing lead-in
  blunder is applied when the puzzle loads so you start on your own winning
  move.
- **Bank** — the embedded puzzle collection (`data/puzzles.json`): compact
  records `{ id, fen, moves, r, t }`, regenerated from the official Lichess
  DB by `tools/fetch-puzzles.sh` + `tools/convert-puzzles.lua`.
- **Puzzle type** — the practice focus, one pick from the curated catalog
  (`core/puzzle_types.lua`): Random, mates, tactics (fork, pin, …), mating
  patterns, phases, specific endgames, pawn play, and openings by name.
  Matchers are pure and shared between the app and the bank builder, so
  the UI and the data can never drift. Persisted as `puzzle_type`.
- **Stratified sampling** — how the bank is built: per-type quotas
  guarantee every catalog type a usable count even when its theme is rare
  in the raw DB (see `docs/puzzle-design.md`).

## Architecture invariants

- `core/` is **pure Lua** — it must load and run with plain `lua`/`luajit`
  and have zero `require("ui/...")`, `logger`, or `Device` references.
  This is the test surface: `make test` (busted) runs against `core/` and
  the pure parts of `engine/` on the host. See
  [ADR-0002](docs/adr/0002-core-is-pure-lua-test-surface.md). The Arbiter
  is pure under the same rule; its spec (`spec/arbiter_spec.lua`) is part
  of the test surface.
- **The Arbiter computes derived state; the App writes it.** Face color,
  flip, whose clock runs, engine-should-move, and the contents of the
  strips/clocks are decided in one transition step and handed to the App
  as a view. UI widgets render what they are told; they do not mutate
  game state and no orchestration logic lives outside the Arbiter.
- Every effect the Arbiter emits (UCI command, schedule/cancel, repaint,
  persist, dialog) is performed by the App through one dispatcher; the
  App does not decide *what* to do, only *how*.
- Engine selection is a **seam**: Berserk and any UCI binary (e.g. Stockfish)
  satisfy the same event interface (`uciok`, `bestmove`, `process_error`,
  timeouts). One adapter per implementation; the App wires handlers
  identically for both.
- The rules engine is **vendored** (not a submodule); all access goes
  through the Game facade. See
  [ADR-0001](docs/adr/0001-vendor-the-chess-rules-engine.md).
