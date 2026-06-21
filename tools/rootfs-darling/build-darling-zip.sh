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

# --- S28: Linux libX11.so.6 + closure, for the Darling X11.backend native bridge.
# Darlings CoreGraphics/AppKit X11.backend loads usr/lib/native/libX11.dylib,
# which is a thin Mach-O native-bridge that elfcalls-dlopens the *Linux*
# libX11.so.6 from the standard paths (/usr/lib/x86_64-linux-gnu, /usr/lib,
# /lib...). That real Linux libX11 then connect()s to /tmp/.X11-unix/X0, which the
# emulators XWireServer (source/x11wire) intercepts and presents to SDL. Without
# this .so the bridge prints "Cannot load libX11.so.6 (ELF)" and the GUI path dies.
# Install + stage libX11 and its full .so closure (libxcb, libXau, libXdmcp, ...).
echo "--- S28: installing + staging Linux libX11.so.6 + closure ---"
( apt-get update -qq && apt-get install -y -qq libx11-6 >/dev/null 2>&1 ) || true
X11SO="$(find /usr/lib /lib -name "libX11.so.6*" -type f 2>/dev/null | head -1)"
if [ -n "$X11SO" ]; then
    # Stage the real ELF content at the SONAME path under BOTH search roots. The
    # guest VFS does NOT reliably follow zip symlinks for the native dlopen path
    # (a symlink entry loads as a tiny file -> "file too short"), so we place the
    # FULL file at libX11.so.6 (not a symlink to libX11.so.6.4.0). Same for the
    # closure SONAMEs.
    for base in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do
        mkdir -p "$STAGE$base"
        cp -L "$X11SO" "$STAGE$base/libX11.so.6"
        for dep in $(ldd "$X11SO" 2>/dev/null | awk "/=>/ {print \$3}" | grep -E "^/" | sort -u); do
            son="$(basename "$dep" | sed -E "s/(\.so\.[0-9]+)\..*/\1/")"
            cp -L "$dep" "$STAGE$base/$son" 2>/dev/null || true
            copy "$dep"
        done
    done
    echo "--- S28: staged libX11.so.6 + closure (real files at SONAME paths) ---"
else
    echo "WARNING: libX11.so.6 not found/installable in image; GUI bridge will fail." >&2
fi

# --- S29: the CoreGraphics GUI native-lib closure ----------------------------
# Bringing up the REAL Darwin GUI stack (CoreGraphics' X11.backend, exercised by
# tools/darwin-cg-probe/cgprobe) pulls a much larger native-bridge closure than
# the bare libX11 of S28. Each usr/lib/native/lib*.dylib bridge elfcalls-dlopens
# a Linux .so.N; if any is missing the bridge prints "Cannot load <lib>.so.N
# (ELF)" and the guest aborts (f4=hlt). The set below is what cgprobe needed to
# reach a live CGS connection (CGSMainConnectionID()=1, 1024x768 display):
#   font/text : libfreetype.so.6 libfontconfig.so.1 (+ libpng16 libz libbrotli* libexpat)
#   imaging   : libjpeg.so.8 libtiff.so.6 libgif.so.7 (+ tiff closure: libdeflate
#               liblzma libwebp libzstd libjbig libLerc libsharpyuv)
#   GL/EGL    : libGL.so.1 libGLU.so.1 libEGL.so.1 (+ libGLdispatch libGLX libOpenGL)
#   X exts    : libXext.so.6 libXrender.so.1 libXfixes.so.3 libXcursor.so.1
#               libXrandr.so.2 libxkbfile.so.1
# Install the Debian packages providing them, then stage every resulting .so at
# its SONAME path under BOTH lib roots (same real-file-not-symlink rule as S28).
echo "--- S29: installing + staging the CoreGraphics GUI native-lib closure ---"
( apt-get update -qq && apt-get install -y -qq \
    libfreetype6 libfontconfig1 libpng16-16 zlib1g libbrotli1 libexpat1 \
    libjpeg62-turbo libtiff6 libgif7 libdeflate0 liblzma5 libwebp7 libzstd1 \
    libjbig0 liblerc4 \
    libgl1 libglu1-mesa libegl1 \
    libxext6 libxrender1 libxfixes3 libxcursor1 libxrandr2 libxkbfile1 \
    >/dev/null 2>&1 ) || true
# The literal SONAMEs the native bridges dlopen (note libjpeg.so.8 — the bridge
# asks for .so.8 even though libjpeg62-turbo ships .so.62; stage the .so.62 ELF
# AT the .so.8 name, ABI-compatible for the symbol subset the bridge calls).
S29_SONAMES="libfreetype.so.6 libfontconfig.so.1 libpng16.so.16 libz.so.1 \
  libbrotlidec.so.1 libbrotlicommon.so.1 libexpat.so.1 \
  libjpeg.so.8 libtiff.so.6 libgif.so.7 libdeflate.so.0 liblzma.so.5 \
  libwebp.so.7 libzstd.so.1 libjbig.so.0 libLerc.so.4 libsharpyuv.so.0 \
  libGL.so.1 libGLU.so.1 libEGL.so.1 libGLdispatch.so.0 libGLX.so.0 libOpenGL.so.0 \
  libXext.so.6 libXrender.so.1 libXfixes.so.3 libXcursor.so.1 libXrandr.so.2 libxkbfile.so.1"
for base in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do
    mkdir -p "$STAGE$base"
    for son in $S29_SONAMES; do
        # libjpeg.so.8 lives on disk as libjpeg.so.62.*; map it explicitly.
        case "$son" in
            libjpeg.so.8) pat="libjpeg.so.62*" ;;
            *) pat="${son}*" ;;
        esac
        real="$(find /usr/lib /lib -name "$pat" -type f 2>/dev/null | head -1)"
        [ -n "$real" ] && cp -L "$real" "$STAGE$base/$son" 2>/dev/null || true
    done
done
echo "--- S29: staged GUI native-lib closure (real files at SONAME paths) ---"
# NOTE: the top-level CoreGraphics.framework/Backends mirror (so _CGSLoadBackend
# finds the X11.backend) is done AFTER the Darwin prefix is staged below — see
# the "S29: mirror CoreGraphics.framework/Backends" block further down.

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
# Stage the whole Darling prefix at the SAME guest path it occupies on a real
# Darling install ($PREFIX, e.g. /usr/libexec/darling) — NOT a renamed path —
# because darlingserver derives mldr/vchroot/launchd paths from its compiled-in
# prefix and execs e.g. `mldr vchroot /usr/libexec/darling /sbin/launchd`. The
# prefix is a full Darwin "/" (sbin/launchd, usr/lib/dyld, usr/libexec/darling/
# mldr, System/, ...). Also symlink /darling-prefix -> $PREFIX for convenience
# (the --darwin-run CLI examples / DYLD_ROOT_PATH).
echo "--- copying Darling Darwin prefix at $PREFIX (this is the big one) ---"
if [ -d "$PREFIX" ]; then
    mkdir -p "$STAGE$PREFIX"
    # Copy the Darwin prefix with tar, EXCLUDING Volumes/DarlingEmulatedDrive:
    # on a real install the `darling` wrapper bind-mounts the host Linux "/"
    # there, so in the image it is a full duplicate Linux root (bin, etc, lib,
    # and even a recursive copy of our own dist/stage) — copying it verbatim
    # balloons the zip and, worse, the recursion made cp error out and silently
    # drop the real nested mldr/launchd. We recreate the needed Linux view from
    # our own rootfs, so the prefix only needs its Darwin content. proc/dev/sys
    # are kernel-virtual; skip them too.
    ( cd "$PREFIX" && tar -ch \
        --exclude='./Volumes/DarlingEmulatedDrive' \
        --exclude='./proc' --exclude='./dev' --exclude='./sys' \
        . 2>/dev/null ) | ( cd "$STAGE$PREFIX" && tar -x 2>/dev/null ) || true
    # Sanity: the two binaries darlingserver execs MUST be present.
    [ -e "$STAGE$PREFIX/usr/libexec/darling/mldr" ] || \
        echo "WARNING: nested mldr missing from staged prefix!" >&2
    [ -e "$STAGE$PREFIX/sbin/launchd" ] || \
        echo "WARNING: launchd missing from staged prefix!" >&2
    # S22 fix (Darwin_Computa): Darlings pid1 launchd skips ipc_server_init() — in
    # _main the pid1_magic branch jmps PAST the ipc_server_init call that the
    # per-user branch makes, so the System launchd never socket+bind+listens
    # /var/tmp/launchd/sock. launchctl bootstrap -S System then cannot connect() to
    # submit the 20 LaunchDaemon job dicts, so no daemon ever spawns. Retarget that
    # jmp to land on the ipc_server_init callsite. The instruction is a 5-byte
    # rel32 `jmp` (E9) at file offset 0x2772f; its disp32 (offset 0x27730) is
    # d5 01 00 00 (-> 0x100027909, skipping ipc_server_init). Patch to 1a 01 00 00
    # (-> 0x10002784e, the `call _ipc_server_init` site). Verify the bytes first so
    # a future Darling rebuild with a different layout fails loud instead of
    # corrupting the binary.
    LD_BIN="$STAGE$PREFIX/sbin/launchd"
    if [ -e "$LD_BIN" ]; then
        cur=$(dd if="$LD_BIN" bs=1 skip=$((0x2772f)) count=5 2>/dev/null | od -An -tx1 | tr -d ' \n')
        if [ "$cur" = "e9d5010000" ]; then
            printf '\x1a\x01\x00\x00' | dd of="$LD_BIN" bs=1 seek=$((0x27730)) count=4 conv=notrunc 2>/dev/null
            echo "--- S22: patched launchd pid1 ipc_server_init jmp (0x27730 d5->1a) ---"
        else
            echo "WARNING: S22 launchd patch SKIPPED — bytes at 0x2772f are '$cur' not 'e9d5010000' (Darling layout changed; re-derive the offset)." >&2
        fi
    fi
    # S22 fix: launchds ipc_server_init does a NON-recursive mkdir(/var/tmp/launchd);
    # /var existed in the prefix but /var/tmp did not, so the mkdir ENOENT'd and
    # ipc_server_init bailed before bind. Create /var/tmp (+ /private/var/tmp) in the
    # Darwin prefix so the submit socket can be bound.
    mkdir -p "$STAGE$PREFIX/var/tmp" "$STAGE$PREFIX/private/var/tmp"
    chmod 1777 "$STAGE$PREFIX/var/tmp" "$STAGE$PREFIX/private/var/tmp" 2>/dev/null || true
    # Convenience symlink for the --darwin-run CLI / DYLD_ROOT_PATH examples.
    ln -sfn "$PREFIX" "$STAGE/darling-prefix" 2>/dev/null || true
    # S29: mirror CoreGraphics.framework/Backends to the framework root. CoreGraphics'
    # _CGSLoadBackend resolves the framework bundle (NSBundle bundleForClass:) then
    # opens <framework>/Backends — but X11.backend is staged under
    # Versions/C/Resources/Backends and the framework lacks the standard
    # Resources/Current symlinks, so open('<framework>/Backends') ENOENTs and the CGS
    # connection never loads. Mirror it as a REAL directory (guest VFS does not
    # reliably follow zip symlinks). This is the last wall before a live CGS session
    # (cgprobe: CGSMainConnectionID()=1, 1024x768).
    CGFW="$STAGE$PREFIX/System/Library/Frameworks/CoreGraphics.framework"
    if [ -d "$CGFW/Versions/C/Resources/Backends" ] && [ ! -e "$CGFW/Backends" ]; then
        cp -R "$CGFW/Versions/C/Resources/Backends" "$CGFW/Backends"
        echo "--- S29: mirrored CoreGraphics.framework/Backends to the framework root ---"
    fi
    # S31: AppKit owns the REAL window backend (X11Display/X11Window -> XCreateWindow/
    # XMapWindow); CoreGraphics X11.backend only does screen/input (its newWindow: is a
    # no-op stub — see tools/darwin-cg-probe/cgwin.c). +[NSDisplay currentDisplay] opens
    # <AppKit.framework>/Backends, which (like CoreGraphics) is staged only under
    # Versions/C/Resources/Backends with no Resources/Current symlink. Mirror it to the
    # framework root as a REAL dir so AppKit can load X11Display. (akwin.c reaches NSWindow
    # alloc with this in place.)
    AKFW="$STAGE$PREFIX/System/Library/Frameworks/AppKit.framework"
    if [ -d "$AKFW/Versions/C/Resources/Backends" ] && [ ! -e "$AKFW/Backends" ]; then
        cp -R "$AKFW/Versions/C/Resources/Backends" "$AKFW/Backends"
        echo "--- S31: mirrored AppKit.framework/Backends to the framework root ---"
    fi
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

# S31: fontconfig config + a font at the BARE Linux paths. AppKit window init pulls in
# the native libfontconfig.so.1 (a Linux .so via elfcalls), which resolves BARE Linux
# paths (/etc/fonts/fonts.conf, /usr/share/fonts), NOT the vchroot-prefixed Darwin ones.
# With no config it errors "Cannot load default config file: (null)" and AppKit wedges
# in initWithContentRect:. Provide a minimal config + at least one TTF so fontconfig
# scans a real dir. (These go in $STAGE/etc + $STAGE/usr/share, zipped into the base +
# darling zips.) The TTF is reused from the Ruby rdoc fonts already in the tree.
mkdir -p "$STAGE/etc/fonts/conf.d" "$STAGE/usr/share/fonts" "$STAGE/var/cache/fontconfig"
cat > "$STAGE/etc/fonts/fonts.conf" <<'FCEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>/usr/share/fonts</dir>
  <cachedir>/var/cache/fontconfig</cachedir>
  <include ignore_missing="yes">/etc/fonts/conf.d</include>
