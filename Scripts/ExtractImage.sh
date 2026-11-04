#!/bin/sh
# The development root: Scripts/ExtractImage.sh [InstallMacOSX.dmg] [out dir]
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec /bin/sh "$ROOT/Package/LionessSetup.sh" --extract "${1:-$HOME/Downloads/InstallMacOSX (Mountain Lion).dmg}" "${2:-$ROOT/ml-root}"
