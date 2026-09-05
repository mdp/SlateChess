# Changelog

All notable changes to SlateChess. The format is Keep a Changelog-ish;
newest first. SlateChess is a fork of Casual Chess for KOReader — see
LICENSE for the full attribution history.

## [1.1.0] - 2026-09-05

### Adaptive puzzle difficulty
- New puzzle profiles start in **Adaptive** mode at 1200. Puzzles stay within
  ±150 rating points; clean first-try solves raise the persisted player rating,
  while mistakes, hints, and skipped unfinished puzzles lower it using a
  standard Elo update. The puzzle HUD shows the current `YOU` rating.
- The original Any, Easy, Normal, Hard, and Expert choices remain available.

### Replace Chal with Berserk
- Berserk is now the bundled UCI engine, built from a pinned upstream revision
  and verified NNUE network. Native arm64/x64 and static 32-bit Kindle ARM
  builds are supported; Stockfish remains an optional fallback.

### SlatePuzzle: quality-filtered 12k bank + the full theme catalog
- The bank builder (`tools/convert-puzzles.lua`) now keeps the human-vetting
  columns the DB publishes — **Popularity** (`p`) and **NbPlays** (`pl`) —
  and gates every record on them: by default puzzles with fewer than
  `MIN_PLAYS` (20) solves or a negative vote score are skipped, as are
  unrung ratings (`MAX_RD`). Both gates tune via env knobs
  (`MIN_PLAYS`, `MIN_POPULARITY`, `MAX_RD`) next to the existing
  `RATING_MIN`/`LIMIT`/`QUOTA_SCALE`.
- Sampling is strictly stratified: all typed catalog quotas are filled
  first; a fallback pool only tops the bank up toward `LIMIT` afterwards,
  so a 12k bank no longer starves the rare mate patterns. `core/puzzles`
  passes the new `p`/`pl` fields through (`Puzzles.quality`) and still
  tolerates banks built without them.
- The catalog (`core/puzzle_types.lua`) now mirrors Lichess's full theme
  vocabulary: new **Goals** (equality · advantage · crushing · mate) and
  **Lengths** (oneMove · short · long · veryLong) groups, and the complete
  named-mate family (balestra · blind swine · corner · double bishop ·
  dovetail · epaulette · hook · kill box · Pillsbury · Morphy · swallow's
  tail · triangle · Vuković); every type carries a one-line `desc` shown in
  the picker.
- `tools/fetch-puzzles.sh` no longer clobbers a reused source file when it
  doubles as the output path (`OUT=` now disambiguates).
- Bank regenerated from the 2026-08 DB: **12,000 puzzles / ~2.5 MB**, all
  quotas met.

### SlatePuzzle: fix Lichess move semantics — you always play the winning side
- The Lichess DB stores each puzzle as `[opponent's lead-in blunder] + the
  solver's winning line`: the FEN is the position BEFORE the opponent's
  decisive move, and the solver is the side OPPOSITE the FEN's active
  color (confirmed against `lichess.org/api/puzzle/<id>`). The app
  previously put the player on the FEN side, so classic rows like 05zdL
  ("mate in 1" tagged) made you play the LOSER — you could "solve" a
  puzzle where you'd been mated, and black-winning forks/pins looked like
  white's.
- The player is now always the **solver**, the board flips to their side
  to move, and the opponent's losing blunder is applied up front — you
  start exactly where lichess.org starts you (on your winning move).
- Added an **outcome quality gate** to the pipeline: `core.puzzle` and
  `tools/convert-puzzles.lua` replay the recorded line and skip rows whose
  solver is mated, draws, or ends clearly worse. The bank was regenerated
  from the DB (8010 rows, ~17 s, all catalog quotas still met).

### SlatePuzzle: real puzzle bank + a puzzle-type dropdown
- The embedded bank is now **8,041 real Lichess puzzles (~1.6 MB)**, built
  by a rewritten offline pipeline (`tools/fetch-puzzles.sh` →
  `tools/convert-puzzles.lua`) that **stratifies by puzzle type**: every
  catalog type is guaranteed a target count, so even rare themes
  (underpromotion, smothered/Anastasia/Arabian mates, en passant, …) have
  a usable pool. Fixes the converter's parsing of the real CSV — Themes and
  OpeningTags are space-separated tokens in current dumps (the parser
  still accepts the older JSON-array encoding) — and lets you reuse a local
  `.zst` instead of re-downloading 300 MB.
