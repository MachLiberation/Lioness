#!/bin/sh
# Builds a guest program: x86-64, against Lion's own frameworks, installed inside ml-root.
#   Scripts/BuildGuest.sh <source> <name>
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$1; NAME=$2
R=${GUEST_ROOT:-$ROOT/ml-root}
OUT="$R/usr/libexec/lioness/$NAME"
mkdir -p "$(dirname "$OUT")"
clang -arch x86_64 -mmacosx-version-min=10.7 -O1 -w -fno-objc-arc -c "$SRC" -o "$ROOT/build/$NAME.o"
clang -arch x86_64 -mmacosx-version-min=10.7 "$ROOT/build/$NAME.o" -o "$OUT" \
    -F"$R/System/Library/Frameworks" -framework Carbon -framework ApplicationServices -framework CoreFoundation \
    -framework AppKit -framework Foundation \
    -F"$R/System/Library/PrivateFrameworks" -framework CoreUI -Wl,-w 2>&1 | grep -v 'missing indirect' || true
[ -x "$OUT" ] || { echo "guest link failed: $OUT" >&2; exit 1; }
