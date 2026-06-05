/*
 *  Copyright (C) 2012-2026  The BoxedWine Team
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef __DARWIN_MACHTRAPS_H__
#define __DARWIN_MACHTRAPS_H__

#ifdef BOXEDWINE_DARWIN

// Darling's macOS-kernel ABI, as exposed by its Linux kernel module (LKM):
// userspace opens /dev/mach and fires each Mach/BSD-extension "trap" as
//   ioctl(fd, DARLING_MACH_API_BASE + trap_num, paramv)
// where paramv is a guest pointer to the trap's packed argument struct. The LKM
// dispatches ioctl_num - DARLING_MACH_API_BASE through its mach_traps[] table.
//
// Darwin_Computa emulates that device in software (source/kernel/darwin/
// devmach.cpp) instead of needing a real Linux kernel module — same ABI,
// answered by the fake kernel. The numbers below are transcribed verbatim from
// darling-newlkm/darling/api.h (DARLING_MACH_API_VERSION 19) so the guest's
// libsystem_kernel talks to us exactly as it would to the real module.

#define DARLING_MACH_API_BASE     0x1000
#define DARLING_MACH_API_VERSION  19

enum DarlingMachTrap {
    NR_get_api_version                          = 0x1000,
    NR_mach_reply_port                          = 0x1001,
    NR__kernelrpc_mach_port_mod_refs            = 0x1002,
    NR_task_self_trap                           = 0x1003,
    NR_host_self_trap                           = 0x1004,
    NR__kernelrpc_mach_port_allocate            = 0x1005,
    NR_mach_msg_overwrite_trap                  = 0x1006,
    NR__kernelrpc_mach_port_deallocate          = 0x1007,
    NR__kernelrpc_mach_port_destroy             = 0x1008,
    NR_semaphore_signal_trap                    = 0x1009,
    NR_semaphore_signal_all_trap                = 0x100A,
    NR_semaphore_wait_trap                      = 0x100B,
    NR_semaphore_wait_signal_trap               = 0x100C,
    NR_semaphore_timedwait_signal_trap          = 0x100D,
    NR_semaphore_timedwait_trap                 = 0x100E,
    NR_bsd_ioctl_trap                           = 0x100F,
    NR_thread_self_trap                         = 0x1010,
    NR_bsdthread_terminate_trap                 = 0x1011,
    NR_psynch_mutexwait_trap                    = 0x1012,
    NR_psynch_mutexdrop_trap                    = 0x1013,
    NR_pthread_kill_trap                        = 0x1014,
    NR_psynch_cvwait_trap                       = 0x1015,
    NR_psynch_cvsignal_trap                     = 0x1016,
    NR_psynch_cvbroad_trap                      = 0x1017,
    NR_mk_timer_create_trap                     = 0x1018,
    NR_mk_timer_arm_trap                        = 0x1019,
    NR_mk_timer_cancel_trap                     = 0x101A,
    NR_mk_timer_destroy_trap                    = 0x101B,
    NR__kernelrpc_mach_port_move_member_trap    = 0x101C,
    NR__kernelrpc_mach_port_insert_member_trap  = 0x101D,
    NR__kernelrpc_mach_port_extract_member_trap = 0x101E,
    NR_thread_death_announce                     = 0x101F,
    NR__kernelrpc_mach_port_insert_right_trap    = 0x1020,
    NR_fork_wait_for_child                       = 0x1021,
    NR_task_for_pid_trap                         = 0x1022,
    NR_pid_for_task_trap                         = 0x1023,
    NR_set_dyld_info                             = 0x1024,
    NR_stop_after_exec                           = 0x1025,
    NR_kernel_printk                             = 0x1026,
    NR_path_at                                   = 0x1027,
    NR_psynch_rw_rdlock                          = 0x1028,
    NR_psynch_rw_wrlock                          = 0x1029,
    NR_psynch_rw_unlock                          = 0x102A,
    NR_psynch_cvclrprepost                       = 0x102B,
    NR_get_tracer                                = 0x102C,
    NR_tid_for_thread                            = 0x102D,
    NR_getuidgid                                 = 0x102E,
    NR_setuidgid                                 = 0x102F,
    NR_task_name_for_pid_trap                    = 0x1030,
    NR_set_tracer                                = 0x1031,
    NR_pthread_markcancel                        = 0x1032,
    NR_pthread_canceled                          = 0x1033,
    NR_pid_get_state                             = 0x1034,
    NR_started_suspended                         = 0x1035,
    NR_task_64bit                                = 0x1036,
    NR__kernelrpc_mach_vm_allocate_trap          = 0x1037,
    NR__kernelrpc_mach_vm_deallocate_trap        = 0x1038,
    NR_last_triggered_watchpoint                 = 0x1039,
    NR_vchroot                                   = 0x103A,
    NR_vchroot_expand                            = 0x103B,
    NR_vchroot_fdpath                            = 0x103C,
    NR_handle_to_path                            = 0x103D,
    NR_fileport_makeport                         = 0x103E,
    NR_fileport_makefd                           = 0x103F,
    NR_sigprocess                                = 0x1040,
    NR_ptrace_thupdate                           = 0x1041,
    NR_ptrace_sigexc                             = 0x1042,
    NR_thread_suspended                          = 0x1043,
    NR_set_thread_handles                        = 0x1044,
    NR_thread_get_special_reply_port             = 0x1045,
    NR__kernelrpc_mach_port_request_notification_trap = 0x1046,
    NR__kernelrpc_mach_port_type_trap            = 0x1047,
    NR__kernelrpc_mach_port_get_attributes_trap  = 0x1048,
    NR__kernelrpc_mach_port_construct_trap       = 0x1049,
    NR__kernelrpc_mach_port_destruct_trap        = 0x104A,
    NR__kernelrpc_mach_port_guard_trap           = 0x104B,
    NR__kernelrpc_mach_port_unguard_trap         = 0x104C,
    NR_kqueue_create                             = 0x104D,
    NR_kevent                                    = 0x104E,
    NR_kevent64                                  = 0x104F,
    NR_kevent_qos                                = 0x1050,
    NR_closing_descriptor                        = 0x1051,

    DARLING_MACH_API_LAST                        = 0x1051,
    DARLING_MACH_API_COUNT = (DARLING_MACH_API_LAST - DARLING_MACH_API_BASE + 1)
};

// Human-readable name for a trap number (for BW64_DEVMACHTRACE). Returns
// "trap_0xNNNN" for anything outside the known range.
const char* darwinMachTrapName(U64 trapNum);

#endif // BOXEDWINE_DARWIN
#endif // __DARWIN_MACHTRAPS_H__
