# SlateChess — build, test, lint, package, and install targets.
#
# Common tasks:
#   make test      — run the busted test suite (core/ + engine/)
#   make lint      — run luacheck on the Lua sources
#   make package   — build dist/slatechess.koplugin-v<version>.zip
#   make install   — copy the plugin to a mounted Kindle/KOReader plugins dir
#   make clean     — remove build artifacts

PLUGIN_NAME  := slatechess.koplugin
VERSION      := $(shell sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' _meta.lua)
DIST_DIR     := dist
ZIP_NAME     := $(PLUGIN_NAME).v$(VERSION).zip

# Where to install when you run `make install`.
# Override explicitly if your mount point differs, e.g.:
#   make install KINDLE_PLUGINS=/Volumes/Kindle/koreader/plugins
KINDLE_MOUNT ?= $(firstword $(wildcard /Volumes/Kindle* /Volumes/USBDrive*))
KINDLE_PLUGINS ?= $(KINDLE_MOUNT)/koreader/plugins

# Files that must exist before we can package.
REQUIRED := chess/src/chess.lua engines/chal icons/wP.svg data/aperturas.json

# First-party Lua sources. chess/src is the vendored third-party rules
# engine and is excluded from linting.
LUA_SOURCES := $(wildcard *.lua) $(wildcard core/*.lua) $(wildcard engine/*.lua) $(wildcard ui/*.lua)

BUSTED := busted
LUACHECK := luacheck

.PHONY: all test lint package install clean check-version

all: test lint package

check-version:
	@test -n "$(VERSION)" || (echo "Could not parse version from _meta.lua"; exit 1)

test:
	@command -v $(BUSTED) >/dev/null 2>&1 || { \
		echo "busted not found. Install with: luarocks install busted"; \
		exit 1; }
	$(BUSTED) spec

lint: check-version
	@command -v $(LUACHECK) >/dev/null 2>&1 || { \
		echo "luacheck not found. Install with: luarocks install luacheck"; \
		exit 1; }
	$(LUACHECK) $(LUA_SOURCES) spec

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
		-x 'engines/stockfish*' 'engines/chal-arm64' \
		-x 'Makefile' '.luacheckrc' 'CONTEXT.md' 'README.md' \
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

clean:
	rm -rf $(DIST_DIR)
