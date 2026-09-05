# SlateChess — chess for KOReader e-ink devices

SlateChess is a chess plugin for [KOReader](https://github.com/koreader/koreader),
built for low-power e-ink devices: Kindle, Kobo, PocketBook, Cervantes,
reMarkable. It's a board for two people playing across a table — with a
computer opponent for solo games — designed to be readable and fast on
slow, greyscale screens.

## Credits

SlateChess is a fork of **[Casual Chess](https://github.com/MJCopper/casualkochess.koplugin)**
by [MJCopper](https://github.com/MJCopper) — thanks for the great starting
point. It builds on a long line of projects:

- **Casual Chess** — [MJCopper](https://github.com/MJCopper), with
  contributions from Cavaliere78 (Salvatore Saggiomo).
- **kochess.koplugin** — Victor Fariña
  ([coffman](https://github.com/coffman)), based on the original kochess by
  Baptiste Fouques ([bateast](https://github.com/bateast/kochess)).
- **Rules engine** — [chess.lua](https://github.com/arizati/chess.lua) by
  arizati, itself a Lua port of [chess.js](https://github.com/jhlywa/chess.js)
  by Jeff Hlywa. Vendored under `chess/src/`.
- **Engine** — [Berserk](https://github.com/jhonnold/Berserk) by Jay Honnold
  (GPL-3.0-or-later), a strong NNUE-based UCI chess engine. The build is pinned
  to upstream commit `6db8174fd9cc511a130425d5e327caef3567fde9`.
- **Piece icons** — derived from the Cburnett chess set by
  Colin M. L. Burnett (GPL-2.0+).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE) for the full terms and the
complete copyright/attribution list.

## SlatePuzzle companion

This repo also ships **SlatePuzzle** (`slatepuzzle.koplugin`) — an offline
chess-puzzle trainer on the same board, with lichess-style facing (flipped
to the puzzle's side to move, pieces never rotated) and no clocks/engines
settings. It bundles a real, stratified Lichess puzzle bank (~8k puzzles,
every practice type covered) and offers a **puzzle-type dropdown**: Random,
mates, tactics, mating patterns, phases, endgames and openings by name.

See [docs/puzzle-design.md](docs/puzzle-design.md) for the data pipeline
and the type catalog, [ADR-0003](docs/adr/0003-puzzle-type-catalog-and-stratified-bank.md)
for the design decisions, and `make puzzle-package` / `make puzzle-install`
to build and install it.

## Goals and focus

- **Two players, one device.** The board is built for over-the-board
  games across a table: pieces rotate to face each side, each player has
  a clock card, and Flip Board swaps seats instantly. This is not a
  serious chess simulator — the computer opponent exists so you can play
  solo, not to train you for tournaments.
- **Readable and calm on e-ink.** Large board, minimal chrome, no
  animations — the UI is designed around slow full-screen refreshes.
- **Untimed by default.** Casual games first; Fischer clocks are opt-in.
- **A clean, testable core.** All chess logic (rules, clock, eval, openings,
  blunder damper) lives in pure Lua with no KOReader dependencies, covered
  by a busted test suite.

## How it works

- `core/` — pure Lua, zero KOReader dependencies: the Game facade over the
  vendored rules engine, the chess clock, eval parsing/formatting, the
  opening book (ECO labels from `data/aperturas.json`), and the blunder
  damper that weakens play on lower difficulties. This is the test surface.
- `engine/` — async UCI client and subprocess plumbing. Any UCI binary
  works; Berserk ships by default, and a Stockfish binary dropped into
  `engines/` is honoured as a fallback.
- `ui/` — KOReader widgets: board, settings/engine/interface dialogs, icon
  resolution and the Button icon compatibility patch.
- `app.lua` — the controller: every state transition funnels through it,
  and it re-derives all view state (board orientation, status bar, move
  log, eval line, clocks) in one place.
- `main.lua` — thin plugin entry point.
- `chess/` — the vendored rules engine (do not edit casually).

See [CONTEXT.md](CONTEXT.md) for the domain language and architecture
invariants.

### The engine

The bundled engine is **Berserk** by Jay Honnold. It provides UCI MultiPV,
centipawn/mate evaluation, and an embedded NNUE network. The engine is built
from a pinned upstream revision for reproducible releases. Its executable is
about 24 MB because the network is embedded.

It speaks standard UCI, so it plugs into the existing `engine/` client. A
Stockfish binary can still be dropped in as `engines/stockfish[-<arch>]` as a
fallback. For older 32-bit ARM Kindles, the build selects Berserk's scalar
NNUE implementation and substitutes modulo transposition-table indexing for
the upstream `__int128` implementation, which that target cannot compile.

Binaries are not tracked in git. Build one for your machine with:

```
sh engines/fetch.sh          # native build (berserk-arm64 or berserk-x64)
sh engines/fetch.sh kindle   # cross-compiles static 32-bit ARM (needs zig)
```

## Install

Download the latest release zip and unzip it into your KOReader plugins
directory:

https://github.com/mdp/SlateChess/releases

The zip contains a `slatechess.koplugin/` folder — it should end up at
`<koreader>/plugins/slatechess.koplugin/`. Then restart KOReader and look for
**SlateChess** under Tools.

## Development

Tests and lint run on the host with [LuaJIT](https://luajit.org/) — the same
interpreter KOReader embeds.

macOS, one-time setup:

```
brew install luajit luarocks
export PATH="$HOME/.luarocks/bin:$PATH"   # add to your shell profile
luarocks install busted luacheck
```

Linux: install `luajit` and `luarocks` from your package manager, then
`luarocks install busted luacheck` as above.

Then:

```
make test      # busted test suite (core/, engine/ uci plumbing, eval formats)
make lint      # luacheck over first-party Lua sources + core/ purity gate
make emU-test  # headless emulator end-to-end pass (9 scripted scenarios)
make package   # dist/slatechess.koplugin-v<version>.zip
make install   # unzip onto a mounted Kindle's KOReader plugins dir
```

To hack on the plugin inside a full KOReader checkout, run the emulator
from the KOReader dev tree (`./kodev run`); symlink this folder into
`koreader/plugins/slatechess.koplugin`.

`make emU-test` drives KOReader's desktop emulator headless: it boots the
plugin the way KOReader would and runs a scripted full session — a fresh
timed game, human move + engine reply, the eval pipeline, undo/redo, the
board flip, a roles-only settings apply (clocks preserved), a PGN load with
the computer to move, a flag-fell finish, and a save → re-boot restore —
asserting the Arbiter view and the rendered widgets at every step
(driver: `tools/emu-driver.lua`, runner: `tools/emu-test.sh`). Point
`EMULATOR_DIR` at your `koreader` dir if auto-detection misses it. CI could
run this against a nightly emulator build.

CI (GitHub Actions) installs LuaJIT 2.1 + luarocks, then runs `make test`
and `make lint` on every push.