</fontconfig>
FCEOF
# Seed one font (the rdoc Lato is shipped in the Darling tree under usr/lib/ruby/...).
_FCFONT="$STAGE$PREFIX/usr/lib/ruby/2.6.0/rdoc/generator/template/darkfish/fonts/Lato-Regular.ttf"
[ -f "$_FCFONT" ] && cp "$_FCFONT" "$STAGE/usr/share/fonts/Lato-Regular.ttf" || true
echo "--- S31: staged bare /etc/fonts/fonts.conf + /usr/share/fonts (fontconfig) ---"

# S32/S33: minimal Darwin user database so libinfo (libsystem_info) resolves the
# current user (uid 0 = root) from FLAT FILES instead of the mach service. Every
# Cocoa/Foundation app calls getpwuid/NSUserName during init; libinfo first tries
# /etc/master.passwd|passwd|group, and ONLY falls through to the
# com.apple.system.opendirectoryd.libinfo mach lookup when they are MISSING. With no
# files staged, AppKit init spins forever on that bootstrap_look_up2 (opendirectoryd
# does not service it under the emulator) — the S32 GUI wedge. These go under the
# Darwin vchroot prefix ($STAGE$PREFIX/etc, mirrored to private/etc) because libinfo
# resolves the vchroot-prefixed path (boot trace: open .../usr/libexec/darling/etc/master.passwd).
mkdir -p "$STAGE$PREFIX/etc" "$STAGE$PREFIX/private/etc"
cat > "$STAGE$PREFIX/etc/master.passwd" <<'PWEOF'
root:*:0:0::0:0:System Administrator:/var/root:/bin/sh
daemon:*:1:1::0:0:System Services:/var/empty:/usr/bin/false
nobody:*:-2:-2::0:0:Unprivileged User:/var/empty:/usr/bin/false
PWEOF
cat > "$STAGE$PREFIX/etc/passwd" <<'PWEOF'
root:*:0:0:System Administrator:/var/root:/bin/sh
daemon:*:1:1:System Services:/var/empty:/usr/bin/false
nobody:*:-2:-2:Unprivileged User:/var/empty:/usr/bin/false
PWEOF
cat > "$STAGE$PREFIX/etc/group" <<'PWEOF'
wheel:*:0:root
daemon:*:1:root
nobody:*:-2:
nogroup:*:-1:
staff:*:20:root
PWEOF
cp "$STAGE$PREFIX/etc/master.passwd" "$STAGE$PREFIX/private/etc/master.passwd"
cp "$STAGE$PREFIX/etc/passwd"        "$STAGE$PREFIX/private/etc/passwd"
cp "$STAGE$PREFIX/etc/group"         "$STAGE$PREFIX/private/etc/group"
echo "--- S33: staged /etc/{master.passwd,passwd,group} (libinfo flat-file fallback) ---"

echo "--- staged tree ready ---"
du -sh "$STAGE" || true
'

