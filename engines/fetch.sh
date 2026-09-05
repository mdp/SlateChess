#!/bin/sh
# Download and build the Berserk UCI engine at a pinned upstream revision.
#
#   sh engines/fetch.sh          # native: berserk-arm64 or berserk-x64
#   sh engines/fetch.sh kindle   # static 32-bit ARM: berserk (needs zig)
#
# Berserk embeds its NNUE network in the executable, so the resulting binary
# is about 24 MB. Downloaded source and network files live only in a temporary
# directory. Binaries are not tracked in git.
set -eu

REVISION="6db8174fd9cc511a130425d5e327caef3567fde9"
VERSION="20260902"
NETWORK="berserk-9b84c340af7e.nn"
NETWORK_URL="https://github.com/jhonnold/berserk-networks/releases/download/networks/$NETWORK"
ARCHIVE_URL="https://github.com/jhonnold/Berserk/archive/$REVISION.tar.gz"

cd "$(dirname "$0")"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/slatechess-berserk.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$2" "$1"
    else
        echo "curl or wget is required" >&2
        exit 1
    fi
}

download "$ARCHIVE_URL" "$BUILD_DIR/berserk.tar.gz"
tar -xzf "$BUILD_DIR/berserk.tar.gz" -C "$BUILD_DIR"
SRC_DIR="$BUILD_DIR/Berserk-$REVISION/src"
download "$NETWORK_URL" "$SRC_DIR/$NETWORK"

if command -v shasum >/dev/null 2>&1; then
    ACTUAL_HASH=$(shasum -a 256 "$SRC_DIR/$NETWORK" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_HASH=$(sha256sum "$SRC_DIR/$NETWORK" | awk '{print $1}')
else
    echo "shasum or sha256sum is required to verify the NNUE network" >&2
    exit 1
fi
EXPECTED_PREFIX=$(printf '%s' "$NETWORK" | sed 's/^berserk-//; s/\.nn$//')
case "$ACTUAL_HASH" in
    "$EXPECTED_PREFIX"*) ;;
    *) echo "Berserk network checksum does not match its filename" >&2; exit 1 ;;
esac

SOURCES="attacks.c bench.c berserk.c bits.c board.c datagen.c eval.c history.c move.c movegen.c movepick.c perft.c random.c search.c see.c tb.c thread.c transposition.c uci.c util.c zobrist.c nn/accumulator.c nn/evaluate.c pyrrhic/tbprobe.c"
COMMON_FLAGS="-std=gnu11 -O3 -flto -DNDEBUG"

case "${1:-native}" in
    kindle)
        ZIG=${ZIG:-zig}
        # Upstream assumes AArch64 whenever NEON is advertised and uses
        # __int128 for TT indexing. Kindle is 32-bit ARM, so use Berserk's
        # scalar NNUE path and an equivalent modulo TT index.
        sed -i.bak 's/return ((unsigned __int128) hash \* (unsigned __int128) TT.count) >> 64;/return hash % TT.count;/' "$SRC_DIR/transposition.h"
        (cd "$SRC_DIR" && "$ZIG" cc -target arm-linux-musleabihf -U__ARM_NEON__ \
            $COMMON_FLAGS "-DVERSION=\"$VERSION\"" "-DEVALFILE=\"$NETWORK\"" \
            $SOURCES -pthread -lm -static \
            -Wl,-z,stack-size=8388608 -s -o "$OLDPWD/berserk")
        echo "built engines/berserk (Linux ARM, static)"
        ;;
    native)
        CC=${CC:-cc}
        case "$(uname -s)-$(uname -m)" in
            Darwin-arm64) DEST="berserk-arm64"; ARCH_FLAGS="-arch arm64" ;;
            Darwin-x86_64) DEST="berserk-x64"; ARCH_FLAGS="-m64 -msse4.1" ;;
            Linux-x86_64) DEST="berserk-x64"; ARCH_FLAGS="-m64 -msse4.1" ;;
            *) DEST="berserk"; ARCH_FLAGS="" ;;
        esac
        (cd "$SRC_DIR" && "$CC" $COMMON_FLAGS $ARCH_FLAGS \
            "-DVERSION=\"$VERSION\"" "-DEVALFILE=\"$NETWORK\"" $SOURCES \
            -pthread -lm -o "$OLDPWD/$DEST")
        echo "built engines/$DEST"
        ;;
    *) echo "usage: sh engines/fetch.sh [native|kindle]" >&2; exit 1 ;;
esac
