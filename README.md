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
- **Engine** — [Chal](https://github.com/namanthanki/chal) 1.4.1 by
  Naman Thanki (MIT), a small UCI chess engine. Vendored as `engines/chal.c`
  with two small slatechess patches (see [The engine](#the-engine)).
- **Piece icons** — derived from the Cburnett chess set by
  Colin M. L. Burnett (GPL-2.0+).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE) for the full terms and the
complete copyright/attribution list.

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
  works; chal ships by default, and a Stockfish binary dropped into
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

The bundled engine is **Chal 1.4.1** by Naman Thanki — roughly a thousand
lines of readable C99 that still produces proper eval scores, PV lines, and
node counts. It was chosen because:

- Engines like Stockfish are not only very large, but tend to be quite
  challenging to run on most e-reader hardware. And honestly, the focus of
  this project is not to be a serious chess simulator, but more on 2-player
  in-person games — so Chal compiles to a **~75 KB static binary**, small
  enough to bundle for every platform without bloating the install.
- It speaks plain UCI, so it plugs straight into the existing
  `engine/` client — and any UCI engine (e.g. Stockfish) can still be
  dropped in as `engines/stockfish[-<arch>]` if you want a stronger
  computer opponent.
- Two small slatechess patches (in `engines/chal.c`): `go movetime` now
  overrides clock-based time management with Stockfish's precedence, and
  `ucinewgame` clears the transposition table.

Binaries are not tracked in git. Build one for your machine with:

```
sh engines/fetch.sh          # native build (engines/chal-arm64 or chal-x64)
sh engines/fetch.sh kindle   # cross-compiles a static Kindle ARM build (needs zig)
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
make lint      # luacheck over first-party Lua sources
make package   # dist/slatechess.koplugin-v<version>.zip
make install   # unzip onto a mounted Kindle's KOReader plugins dir
```

To hack on the plugin inside a full KOReader checkout, run the emulator
from the KOReader dev tree (`./kodev run`); symlink this folder into
`koreader/plugins/slatechess.koplugin`.

CI (GitHub Actions) installs LuaJIT 2.1 + luarocks, then runs `make test`
and `make lint` on every push.
