#!/bin/sh
# Starts and stops appkitd as a launchd job in this login session. launchd owns the Mach service name,
# so this is what makes com.lioness.appkitd findable. The plist is generated in build/ rather than
# installed in LaunchAgents, so nothing survives a logout.
#   Scripts/Appkitd.sh start | stop | status
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LABEL=com.lioness.appkitd
PLIST="$ROOT/build/$LABEL.plist"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
    start)
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        # bootout returns before the job is gone, and bootstrapping over it fails with an I/O error.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
            sleep 0.3
        done
        cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array>
        <string>$ROOT/build/appkitd</string>
        <string>$ROOT/ml-root</string>
    </array>
    <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardErrorPath</key><string>$ROOT/build/appkitd.log</string>
    <key>StandardOutPath</key><string>$ROOT/build/appkitd.log</string>
</dict></plist>
EOF
        launchctl bootstrap "$DOMAIN" "$PLIST"
        echo "started $LABEL"
        ;;
    stop)
        launchctl bootout "$DOMAIN/$LABEL" && echo "stopped $LABEL"
        ;;
    status)
        launchctl print "$DOMAIN/$LABEL" | grep -E 'state =|pid =|last exit' || true
        ;;
    *)
        echo "usage: $0 start|stop|status" >&2; exit 2
        ;;
esac
