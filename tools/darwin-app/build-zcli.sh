#!/bin/bash
# build-zcli.sh — M6' (M6 pivot): build zcli, a direct libsqlite3
# persistence probe, and stage it at /usr/bin/zcli.
#
# Same loading convention as the other probes (-nostdlib -e _main -no_pie against
# the staged guest dylibs) + libobjc + Foundation (for the NSString cross-check)
# + the staged libsqlite3.dylib by path. The zlib C API is declared extern in
# the source (no sqlite3.h is staged). This sidesteps Darling's broken Cocotron
# CoreData (M6) and proves real on-disk DB persistence on the layer that works.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
ZLIB="$STAGE/usr/lib/libz.1.dylib"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$ZLIB"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/zcli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/zcli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$ZLIB"
echo "built binary: $BIN"
file "$BIN"

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/zcli"
    chmod +x "$rootdir/usr/bin/zcli"
    echo "installed: $rootdir/usr/bin/zcli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== zcli installed at guest /usr/bin/zcli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/zcli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
