# SlateChess — chess for KOReader e-ink devices

<p align="center">
  <img width="379" height="511" alt="SlateChess — chess board" src="https://github.com/user-attachments/assets/22e06d73-6c7c-4b23-befc-4e1a595c98db" />
  <img width="382" height="511" alt="SlatePuzzle — chess puzzles" src="https://github.com/user-attachments/assets/3966fe67-fb3f-4e9b-b348-4b298294f8fe" />
</p>

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

Download the latest release zip(s) and unzip them into your KOReader plugins
directory:

https://github.com/mdp/SlateChess/releases

Each release ships two self-contained plugins:

- **`slatechess.koplugin`** — the chess app (board, clock, engines, PGN).
- **`slatepuzzle.koplugin`** — the 12,000-puzzle trainer with the adaptive
  `YOU` rating.

Unzip either into `<koreader>/plugins/` so the `*.koplugin/` folder lands at
`<koreader>/plugins/<name>.koplugin/`, then restart KOReader. Look for
**SlateChess** and **SlatePuzzle** under Tools.

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

To hack on the plugin inside a full KOReader checkout, run the emulator from
the KOReader dev tree. The KOReader checkout is vendored as a git submodule:

```sh
git submodule update --init --recursive koreader
sh koreader/../engines/fetch.sh native   # build the Berserk engine binary
```

Then build the emulator once per machine (`./kodev build` inside `koreader/`)
and run it - see `docs/koreader-emulator.md` for the full Linux/macOS build
and run guide, including the emulated screen resolutions. The plugin is linked
into `koreader/plugins/slatechess.koplugin` by portable relative symlinks.

`make emU-test` drives KOReader's desktop emulator headless: it boots the
plugin the way KOReader would and runs a scripted full session — a fresh
timed game, human move + engine reply, the eval pipeline, undo/redo, the
board flip, a roles-only settings apply (clocks preserved), a PGN load with
the computer to move, a flag-fell finish, and a save → re-boot restore —
asserting the Arbiter view and the rendered widgets at every step
(driver: `tools/emu-driver.lua`, runner: `tools/emu-test.sh`). It auto-detects
`koreader/` (the submodule); point `EMULATOR_DIR` at another checkout if
auto-detection misses it. CI could run this against a nightly emulator build.

CI (GitHub Actions) installs LuaJIT 2.1 + luarocks, then runs `make test`
and `make lint` on every push. Pushing a `v*.*.*` tag runs the release job:
it cross-compiles the Kindle engine with Zig, builds both plugin zips
(`make package` + `make puzzle-package`), sanity-checks each, and attaches
them to a GitHub release.
