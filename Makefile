# SlateChess — build, test, lint, package, and install targets.
#
# Common tasks:
#   make test      — run the busted test suite (core/ + engine/)
#   make lint      — run luacheck on the Lua sources
#   make package   — build dist/slatechess.koplugin-v<version>.zip
#   make install   — copy the plugin to a mounted Kindle/KOReader plugins dir
#   make clean     — remove build artifacts

PLUGIN_NAME  := slatechess.koplugin
PUZZLE_NAME  := slatepuzzle.koplugin
VERSION      := $(shell sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' _meta.lua)
DIST_DIR     := dist
ZIP_NAME     := $(PLUGIN_NAME).v$(VERSION).zip
PUZZLE_ZIP   := $(PUZZLE_NAME).v$(VERSION).zip
STAGE_DIR    := $(DIST_DIR)/$(PUZZLE_NAME)

# Where to install when you run `make install`.
# Override explicitly if your mount point differs, e.g.:
#   make install KINDLE_PLUGINS=/Volumes/Kindle/koreader/plugins
KINDLE_MOUNT ?= $(firstword $(wildcard /Volumes/Kindle* /Volumes/USBDrive*))
KINDLE_PLUGINS ?= $(KINDLE_MOUNT)/koreader/plugins

# Files that must exist before we can package.
REQUIRED := chess/src/chess.lua engines/berserk icons/wP.svg data/aperturas.json

# First-party Lua sources. chess/src is the vendored third-party rules
# engine and is excluded from linting. puzzle/ is SlatePuzzle-only code.
LUA_SOURCES := $(wildcard *.lua) $(wildcard core/*.lua) $(wildcard engine/*.lua) $(wildcard ui/*.lua) $(wildcard puzzle/*.lua) $(wildcard puzzle/ui/*.lua)

BUSTED := busted
LUACHECK := luacheck

.PHONY: all test lint package install clean check-version core-gate emU-test \
        stage-puzzle puzzle-package puzzle-install emU-test-puzzle puzzles

all: test lint package

check-version:
	@test -n "$(VERSION)" || (echo "Could not parse version from _meta.lua"; exit 1)

test:
	@command -v $(BUSTED) >/dev/null 2>&1 || { \
		echo "busted not found. Install with: luarocks install busted"; \
		exit 1; }
	$(BUSTED) spec

lint: check-version core-gate
	@command -v $(LUACHECK) >/dev/null 2>&1 || { \
		echo "luacheck not found. Install with: luarocks install luacheck"; \
		exit 1; }
	# On macOS where the PATH luacheck is a broken Lua 5.5 rock, a working
	# luacheck is available via Homebrew's keg (version-coupled); point
	# LUACHECK at it, e.g.:
	#   make lint LUACHECK="/opt/homebrew/opt/lua/bin/lua5.5 -e 'package.path=<keg share/lua/5.5/? paths>;require(\"luacheck.main\")' --"
	$(LUACHECK) $(LUA_SOURCES) spec

# Mechanical core/ purity gate: luacheck does not track `require` strings,
# so the .luacheckrc std gate (no os./io., math restricted to the pure set,
# math.random only at the Blunder default) is backed by this script which
# forbids any require outside the sealed core modules / vendored chess.
core-gate:
	@sh tools/core-gate.sh

# Boot KOReader's desktop emulator and drive a scripted full session
# (boot, moves, engine replies, evals, undo/redo, flip, settings, PGN
# load, flag-fell, save -> re-boot restore). Point EMULATOR_DIR at the
# koreader dir if auto-detection misses it, e.g.:
#   make emU-test EMULATOR_DIR=/path/to/koreader
emU-test:
	@sh tools/emu-test.sh $(EMULATOR_DIR)

package: check-version
	@for f in $(REQUIRED); do \
		test -e "$$f" || { echo "Missing $$f"; exit 1; }; \
	done
	@mkdir -p $(DIST_DIR)
	@rm -f $(DIST_DIR)/$(ZIP_NAME)
	zip -r $(DIST_DIR)/$(ZIP_NAME) . \
		-x '*/.git/*' '.git/*' \
		-x '.gitignore' \
		-x '$(DIST_DIR)/*' 'dist/*' \
		-x 'screenshots/*' \
		-x 'spec/*' \
		-x 'engines/stockfish*' 'engines/berserk-arm64' 'engines/berserk-x64' \
		-x 'Makefile' '.luacheckrc' 'CONTEXT.md' 'README.md' \
		-x 'e-reader-resolutions.md' \
		-x '*.swp' '.DS_Store'
	@echo "Built $(DIST_DIR)/$(ZIP_NAME) ($(VERSION))"
	@unzip -l $(DIST_DIR)/$(ZIP_NAME) | tail -n 1

install: package
	@test -d "$(KINDLE_PLUGINS)" || { \
		echo "KOReader plugins dir not found at $(KINDLE_PLUGINS)"; \
		echo "Is your Kindle mounted? Set KINDLE_PLUGINS=/path/to/koreader/plugins"; \
		exit 1; }
	unzip -o $(DIST_DIR)/$(ZIP_NAME) -d $(KINDLE_PLUGINS)/$(PLUGIN_NAME)/
	@echo "Installed $(PLUGIN_NAME) to $(KINDLE_PLUGINS) — restart KOReader."

# --- SlatePuzzle: a second self-contained plugin packaged from the same
# repo (see tools/stage-puzzle.sh for the shared/specific split).

stage-puzzle:
	@sh tools/stage-puzzle.sh

puzzle-package: check-version stage-puzzle
	@test -s $(STAGE_DIR)/data/puzzles.json || { \
		echo "data/puzzles.json missing or empty — run tools/fetch-puzzles.sh"; \
		exit 1; }
	@rm -f $(DIST_DIR)/$(PUZZLE_ZIP)
	cd $(STAGE_DIR) && zip -qr ../$(PUZZLE_ZIP) .
	@echo "Built $(DIST_DIR)/$(PUZZLE_ZIP) ($(VERSION))"
	@unzip -l $(DIST_DIR)/$(PUZZLE_ZIP) | tail -n 1

puzzle-install: puzzle-package
	@test -d "$(KINDLE_PLUGINS)" || { \
		echo "KOReader plugins dir not found at $(KINDLE_PLUGINS)"; \
		echo "Is your Kindle mounted? Set KINDLE_PLUGINS=/path/to/koreader/plugins"; \
		exit 1; }
	unzip -o $(DIST_DIR)/$(PUZZLE_ZIP) -d $(KINDLE_PLUGINS)/$(PUZZLE_NAME)/
	@echo "Installed $(PUZZLE_NAME) to $(KINDLE_PLUGINS) — restart KOReader."

emU-test-puzzle:
	@$(MAKE) stage-puzzle
	@sh tools/emu-test-puzzle.sh $(EMULATOR_DIR)

# Regenerate the embedded SlatePuzzle bank from a local Lichess DB dump.
#   make puzzles INPUT=/path/to/lichess_db_puzzle.csv.zst
puzzles:
	@test -n "$(INPUT)" || { \
		echo "usage: make puzzles INPUT=/path/to/lichess_db_puzzle.csv.zst"; \
		echo "  (see tools/fetch-puzzles.sh for LIMIT/QUOTA_SCALE knobs)"; \
		exit 1; }
	@sh tools/fetch-puzzles.sh "$(INPUT)"

clean:
	rm -rf $(DIST_DIR)
