#!/bin/bash
# build-reportcli.sh — M50: CAPSTONE CLI SYNTHESIS (NSFileHandle read -> JSON ->
# NSPredicate filter+sort -> NSString report -> HMAC-SHA256). Stage at /usr/bin/reportcli.
# Links Foundation + CoreFoundation (M17) + libcrypto.44 (M20) BY PATH; HMAC extern.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"
LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"; LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
COREFOUNDATION="$STAGE/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
LIBCRYPTO="$STAGE/usr/lib/libcrypto.44.dylib"
for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$COREFOUNDATION" "$LIBCRYPTO"; do
  [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }; done
BIN="$HERE/reportcli"
clang -target x86_64-apple-macos10.15 -fno-objc-arc -fobjc-runtime=macosx-10.15 \
  -nostdlib -e _main -Wl,-no_pie -o "$BIN" \
  "$HERE/reportcli.m" "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$COREFOUNDATION" "$LIBCRYPTO"
echo "built binary: $BIN"; file "$BIN"
install_bin() { local r="$1"; install -d "$r/usr/bin"; cp "$BIN" "$r/usr/bin/reportcli"; chmod +x "$r/usr/bin/reportcli"; echo "installed: $r/usr/bin/reportcli"; }
OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"; install_bin "$STAGE"
echo ""; echo "=== reportcli installed at guest /usr/bin/reportcli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/reportcli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
