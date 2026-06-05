#!/bin/bash
# build-darling-zip.sh — assemble the Darling (macOS userland) rootfs zips that
# Darwin_Computa mounts to run Mach-O binaries on the emulated-Linux substrate.
#
# This is the Darwin analogue of tools/rootfs64/build-wine64-zip.sh: the same
# Docker-stage-then-host-zip recipe, but staging Darling's amd64 userland (the
# `mldr` Linux ELF loader + the Darwin root it loads: dyld, libSystem, the
# frameworks) instead of wine64.
#
# It produces two layered zips that FsZip mounts at "/" (later layers override):
#
#   glibc-rootfs64.zip   base: the glibc dynamic linker + libc + mldr's Linux
#                        .so closure (mldr is an ordinary x86_64 Linux ELF, so
#                        it needs a Linux ld.so + libc to start, exactly like
#                        wine64 does). Same name/role as the wine64 base so the
#                        launcher (setupDarwinRun in source/sdl/main.cpp) mounts
#                        it unchanged.
#   darling.zip          overlay: Darling's install tree — mldr, the Darwin
#                        prefix (/usr/lib/dyld, /usr/lib/system/*, frameworks),
#                        staged at the guest paths Darling expects.
#
# At least one staged path trips FsZip::guestIs64 (x86_64-linux-gnu/, /lib64/)
# so the launcher treats the guest as 64-bit.
#
# WHY DOCKER: Darling ships amd64 packages; on this Apple-silicon host we stage
# from a `--platform linux/amd64` image so every binary is the x86_64 the
# interpreter executes. The heavy install is done ONCE into a committed image
# (darwin-computa/darling:base); this script only stages + zips from it.
#
# To build that base image from scratch (slow, emulated amd64 — do it once):
#
#   # Option A: install Darling's published .deb (recommended — fast, stable)
#   #   see https://github.com/darlinghq/darling/releases for the current .deb
#   docker run --name darlingbuild --platform linux/amd64 ubuntu:24.04 bash -c '
#     export DEBIAN_FRONTEND=noninteractive
#     apt-get update -qq
#     apt-get install -y -qq wget ca-certificates
#     wget -q -O /tmp/darling.deb <URL-of-darling_amd64.deb>
#     apt-get install -y -qq /tmp/darling.deb'
#   docker commit darlingbuild darwin-computa/darling:base
#   docker rm darlingbuild
#
#   # Option B: build from source (see https://github.com/darlinghq/darling-docker)
#
# Output zips land in tools/rootfs-darling/dist/ (gitignored — build artifact).
#
# Then run:  tools/run_darling_cli.sh /usr/bin/sw_vers
set -euo pipefail

IMAGE="${DARLING_IMAGE:-darwin-computa/darling:base}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$HERE/dist"
mkdir -p "$DIST"

# Preflight: Docker must be up and the base image must exist, or fail with a
# clear, actionable message instead of a cryptic daemon error.
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: the Docker daemon is not running. Start Docker Desktop, then re-run." >&2
    exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERROR: base image '$IMAGE' not found." >&2
    echo "Build it once with the recipe in the header of this script (Option A/B)," >&2
    echo "or point DARLING_IMAGE at an existing image that has Darling installed." >&2
    exit 1
fi

echo "=== staging Darling rootfs from $IMAGE (linux/amd64) ==="

STAGEHOST="$DIST/stage"
rm -rf "$STAGEHOST"; mkdir -p "$STAGEHOST"

# Stage a clean guest "/" tree into the mounted volume. We stage in the container
# (Linux paths/symlinks) but ZIP on the macOS host afterward.
#
# DARLING_PREFIX is where Darling's Darwin root lives in the image. The upstream
# install puts it at /usr/local/libexec/darling (a full macOS "/" with usr/lib/
# dyld, usr/lib/system, System/Library/Frameworks, ...). mldr is the Linux ELF
# that loads a Mach-O from inside that prefix. Override DARLING_PREFIX if your
# image differs.
docker run --rm --platform linux/amd64 \
    -e DARLING_PREFIX="${DARLING_PREFIX:-/usr/local/libexec/darling}" \
    -v "$DIST":/dist "$IMAGE" bash -c '
set -euo pipefail
STAGE=/dist/stage
mkdir -p "$STAGE"
PREFIX="$DARLING_PREFIX"

# Locate mldr — the Linux ELF entry point. It usually sits next to the prefix
# (…/libexec/darling/mldr) or on PATH.
MLDR="$(command -v mldr || true)"
[ -z "$MLDR" ] && [ -x "$PREFIX/../mldr" ] && MLDR="$(readlink -f "$PREFIX/../mldr")"
[ -z "$MLDR" ] && [ -x /usr/libexec/darling/mldr ] && MLDR=/usr/libexec/darling/mldr
[ -z "$MLDR" ] && MLDR="$(find / -name mldr -type f -perm -u+x 2>/dev/null | head -1)"
if [ -z "$MLDR" ] || [ ! -e "$MLDR" ]; then
    echo "ERROR: could not find mldr in the image. Set DARLING_PREFIX / install Darling." >&2
    exit 2
