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
- **App** — the full-screen widget and controller (`app.lua`). Owns all
  state transitions: every change to game state funnels through one
  transition step, which then derives everything else.
- **Face color** — which side the board renders for. Derived state, never
  set ad hoc: in human-vs-human play the board faces the side to move;
  otherwise it faces the human (white by default). Computed by the App at
  every transition, applied to the board in one repaint.
- **Roles** — per-color Human/Computer designation. Stored on the Game and
  persisted in settings.
- **Engine** — a computer opponent speaking UCI. One spawned binary behind
  one interface (`engine/`): **chal** ships by default; a Stockfish binary
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

## Architecture invariants

- `core/` is **pure Lua** — it must load and run with plain `lua`/`luajit`
  and have zero `require("ui/...")`, `logger`, or `Device` references.
  This is the test surface: `make test` (busted) runs against `core/` and
  the pure parts of `engine/` on the host. See
  [ADR-0002](docs/adr/0002-core-is-pure-lua-test-surface.md).
- The **App is the only writer** of derived state (face color, status bar,
  move log, eval line). UI widgets render what they are told; they do not
  mutate game state.
- Engine selection is a **seam**: chal and any UCI binary (e.g. Stockfish)
  satisfy the same event interface (`uciok`, `bestmove`, `process_error`,
  timeouts). One adapter per implementation; the App wires handlers
  identically for both.
- The rules engine is **vendored** (not a submodule); all access goes
  through the Game facade. See
  [ADR-0001](docs/adr/0001-vendor-the-chess-rules-engine.md).
