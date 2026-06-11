#!/bin/bash
# build-akapp.sh — build DarwinComputa.app, a REAL Mac .app bundle for the
# Darwin guest (S38), and stage it into the guest filesystem.
#
# Cross-compiles akapp.c on the macOS host (Apple clang, x86_64) against the
# *staged guest* dylibs (same recipe as build-akrun.sh: -nostdlib -e _main
# -no_pie so install names point at the guest frameworks and it loads under the
# guest /usr/lib/dyld), then assembles the bundle:
#
#   DarwinComputa.app/Contents/
#     Info.plist
#     MacOS/DarwinComputa     <- the binary
#     Resources/Welcome.txt   <- a bundle resource read at runtime
#
# and installs it at the guest path /Applications/DarwinComputa.app in BOTH:
#   - the live overlay  (~/Library/Application Support/Boxedwine/rootfs-darling/
#                        root/usr/libexec/darling/Applications/...)
#   - the dist stage tree (tools/rootfs-darling/dist/stage/usr/libexec/darling/
#                        Applications/...)  so build-darling-zip.sh can bake it.
#
# Launch it with: bash tools/run_darling_app_bundle.sh
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
BIN="$HERE/DarwinComputa"
clang \
    -target x86_64-apple-macos10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/akapp.c" \
    "$LIBSYSTEM" \
    "$COREGRAPHICS" \
    "$FOUNDATION" \
    "$APPKIT"
echo "built binary: $BIN"
file "$BIN"

# 2) Assemble the .app bundle under a build dir, then copy it into each guest
#    filesystem root. Helper so overlay + stage get identical trees.
APP_REL="Applications/DarwinComputa.app"
install_bundle() {
    local rootdir="$1"          # the guest's /usr/libexec/darling root
    local app="$rootdir/$APP_REL"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$HERE/Info.plist"   "$app/Contents/Info.plist"
    cp "$BIN"               "$app/Contents/MacOS/DarwinComputa"
    chmod +x               "$app/Contents/MacOS/DarwinComputa"
    cp "$HERE/Welcome.txt"  "$app/Contents/Resources/Welcome.txt"
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
echo "=== DarwinComputa.app installed at guest /Applications/DarwinComputa.app ==="
echo "    Contents/MacOS/DarwinComputa  (exec)"
echo "    Contents/Info.plist           (CFBundleName 'Darwin Computa', id com.darwincomputa.akapp)"
echo "    Contents/Resources/Welcome.txt"
echo ""
echo "Launch:  bash tools/run_darling_app_bundle.sh"
