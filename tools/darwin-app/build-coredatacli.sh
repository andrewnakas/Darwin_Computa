#!/bin/bash
# build-coredatacli.sh — M6: build coredatacli, a CoreData persistence probe, and
# stage it at /usr/bin/coredatacli.
#
# Same loading convention as the other probes (-nostdlib -e _main -no_pie against
# the staged guest dylibs) + libobjc + Foundation + CoreData. CoreData pulls in
# libsqlite3 at runtime via its own dependency; we link the framework binary by
# path. The programmatic model means no .momd resource bundle is needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$REPO/tools/rootfs-darling/dist/stage/usr/libexec/darling"

LIBSYSTEM="$STAGE/usr/lib/libSystem.B.dylib"
LIBOBJC="$STAGE/usr/lib/libobjc.A.dylib"
FOUNDATION="$STAGE/System/Library/Frameworks/Foundation.framework/Foundation"
COREDATA="$STAGE/System/Library/Frameworks/CoreData.framework/CoreData"

for f in "$LIBSYSTEM" "$LIBOBJC" "$FOUNDATION" "$COREDATA"; do
    [ -f "$f" ] || { echo "missing staged dylib: $f" >&2; exit 1; }
done

BIN="$HERE/coredatacli"
clang \
    -target x86_64-apple-macos10.15 \
    -fno-objc-arc \
    -fobjc-runtime=macosx-10.15 \
    -nostdlib \
    -e _main \
    -Wl,-no_pie \
    -o "$BIN" \
    "$HERE/coredatacli.m" \
    "$LIBSYSTEM" \
    "$LIBOBJC" \
    "$FOUNDATION" \
    "$COREDATA"
echo "built binary: $BIN"
file "$BIN"

# Compile the CoreData model (.momd) on the host with momc — Darling's Cocotron
# CoreData can't build a model programmatically (NSAttributeDescription -init is an
# abstract stub that throws), so coredatacli loads this compiled model via
# initWithContentsOfURL: instead. Staged at guest /usr/share/m6/Note.momd.
MOMC="$(xcrun --find momc 2>/dev/null || true)"
MODELSRC="$HERE/Note.xcdatamodeld"
MOMD_OUT="$HERE/Note.momd"
if [ -n "$MOMC" ] && [ -d "$MODELSRC" ]; then
    rm -rf "$MOMD_OUT"
    "$MOMC" --action compile "$MODELSRC" "$MOMD_OUT" >/dev/null 2>&1 || true
fi
[ -d "$MOMD_OUT" ] || { echo "warning: Note.momd not compiled (momc missing?)" >&2; }

install_bin() {
    local rootdir="$1"
    install -d "$rootdir/usr/bin"
    cp "$BIN" "$rootdir/usr/bin/coredatacli"
    chmod +x "$rootdir/usr/bin/coredatacli"
    echo "installed: $rootdir/usr/bin/coredatacli"
    if [ -d "$MOMD_OUT" ]; then
        install -d "$rootdir/usr/share/m6"
        rm -rf "$rootdir/usr/share/m6/Note.momd"
        cp -R "$MOMD_OUT" "$rootdir/usr/share/m6/Note.momd"
        echo "installed: $rootdir/usr/share/m6/Note.momd"
    fi
}

OVERLAY="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
install_bin "$OVERLAY"
install_bin "$STAGE"

echo ""
echo "=== coredatacli installed at guest /usr/bin/coredatacli ==="
echo "Run:  BW64_SHELLSPAWN=/usr/bin/coredatacli bash tools/run_darling_cli.sh /usr/bin/darlingserver"
