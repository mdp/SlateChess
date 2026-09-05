#!/bin/sh
# Mechanical core/ purity gate.
#
# luacheck does not track `require` strings, so the .luacheckrc std gate
# (no os./io., math limited to the pure set) can't catch a stray
# require("ui/...") in core/. This script is the teeth behind it: core/
# may only require the sealed core modules and the vendored rules engine.
set -e
cd "$(dirname "$0")/.."

ALLOWED='require\("core\.(game|clock|blunder|eval|openings|puzzle|puzzles|puzzle_types)"\)|require\("chess/src/chess"\)'

BAD=$(grep -nE 'require\(' core/*.lua \
    | grep -vE "$ALLOWED" || true)

if [ -n "$BAD" ]; then
    echo "core/ may only require the sealed core modules"
    echo "(core.game, core.clock, core.blunder, core.eval, core.openings," \
        "core.puzzle, core.puzzles)" \
        "or the vendored chess/src/chess:"
    echo "$BAD"
    exit 1
fi
echo "core/ require gate OK"