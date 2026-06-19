#!/bin/bash
# build-xpathcli.sh — M18: build xpathcli, a DIRECT libxml2 probe exercising XPath
# queries + DOM tree navigation (a deeper, new capability over M8's NSXMLParser SAX
# wrapper), and stage it at /usr/bin/xpathcli.
#
# Same loading convention as the other C-library probes (zcli/sqlitecli): -nostdlib
# -e _main -no_pie against the staged guest dylibs, + libobjc + Foundation (for the
# NSString cross-check) + the staged libxml2.2.dylib BY PATH. The libxml2 C API is
# declared extern in the source (no libxml/*.h staged; the ABI is stable and the
# few structs we touch are mirrored by their head prefix). libxml2 is clean and
# self-contained (deps: libSystem/libicucore/libz/libc++), so its indirect libs
# resolve at load time under the guest dyld, like zcli's libz.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
LIBXML="$STAGE/usr/lib/libxml2.2.dylib"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$LIBXML"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/xpathcli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/xpathcli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$LIBXML"
echo "built binary: $BIN"
file "$BIN"

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/xpathcli"
    chmod +x "$rootdir/usr/bin/xpathcli"
    echo "installed: $rootdir/usr/bin/xpathcli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== xpathcli installed at guest /usr/bin/xpathcli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/xpathcli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
