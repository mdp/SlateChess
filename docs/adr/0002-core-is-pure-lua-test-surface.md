# ADR-0002: core/ is pure Lua — the test surface

Status: accepted, 2026-08-30

## Context

All game logic (rules facade, clocks, eval formatting, opening book,
blunder injection) previously lived inside `main.lua`, a 1360-line KOReader
widget. None of it could run without a full KOReader environment, so none
of it was tested; bugs (e.g. the blunder damper appending `q` to every
weakened move) surfaced only on device.

## Decision

- `core/` contains the rules facade (Game), clock, eval, openings and
  blunder modules. They must load and run under plain `lua`/`luajit` with
  zero KOReader requires. Impurity (time source, RNG, JSON decoder, UI
  scheduling) is injected through constructor parameters.
- Tests (`spec/`, busted) run on the host via `make test` and in CI.
- KOReader-specific code (widgets, scheduling, subprocess) lives in
  `app.lua`, `engine/` and `ui/` and stays untested on the host; it is kept
  thin and verified in the emulator.

## Consequences

- New game logic goes into `core/` with tests; the App only orchestrates.
- Engine results must not be trusted from UI-level reasoning alone —
  the clock and eval math are proven by `spec/clock_spec.lua` and
  `spec/eval_spec.lua`.