- New `core/puzzle_types.lua`: the curated puzzle-type catalog (Random ·
  Mates · Tactics · Mating patterns · Endgames · Pawn play · Phases ·
  Openings by name) shared verbatim by the app and the bank builder;
  exact-theme and opening-family matchers, plus one-pass per-type counts.
  ADR-0003.
- New **Puzzle type** selection: a grouped dropdown (`ui/type_picker.lua`)
  with the current pick marked and live per-type counts — reachable from a
  new "Puzzle Type…" hamburger entry (applies instantly) and from Settings
  (applied on Save). Difficulty stays a radio group in Settings.
- The machine's `settings` transition now **re-draws a fresh random puzzle**
  when a filter axis changes; selecting a type drops you straight into that
  type. The status strip shows the active type on the header line.
- Fixed: the empty slice no longer crashes layout rendering — an empty
  session renders a piece-less board with the "No puzzles match" message
  instead of tripping the board's Game assertion.
- The emulator driver is now **solution-driven** (plays whatever the
  machine draws, via `remainingSolution()`), so `make emU-test-puzzle`
  passes against the real bank; it also covers the empty-type path.

### Human-vs-human board orientation
- New Interface **"Flip pieces to player on each turn"** toggle. On =
  the classic behavior: in human-vs-human the whole board rotates 180°
  toward the side to move on every turn. Off (default) = the fixed
  board.
- Fixed board (off, default): the board stays fixed — white's side at the
  bottom — for the whole game, and each side's far pieces angle toward
  their own player, black's upside-down on the far side and white's
  upright at the bottom, so nothing inverts when the turn passes. The
  full-board per-turn face pivot machinery stays in place, just parked
  unless the toggle is on; the manual "Invert Opponent Pieces" toggle
  still applies to human-vs-computer games.
- Wired through the whole stack: the arbiter setting + view projection
  (`face_color` follows the mover only with the toggle on, `rotate_top_
  pieces` on in fixed hvh), the app's derived orientation, the settings
  dialog, and the interface dialog's live preview and reset. The
  emulator's hvh scenario now toggles both modes through real settings
  applies and asserts the face follows the mover.

### Emulator end-to-end test pass
- `make emU-test` boots KOReader's desktop emulator headless and drives a
  scripted full session through the App's public surface:
  `tools/emu-driver.lua` (the patch) + `tools/emu-test.sh` (the runner)
  report per-step PASS/FAIL, a RESULT line and a SUMMARY, then exit 0/1.
