#!/bin/sh
# Runs a test app through LaunchServices so it really has focus, and captures its window from this shell (a child
# of the app would not have screen-capture permission). The app comes to the front for several seconds.
#   Scripts/Focused.sh <work dir> gallery   -> <work dir>/<name>.png, <name>.txt, <name>.log
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
F=$1; NAME=$2
D="$ROOT/build/libLionessAqua.dylib"
rm -f "$F/$NAME.png" "$F/$NAME.txt" "$F/$NAME.log"
if [ "$NAME" = gallery ]; then
    B="$F/Gallery.app/Contents"
    mkdir -p "$B/MacOS"
    cp "$ROOT/build/AquaGallery" "$B/MacOS/Gallery"
    cat > "$B/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.lioness.gallery-test</string><key>CFBundleExecutable</key><string>Gallery</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleName</key><string>Gallery</string></dict></plist>
PLIST
    codesign -f -s - "$F/Gallery.app" 2>/dev/null
    open -n "$F/Gallery.app" --stdout "$F/$NAME.log" --env DYLD_INSERT_LIBRARIES="$D" --env PROBE_VISIBLE=1 --env PROBE_LABELS=1 --env PROBE_HOLD="$F/$NAME.txt" --args "$F/$NAME.unused.png"
fi
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$F/$NAME.txt" ] && break; sleep 0.5; done
cat "$F/$NAME.txt"
sleep 0.5
/usr/sbin/screencapture -x -o -l"$(cut -d' ' -f1 "$F/$NAME.txt")" "$F/$NAME.png"
sleep 5
