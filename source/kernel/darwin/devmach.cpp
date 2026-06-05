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

#include "../../io/fsvirtualopennode.h"
#include "machtraps.h"
#include "devmach.h"
#include "cpu64.h"
#include "kmemory64.h"
#include "kprocess.h"

#include <stdio.h>
#include <stdlib.h>

// /dev/mach — the emulated Darling kernel ("XNU-in-a-fake-Linux") interface.
//
// Darling's userspace (libsystem_kernel) does open("/dev/mach") then issues
// every Mach / psynch / kqueue trap as ioctl(fd, DARLING_MACH_API_BASE + trap,
// paramv). The real Darling LKM dispatches those through mach_traps[]. Here we
// answer them in software, against the 64-bit guest memory (KMemory64), so no
// real Linux kernel module is needed — see machtraps.h for the ABI.
//
// Phase B scope: the device opens, the kernel handshake completes
// (get_api_version + mach_reply_port + a few self-traps), and every trap is
// traced (BW64_DEVMACHTRACE=1) so the discovery loop can see what dyld/libSystem
// reaches next. Mach IPC (mach_msg) and psynch fidelity are Phase C/D.

class DevMach : public FsVirtualOpenNode {
public:
    DevMach(const std::shared_ptr<FsNode>& node, U32 flags) : FsVirtualOpenNode(node, flags) {}

    // Darling never read()/write()s /dev/mach — all traffic is ioctl. Keep these
    // well-defined no-ops so a stray read/write fails the Darwin way (0 bytes),
    // not with an emulator assert.
    U32 readNative(U8* buffer, U32 len) override { return 0; }
    U32 writeNative(U8* buffer, U32 len) override { return 0; }

    // The legacy 32-bit ioctl entry point is never used for /dev/mach (Darling is
    // 64-bit only and the trap arg is a 64-bit guest pointer). The 64-bit ioctl
    // dispatcher in syscall64.cpp detects a DevMach and calls mach_ioctl()
    // directly with the CPU64 + paramv pointer instead. Refuse the 32-bit path.
    U32 ioctl(KThread* thread, U32 request) override { return -K_ENODEV; }

    // The real entry point: ioctl(fd, DARLING_MACH_API_BASE + trap, paramv).
    // Returns the value the guest's ioctl() should see (0 / positive on success,
    // a negative Linux errno on failure — Darling's userspace reads it the same
    // way it reads a real ioctl return).
    S64 mach_ioctl(CPU64* cpu, U64 request, U64 paramv);
};

// ---- trap-name table (for the trace) -------------------------------------

