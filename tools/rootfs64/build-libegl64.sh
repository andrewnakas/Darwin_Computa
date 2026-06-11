#!/bin/bash
# build-libegl64.sh — compile the guest libEGL.so.1 (the EGL shim Darling's
# OpenGL.framework/CGL resolves through the libEGL.dylib native bridge) and
# stage the artifact in tools/rootfs64/libegl64/libEGL.so.1.
#
# Same freestanding recipe as build-libgl64.sh: plain C, no libc, traps to the
# host gl64 bridge (source/opengl/gl64bridge*). Cross-compiles from macOS with
# Apple clang + ld.lld; falls back to a Docker gcc when neither is available.
#
# Usage:  tools/rootfs64/build-libegl64.sh
# Output: tools/rootfs64/libegl64/libEGL.so.1   (commit this)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/libegl64"
IMAGE="boxedwine64/wine64-debian:bookworm"

[ -f "$SRC/libegl64.c" ] || { echo "error: $SRC/libegl64.c missing" >&2; exit 1; }

echo "=== building guest libEGL.so.1 (linux/amd64) ==="

LLD=""
for c in /opt/homebrew/Cellar/lld@*/*/bin/ld.lld /opt/homebrew/opt/llvm/bin/ld.lld \
         /usr/local/opt/llvm/bin/ld.lld; do
    [ -x "$c" ] && LLD="$c" && break
done
command -v ld.lld >/dev/null 2>&1 && LLD="${LLD:-ld.lld}"

if command -v x86_64-linux-gnu-gcc >/dev/null 2>&1; then
    CC=x86_64-linux-gnu-gcc
    echo "--- using host $CC ---"
    "$CC" -shared -fPIC -O2 -fvisibility=hidden -nostdlib -ffreestanding \
        -Wl,-soname,libEGL.so.1 \
        -o "$SRC/libEGL.so.1" "$SRC/libegl64.c"
elif command -v clang >/dev/null 2>&1 && [ -n "$LLD" ]; then
    echo "--- using host clang (x86_64-linux target) + $LLD ---"
    clang --target=x86_64-linux-gnu -fPIC -O2 -fvisibility=hidden -ffreestanding \
        -c "$SRC/libegl64.c" -o "$SRC/libegl64.o"
    "$LLD" -shared -soname libEGL.so.1 \
        -o "$SRC/libEGL.so.1" "$SRC/libegl64.o"
    rm -f "$SRC/libegl64.o"
else
    echo "--- compiling inside $IMAGE ---"
    docker run --rm --platform linux/amd64 -v "$SRC":/src "$IMAGE" bash -c '
        set -euo pipefail
        if ! command -v gcc >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -y -qq gcc libc6-dev
        fi
        gcc -shared -fPIC -O2 -fvisibility=hidden -nostdlib -ffreestanding \
            -Wl,-soname,libEGL.so.1 \
            -o /src/libEGL.so.1 /src/libegl64.c
        strip --strip-unneeded /src/libEGL.so.1 || true
    '
fi

echo "=== result ==="
ls -l "$SRC/libEGL.so.1"
if command -v readelf >/dev/null 2>&1; then
    readelf -d "$SRC/libEGL.so.1" | grep -i soname || true
    readelf --dyn-syms "$SRC/libEGL.so.1" | grep -E 'eglGetDisplay|eglCreateContext|eglSwapBuffers' || true
fi
echo "=== done: $SRC/libEGL.so.1 ==="
