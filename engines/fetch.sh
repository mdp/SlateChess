#!/bin/sh
# Build the Chal engine binary for this machine into engines/.
#
# Chal is the plugin's primary engine: a ~999-line UCI chess engine
# with proper eval scores (see engines/chal.c, MIT license, with two
# small slatechess patches: "go movetime" support and ucinewgame TT
# clear).  Binaries are NOT tracked in git -- run this once per
# machine:
#
#   macOS / Linux native:  sh engines/fetch.sh
#   Kindle (Linux ARM):    cross-compiles with zig, if installed:
#                            sh engines/fetch.sh kindle
#
# Output: engines/chal-arm64 | engines/chal-x64 (native),
#         engines/chal (Kindle ARM, static musl).
set -eu

cd "$(dirname "$0")"
CC="${CC:-cc}"
CFLAGS="-O3 -Wall -Wextra -pedantic -std=c99"

case "${1:-native}" in
    kindle)
        ZIG="${ZIG:-zig}"
        "$ZIG" cc -target arm-linux-musleabihf $CFLAGS -static chal.c -o chal -lm
        echo "built engines/chal (Linux ARM, static)"
        ;;
    native)
        case "$(uname -s)-$(uname -m)" in
            Darwin-arm64)  DEST="chal-arm64" ;;
            Darwin-x86_64) DEST="chal-x64" ;;
            Linux-x86_64)  DEST="chal-x64" ;;
            *) echo "unknown platform, building 'chal'"; DEST="chal" ;;
        esac
        EXTRA=""
        [ "$(uname -s)" = "Linux" ] && EXTRA="-lm"
        "$CC" $CFLAGS chal.c -o "$DEST" $EXTRA
        echo "built engines/$DEST"
        ;;
    *) echo "usage: sh engines/fetch.sh [native|kindle]" >&2; exit 1 ;;
esac
