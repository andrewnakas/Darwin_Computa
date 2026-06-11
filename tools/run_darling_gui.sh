#!/bin/bash
# run_darling_gui.sh — launch a macOS GUI app under Darwin_Computa (S36).
#
# Boots the full launchd substrate, then shellspawn-execs the GUI app as a
# launchd child (GUI apps need the booted path: a valid bootstrap port for the
# libinfo/notification lookups AppKit does during init — see the S32 finding).
# The app's NSWindow maps through AppKit's X11 backend onto the in-process X11
# wire server, its window content presents via the gl64 trap-GL/EGL bridge to
# the host SDL window, and host keyboard/mouse flow back in as X11 events.
#
# Usage:
#   tools/run_darling_gui.sh [/guest/path/to/app]
#     default app: /usr/bin/akrun   (the interactive red-window AppKit probe:
#                  logs 'akrun: event type=...' for every click/keypress)
#
# What to expect:
#   - boot takes ~3-8 minutes under the interpreter (progress bar in the window;
#     occasionally the boot stalls — Ctrl-C and retry)
#   - the app's window appears in the Boxedwine host window a minute or two
#     after boot ("XWire SDL: presented ..." in the log)
#   - click/type in the window; akrun logs each event it receives
#   - Ctrl-C here to quit (or close the host window)
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

APP="${1:-/usr/bin/akrun}"
NAME="$(basename "$APP")"

echo "=== Darwin_Computa GUI: booting substrate, then launching $APP ==="
echo "    (boot ~3-8 min; the app window appears in the Boxedwine window)"

exec env \
    BW64_SHELLSPAWN="$APP" \
    BW64_CANCELEXIT="$NAME,securityd" \
    bash "$ROOT_DIR/tools/run_darling_cli.sh" /usr/bin/darlingserver
