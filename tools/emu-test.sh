#!/bin/sh
# SlateChess — emulator end-to-end test pass.
#
# Boots KOReader's desktop emulator once with the plugin linked, installs the
# test driver as a userpatch, drives a scripted full session (boot, human
# moves, engine replies, evals, undo/redo, flip, settings, PGN load,
# flag-fell, save -> re-boot restore), and reports per-step PASS/FAIL plus a
# RESULT line and SUMMARY.
#
# Driver: tools/emu-driver.lua. Results land in $EMULATOR_DIR/EMU_TEST_RESULT.txt.
#
# Usage:
#   tools/emu-test.sh                       # auto-detect the emulator
#   tools/emu-test.sh /path/to/koreader     # explicit
#   EMULATOR_DIR=/path/to/koreader make emU-test

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

mkdir -p "$EMULATOR_DIR/patches"

PATCH="$EMULATOR_DIR/patches/2-slatechess-emu.lua"
PLUGIN="$EMULATOR_DIR/plugins/slatechess.koplugin"
RESULT_FILE="$EMULATOR_DIR/EMU_TEST_RESULT.txt"
LOG_FILE="$EMULATOR_DIR/_emu_test.log"

cp "$REPO_DIR/tools/emu-driver.lua" "$PATCH"
if [ ! -e "$PLUGIN" ]; then
    ln -s "$REPO_DIR" "$PLUGIN"
fi

rm -f "$RESULT_FILE" "$LOG_FILE"
echo "=== booting emulator: $EMULATOR_DIR ==="
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
    echo "=== SLATECHESS EMU RUN ==="
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