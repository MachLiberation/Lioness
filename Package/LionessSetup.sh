#!/bin/sh
# Builds the Mountain Lion root appkitd runs, from Apple's installer image, then turns Lioness on.
# Needs nothing beyond macOS itself: no Xcode tools. Nothing from the image is run natively; the disk images are
# mounted read-only and their contents only copied as data.
#
#   sudo /Library/Lioness/LionessSetup.sh download        fetch Apple's image and use it
#   sudo /Library/Lioness/LionessSetup.sh /path/to.dmg    use this image
#   sudo /Library/Lioness/LionessSetup.sh keep            use the root that is already there
#   LionessSetup.sh --extract image.dmg outdir            only copy the files out (for development)
#
# Accepts InstallMacOSX.dmg as Apple serves it, InstallESD.dmg, or an image holding the Install app.
# The work folder needs about 7 GB with an image, 11 GB when downloading, and is deleted afterwards.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

HOME_DIR=${LIONESS_HOME:-/Library/Lioness}
URL=https://updates.cdn-apple.com/2021/macos/031-0627-20210614-90D11F33-1A65-42DD-BBEA-E1D9F43A6B3F/InstallMacOSX.dmg
SIZE=4449317520
# The renderer patches into this exact build of CoreUI, so this is what decides whether an image is usable.
COREUI_MD5=321891e887e4c674a4d1667fad9427f8
COREUI=System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/CoreUI
WORK=${LIONESS_WORK:-$HOME_DIR/setup-work}
ROOT_DIR=$HOME_DIR/ml-root
STATE=$HOME_DIR/setup.state
SOURCE_FILE=$HOME_DIR/setup.source
SETUP_PLIST=/Library/LaunchDaemons/com.lioness.setup.plist
IN_JOB=0
MOUNTS=""

say() { echo "LionessSetup: $*"; }

console_uid() {
    u=$(stat -f%u /dev/console 2>/dev/null) || u=0
    [ "${u:-0}" != 0 ] && echo "$u"
}
tell_user() {   # kind(notification|alert) text
    [ "$(id -u)" = 0 ] || return 0
    u=$(console_uid) || return 0
    if [ "$1" = alert ]; then
        launchctl asuser "$u" osascript -e "display alert \"Lioness\" message \"$2\"" >/dev/null 2>&1 &
    else
        launchctl asuser "$u" osascript -e "display notification \"$2\" with title \"Lioness\"" >/dev/null 2>&1 &
    fi
}
detach_all() {
    for m in $MOUNTS; do hdiutil detach -quiet "$m" 2>/dev/null || hdiutil detach -quiet -force "$m" 2>/dev/null || true; done
    MOUNTS=""
}
end_job() {   # The job is finished either way, and must not run again at the next boot.
    [ "$IN_JOB" = 1 ] || return 0
    rm -f "$SETUP_PLIST"
    launchctl bootout system/com.lioness.setup 2>/dev/null   # ends this script
}
fail() {
    say "failed: $*" >&2
    detach_all
    rm -rf "${HOME_DIR:?}/ml-root.new"
    [ -d "$HOME_DIR" ] && echo failed > "$STATE" 2>/dev/null
    tell_user alert "Lioness could not set up Mountain Lion: $*

To try again: sudo /Library/Lioness/LionessSetup.sh download
or: sudo /Library/Lioness/LionessSetup.sh /path/to/InstallMacOSX.dmg"
    sleep 1
    end_job
    exit 1
}

need_space() {   # gigabytes, on the volume holding the work folder
    free=$(df -k "$HOME_DIR" | awk 'NR==2 {print $4}')
    [ "${free:-0}" -ge $(($1 * 1024 * 1024)) ] || fail "needs $1 GB free on the startup disk, and $((${free:-0} / 1024 / 1024)) GB is free."
}

attach() {   # image -> prints the mount point
    mkdir -p "$WORK/mnt"
    plist=$(hdiutil attach -readonly -nobrowse -noverify -noautoopen -mountrandom "$WORK/mnt" -plist "$1" </dev/null 2>/dev/null) || return 1
    printf '%s' "$plist" | plutil -extract system-entities xml1 -o - - |
        grep -A1 '<key>mount-point</key>' | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/' | head -1
}

coreui_good() { [ -f "$1/$COREUI" ] && [ "$(md5 -q "$1/$COREUI")" = "$COREUI_MD5" ]; }
root_good() {
    coreui_good "$1" && [ -f "$1/usr/lib/dyld" ] && [ -f "$1/usr/lib/libSystem.B.dylib" ] &&
        [ -f "$1/System/Library/CoreServices/SystemVersion.plist" ]
}

