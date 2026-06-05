/*
 *  Copyright (C) 2012-2026  The BoxedWine Team
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#include "boxedwine.h"

#ifdef BOXEDWINE_DARWIN

#include "machtraps.h"
#include "kmemory64.h"
#include "cpu64.h"
#include "devmach.h"

#include <cstdio>

// --darwin-selftest: the Darwin/_dev/mach trap-layer smoke test. The CI-able
// counterpart to --x64-selftest for the emulated Darling kernel interface.
//
// Phase B asserts the kernel handshake: get_api_version returns the pinned
// version, the self-traps return stable non-zero port names, mach_reply_port
// hands out distinct non-zero names, and trap-name decoding works. These are the
// pieces dyld/libSystem touch before any Mach IPC, so locking them in keeps the
// handshake from silently regressing as Phase C/D grow the dispatcher.

static int g_pass = 0;
static int g_fail = 0;

static void check(bool cond, const char* what) {
    if (cond) {
        g_pass++;
        printf("  PASS: %s\n", what);
    } else {
        g_fail++;
        printf("  FAIL: %s\n", what);
    }
}

int runDarwinSelfTest() {
    printf("\n=== Darwin_Computa self-test (/dev/mach trap layer) ===\n");

    // A minimal CPU64/KMemory64 so the dispatcher runs exactly as it does for
    // the guest. The handshake traps return scalars and don't read paramv, so an
    // empty memory is fine here. We call the trap dispatcher directly (not via
    // the FsOpenNode device wrapper) so the test needs no VFS / FsNode.
    KMemory64 mem(nullptr);
    CPU64 cpu(&mem);

    auto trap = [&](U64 t, U64 paramv) -> S64 {
        return darwinMachTrapDispatch(&cpu, t, paramv);
    };

    // get_api_version must equal the version Darling's userspace expects, or it
    // bails before issuing any other trap.
    check(trap(NR_get_api_version, 0) == DARLING_MACH_API_VERSION,
          "get_api_version returns DARLING_MACH_API_VERSION");

    // Self / special ports: stable and non-zero.
    S64 taskPort   = trap(NR_task_self_trap, 0);
    S64 hostPort   = trap(NR_host_self_trap, 0);
    S64 threadPort = trap(NR_thread_self_trap, 0);
    check(taskPort > 0,   "task_self_trap returns a non-zero port");
    check(hostPort > 0,   "host_self_trap returns a non-zero port");
    check(threadPort > 0, "thread_self_trap returns a non-zero port");
    check(taskPort == trap(NR_task_self_trap, 0),
          "task_self_trap is stable across calls");
    check(taskPort != hostPort && hostPort != threadPort && taskPort != threadPort,
          "the three self ports are distinct");

    // mach_reply_port hands out fresh, distinct, non-zero names.
    S64 r1 = trap(NR_mach_reply_port, 0);
    S64 r2 = trap(NR_mach_reply_port, 0);
    check(r1 > 0 && r2 > 0, "mach_reply_port returns non-zero names");
    check(r1 != r2, "mach_reply_port hands out distinct names");

    // task_64bit: the guest task is 64-bit.
    check(trap(NR_task_64bit, 0) == 1, "task_64bit reports 64-bit");

    // An unimplemented trap reports -ENOSYS (the discovery-loop signal), not a
    // bogus success.
    check(trap(NR_kqueue_create, 0) == (S64)-K_ENOSYS,
          "unimplemented trap (kqueue_create) returns -ENOSYS");

    // Trap-name decoding (used by BW64_DEVMACHTRACE).
    check(darwinMachTrapName(NR_mach_msg_overwrite_trap) != nullptr,
          "trap-name table resolves a known trap");
    check(darwinMachTrapName(0x9999) == nullptr,
          "trap-name table returns null for an unknown trap");

    printf("=== darwin-selftest: %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

#endif // BOXEDWINE_DARWIN
