#!/bin/bash
# run_darling_app_bundle.sh — launch a real macOS .app BUNDLE under Darwin_Computa
# (S38). The "open Foo.app" experience, minus the LaunchServices middleman.
#
# Why not /usr/bin/open?  Darling's open(1) calls _LSOpenURLsWithRole, which
# routes through LaunchServices + coreservicesd/launchd XPC — none of which is
# functional on our stripped substrate. So instead we resolve the bundle's
# executable (Contents/MacOS/<CFBundleExecutable>) and exec THAT directly through
# the proven shellspawn path (BW64_SHELLSPAWN). Because the kernel execs the real
# bundle binary, Darling's CoreFoundation still derives [NSBundle mainBundle] by
# walking the executable path up to the .app — so inside the app, mainBundle,
# Info.plist, and Resources/ all resolve correctly. That is a genuine bundle
# launch; only the Finder/open front-end is bypassed.
#
# Usage:
#   tools/run_darling_app_bundle.sh [/guest/path/to/Foo.app]
#     default: /Applications/DarwinComputa.app   (built by
#              tools/darwin-app/build-akapp.sh)
#
# What to expect: same as run_darling_gui.sh — boot ~3-8 min behind the DARWIN
# COMPUTA loading screen, then the app's window appears in the Boxedwine window.
# The app logs its own bundle evidence at startup:
#   akapp: bundlePath = .../Applications/DarwinComputa.app
#   akapp: CFBundleName = Darwin Computa
#   akapp: Welcome.txt body = "Hello from inside Darwin Computa. ..."
#   akapp: BUNDLE OK — mainBundle resolved to a .app
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

APP="${1:-/Applications/DarwinComputa.app}"

# The guest filesystem root where the bundle physically lives (overlay or zip),
# used only to read the Info.plist host-side so we can resolve the executable
# name. The overlay path mirrors the guest path under the darling prefix.
GUEST_ROOT="$HOME/Library/Application Support/Boxedwine/rootfs-darling/root/usr/libexec/darling"
HOST_APP="$GUEST_ROOT$APP"

if [ ! -d "$HOST_APP" ]; then
    echo "error: bundle not found at $HOST_APP" >&2
    echo "       build it first:  bash tools/darwin-app/build-akapp.sh" >&2
    exit 1
fi

# Resolve Contents/MacOS/<CFBundleExecutable> from the Info.plist. Fall back to
# the bundle's basename (the macOS convention when CFBundleExecutable is absent).
PLIST="$HOST_APP/Contents/Info.plist"
EXE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST" 2>/dev/null || true)"
if [ -z "$EXE" ]; then
    base="$(basename "$APP")"; EXE="${base%.app}"
fi

GUEST_EXEC="$APP/Contents/MacOS/$EXE"
if [ ! -x "$GUEST_ROOT$GUEST_EXEC" ]; then
    echo "error: bundle executable not found/executable: $GUEST_ROOT$GUEST_EXEC" >&2
    exit 1
fi

NAME="$(basename "$GUEST_EXEC")"

echo "=== Darwin_Computa: launching bundle $APP ==="
echo "    executable: $GUEST_EXEC"
echo "    (boot ~3-8 min; the app window appears in the Boxedwine window)"

exec env \
    BW64_SHELLSPAWN="$GUEST_EXEC" \
    BW64_CANCELEXIT="$NAME,securityd" \
    bash "$ROOT_DIR/tools/run_darling_cli.sh" /usr/bin/darlingserver
