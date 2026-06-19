#!/bin/bash
# build-x2jcli.sh — M32: build x2jcli, CLI SYNTHESIS #2 (cross-tier): libxml2 XPath
# -> NSJSONSerialization -> AES-256-CBC enc/dec. Stage at /usr/bin/x2jcli. Links the
# union BY PATH: Foundation + CoreFoundation (M17) + libxml2.2 (M18) + libcrypto.44
# (M21). C APIs extern (no headers staged; libxml2 structs mirrored head-prefix).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"
LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
COREFOUNDATION="$STAGE/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
LIBXML="$STAGE/usr/lib/libxml2.2.dylib"
LIBCRYPTO="$STAGE/usr/lib/libcrypto.44.dylib"
for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$COREFOUNDATION" "$LIBXML" "$LIBCRYPTO"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done
BIN="$HERE/x2jcli"
clang -target x86_64-apple-macos10.15 -fno-objc-arc -fobjc-runtime=macosx-10.15 \
    -nostdlib -e _main -Wl,-no_pie -o "$BIN" \
    "$HERE/x2jcli.m" "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$COREFOUNDATION" "$LIBXML" "$LIBCRYPTO"
echo "built binary: $BIN"; file "$BIN"
install_bin() { local r="$1"; install -d "$r/usr/bin"; cp "$BIN" "$r/usr/bin/x2jcli"; chmod +x "$r/usr/bin/x2jcli"; echo "installed: $r/usr/bin/x2jcli"; }
OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"; install_bin "$STAGE"
echo ""; echo "=== x2jcli installed at guest /usr/bin/x2jcli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/x2jcli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
