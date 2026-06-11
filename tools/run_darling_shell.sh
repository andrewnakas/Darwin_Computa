#!/bin/bash
# run_darling_shell.sh — M2: an INTERACTIVE shell under Darwin_Computa.
#
# Boots the full Darling substrate, shellspawn-execs /bin/bash with a LIVE
# host->child stdin path, and "types" a scripted session at the running shell —
# line by line, with a pause between lines — so bash reads, parses, executes and
# prints each command incrementally. This is the real interactive read loop, not
# a one-shot exec: the script carries shell state across separately-typed lines
# (a variable set on one line is mutated on a later line), which is only possible
# if a single persistent bash process is reading our stdin command-by-command.
#
# The mechanism (see source/shellspawn/shellspawnclient.cpp): BW64_SHELLSPAWN
# runs bash as a launchd child; BW64_STDIN_SCRIPT (decoded: literal \n -> newline)
# is fed to bash's stdin via the kernel's host-pipe writeNative, then stdin is
# closed (EOF) so bash exits. Output appears in the log as ShellSpawn[out]: ...
#
# Usage:
#   tools/run_darling_shell.sh [/guest/path/to/shell]
#     default shell: /bin/bash
#
# What to expect (boot ~3-8 min behind the DARWIN COMPUTA loading screen):
#   ShellSpawn[in]:  echo M2-READY-$((6*7))      <- a line we typed
#   ShellSpawn[out]: M2-READY-42                 <- bash evaluated it live
#   ShellSpawn[out]: M2-COUNTER-111              <- state carried across lines
#   ShellSpawn[out]: M2-DONE
#   ShellSpawn: '/bin/bash' exited with code 0
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

SHELL_BIN="${1:-/bin/bash}"
NAME="$(basename "$SHELL_BIN")"

# The interactive session. Each line is "typed" at the shell ~0.6s apart. The
# COUNTER lines are the load-bearing proof: 100 is set on one typed line, +11'd
# on the next, and echoed on a third -> M2-COUNTER-111 only if a single bash
# process retained state across three separately-read lines (a live read loop).
SCRIPT='echo M2-READY-$((6*7))\nCOUNTER=100\nCOUNTER=$((COUNTER+11))\necho M2-COUNTER-$COUNTER\necho M2-PWD-is-$(pwd)\necho M2-DONE\nexit'

echo "=== Darwin_Computa M2: interactive $SHELL_BIN ==="
echo "    booting substrate, then typing a scripted session at the shell"
echo "    (boot ~3-8 min; watch the log for ShellSpawn[in]/[out] lines)"

# PWD/HOME let bash skip the getcwd-on-startup walk (Darling's libc walks ".."
# via openat/getdents, which trips over the vchroot root boundary and aborts
# with "shell-init: error retrieving current directory" exit 70). A real login
# shell always inherits PWD from its parent, so this is the normal path, not a
# workaround. CHDIR (BW64_SPAWN_CWD, default /var/root) sets the actual cwd.
exec env \
    BW64_SHELLSPAWN="$SHELL_BIN" \
    BW64_STDIN_SCRIPT="$SCRIPT" \
    BW64_SPAWN_CWD="/var/root" \
    BW64_SPAWN_ENV="PWD=/var/root;HOME=/var/root" \
    BW64_CANCELEXIT="$NAME,securityd" \
    bash "$ROOT_DIR/tools/run_darling_cli.sh" /usr/bin/darlingserver
