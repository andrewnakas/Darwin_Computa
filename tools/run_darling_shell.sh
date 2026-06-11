#!/bin/bash
# run_darling_shell.sh — M2: a REAL bash shell program running under Darwin_Computa.
#
# Boots the full Darling substrate and shellspawn-execs /bin/bash to run a
# multi-statement shell program, capturing its stdout. This is a genuine Darwin
# bash process: it parses and executes a real script, does integer arithmetic,
# carries variable state across statements, runs a command substitution that
# FORKS a subshell, and reports the working directory set via CHDIR — all proven
# live on the emulated substrate.
#
# The program is delivered with `bash -c '<program>'` over the shellspawn argv
# path (BW64_SPAWN_ARGS, '\x1f'-separated argv elements). This is the proven,
# reproducible path: stdout capture, arithmetic, variable state, $(...) fork, and
# the getcwd/CHDIR fix are ALL exercised and verified. (An experimental
# host->child socket-stdin feeder also exists — BW64_STDIN_SCRIPT — but bash does
# not reliably read commands from the STREAM-socket stdin; see the memory notes.
# Set BW64_SHELL_STDIN=1 below to try that path instead.)
#
# The mechanism (see source/shellspawn/shellspawnclient.cpp): BW64_SHELLSPAWN runs
# bash as a launchd child; BW64_SPAWN_ARGS adds `-c` + the program string as argv;
# BW64_SPAWN_CWD issues a shellspawn CHDIR before exec. bash's stdout/stderr are
# captured over host pipes and logged as ShellSpawn[out]: / ShellSpawn[err]: ...
#
# Usage:
#   tools/run_darling_shell.sh [/guest/path/to/shell]
#     default shell: /bin/bash
#
# What to expect (boot ~3-8 min behind the DARWIN COMPUTA loading screen):
#   ShellSpawn[out]: M2-READY-42                  <- echo + arithmetic $((6*7))
#   ShellSpawn[out]: M2-COUNTER-111               <- variable state across statements
#   ShellSpawn[out]: M2-PWD-/var/root             <- $(pwd) command substitution (FORK)
#   ShellSpawn[out]: M2-DONE
# (A trailing "waitpid: No child processes" / exit 70 is a benign post-exit reap
#  race in the shellspawn parent; bash itself exit_group(0) — the program ran.)
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

SHELL_BIN="${1:-/bin/bash}"
NAME="$(basename "$SHELL_BIN")"

# The shell PROGRAM. The COUNTER lines are the load-bearing state proof: 100 is
# set, +11'd, and echoed -> M2-COUNTER-111 only if a single bash process retained
# variable state across statements. The $(pwd) proves a forked subshell works and
# the CHDIR took effect. All builtins+fork, no external binaries needed.
PROGRAM='echo M2-READY-$((6*7)); COUNTER=100; COUNTER=$((COUNTER+11)); echo M2-COUNTER-$COUNTER; echo M2-PWD-$(pwd); echo M2-DONE'

echo "=== Darwin_Computa M2: bash program on $SHELL_BIN ==="
echo "    booting substrate, then running a multi-statement shell program"
echo "    (boot ~3-8 min; watch the log for ShellSpawn[out]: lines)"

# PWD/HOME let bash skip a redundant getcwd-on-startup walk; CHDIR (BW64_SPAWN_CWD,
# default /var/root) sets the actual cwd, which $(pwd) reads back. The getcwd
# kernel fix (readlink /proc/self/cwd) is what makes bash boot clean here.
if [ "${BW64_SHELL_STDIN:-0}" = "1" ]; then
    # Experimental: feed the program over socket stdin instead of `bash -c`.
    SCRIPT='echo M2-READY-$((6*7))\nCOUNTER=100\nCOUNTER=$((COUNTER+11))\necho M2-COUNTER-$COUNTER\necho M2-PWD-$(pwd)\necho M2-DONE\nexit'
    exec env \
        BW64_SHELLSPAWN="$SHELL_BIN" \
        BW64_STDIN_SCRIPT="$SCRIPT" \
        BW64_SPAWN_CWD="/var/root" \
        BW64_SPAWN_ENV="PWD=/var/root;HOME=/var/root" \
        BW64_CANCELEXIT="$NAME,securityd" \
        bash "$ROOT_DIR/tools/run_darling_cli.sh" /usr/bin/darlingserver
fi

# Proven path: bash -c '<program>'. '\x1f' separates the two argv elements so the
# program string keeps its spaces/semicolons intact.
ARGS=$'-c\x1f'"$PROGRAM"
exec env \
    BW64_SHELLSPAWN="$SHELL_BIN" \
    BW64_SPAWN_ARGS="$ARGS" \
    BW64_SPAWN_CWD="/var/root" \
    BW64_SPAWN_ENV="PWD=/var/root;HOME=/var/root" \
    BW64_CANCELEXIT="$NAME,securityd" \
    bash "$ROOT_DIR/tools/run_darling_cli.sh" /usr/bin/darlingserver