fi
echo "--- mldr: $MLDR ---"
echo "--- prefix: $PREFIX ---"

copy() {  # copy a file preserving its absolute path under $STAGE, deref symlinks
  local src="$1"
  [ -e "$src" ] || return 0
  local real; real="$(readlink -f "$src")"
  mkdir -p "$STAGE$(dirname "$src")"
  cp -aL "$real" "$STAGE$src" 2>/dev/null || true
}

# --- base layer: glibc + the Linux .so closure of mldr ---
echo "--- copying glibc + mldr Linux .so closure ---"
libs=$(ldd "$MLDR" 2>/dev/null | awk "/=>/ {print \$3} /ld-linux/ {print \$1}" | grep -E "^/" | sort -u)
for l in $libs; do copy "$l"; done
copy /lib64/ld-linux-x86-64.so.2
copy /lib/x86_64-linux-gnu/libc.so.6
# libgcc_s is dlopen-ed lazily by glibc for pthread unwinding (ldd misses it).
copy /lib/x86_64-linux-gnu/libgcc_s.so.1
copy /usr/lib/x86_64-linux-gnu/libgcc_s.so.1
mkdir -p "$STAGE/etc"; : > "$STAGE/etc/ld.so.cache"

# Stage mldr at the canonical guest path the launcher expects
# ($DARWIN_MLDR, default /usr/libexec/darling/mldr).
mkdir -p "$STAGE/usr/libexec/darling"
cp -aL "$MLDR" "$STAGE/usr/libexec/darling/mldr"

# Stage the Linux-side Darling binaries: darlingserver (the userspace macOS
# "kernel" process mldr RPCs to over a socket) and the `darling` wrapper, plus
# their .so closure. darlingserver is the heart of the modern Darling model.
echo "--- copying darlingserver + darling wrapper + their .so closure ---"
for dbin in /usr/bin/darlingserver /usr/bin/darling; do
    [ -e "$dbin" ] || continue
    copy "$dbin"
    dlibs=$(ldd "$dbin" 2>/dev/null | awk "/=>/ {print \$3} /ld-linux/ {print \$1}" | grep -E "^/" | sort -u)
    for l in $dlibs; do copy "$l"; done
done

# --- overlay layer: the Darwin prefix (dyld, libSystem, frameworks) ---
# Stage the whole Darling prefix as the guest macOS "/". This is the macOS
# userland Darling provides; we copy it verbatim so dyld resolves @rpath/
# /usr/lib/... exactly as on a real Darling install. It is large; that is
# expected (Phase I makes it streamable for the web build).
echo "--- copying Darling Darwin prefix (this is the big one) ---"
if [ -d "$PREFIX" ]; then
    mkdir -p "$STAGE/darling-prefix"
    cp -aL "$PREFIX/." "$STAGE/darling-prefix/" 2>/dev/null || true
else
    echo "WARNING: DARLING_PREFIX $PREFIX is not a directory; overlay will be thin." >&2
fi

# Writable scratch dirs a Darwin/Linux rootfs needs.
mkdir -p "$STAGE/tmp" "$STAGE/var/tmp" "$STAGE/home/username" "$STAGE/run/user/1000"

# /etc/passwd + group + nsswitch: darlingserver calls getpwuid(0) during prefix
# setup ("Cannot determine your user name") and must resolve a root entry;
# nsswitch "files" keeps NSS from trying a nonexistent nscd socket. Provide a
# minimal set (root + the default unprivileged user).
mkdir -p "$STAGE/etc"
printf "root:x:0:0:root:/root:/bin/bash\nusername:x:1000:1000:username:/home/username:/bin/bash\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n" > "$STAGE/etc/passwd"
printf "root:x:0:\nusername:x:1000:\nnogroup:x:65534:\n" > "$STAGE/etc/group"
printf "passwd: files\ngroup: files\nhosts: files dns\n" > "$STAGE/etc/nsswitch.conf"

echo "--- staged tree ready ---"
du -sh "$STAGE" || true
'

echo "=== zipping on host (preserves symlinks) ==="
rm -f "$DIST/glibc-rootfs64.zip" "$DIST/darling.zip"
# Base: glibc + Linux deps. Overlay: mldr + the Darwin prefix.
( cd "$STAGEHOST" && zip -qry9 "$DIST/glibc-rootfs64.zip" lib64 lib etc tmp var run 2>/dev/null || true )
( cd "$STAGEHOST" && zip -qry9 "$DIST/darling.zip" usr darling-prefix home 2>/dev/null || true )
echo "=== zip sizes ==="
ls -lh "$DIST"/*.zip 2>/dev/null || echo "(no zips produced — check staging output above)"
echo "=== done. zips in $DIST ==="
echo "Run:  tools/run_darling_cli.sh /usr/bin/sw_vers"
