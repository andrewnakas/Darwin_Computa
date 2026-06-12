#!/bin/bash
# build-jscli.sh — M5a: build jscli, a JavaScriptCore execution probe, and stage
# it at /usr/bin/jscli.
#
# Same loading convention as the other probes (-nostdlib -e _main -no_pie against
# the staged guest dylibs) + libobjc + Foundation, linking the staged
# JavaScriptCore.framework binary by path. JSC C API is declared extern in the
# source (no JSC headers are staged).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
JSC="$STAGE/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$JSC"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/jscli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/jscli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$JSC"
echo "built binary: $BIN"
file "$BIN"

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/jscli"
    chmod +x "$rootdir/usr/bin/jscli"
    echo "installed: $rootdir/usr/bin/jscli"
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== jscli installed at guest /usr/bin/jscli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/jscli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
