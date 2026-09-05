# KOReader emulator: submodule, build, run & resolutions

SlateChess (and its sibling plugin SlatePuzzle) is a KOReader plugin. To run
it the way an e-reader would, this project vendors the KOReader dev tree as a
git submodule (`koreader/`) and drives its desktop emulator - headless for
the end-to-end test passes, or interactively on a display.

## Submodule setup

The submodule is pinned to the commit the emulator build is based on:

```sh
git submodule update --init --recursive koreader
```

`--recursive` matters: KOReader itself vendors submodules (`base`, `l10n`,
`platform/android/luajit-launcher`, `resources/fonts`, `test`). The checked-in
`koreader/.gitmodules` pins those inner commits too, so a fresh recursive
update reproduces the exact tree.

Everything a build generates under `koreader/` (`base/build/`,
`koreader-emulator-*/`) is git-ignored inside the submodule, so build output is
never committed to SlateChess and only exists on the machine that built it.

---

## Build on Linux (x86_64)

Tested on Debian trixie; the equivalents apply to Ubuntu.

### Prerequisites

```sh
sudo apt update
sudo apt install -y \
  cmake meson ninja-build pkgconf \
  autoconf automake libtool gperf nasm subversion \
  git patch wget unzip curl ccache
```

The emulator opens an SDL3 window, so the X11 video-driver dev headers are
also required. KOReader builds its own bundled SDL3 (3.4.x) whenever the
distro's SDL3 is older than the minimum it wants (3.2.12); the bundled build
must be able to enable its X11 backend:

```sh
sudo apt install -y \
  libx11-dev libxext-dev libxrandr-dev libxrender-dev libxi-dev \
  libxfixes-dev libxcursor-dev libxinerama-dev libxss-dev libxtst-dev \
  libxxf86vm-dev libxkbfile-dev libxkbcommon-dev \
  libwayland-dev wayland-protocols libdecor-0-dev \
  libdbus-1-dev libusb-1.0-0-dev libpulse-dev
```

`ccache` is optional but makes rebuilds dramatically faster. If it is not
installed, build with `USE_NO_CCACHE=1`.

### Build

```sh
cd koreader
./kodev build        # downloads + compiles ~40 bundled libs; ~15-60 min
```

Output lands in `koreader-emulator-x86_64-linux-gnu-debug/koreader/`.

---

## Build on macOS (arm64 / Intel)

Requires Xcode command line tools and Homebrew:

```sh
xcode-select --install
brew install cmake ninja meson pkgconf ccache
brew install sdl3            # optional; the toolchain falls back to bundled
```

Then:

```sh
cd koreader
./kodev build
```

Output lands in `koreader-emulator-arm64-apple-darwinNN.N.N-debug/koreader/`
(arch/os version varies).

---

## Run

### Headless end-to-end passes (CI-style)

```sh
# from the SlateChess checkout
make emU-test            # chess app (boot, moves, eval, undo/redo, flip,
                         # settings, PGN load, flag-fell, save/restore)
make emU-test-puzzle     # puzzle app (bank, replay, navigation, resume)
```

The runners auto-detect `./koreader` (the submodule); pass an explicit
`EMULATOR_DIR=` if you keep several checkouts. On a machine without a display,
wrap it in a virtual framebuffer:

```sh
xvfb-run -a make emU-test
```

### Interactive (visible window)

```sh
E=path/to/koreader/koreader-emulator-.../koreader
cd "$E" && ./koreader.sh
```

- macOS: the SDL window opens normally.
- Linux without a physical display: point it at a virtual display, e.g.
  `DISPLAY=:1` served by a VNC server (KasmVNC / Xvnc), as used in this
  project's dev setup.
- `koreader.sh` restarts the reader (exit code 85) so the plugin reloads on
  quit; Ctrl+C exits for good.

### Emulated screen size

The emulator honours device-resolution env vars; layout and font metrics are
computed at these pixel sizes:

```sh
EMULATE_READER_W=1072 EMULATE_READER_H=1448 ./koreader.sh
```

The default is 600x800 when unset. For a window that fits a small desktop, use
a scale fraction of the target resolution and keep the ratio (next section).

---

## Preferred resolutions

From `e-reader-resolutions.md`, the layout targets (portrait, pixel W x H).
**Bold** marks the emulator default.

| Resolution (W x H) | Half scale | Devices |
|---|---|---|
| **600 x 800** | 300 x 400 | Kindle 8 / 10, Kobo Touch |
| 758 x 1024 | 379 x 512 | Kobo Nia |
| 1072 x 1448 | 536 x 724 | Kindle 11, Paperwhite 4, Voyage, Oasis (1st), Clara HD/2E/BW/Colour, Glo HD |
| 1236 x 1648 | 618 x 824 | Paperwhite 5 / 5 Signature |
| 1264 x 1680 | 632 x 840 | Paperwhite 6 / 6 Signature, Colorsoft, Oasis 2/3, Libra 2/Colour, Forma |
| 1404 x 1872 | 702 x 936 | Kobo Elipsa / Elipsa 2E |
| 1440 x 1920 | 720 x 960 | Kobo Sage |
| 1860 x 2480 | 930 x 1240 | Kindle Scribe (2022 / 2024) |
| 1980 x 2640 | 990 x 1320 | Kindle Scribe 3 |

Common interactive choice (6" Paperwhite at half scale, ratio kept), fits a
~1100+ wide VNC desktop:

```sh
EMULATE_READER_W=536 EMULATE_READER_H=724 ./koreader.sh
```

---

## Notes

- **Engine binaries are not in git.** After a fresh clone run
  `sh engines/fetch.sh native` to build `engines/berserk-<arch>` (Linux x86_64
  -> `berserk-x64`, macOS arm64 -> `berserk-arm64`, Kindle -> `berserk`);
  `app.lua` picks the right name via `jit.arch`.
- **Plugin symlinks.** The emulator loads plugins from `koreader/plugins/`.
  The checkout keeps untracked, portable relative symlinks
  `slatechess.koplugin -> ../..` and
  `slatepuzzle.koplugin -> ../../dist/slatepuzzle.koplugin`, so they resolve
  on any machine and layout.
- **Rebuilds.** After `git submodule update --init --recursive`, the emulator
  is not yet built; run `./kodev build` once per machine. The multi-GB
  `base/build` tree is machine-specific and ignored.