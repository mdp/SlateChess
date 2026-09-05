#!/bin/sh
# emu-test-puzzle.sh — SlatePuzzle emulator end-to-end test pass.
#
# Mirrors tools/emu-test.sh for the puzzle app: stages the puzzle plugin,
# symlinks it into the emulator, installs the puzzle driver as a userpatch,
# boots once, drives a scripted solving session (boot, correct move +
# auto-reply, wrong move, next, restart, settings re-filter, resume), and
# reports per-step PASS/FAIL plus a RESULT line.
#
# Driver: tools/emu-driver-puzzle.lua.
#
# Usage:
#   tools/emu-test-puzzle.sh                     # auto-detect the emulator
#   tools/emu-test-puzzle.sh /path/to/koreader
#   EMULATOR_DIR=/path/to/koreader make emU-test-puzzle

set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

EMULATOR_DIR="${1:-${EMULATOR_DIR:-}}"
if [ -z "$EMULATOR_DIR" ]; then
    for base in "$HOME/Syncthing/mdp-src/koreader" "$HOME"; do
        for cand in "$base"/koreader-emulator*/koreader "$base"/koreader*emu*/koreader; do
            if [ -d "$cand" ]; then
                EMULATOR_DIR="$cand"
                break 2
            fi
        done
    done
fi
if [ -z "$EMULATOR_DIR" ] || [ ! -d "$EMULATOR_DIR" ]; then
    echo "Emulator not found. Pass the koreader dir or set EMULATOR_DIR." >&2
    exit 2
fi

# The puzzle plugin must be staged before the run (make emU-test-puzzle
# does this; the standalone script stages it too for safety).
"$REPO_DIR/tools/stage-puzzle.sh" >/dev/null

mkdir -p "$EMULATOR_DIR/patches"

PATCH="$EMULATOR_DIR/patches/2-slatepuzzle-emu.lua"
PLUGIN="$EMULATOR_DIR/plugins/slatepuzzle.koplugin"
RESULT_FILE="$EMULATOR_DIR/EMU_TEST_PUZZLE_RESULT.txt"
LOG_FILE="$EMULATOR_DIR/_emu_test_puzzle.log"

cp "$REPO_DIR/tools/emu-driver-puzzle.lua" "$PATCH"
ln -sfn "$REPO_DIR/dist/slatepuzzle.koplugin" "$PLUGIN"

rm -f "$RESULT_FILE" "$LOG_FILE"
echo "=== booting emulator (puzzle): $EMULATOR_DIR ==="
"$EMULATOR_DIR/koreader.sh" > "$LOG_FILE" 2>&1 &
EMU_PID=$!

found=""
for i in $(seq 1 240); do
    if [ -f "$RESULT_FILE" ]; then found="yes"; break; fi
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
        echo "emulator exited without producing a result — log tail:" >&2
        tail -30 "$LOG_FILE" 2>/dev/null >&2 || true
        exit 1
    fi
    sleep 2
done

if [ -n "$found" ]; then
    echo "=== SLATEPUZZLE EMU RUN ==="
    cat "$RESULT_FILE"
    wait "$EMU_PID" 2>/dev/null || true
    RESULT="$(grep -o 'RESULT: .*' "$RESULT_FILE" | head -1 || true)"
else
    echo "no result within 8 minutes — log tail:" >&2
    tail -30 "$LOG_FILE" 2>/dev/null >&2 || true
    RESULT="RESULT: FAIL"
fi

rm -f "$PATCH" "$LOG_FILE"

case "$RESULT" in
    *PASS*) exit 0 ;;
    *) exit 1 ;;
esac