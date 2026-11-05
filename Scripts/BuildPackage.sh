#!/bin/sh
# Builds build/Lioness-<version>.pkg: appkitd, the renderer, the Ammonia tweak, and the page and script that fetch or unpack
# Mountain Lion on the user's machine. It holds none of Apple's files, and is unsigned. Building it needs the Xcode tools and
# an ml-root (Scripts/ExtractImage.sh); installing it needs neither.
#   Scripts/BuildPackage.sh [version]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-2.0.0}
BUILD="$ROOT/build"
STAGE="$BUILD/pkg-root"
HOME_STAGE="$STAGE/Library/Lioness"
PLUGINS="$BUILD/pkg-plugins"
BUNDLE="$PLUGINS/LionessImage.bundle"
OUT="$BUILD/Lioness-$VERSION.pkg"
RENDERER="$ROOT/ml-root/usr/libexec/lioness/renderer"
cmake --build "$BUILD" --target appkitd LionessAqua LionessRenderer
chmod -R u+w "$STAGE" 2>/dev/null || true
rm -rf "${BUILD:?}/pkg-root" "${BUILD:?}/pkg-plugins" "${OUT:?}"
mkdir -p "$HOME_STAGE/tweak" "$BUNDLE/Contents/MacOS"

cp "$BUILD/appkitd" "$RENDERER" "$HOME_STAGE/"
cp "$BUILD/libLionessAqua.dylib" "$HOME_STAGE/tweak/"
cp "$ROOT/Package/LionessSetup.sh" "$ROOT/Package/Uninstall.sh" "$ROOT/Package/libLionessAqua.dylib.blacklist" "$ROOT/Package/flavours-names.txt" \
   "$ROOT/Package/com.lioness.appkitd.plist" "$ROOT/Package/com.lioness.setup.plist" "$HOME_STAGE/"
codesign -f -s - "$HOME_STAGE/appkitd" "$HOME_STAGE/tweak/libLionessAqua.dylib"
# The daemon runs as nobody, and everything it reads must be readable by it.
chmod -R a+rX,go-w "$HOME_STAGE"
chmod 755 "$HOME_STAGE/appkitd" "$HOME_STAGE/LionessSetup.sh" "$HOME_STAGE/Uninstall.sh"
chmod 755 "$ROOT/Package/Scripts/preinstall" "$ROOT/Package/Scripts/postinstall"
find "$STAGE" -type f -exec xattr -c {} +   # or pkgbuild writes them out as ._ files
# The page runs in Installer's plugin service, which is arm64e or x86_64.
sed "s/VERSION/$VERSION/g" "$ROOT/Package/Plugin/Info.plist" > "$BUNDLE/Contents/Info.plist"
clang -arch arm64e -arch x86_64 -mmacosx-version-min=11.0 -bundle -fobjc-arc -Wno-deprecated-declarations \
    -framework Cocoa -framework InstallerPlugins \
    "$ROOT/Package/Plugin/LionessImage.m" -o "$BUNDLE/Contents/MacOS/LionessImage"
codesign -f -s - "$BUNDLE"
cp "$ROOT/Package/Plugin/InstallerSections.plist" "$PLUGINS/"
sed "s/VERSION/$VERSION/g" "$ROOT/Package/Distribution.xml" > "$BUILD/Distribution.xml"
pkgbuild --root "$STAGE" --identifier com.lioness.appkit --version "$VERSION" --ownership recommended \
    --scripts "$ROOT/Package/Scripts" --install-location / "$BUILD/Lioness-component.pkg"
productbuild --distribution "$BUILD/Distribution.xml" --plugins "$PLUGINS" --package-path "$BUILD" "$OUT"
rm -f "${BUILD:?}/Lioness-component.pkg"
ls -la "$OUT"
