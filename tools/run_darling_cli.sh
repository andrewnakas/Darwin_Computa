#!/bin/bash
# run_darling_cli.sh — launch a macOS (Mach-O) program headless under emulated
# Darling, through the full Darwin_Computa kernel. The Darwin analogue of
# tools/run_wine64.sh: it points the emulator's --darwin-run at the staged
# Darling rootfs zips (built by tools/rootfs-darling/build-darling-zip.sh) and
# runs mldr -> dyld -> the Mach-O.
#
# Usage: tools/run_darling_cli.sh <guest-macho> [args...]
#   e.g. tools/run_darling_cli.sh /usr/bin/sw_vers
#
# Useful env:
#   BW64_DEVMACHTRACE=1  trace every Mach trap the guest issues (the discovery
#                        loop's primary instrument)
#   BW64_SYSTRACE=1      trace Linux syscalls (find the next unimplemented one)
#   DARWIN_MLDR=...      override the guest path to mldr (default
#                        /usr/libexec/darling/mldr)
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RF="$ROOT_DIR/tools/rootfs-darling"
DIST="$RF/dist"

# --darwin-run resolves the rootfs from the executable's local data dir (on
# macOS: ~/Library/Application Support/Boxedwine/rootfs-darling). Mirror the
# staged zips/root there so the launcher finds them, the same way the build
# script's output is consumed.
LOCALDIR="$HOME/Library/Application Support/Boxedwine/rootfs-darling"

# Locate a Darwin_Computa build. Prefer the agent-driven build_darwin tree; fall
# back to any DerivedData Debug/Release build.
BOX="$ROOT_DIR/project/mac-xcode/Boxedwine/build_darwin/Build/Products/Debug/Boxedwine.app/Contents/MacOS/Boxedwine"
if [ ! -x "$BOX" ]; then
    for p in "$ROOT_DIR/project/mac-xcode"/build_*/Build/Products/*/Boxedwine.app/Contents/MacOS/Boxedwine \
             "$HOME/Library/Developer/Xcode/DerivedData"/Boxedwine-*/Build/Products/*/Boxedwine.app/Contents/MacOS/Boxedwine; do
        [ -x "$p" ] && BOX="$p"
    done
fi
[ -x "$BOX" ] || { echo "error: no Darwin_Computa build found (build the Boxedwine scheme first)" >&2; exit 1; }

if [ $# -lt 1 ]; then
    echo "usage: $0 <guest-macho> [args...]   e.g. $0 /usr/bin/sw_vers" >&2
    exit 2
fi

# Make the staged rootfs visible at the location --darwin-run reads. If the
# build script staged into tools/rootfs-darling/dist, mirror it into LOCALDIR.
if [ -d "$DIST" ] && [ ! -d "$LOCALDIR/dist" ]; then
    mkdir -p "$LOCALDIR"
    ln -sfn "$DIST" "$LOCALDIR/dist"
    mkdir -p "$LOCALDIR/root"
fi
if [ ! -e "$DIST/darling.zip" ]; then
    echo "warning: $DIST/darling.zip not found — run tools/rootfs-darling/build-darling-zip.sh first." >&2
    echo "         (proceeding so you can still see the boot reach open(/dev/mach))" >&2
fi

echo "=== Darwin_Computa: $BOX ==="
echo "=== guest: $* ==="
exec "$BOX" --darwin-run "$@"
