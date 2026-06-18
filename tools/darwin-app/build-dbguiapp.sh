#!/bin/bash
# build-dbguiapp.sh — M11 (SYNTHESIS): build DbGui.app, an AppKit GUI app that runs
# JavaScript through JavaScriptCore and shows the result in its window. Composes the
# proven GUI chain (S37/S38) with libsqlite3 (M6'). Installed at the guest path
# /Applications/DbGui.app (launched via the proven bundle path, like DarwinComputa.app).
#
# Cross-compiles dbguiapp.c against the *staged guest* dylibs with the akapp loading
# convention (-nostdlib -e _main -no_pie) PLUS JavaScriptCore.framework.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
COREGRAPHICS="$STAGE/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
APPKIT="$STAGE/System/Library/Frameworks/AppKit.framework/AppKit"
SQLITE="$STAGE/usr/lib/libsqlite3.dylib"

for f in "$LIBSYSTEM" "$COREGRAPHICS" "$FOUNDATION" "$APPKIT" "$SQLITE"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/DbGui"
clang \
    -target x86_64-apple-macos10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/dbguiapp.c" \
    "$LIBSYSTEM" \
    "$COREGRAPHICS" \
    "$FOUNDATION" \
    "$APPKIT" \
    "$SQLITE"
echo "built binary: $BIN"
file "$BIN"

APP_REL="Applications/DbGui.app"
install_bundle() {
    local rootdir="$1"
    local app="$rootdir/$APP_REL"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$HERE/DbGui-Info.plist" "$app/Contents/Info.plist"
    cp "$BIN"                   "$app/Contents/MacOS/DbGui"
    chmod +x                    "$app/Contents/MacOS/DbGui"
    echo "installed bundle: $app"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
mkdir -p "$OVERLAY/Applications"; install_bundle "$OVERLAY"
mkdir -p "$STAGE/Applications";   install_bundle "$STAGE"

echo ""
echo "=== DbGui.app installed at guest /Applications/DbGui.app ==="
echo "Launch:  bash tools/run_darling_app_bundle.sh /Applications/DbGui.app"
