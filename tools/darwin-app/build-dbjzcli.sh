#!/bin/bash
# build-dbjzcli.sh — M33: build dbjzcli, CLI SYNTHESIS #3 (persistence tier):
# SQLite on disk -> NSJSONSerialization -> zlib compress. Stage at /usr/bin/dbjzcli.
# Links the union BY PATH: Foundation + CoreFoundation (M17) + libsqlite3 (M6') +
# libz.1 (M15). C APIs extern (sqlite3 opaque handles, zlib stable ABI; no headers).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"
LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
COREFOUNDATION="$STAGE/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
SQLITE="$STAGE/usr/lib/libsqlite3.dylib"
ZLIB="$STAGE/usr/lib/libz.1.dylib"
for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$COREFOUNDATION" "$SQLITE" "$ZLIB"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done
BIN="$HERE/dbjzcli"
clang -target x86_64-apple-macos10.15 -fno-objc-arc -fobjc-runtime=macosx-10.15 \
    -nostdlib -e _main -Wl,-no_pie -o "$BIN" \
    "$HERE/dbjzcli.m" "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$COREFOUNDATION" "$SQLITE" "$ZLIB"
echo "built binary: $BIN"; file "$BIN"
install_bin() { local r="$1"; install -d "$r/usr/bin"; cp "$BIN" "$r/usr/bin/dbjzcli"; chmod +x "$r/usr/bin/dbjzcli"; echo "installed: $r/usr/bin/dbjzcli"; }
OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"; install_bin "$STAGE"
echo ""; echo "=== dbjzcli installed at guest /usr/bin/dbjzcli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/dbjzcli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
