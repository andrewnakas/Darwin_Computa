#!/bin/bash
# run_darling_app.sh — run a macOS (Mach-O) CLI app under emulated Darling and
# show its output like a terminal. This is the "hello world" demo path: instead
# of waiting for launchd to bootstrap services, we tell darlingserver to exec the
# app DIRECTLY as its container init process (DSERVER_INIT), so the app runs
# through the full mldr -> dyld -> libSystem -> darlingserver checkin pipeline and
# prints to stdout. (See setupDarwinRun in source/sdl/main.cpp, which forwards
# DSERVER_INIT, and darlingserver's spawnLaunchd which reads it.)
#
# Usage:
#   tools/run_darling_app.sh [/guest/path/to/app] [--raw] [--window]
#     default app: /usr/bin/sw_vers
#     --raw     : show the full emulator/darlingserver log (debugging)
#     --window  : open the demo in a new macOS Terminal.app window
#
# Examples:
#   tools/run_darling_app.sh                      # sw_vers
#   tools/run_darling_app.sh /usr/bin/uname
#   tools/run_darling_app.sh /bin/echo            # (echo with no args -> blank line)
#   tools/run_darling_app.sh /usr/bin/sw_vers --window
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

APP="/usr/bin/sw_vers"
RAW=0
WINDOW=0
for a in "$@"; do
    case "$a" in
        --raw)    RAW=1 ;;
        --window) WINDOW=1 ;;
        /*)       APP="$a" ;;
        *)        echo "ignoring unknown arg: $a" >&2 ;;
    esac
done

# --window: relaunch ourselves inside a new Terminal.app window so the demo is
# visible as a GUI terminal, then exit.
if [ "$WINDOW" = "1" ]; then
    SELF="$ROOT_DIR/tools/run_darling_app.sh"
    osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
    activate
    do script "clear; echo 'Darwin_Computa — running $APP under emulated macOS...'; '$SELF' '$APP'"
end tell
OSA
    echo "Opened a Terminal window running $APP."
    exit 0
fi

LOG="$(mktemp -t darwin_app).log"
trap 'pkill -9 -f "darwin-run" 2>/dev/null; rm -f "$LOG"' EXIT

echo "=== Darwin_Computa: running $APP under emulated macOS (Darling) ==="
echo "    (booting darlingserver + mldr + dyld; first run takes ~60-90s)"
echo

# DSERVER_INIT makes darlingserver exec the app instead of /sbin/launchd.
DSERVER_INIT="$APP" BW64_DSLOG=1 \
    bash "$ROOT_DIR/tools/run_darling_cli.sh" /usr/bin/darlingserver >"$LOG" 2>&1 &
EMU=$!

# Wait until the app has run (it writes stdout) or exits, or we time out.
for i in $(seq 1 60); do
    if grep -q "exit_group syscall, status=.* pid=26" "$LOG" 2>/dev/null; then break; fi
    if ! kill -0 "$EMU" 2>/dev/null; then break; fi
    sleep 2
done

if [ "$RAW" = "1" ]; then
    cat "$LOG"
else
    # The app's stdout/stderr is teed by the kernel as "[guest fd=N pid=M name] ...".
    # Strip the prefix to present it like a normal terminal. fd=1 is stdout,
    # fd=2 is stderr.
    echo "----- $APP output -----"
    grep -E "^\[guest fd=[12] pid=26 " "$LOG" \
        | sed -E 's/^\[guest fd=[12] pid=26 [^]]*\] //' || true
    echo "-----------------------"
    if grep -q "exit_group syscall, status=0  pid=26" "$LOG"; then
        echo "(app exited 0 — clean run)"
    else
        st=$(grep -oE "exit_group syscall, status=[0-9-]+  pid=26" "$LOG" | head -1)
        echo "(app finished: ${st:-still running / no clean exit seen — try --raw})"
    fi
fi
