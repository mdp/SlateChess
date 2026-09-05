#!/bin/sh
# fetch-puzzles.sh — build data/puzzles.json from the Lichess puzzle database.
#
# Downloads the official Lichess puzzle DB CSV (zstd), converts a stratified
# sample (see tools/convert-puzzles.lua) into the compact JSON bank the
# SlatePuzzle plugin ships in data/puzzles.json.
#
# Usage:
#   sh tools/fetch-puzzles.sh [output.puzzles.json]
#   sh tools/fetch-puzzles.sh /path/to/lichess_db_puzzle.csv  # reuse a local copy
#   sh tools/fetch-puzzles.sh /path/to/lichess_db_puzzle.csv.zst  # reuse a local copy
#   OUT=out.json sh tools/fetch-puzzles.sh /path/to.csv.zst  # reuse AND write elsewhere
#   LIMIT=8000 sh tools/fetch-puzzles.sh          # cap records (default 12000)
#   RATING_MIN=800 RATING_MAX=2200 sh tools/fetch-puzzles.sh
#   QUOTA_SCALE=0.5 sh tools/fetch-puzzles.sh     # shrink every type's quota
#   MIN_PLAYS=0 MIN_POPULARITY=-100 sh tools/fetch-puzzles.sh  # relax quality
#   MIN_PLAYS=100 MIN_POPULARITY=30 sh tools/fetch-puzzles.sh  # tighten quality
#
# Knobs (env): LIMIT (default 12000), RATING_MIN (default 400),
# RATING_MAX (default 3000), SEED (accepted for future stratified sampling),
# QUOTA_SCALE (default 1), MIN_PLAYS (default 20), MIN_POPULARITY (default 0),
# MAX_RD (default 99999), LDL_URL (overrides the URL).
#
# The full DB is ~300MB compressed / ~7GB as text; the script streams it
# through zstd and only materializes the sampled records.

set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
# Disambiguate the first argument: an existing .csv/.zst is a SOURCE to reuse
# (output then defaults to $REPO_DIR/data/puzzles.json); anything else that is
# given is treated as the OUTPUT path.
if [ -n "$SRC" ] && [ -f "$SRC" ] && { [ "${SRC##*.}" = "csv" ] || [ "${SRC##*.}" = "zst" ]; }; then
    OUT="${OUT:-$REPO_DIR/data/puzzles.json}"
else
    OUT="${OUT:-${1:-$REPO_DIR/data/puzzles.json}}"
fi
LIMIT="${LIMIT:-12000}"
RATING_MIN="${RATING_MIN:-400}"
RATING_MAX="${RATING_MAX:-3000}"
SEED="${SEED:-42}"
QUOTA_SCALE="${QUOTA_SCALE:-1}"
MIN_PLAYS="${MIN_PLAYS:-20}"
MIN_POPULARITY="${MIN_POPULARITY:-0}"
MAX_RD="${MAX_RD:-99999}"
LDL_URL="${LDL_URL:-https://database.lichess.org/lichess_db_puzzle.csv.zst}"

command -v zstd >/dev/null 2>&1 || {
    echo "zstd is required (brew install zstd / apt install zstd)" >&2; exit 1; }
command -v luajit >/dev/null 2>&1 || command -v lua >/dev/null 2>&1 || {
    echo "luajit or lua is required" >&2; exit 1; }

LUA="$(command -v luajit 2>/dev/null || command -v lua)"

tmp="$TMPDIR/puzzlebank.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"

SRC="${SRC:-}"
if [ -n "$SRC" ] && [ -f "$SRC" ] && [ "${SRC##*.}" = "csv" ]; then
    echo "using local CSV: $SRC"
    IN_CSV="$SRC"
elif [ -n "$SRC" ] && [ -f "$SRC" ] && [ "${SRC##*.}" = "zst" ]; then
    echo "using local zst: $SRC"
    IN_CSV="$tmp/lichess_db_puzzle.csv"
    zstd -dc "$SRC" > "$IN_CSV"
else
    echo "downloading $LDL_URL ..."
    curl -fsSL --retry 3 -o "$tmp/lichess_db_puzzle.csv.zst" "$LDL_URL"
    echo "decompressing + sampling ..."
    IN_CSV="$tmp/lichess_db_puzzle.csv"
    zstd -dc "$tmp/lichess_db_puzzle.csv.zst" > "$IN_CSV"
fi

echo "converting (limit=$LIMIT, rating $RATING_MIN..$RATING_MAX, quota_scale=$QUOTA_SCALE, quality plays>=${MIN_PLAYS} pop>=${MIN_POPULARITY}) ..."
LIMIT="$LIMIT" RATING_MIN="$RATING_MIN" RATING_MAX="$RATING_MAX" \
QUOTA_SCALE="$QUOTA_SCALE" MIN_PLAYS="$MIN_PLAYS" \
MIN_POPULARITY="$MIN_POPULARITY" MAX_RD="$MAX_RD" \
    "$LUA" "$REPO_DIR/tools/convert-puzzles.lua" "$IN_CSV" "$tmp/out.json"
mv "$tmp/out.json" "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"