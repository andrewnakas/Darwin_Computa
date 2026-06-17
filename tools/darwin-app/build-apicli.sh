#!/bin/bash
# build-apicli.sh — M4c: build apicli, an HTTPS/TLS client over the raw socket
# bridge using the staged MODERN OpenSSL, and stage it at /usr/bin/apicli.
#
# CRITICAL: link libssl.46.dylib + libcrypto.44.dylib EXPLICITLY. The default
# libssl.dylib symlink points at ancient OpenSSL 0.9.8 (TLS1.0-only, which modern
# servers reject); only the numbered .46/.44 pair is modern (TLS_client_method,
# TLS 1.2/1.3). Same loading convention as foundationcli/netcli (-nostdlib
# -e _main -no_pie against the staged guest dylibs) + libobjc + Foundation for the
# NSString content check.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"
L="$STAGE/usr/lib"

LIBSYSTEM="$L/libSystem.B.dylib"
LIBOBJC="$L/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
LIBSSL="$L/libssl.46.dylib"        # modern (TLS 1.3); NOT the 0.9.8 libssl.dylib symlink
LIBCRYPTO="$L/libcrypto.44.dylib"  # the libcrypto libssl.46 links against

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$LIBSSL" "$LIBCRYPTO"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/apicli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/apicli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$LIBSSL" \
    "$LIBCRYPTO"
echo "built binary: $BIN"
file "$BIN"
echo "linked TLS libs:"; otool -L "$BIN" | grep -iE "libssl|libcrypto" || true

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/apicli"
    chmod +x "$rootdir/usr/bin/apicli"
    echo "installed: $rootdir/usr/bin/apicli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== apicli installed at guest /usr/bin/apicli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/apicli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
