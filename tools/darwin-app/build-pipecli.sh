#!/bin/bash
# build-pipecli.sh — M31: build pipecli, a CLI SYNTHESIS composing four proven
# capabilities (JSON parse + NSPredicate filter + NSKeyedArchiver + SHA-256) into one
# data pipeline, and stage it at /usr/bin/pipecli.
#
# Same loading convention as the other probes (-nostdlib -e _main -no_pie against the
# staged guest dylibs). This one links the UNION of what the composed capabilities
# need, all BY PATH:
#   - Foundation                      (JSON / NSPredicate / NSKeyedArchiver / NSData)
#   - CoreFoundation                  (the CF-resident classes — the M17 finding)
#   - libcrypto.44 (modern OpenSSL)   (SHA-256 — the M20/M4c layer, NOT 0.9.x)
# SHA256 is declared extern (no openssl headers staged).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
COREFOUNDATION="$STAGE/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
LIBCRYPTO="$STAGE/usr/lib/libcrypto.44.dylib"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$COREFOUNDATION" "$LIBCRYPTO"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/pipecli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/pipecli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$COREFOUNDATION" \
    "$LIBCRYPTO"
echo "built binary: $BIN"
file "$BIN"

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/pipecli"
    chmod +x "$rootdir/usr/bin/pipecli"
    echo "installed: $rootdir/usr/bin/pipecli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== pipecli installed at guest /usr/bin/pipecli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/pipecli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