- The nine scenarios: fresh timed boot (engine handshake, widgets built),
  human e4 → engine reply (history, running, live clocks, rendered
  strips), the eval pipeline reaching the eval row, undo-all/redo-all,
  the board-flip preference, a roles-only settings apply preserving clock
  remaining (the live-bug #2 regression, end-to-end), a PGN load with the
  computer to move that must launch a search (live-bug #1), a flag-fell
  finish, and a save → re-boot restore (`saved_pgn` persisted, position
  resumed). Auto-detects the emulator; `EMULATOR_DIR=` overrides.
- First full run: 9/9 PASS, and it independently re-confirmed the two
  live-bug regressions inside the real plugin.

### Player widgets
- Player strips now show the last four plies over two history lines —
  identical content on both strips in every game mode, so each player
  reads the same bracket right side up. The strips mirror each other
  exactly: both carry the eval line (Engine Evals) and the
  recommended-moves line (Engine Hints), both toggleable in Interface
  settings, so the far side reads the same verdict even when it's a
  computer.
- Taken pieces move off the strips into the board's right gutter
  (ui/capture_gutter): two columns of the board's own piece icons down
  the side, each side's spoils anchoring at their own edge and growing
  toward the middle — taken white pieces on Black's side, taken black
  pieces on White's side, following the board flip. The far half
  points at the player across the board (180° icon variants, like the
  rotated top strip); the near half stays upright. The gutters stay
  symmetric and the columns center in the right one's slack; icons
  shrink to fit if a whole army ends up in there.
- Clock cards are unchanged.

### Chrome
- One control row, at the top only: the undo/redo chevrons centered,
  the hamburger right-justified — a third smaller than the old
  title-bar icons. The gear left the bar: Settings is the first entry
  in the hamburger menu. The bottom bar is gone: no more
  "White(Human) < Black(Computer)" roster line; the board's zone now
  runs down to the frame's bottom line, so the board grows into the
  freed space. "Computer thinking…" lives in the eval rows (both
  strips).

### Engine orchestration
- The whole game flow now runs through the `core.arbiter` transition
  funnel (design A in docs/arbiter-design.md). The App constructs an
  arbiter from the settings snapshot and feeds it one event per thing
  that happens — board move, engine line, UCI ready/bestmove/failure,
  settings apply, undo/redo, PGN load, save — and performs its effect
  list (persist, UCI commands, timers, repaints, game-over announce).
  The board no longer plays moves itself: it reports the desired move
  and the arbiter validates and applies it.
- Fixes a family of live bugs that lived in the old App orchestration:
  the PGN-load dead position (the engine kept answering its stale
  search after the game was replaced), the roles-only settings
  clock wipe (the free-increment double-switch on every move), and
  mid-game difficulty changes that silently did nothing.
- Game-over "Continue" and "New Game" reset through the arbiter; the
  clock/flag-fall ticker and the missing-engine behavior now live in
  the transitioned machine, pinned by spec/arbiter_spec.lua (27 tests).
- Stragglers and debris removed from app.lua: the App-side thinking
  indicator is gone (the machine's 3s reveal latch drives the eval-row
  text through view()), the dead `setHintsText` and dead search fields
  (`_go_kind`, `engine_busy`, `_analysis_active`, `_pending_launch`,
  watchdogs) are deleted, and the design doc's event/view tables now
  match the implementation (`resume`, `engine_restart`, flat notation
  view fields).

### Core purity gate (lint)
- `core/*.lua` now runs under a tailored luacheck std (built from
  luacheck's own luajit definitions): `os.*`/`io.*` are banned outright
  and `math` is restricted to the pure arithmetic set — `math.random`
  may only appear as the injected-`deps.rng` default in the Blunder
  (marked inline). `os.time` fallbacks are gone: `Clock:new` and
  `Arbiter:new` now require the injected time source.
- `make lint` also runs a mechanical require gate (luacheck does not
  track `require` strings): core may only pull the sealed core modules
  or the vendored rules engine.
- Verified 0 warnings / 0 errors across the whole tree with a working
  luacheck (Homebrew keg), and the emulator still plays e2-e4 /
  engine-reply with correct clock accounting.

## 1.0.0 — 2026-08-31

First SlateChess release. The plugin was renamed from PlyChess and now
lives at https://github.com/mdp/SlateChess; history before this point
(Casual Chess and its ancestors) is squashed and credited in LICENSE.

### Renamed to SlateChess
- New name everywhere: plugin metadata, menus, dispatcher action, settings
  file (`slatechess.lua`), icon paths, packaging and CI.
- One-time migrations on first launch: settings are copied from
  `plychess.lua`, and the old icon cache dir is removed.

### About dialog
- New "About SlateChess" entry in the hamburger menu: version, the most
  recent changelog entries, and a GitHub link (opens in the browser on
  devices that support it).

### Board markers
- Corner-bracket marks: └ ┐ on the last-move squares, four corners on the
  selected square; the old solid ring and dashed from/to outlines are gone.
- Fixed a regression where the marker overlay swallowed all board input.
- E-ink ghosting on moved squares is cleared with a scheduled refresh.

### Clock and layout
- Untimed games no longer show a running clock; timer font is a notch bigger.
- Larger coordinates, clock card sizing fixes, per-move evals in the
  notation strips, and Flip Board in the menu.
- Analysis lines wait until the computer has moved.

### Under the hood
- Chal engine with `go movetime` and `ucinewgame` TT-clear patches; a
  hardened search lifecycle (watchdog, stalled-search recovery).
- Layered core/engine/ui architecture with a busted test suite and
  luacheck-clean sources.