# --- S28: stage the raw-Xlib GUI probe (host-built Mach-O) -------------------
# xprobe is a minimal libX11 client (XOpenDisplay->XCreateWindow->XMapWindow)
# used to light up the in-process X11 wire-server -> SDL bridge without the whole
# AppKit stack. It must be a Darwin x86_64 Mach-O linked against the *staged*
# guest dylibs, so it is cross-built on the macOS host (Apple clang) — NOT in the
# Docker container — and injected into the stage tree here. Run via
# DSERVER_INIT=/usr/bin/xprobe. See tools/darwin-x11-probe/.
XPROBE_SRC="$(cd "$(dirname "$0")/.." && pwd)/darwin-x11-probe"
if [ -f "$XPROBE_SRC/build.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$XPROBE_SRC/build.sh" >/dev/null 2>&1 && [ -f "$XPROBE_SRC/xprobe" ]; then
        DPFX="$STAGEHOST/dist/stage/usr/libexec/darling"
        if [ -d "$DPFX/usr/bin" ]; then
            cp "$XPROBE_SRC/xprobe" "$DPFX/usr/bin/xprobe"
            chmod 755 "$DPFX/usr/bin/xprobe"
            echo "--- S28: staged GUI probe at usr/libexec/darling/usr/bin/xprobe ---"
        fi
    else
        echo "WARNING: xprobe cross-build failed; GUI probe not staged." >&2
    fi
fi

# --- S29: stage the CoreGraphics GUI probe (host-built Mach-O) ---------------
# cgprobe drives the REAL Darwin GUI stack one layer up from xprobe: it calls
# CGSInitialize/CGMainDisplayID so CoreGraphics' _CGSLoadBackend loads the
# X11.backend (whose CGSConnectionX11 calls XOpenDisplay over the same libX11
# native bridge xprobe proved). Cross-built on the host against the staged
# CoreGraphics + Foundation + libSystem. Run via DSERVER_INIT=/usr/bin/cgprobe.
# See tools/darwin-cg-probe/.
CGPROBE_SRC="$(cd "$(dirname "$0")/.." && pwd)/darwin-cg-probe"
if [ -f "$CGPROBE_SRC/build.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$CGPROBE_SRC/build.sh" >/dev/null 2>&1 && [ -f "$CGPROBE_SRC/cgprobe" ]; then
        DPFX="$STAGEHOST/dist/stage/usr/libexec/darling"
        if [ -d "$DPFX/usr/bin" ]; then
            cp "$CGPROBE_SRC/cgprobe" "$DPFX/usr/bin/cgprobe"
            chmod 755 "$DPFX/usr/bin/cgprobe"
            echo "--- S29: staged CG GUI probe at usr/libexec/darling/usr/bin/cgprobe ---"
        fi
    else
        echo "WARNING: cgprobe cross-build failed; CG GUI probe not staged." >&2
    fi
    # S30: cgwin — CGSNewRegionWithRect/CGSNewWindow/CGSOrderWindow. Proves CoreGraphics'
    # X11.backend newWindow: is a NO-OP stub (CGSNewWindow returns err 1001) — the CGS
    # window path is a DEAD END; windows live in AppKit. Kept as a regression/record.
    if [ -f "$CGPROBE_SRC/build-cgwin.sh" ] && bash "$CGPROBE_SRC/build-cgwin.sh" >/dev/null 2>&1 && [ -f "$CGPROBE_SRC/cgwin" ]; then
        DPFX="$STAGEHOST/dist/stage/usr/libexec/darling"
        if [ -d "$DPFX/usr/bin" ]; then
            cp "$CGPROBE_SRC/cgwin" "$DPFX/usr/bin/cgwin"; chmod 755 "$DPFX/usr/bin/cgwin"
            echo "--- S30: staged cgwin (CGSNewWindow dead-end probe) at usr/bin/cgwin ---"
        fi
    fi
    # S31: akwin — the AppKit NSWindow probe ([NSApplication sharedApplication] -> NSWindow
    # initWithContentRect: -> makeKeyAndOrderFront:). The REAL window path: X11Display ->
    # X11Window -> XCreateWindow/XMapWindow. Currently wedges on a /proc/self/mountinfo
    # re-read loop wrapped in pthread_canceled (S31/S32 frontier). Run DSERVER_INIT=/usr/bin/akwin.
    if [ -f "$CGPROBE_SRC/build-akwin.sh" ] && bash "$CGPROBE_SRC/build-akwin.sh" >/dev/null 2>&1 && [ -f "$CGPROBE_SRC/akwin" ]; then
        DPFX="$STAGEHOST/dist/stage/usr/libexec/darling"
        if [ -d "$DPFX/usr/bin" ]; then
            cp "$CGPROBE_SRC/akwin" "$DPFX/usr/bin/akwin"; chmod 755 "$DPFX/usr/bin/akwin"
            echo "--- S31: staged akwin (AppKit NSWindow probe) at usr/bin/akwin ---"
        fi
    fi
    # S37: akrun — the interactive AppKit probe (NSButton toggles bg, NSTextField,
    # live event pump logging every NSEvent). The default GUI app for
    # tools/run_darling_gui.sh. Run DSERVER_INIT=/usr/bin/akrun (or shellspawn).
    if [ -f "$CGPROBE_SRC/build-akrun.sh" ] && bash "$CGPROBE_SRC/build-akrun.sh" >/dev/null 2>&1 && [ -f "$CGPROBE_SRC/akrun" ]; then
        DPFX="$STAGEHOST/dist/stage/usr/libexec/darling"
        if [ -d "$DPFX/usr/bin" ]; then
            cp "$CGPROBE_SRC/akrun" "$DPFX/usr/bin/akrun"; chmod 755 "$DPFX/usr/bin/akrun"
            echo "--- S37: staged akrun (interactive AppKit probe) at usr/bin/akrun ---"
        fi
    fi
fi

# --- S38: DarwinComputa.app — a real Mac .app BUNDLE -------------------------
# Same interactive app as akrun, but delivered as a proper bundle
# (Contents/{Info.plist, MacOS/DarwinComputa, Resources/Welcome.txt}) installed
# at the guest path /Applications/DarwinComputa.app. Launching it execs
# Contents/MacOS/DarwinComputa via shellspawn, so Darling's CoreFoundation
# derives [NSBundle mainBundle] from the executable path -> Info.plist + Resources
# resolve. VERIFIED S38: 'BUNDLE OK — mainBundle resolved to a .app'. open(1)/
# LaunchServices is NOT used (non-functional on this substrate). Launch with
# tools/run_darling_app_bundle.sh. See tools/darwin-app/.
APP_SRC="$(cd "$(dirname "$0")/.." && pwd)/darwin-app"
if [ -f "$APP_SRC/build-akapp.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-akapp.sh" >/dev/null 2>&1; then
        # build-akapp.sh installs into dist/stage already; confirm it landed.
        if [ -d "$STAGEHOST/dist/stage/usr/libexec/darling/Applications/DarwinComputa.app" ]; then
            echo "--- S38: staged DarwinComputa.app at Applications/DarwinComputa.app ---"
        fi
    else
        echo "WARNING: akapp bundle build failed; DarwinComputa.app not staged." >&2
    fi
fi

# --- M1 (S39): DarwinPad.app — a real EDITABLE text editor bundle ------------
# A TextEdit-style .app: NSWindow + NSScrollView{editable NSTextView} + File/Edit
# menu bar, installed at the guest path /Applications/DarwinPad.app. Unlike
# akrun/akapp (which only LOG NSEvents), DarwinPad holds a real mutable text
# buffer and proves the editing path by READING THE BUFFER BACK after a
# programmatic insertText:/deleteBackward: (verdict 'DARWINPAD EDIT OK — buffer
# mutated'). Same bundle-launch mechanism as S38. Launch with
# tools/run_darling_app_bundle.sh /Applications/DarwinPad.app. See tools/darwin-app/.
if [ -f "$APP_SRC/build-darwinpad.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-darwinpad.sh" >/dev/null 2>&1; then
        if [ -d "$STAGEHOST/dist/stage/usr/libexec/darling/Applications/DarwinPad.app" ]; then
            echo "--- M1/S39: staged DarwinPad.app at Applications/DarwinPad.app ---"
        fi
    else
        echo "WARNING: darwinpad bundle build failed; DarwinPad.app not staged." >&2
    fi
fi

# --- M11 (S54): JSGui.app — a GUI app that RUNS JAVASCRIPT (AppKit + JavaScriptCore)
# The first SYNTHESIS app: composes the proven GUI chain (S37/S38: NSWindow + X11
# backend + GL present) with JavaScriptCore (M5a). jsguiapp.c builds an NSWindow
# with an NSTextField + "Run JS" button, brings up a JSC context, evaluates JS
# (6*7=42, 'darwin'.toUpperCase()), shows the result in the field, and re-evaluates
# JS on each button click. KEY INTEGRATION FIX: create the JSC context AFTER the
# NSWindow+views are built but BEFORE makeKeyAndOrderFront — JSC's GC/JIT thread
# creation races AppKit's X11 event-pump threads (the S34/S35 darlingserver
# thread-checkin wedge) if done after the window maps; the pre-map gap is quiet.
# VERIFIED M11/S54 (live): M11-WINDOW-OK / M11-JSC-CTX-OK / M11-JS-EVAL-42 /
# M11-JS-STR-DARWIN / M11-FIELD-SET / M11-DONE / 'first window mapped' + a button
# click -> 'click 1 -> JS says 7 from JS'. Launch:
# bash tools/run_darling_app_bundle.sh /Applications/JSGui.app
if [ -f "$APP_SRC/build-jsguiapp.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-jsguiapp.sh" >/dev/null 2>&1; then
        if [ -d "$STAGEHOST/dist/stage/usr/libexec/darling/Applications/JSGui.app" ]; then
            echo "--- M11/S54: staged JSGui.app at Applications/JSGui.app ---"
        fi
    else
        echo "WARNING: jsguiapp bundle build failed; JSGui.app not staged." >&2
    fi
fi

# --- M12 (S55): DbGui.app — a GUI app BACKED BY SQLite (AppKit + libsqlite3) ---
# Second synthesis app: the proven GUI chain (S37/S38) + on-disk SQLite (M6'). A
# "notes" app: opens a SQLite DB, CREATE TABLE + INSERT a row, shows the live
# COUNT in an NSTextField, and INSERTs another row on each "Add note" click. Same
# safe ordering as M11 (open the DB after window-build, before makeKeyAndOrderFront).
# VERIFIED M12/S55 (live): M12-WINDOW-OK / M12-DB-OPEN-OK / M12-DB-INSERT-1(count=1)
# / M12-FIELD-SET / 'first window mapped' / M12-DONE + 'Add note' clicks ->
# count 1->2->3 (live DB writes from the GUI). Launch:
# bash tools/run_darling_app_bundle.sh /Applications/DbGui.app
if [ -f "$APP_SRC/build-dbguiapp.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-dbguiapp.sh" >/dev/null 2>&1; then
        if [ -d "$STAGEHOST/dist/stage/usr/libexec/darling/Applications/DbGui.app" ]; then
            echo "--- M12/S55: staged DbGui.app at Applications/DbGui.app ---"
        fi
    else
        echo "WARNING: dbguiapp bundle build failed; DbGui.app not staged." >&2
    fi
fi

# --- M13 (S56): ListGui.app — a GUI app that PARSES JSON INTO A LIST -----------
# Third synthesis app: the proven GUI chain (S37/S38) + NSJSONSerialization (M7) +
# Foundation collection enumeration (M3). Parses an embedded JSON array of {name,
# score} records and renders ONE NSTextField per record — a real "list view" of
# parsed data (the fetch/parse->display shape of most apps; data is embedded since
# the live-network fetch M10 is blocked on a guest-TLS issue). JSON is pure
# Foundation (no extra lib/threads). VERIFIED M13/S56 (live): M13-WINDOW-OK /
# M13-JSON-PARSE-3 / M13-ROW-0-alpha-10 / -1-bravo-42 / -2-charlie-7 /
# M13-ROWS-SHOWN-3 / 'first window mapped'. Launch:
# bash tools/run_darling_app_bundle.sh /Applications/ListGui.app
if [ -f "$APP_SRC/build-listguiapp.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-listguiapp.sh" >/dev/null 2>&1; then
        if [ -d "$STAGEHOST/dist/stage/usr/libexec/darling/Applications/ListGui.app" ]; then
            echo "--- M13/S56: staged ListGui.app at Applications/ListGui.app ---"
        fi
    else
        echo "WARNING: listguiapp bundle build failed; ListGui.app not staged." >&2
    fi
fi

# --- M14 (S57): AppGui.app — CAPSTONE: JS + SQLite + GUI list in one app -------
# The capstone synthesis: combines THREE heavy proven subsystems in one window —
# JavaScriptCore (M5a) + SQLite (M6') + AppKit list (M11/M12/M13). "Compute & Save"
# click -> JS computes a value -> INSERT into SQLite -> re-render the saved-values
# list. Same init-before-makeKeyAndOrderFront ordering as M11. VERIFIED M14/S57
# (live): M14-WINDOW-OK / M14-JSC-OK / M14-DB-OK / 'first window mapped' / M14-DONE +
# a click -> M14-COMPUTE-3 (JS 'Math.pow(2,1)+1' -> SQLite) / M14-LIST-1. Launch:
# bash tools/run_darling_app_bundle.sh /Applications/AppGui.app
if [ -f "$APP_SRC/build-appgui.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-appgui.sh" >/dev/null 2>&1; then
        if [ -d "$STAGEHOST/dist/stage/usr/libexec/darling/Applications/AppGui.app" ]; then
            echo "--- M14/S57: staged AppGui.app at Applications/AppGui.app ---"
        fi
    else
        echo "WARNING: appgui bundle build failed; AppGui.app not staged." >&2
    fi
fi

# --- M3 (S42): foundationcli — a NORMAL Objective-C Foundation program -------
# Unlike akapp/darwinpad (which hand-roll objc_msgSend via extern decls + cast-
# through calls), foundationcli.m is REAL Objective-C ([obj msg], @"literals",
# @[...], @autoreleasepool), so clang emits the genuine objc_msgSend / class+sel
# refs / autorelease machinery. Running it validates dyld + libobjc + Foundation
# through the SAME codegen path every normal Mac tool uses — the M3 milestone.
# Installed at the guest path /usr/bin/foundationcli. VERIFIED M3/S42 (live):
# M3-STRING-HELLO, DARWIN / M3-ARRAY-COUNT-3 / M3-JOIN-a-b-c / M3-NUM-42 /
# M3-PROC-foundationcli / M3-DONE, exit_group(0). Run with
# BW64_SHELLSPAWN=/usr/bin/foundationcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-foundationcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-foundationcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/foundationcli" ]; then
            echo "--- M3/S42: staged foundationcli at usr/bin/foundationcli ---"
        fi
    else
        echo "WARNING: foundationcli build failed; not staged." >&2
    fi
fi

# --- M4 (S43): netcli — Foundation networking probe -------------------------
# Proves Darwin's networking on the substrate: the emulator bridges guest
# AF_INET sockets to REAL host sockets (source/kernel/knativesocket.cpp), and
# netcli drives the full transport stack — in-guest DNS (getaddrinfo ->
# resolv.conf 8.8.8.8), TCP connect, and a complete HTTP/1.0 exchange parsed for
# the status line (the GATE). Installed at /usr/bin/netcli. VERIFIED M4/S43
# (live, example.com): N4-DNS-<ip> / N4-RAW-CONNECT-OK / N4-RAW-HTTP-828 /
# N4-RAW-STATUS-200 / N4-RAW-BODY-559 / N4-DONE, exit_group(0). A best-effort
# CFNetwork tier (NSURLConnection) prints N4-URL-GAP here: this Darling's
# high-level URL loaders have gaps (NSURLSession missing-selector;
# NSURLConnection -1015 chunked / -1001 timeout) — recorded as follow-ups, NOT
# gating. Run: BW64_SHELLSPAWN=/usr/bin/netcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-netcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-netcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/netcli" ]; then
            echo "--- M4/S43: staged netcli at usr/bin/netcli ---"
        fi
    else
        echo "WARNING: netcli build failed; not staged." >&2
    fi
fi

# --- M4b (S44): httpget — a reliable HTTP client w/ in-process chunked decode --
# M4 proved the transport; M4b proves a COMPLETE, DECODED HTTP transaction.
# Darling's high-level CFNetwork loaders are flakily broken on this substrate
# (NSURLSession missing-selector; NSURLConnection -1015 on chunked bodies via its
# broken chunked decoder + intermittent -1001 connection-setup), so httpget builds
# the HTTP layer on the reliable raw socket bridge and decodes chunked
# transfer-encoding ITSELF. Installed at /usr/bin/httpget. VERIFIED M4b/S44 (live,
# example.com): M4B-DNS-<ip> / M4B-CONNECT-OK / M4B-STATUS-200 /
# M4B-ENCODING-chunked / M4B-DECODED-559 / M4B-HASMARKER-1 (NSString contains: the
# real page title) / M4B-DONE, exit_group(0). Run:
# BW64_SHELLSPAWN=/usr/bin/httpget bash tools/run_darling_cli.sh /usr/bin/darlingserver.
# (neturl, the NSURLConnection diagnostic that mapped the CFNetwork gaps, is kept
# in tools/darwin-app/ but not staged — it intentionally fails on this substrate.)
if [ -f "$APP_SRC/build-httpget.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-httpget.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/httpget" ]; then
            echo "--- M4b/S44: staged httpget at usr/bin/httpget ---"
        fi
    else
        echo "WARNING: httpget build failed; not staged." >&2
    fi
fi

# --- M4c (S45): httpsget — HTTPS/TLS via modern OpenSSL over the socket bridge --
# M4c proves a real TLS handshake + decoded HTTPS body. The emulator socket bridge
# is raw TCP only (TLS runs in guest userspace), and Darling's CFNetwork loaders
# are flaky (see M4b), so httpsget links the staged MODERN OpenSSL
# (libssl.46/libcrypto.44 => TLS 1.2/1.3 — NOT the libssl.dylib symlink, which is
# ancient 0.9.8/TLS1.0-only that modern servers reject) and does SSL_connect + SNI
# over a guest socket, then reuses the M4b chunked decoder. Installed at
# /usr/bin/httpsget. VERIFIED M4c/S45 (live, https://example.com): M4C-DNS-<ip> /
# M4C-TCP-OK / M4C-HANDSHAKE-OK-TLSv1.2 / M4C-STATUS-200 / M4C-DECODED-559 /
# M4C-HASMARKER-1 / M4C-DONE, exit_group(0). Run:
# BW64_SHELLSPAWN=/usr/bin/httpsget bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-httpsget.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-httpsget.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/httpsget" ]; then
            echo "--- M4c/S45: staged httpsget at usr/bin/httpsget ---"
        fi
    else
        echo "WARNING: httpsget build failed; not staged." >&2
    fi
fi

# --- M5a (S46-S47): jscli — run real JavaScript through JavaScriptCore ---------
# JavaScriptCore.framework (the full engine) is staged; jscli.m drives the JSC C
# API to evaluate real JS and read results back. It was BLOCKED on several
# emulator gaps that JSC's init + JIT hit, all fixed in the emulator (S47): the
# WTF StackBounds wall (getrlimit RLIMIT_STACK must be finite 8MB, syscall64.cpp)
# + a batch of x87 register-form arithmetic and SSE4.1 opcodes (cpu64.cpp:
# x87 D8/DC FADD/FMUL/FSUB/FDIV; PINSRD/Q, PEXTRD/Q, EXTRACTPS, PBLENDW, PACKUSDW,
# the PMOVSX/ZX family, and the variable-blend PBLENDVB/BLENDVPS/BLENDVPD).
# VERIFIED M5a/S47 (live): M5A-EVAL-42 / M5A-STR-DARWIN / M5A-FUNC-120 /
# M5A-LOOP-4950 / M5A-DONE, exit_group(0). Run:
# BW64_SHELLSPAWN=/usr/bin/jscli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-jscli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-jscli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/jscli" ]; then
            echo "--- M5a/S47: staged jscli at usr/bin/jscli ---"
        fi
    else
        echo "WARNING: jscli build failed; not staged." >&2
    fi
fi

# --- M6' (S49): sqlitecli — real on-disk SQLite persistence via libsqlite3 ------
# CoreData (M6) was un-usable here (Darling's Cocotron CoreData is incomplete), so
# we prove the persistence capability DIRECTLY on libsqlite3 (the staged full
# SQLite), which works. sqlitecli.m declares the SQLite C API extern and does
# CREATE/INSERT then CLOSE + RE-OPEN a fresh connection + SELECT (reading back from
# disk). Installed at /usr/bin/sqlitecli. VERIFIED M6'/S49 (live): M6P-VERSION-3.32.3
# / M6P-OPEN-OK / M6P-CREATE-OK / M6P-INSERT-3 / M6P-FILE-8192 / M6P-REOPEN-OK /
# M6P-SELECT-3 / M6P-VALUE-NOTE-2-42 / M6P-DONE. Run:
# BW64_SHELLSPAWN=/usr/bin/sqlitecli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-sqlitecli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-sqlitecli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/sqlitecli" ]; then
            echo "--- M6'/S49: staged sqlitecli at usr/bin/sqlitecli ---"
        fi
    else
        echo "WARNING: sqlitecli build failed; not staged." >&2
    fi
fi

# --- M15 (S58): zcli — data compression via the staged libz (zlib) ------------
# Deterministic, headless capability on a staged C lib (the libsqlite3/OpenSSL
# pattern), no networking. zcli.m declares the zlib C API extern and does a
# compress -> uncompress round-trip with byte-identity + crc32. Installed at
# /usr/bin/zcli. VERIFIED M15/S58 (live): M15-ZVER-1.2.11 / M15-ORIG-1024 /
# M15-CRC-220d331a / M15-COMPRESSED-32 / M15-SMALLER-1 / M15-ROUNDTRIP-OK /
# M15-NSSTRING-OK / M15-DONE. Run:
# BW64_SHELLSPAWN=/usr/bin/zcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-zcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-zcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/zcli" ]; then
            echo "--- M15/S58: staged zcli at usr/bin/zcli ---"
        fi
    else
        echo "WARNING: zcli build failed; not staged." >&2
    fi
fi

# --- M16 (S59): fmcli — real filesystem ops via NSFileManager -----------------
# A fundamental userland capability (pure Foundation). fmcli.m exercises the core
# NSFileManager API: createDirectoryAtPath / NSData writeToFile / fileExistsAtPath
# isDirectory / contentsAtPath / contentsOfDirectoryAtPath / attributesOfItemAtPath.
# VERIFIED M16/S59 (live): M16-MKDIR-OK / M16-WRITE-OK / M16-EXISTS-1 /
# M16-READ-DARWIN / M16-LIST-1 / M16-ATTR-SIZE-14 / M16-DONE. KNOWN GAP (non-gating):
# removeItemAtPath: fails — FsFileNode::remove() -> host unlink(nativePath) EPERM
# (errno=1), independent of atomic/non-atomic write (M16-REMOVE-GAP-epermremove);
# a future emulator VFS fix (source/io/fsfilenode.cpp). Run:
# BW64_SHELLSPAWN=/usr/bin/fmcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-fmcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-fmcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/fmcli" ]; then
            echo "--- M16/S59: staged fmcli at usr/bin/fmcli ---"
        fi
    else
        echo "WARNING: fmcli build failed; not staged." >&2
    fi
fi

# --- M17 (S60): datecli — date/time via NSDateFormatter + NSCalendar -----------
# A fundamental Foundation capability (parsing/formatting dates + calendar
# arithmetic). datecli.m parses a fixed UTC instant, round-trips the format,
# reformats under a different pattern, decomposes to NSDateComponents (year/month/
# day) via a Gregorian NSCalendar, adds 40 days, and measures the interval. KEY
# LINK FIX (resolves the M8 NSCharacterSet by-path gotcha): NSDate/NSCalendar/
# NSLocale/NSTimeZone/NSDateComponents are defined in CoreFoundation (imported U
# into Foundation, which re-exports it), so build-datecli.sh links CoreFoundation
# BY PATH too. Installed at /usr/bin/datecli. VERIFIED M17/S60 (live): M17-PARSE-OK
# / M17-FORMAT-2026-01-15 12:00:00 +0000 / M17-ALTFMT-... / M17-YMD-2026-1-15 /
# M17-PLUS40-2026-02-24 12:00:00 +0000 / M17-INTERVAL-3456000 / M17-DONE.
# KNOWN GAP (non-gating, like the M16 remove gap): the embedded-ICU-66 day-of-week
# derivation is wrong under emulation — weekday reports Sun(1) for a date whose YMD
# correctly extracts as Thu(2026-01-15); an internally-consistent off-by-4 across
# both the NSCalendar weekday component and the EEE formatter. Not a data/mmap
# issue (ICU data is embedded: symbol _icudt66_dat) and not a TZ slip (YMD right);
# a prebuilt ICU defect, not recompilable in-tree. The probe cross-checks the
# authoritative weekday with Zeller's congruence (works in-guest: pure integer math
# on the correct YMD) -> M17-WEEKDAY-MATCH-MISMATCH (ICU=1 vs Zeller=5). Gate = the
# 6 working facets. Run:
# BW64_SHELLSPAWN=/usr/bin/datecli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-datecli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-datecli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/datecli" ]; then
            echo "--- M17/S60: staged datecli at usr/bin/datecli ---"
        fi
    else
        echo "WARNING: datecli build failed; not staged." >&2
    fi
fi

# --- M18 (S61): xpathcli — DIRECT libxml2 with XPath queries + DOM navigation --
# A DEEPER, NEW capability over M8's NSXMLParser SAX wrapper: drives libxml2's real
# engine directly to build an in-memory DOM, navigate the element tree, read
# attributes/text, and run XPath expressions (node-set selection + string()
# extraction) — which the SAX-only path cannot do. libxml2 is a clean self-contained
# staged C lib (deps libSystem/libicucore/libz/libc++); build-xpathcli.sh links it
# BY PATH and the C API is declared extern (no libxml headers staged; the touched
# structs are mirrored by their head prefix, ABI-validated header-free on host).
# Installed at /usr/bin/xpathcli. VERIFIED M18/S61 (live): M18-XMLVER-20904 /
# M18-PARSE-OK / M18-ROOT-catalog / M18-FIRSTCHILD-book / M18-ATTR-b1 /
# M18-TEXT-Darwin / M18-XPATH-COUNT-3 / M18-XPATH-PRICE-31.50 / M18-NSSTRING-OK /
# M18-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/xpathcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-xpathcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-xpathcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/xpathcli" ]; then
            echo "--- M18/S61: staged xpathcli at usr/bin/xpathcli ---"
        fi
    else
        echo "WARNING: xpathcli build failed; not staged." >&2
    fi
fi

# --- M19 (S62): arccli — archive (tar) create + extract via libarchive ---------
# A structured-archive capability above M15's raw zlib byte compression. arccli.m
# does a fully self-contained in-memory round trip: write a 2-entry ustar tar via
# the libarchive write API, then read it back via the read API (format/filter
# auto-detect), enumerate entries (pathname + size), and verify the extracted body
# bytes. libarchive is a clean self-contained staged C lib (deps libSystem/liblzma/
# libz/libbz2/libiconv); build-arccli.sh links it BY PATH and the C API is declared
# extern (no archive.h staged; archive/archive_entry are opaque pointers, ABI
# validated header-free on host). Installed at /usr/bin/arccli. VERIFIED M19/S62
# (live): M19-ARCVER-libarchive 3.3.2 / M19-WRITE-OK / M19-WROTE-3072 /
# M19-READ-OPEN-OK / M19-ENTRY-note.txt-14 / M19-ENTRY-data.bin-22 / M19-COUNT-2 /
# M19-CONTENT-OK / M19-NSSTRING-OK / M19-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/arccli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-arccli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-arccli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/arccli" ]; then
            echo "--- M19/S62: staged arccli at usr/bin/arccli ---"
        fi
    else
        echo "WARNING: arccli build failed; not staged." >&2
    fi
fi

# --- M20 (S63): cryptocli — cryptographic digests + HMAC via modern libcrypto --
# A fundamental, deterministic, headless capability (hashing underpins integrity,
# signatures, content-addressing). cryptocli.m computes SHA-256 (one-shot AND via
# the streaming EVP context API, confirming they match), MD5, and HMAC-SHA256,
# each verified against authoritative host-computed hex. Uses the MODERN libcrypto
# (the M4c lesson: libcrypto.44, NOT the ancient 0.9.x); in-guest that is actually
# LibreSSL 2.8.3 under the OpenSSL-44 versioning, and the EVP/HMAC/SHA/MD5 paths all
# work. build-cryptocli.sh links libcrypto.44 BY PATH and declares the C API extern
# (no openssl headers staged; EVP_MD_CTX is an opaque handle, ABI-validated header-
# free on host). Installed at /usr/bin/cryptocli. VERIFIED M20/S63 (live):
# M20-SSLVER-LibreSSL 2.8.3 / M20-SHA256-OK / M20-EVP-MATCH-OK / M20-MD5-OK /
# M20-HMAC-OK / M20-NSSTRING-OK / M20-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/cryptocli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-cryptocli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-cryptocli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/cryptocli" ]; then
            echo "--- M20/S63: staged cryptocli at usr/bin/cryptocli ---"
        fi
    else
        echo "WARNING: cryptocli build failed; not staged." >&2
    fi
fi

# --- M21 (S64): aescli — AES-256-CBC symmetric encryption via libcrypto EVP ----
# Extends M20 (digests) to the CIPHER path of the same modern OpenSSL. aescli.m does
# a deterministic encrypt->decrypt round trip with a FIXED key+IV: encrypt a known
# plaintext via EVP_EncryptInit/Update/Final (EVP_aes_256_cbc, PKCS#7), confirm the
# ciphertext hex equals the authoritative host value, then decrypt via
# EVP_DecryptInit/Update/Final and confirm byte-identity with the original. Uses the
# MODERN libcrypto.44 (in-guest LibreSSL 2.8.3 under OpenSSL-44 versioning, per M20);
# build-aescli.sh links it BY PATH and declares the C API extern (no openssl headers;
# EVP_CIPHER_CTX opaque, ABI-validated header-free on host). Installed at
# /usr/bin/aescli. VERIFIED M21/S64 (live): M21-SSLVER-LibreSSL 2.8.3 /
# M21-ENC-LEN-32 / M21-CIPHER-OK / M21-DIFFERS-OK / M21-DEC-LEN-31 /
# M21-ROUNDTRIP-OK / M21-NSDATA-OK / M21-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/aescli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-aescli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-aescli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/aescli" ]; then
            echo "--- M21/S64: staged aescli at usr/bin/aescli ---"
        fi
    else
        echo "WARNING: aescli build failed; not staged." >&2
    fi
fi

# --- M22 (S65): b64cli — Base64 + URL percent-encoding via Foundation ----------
# A fundamental encoding capability (pure Foundation, no networking). b64cli.m:
# base64 encode/decode round trip via NSData; NSCharacterSet membership check; URL
# percent-encode/decode round trip. EXERCISES the M17 CoreFoundation-by-path finding
# (NSData/NSCharacterSet live in CF) — build-b64cli.sh links CoreFoundation BY PATH.
# KEY GUEST API FINDING: this Cocotron Foundation predates the OS X 10.9 percent API
# (+[NSCharacterSet URLQueryAllowedCharacterSet] and
# stringByAddingPercentEncodingWithAllowedCharacters: are ABSENT — an initial probe
# threw "unrecognized selector"). The probe uses the LEGACY percent-escape API the
# guest DOES ship (stringByAddingPercentEscapesUsingEncoding: + Replacing) plus
# +characterSetWithCharactersInString:. Installed at /usr/bin/b64cli. VERIFIED
# M22/S65 (live): M22-B64-OK / M22-B64-DECODE-OK / M22-CSET-OK / M22-PCT-OK /
# M22-PCT-DECODE-OK / M22-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/b64cli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-b64cli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-b64cli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/b64cli" ]; then
            echo "--- M22/S65: staged b64cli at usr/bin/b64cli ---"
        fi
    else
        echo "WARNING: b64cli build failed; not staged." >&2
    fi
fi

# --- M23 (S66): scancli — NSScanner string tokenizing + NSUUID gen/round-trip --
# Two fundamental Foundation capabilities (pure Foundation, no networking).
# scancli.m: NSScanner scans an int / double / delimited token out of a structured
# string (scanInt:/scanDouble:/scanUpToString:intoString:) and confirms isAtEnd;
# NSUUID parses a known UUID string, verifies its 16 bytes vs the authoritative host
# value, round-trips UUIDString, and confirms a generated +UUID is well-formed and
# unique. ALL selectors were verified present in the staged guest binary before
# authoring (the M22 lesson). NSScanner/charactersToBeSkipped pull in NSCharacterSet
# (CF-resident) so build-scancli.sh links CoreFoundation BY PATH (the M17 finding).
# Installed at /usr/bin/scancli. VERIFIED M23/S66 (live): M23-SCAN-INT-42 /
# M23-SCAN-DBL-19.95 / M23-SCAN-TOK-Darwin / M23-SCAN-TAIL-OK /
# M23-UUID-BYTES-OK / M23-UUID-ROUNDTRIP-OK / M23-UUID-GEN-OK / M23-DONE — a full
# clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/scancli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-scancli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-scancli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/scancli" ]; then
            echo "--- M23/S66: staged scancli at usr/bin/scancli ---"
        fi
    else
        echo "WARNING: scancli build failed; not staged." >&2
    fi
fi

# --- M24 (S67): predcli — NSPredicate + NSSortDescriptor + NSExpression --------
# Collection querying (pure Foundation, no networking): filter/sort/evaluate over an
# in-memory array of dictionaries — the core of fetch requests and rule engines.
# predcli.m: predicateWithFormat:@"qty >= 20" + filteredArrayUsingPredicate:, a
# descending NSSortDescriptor, an arithmetic NSExpression (6*7), and a compound AND
# predicate. ALL selectors verified present in the staged guest binary before
# authoring (M22 lesson). NSPredicate leans on CF machinery so build-predcli.sh
# links CoreFoundation BY PATH (M17). Installed at /usr/bin/predcli. VERIFIED
# M24/S67 (live): M24-COUNT-4 / M24-FILTER-3 / M24-FILTER-NAMES-beta,gamma,delta /
# M24-SORT-TOP-gamma / M24-SORT-ORDER-gamma,delta,beta / M24-EXPR-42 / M24-AND-1 /
# M24-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/predcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-predcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-predcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/predcli" ]; then
            echo "--- M24/S67: staged predcli at usr/bin/predcli ---"
        fi
    else
        echo "WARNING: predcli build failed; not staged." >&2
    fi
fi

# --- M25 (S68): archcli — object serialization via NSKeyedArchiver + plist ------
# A fundamental persistence/IPC capability (pure Foundation, no networking):
# archive an object graph to bytes and restore it. archcli.m: keyed-archive a nested
# {string,number,array} dict via archivedDataWithRootObject:, unarchive it, confirm
# deep equality + pull a string/number; plus a binary-plist round trip via
# NSPropertyListSerialization. Uses the LEGACY archiving API (pre-secure-coding) the
# guest ships (M22 vintage lesson); all selectors pre-vetted present. NSPropertyList
# Serialization is CF-resident so build-archcli.sh links CoreFoundation BY PATH (M17).
# Installed at /usr/bin/archcli. VERIFIED M25/S68 (live): M25-ARCH-OK /
# M25-ARCH-STR-Darwin / M25-ARCH-NUM-42 / M25-PLIST-LEN-104 / M25-PLIST-OK /
# M25-DONE — a full clean pass (no gaps; the keyed-archive byte length differs from
# host, 448 vs 412, an encoding-overhead diff that does not affect the round trip).
# Run: BW64_SHELLSPAWN=/usr/bin/archcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-archcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-archcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/archcli" ]; then
            echo "--- M25/S68: staged archcli at usr/bin/archcli ---"
        fi
    else
        echo "WARNING: archcli build failed; not staged." >&2
    fi
fi

# --- M26 (S69): deccli — exact decimal arithmetic + NSCountedSet counting -------
# Two fundamental Foundation capabilities (pure Foundation, no networking).
# NSDecimalNumber does arbitrary-precision BASE-10 math (what money needs — binary
# float cannot represent 0.10+0.20 exactly, decimal can); NSCountedSet is a
# frequency multiset. deccli.m: 0.10+0.20 == "0.3" exactly (and shows the C double
# 0.1+0.2 != 0.3), 19.99*3 == "59.97" exactly, and counts [a,b,a,c,a,b] -> a:3/b:2/
# c:1. All selectors pre-vetted present (M22); CoreFoundation linked BY PATH (M17).
# Installed at /usr/bin/deccli. VERIFIED M26/S69 (live): M26-DEC-SUM-0.3 /
# M26-DEC-SUM-OK / M26-DOUBLE-DIFFERS-OK / M26-DEC-MUL-59.97 / M26-DEC-MUL-OK /
# M26-CSET-A-3 / M26-CSET-OK / M26-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/deccli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-deccli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-deccli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/deccli" ]; then
            echo "--- M26/S69: staged deccli at usr/bin/deccli ---"
        fi
    else
        echo "WARNING: deccli build failed; not staged." >&2
    fi
fi

# --- M27 (S70): urlcli — NSString path manipulation + NSURL parse/compose -------
# A fundamental Foundation capability (pure Foundation, no networking; NSURL here is
# pure parsing, not fetching) complementing M16. urlcli.m: NSString path ops on
# "/usr/local/bin/darwin.app" (lastPathComponent/pathExtension/deleteLast/append/
# pathComponents) + NSURL parse of "https://example.com:8080/a/b/file.json?q=1"
# (scheme/host/path/lastPathComponent) + fileURLWithPath:+URLByAppendingPathComponent:.
# Selectors pre-vetted present (M22); NSURL is CF-resident so build-urlcli.sh links
# CoreFoundation BY PATH (M17). Installed at /usr/bin/urlcli. VERIFIED M27/S70 (live):
# M27-LAST-darwin.app / M27-EXT-app / M27-DELLAST-/usr/local/bin / M27-APPEND-.../Contents
# / M27-NCOMP-5 / M27-URL-SCHEME-https / M27-URL-HOST-example.com /
# M27-URL-PATH-/a/b/file.json / M27-URL-LAST-file.json / M27-FILEURL-OK / M27-DONE —
# a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/urlcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-urlcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-urlcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/urlcli" ]; then
            echo "--- M27/S70: staged urlcli at usr/bin/urlcli ---"
        fi
    else
        echo "WARNING: urlcli build failed; not staged." >&2
    fi
fi

# --- M28 (S71): numcli — number formatting + parsing via NSNumberFormatter ------
# A fundamental Foundation capability (pure Foundation, no networking). numcli.m
# pins en_US_POSIX with explicit fraction digits: format 1234567.5 ungrouped ->
# "1234567.50", 42 -> "42.00", parse "1234567.50" back == 1234567.5, negative round
# trip -42.25, and grouping WITH an explicit grouping size -> "1,234,567.50". Guest
# quirk recorded: Cocotron NSNumberFormatter needs an EXPLICIT setGroupingSize: to
# emit separators (setUsesGroupingSeparator:YES alone leaves size 0 = no grouping;
# the host default of 3 masks this). Selectors pre-vetted present (M22); CF by-path
# (M17). Installed at /usr/bin/numcli. VERIFIED M28/S71 (live): M28-FMT-OK /
# M28-FMT42-OK / M28-PARSE-OK / M28-NEG-ROUNDTRIP-OK / M28-GROUPING-OK / M28-DONE —
# a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/numcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-numcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-numcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/numcli" ]; then
            echo "--- M28/S71: staged numcli at usr/bin/numcli ---"
        fi
    else
        echo "WARNING: numcli build failed; not staged." >&2
    fi
fi

# --- M29 (S72): strcli — everyday NSString text processing ---------------------
# Split/join/trim/case/search/replace (pure Foundation, no networking) — the plain
# string-ops layer complementing M9 (regex) and M23 (NSScanner). strcli.m:
# componentsSeparatedByString:/byCharactersInSet:, componentsJoinedByString:,
# stringByTrimmingCharactersInSet:, upper/lowercaseString, rangeOfString:,
# stringByReplacingOccurrencesOfString:, hasPrefix/hasSuffix. Selectors pre-vetted
# (M22); char-set ops pull in NSCharacterSet so build-strcli.sh links CoreFoundation
# BY PATH (M17). Installed at /usr/bin/strcli. VERIFIED M29/S72 (live): M29-SPLIT-4 /
# M29-JOIN-a|b|c|d / M29-SPLITSET-3 / M29-TRIM-hi / M29-UPPER-DARWIN / M29-LOWER-darwin
# / M29-FIND-7 / M29-REPLACE-DARWIN ROCKS / M29-PREFIX-1 / M29-DONE — a full clean
# pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/strcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-strcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-strcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/strcli" ]; then
            echo "--- M29/S72: staged strcli at usr/bin/strcli ---"
        fi
    else
        echo "WARNING: strcli build failed; not staged." >&2
    fi
fi

# --- M30 (S73): datacli — NSData/NSMutableData binary buffer operations ---------
# Binary-buffer manipulation (pure Foundation, no networking) — the layer under
# every parser/serializer/codec. datacli.m: build via appendData:/appendBytes:,
# slice via subdataWithRange:, search via rangeOfData:options:range:, patch in place
# via replaceBytesInRange:withBytes:, read out via getBytes:range:. Selectors
# pre-vetted (M22); NSData/NSMutableData are CF-resident so build-datacli.sh links
# CoreFoundation BY PATH (M17). Installed at /usr/bin/datacli. VERIFIED M30/S73
# (live): M30-LEN-14 / M30-BUILD-DARWIN COMPUTA / M30-SLICE-COMPUTA / M30-FIND-7 /
# M30-PATCH-darwin COMPUTA / M30-GET-darwin / M30-DONE — a full clean pass (no gaps).
# Run: BW64_SHELLSPAWN=/usr/bin/datacli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-datacli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-datacli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/datacli" ]; then
            echo "--- M30/S73: staged datacli at usr/bin/datacli ---"
        fi
    else
        echo "WARNING: datacli build failed; not staged." >&2
    fi
fi

# --- M31 (S74): pipecli — CLI SYNTHESIS (JSON -> predicate -> archive -> SHA-256) -
# Composes four separately-proven capabilities into one data pipeline in a single
# process (the CLI analog of the M11-M14 GUI synthesis tier) — proving they
# INTEROPERATE: JSON parse (M7) -> NSPredicate filter (M24) -> NSKeyedArchiver (M25)
# -> SHA-256 (M20). pipecli.m parses a JSON record array, filters qty>=20, keyed-
# archives the result, SHA-256s the archive, runs the whole pipeline TWICE to prove
# end-to-end determinism (identical digest), and round-trips the unarchive. Links the
# union of needs BY PATH: Foundation + CoreFoundation (M17) + modern libcrypto.44
# (M20). Installed at /usr/bin/pipecli. VERIFIED M31/S74 (live): M31-JSON-OK /
# M31-COUNT-3 / M31-NAMES-beta,gamma,delta / M31-STABLE-OK / M31-UNARCHIVE-OK /
# M31-DONE — full clean pass on the archive-format-independent gating checks (the SHA
# value + archive length differ from host: guest NSKeyedArchiver encodes differently,
# non-gating). Run:
# BW64_SHELLSPAWN=/usr/bin/pipecli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-pipecli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-pipecli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/pipecli" ]; then
            echo "--- M31/S74: staged pipecli at usr/bin/pipecli ---"
        fi
    else
        echo "WARNING: pipecli build failed; not staged." >&2
    fi
fi

# --- M32 (S75): x2jcli — CROSS-TIER SYNTHESIS (libxml2 XPath -> JSON -> AES) -----
# CLI synthesis #2, spanning the C-library tier and the Foundation tier in one
# process to prove they interoperate across the boundary (a different mix than M31):
# libxml2 XPath (M18) -> NSJSONSerialization (M7) -> AES-256-CBC enc/dec (M21).
# x2jcli.m parses an XML <catalog> with libxml2, XPath //book extracts title+price
# into a Foundation array, serializes to JSON, AES-256 encrypts the JSON (fixed
# key+IV), decrypts it back (byte-identical), and re-parses the JSON to confirm the
# data survived the full round trip. Links Foundation + CoreFoundation (M17) +
# libxml2.2 (M18) + libcrypto.44 (M21) by path; C APIs extern (libxml2 structs
# head-prefix, ABI-validated header-free on host). Installed at /usr/bin/x2jcli.
# VERIFIED M32/S75 (live, matches host exactly): M32-XML-OK / M32-XPATH-3 /
# M32-JSON-110 / M32-ENC-LEN-112 / M32-DEC-OK / M32-REPARSE-3 / M32-TITLE2-Computa /
# M32-PRICE2-31.50 / M32-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/x2jcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-x2jcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-x2jcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/x2jcli" ]; then
            echo "--- M32/S75: staged x2jcli at usr/bin/x2jcli ---"
        fi
    else
        echo "WARNING: x2jcli build failed; not staged." >&2
    fi
fi

# --- M33 (S76): dbjzcli — PERSISTENCE-TIER SYNTHESIS (SQLite -> JSON -> zlib) ----
# CLI synthesis #3, the persistence tier end to end. Composes a real on-disk DB, the
# Foundation data tier, and compression in one process: SQLite on disk (M6') ->
# NSJSONSerialization (M7) -> zlib compress (M15). dbjzcli.m opens an on-disk SQLite
# DB, CREATE+INSERT 3 rows, SELECT them back via a prepared statement into a
# Foundation array, serializes to JSON, zlib-compresses, then uncompresses and
# confirms byte-identity + re-parses. Links Foundation + CoreFoundation (M17) +
# libsqlite3 (M6') + libz.1 (M15) by path; C APIs extern. Installed at
# /usr/bin/dbjzcli. VERIFIED M33/S76 (live, matches host exactly): M33-DBOPEN-OK /
# M33-INSERT-3 / M33-SELECT-3 / M33-NAME2-beta / M33-JSON-72 / M33-ZIP-52 /
# M33-ROUNDTRIP-OK / M33-REPARSE-3 / M33-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/dbjzcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-dbjzcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-dbjzcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/dbjzcli" ]; then
            echo "--- M33/S76: staged dbjzcli at usr/bin/dbjzcli ---"
        fi
    else
        echo "WARNING: dbjzcli build failed; not staged." >&2
    fi
fi

# --- M34 (S77): setcli — NSSet set algebra + NSOrderedSet ordered-unique ---------
# Collection capabilities (pure Foundation, no networking) rounding out the
# collections tier alongside M24 (predicate/sort) and M26 (counted set). setcli.m:
# membership, dedup via setWithArray:, union/intersect/minus, isSubsetOfSet:, and
# NSOrderedSet insertion-order + uniqueness (count/indexOfObject:/objectAtIndex:).
# Selectors pre-vetted (M22); NSSet/NSOrderedSet are CF-resident so build-setcli.sh
# links CoreFoundation BY PATH (M17). Installed at /usr/bin/setcli. VERIFIED M34/S77
# (live, matches host exactly): M34-HAS-1 / M34-DEDUP-3 / M34-UNION-4 /
# M34-INTERSECT-2 / M34-MINUS-2 / M34-SUBSET-1 / M34-ORDERED-CNT-3 / M34-ORDERED-IDX-1
# / M34-ORDERED-FIRST-c / M34-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/setcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-setcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-setcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/setcli" ]; then
            echo "--- M34/S77: staged setcli at usr/bin/setcli ---"
        fi
    else
        echo "WARNING: setcli build failed; not staged." >&2
    fi
fi

# --- M35 (S78): proccli — NSProcessInfo process + environment introspection ------
# Runtime introspection (pure Foundation, no networking): env vars, process name, OS
# version, CPU/memory facts, unique-id minting. proccli.m: environment dict (>0,
# PATH present), processName, operatingSystemVersionString, processorCount (>=1),
# physicalMemory (>0), globallyUniqueString (two calls differ). Gating is STRUCTURAL
# (the guest's runtime facts differ from host). Selectors pre-vetted (M22); CF by-path
# (M17). Installed at /usr/bin/proccli. VERIFIED M35/S78 (live): M35-ENV-COUNT-10 /
# M35-ENV-HASPATH-1 / M35-PROCNAME-proccli / M35-OSVER-OK / M35-CPUS-8 / M35-MEM-OK /
# M35-GUID-OK / M35-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/proccli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-proccli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-proccli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/proccli" ]; then
            echo "--- M35/S78: staged proccli at usr/bin/proccli ---"
        fi
    else
        echo "WARNING: proccli build failed; not staged." >&2
    fi
fi

# --- M36 (S79): timercli — NSTimer + NSRunLoop event-loop machinery -------------
# The async/event-loop substrate (pure Foundation, no networking) GUI apps + async
# code depend on. timercli.m schedules a ONE-SHOT NSTimer on the current run loop,
# pumps the loop (runMode:beforeDate:), and confirms the callback is delivered + time
# advanced. Selectors + NSDefaultRunLoopMode (CF const) pre-vetted (M22); CF by-path
# (M17). KNOWN GUEST GAPS (non-gating, documented): (1) a REPEATING NSTimer fires
# only ONCE under emulation; (2) -[NSThread sleepForTimeInterval:] HANGS. The probe
# avoids both (one-shot timer, NSDate timing, no thread sleep). Installed at
# /usr/bin/timercli. VERIFIED M36/S79 (live): M36-FIRED-1 / M36-FIRED-OK /
# M36-ELAPSED-OK / M36-MAINTHREAD-1 / M36-DONE — a full clean pass on the gated
# facets. Run:
# BW64_SHELLSPAWN=/usr/bin/timercli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-timercli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-timercli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/timercli" ]; then
            echo "--- M36/S79: staged timercli at usr/bin/timercli ---"
        fi
    else
        echo "WARNING: timercli build failed; not staged." >&2
    fi
fi

# --- M37 (S80): fhcli — NSFileHandle descriptor-level file I/O -------------------
# Streaming FD-level read/write/seek over a real on-disk file (pure Foundation, no
# networking) — completes the file-I/O picture with M16 (NSFileManager path ops) and
# M30 (in-memory NSData). fhcli.m: write via fileHandleForWritingAtPath: + two
# writeData: calls, read via fileHandleForReadingAtPath: readDataToEndOfFile,
# seekToFileOffset: + readDataOfLength: partial read, offsetInFile. Avoids the M16
# removeItemAtPath gap (leaves the file in place). Selectors pre-vetted (M22); CF
# by-path (M17). Installed at /usr/bin/fhcli. VERIFIED M37/S80 (live, matches host
# exactly): M37-WRITE-OK / M37-READALL-DARWIN COMPUTA / M37-SEEKREAD-COMPUTA /
# M37-OFFSET-14 / M37-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/fhcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-fhcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-fhcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/fhcli" ]; then
            echo "--- M37/S80: staged fhcli at usr/bin/fhcli ---"
        fi
    else
        echo "WARNING: fhcli build failed; not staged." >&2
    fi
fi

# --- M38 (S81): enccli — NSString text encoding conversion + encoded file I/O -----
# Encoding-conversion machinery (pure Foundation, no networking): UTF-8/UTF-16 byte
# lengths, NSData round-trip, ASCII-convertibility, and writing/reading a UTF-8 text
# file with a multi-byte char — distinct from M22 (base64/percent) and M29 (plain
# string ops). enccli.m on "Darwin café": lengthOfBytesUsingEncoding: UTF8 (12) /
# UTF16 (22), dataUsingEncoding:+initWithData:encoding: round trip, canBeConvertedTo
# Encoding:ASCII (NO — the é blocks it), writeToFile:encoding:UTF8 +
# stringWithContentsOfFile:encoding:. Avoids the M16 removeItemAtPath gap. Selectors
# pre-vetted (M22); CF by-path (M17). Installed at /usr/bin/enccli. VERIFIED M38/S81
# (live, matches host exactly): M38-UTF8LEN-12 / M38-UTF16LEN-22 / M38-ROUNDTRIP-OK /
# M38-ASCII-0 / M38-FILE-OK / M38-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/enccli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-enccli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-enccli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/enccli" ]; then
            echo "--- M38/S81: staged enccli at usr/bin/enccli ---"
        fi
    else
        echo "WARNING: enccli build failed; not staged." >&2
    fi
fi

# --- M39 (S82): csvcli — CLI SYNTHESIS #4 (file -> split -> decimal sum -> JSON) --
# A realistic "ingest a data file, compute, emit JSON" pipeline (pure Foundation, no
# networking) composing four proven capabilities: NSFileHandle read (M37) ->
# NSString split (M29) -> NSDecimalNumber exact sum (M26) -> NSJSONSerialization (M7).
# csvcli.m writes a CSV-ish file, reads it via a file handle, splits rows/fields, sums
# the amount column with exact decimal math (19.99+12.50+31.35=63.84), and emits
# {count,total,names} as JSON with a round-trip check. Pure Foundation +
# CoreFoundation BY PATH (M17); avoids the M16 remove gap. Installed at /usr/bin/csvcli.
# VERIFIED M39/S82 (live, matches host exactly): M39-READ-47 / M39-ROWS-3 /
# M39-TOTAL-63.84 / M39-JSON-{"count":3,"total":"63.84",...} / M39-JSON-OK /
# M39-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/csvcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-csvcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-csvcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/csvcli" ]; then
            echo "--- M39/S82: staged csvcli at usr/bin/csvcli ---"
        fi
    else
        echo "WARNING: csvcli build failed; not staged." >&2
    fi
fi

# --- M40 (S83): errcli — NSError out-param + ObjC @try/@catch/@throw -------------
# The error-handling substrate every robust program relies on (pure Foundation + the
# ObjC exception runtime, no networking). errcli.m: construct/read an NSError
# (domain/code/localizedDescription), propagate one through an (NSError**) out-param,
# and @throw/@catch/@finally an NSException (name/reason), confirming control resumes.
# The ObjC exception helpers (objc_exception_throw/begin_catch/end_catch) are exported
# by the staged libobjc, so @throw/@catch work. NSError/NSException are CF-resident +
# NSLocalizedDescriptionKey is a CF const, so build-errcli.sh links CoreFoundation BY
# PATH (M17). Selectors pre-vetted (M22). Installed at /usr/bin/errcli. VERIFIED
# M40/S83 (live, matches host exactly): M40-ERR-DOMAIN-DarwinComputa / M40-ERR-CODE-42
# / M40-ERR-DESC-boom / M40-OUTPARAM-OK / M40-CATCH-DarwinError /
# M40-CATCH-REASON-deliberate / M40-AFTER-OK / M40-DONE — a full clean pass (no gaps).
# Run: BW64_SHELLSPAWN=/usr/bin/errcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-errcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-errcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/errcli" ]; then
            echo "--- M40/S83: staged errcli at usr/bin/errcli ---"
        fi
    else
        echo "WARNING: errcli build failed; not staged." >&2
    fi
fi

# --- M41 (S84): caldiffcli — NSCalendar date-from-components + date-difference ----
# The INVERSE of M17: build a date from explicit Y/M/D components and compute the
# span between two dates (pure Foundation, no networking; avoids the M17 ICU weekday
# gap — no weekday facet). caldiffcli.m: dateFromComponents: to build 2026-01-15 and
# 2026-02-24, round-trip via components:fromDate:, then components:fromDate:toDate:
# for the day span (40) and month+day span (1 month, 9 days), plus a compare:.
# @"gregorian" + UTC (per M17). NSCalendar/NSDateComponents are CF-resident so
# build-caldiffcli.sh links CoreFoundation BY PATH (M17). Selectors pre-vetted (M22;
# -[NSDateComponents day] confirmed via the method table). Installed at
# /usr/bin/caldiffcli. VERIFIED M41/S84 (live, matches host exactly):
# M41-BUILDA-2026-1-15 / M41-BUILDB-2026-2-24 / M41-DIFFDAYS-40 / M41-DIFFMON-1-9 /
# M41-ORDER-OK / M41-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/caldiffcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-caldiffcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-caldiffcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/caldiffcli" ]; then
            echo "--- M41/S84: staged caldiffcli at usr/bin/caldiffcli ---"
        fi
    else
        echo "WARNING: caldiffcli build failed; not staged." >&2
    fi
fi

# --- M42 (S85): recap — NSRegularExpression capture groups + template replacement -
# A DEEPER regex exercise than M9's basic matching (pure Foundation, no networking):
# numbered capture-group extraction, multi-match counting, and $1-style template
# (backreference) replacement. recap.m: (\w+)=(\d+) on "qty=42" -> CAP1 "qty"/CAP2 "42"
# /NRANGES 3, \d+ count in "a1 b22 c333" (3), template "$2:$1" -> "42:qty", global
# "$2=$1" on "x=1 y=2" -> "1=x 2=y". Selectors pre-vetted (M22); CF by-path (M17).
# Installed at /usr/bin/recap. VERIFIED M42/S85 (live, matches host exactly):
# M42-CAP1-qty / M42-CAP2-42 / M42-NRANGES-3 / M42-COUNT-3 / M42-TEMPLATE-42:qty /
# M42-GLOBAL-1=x 2=y / M42-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/recap bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-recap.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-recap.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/recap" ]; then
            echo "--- M42/S85: staged recap at usr/bin/recap ---"
        fi
    else
        echo "WARNING: recap build failed; not staged." >&2
    fi
fi

# --- M43 (S86): csetcli — NSCharacterSet predefined classes + membership/inversion -
# Deepens NSCharacterSet coverage (pure Foundation, no networking) beyond M22
# (membership) / M29 (splitting): the PREDEFINED class sets + inverted-set semantics.
# csetcli.m: decimalDigit/letter/whitespace/alphanumeric character classes, a custom
# characterSetWithCharactersInString:, and invertedSet — each via characterIsMember:.
# Uses the pre-10.9 class methods the guest ships (the 10.9 URL* sets are ABSENT per
# M22). Selectors pre-vetted (M22); CF by-path (M17). Installed at /usr/bin/csetcli.
# VERIFIED M43/S86 (live, matches host exactly): M43-DIGIT-1 / M43-LETTER-1 /
# M43-WS-1 / M43-ALNUM-1 / M43-CUSTOM-1 / M43-INVERTED-1 / M43-DONE — a full clean
# pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/csetcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-csetcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-csetcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/csetcli" ]; then
            echo "--- M43/S86: staged csetcli at usr/bin/csetcli ---"
        fi
    else
        echo "WARNING: csetcli build failed; not staged." >&2
    fi
fi

# --- M44 (S87): cfuuidcli — CFUUID + CFString via the CoreFoundation C API -------
# The CF C-layer counterpart to M23's NSUUID (pure-C path, NO ObjC runtime). Proves
# the CoreFoundation C API works on the substrate independent of the ObjC bridge.
# cfuuidcli.m: CFUUIDCreate -> CFUUIDCreateString (36-char "8-4-4-4-12"), two differ,
# CFUUIDCreateFromString on a known UUID -> CFUUIDGetUUIDBytes == known bytes. A
# PURE-C probe (no #import <Foundation>) to avoid an SDK-header collision (Foundation
# umbrella pulls in the real CFUUID.h, conflicting with our extern decls) — keeps the
# guest build header-free + host-validatable; CFUUIDBytes mirrored as a 16-byte
# MyCFUUIDBytes (ABI validated header-free on host). Symbols pre-vetted exported (M22);
# CF linked BY PATH (M17). Installed at /usr/bin/cfuuidcli. VERIFIED M44/S87 (live):
# M44-CFVER-1153 / M44-GENLEN-36 / M44-DASHES-4 / M44-UNIQUE-OK /
# M44-BYTES-0123456789ab4cde8f0123456789abcd / M44-BYTES-OK / M44-DONE — a full clean
# pass (CFVER differs from host, just proves the C lib is live). Run:
# BW64_SHELLSPAWN=/usr/bin/cfuuidcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-cfuuidcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-cfuuidcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/cfuuidcli" ]; then
            echo "--- M44/S87: staged cfuuidcli at usr/bin/cfuuidcli ---"
        fi
    else
        echo "WARNING: cfuuidcli build failed; not staged." >&2
    fi
fi

# --- M45 (S88): cfcollcli — CFArray + CFDictionary + CFNumber via the CF C API ----
# Extends M44's CF C-layer proof to the CONTAINER types (pure-C, NO ObjC runtime):
# build a CFArray of CFStrings + a CFDictionary of CFString->CFNumber via the pure-C
# interface, read count/indexed value/key lookup — exercising the CF retain/callback
# machinery (kCFTypeArrayCallBacks etc.). cfcollcli.m is a PURE-C probe (no #import
# <Foundation>) per the M44 trick; symbols pre-vetted exported (M22); CF linked BY
# PATH (M17). Installed at /usr/bin/cfcollcli. VERIFIED M45/S88 (live, matches host
# exactly): M45-ARRCOUNT-3 / M45-ARRIDX-OK / M45-DICTCOUNT-2 / M45-DICTVAL-42 /
# M45-DICTVAL-OK / M45-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/cfcollcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-cfcollcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-cfcollcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/cfcollcli" ]; then
            echo "--- M45/S88: staged cfcollcli at usr/bin/cfcollcli ---"
        fi
    else
        echo "WARNING: cfcollcli build failed; not staged." >&2
    fi
fi

# --- M46 (S89): cfdatacli — CFData + CFString operations via the CF C API --------
# Extends the CF C-layer (M44 CFUUID/CFString-create, M45 containers) to DATA BUFFERS
# + STRING OPS (pure-C, NO ObjC runtime): CFMutableData append/read + CFString find/
# substring/prefix. cfdatacli.m: CFDataCreateMutable + CFDataAppendBytes "DARWIN"/
# " COMPUTA" -> len 14 + byte compare, CFStringFindWithOptions "COMP" -> 7,
# CFStringCreateWithSubstring {7,7} -> "COMPUTA", CFStringHasPrefix "DARWIN". PURE-C
# probe per the M44 trick; CFRange mirrored (16-byte struct, ABI-validated header-free
# on host); symbols pre-vetted exported (M22); CF linked BY PATH (M17). Installed at
# /usr/bin/cfdatacli. VERIFIED M46/S89 (live, matches host exactly): M46-DATALEN-14 /
# M46-DATA-OK / M46-FIND-7 / M46-SUBSTR-OK / M46-PREFIX-1 / M46-DONE — a full clean
# pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/cfdatacli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-cfdatacli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-cfdatacli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/cfdatacli" ]; then
            echo "--- M46/S89: staged cfdatacli at usr/bin/cfdatacli ---"
        fi
    else
        echo "WARNING: cfdatacli build failed; not staged." >&2
    fi
fi

# --- M47 (S90): fmtcli — NSString formatting + NSMutableString building ----------
# The string-construction layer (pure Foundation, no networking), distinct from M29
# (split/search/case) and M38 (encodings). fmtcli.m: stringWithFormat: with mixed
# specifiers (%@/%d/%.2f/%x), NSMutableString appendString:/appendFormat:/
# insertString:atIndex:/replaceCharactersInRange:withString:, and
# stringByPaddingToLength:. Selectors pre-vetted (M22); NSString/NSMutableString are
# CF-resident so build-fmtcli.sh links CoreFoundation BY PATH (M17). Installed at
# /usr/bin/fmtcli. VERIFIED M47/S90 (live, matches host exactly):
# M47-FMT-Darwin #42 = 19.99 [2a] / M47-APPEND-DARWIN v2 / M47-INSERT-<<DARWIN v2 /
# M47-REPLACE->>DARWIN v2 / M47-PAD-Darwin.. / M47-DONE — a full clean pass (no gaps).
# Run: BW64_SHELLSPAWN=/usr/bin/fmtcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-fmtcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-fmtcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/fmtcli" ]; then
            echo "--- M47/S90: staged fmtcli at usr/bin/fmtcli ---"
        fi
    else
        echo "WARNING: fmtcli build failed; not staged." >&2
    fi
fi

# --- M48 (S91): idxcli — NSIndexSet / NSMutableIndexSet index-set operations -----
# A real Foundation collection (pure Foundation, no networking) — the integer-index
# set behind table/list selection, distinct from M34's NSSet/NSOrderedSet (object
# sets). idxcli.m: indexSetWithIndexesInRange:{2,3} count/contains, NSMutableIndexSet
# addIndexesInRange:+addIndex: count/first/last, and ordered iteration via firstIndex/
# indexGreaterThanIndex:. Selectors pre-vetted (M22); CF by-path (M17). Installed at
# /usr/bin/idxcli. VERIFIED M48/S91 (live, matches host exactly): M48-COUNT-3 /
# M48-HAS3-1 / M48-HAS5-0 / M48-MUTCOUNT-4 / M48-FIRST-2 / M48-LAST-10 /
# M48-ITER-2,3,4,10 / M48-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/idxcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-idxcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-idxcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/idxcli" ]; then
            echo "--- M48/S91: staged idxcli at usr/bin/idxcli ---"
        fi
    else
        echo "WARNING: idxcli build failed; not staged." >&2
    fi
fi

# --- M49 (S92): valcli — NSValue boxing of C structs (NSRange/NSPoint/NSSize) -----
# The Foundation pattern for putting non-object C structs into object collections
# (pure Foundation, no networking): box a struct in an NSValue, store it in an
# NSArray, pull it back, unbox, and compare. valcli.m: valueWithRange:/rangeValue,
# valueWithPoint:/pointValue, valueWithSize:/sizeValue, isEqualToValue:, and NSArray
# storage+retrieval. Selectors pre-vetted (M22); CF by-path (M17). Installed at
# /usr/bin/valcli. VERIFIED M49/S92 (live, matches host exactly): M49-RANGE-3-7 /
# M49-POINT-1.5-2.5 / M49-SIZE-40-80 / M49-EQ-1 / M49-ARR-POINT-1.5-2.5 / M49-DONE —
# a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/valcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-valcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-valcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/valcli" ]; then
            echo "--- M49/S92: staged valcli at usr/bin/valcli ---"
        fi
    else
        echo "WARNING: valcli build failed; not staged." >&2
    fi
fi

# --- M50 (S93): reportcli — CAPSTONE CLI SYNTHESIS (read->JSON->query->report->HMAC) -
# The most capabilities composed in one program yet: a realistic "ingest -> query ->
# report -> sign" pipeline chaining FIVE proven capabilities — NSFileHandle read (M37)
# -> NSJSONSerialization (M7) -> NSPredicate filter + NSSortDescriptor (M24) ->
# NSString format report (M47) -> HMAC-SHA256 (M20 libcrypto). reportcli.m writes a
# JSON {name,score} file, reads it via a file handle, parses, filters score>=80, sorts
# descending, formats a plain-text report, and HMAC-signs the report bytes (fixed key)
# verified vs the authoritative host hex. Links Foundation + CoreFoundation (M17) +
# libcrypto.44 (M20) BY PATH; HMAC extern; selectors pre-vetted (M22). Installed at
# /usr/bin/reportcli. VERIFIED M50/S93 (live, matches host exactly): M50-READ-115 /
# M50-PARSE-4 / M50-FILTER-3 / M50-TOP-gamma / M50-REPORT-REPORT|gamma=95|beta=88|delta=80|
# / M50-HMAC-OK / M50-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/reportcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-reportcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-reportcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/reportcli" ]; then
            echo "--- M50/S93: staged reportcli at usr/bin/reportcli ---"
        fi
    else
        echo "WARNING: reportcli build failed; not staged." >&2
    fi
fi

# --- M51 (S94): bytecli — NSByteCountFormatter human-readable byte-count formatting -
# Turns raw byte counts into "512 bytes"/"1 KB"/"1 MB"-style strings (pure Foundation,
# no networking) — the formatter every file/download UI uses. bytecli.m: decimal
# count style on 512/1500/1500000, plus includesUnit:NO. Gating is STRUCTURAL
# (unit-substring checks: "byte"/"KB"/"MB") to stay robust against the guest's ICU/
# locale quirks. Selectors pre-vetted (M22); CF by-path (M17). Installed at
# /usr/bin/bytecli. VERIFIED M51/S94 (live, matches host exactly): M51-B512-512 bytes /
# M51-B512-OK / M51-KB-1 KB / M51-KB-OK / M51-MB-OK / M51-NOUNIT-OK / M51-DONE — a
# full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/bytecli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-bytecli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-bytecli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/bytecli" ]; then
            echo "--- M51/S94: staged bytecli at usr/bin/bytecli ---"
        fi
    else
        echo "WARNING: bytecli build failed; not staged." >&2
    fi
fi

# --- M52 (S95): scan2cli — deeper NSScanner scanning (float/hex/longlong/charset) -
# Extends M23 (int/double/token) to numeric-format + charset-driven scanning (pure
# Foundation, no networking). scan2cli.m: scanFloat: "3.14rest"->3.14, scanHexInt:
# "0x2A"->42, scanLongLong: "9000000000" (>32-bit), scanCharactersFromSet:letters
# "abcDEF123"->"abcDEF", scanUpToCharactersFromSet:digits "name=123"->"name=".
# NSScanner pulls in NSCharacterSet (CF-resident) so build-scan2cli.sh links
# CoreFoundation BY PATH (M17). Selectors pre-vetted (M22). Installed at
# /usr/bin/scan2cli. VERIFIED M52/S95 (live, matches host exactly): M52-FLOAT-3.14 /
# M52-HEX-42 / M52-LL-9000000000 / M52-CHARS-abcDEF / M52-UPTO-name= / M52-DONE — a
# full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/scan2cli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-scan2cli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-scan2cli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/scan2cli" ]; then
            echo "--- M52/S95: staged scan2cli at usr/bin/scan2cli ---"
        fi
    else
        echo "WARNING: scan2cli build failed; not staged." >&2
    fi
fi

# --- M53 (S96): deccli2 — NSDecimalNumber division + power-of-10 + comparison -----
# Extends M26 (exact add/multiply) to division/scaling/compare (pure Foundation, no
# networking). deccli2.m: exact no-handler division 1/4->"0.25" + 10/2->"5",
# power-of-10 19.99*10^2->"1999", compare 3.33<3.34 -> -1. KNOWN GAP (non-gating, like
# M17 ICU / M28 grouping): NSDecimalNumberHandler-controlled ROUNDING is broken under
# emulation — a first probe used decimalNumberByDividingBy:withBehavior: (plain
# rounding, scale 2) and the guest IGNORED the scale (10/3 -> "3.33333" not "3.33")
# and misinterpreted the handler arg (1/8 -> "0.0922337" not "0.13"). Reworked to gate
# on the working paths + surface M53-HANDLER-GAP-norounding. Workaround: scale by
# powers of 10 (the POW path works). Selectors pre-vetted (M22); CF by-path (M17).
# Installed at /usr/bin/deccli2. VERIFIED M53/S96 (live): M53-DIV4-0.25 / M53-DIV2-5 /
# M53-POW-1999 / M53-CMP--1 / M53-HANDLER-GAP-norounding / M53-DONE — gating facets a
# full clean pass; handler-rounding a documented gap. Run:
# BW64_SHELLSPAWN=/usr/bin/deccli2 bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-deccli2.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-deccli2.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/deccli2" ]; then
            echo "--- M53/S96: staged deccli2 at usr/bin/deccli2 ---"
        fi
    else
        echo "WARNING: deccli2 build failed; not staged." >&2
    fi
fi

# --- M54 (S97): blkcli — Obj-C BLOCKS through Foundation block-based APIs ---------
# Proves the Obj-C BLOCK/CLOSURE runtime works on the substrate (pure Foundation + the
# block runtime, no networking) — a distinct runtime feature underpinning modern Cocoa
# block APIs. blkcli.m: sortedArrayUsingComparator: (descending block), indexOfObject
# PassingTest: (predicate block), enumerateObjectsUsingBlock: (__block accumulator),
# enumerateKeysAndObjectsUsingBlock: (dict block). The block runtime symbols
# (__NSConcreteStackBlock/__NSConcreteGlobalBlock, Block_copy/release) are defined in
# libsystem_blocks.dylib + re-exported by libSystem, so blocks link+run. Selectors
# pre-vetted (M22); CF by-path (M17). Installed at /usr/bin/blkcli. VERIFIED M54/S97
# (live, matches host exactly): M54-SORT-3,2,1 / M54-FINDIDX-1 / M54-SUM-6 /
# M54-DICTSUM-42 / M54-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/blkcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-blkcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-blkcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/blkcli" ]; then
            echo "--- M54/S97: staged blkcli at usr/bin/blkcli ---"
        fi
    else
        echo "WARNING: blkcli build failed; not staged." >&2
    fi
fi

# --- M55 (S98): gcdcli — Grand Central Dispatch (libdispatch) C API --------------
# A major Darwin concurrency subsystem (builds on M54's block runtime; distinct from
# M36's NSRunLoop): dispatch a block to a queue + semaphore handoff, serial
# dispatch_sync, and parallel dispatch_apply. gcdcli.m: dispatch_async to a concurrent
# queue sets a value + signals a semaphore the main thread waits on (ASYNC-42),
# dispatch_sync on a serial queue (SYNC-OK), dispatch_apply(5) summing indices guarded
# by a serial queue (APPLY-10). libdispatch is staged + re-exported by libSystem; the
# block runtime is libsystem_blocks (M54). Symbols pre-vetted exported (M22); CF
# by-path (M17). Installed at /usr/bin/gcdcli. VERIFIED M55/S98 (live, matches host
# exactly): M55-ASYNC-42 / M55-ASYNC-OK / M55-SYNC-OK / M55-APPLY-10 / M55-DONE — a
# full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/gcdcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-gcdcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-gcdcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/gcdcli" ]; then
            echo "--- M55/S98: staged gcdcli at usr/bin/gcdcli ---"
        fi
    else
        echo "WARNING: gcdcli build failed; not staged." >&2
    fi
fi

# --- M56 (S99): gcd2cli — GCD coordination primitives (group/after/barrier) -------
# Deepens M55's GCD proof to the COORDINATION patterns concurrent code uses (pure C
# dispatch + blocks, no networking): dispatch_group fan-out 4 tasks + dispatch_group_
# wait (GROUP-4), dispatch_after deferred ~50ms block + semaphore (AFTER-OK),
# dispatch_barrier_sync exclusive write on a concurrent queue (BARRIER-OK). libdispatch
# staged + re-exported by libSystem (M55); dispatch C API via <dispatch/dispatch.h>.
# Symbols pre-vetted exported (M22); CF by-path (M17). Installed at /usr/bin/gcd2cli.
# VERIFIED M56/S99 (live, matches host exactly): M56-GROUP-4 / M56-GROUP-OK /
# M56-AFTER-OK / M56-BARRIER-OK / M56-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/gcd2cli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-gcd2cli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-gcd2cli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/gcd2cli" ]; then
            echo "--- M56/S99: staged gcd2cli at usr/bin/gcd2cli ---"
        fi
    else
        echo "WARNING: gcd2cli build failed; not staged." >&2
    fi
fi

# --- M57 (S100): parcli — CONCURRENCY SYNTHESIS (JSON -> parallel map -> HMAC) ----
# The first synthesis exercising the GCD tier: a "parallel-process -> aggregate ->
# sign" pipeline composing NSJSONSerialization (M7) -> dispatch_apply parallel map
# (M55) + dispatch_barrier_sync guarded accumulate (M56) -> HMAC-SHA256 (M20), proving
# GCD concurrency interoperates with the data + crypto tiers. parcli.m parses JSON
# {score} records, processes them CONCURRENTLY (square each + sum under a barrier on a
# concurrent queue), then HMAC-SHA256s the decimal sum string (fixed key) verified vs
# the authoritative host hex. Links Foundation + CoreFoundation (M17) + libcrypto.44
# (M20) by path; libdispatch + block runtime via libSystem re-exports. Symbols
# pre-vetted (M22). Installed at /usr/bin/parcli. VERIFIED M57/S100 (live, matches host
# exactly): M57-PARSE-4 / M57-SUM-3000 / M57-SUM-OK / M57-HMAC-OK / M57-DONE — a full
# clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/parcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-parcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-parcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/parcli" ]; then
            echo "--- M57/S100: staged parcli at usr/bin/parcli ---"
        fi
    else
        echo "WARNING: parcli build failed; not staged." >&2
    fi
fi

# --- M58 (S101): kvccli — Key-Value Coding (KVC) + block-based NSPredicate --------
# KVC is a core Cocoa mechanism (backbone of bindings/Core Data/AppKit), pure
# Foundation + the block runtime (M54), no networking. kvccli.m: valueForKey:"name"
# (KEY-beta), nested valueForKeyPath:"inner.x" (KEYPATH-7), KVC collection operators
# @sum/@avg/@max.score over an array of dicts (SUM-90/AVG-30/MAX-50), and
# predicateWithBlock: score>25 (BLOCKPRED-2). Selectors pre-vetted (M22); NSArray/
# NSDictionary CF-resident so build-kvccli.sh links CoreFoundation BY PATH (M17); block
# runtime via libSystem (M54). Installed at /usr/bin/kvccli. VERIFIED M58/S101 (live,
# matches host exactly): M58-KEY-beta / M58-KEYPATH-7 / M58-SUM-90 / M58-AVG-30 /
# M58-MAX-50 / M58-BLOCKPRED-2 / M58-DONE — a full clean pass (no gaps). Run:
# BW64_SHELLSPAWN=/usr/bin/kvccli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-kvccli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-kvccli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/kvccli" ]; then
            echo "--- M58/S101: staged kvccli at usr/bin/kvccli ---"
        fi
    else
        echo "WARNING: kvccli build failed; not staged." >&2
    fi
fi

# --- M59 (S103): dsrccli — GCD dispatch_source event sources (timer + data) -------
# Extends the GCD tier (M55 queues/apply, M56 group/after/barrier) to dispatch_source,
# the libdispatch event-source primitive. Pure C dispatch API + blocks (M54); no net.
# libdispatch staged + re-exported by libSystem (M55); CoreFoundation BY PATH (M17);
# symbols pre-vetted (M22). dsrccli.m: create a TIMER source + a DATA_ADD source,
# deliver handlers, coalesce merge_data 5+7+30 -> get_data 42, and run a cancel handler.
# Installed at /usr/bin/dsrccli. VERIFIED M59/S103 (live) on the GATING facets:
# M59-SOURCE-OK (create + handler delivery) / M59-DATA-42 / M59-DATA-OK (coalescing) /
# M59-CANCEL-OK / M59-DONE. KNOWN GUEST GAP (non-gating, same class as M36's repeating
# NSTimer): a DISPATCH_SOURCE_TYPE_TIMER fires ONCE and does not re-arm — macOS
# kqueue/EVFILT_TIMER is serviced via Darling libkqueue over Mach traps and the
# periodic rearm isn't driven by the substrate (M59-TIMER-GAP-fireonce); a deep
# multi-session libkqueue fix. Run:
# BW64_SHELLSPAWN=/usr/bin/dsrccli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-dsrccli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-dsrccli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/dsrccli" ]; then
            echo "--- M59/S103: staged dsrccli at usr/bin/dsrccli ---"
        fi
    else
        echo "WARNING: dsrccli build failed; not staged." >&2
    fi
fi

# --- M60 (S104): cfsetcli — CFSet + CFBag via the CoreFoundation C API ------------
# Extends the CF C-layer (M44 CFUUID/CFString, M45 CFArray/CFDictionary/CFNumber,
# M46 CFData) to the SET + MULTISET container types — the pure-C counterparts to
# M34's NSSet and M26's NSCountedSet. PURE-C probe (no #import) per the M44 trick;
# symbols + callback structs (kCFTypeSetCallBacks/kCFTypeBagCallBacks) pre-vetted
# (M22); CoreFoundation BY PATH (M17). cfsetcli.m: CFSet dedup {alpha,beta,gamma,beta}
# -> 3 + CFSetContainsValue, CFMutableSet add2/remove1 -> 1, CFBag {a,a,a,b,b,c} ->
# total 6 with CFBagGetCountOfValue a=3/c=1. Installed at /usr/bin/cfsetcli. VERIFIED
# M60/S104 (live, matches host): M60-SETCOUNT-3 / M60-SETHAS-1 / M60-SETNO-0 /
# M60-MUTSET-1 / M60-BAGTOTAL-6 / M60-BAGA-3 / M60-BAGC-1 / M60-DONE — full clean pass.
# Run: BW64_SHELLSPAWN=/usr/bin/cfsetcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-cfsetcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-cfsetcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/cfsetcli" ]; then
            echo "--- M60/S104: staged cfsetcli at usr/bin/cfsetcli ---"
        fi
    else
        echo "WARNING: cfsetcli build failed; not staged." >&2
    fi
fi

# --- M61 (S105): opqcli — NSOperationQueue + NSBlockOperation ---------------------
# The higher-level Cocoa concurrency abstraction ABOVE GCD (M55-M57): an operation
# queue schedules NSOperation objects honoring inter-operation DEPENDENCIES and a
# max-concurrency cap, blocking until all finish. Pure Foundation (M3) + block runtime
# (M54); no net. Selectors + classes pre-vetted (M22); CoreFoundation BY PATH (M17).
# opqcli.m: serial queue (maxConcurrent 1) runs 3 addOperationWithBlock: ops (RAN-3);
# dependency graph opA->opB->opC forces order CBA despite reverse add-order (ORDER-CBA);
# a directly-started NSBlockOperation runs its block (BLOCKOP-OK). Installed at
# /usr/bin/opqcli. VERIFIED M61/S105 (live, matches host): M61-RAN-3 / M61-ORDER-CBA /
# M61-BLOCKOP-OK / M61-DONE — full clean pass, NSOperation dependency resolution works.
# Run: BW64_SHELLSPAWN=/usr/bin/opqcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-opqcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-opqcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/opqcli" ]; then
            echo "--- M61/S105: staged opqcli at usr/bin/opqcli ---"
        fi
    else
        echo "WARNING: opqcli build failed; not staged." >&2
    fi
fi

# --- M62 (S106): cachecli — NSCache in-memory key/value cache --------------------
# NSCache is Foundation's thread-safe, auto-evicting object cache (the store behind
# image/data caches in real apps), distinct from NSDictionary in its cache semantics
# (cost accounting, eviction). Pure Foundation (M3); no net. Selectors pre-vetted
# (M22) — NOTE setCountLimit:/countLimit are ABSENT in this Cocotron Foundation, so
# cachecli.m uses only the present selectors. CoreFoundation BY PATH (M17). cachecli.m:
# store 3 / read back (GET-beta), missing-key nil (MISS-1), setObject:forKey:cost:
# (COST-gamma), removeObjectForKey: (REMOVE-1) leaving others (REMAIN-beta),
# removeAllObjects (REMOVEALL-1). Installed at /usr/bin/cachecli. VERIFIED M62/S106
# (live, matches host): M62-GET-beta / M62-MISS-1 / M62-COST-gamma / M62-REMOVE-1 /
# M62-REMAIN-beta / M62-REMOVEALL-1 / M62-DONE — full clean pass. (NSXMLDocument was
# tried first for M62 but is a Darling Foundation STUB — initWithXMLString: logs
# "unimplemented" + returns nil, like CoreData M6; tree-XML is served by M18.) Run:
# BW64_SHELLSPAWN=/usr/bin/cachecli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-cachecli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-cachecli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/cachecli" ]; then
            echo "--- M62/S106: staged cachecli at usr/bin/cachecli ---"
        fi
    else
        echo "WARNING: cachecli build failed; not staged." >&2
    fi
fi

# --- M63 (S107): attrcli — NSAttributedString / NSMutableAttributedString ---------
# Styled/rich text: a string with per-character-range attribute dictionaries — the
# foundation of all rich text. Distinct from the plain-string tier (M29 processing,
# M47 formatting). Pure Foundation (M3) + block runtime (M54); no net. Selectors
# pre-vetted (M22); CoreFoundation BY PATH (M17). attrcli.m: build "Darwin Computa"
# with @"weight"=bold over [0,6) and thin over [7,14), read attributesAtIndex:
# effectiveRange:, extract a styled substring, enumerate attribute RUNS via a block.
# Installed at /usr/bin/attrcli. VERIFIED M63/S107 (live, matches host): M63-LEN-14 /
# M63-ATTR0-bold / M63-RANGE0-6 / M63-ATTR7-thin / M63-SUB-Computa / M63-RUNS-3 (3 runs
# = bold / the unattributed space at index 6 / thin — correct enumeration semantics) /
# M63-DONE. (NSMeasurement was considered but its conversion API
# measurementByConvertingToUnit: is ABSENT.) Run:
# BW64_SHELLSPAWN=/usr/bin/attrcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-attrcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-attrcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/attrcli" ]; then
            echo "--- M63/S107: staged attrcli at usr/bin/attrcli ---"
        fi
    else
        echo "WARNING: attrcli build failed; not staged." >&2
    fi
fi

# --- M64 (S108): maptblcli — NSMapTable + NSHashTable (pointer collections) -------
# The configurable-ownership collections (NSMapTable = dict-like map, NSHashTable =
# set-like store, both supporting strong/weak ref policies) — lower-level cousins of
# NSDictionary/NSSet for caches/observer-registries/object-graphs. Distinct from the
# collections tier (M24/M26/M34/M45/M60). Pure Foundation (M3); no net. Selectors
# pre-vetted (M22); CoreFoundation BY PATH (M17). maptblcli.m: NSMapTable strongToStrong
# set3/get/count/remove/miss; NSHashTable add{x,y,z,y}/contains. Installed at
# /usr/bin/maptblcli. VERIFIED M64/S108 (live, matches host): M64-MAPGET-beta /
# M64-MAPCOUNT-3 / M64-MAPREMOVE-2 / M64-MAPMISS-1 / M64-HASHCOUNT-3 / M64-HASHHAS-1 /
# M64-HASHNO-0 / M64-DONE — full clean pass. (M64 first tried NSLinguisticTagger [STUB,
# 0 tokens] and rejected NSDateInterval/NSDateComponentsFormatter/NSLengthFormatter at
# pre-vet — format selectors ABSENT.) Run:
# BW64_SHELLSPAWN=/usr/bin/maptblcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-maptblcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-maptblcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/maptblcli" ]; then
            echo "--- M64/S108: staged maptblcli at usr/bin/maptblcli ---"
        fi
    else
        echo "WARNING: maptblcli build failed; not staged." >&2
    fi
fi

# --- M7 (S50): jsoncli — JSON parse + serialize via NSJSONSerialization --------
# A Foundation data-tier capability on the proven Foundation/ObjC runtime.
# jsoncli.m parses a JSON doc, reads typed values (string/number/nested array),
# then re-serializes the graph and re-parses it (lossless round-trip). Installed at
# /usr/bin/jsoncli. VERIFIED M7/S50 (live): M7-PARSE-OK / M7-STR-DARWIN / M7-NUM-42
# / M7-ARRAY-3 / M7-NESTED-7 / M7-SERIALIZE-66 / M7-ROUNDTRIP-OK / M7-DONE. Run:
# BW64_SHELLSPAWN=/usr/bin/jsoncli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-jsoncli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-jsoncli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/jsoncli" ]; then
            echo "--- M7/S50: staged jsoncli at usr/bin/jsoncli ---"
        fi
    else
        echo "WARNING: jsoncli build failed; not staged." >&2
    fi
fi

# --- M8 (S51): xmlcli — event-driven XML parsing via NSXMLParser ---------------
# A second Foundation data format (distinct from JSON), exercising the SAX
# delegate chain. xmlcli.m parses an XML doc with a delegate that counts elements,
# reads an attribute, and accumulates element text (didStartElement /
# foundCharacters / didEndElement). Installed at /usr/bin/xmlcli. VERIFIED M8/S51
# (live): M8-PARSE-OK / M8-ELEMENTS-3 / M8-ATTR-42 / M8-TEXT-DARWIN / M8-DONE. Run:
# BW64_SHELLSPAWN=/usr/bin/xmlcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-xmlcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-xmlcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/xmlcli" ]; then
            echo "--- M8/S51: staged xmlcli at usr/bin/xmlcli ---"
        fi
    else
        echo "WARNING: xmlcli build failed; not staged." >&2
    fi
fi

# --- M9 (S52): regexcli — regular expressions via NSRegularExpression ----------
# Text-processing capability on the proven Foundation runtime (the ICU regex
# engine in-guest). regexcli.m compiles a pattern, counts matches, extracts a
# CAPTURE GROUP, and does a template REPLACE-ALL (with exact-output check).
# Installed at /usr/bin/regexcli. VERIFIED M9/S52 (live): M9-COMPILE-OK /
# M9-COUNT-4 / M9-CAPTURE-42 / M9-REPLACE-OK / M9-DONE. Run:
# BW64_SHELLSPAWN=/usr/bin/regexcli bash tools/run_darling_cli.sh /usr/bin/darlingserver.
if [ -f "$APP_SRC/build-regexcli.sh" ] && command -v clang >/dev/null 2>&1; then
    if bash "$APP_SRC/build-regexcli.sh" >/dev/null 2>&1; then
        if [ -f "$STAGEHOST/dist/stage/usr/libexec/darling/usr/bin/regexcli" ]; then
            echo "--- M9/S52: staged regexcli at usr/bin/regexcli ---"
        fi
    else
        echo "WARNING: regexcli build failed; not staged." >&2
    fi
fi

# --- S37: X11 locale/compose data (libx11-data) ------------------------------
# Cocotron's AppKit translates KeyPress -> NSEvent characters via XIM
# (Xutf8LookupString on a per-window XIC). libX11's XOpenIM needs
# /usr/share/X11/locale/{locale.dir,compose.dir,<locale>/...}; without them XIM
# init fails and typed keys carry NO characters (typing is dead even though
# KeyDown events arrive). Bare Linux path — the native-bridge libX11 resolves
# bare paths, not vchroot-prefixed ones (same rule as the S31 fontconfig fix).
X11DATA_DEB="https://ftp.debian.org/debian/pool/main/libx/libx11/libx11-data_1.8.4-2+deb12u2_all.deb"
if [ ! -d "$STAGEHOST/usr/share/X11/locale" ]; then
    X11TMP="$(mktemp -d)"
    if curl -sL -o "$X11TMP/d.deb" "$X11DATA_DEB" && (cd "$X11TMP" && ar x d.deb && tar xf data.tar.xz); then
        mkdir -p "$STAGEHOST/usr/share/X11"
        cp -R "$X11TMP/usr/share/X11/locale" "$STAGEHOST/usr/share/X11/locale"
        echo "--- S37: staged /usr/share/X11/locale (XIM/compose data for typing) ---"
    else
        echo "WARNING: libx11-data fetch failed; AppKit typing will produce no characters." >&2
    fi
    rm -rf "$X11TMP"
fi

# --- S36: replace Mesa libGL/libEGL with the gl64 trap shims -----------------
# Darling's AppKit window present path is CGL -> EGL -> Linux libEGL/libGL
# (QuartzCore CAWindowOpenGLContext renderSurface: + CGLFlushDrawable). Mesa's
# software EGL needs DRI drivers (swrast = LLVM under emulation) and can never
# initialize here — akwin died with 'CGL error 10004'. The trap shims
# (tools/rootfs64/libgl64 + libegl64) forward every gl*/egl* call to the host
# gl64 bridge, which renders on the host GPU and presents through the X11-wire
# sink. Staged OVER the Mesa copies at both lib roots (S29 staged those only to
# satisfy the native-bridge dlopen closure).
RF64="$(cd "$(dirname "$0")/.." && pwd)/rootfs64"
bash "$RF64/build-libgl64.sh"  >/dev/null 2>&1 || true
bash "$RF64/build-libegl64.sh" >/dev/null 2>&1 || true
if [ -f "$RF64/libgl64/libGL.so.1" ] && [ -f "$RF64/libegl64/libEGL.so.1" ]; then
    for base in "$STAGEHOST/lib/x86_64-linux-gnu" "$STAGEHOST/usr/lib/x86_64-linux-gnu"; do
        [ -d "$base" ] || continue
        cp "$RF64/libgl64/libGL.so.1"  "$base/libGL.so.1"
        cp "$RF64/libegl64/libEGL.so.1" "$base/libEGL.so.1"
    done
    echo "--- S36: staged gl64 trap libGL.so.1 + libEGL.so.1 over Mesa (both lib roots) ---"
else
    echo "WARNING: gl64 trap shims missing; Mesa libGL/libEGL left in place (no GUI pixels)." >&2
fi

echo "=== zipping on host (preserves symlinks) ==="
rm -f "$DIST/glibc-rootfs64.zip" "$DIST/darling.zip"
# Base: glibc + Linux deps. Overlay: mldr + the Darwin prefix.
( cd "$STAGEHOST" && zip -qry9 "$DIST/glibc-rootfs64.zip" lib64 lib etc tmp var run 2>/dev/null || true )
( cd "$STAGEHOST" && zip -qry9 "$DIST/darling.zip" usr darling-prefix home 2>/dev/null || true )
echo "=== zip sizes ==="
ls -lh "$DIST"/*.zip 2>/dev/null || echo "(no zips produced — check staging output above)"
echo "=== done. zips in $DIST ==="
echo "Run:  tools/run_darling_cli.sh /usr/bin/sw_vers"
