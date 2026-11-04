#!/bin/sh
# Rebuilds, restarts appkitd, draws the gallery with the dylib, and reports daemon failures.
#   Scripts/Gallery.sh <out.png>
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$1
cmake --build "$ROOT/build" 2>&1 | grep -E 'error|FAILED' | cut -c1-200 | head
for f in appkitd AquaGallery libLionessAqua.dylib; do codesign -f -s - "$ROOT/build/$f" 2>/dev/null; done
rm -f "$ROOT/build/appkitd.log"
"$ROOT/Scripts/Appkitd.sh" start >/dev/null
sleep 1
LIONESS_DUMP=1 LIONESS_FORCE_ACTIVE=1 DYLD_INSERT_LIBRARIES="$ROOT/build/libLionessAqua.dylib" timeout 60 "$ROOT/build/AquaGallery" "$OUT" > "$OUT.out" 2>&1
echo "gallery exit=$?"
grep -aE 'guest stopped|host signal|bytes:|frames:' "$ROOT/build/appkitd.log" | cut -c1-170
"$ROOT/Scripts/Appkitd.sh" status | head -1
