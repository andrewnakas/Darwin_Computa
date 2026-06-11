#!/bin/bash
# build-netcli.sh — M4: build netcli, a Foundation NSURLSession networking probe
# (real Objective-C, compiler-emitted objc_msgSend), and stage it at the guest
# path /usr/bin/netcli.
#
# Same loading convention as foundationcli/akapp (-nostdlib -e _main -no_pie
# against the staged guest dylibs), linking the frameworks NSURLSession needs:
# Foundation + CFNetwork (URL loading) + libobjc (runtime) + libSystem
# (libdispatch for the semaphore, BSD sockets for the raw tier).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
CFNETWORK="$STAGE/System/Library/Frameworks/CFNetwork.framework/CFNetwork"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$CFNETWORK"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/netcli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/netcli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$CFNETWORK"
echo "built binary: $BIN"
file "$BIN"

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/netcli"
    chmod +x "$rootdir/usr/bin/netcli"
    echo "installed: $rootdir/usr/bin/netcli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== netcli installed at guest /usr/bin/netcli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/netcli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
