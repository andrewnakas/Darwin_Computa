#!/bin/bash
# build-aescli.sh — M21: build aescli, a AES-256-CBC symmetric encryption probe on
# the MODERN staged libcrypto (OpenSSL), and stage it at /usr/bin/aescli.
#
# Same loading convention as the other C-library probes (zcli/xpathcli/arccli):
# -nostdlib -e _main -no_pie against the staged guest dylibs, + libobjc + Foundation
# (for the NSString cross-check) + the MODERN libcrypto BY PATH.
#
# CRYPTO CHOICE (the M4c lesson): link libcrypto.44.dylib (modern OpenSSL), NOT the
# ancient libcrypto.0.9.x or the bare libcrypto.dylib symlink (which points at 0.9.x).
# The modern lib exports the full EVP digest API + HMAC + OpenSSL_version we use.
# The C API is declared extern in the source (no openssl headers staged; EVP_MD_CTX
# is an opaque handle and digest sizes are fixed constants, ABI-validated header-free
# on host).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
LIBCRYPTO="$STAGE/usr/lib/libcrypto.44.dylib"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$LIBCRYPTO"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/aescli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/aescli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$LIBCRYPTO"
echo "built binary: $BIN"
file "$BIN"

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/aescli"
    chmod +x "$rootdir/usr/bin/aescli"
    echo "installed: $rootdir/usr/bin/aescli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== aescli installed at guest /usr/bin/aescli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/aescli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
