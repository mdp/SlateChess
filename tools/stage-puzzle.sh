#!/bin/sh
# stage-puzzle.sh — build the SlatePuzzle staging tree from the repo.
#
# Two KOReader plugins cannot share modules at runtime (package.path is
# prefixed per-plugin), so the puzzle plugin must be a self-contained tree.
# This script assembles dist/slatepuzzle.koplugin/ from:
#   * the puzzle-specific sources (puzzle/*)  — app, main, ui/status, ui/settings
#   * the SHARED modules both apps use        — copied verbatim, one repo copy
#   * the vers and doc files (puzzle/_meta.lua template + an injected version)
#
# The shared set is deliberately the transparent subset SlatePuzzle needs:
#   core/game.lua  core/puzzle.lua  core/puzzles.lua  core/puzzle_types.lua
#   core/eval.lua
#   ui/board.lua  ui/layout.lua  ui/compat.lua  ui/overlay.lua
#   ui/marks_overlay.lua  ui/icons.lua  ui/capture_gutter.lua
#   chess/  icons/  data/puzzles.json  LICENSE  CHANGELOG.md
#
# A change to any shared module lands in BOTH zips automatically on the next
# package.

set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$REPO_DIR/dist/slatepuzzle.koplugin"

rm -rf "$STAGE"
mkdir -p "$STAGE"

# --- puzzle-specific files -------------------------------------------------
# app.lua is staged as puzzle_app.lua: SlateChess's main.lua requires the
# generic "app" module, and Lua caches modules by name — both plugins load
# in one KOReader process, so the puzzle's app module must have a unique
# name or one plugin would return the other's App class.
cp "$REPO_DIR/puzzle/main.lua" "$STAGE/main.lua"
cp "$REPO_DIR/puzzle/app.lua"  "$STAGE/puzzle_app.lua"
mkdir -p "$STAGE/ui"
cp "$REPO_DIR"/puzzle/ui/*.lua "$STAGE/ui/"

# --- shared pure core ------------------------------------------------------
mkdir -p "$STAGE/core"
for f in core/game.lua core/puzzle.lua core/puzzles.lua core/puzzle_types.lua core/eval.lua; do
    cp "$REPO_DIR/$f" "$STAGE/$f"
done

# --- shared UI -------------------------------------------------------------
for f in ui/board.lua ui/layout.lua ui/gameplay_design.lua ui/fitted_text.lua ui/compat.lua ui/overlay.lua \
         ui/marks_overlay.lua ui/icons.lua ui/capture_gutter.lua \
         ui/gameplay_frame.lua ui/hud_rule.lua; do
    cp "$REPO_DIR/$f" "$STAGE/$f"
done

# --- vendored rules engine, icons, data ------------------------------------
cp -R "$REPO_DIR/chess" "$STAGE/chess"
mkdir -p "$STAGE/icons"
cp "$REPO_DIR"/icons/*.svg "$STAGE/icons/"
mkdir -p "$STAGE/data"
test -s "$REPO_DIR/data/puzzles.json" \
    || { echo "data/puzzles.json is missing — run tools/fetch-puzzles.sh" >&2; exit 1; }
cp "$REPO_DIR/data/puzzles.json" "$STAGE/data/puzzles.json"

# --- docs and licence ------------------------------------------------------
cp "$REPO_DIR/LICENSE" "$STAGE/LICENSE" 2>/dev/null || true
cp "$REPO_DIR/CHANGELOG.md" "$STAGE/CHANGELOG.md" 2>/dev/null || true

# --- _meta.lua: the root version is the single source across both apps, so
# it is injected here at package time (one tag releases both zips). --------
root_version="$(sed -n 's/^[[:space:]]*version[[:space:]]*=.*"\([0-9.]*\)".*/\1/p' "$REPO_DIR/_meta.lua")"
sed "s/@VERSION@/$root_version/" "$REPO_DIR/puzzle/_meta.lua" > "$STAGE/_meta.lua"

echo "staged $STAGE ($(find "$STAGE" -type f | wc -l | tr -d ' ') files, version $root_version)"
