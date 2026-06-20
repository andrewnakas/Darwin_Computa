#!/bin/bash
# build-fmtcli.sh — M47: build fmtcli, a normal Objective-C Foundation program
# exercising NSString formatting + NSMutableString building, and
# stage it at the guest /usr/bin/fmtcli.
#
# Same cross-compile convention as build-fmcli.sh (-nostdlib -e _main -no_pie,
# link the staged guest dylibs BY PATH so install names point at the guest
# frameworks and it loads under the guest /usr/lib/dyld), with ONE crucial delta:
#
#   We ALSO link CoreFoundation BY PATH.
#
# WHY (this resolves the M8 "NSCharacterSet not resolvable by-path" gotcha):
# NSDate / NSCalendar / NSLocale / NSTimeZone / NSDateComponents — like
# NSCharacterSet — are DEFINED in CoreFoundation and only imported (U) into
# Foundation, which re-exports CoreFoundation. Linking Foundation by path does
# NOT pull its re-export targets by path, so those classes go unresolved at link
# time. Linking CoreFoundation by path too makes them resolve directly.
#
# Run it (after the rootfs has this staged):
#   BW64_SHELLSPAWN=/usr/bin/fmtcli bash tools/run_darling_cli.sh /usr/bin/darlingserver
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
COREFOUNDATION="$STAGE/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$COREFOUNDATION"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

# 1) Cross-compile. Real ObjC codegen; CoreFoundation linked by path so the
#    NSDate/NSCalendar family (defined there, re-exported by Foundation) resolves.
BIN="$HERE/fmtcli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/fmtcli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$COREFOUNDATION"
echo "built binary: $BIN"
file "$BIN"

# 2) Install at the guest path /usr/bin/fmtcli in BOTH roots (live overlay +
#    dist stage).
install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/fmtcli"
    chmod +x "$rootdir/usr/bin/fmtcli"
    echo "installed: $rootdir/usr/bin/fmtcli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== fmtcli installed at guest /usr/bin/fmtcli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/fmtcli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
