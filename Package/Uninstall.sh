#!/bin/sh
# Removes everything the Lioness package installed, blacklist included. Apps keep the tweak until they quit.
#   sudo /Library/Lioness/Uninstall.sh
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
launchctl bootout system/com.lioness.setup 2>/dev/null
launchctl bootout system/com.lioness.appkitd 2>/dev/null
launchctl bootout system/com.lioness.skylightaugmentord 2>/dev/null
u=$(stat -f%u /dev/console 2>/dev/null || echo 0)
[ "${u:-0}" != 0 ] && launchctl bootout "gui/$u/com.lioness.menud" 2>/dev/null || true
pkill -x LionessSpotlight 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.lioness.appkitd.plist /Library/LaunchDaemons/com.lioness.skylightaugmentord.plist /Library/LaunchDaemons/com.lioness.setup.plist /Library/LaunchAgents/com.lioness.menud.plist
rm -f /private/var/ammonia/core/tweaks/libLionessAqua.dylib /private/var/ammonia/core/tweaks/libLionessAqua.dylib.blacklist /private/var/ammonia/core/tweaks/libLionessAqua.dylib.whitelist /private/var/ammonia/core/tweaks/libLionessAqua.whitelist /private/var/ammonia/core/tweaks/.com.lioness.appkitd.token \
      /private/var/ammonia/core/tweaks/libLionessMenus.dylib /private/var/ammonia/core/tweaks/libLionessMenus.dylib.blacklist /private/var/ammonia/core/tweaks/.com.lioness.menud.token
rm -rf /Library/Lioness /Users/Shared/.lioness-setup
pkgutil --forget com.lioness.appkit >/dev/null 2>&1
pkgutil --forget com.lioness.aqua >/dev/null 2>&1
echo "Lioness removed"