extract() {   # image out
    image=$1; out=$2
    [ -r "$image" ] || fail "cannot read $image. If it is in Downloads, Desktop or Documents, macOS may be keeping this job out: move it to /Users/Shared and try again."
    mkdir -p "$WORK"
    rm -f "${WORK:?}/InstallESD.dmg"; rm -rf "${WORK:?}/InstallMacOSX.pkg"

    say "mounting $image"
    top=$(attach "$image") && [ -n "$top" ] || fail "$image is not a disk image macOS can open."
    MOUNTS="$top $MOUNTS"
    # The image may be any layer of Apple's nesting.
    if [ -f "$top/BaseSystem.dmg" ]; then
        esd=$top
    else
        inner=""
        if [ -f "$top/InstallMacOSX.pkg" ]; then
            say "unpacking InstallESD.dmg (several minutes)"
            xar -xf "$top/InstallMacOSX.pkg" -C "$WORK" InstallMacOSX.pkg/InstallESD.dmg || fail "could not unpack the installer in $image."
            mv "$WORK/InstallMacOSX.pkg/InstallESD.dmg" "$WORK/InstallESD.dmg"
            inner=$WORK/InstallESD.dmg
        else
            for f in "$top"/*.app/Contents/SharedSupport/InstallESD.dmg "$top"/InstallESD.dmg; do [ -f "$f" ] && inner=$f; done
        fi
        [ -n "$inner" ] || fail "$image is not an OS X installer image."
        esd=$(attach "$inner") && [ -n "$esd" ] || fail "could not open InstallESD.dmg from $image."
        MOUNTS="$esd $MOUNTS"
    fi
    [ -f "$esd/BaseSystem.dmg" ] || fail "$image has no BaseSystem.dmg."
    base=$(attach "$esd/BaseSystem.dmg") && [ -n "$base" ] || fail "could not open BaseSystem.dmg from $image."
    MOUNTS="$base $MOUNTS"
    coreui_good "$base" || fail "$image is not the OS X 10.8.5 Mountain Lion image from Apple's download page (https://support.apple.com/en-us/106387)."

    say "copying the system files"
    mkdir -p "$out"
    for d in usr/lib usr/share/icu bin sbin System/Library/Frameworks System/Library/PrivateFrameworks \
             System/Library/CoreServices/SystemVersion.plist System/Library/Fonts "System/Library/Keyboard Layouts" \
             System/Library/ColorSync System/Library/CoreServices/CoreTypes.bundle; do
        [ -e "$base/$d" ] || continue
        mkdir -p "$out/$(dirname "$d")"
        ditto --norsrc "$base/$d" "$out/$d" || fail "could not copy $d. Is the disk full?"
    done
    detach_all
    root_good "$out" || fail "the copied files are incomplete."
}

prepare_root() {   # What appkitd expects beyond Apple's files.
    r=$1
    if [ -f "$HOME_DIR/renderer" ]; then
        mkdir -p "$r/usr/libexec/lioness"
        cp -f "$HOME_DIR/renderer" "$r/usr/libexec/lioness/renderer" || fail "could not install the renderer."
    fi
    chmod -R a+rX,go-w "$r"
    # The daemon runs as nobody: these are all it may write.
    for d in tmp var/tmp var/run var/log var/db var/folders; do mkdir -p "$r/$d"; chmod 1777 "$r/$d"; done
    mkdir -p "$r/etc"
    printf 'nobody:*:-2:-2::0:0:Nobody:/var/empty:/usr/bin/false\nroot:*:0:0::0:0:System Administrator:/var/root:/bin/sh\n' > "$r/etc/master.passwd"
    printf 'nobody:*:-2:-2:Nobody:/var/empty:/usr/bin/false\nroot:*:0:0:System Administrator:/var/root:/bin/sh\n' > "$r/etc/passwd"
    printf 'nobody:*:-2:\nwheel:*:0:root\n' > "$r/etc/group"
    chmod 644 "$r/etc/master.passwd" "$r/etc/passwd" "$r/etc/group"
}

install_atomically() {   # src dst mode
    cp -f "$1" "$2.new" && chown root:wheel "$2.new" && chmod "$3" "$2.new" && mv -f "$2.new" "$2"
}

activate() {   # The tweak and the daemon go on only now, so no app is ever injected ahead of a working root.
    if [ "$HOME_DIR" != /Library/Lioness ] || [ "$(id -u)" != 0 ]; then
        say "not the installed copy or not root: leaving the tweak and daemon alone"
        return 0
    fi
    tweaks=/private/var/ammonia/core/tweaks
    [ -d "$tweaks" ] || fail "Ammonia is not installed: $tweaks does not exist."
    launchctl bootout system/com.lioness.appkitd 2>/dev/null
    rm -f /private/var/ammonia/core/tweaks/.com.lioness.appkitd.token /private/var/ammonia/core/tweaks/libLionessAqua.dylib.whitelist /private/var/ammonia/core/tweaks/libLionessAqua.whitelist
    # New inodes, as running processes may have the old ones mapped.
    install_atomically "$HOME_DIR/tweak/libLionessAqua.dylib" "$tweaks/libLionessAqua.dylib" 755 || fail "could not install the tweak."
    install_atomically "$HOME_DIR/libLionessAqua.dylib.blacklist" "$tweaks/libLionessAqua.dylib.blacklist" 644 || fail "could not install the blacklist."
    install_atomically "$HOME_DIR/com.lioness.appkitd.plist" /Library/LaunchDaemons/com.lioness.appkitd.plist 644 || fail "could not install the daemon."
    launchctl bootstrap system /Library/LaunchDaemons/com.lioness.appkitd.plist || fail "could not start com.lioness.appkitd."
}

setup() {   # download | keep | image path
    what=$1
    echo running > "$STATE"
    image=""
    case "$what" in
    keep)
        root_good "$ROOT_DIR" || fail "there is no usable Mountain Lion root to keep."
        ;;
    download)
        need_space 11
        mkdir -p "$WORK"
        image=$WORK/InstallMacOSX.dmg
        have=$(stat -f%z "$image" 2>/dev/null || echo 0)
        [ "$have" -gt "$SIZE" ] && { rm -f "${image:?}"; have=0; }
        if [ "$have" != "$SIZE" ]; then
            say "downloading $URL (resuming from $have bytes)"
            /usr/bin/curl -fL --retry 10 --retry-delay 15 --retry-all-errors -C - -o "$image" "$URL" || fail "the download from Apple did not finish. It resumes from where it stopped when you try again."
        fi
        [ "$(stat -f%z "$image")" = "$SIZE" ] || { rm -f "${image:?}"; fail "the download from Apple came back the wrong size."; }
        ;;
    *)
        need_space 7
        image=$what
        ;;
    esac
    if [ -n "$image" ]; then
        chmod -R u+w "$HOME_DIR/ml-root.new" 2>/dev/null; rm -rf "${HOME_DIR:?}/ml-root.new"
        extract "$image" "$HOME_DIR/ml-root.new"
        prepare_root "$HOME_DIR/ml-root.new"
        chmod -R u+w "$ROOT_DIR" 2>/dev/null; rm -rf "${HOME_DIR:?}/ml-root"
        mv "$HOME_DIR/ml-root.new" "$ROOT_DIR" || fail "could not put the root in place."
    else
        prepare_root "$ROOT_DIR"
    fi
    activate
    rm -rf "${HOME_DIR:?}/setup-work"
    echo done > "$STATE"
    say "ready: $(du -sh "$ROOT_DIR" | cut -f1) in $ROOT_DIR"
    tell_user notification "Mountain Lion's look is ready. Quit and reopen apps to see it."
    sleep 1
}

trap detach_all EXIT

case "${1:-}" in
--extract)
    [ $# = 3 ] || { echo "usage: $0 --extract image.dmg outdir" >&2; exit 2; }
    HOME_DIR=$3; STATE=/dev/null; WORK=${LIONESS_WORK:-${TMPDIR:-/tmp}/lioness-extract}
    mkdir -p "$3"
    extract "$2" "$3"
    say "done: $(du -sh "$3" | cut -f1) in $3"
    ;;
--check)
    root_good "$ROOT_DIR"
    ;;
--job)
    IN_JOB=1
    mkdir -p "$HOME_DIR/log"
    exec >> "$HOME_DIR/log/setup.log" 2>&1
    say "started $(date)"
    [ -f "$SOURCE_FILE" ] || fail "nothing says which image to use."
    setup "$(cat "$SOURCE_FILE")"
    rm -f "${HOME_DIR:?}/setup.source"
    end_job
    ;;
"" | -h | --help)
    sed -n '6,9p' "$0"
    exit 2
    ;;
*)
    if [ "$HOME_DIR" = /Library/Lioness ] && [ "$(id -u)" != 0 ]; then echo "run with sudo" >&2; exit 1; fi
    mkdir -p "$HOME_DIR/log"
    setup "$1"
    ;;
esac
exit 0