const char* darwinMachTrapName(U64 trapNum) {
    switch ((DarlingMachTrap)trapNum) {
        case NR_get_api_version: return "get_api_version";
        case NR_mach_reply_port: return "mach_reply_port";
        case NR__kernelrpc_mach_port_mod_refs: return "mach_port_mod_refs";
        case NR_task_self_trap: return "task_self_trap";
        case NR_host_self_trap: return "host_self_trap";
        case NR__kernelrpc_mach_port_allocate: return "mach_port_allocate";
        case NR_mach_msg_overwrite_trap: return "mach_msg_overwrite_trap";
        case NR__kernelrpc_mach_port_deallocate: return "mach_port_deallocate";
        case NR__kernelrpc_mach_port_destroy: return "mach_port_destroy";
        case NR_semaphore_signal_trap: return "semaphore_signal";
        case NR_semaphore_signal_all_trap: return "semaphore_signal_all";
        case NR_semaphore_wait_trap: return "semaphore_wait";
        case NR_semaphore_wait_signal_trap: return "semaphore_wait_signal";
        case NR_semaphore_timedwait_signal_trap: return "semaphore_timedwait_signal";
        case NR_semaphore_timedwait_trap: return "semaphore_timedwait";
        case NR_bsd_ioctl_trap: return "bsd_ioctl";
        case NR_thread_self_trap: return "thread_self_trap";
        case NR_bsdthread_terminate_trap: return "bsdthread_terminate";
        case NR_psynch_mutexwait_trap: return "psynch_mutexwait";
        case NR_psynch_mutexdrop_trap: return "psynch_mutexdrop";
        case NR_pthread_kill_trap: return "pthread_kill";
        case NR_psynch_cvwait_trap: return "psynch_cvwait";
        case NR_psynch_cvsignal_trap: return "psynch_cvsignal";
        case NR_psynch_cvbroad_trap: return "psynch_cvbroad";
        case NR_mk_timer_create_trap: return "mk_timer_create";
        case NR_mk_timer_arm_trap: return "mk_timer_arm";
        case NR_mk_timer_cancel_trap: return "mk_timer_cancel";
        case NR_mk_timer_destroy_trap: return "mk_timer_destroy";
        case NR__kernelrpc_mach_port_move_member_trap: return "mach_port_move_member";
        case NR__kernelrpc_mach_port_insert_member_trap: return "mach_port_insert_member";
        case NR__kernelrpc_mach_port_extract_member_trap: return "mach_port_extract_member";
        case NR_thread_death_announce: return "thread_death_announce";
        case NR__kernelrpc_mach_port_insert_right_trap: return "mach_port_insert_right";
        case NR_fork_wait_for_child: return "fork_wait_for_child";
        case NR_task_for_pid_trap: return "task_for_pid";
        case NR_pid_for_task_trap: return "pid_for_task";
        case NR_set_dyld_info: return "set_dyld_info";
        case NR_stop_after_exec: return "stop_after_exec";
        case NR_kernel_printk: return "kernel_printk";
        case NR_path_at: return "path_at";
        case NR_psynch_rw_rdlock: return "psynch_rw_rdlock";
        case NR_psynch_rw_wrlock: return "psynch_rw_wrlock";
        case NR_psynch_rw_unlock: return "psynch_rw_unlock";
        case NR_psynch_cvclrprepost: return "psynch_cvclrprepost";
        case NR_get_tracer: return "get_tracer";
        case NR_tid_for_thread: return "tid_for_thread";
        case NR_getuidgid: return "getuidgid";
        case NR_setuidgid: return "setuidgid";
        case NR_task_name_for_pid_trap: return "task_name_for_pid";
        case NR_set_tracer: return "set_tracer";
        case NR_pthread_markcancel: return "pthread_markcancel";
        case NR_pthread_canceled: return "pthread_canceled";
        case NR_pid_get_state: return "pid_get_state";
        case NR_started_suspended: return "started_suspended";
        case NR_task_64bit: return "task_64bit";
        case NR__kernelrpc_mach_vm_allocate_trap: return "mach_vm_allocate";
        case NR__kernelrpc_mach_vm_deallocate_trap: return "mach_vm_deallocate";
        case NR_last_triggered_watchpoint: return "last_triggered_watchpoint";
        case NR_vchroot: return "vchroot";
        case NR_vchroot_expand: return "vchroot_expand";
        case NR_vchroot_fdpath: return "vchroot_fdpath";
        case NR_handle_to_path: return "handle_to_path";
        case NR_fileport_makeport: return "fileport_makeport";
        case NR_fileport_makefd: return "fileport_makefd";
        case NR_sigprocess: return "sigprocess";
        case NR_ptrace_thupdate: return "ptrace_thupdate";
        case NR_ptrace_sigexc: return "ptrace_sigexc";
        case NR_thread_suspended: return "thread_suspended";
        case NR_set_thread_handles: return "set_thread_handles";
        case NR_thread_get_special_reply_port: return "thread_get_special_reply_port";
        case NR__kernelrpc_mach_port_request_notification_trap: return "mach_port_request_notification";
        case NR__kernelrpc_mach_port_type_trap: return "mach_port_type";
        case NR__kernelrpc_mach_port_get_attributes_trap: return "mach_port_get_attributes";
        case NR__kernelrpc_mach_port_construct_trap: return "mach_port_construct";
        case NR__kernelrpc_mach_port_destruct_trap: return "mach_port_destruct";
        case NR__kernelrpc_mach_port_guard_trap: return "mach_port_guard";
        case NR__kernelrpc_mach_port_unguard_trap: return "mach_port_unguard";
        case NR_kqueue_create: return "kqueue_create";
        case NR_kevent: return "kevent";
        case NR_kevent64: return "kevent64";
        case NR_kevent_qos: return "kevent_qos";
        case NR_closing_descriptor: return "closing_descriptor";
        default: return nullptr;
    }
}

