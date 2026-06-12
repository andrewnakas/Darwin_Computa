#!/bin/bash
# build-sqlitecli.sh — M6' (M6 pivot): build sqlitecli, a direct libsqlite3
# persistence probe, and stage it at /usr/bin/sqlitecli.
#
# Same loading convention as the other probes (-nostdlib -e _main -no_pie against
# the staged guest dylibs) + libobjc + Foundation (for the NSString cross-check)
# + the staged libsqlite3.dylib by path. The SQLite C API is declared extern in
# the source (no sqlite3.h is staged). This sidesteps Darling's broken Cocotron
# CoreData (M6) and proves real on-disk DB persistence on the layer that works.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
SQLITE="$STAGE/usr/lib/libsqlite3.dylib"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$SQLITE"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/sqlitecli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/sqlitecli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$SQLITE"
echo "built binary: $BIN"
file "$BIN"

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/sqlitecli"
    chmod +x "$rootdir/usr/bin/sqlitecli"
    echo "installed: $rootdir/usr/bin/sqlitecli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== sqlitecli installed at guest /usr/bin/sqlitecli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/sqlitecli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
