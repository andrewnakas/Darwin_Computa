#!/bin/bash
# build-arccli.sh — M19: build arccli, a libarchive tar create+extract probe (a
# structured-archive capability above M15's raw zlib), and stage it at
# /usr/bin/arccli.
#
# Same loading convention as the other C-library probes (zcli/xpathcli): -nostdlib
# -e _main -no_pie against the staged guest dylibs, + libobjc + Foundation (for the
# NSString cross-check) + the staged libarchive.2.dylib BY PATH. The libarchive C
# API is declared extern in the source (no archive.h staged; archive/archive_entry
# are opaque pointers, validated header-free on host). libarchive is clean and
# self-contained (deps libSystem/liblzma/libz/libbz2/libiconv), so its indirect
# libs resolve at load time under the guest dyld, like zcli's libz.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
LIBARCHIVE="$STAGE/usr/lib/libarchive.2.dylib"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$LIBARCHIVE"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/arccli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/arccli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$LIBARCHIVE"
echo "built binary: $BIN"
file "$BIN"

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/arccli"
    chmod +x "$rootdir/usr/bin/arccli"
    echo "installed: $rootdir/usr/bin/arccli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== arccli installed at guest /usr/bin/arccli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/arccli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
