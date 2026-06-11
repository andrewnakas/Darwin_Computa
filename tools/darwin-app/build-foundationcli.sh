#!/bin/bash
# build-foundationcli.sh — M3: build foundationcli, a NORMAL Objective-C
# Foundation program (compiler-emitted objc_msgSend, NOT a hand-rolled shim like
# akapp.c), and stage it into the guest filesystem at /usr/bin/foundationcli.
#
# Cross-compiles foundationcli.m on the macOS host (Apple clang, x86_64) against
# the *staged guest* dylibs. We keep the akapp loading convention (-nostdlib
# -e _main -no_pie, link the guest dylibs by path so install names point at the
# guest frameworks and it loads under the guest /usr/lib/dyld) — but the SOURCE
# is real Objective-C, so clang emits the genuine ObjC runtime calls. The DELTA
# from akapp is exactly the bit M3 proves: the ObjC runtime + Foundation work
# through the compiler's normal codegen, not a manual objc_msgSend cast.
#
# Crucially we link the staged libobjc.A.dylib so the compiler-emitted
# objc_msgSend / class refs / selector refs resolve to the guest runtime.
#
# Run it (after the rootfs has this staged) with:
#   bash tools/run_darling_cli.sh /usr/bin/foundationcli
# or over shellspawn:
#   BW64_SHELLSPAWN=/usr/bin/foundationcli bash tools/run_darling_cli.sh /usr/bin/darlingserver
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

# 1) Cross-compile. -x objective-c + the .m source => clang emits real ObjC
#    codegen (objc_msgSend, class/selector refs, autorelease). -fno-objc-arc:
#    @autoreleasepool drains the pool explicitly; MRC keeps the link surface
#    minimal (no ARC runtime helpers beyond what libobjc provides) and matches
#    the simple, leak-free lifetime of this short-lived CLI.
BIN="$HERE/foundationcli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/foundationcli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION"
echo "built binary: $BIN"
file "$BIN"

# 2) Install at the guest path /usr/bin/foundationcli in BOTH roots (live overlay
#    + dist stage), same as build-akapp.sh stages the bundle.
install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/foundationcli"
    chmod +x "$rootdir/usr/bin/foundationcli"
    echo "installed: $rootdir/usr/bin/foundationcli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== foundationcli installed at guest /usr/bin/foundationcli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/foundationcli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
