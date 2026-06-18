#!/bin/bash
# build-jsguiapp.sh — M11 (SYNTHESIS): build JSGui.app, an AppKit GUI app that runs
# JavaScript through JavaScriptCore and shows the result in its window. Composes the
# proven GUI chain (S37/S38) with JavaScriptCore (M5a). Installed at the guest path
# /Applications/JSGui.app (launched via the proven bundle path, like DarwinComputa.app).
#
# Cross-compiles jsguiapp.c against the *staged guest* dylibs with the akapp loading
# convention (-nostdlib -e _main -no_pie) PLUS JavaScriptCore.framework.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
COREGRAPHICS="$STAGE/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
APPKIT="$STAGE/System/Library/Frameworks/AppKit.framework/AppKit"
JSC="$STAGE/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"

for f in "$LIBSYSTEM" "$COREGRAPHICS" "$FOUNDATION" "$APPKIT" "$JSC"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/JSGui"
clang \
    -target x86_64-apple-macos10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/jsguiapp.c" \
    "$LIBSYSTEM" \
    "$COREGRAPHICS" \
    "$FOUNDATION" \
    "$APPKIT" \
    "$JSC"
echo "built binary: $BIN"
file "$BIN"

APP_REL="Applications/JSGui.app"
install_bundle() {
    local rootdir="$1"
    local app="$rootdir/$APP_REL"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$HERE/JSGui-Info.plist" "$app/Contents/Info.plist"
    cp "$BIN"                   "$app/Contents/MacOS/JSGui"
    chmod +x                    "$app/Contents/MacOS/JSGui"
    echo "installed bundle: $app"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
mkdir -p "$OVERLAY/Applications"; install_bundle "$OVERLAY"
mkdir -p "$STAGE/Applications";   install_bundle "$STAGE"

echo ""
echo "=== JSGui.app installed at guest /Applications/JSGui.app ==="
echo "Launch:  bash tools/run_darling_app_bundle.sh /Applications/JSGui.app"