// ---- well-known Mach port names (special ports) --------------------------
// XNU hands these fixed names back from the self-traps. dyld/libSystem only
// require that they are non-zero and stable per task, and that the matching
// deallocate/mod_refs accept them. We hand back the canonical XNU values.
static const U32 TASK_SELF_PORT   = 0x103;  // mach_task_self_
static const U32 HOST_SELF_PORT   = 0x203;
static const U32 THREAD_SELF_PORT = 0x303;
// mach_reply_port hands out a fresh receive right each call; we just need a
// monotonic, non-zero, per-process supply. Start above the special-port range.
static U32 g_nextReplyPort = 0x1000;

S64 DevMach::mach_ioctl(CPU64* cpu, U64 request, U64 paramv) {
    return darwinMachTrapDispatch(cpu, request, paramv);
}

// The trap dispatcher proper, as a free function so it can be unit-tested
// (--darwin-selftest) without standing up the FsOpenNode/VFS machinery.
S64 darwinMachTrapDispatch(CPU64* cpu, U64 request, U64 paramv) {
    U64 trap = request;   // ioctl request IS DARLING_MACH_API_BASE + trap_num
    static const bool trace = getenv("BW64_DEVMACHTRACE") != nullptr;

    const char* name = darwinMachTrapName(trap);
    if (trace) {
        if (name) {
            klog_fmt("DEVMACH trap %s (0x%llx) paramv=0x%llx",
                     name, (unsigned long long)trap, (unsigned long long)paramv);
        } else {
            klog_fmt("DEVMACH trap UNKNOWN 0x%llx paramv=0x%llx",
                     (unsigned long long)trap, (unsigned long long)paramv);
        }
    }

    switch ((DarlingMachTrap)trap) {
        // --- generic handshake -------------------------------------------
        case NR_get_api_version:
            // Darling's userspace checks this matches its compiled-in version
            // before doing anything else. Mismatch => it bails immediately.
            return DARLING_MACH_API_VERSION;

        // --- self / special ports (Phase B: stable non-zero names) --------
        case NR_task_self_trap:    return TASK_SELF_PORT;
        case NR_host_self_trap:    return HOST_SELF_PORT;
        case NR_thread_self_trap:  return THREAD_SELF_PORT;

        case NR_mach_reply_port:
            // Hand out a fresh, non-zero reply-port name. Real port semantics
            // (queues, rights) arrive in Phase C with mach_msg.
            return (S64)(g_nextReplyPort++);

        case NR_thread_get_special_reply_port:
            return (S64)(g_nextReplyPort++);

        // --- identity / creds (self only for now) ------------------------
        case NR_task_64bit:
            return 1;   // yes, the guest task is 64-bit
        case NR_getuidgid:
            // paramv -> { uid_t*, gid_t* } is filled by Phase C; for now report
            // success with the conventional Darling default (uid 0 / gid 0 in
            // the container). Returning 0 keeps libSystem moving.
            return 0;

        // --- traps that are safe to acknowledge as no-ops during bringup --
        case NR_set_dyld_info:        // dyld registers its all-image info ptr
        case NR_stop_after_exec:      // debugger hook; not stopping
        case NR_started_suspended:    // not suspended
        case NR_set_thread_handles:   // pthread/TSD self-registration
        case NR_set_tracer:
        case NR_kernel_printk:        // routed to klog below if it carries text
            return 0;

        default:
            // Everything else is not yet implemented. Trace it (always, not just
            // under BW64_DEVMACHTRACE) so the discovery loop sees the next gate,
            // and return -ENOSYS, which is how the real path reports an
            // unsupported trap. Phase C/D fill these in (mach_msg, psynch,
            // kqueue, vchroot, ...).
            klog_fmt("DEVMACH UNIMPLEMENTED trap %s (0x%llx) -> -ENOSYS",
                     name ? name : "?", (unsigned long long)trap);
            return -K_ENOSYS;
    }
}

FsOpenNode* openDevMach(const std::shared_ptr<FsNode>& node, U32 flags, U32 data) {
    return new DevMach(node, flags);
}

// Non-template dispatch shim called from syscall64.cpp's ioctl handler. Kept out
// of the header so syscall64.cpp doesn't need the full DevMach class definition;
// it only needs to know "is this open node a DevMach, and if so route here."
S64 devMachIoctl(FsOpenNode* openNode, CPU64* cpu, U64 request, U64 paramv) {
    DevMach* dev = dynamic_cast<DevMach*>(openNode);
    if (!dev) return (S64)-K_ENODEV;
    return dev->mach_ioctl(cpu, request, paramv);
}

#endif // BOXEDWINE_DARWIN
