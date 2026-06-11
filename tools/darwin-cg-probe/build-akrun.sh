#!/bin/bash
# Build akrun — a minimal AppKit NSWindow probe Mach-O for the Darwin guest (S31).
#
# Mirrors build.sh (cgprobe) but also links AppKit, since the REAL window backend
# (X11Display/X11Window -> XCreateWindow/XMapWindow) lives in AppKit, not CoreGraphics
# (see akrun.c / cgwin.c headers). Cross-compiles on the macOS host (Apple clang,
# x86_64) and links against the *staged guest* dylibs so install names point at the
# guest frameworks and the binary loads under the guest /usr/lib/dyld.
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

OUT="$HERE/akrun"

clang \
    -target x86_64-apple-macos10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$OUT" \
    "$HERE/akrun.c" \
    "$LIBSYSTEM" \
    "$COREGRAPHICS" \
    "$FOUNDATION" \
    "$APPKIT"

echo "built: $OUT"
file "$OUT"
echo "--- load commands (dylinker + dylibs) ---"
otool -l "$OUT" | grep -A2 'LC_LOAD_DYLINKER\|LC_LOAD_DYLIB\|LC_MAIN' | grep -E 'name|entryoff' || true
