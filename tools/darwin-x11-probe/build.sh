#!/bin/bash
# Build xprobe — a minimal raw-Xlib client Mach-O for the Darwin guest.
#
# Cross-compiles on the macOS host (Apple clang, x86_64 target) and links
# against the *staged guest* dylibs (libSystem.B.dylib + libX11.dylib) so the
# resulting binary references the guest install names (/usr/lib/libSystem.B.dylib,
# /usr/lib/native/libX11.dylib) and is loaded by the guest /usr/lib/dyld under
# the emulator — NOT the host's. See xprobe.c header for why.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBX11="$STAGE/usr/lib/native/libX11.dylib"

for f in "$LIBSYSTEM" "$LIBX11"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

OUT="$HERE/xprobe"

# -nostdlib: do not pull the HOST SDK's crt1/libSystem — we provide the guest's.
# -e _main: enter directly at main (no crt). The guest dyld + libSystem set up
#   the C runtime; for a probe this minimal (no static initializers, argc/argv
#   unused) jumping straight to _main is sufficient and avoids host crt deps.
# We pass the staged dylibs by path so the linker records THEIR install names.
clang \
    -target x86_64-apple-macos10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$OUT" \
    "$HERE/xprobe.c" \
    "$LIBSYSTEM" \
    "$LIBX11"

echo "built: $OUT"
file "$OUT"
echo "--- load commands (dylinker + dylibs) ---"
otool -l "$OUT" | grep -A2 'LC_LOAD_DYLINKER\|LC_LOAD_DYLIB\|LC_MAIN' | grep -E 'name|entryoff' || true
