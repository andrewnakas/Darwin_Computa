#!/bin/bash
# Build cgprobe — a minimal CoreGraphics client Mach-O for the Darwin guest (S29).
#
# Cross-compiles on the macOS host (Apple clang, x86_64 target) and links against
# the *staged guest* dylibs (libSystem.B.dylib + CoreGraphics + Foundation) so the
# resulting binary references the guest install names
#   (/usr/lib/libSystem.B.dylib,
#    /System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics,
#    /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation)
# and is loaded by the guest /usr/lib/dyld under the emulator — NOT the host's.
# See cgprobe.c header for why. Mirrors tools/darwin-x11-probe/build.sh (xprobe).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
COREGRAPHICS="$STAGE/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"

for f in "$LIBSYSTEM" "$COREGRAPHICS" "$FOUNDATION"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

OUT="$HERE/cgprobe"

# -nostdlib: do not pull the HOST SDK's crt1/libSystem — we provide the guest's.
# -e _main: enter directly at main (no crt). The guest dyld + libSystem set up
#   the C runtime; cgprobe has no static initializers of its own so jumping
#   straight to _main is sufficient and avoids host crt deps. (Same as xprobe.)
# Foundation is linked because CoreGraphics' _CGSLoadBackend uses NSBundle to
#   enumerate + load the X11.backend bundle; pulling Foundation in as a load
#   dependency guarantees it (and its ObjC runtime) is initialized.
# We pass the staged dylibs by path so the linker records THEIR install names.
clang \
    -target x86_64-apple-macos10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$OUT" \
    "$HERE/cgprobe.c" \
    "$LIBSYSTEM" \
    "$COREGRAPHICS" \
    "$FOUNDATION"

echo "built: $OUT"
file "$OUT"
echo "--- load commands (dylinker + dylibs) ---"
otool -l "$OUT" | grep -A2 'LC_LOAD_DYLINKER\|LC_LOAD_DYLIB\|LC_MAIN' | grep -E 'name|entryoff' || true
