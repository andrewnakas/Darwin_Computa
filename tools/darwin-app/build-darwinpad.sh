#!/bin/bash
# build-darwinpad.sh — build DarwinPad.app (M1), a TextEdit-style Mac .app bundle
# for the Darwin guest, and stage it into the guest filesystem.
#
# Same cross-build recipe as build-akapp.sh (S38): cross-compile darwinpad.c on the
# macOS host (Apple clang, x86_64) against the *staged guest* dylibs (-nostdlib
# -e _main -no_pie so install names point at the guest frameworks and it loads
# under the guest /usr/lib/dyld), then assemble the bundle:
#
#   DarwinPad.app/Contents/
#     Info.plist
#     MacOS/DarwinPad        <- the binary (real editable text field + menu bar)
#
# and install it at the guest path /Applications/DarwinPad.app in BOTH the live
# overlay and the dist stage tree (so build-darling-zip.sh can bake it).
#
# Launch it with: bash tools/run_darling_app_bundle.sh /Applications/DarwinPad.app
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
COREGRAPHICS="$STAGE/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
APPKIT="$STAGE/System/Library/Frameworks/AppKit.framework/AppKit"

for f in "$LIBSYSTEM" "$COREGRAPHICS" "$FOUNDATION" "$APPKIT"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

# 1) Cross-compile the binary.
BIN="$HERE/DarwinPad"
clang \
    -target x86_64-apple-macos10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/darwinpad.c" \
    "$LIBSYSTEM" \
    "$COREGRAPHICS" \
    "$FOUNDATION" \
    "$APPKIT"
echo "built binary: $BIN"
file "$BIN"

# 2) Assemble the .app bundle and copy it into each guest filesystem root.
APP_REL="Applications/DarwinPad.app"
install_bundle() {
    local rootdir="$1"          # the guest's /usr/libexec/darling root
    local app="$rootdir/$APP_REL"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$HERE/DarwinPad-Info.plist" "$app/Contents/Info.plist"
    cp "$BIN"                       "$app/Contents/MacOS/DarwinPad"
    chmod +x                        "$app/Contents/MacOS/DarwinPad"
    echo "installed bundle: $app"
}

# The live overlay (layers over the read-only zips; no zip rewrite needed).
OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
mkdir -p "$OVERLAY/Applications"
install_bundle "$OVERLAY"

# The dist stage tree (durable; build-darling-zip.sh bakes this into darling.zip).
mkdir -p "$STAGE/Applications"
install_bundle "$STAGE"

echo ""
echo "=== DarwinPad.app installed at guest /Applications/DarwinPad.app ==="
echo "    Contents/MacOS/DarwinPad  (editable text field + field editor + File/Edit menu)"
echo "    Contents/Info.plist       (CFBundleName 'DarwinPad', id com.darwincomputa.darwinpad)"
echo ""
echo "Launch:  bash tools/run_darling_app_bundle.sh /Applications/DarwinPad.app"
