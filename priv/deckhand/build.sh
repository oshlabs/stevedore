#!/bin/sh
# Rebuilds the checked-in deckhand binaries from deckhand.zig.
#
# Builds are reproducible: the same source and the same pinned Zig version
# yield byte-identical binaries on any host OS/arch (Zig cross-compiles both
# targets natively). CI reruns this script and fails on any byte diff, so the
# checked-in blobs are verifiable, not trusted.
set -eu

ZIG_VERSION=0.16.0
ZIG=${ZIG:-zig}

have=$("$ZIG" version)
if [ "$have" != "$ZIG_VERSION" ]; then
  echo "error: need zig $ZIG_VERSION, found $have" >&2
  echo "get it from https://ziglang.org/download/#release-$ZIG_VERSION" >&2
  exit 1
fi

cd "$(dirname "$0")"

"$ZIG" build-exe deckhand.zig -O ReleaseSmall -target x86_64-linux -fstrip -femit-bin=deckhand-x86_64
"$ZIG" build-exe deckhand.zig -O ReleaseSmall -target aarch64-linux -fstrip -femit-bin=deckhand-aarch64
rm -f deckhand-x86_64.o deckhand-aarch64.o

ls -l deckhand-x86_64 deckhand-aarch64
