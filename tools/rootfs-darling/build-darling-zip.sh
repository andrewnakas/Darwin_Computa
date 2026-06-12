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
