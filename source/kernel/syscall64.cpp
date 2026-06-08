/*
 *  Copyright (C) 2012-2026  The BoxedWine Team
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#include "boxedwine.h"

#ifdef BOXEDWINE_GUEST_X64

#include "syscall64.h"
#include "cpu64.h"
#include "kmemory64.h"
#include "ksocket.h"
#include "kevent.h"  // syscall_eventfd2 (shared with the 32-bit path)
#include "kpidfd.h"  // syscall_pidfd_open (darlingserver process monitor)
#include "ktimer.h"  // KTimer for 64-bit timerfd
#include <thread>   // std::this_thread::yield() for sched_yield
#include <mutex>    // std::recursive_mutex for BW64_SERIAL_TEARDOWN
#include <set>      // BW64_BLOCKDUMP dedup set
#include "kunixsocket.h"
#include "kpoll.h"
#include "ripSampler.h"
#ifdef BOXEDWINE_OPENGL
#include "../opengl/gl64bridge.h"
#include "../opengl/gl64bridge_abi.h"
#ifdef BOXEDWINE_DARWIN
#include "devmach.h"
#include "darwin/dyldsym.h"
#endif
#endif

// x86-64 Linux syscall numbers used here. The canonical table lives in
// arch/x86/entry/syscalls/syscall_64.tbl in the Linux source; the values
// below are stable Linux ABI and never change.
#define X64_SYS_read              0
#define X64_SYS_write             1
#define X64_SYS_open              2
#define X64_SYS_close             3
#define X64_SYS_stat              4
#define X64_SYS_fstat             5
#define X64_SYS_lstat             6
#define X64_SYS_poll              7
#define X64_SYS_ppoll             271
#define X64_SYS_pselect6          270
#define X64_SYS_lseek             8
#define X64_SYS_mmap              9
#define X64_SYS_mprotect          10
#define X64_SYS_munmap            11
#define X64_SYS_brk               12
#define X64_SYS_shmget            29
#define X64_SYS_shmat             30
#define X64_SYS_shmctl            31
#define X64_SYS_shmdt             67
#define X64_SYS_rt_sigaction      13
#define X64_SYS_rt_sigprocmask    14
#define X64_SYS_ioctl             16
#define X64_SYS_pread64           17
#define X64_SYS_writev            20
#define X64_SYS_access            21
#define X64_SYS_readlink          89
#define X64_SYS_readlinkat        267
#define X64_SYS_faccessat         269
#define X64_SYS_faccessat2        439
#define X64_SYS_mkdir             83
#define X64_SYS_mkdirat           258
#define X64_SYS_symlink           88
#define X64_SYS_symlinkat         266
#define X64_SYS_link              86
#define X64_SYS_linkat            265
#define X64_SYS_utimensat         280
#define X64_SYS_socketpair        53
#define X64_SYS_shutdown          48
#define X64_SYS_socket            41
#define X64_SYS_connect           42
#define X64_SYS_accept            43
#define X64_SYS_bind              49
#define X64_SYS_listen            50
#define X64_SYS_getsockname       51
#define X64_SYS_getpeername       52
#define X64_SYS_setsockopt        54
#define X64_SYS_getsockopt        55
#define X64_SYS_sendmsg           46
#define X64_SYS_recvmsg           47
#define X64_SYS_sendmmsg          307
#define X64_SYS_recvmmsg          299
#define X64_SYS_sendto            44
#define X64_SYS_recvfrom          45
#define X64_SYS_unlink            87
#define X64_SYS_unlinkat          263
#define X64_SYS_rename            82
#define X64_SYS_renameat          264
#define X64_SYS_renameat2         316
#define X64_SYS_fchdir            81
#define X64_SYS_ftruncate         77
#define X64_SYS_umask             95
#define X64_SYS_setsid            112
#define X64_SYS_getpid            39
#define X64_SYS_exit              60
#define X64_SYS_uname             63
#define X64_SYS_setuid            105
#define X64_SYS_setgid            106
#define X64_SYS_getuid            102
#define X64_SYS_time              201
#define X64_SYS_getgid            104
#define X64_SYS_geteuid           107
#define X64_SYS_getegid           108
#define X64_SYS_prctl             157
#define X64_SYS_arch_prctl        158
#define X64_SYS_ptrace            101
#define X64_SYS_mount             165
#define X64_SYS_unshare           272
#define X64_SYS_chown             92
#define X64_SYS_fchown            93
#define X64_SYS_lchown            94
#define X64_SYS_fchownat          260
#define X64_SYS_gettid            186
#define X64_SYS_futex             202
#define X64_SYS_set_tid_address   218
#define X64_SYS_clock_gettime     228
#define X64_SYS_exit_group        231
#define X64_SYS_openat            257
#define X64_SYS_newfstatat        262
#define X64_SYS_set_robust_list   273
#define X64_SYS_madvise           28
#define X64_SYS_fadvise64         221
#define X64_SYS_mremap            25
#define X64_SYS_sigaltstack       131
#define X64_SYS_rt_sigreturn      15
#define X64_SYS_dup               32
#define X64_SYS_dup2              33
#define X64_SYS_getcwd            79
#define X64_SYS_chdir             80
#define X64_SYS_fcntl             72
#define X64_SYS_pipe              22
#define X64_SYS_pipe2             293
#define X64_SYS_getdents64        217
#define X64_SYS_tgkill            234
#define X64_SYS_tkill             200
#define X64_SYS_prlimit64         302
#define X64_SYS_getrlimit         97
#define X64_SYS_setrlimit         160
#define X64_SYS_sched_getscheduler 145
#define X64_SYS_sched_setscheduler 144
#define X64_SYS_sched_getparam    143
#define X64_SYS_mlockall          151
#define X64_SYS_munlockall        152
#define X64_SYS_mlock             149
#define X64_SYS_munlock           150
#define X64_SYS_getrandom         318
#define X64_SYS_getcpu            309
#define X64_SYS_sched_yield       24
#define X64_SYS_sched_setaffinity 203
#define X64_SYS_sched_getaffinity 204
#define X64_SYS_statfs            137
#define X64_SYS_fstatfs           138
#define X64_SYS_kill              62
#define X64_SYS_gettimeofday      96
#define X64_SYS_getrusage         98
#define X64_SYS_sysinfo           99
#define X64_SYS_getppid           110
#define X64_SYS_getpgrp           111
#define X64_SYS_getpgid           121
#define X64_SYS_getsid            124
#define X64_SYS_clock_getres      229
#define X64_SYS_clock_nanosleep   230
#define X64_SYS_nanosleep         35
#define X64_SYS_rseq              334
#define X64_SYS_clone3            435
#define X64_SYS_eventfd2          290
#define X64_SYS_eventfd           284
#define X64_SYS_timerfd_create    283
#define X64_SYS_timerfd_settime   286
#define X64_SYS_timerfd_gettime   287
#define X64_SYS_epoll_create1     291
#define X64_SYS_epoll_create      213
#define X64_SYS_pidfd_open        434
#define X64_SYS_process_vm_readv  310
#define X64_SYS_process_vm_writev 311
#define X64_SYS_epoll_ctl         233
#define X64_SYS_epoll_wait        232
#define X64_SYS_pwrite64          18
#define X64_SYS_readv             19
#define X64_SYS_select            23
#define X64_SYS_chmod             90
#define X64_SYS_fchmod            91
#define X64_SYS_fchmodat          268
#define X64_SYS_fchmodat2         452
#define X64_SYS_clone             56
#define X64_SYS_fork              57
#define X64_SYS_vfork             58
#define X64_SYS_execve            59
#define X64_SYS_wait4             61
#define X64_SYS_pause             34
#define X64_SYS_getitimer         36
#define X64_SYS_setitimer         38
#define X64_SYS_rt_sigpending     127
#define X64_SYS_rt_sigtimedwait   128
#define X64_SYS_rt_sigqueueinfo   129
#define X64_SYS_rt_sigsuspend     130

// arch_prctl subfunctions
#define X64_ARCH_SET_GS  0x1001
#define X64_ARCH_SET_FS  0x1002
#define X64_ARCH_GET_FS  0x1003
#define X64_ARCH_GET_GS  0x1004

// Linux returns errno as the negated value in RAX. We use the same K_*
// constants as the 32-bit path so error semantics stay aligned.
#ifndef K_ENOSYS
#define K_ENOSYS 38
#endif
#ifndef K_EINVAL
#define K_EINVAL 22
#endif
#ifndef K_EFAULT
#define K_EFAULT 14
#endif
#ifndef K_EAGAIN
#define K_EAGAIN 11
#endif
#ifndef K_ENOMEM
#define K_ENOMEM 12
#endif
#ifndef K_ECHILD
#define K_ECHILD 10
#endif
#ifndef K_EINTR
#define K_EINTR 4
#endif
#ifndef K_EBADF
#define K_EBADF 9
#endif
#ifndef K_EMFILE
#define K_EMFILE 24
#endif
#ifndef K_ESRCH
#define K_ESRCH 3
#endif
#ifndef K_ENODATA
#define K_ENODATA 61
#endif
#ifndef K_ENOTSUP
#define K_ENOTSUP 95
#endif

// FUTEX_* op codes from <linux/futex.h>. We handle WAIT/WAKE + their
// BITSET variants (glibc 2.35+ uses WAKE_BITSET for pthread_cond_signal)
// and recognize REQUEUE/CMP_REQUEUE/WAKE_OP so we don't reject them with
// EINVAL — they degrade to "no waiters woken" which is correct for our
// single-threaded world. The CLOCK_REALTIME bit (0x100) is ignored
// because we don't block anyway.
#define X64_FUTEX_WAIT             0
#define X64_FUTEX_WAKE             1
#define X64_FUTEX_REQUEUE          3
#define X64_FUTEX_CMP_REQUEUE      4
#define X64_FUTEX_WAKE_OP          5
#define X64_FUTEX_WAIT_BITSET      9
#define X64_FUTEX_WAKE_BITSET      10
#define X64_FUTEX_PRIVATE_FLAG     128
#define X64_FUTEX_CLOCK_REALTIME   256
#define X64_FUTEX_WAIT_PRIVATE     (X64_FUTEX_WAIT | X64_FUTEX_PRIVATE_FLAG)
#define X64_FUTEX_WAKE_PRIVATE     (X64_FUTEX_WAKE | X64_FUTEX_PRIVATE_FLAG)

// MAP_* bits used by mmap. Kept local to avoid pulling kernel.h here.
#ifndef K_MAP_ANONYMOUS
#define K_MAP_ANONYMOUS 0x20
#endif
#ifndef K_MAP_FIXED
#define K_MAP_FIXED 0x10
#endif

// Base address for mmap(NULL, ...) placements. High enough to never collide
// with PIE-loaded segments (X64_PIE_BASE=0x400000000) or the program break.
#define MMAP64_BASE 0x700000000ULL

// Address-space allocation for mmap(NULL,...) now lives in
// KMemory64::mmapReserveAndMap, which scans for a free gap and maps it as ONE
// atomic step under the process mmap lock. The old split here (allocMmapRange
// returns an address, the caller maps it afterwards) was a TOCTOU race in the
// multi-threaded build: two sibling threads scanned, both saw the same gap
// free, both mapped there, and the second map zeroed the first → guest-heap
// corruption ("malloc(): corrupted double linked list") in wineserver during
// the boot storm. The shared bump cursor moved to KMemory64::mmapNext.

// BW64_CRASHRING: a tiny lock-light ring of the last few socket writes (pid +
// fd + first 16 bytes = the wineserver request header / opcode). When a guest
// process prints an abort to stderr (e.g. wineserver's "release_object:
// Assertion 'obj->refcount' failed"), we dump the ring so the request sequence
// that led to the crash is visible WITHOUT the multi-GB BW64_IPCDUMP firehose.
// Zero cost when the env var is unset.
// kind: 'W'=write, 'R'=read, 'M'=recvmsg, 'F'=scm_rights fd delivered (recv),
//       'S'=sendmsg scm_rights fd sent (e0=#fds, e1=first guest fd).
// extra0/extra1 carry per-kind context (see crashRingRecordRead callers).
struct CrashRingEntry { char kind; U32 pid; U32 fd; U32 len; U32 extra0; U32 extra1; U8 hdr[16]; };
// Serializes guest file reads (sys_read64 + sys_mmap64_file) against the shared
// per-zip decompression stream. wine's DLLs live in wine64.zip; every
// FsZipOpenNode of the same entry shares ONE unzFile + position state, and the
// seek()+readNative() that maps a DLL segment is several un-co-locked calls. Two
// wine processes loading the same DLL on separate host threads otherwise
// interleave seek/read and each reads from the OTHER's file position — splatter-
// ing a DLL's MZ header over its own .text/.data/IAT, corrupting the IAT, and
// producing a wild indirect call into low memory (RIP=0x10270) -> "could not load
// kernel32.dll" -> cascading wineserver heap corruption. Holding this lock across
// the whole read makes file reads atomic. Not perf-critical (DLL load path).
static std::mutex g_fileReadMutex;

static CrashRingEntry g_crashRing[64];
static std::atomic<U32> g_crashRingPos{0};
static bool g_crashRingOn = false;
static bool g_crashRingChecked = false;
// BW64_WSREAD: also record the READ side (read/recvmsg/scm) of wineserver
// sockets into the same ring, so the dump shows the request/reply/fd-pass
// sequence — needed to catch a duplicated or mis-framed request that drives
// wineserver's release_object double-free. Independent gate, zero cost when off.
static bool g_wsReadOn = false;
static bool g_wsReadChecked = false;
static bool wsReadEnabled() {
    if (!g_wsReadChecked) { g_wsReadOn = getenv("BW64_WSREAD") != nullptr; g_wsReadChecked = true; }
    return g_wsReadOn;
}
static void crashRingPut(char kind, U32 pid, U32 fd, const U8* data, U32 count, U32 extra0, U32 extra1) {
    U32 i = g_crashRingPos.fetch_add(1) % 64;
    g_crashRing[i].kind = kind;
    g_crashRing[i].pid = pid; g_crashRing[i].fd = fd; g_crashRing[i].len = count;
    g_crashRing[i].extra0 = extra0; g_crashRing[i].extra1 = extra1;
    U32 n = count < 16 ? count : 16;
    for (U32 j = 0; j < 16; j++) g_crashRing[i].hdr[j] = (data && j < n) ? data[j] : 0;
}
static void crashRingRecord(U32 pid, U32 fd, const U8* data, U32 count) {
    if (!g_crashRingChecked) { g_crashRingOn = getenv("BW64_CRASHRING") != nullptr; g_crashRingChecked = true; }
    if (!g_crashRingOn) return;
    crashRingPut('W', pid, fd, data, count, 0, 0);
}
// BW64_WSCONC: concurrency witness for the bug #2 teardown crash. wine's
// wineserver is designed single-threaded (one epoll loop processes every
// client request + disconnect strictly serially). If our MT model ever has two
// HOST threads inside wineserver's own request processing at the same instant,
// a close_handle's release_object can race the disconnect-cascade's release of
// the same object -> refcount underflow -> the object.c:443 assert. This counts
// how many host threads are concurrently reading wineserver's (pid 14) socket;
// any value >1 is the smoking gun. Keyed by the READING process id so it only
// arms for wineserver itself. Zero cost unless BW64_WSCONC is set.
static bool g_wsConcInit = false, g_wsConcOn = false;
static std::atomic<int> g_wsConcInflight{0};
static std::atomic<int> g_wsConcMax{0};
static bool wsConcEnabled() {
    if (!g_wsConcInit) { g_wsConcOn = getenv("BW64_WSCONC") != nullptr; g_wsConcInit = true; }
    return g_wsConcOn;
}
// Read-side recorder (used by sys_read64 / sys_recvmsg64 / the scm witness).
// Gated by BW64_WSREAD AND the same ring being on so the dump path fires.
static void crashRingRecordRead(char kind, U32 pid, U32 fd, const U8* data, U32 count, U32 extra0, U32 extra1) {
    if (!g_crashRingChecked) { g_crashRingOn = getenv("BW64_CRASHRING") != nullptr; g_crashRingChecked = true; }
    if (!g_crashRingOn || !wsReadEnabled()) return;
    crashRingPut(kind, pid, fd, data, count, extra0, extra1);
}
static void crashRingDump(const char* why) {
    if (!g_crashRingOn) return;
    klog_fmt("CRASHRING dump (%s) — last 64 socket events, oldest first:", why);
    U32 start = g_crashRingPos.load();
    for (U32 k = 0; k < 64; k++) {
        CrashRingEntry& e = g_crashRing[(start + k) % 64];
        if (e.kind == 0) continue;
        klog_fmt("  CR[%u] %c pid=%u fd=%u len=%u e0=%u e1=%u  [%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x]",
                 k, e.kind, e.pid, e.fd, e.len, e.extra0, e.extra1,
                 e.hdr[0],e.hdr[1],e.hdr[2],e.hdr[3],e.hdr[4],e.hdr[5],e.hdr[6],e.hdr[7],
                 e.hdr[8],e.hdr[9],e.hdr[10],e.hdr[11],e.hdr[12],e.hdr[13],e.hdr[14],e.hdr[15]);
    }
}

static U64 sys_write64(CPU64* cpu, U64 fd, U64 buf, U64 count) {
    if (count == 0) return 0;
    if (count > (1ULL << 20)) count = 1ULL << 20;
    std::vector<U8> buffer((size_t)count + 1);
    cpu->memory->memcpyFromGuest(buffer.data(), buf, count);
    buffer[count] = 0;
    // BW64_LAUNCHMSG (S20): launchctl submits each LaunchDaemon job dict to
    // launchd over the launchd control socket. liblaunch uses sendmsg(), but if
    // the guest libc lowers that to write()/writev() on the connected SOCK_STREAM
    // (or the submit takes any other write path) sys_sendmsg64 never sees it. So
    // ALSO scan write payloads here for the literal "RunAtLoad" key — a launch
    // job dict carries it as inline ASCII on every transport. This is the
    // catch-all that answers whether the 20 job dicts ever leave launchctl.
    if (getenv("BW64_LAUNCHMSG") && fd > 2 && fd < 0x2000) {
        U32 wpid = (cpu->thread && cpu->thread->process) ? cpu->thread->process->id : 0;
        if (count > 64) {
            klog_fmt("SOCKWRITE-W pid=%u fd=%llu count=%llu",
                     (unsigned)wpid, (unsigned long long)fd, (unsigned long long)count);
        }
        for (U64 i = 0; i + 9 <= count && i < 1048576; i++) {
            if (buffer[i] == 'R' && buffer[i+1] == 'u' && buffer[i+2] == 'n' &&
                buffer[i+3] == 'A' && buffer[i+8] == 'd' &&
                buffer[i+4] == 't' && buffer[i+5] == 'L') { // "RunAtLoad"
                klog_fmt("LAUNCHMSG-WRITE pid=%u fd=%llu count=%llu (carries RunAtLoad)",
                         (unsigned)wpid, (unsigned long long)fd, (unsigned long long)count);
                break;
            }
        }
    }
    if (fd == 1 || fd == 2) {
        // Tee stdout/stderr to host console so ld-linux + glibc diagnostics
        // surface immediately. Also forward to the kobject so anything
        // tailing the host FS still sees it.
        U32 wpid = (cpu->thread && cpu->thread->process) ? cpu->thread->process->id : 0;
        const char* wexe = (cpu->thread && cpu->thread->process) ? cpu->thread->process->name.c_str() : "?";
        klog_fmt("[guest fd=%llu pid=%u %s] %s", (unsigned long long)fd, (unsigned)wpid, wexe, (const char*)buffer.data());
        // On a guest abort, dump the request ring so we can see the wineserver
        // request sequence that triggered the double-release.
        if (fd == 2 && (strstr((const char*)buffer.data(), "release_object") ||
                        strstr((const char*)buffer.data(), "Assertion") ||
                        strstr((const char*)buffer.data(), "tcache") ||
                        strstr((const char*)buffer.data(), "unaligned") ||
                        strstr((const char*)buffer.data(), "unimplemented function") ||
                        strstr((const char*)buffer.data(), "corrupted"))) {
            crashRingDump((const char*)buffer.data());
            // BW64_WSBT: at the assert WRITE (glibc prints the message BEFORE
            // abort()), wineserver's guest stack is still intact. Scan it for
            // code-looking return addresses so addr2line on the wineserver binary
            // can name the release_object CALLER (the buggy teardown path). The
            // assert chain is __assert_fail -> release_object -> <culprit>. We
            // print RIP + any stack word that lands in the wineserver text range
            // [base, base+size). The image base is logged once at load (BW64_WSBT
            // also enables that). Cheap: only on the abort path.
            if (getenv("BW64_WSBT")) {
                auto rdq = [&](U64 a) -> U64 {
                    U64 v = 0;
                    for (int b = 0; b < 8; b++) v |= ((U64)cpu->memory->readb(a + b)) << (b * 8);
                    return v;
                };
                klog_fmt("WSBT: assert in pid=%u %s  RIP=%llx RSP=%llx RBP=%llx",
                         (unsigned)wpid, wexe,
                         (unsigned long long)cpu->rip,
                         (unsigned long long)cpu->reg[X64_RSP].u64,
                         (unsigned long long)cpu->reg[X64_RBP].u64);
                U64 sp = cpu->reg[X64_RSP].u64;
                // Walk a wide stack window; print every word that could be a
                // return address into a mapped, executable-ish region. We don't
                // know the exact text range here, so print all plausible code
                // pointers (high-half canonical, page-aligned-ish) and let
                // post-processing filter by the wineserver mmap range.
                for (int i = 0; i < 160; i++) {
                    U64 v = rdq(sp + (U64)i * 8);
                    // Heuristic: wineserver/glibc code lives at low-ish 47-bit
                    // addresses; skip obvious data (small ints, ASCII, stack ptrs
                    // near sp). Print candidates with the 'CODE?' tag.
                    if (v > 0x10000 && v < 0x800000000000ULL &&
                        (v < sp - 0x100000 || v > sp + 0x100000)) {
                        klog_fmt("WSBT:   [rsp+%03x] = 0x%llx", i * 8, (unsigned long long)v);
                    }
                }
            }
            // BW64_MALLOCDUMP: for the glibc malloc-METADATA faces ("unaligned
            // tcache chunk" / "corrupted double-linked list" / "corrupted
            // unsorted chunks") — the dominant faces of bug #2 — REFWATCH can't
            // fire (no release_object). glibc's malloc_printerr(msg) is reached
            // from the freelist-walk that detected the bad chunk, and the bad
            // chunk pointer is usually still live in a callee-saved register
            // (rbx/rbp/r12-r15, preserved across __libc_message) or a nearby
            // stack slot. Dump them + flag stack words that point into the
            // wineserver heap range so we can correlate the corrupted address
            // against recent writes (BW64_MEMRING). Cheap: abort path only.
            if (getenv("BW64_MALLOCDUMP") &&
                (strstr((const char*)buffer.data(), "tcache") ||
                 strstr((const char*)buffer.data(), "corrupted") ||
                 strstr((const char*)buffer.data(), "unaligned"))) {
                auto rdq = [&](U64 a) -> U64 {
                    U64 v = 0;
                    for (int b = 0; b < 8; b++) v |= ((U64)cpu->memory->readb(a + b)) << (b * 8);
                    return v;
                };
                klog_fmt("MALLOCDUMP pid=%u %s RIP=%llx RSP=%llx RBP=%llx RBX=%llx R12=%llx R13=%llx R14=%llx R15=%llx RDI=%llx RSI=%llx",
                         (unsigned)wpid, wexe, (unsigned long long)cpu->rip,
                         (unsigned long long)cpu->reg[X64_RSP].u64, (unsigned long long)cpu->reg[X64_RBP].u64,
                         (unsigned long long)cpu->reg[X64_RBX].u64, (unsigned long long)cpu->reg[X64_R12].u64,
                         (unsigned long long)cpu->reg[X64_R13].u64, (unsigned long long)cpu->reg[X64_R14].u64,
                         (unsigned long long)cpu->reg[X64_R15].u64, (unsigned long long)cpu->reg[X64_RDI].u64,
                         (unsigned long long)cpu->reg[X64_RSI].u64);
                // Heap candidates: glibc's main arena heap lives well above the
                // PE/text mappings and below the stack. Print stack words that
                // look like heap data pointers (not text <0x500000000, not near
                // rsp), and dump 16 bytes around each — a corrupted chunk shows a
                // mis-aligned or wild fd/bk.
                U64 sp = cpu->reg[X64_RSP].u64;
                for (int i = 0; i < 64; i++) {
                    U64 v = rdq(sp + (U64)i * 8);
                    if (v > 0x500000000ULL && v < 0x800000000000ULL &&
                        (v < sp - 0x200000 || v > sp + 0x200000)) {
                        klog_fmt("MALLOCDUMP   [rsp+%03x]=0x%llx  chunk?[-8..+16]= %016llx | %016llx %016llx %016llx",
                                 i * 8, (unsigned long long)v,
                                 (unsigned long long)rdq(v - 8), (unsigned long long)rdq(v),
                                 (unsigned long long)rdq(v + 8), (unsigned long long)rdq(v + 16));
                    }
                }
                // Correlate against the wineserver write ring (BW64_MEMRING).
                kmemory64DumpMemRing(0);
            }
        }
        // BW64_STUBDUMP: when wine reports a call to an unimplemented function,
        // dump the live register/stack state so we can identify the stub and the
        // ABI register the dll/func name strings actually landed in. The abort
        // message itself loses the names (they print as ".garbage").
        if (fd == 2 && getenv("BW64_STUBDUMP") &&
            strstr((const char*)buffer.data(), "unimplemented function")) {
            auto rdStr = [&](U64 a) -> std::string {
                std::string s;
                if (!a) return "<null>";
                for (int i = 0; i < 64; i++) {
                    U8 c = cpu->memory->readb(a + i);
                    if (!c) break;
                    if (c < 32 || c > 126) { s += '?'; } else s += (char)c;
                }
                return s.empty() ? "<empty>" : s;
            };
            klog_fmt("STUBDUMP pid=%u RIP=%llx RSP=%llx RAX=%llx RCX=%llx RDX=%llx R8=%llx R9=%llx RDI=%llx RSI=%llx",
                     (unsigned)wpid, (unsigned long long)cpu->rip,
                     (unsigned long long)cpu->reg[X64_RSP].u64, (unsigned long long)cpu->reg[X64_RAX].u64,
                     (unsigned long long)cpu->reg[X64_RCX].u64, (unsigned long long)cpu->reg[X64_RDX].u64,
                     (unsigned long long)cpu->reg[X64_R8].u64, (unsigned long long)cpu->reg[X64_R9].u64,
                     (unsigned long long)cpu->reg[X64_RDI].u64, (unsigned long long)cpu->reg[X64_RSI].u64);
            klog_fmt("STUBDUMP  RCX->\"%s\" RDX->\"%s\" R8->\"%s\" RDI->\"%s\" RSI->\"%s\"",
                     rdStr(cpu->reg[X64_RCX].u64).c_str(), rdStr(cpu->reg[X64_RDX].u64).c_str(),
                     rdStr(cpu->reg[X64_R8].u64).c_str(), rdStr(cpu->reg[X64_RDI].u64).c_str(),
                     rdStr(cpu->reg[X64_RSI].u64).c_str());
            auto rdq = [&](U64 a) -> U64 {
                U64 v = 0;
                for (int b = 0; b < 8; b++) v |= ((U64)cpu->memory->readb(a + b)) << (b * 8);
                return v;
            };
            U64 sp = cpu->reg[X64_RSP].u64;
            for (int i = 0; i < 12; i++) {
                U64 v = rdq(sp + (U64)i * 8);
                klog_fmt("STUBDUMP  [rsp+%02x]=%llx  ->\"%s\"", i * 8, (unsigned long long)v, rdStr(v).c_str());
            }
        }
    } else if (cpu->thread && cpu->thread->process) {
        crashRingRecord(cpu->thread->process->id, (U32)fd, buffer.data(), (U32)count);
    }
    if (!cpu->thread || !cpu->thread->process) {
        return count;
    }
    KFileDescriptorPtr fdesc = cpu->thread->process->getFileDescriptor((FD)fd);
    if (!fdesc) {
        if (fd == 1 || fd == 2) return count; // already klog'd
        return (U64)-9; // -EBADF
    }
    if (!fdesc->canWrite()) {
        return (U64)-K_EINVAL;
    }
    U32 wrote = fdesc->kobject->writeNative(buffer.data(), (U32)count);
    // A connected stream socket whose peer object is TRANSIENTLY unreferenced
    // under boot-time fd-table churn returns -K_EWOULDBLOCK (see
    // KUnixSocketObject::writeNative). On a blocking fd this must not surface to
    // the guest (wine treats a short/odd write to its wineserver request socket
    // as fatal -> "partial write"). Retry a bounded number of host yields so the
    // peer's strong ref reappears; only give up (real -EPIPE) if it never does.
    if ((S32)wrote == -K_EWOULDBLOCK && fdesc->kobject->isBlocking()) {
        for (int spin = 0; spin < 1000 && (S32)wrote == -K_EWOULDBLOCK; spin++) {
            std::this_thread::yield();
            wrote = fdesc->kobject->writeNative(buffer.data(), (U32)count);
        }
        if ((S32)wrote == -K_EWOULDBLOCK) {
            wrote = (U32)-K_EPIPE; // peer truly gone after retries
        }
    }
    if (getenv("BW64_IPCDUMP")) {
        char hex[64] = {0}; int n = (int)((count < 16) ? count : 16);
        for (int i = 0; i < n; i++) snprintf(hex + i*3, 4, "%02x ", buffer[i]);
        klog_fmt("IPC [pid=%d] write(fd=%d,count=%llu) -> %d  [%s]",
                 (int)cpu->thread->process->id, (int)fd,
                 (unsigned long long)count, (int)(S32)wrote, hex);
    }
    return (S32)wrote < 0 ? (U64)(S64)(S32)wrote : (U64)wrote;
}

static U64 sys_arch_prctl64(CPU64* cpu, U64 code, U64 addr) {
    switch (code) {
        case X64_ARCH_SET_FS:
            cpu->fsbase = addr;
            return 0;
        case X64_ARCH_SET_GS:
            cpu->gsbase = addr;
            return 0;
        case X64_ARCH_GET_FS:
            cpu->memory->writeq(addr, cpu->fsbase);
            return 0;
        case X64_ARCH_GET_GS:
            cpu->memory->writeq(addr, cpu->gsbase);
            return 0;
        default:
            return (U64)-K_EINVAL;
    }
}

// brk(0) → returns current break. brk(new) → tries to set break, returns
// new break on success or old break on failure (Linux contract). Stored
// per-process on KProcess::brkEnd in the 32-bit path; we put it on the
// thread's process the same way.
static U64 sys_brk64(CPU64* cpu, U64 newBrk) {
    // Resolve where the current break lives. Full kernel: KProcess::brkEnd64.
    // Standalone runner (no process): CPU64::runnerBrk, seeded by the runner
    // to just past the loaded image. If neither is available there's no heap
    // to manage, so report 0 (the historical no-process behaviour).
    bool hasProcess = (cpu->thread && cpu->thread->process);
    U64 oldBrk;
    if (hasProcess) {
        oldBrk = cpu->thread->process->brkEnd64;
    } else if (cpu->runnerBrk) {
        oldBrk = cpu->runnerBrk;
    } else {
        return 0;
    }

    if (newBrk == 0 || newBrk < oldBrk) {
        return oldBrk;
    }
    // Map the gap as anonymous RW. mmapAnonymousFixed expects page-aligned
    // addresses; round oldBrk up and newBrk up to page boundaries.
    U64 alignedOld = (oldBrk + 0xFFF) & ~0xFFFULL;
    U64 alignedNew = (newBrk + 0xFFF) & ~0xFFFULL;
    if (alignedNew > alignedOld) {
        U64 ret = cpu->memory->mmapAnonymousFixed(alignedOld, alignedNew - alignedOld, 0x3); // PROT_READ|WRITE
        if ((S64)ret < 0) {
            return oldBrk;
        }
    }
    if (hasProcess) cpu->thread->process->brkEnd64 = newBrk;
    else            cpu->runnerBrk = newBrk;
    return newBrk;
}

// Forward decl for the file-backed path; defined below.
static U64 sys_mmap64_file(CPU64* cpu, U64 addr, U64 length, U64 prot,
                           U64 flags, U64 fd, U64 offset);

static U64 sys_mmap64(CPU64* cpu, U64 addr, U64 length, U64 prot, U64 flags, U64 fd, U64 offset) {
    if (!(flags & K_MAP_ANONYMOUS)) {
        return sys_mmap64_file(cpu, addr, length, prot, flags, fd, offset);
    }
    if (getenv("BW64_MMAPDUMP") && length >= 0x1000000) {
        klog_fmt("MMAP [pid=%d] BIG anon enter addr=0x%llx len=0x%llx prot=0x%x",
                 (int)(cpu->thread ? cpu->thread->process->id : -1),
                 (unsigned long long)addr, (unsigned long long)length, (unsigned)prot);
    }
    // The macOS commpage lives at a FIXED guest address (x86_64
    // _COMM_PAGE64_BASE_ADDRESS = 0x7fffffe00000). Darling's mldr maps it with a
    // plain address hint (no MAP_FIXED), trusting the XNU kernel to reserve that
    // exact page. Our hint logic relocates a hint whose range isn't free, so if
    // anything already touched that page mldr's commpage ends up elsewhere while
    // libsystem_malloc/libpthread/libdispatch read the hardcoded address (blank
    // -> _phys_ncpus==0 -> div #DE in __malloc_initialize). Honor the commpage
    // address verbatim (force-fixed) so the data mldr writes is where the guest
    // reads it.
    if (addr != 0 && (addr & ~0xFFFULL) == 0x7fffffe00000ULL) {
        flags |= K_MAP_FIXED;
        if (getenv("BW64_COMMPAGE")) {
            klog_fmt("COMMPAGE: forcing MAP_FIXED for mmap addr=0x%llx len=0x%llx "
                     "prot=0x%x pid=%d", (unsigned long long)addr,
                     (unsigned long long)length, (unsigned)prot,
                     (int)(cpu->thread ? cpu->thread->process->id : -1));
        }
    }
    U64 ret;
    bool fixed = (flags & K_MAP_FIXED) != 0;
    if (addr != 0 && fixed) {
        // MAP_FIXED: caller demands this exact address and expects any existing
        // mapping there to be replaced. Honor it verbatim.
        ret = cpu->memory->mmapAnonymousFixed(addr & ~0xFFFULL, length, (U32)prot);
    } else if (addr != 0) {
        // addr is a HINT (no MAP_FIXED). Linux may place elsewhere if the hint
        // is already occupied — and it MUST, because force-mapping over an
        // existing region silently destroys whatever lived there. Wine's view
        // manager then later MAP_FIXED-maps its own view at an address it still
        // believes is free, finds our stray anonymous mapping, and aborts in
        // create_view (`assert(view->protect & VPROT_SYSTEM)`, virtual.c:1578).
        // So: take the hint only if the whole range is free; otherwise let the
        // allocator pick a free range (kernel's prerogative for a hint).
        //
        // "Free" here means no ACCESSIBLE mapping — a page with any of R/W/X.
        // Crucially it does NOT mean "no K64_PAGE_MAPPED": wine reserves huge
        // PROT_NONE arenas (MAPPED but prot 0) and then mmaps committed pages at
        // HINT addresses *inside* its own reservation. Treating those reserved
        // pages as occupied would bounce the allocation to an unrelated address
        // and desync wine's view tree (hang/abort). Only a real R/W/X mapping is
        // a genuine conflict that forces relocation.
        U64 alignedAddr = addr & ~0xFFFULL;
        U64 pageStart = alignedAddr >> 12;
        U64 pageCount = (length + 0xFFFULL) >> 12;
        const U32 accessible = K64_PAGE_READ | K64_PAGE_WRITE | K64_PAGE_EXEC;
        bool rangeFree = true;
        for (U64 i = 0; i < pageCount; i++) {
            if (cpu->memory->getPageFlags(pageStart + i) & accessible) { rangeFree = false; break; }
        }
        if (rangeFree) {
            ret = cpu->memory->mmapAnonymousFixed(alignedAddr, length, (U32)prot);
        } else {
            ret = cpu->memory->mmapReserveAndMap(length, (U32)prot);
        }
    } else {
        // addr == 0: atomically reserve+map a free range. mmapReserveAndMap holds
        // the process mmap lock across the gap scan AND the map, so two sibling
        // threads can't be handed the same address (the old allocMmapRange-then-
        // map split was a TOCTOU race → guest-heap corruption in wineserver
        // during the MT boot storm).
        ret = cpu->memory->mmapReserveAndMap(length, (U32)prot);
    }
    if (getenv("BW64_MMAPDUMP") && length >= 0x1000000) {
        klog_fmt("MMAP [pid=%d] BIG anon exit  -> 0x%llx",
                 (int)(cpu->thread ? cpu->thread->process->id : -1),
                 (unsigned long long)ret);
    }
    (void)offset;
    return ret;
}

// ---- SysV shared memory (IPC_PRIVATE only) for the 64-bit guest ----
// Wine's unix-side ntdll uses anonymous shm segments to back memory views; the
// Save/Save As common dialog is the first GUI path that hits this. We service
// shmget/shmat/shmdt/shmctl out of the per-process shm64 table (see kprocess.h
// for why per-process is correct). shmat backs the segment with real anonymous
// pages via the normal mmap allocator, so wine sees a properly-mapped view and
// no longer trips create_view. Non-IPC_PRIVATE keys are rejected (-ENOSYS-free
// fallback isn't what wine wants here; it asks for IPC_PRIVATE).
#define K_IPC_PRIVATE   0
#define K_IPC_RMID      0
#define K_IPC_STAT      2
#define K_IPC_64        0x0100
#define K_SHM_RDONLY    010000

static U64 sys_shmget64(CPU64* cpu, U64 key, U64 size, U64 /*shmflg*/) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_EINVAL;
    // Only anonymous segments are supported (what wine requests). A named key
    // would need a system-wide table; wine's view-backing path never uses one.
    if (key != K_IPC_PRIVATE) return (U64)-K_EINVAL;
    KProcess* process = cpu->thread->process.get();
    S32 id = process->nextShm64Id++;
    KProcess::ShmSeg64 seg;
    seg.size = size;
    process->shm64[id] = seg;
    return (U64)(S64)id;
}

static U64 sys_shmat64(CPU64* cpu, U64 shmid, U64 shmaddr, U64 shmflg) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_EINVAL;
    KProcess* process = cpu->thread->process.get();
    auto it = process->shm64.find((S32)shmid);
    if (it == process->shm64.end()) return (U64)-K_EINVAL;
    KProcess::ShmSeg64& seg = it->second;
    U32 prot = (shmflg & K_SHM_RDONLY) ? K_PROT_READ : (K_PROT_READ | K_PROT_WRITE);
    U64 addr;
    if (shmaddr == 0) {
        addr = cpu->memory->mmapReserveAndMap(seg.size, prot);
    } else {
        addr = cpu->memory->mmapAnonymousFixed(shmaddr & ~0xFFFULL, seg.size, prot);
    }
    if ((S64)addr < 0) return addr;          // propagate -errno
    seg.address = addr;
    return addr;
}

static U64 sys_shmdt64(CPU64* cpu, U64 shmaddr) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_EINVAL;
    KProcess* process = cpu->thread->process.get();
    for (auto it = process->shm64.begin(); it != process->shm64.end(); ++it) {
        KProcess::ShmSeg64& seg = it->second;
        if (seg.address && seg.address == shmaddr) {
            cpu->memory->munmap(seg.address, seg.size);
            seg.address = 0;
            // A segment detached after IPC_RMID is destroyed (Linux semantics).
            if (seg.markedForDelete) process->shm64.erase(it);
            return 0;
        }
    }
    return (U64)-K_EINVAL;
}

static U64 sys_shmctl64(CPU64* cpu, U64 shmid, U64 cmd, U64 buf) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_EINVAL;
    KProcess* process = cpu->thread->process.get();
    cmd &= ~K_IPC_64;
    auto it = process->shm64.find((S32)shmid);
    if (it == process->shm64.end()) return (U64)-K_EINVAL;
    KProcess::ShmSeg64& seg = it->second;
    if (cmd == K_IPC_RMID) {
        // Mark for delete; reap now if nothing is attached (matches Linux: RMID
        // on an unattached segment frees it immediately).
        seg.markedForDelete = true;
        if (seg.address == 0) process->shm64.erase(it);
        return 0;
    }
    if (cmd == K_IPC_STAT) {
        if (!buf) return (U64)-K_EFAULT;
        // Minimal struct shmid64_ds: zero it, then fill shm_segsz. Wine's view
        // backing doesn't inspect the rest; zeroing keys/perms is safe.
        cpu->memory->memsetGuest(buf, 0, 112);
        cpu->memory->writeq(buf + 40, seg.size);   // shm_segsz
        return 0;
    }
    return (U64)-K_EINVAL;
}

// exit(2) — terminate the calling thread. If it's the last thread in the
// process, this ends the process (exitgroup). `group` forces process-wide
// termination regardless of thread count (exit_group(2)).
// BW64_SERIAL_TEARDOWN experiment: a global lock serializing the EXECUTION of
// 64-bit process/thread teardown. On real Linux wineserver observes every client
// disconnect + final request through ONE epoll, fully serial. Here the boot
// helpers run on separate HOST threads and exit truly concurrently, so their
// terminate_thread/close requests + socket EOFs interleave at instruction
// granularity — the suspected trigger for wineserver's release_object refcount
// underflow / heap corruption during the post-boot teardown storm. Holding this
// across the whole cleanup (which closes the wineserver socket -> EOF) forces
// wineserver to see one client's full disconnect before the next begins.
// Recursive so an exitgroup that internally drives sibling teardown can't
// self-deadlock. Env-gated so it's a clean A/B with no cost when off.
// Does signal `sig`'s DEFAULT disposition kill the process? (Linux semantics.)
// Used when a self-directed signal (raise/abort via tgkill/kill) has no handler:
// fatal-default => terminate the process; ignore/stop-default => drop it.
// Default-IGNORE: SIGCHLD, SIGCONT, SIGURG, SIGWINCH. Default-STOP: SIGSTOP,
// SIGTSTP, SIGTTIN, SIGTTOU (we don't job-control, so treat as non-fatal/drop).
// Everything else with a meaningful default terminates.
static bool sigDefaultIsFatal(U32 sig) {
    switch (sig) {
        case 17:  // SIGCHLD  (default: ignore)
        case 18:  // SIGCONT  (default: continue)
        case 23:  // SIGURG   (default: ignore)
        case 28:  // SIGWINCH (default: ignore)
        case 19:  // SIGSTOP  (default: stop — no job control here, drop)
        case 20:  // SIGTSTP
        case 21:  // SIGTTIN
        case 22:  // SIGTTOU
            return false;
        default:
            return (sig >= 1 && sig <= 64);
    }
}

static std::recursive_mutex g_serialTeardownMutex;
static bool g_serialTeardownInit = false, g_serialTeardownOn = false;
static U64 sys_exit64(CPU64* cpu, U64 status, bool group) {
    if (!g_serialTeardownInit) {
        g_serialTeardownOn = std::getenv("BW64_SERIAL_TEARDOWN") != nullptr;
        g_serialTeardownInit = true;
    }
    if (cpu->thread && cpu->thread->process) {
        KProcess* p = cpu->thread->process.get();
        klog_fmt("CPU64: %s syscall, status=%lld  pid=%d exe='%s'",
                 group ? "exit_group" : "exit", (long long)status,
                 (int)p->id, p->exe.c_str());
    } else {
        klog_fmt("CPU64: %s syscall, status=%lld",
                 group ? "exit_group" : "exit", (long long)status);
    }
    // Stop this thread's run loop now, whatever else happens below.
    cpu->yield = true;
    if (cpu->thread && cpu->thread->process) {
        KProcess* process = cpu->thread->process.get();
        std::unique_lock<std::recursive_mutex> serialLk;
        if (g_serialTeardownOn) {
            serialLk = std::unique_lock<std::recursive_mutex>(g_serialTeardownMutex);
        }
        if (group) {
            process->exitgroup(cpu->thread, (U32)status);
        } else {
            // KProcess::exit runs cleanup() (which zeroes clear_child_tid64 and
            // futex-wakes the joiner) and terminates this thread; if it's the
            // last thread it falls through to exitgroup and ends the process.
            process->exit(cpu->thread, (U32)status);
        }
    }
    return 0;
}

// struct utsname is 6 × 65-byte fixed strings on x86-64 Linux (390 bytes).
static U64 sys_uname64(CPU64* cpu, U64 bufAddr) {
    if (!bufAddr) return (U64)-K_EFAULT;
    char buf[6 * 65];
    std::memset(buf, 0, sizeof(buf));
    auto setField = [&](int idx, const char* s) {
        std::strncpy(buf + idx * 65, s, 64);
    };
    setField(0, "Linux");                  // sysname
    setField(1, "boxedwine64");            // nodename
    setField(2, "6.1.0-boxedwine");        // release — pretend modern kernel
    setField(3, "#1 SMP boxedwine64");     // version
    setField(4, "x86_64");                 // machine
    setField(5, "(none)");                 // domainname
    cpu->memory->memcpyToGuest(bufAddr, buf, sizeof(buf));
    return 0;
}

// getrandom — fill buffer with pseudo-random bytes. Good enough for ld.so's
// stack canary; not cryptographically strong, but glibc only needs entropy.
static U64 sys_getrandom64(CPU64* cpu, U64 bufAddr, U64 buflen, U64 /*flags*/) {
    if (!bufAddr || buflen == 0) return 0;
    if (buflen > 256) buflen = 256;
    U8 tmp[256];
    static U64 seed = 0x9E3779B97F4A7C15ULL;
    for (U64 i = 0; i < buflen; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        tmp[i] = (U8)(seed >> 33);
    }
    cpu->memory->memcpyToGuest(bufAddr, tmp, buflen);
    return buflen;
}

// Linux resource numbers we care about reporting a *finite* limit for.
#define K_RLIMIT_NOFILE 7
// A realistic open-file limit. RLIMIT_NOFILE MUST NOT be reported as
// RLIM_INFINITY: Darling's libkqueue sizes its fd->kqueue map as
// `map_new(rlim_max)` and mmaps `rlim_max * sizeof(void*)` bytes. With an
// infinite (~UINT_MAX) max that becomes a ~32 GB sparse mmap, and the resulting
// map then fails (kqueue() -> -1), which makes launchd_runtime_init's
// `assert(kqueue() != -1)` fire (UD2). Report the conventional macOS OPEN_MAX so
// the map is a sane ~80 KB and kqueue() succeeds. (Linux default hard cap is
// often 1048576; macOS userland expects ~10240, which Darling targets.)
#define K_RLIMIT_NOFILE_CUR 10240ULL
#define K_RLIMIT_NOFILE_MAX 10240ULL

// prlimit64(pid, resource, new_limit*, old_limit*). We don't enforce limits, so
// we report "no limit" (RLIM64_INFINITY) for everything EXCEPT RLIMIT_NOFILE,
// which must be finite (see the NOFILE note above).
static U64 sys_prlimit64_64(CPU64* cpu, U64 /*pid*/, U64 res, U64 newLim, U64 oldLim) {
    if (oldLim) {
        // struct rlimit64 { __u64 rlim_cur; __u64 rlim_max; }
        if (res == K_RLIMIT_NOFILE) {
            cpu->memory->writeq(oldLim, K_RLIMIT_NOFILE_CUR);
            cpu->memory->writeq(oldLim + 8, K_RLIMIT_NOFILE_MAX);
        } else {
            cpu->memory->writeq(oldLim, ~0ULL);
            cpu->memory->writeq(oldLim + 8, ~0ULL);
        }
    }
    (void)newLim;
    return 0;
}

// clock_gettime(clk, struct timespec*). Returns wall-clock from the host so
// glibc gets monotonically advancing values.
static U64 sys_clock_gettime64(CPU64* cpu, U64 /*clk*/, U64 tsAddr) {
    if (!tsAddr) return (U64)-K_EFAULT;
    U64 us = KSystem::getSystemTimeAsMicroSeconds();
    U64 sec = us / 1000000ULL;
    U64 nsec = (us % 1000000ULL) * 1000ULL;
    cpu->memory->writeq(tsAddr, sec);
    cpu->memory->writeq(tsAddr + 8, nsec);
    return 0;
}

// read/write/open/close — wired to the existing 32-bit KProcess FD table via
// a bounce buffer. The kobject->readNative path is host-pointer, so the
// 64-bit guest address never has to flow through the 32-bit memory layer.
// Reads from fd 0 still return 0 (EOF) so apps that probe stdin don't hang.
static U64 sys_read64(CPU64* cpu, U64 fd, U64 buf, U64 count) {
    if (fd == 0) return 0;
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    KFileDescriptorPtr fdesc = cpu->thread->process->getFileDescriptor((FD)fd);
    if (!fdesc) return (U64)-9; // -EBADF
    if (!fdesc->canRead()) return (U64)-K_EINVAL;
    if (count == 0) return 0;
    // Cap to a reasonable per-call size — ld-linux reads in 4KB-64KB chunks.
    if (count > (1ULL << 20)) count = 1ULL << 20;
    std::vector<U8> tmp((size_t)count);
    // BW64_WSREAD witness: for a wineserver (record-oriented, non-XWire) unix
    // socket, capture the recv-buffer fill before/after the read so the dump can
    // reveal a read that returns N>0 without the cursor advancing by N (a
    // re-read of the same request bytes — the suspected double-free driver).
    KUnixSocketObject* wsSock = nullptr;
    size_t recvBefore = 0;
    if (wsReadEnabled() && cpu->thread && cpu->thread->process) {
        KUnixSocketObject* us = dynamic_cast<KUnixSocketObject*>(fdesc->kobject.get());
        if (us && !us->isXWire()) { wsSock = us; recvBefore = us->debugRecvUsed(); }
    }
    // BW64_WSCONC concurrency witness: for a wineserver process, log this read
    // with the guest thread id. If two different thread ids show overlapping
    // reads of the SAME socket, wineserver is processing requests on >1 thread —
    // the teardown double-release race. We log the live thread count for pid so
    // ">1 thread for wineserver" is visible directly.
    bool wsConcThis = false;
    if (wsConcEnabled() && cpu->thread && cpu->thread->process &&
        cpu->thread->process->exe.contains("wineserver")) {
        KUnixSocketObject* us = dynamic_cast<KUnixSocketObject*>(fdesc->kobject.get());
        if (us && !us->isXWire()) {
            wsConcThis = true;
            int now = ++g_wsConcInflight;
            int prevMax = g_wsConcMax.load();
            while (now > prevMax && !g_wsConcMax.compare_exchange_weak(prevMax, now)) {}
            if (now > 1) {
                klog_fmt("WSCONC: %d host threads concurrently in wineserver socket read! pid=%d tid=%d fd=%d",
                         now, (int)cpu->thread->process->id, (int)cpu->thread->id, (int)fd);
            }
        }
    }
    // Serialize against sys_mmap64_file (and other reads) on the shared per-zip
    // stream — see g_fileReadMutex. A KFile read that repositions a zip's shared
    // unzFile must not interleave with another thread's read/mmap of the same zip.
    // ONLY lock for real files (KFile): a blocking socket/pipe read must NOT hold
    // this global lock or it stalls every other process's file reads (deadlock).
    U32 got;
    {
        std::shared_ptr<KFile> rkfile = std::dynamic_pointer_cast<KFile>(fdesc->kobject);
        if (rkfile) {
            std::lock_guard<std::mutex> lk(g_fileReadMutex);
            got = fdesc->kobject->readNative(tmp.data(), (U32)count);
        } else {
            got = fdesc->kobject->readNative(tmp.data(), (U32)count);
        }
    }
    if (wsConcThis) { --g_wsConcInflight; }
    if ((S32)got < 0) {
        return (U64)(S64)(S32)got; // sign-extend kernel errno
    }
    if (got > 0) {
        cpu->memory->memcpyToGuest(buf, tmp.data(), got);
    }
    if (wsSock) {
        size_t recvAfter = wsSock->debugRecvUsed();
        crashRingRecordRead('R', cpu->thread->process->id, (U32)fd, tmp.data(), got,
                            (U32)recvBefore, (U32)recvAfter);
    }
    if (getenv("BW64_IPCDUMP")) {
        // First bytes help identify wineserver reply headers vs pipe wakeup
        // bytes. BW64_IPCWIDE dumps up to 48 bytes so a select_reply's apc_call
        // body (past the 8-byte reply_header) is visible, not just the header.
        int cap = getenv("BW64_IPCWIDE") ? 48 : 16;
        char hex[160] = {0}; int n = (int)((got < (U32)cap) ? got : (U32)cap);
        for (int i = 0; i < n; i++) snprintf(hex + i*3, 4, "%02x ", tmp[i]);
        klog_fmt("IPC [pid=%d] read(fd=%d,count=%llu) -> %d  [%s]",
                 (int)cpu->thread->process->id, (int)fd,
                 (unsigned long long)count, (int)got, hex);
    }
    return (U64)got;
}

// openat(dirfd, path, flags, mode). For dirfd we honour AT_FDCWD (-100) and
// any "absolute" path. Relative paths against a real dirfd aren't supported
// yet — ld-linux always passes AT_FDCWD or absolute, so this covers the
// startup path.
#ifndef K_AT_FDCWD
#define K_AT_FDCWD (-100)
#endif
static U64 sys_openat64(CPU64* cpu, U64 dirfd, U64 pathAddr, U64 flags, U64 /*mode*/) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    if (!pathAddr) return (U64)-K_EFAULT;
    char path[1024] = {0};
    cpu->memory->memcpyFromGuest(path, pathAddr, sizeof(path) - 1);
    KProcess* process = cpu->thread->process.get();
    // /proc/self/exe (and /proc/<pid>/exe): the kernel exposes the executable as
    // a magic symlink. wine's loader open()s/realpath()s it to find its install
    // dir; redirect to the real backing file so it resolves to the loader path
    // instead of a bogus "/proc"-derived prefix. (readlink/readlinkat handle the
    // symlink-read form separately.)
    BString self = B("/proc/self/exe");
    BString selfPid = B("/proc/") + BString::valueOf(process->id) + B("/exe");
    if (self == path || selfPid == path) {
        std::memset(path, 0, sizeof(path));
        std::strncpy(path, process->exe.c_str(), sizeof(path) - 1);
    }
    // /proc/self/mounts and /proc/self/mountinfo: Apple libc's statfs->BSD
    // converter (statfs_linux_to_bsd64) opens these to fill f_mntonname /
    // f_fstypename for fstatfs(2). mldr's vchroot rewrites the path to the
    // PREFIXED form (e.g. /usr/libexec/darling/proc/self/mounts), and we only
    // register /proc/mounts at the bare path, so the prefixed open ENOENTs ->
    // fstatfs fails -> glob/fts ABANDONS the directory it just opened (the S17
    // wall: launchctl opendir's /System/Library/LaunchDaemons, fstatfs's the fd,
    // gets the error, and closes it WITHOUT readdir -> no daemon plists load ->
    // no services spawn). Redirect any path ENDING in proc/self/mounts[info] (or
    // proc/<pid>/...) to the bare global virtual file so the converter succeeds.
    {
        const char* p = path;
        size_t plen = std::strlen(p);
        auto endsWith = [&](const char* suf) {
            size_t sl = std::strlen(suf);
            return plen >= sl && std::strcmp(p + plen - sl, suf) == 0;
        };
        // Match the bare and vchroot-prefixed self/<pid> forms by suffix; only act
        // when the path is actually under a /proc/ tree.
        if (std::strstr(p, "/proc/") && (endsWith("/mountinfo") || endsWith("/mounts"))) {
            const char* target = endsWith("/mountinfo") ? "/proc/mountinfo" : "/proc/mounts";
            std::memset(path, 0, sizeof(path));
            std::strncpy(path, target, sizeof(path) - 1);
        }
    }
    // BW64_DLLPATH: trace the loader's DLL/dir search for the failing first
    // process — logs every path that mentions the wine install dir, system32,
    // or a builtin DLL, so we can see WHICH search dirs ntdll constructs (the
    // bootstrap process never probes x86_64-windows -> "could not load kernel32").
    if (getenv("BW64_DLLPATH") && (strstr(path, "wine") || strstr(path, "system32") ||
                                   strstr(path, "x86_64-windows"))) {
        klog_fmt("DLLPATH pid=%d openat('%s') flags=0x%llx", (int)process->id, path,
                 (unsigned long long)flags);
    }
    bool isAbs = (path[0] == '/');
    if (!isAbs && (S32)dirfd != K_AT_FDCWD) {
        klog_fmt("sys_openat64: relative path '%s' with dirfd=%d not yet supported",
                 path, (int)(S32)dirfd);
        return (U64)-2;
    }
    KFileDescriptorPtr result;
    U32 rc = process->openFile(process->currentDirectory, BString::copy(path),
                               (U32)flags, result);
    if ((S32)rc < 0) {
        if (getenv("BW64_DLLTRACE") && (strstr(path, ".dll") || strstr(path, ".exe") ||
                                        strstr(path, "x86_64-windows") || strstr(path, "kernel32"))) {
            klog_fmt("DLLTRACE pid=%d FAIL open('%s') rc=%d cwd='%s'",
                     (int)process->id, path, (int)(S32)rc, process->currentDirectory.c_str());
        } else if (getenv("BW64_SCDUMP")) {
            BString full = Fs::getFullPath(process->currentDirectory, BString::copy(path));
            klog_fmt("sys_openat64: open('%s') -> %d  [cwd='%s' full='%s' flags=0x%llx]",
                     path, (int)(S32)rc, process->currentDirectory.c_str(), full.c_str(),
                     (unsigned long long)flags);
        } else {
            klog_fmt("sys_openat64: open('%s') -> %d", path, (int)(S32)rc);
        }
        return (U64)(S64)(S32)rc;
    }
    if (getenv("BW64_DLLTRACE") && (strstr(path, ".dll") || strstr(path, ".exe") ||
                                    strstr(path, "x86_64-windows") || strstr(path, "x86_64-unix"))) {
        klog_fmt("DLLTRACE pid=%d OPEN  '%s' -> fd %d", (int)process->id, path, (int)result->handle);
    }
    // BW64_DIRTRACE: log every O_DIRECTORY open (flags&0x10000) so we can see
    // exactly which directories the failing loader enumerates while hunting for
    // kernel32.dll, and whether the open itself succeeds.
    if (getenv("BW64_DIRTRACE") && ((flags & 0x10000) != 0)) {
        // Also resolve the node behind the new fd and report whether it's a
        // directory + its child count — so we can tell a real empty dir from a
        // mis-resolved node (the S17 LaunchDaemons wall: opendir succeeds but the
        // node carries 0 children / isn't a dir, so glob/readdir surfaces nothing).
        int isDir = -1; U32 childCount = 0; const char* nodePath = "?";
        std::shared_ptr<KFile> kf = std::dynamic_pointer_cast<KFile>(result->kobject);
        if (kf && kf->openFile && kf->openFile->node) {
            isDir = kf->openFile->node->isDirectory() ? 1 : 0;
            nodePath = kf->openFile->node->path.c_str();
            if (isDir) childCount = kf->openFile->getDirectoryEntryCount();
        }
        klog_fmt("DIRTRACE pid=%d OPENDIR '%s' -> fd %d (flags=0x%llx) node='%s' isDir=%d children=%u",
                 (int)process->id, path, (int)result->handle, (unsigned long long)flags,
                 nodePath, isDir, childCount);
    }
    // BW64_DIRTRACE: also log REGULAR-file opens of LaunchDaemons/LaunchAgents
    // plists — proves launchctl actually reads each daemon plist after the dir
    // listing (so a missing service-spawn is downstream at launchd's job_start
    // fork, not a readdir gap).
    if (getenv("BW64_DIRTRACE") && (strstr(path, "LaunchDaemons/") || strstr(path, "LaunchAgents/")) &&
        ((flags & 0x10000) == 0)) {
        klog_fmt("DIRTRACE pid=%d PLISTOPEN '%s' -> fd %d", (int)process->id, path, (int)result->handle);
    }
    // BW64_LDTRACE: log EVERY open of a Launch*/Library path (dir or file) with
    // its fd + O_DIRECTORY flag — so the glob reopen sequence (which fd maps to
    // which path) is unambiguous.
    if (getenv("BW64_LDTRACE") && (strstr(path, "Launch") || strstr(path, "Library"))) {
        klog_fmt("LDTRACE pid=%d open '%s' -> fd %d (O_DIR=%d)", (int)process->id, path,
                 (int)result->handle, (flags & 0x10000) ? 1 : 0);
    }
    // Feed the GUI loading screen's activity log: surface the meaningful things
    // wine loads during the boot storm (DLLs/EXEs, the graphics/font stack) so
    // the user can SEE what's loading instead of a stuck bar. Cheap string
    // checks; only fires while the loading screen is active (percent >= 0).
    if (KSystem::bootProgressPercent >= 0) {
        const char* base = strrchr(path, '/');
        base = base ? base + 1 : path;
        if (strstr(path, ".dll") || strstr(path, ".exe") ||
            strstr(path, "winex11") || strstr(path, "freetype") ||
            strstr(path, "fontconfig") || strstr(path, ".so")) {
            KSystem::noteBootLog(B("Loading ") + BString::copy(base));
        }
    }
    if (getenv("BW64_SCDUMP")) {
        // Log successful opens of the GUI driver modules so we can see whether
        // wine actually loads its x11 backend (winex11.so/.drv, win32u, the
        // display drivers) vs falling back to the null driver.
        if (strstr(path, "winex11") || strstr(path, "win32u") ||
            strstr(path, ".drv")    || strstr(path, "x11")) {
            klog_fmt("sys_openat64: OPENED '%s' -> fd %d", path, (int)result->handle);
        }
    }
    return (U64)result->handle;
}

static U64 sys_close64(CPU64* cpu, U64 fd) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    // BW64_SOCKDTOR: witness guest close() of a connected stream socket so we can
    // tell a LEGITIMATE close(2) (wine really closed the fd) from a SPURIOUS GC
    // (the object destructs while the fd is conceptually still open). Pairs with
    // the SOCKDTOR dtor witness — match the kobject pointer across both.
    if (std::getenv("BW64_SOCKDTOR")) {
        KFileDescriptorPtr fdesc = cpu->thread->process->getFileDescriptor((FD)fd);
        if (fdesc && fdesc->kobject && fdesc->kobject->type == KTYPE_UNIX_SOCKET) {
            // use_count BEFORE the close is the decisive A-vs-B signal:
            //   ==2 (this fdesc->kobject + the local fdesc copy held here) => this
            //        close drops the LAST process ref -> the object destructs now
            //        -> no other process's fd holds it => MODEL A (shared object).
            //   > 2 => another fd table still references the SAME object, so this
            //        close should NOT destruct it; the kill must be the peer-EOF
            //        cascade from the OTHER end's dtor => MODEL B (peer cascade).
            // (We hold one extra ref via `fdesc` here, so subtract it mentally:
            //  raw==2 means exactly one real holder remains = the fd being closed.)
            long uc = fdesc->kobject.use_count();
            KUnixSocketObject* us = dynamic_cast<KUnixSocketObject*>(fdesc->kobject.get());
            void* peer = nullptr;
            int peerIn = -1, peerOut = -1, peerConn = -1;
            int myIn = -1, myOut = -1, myConn = -1;
            if (us) {
                myIn = (int)us->inClosed; myOut = (int)us->outClosed; myConn = (int)us->connected;
                std::shared_ptr<KUnixSocketObject> con = us->connection.lock();
                if (con) {
                    peer = (void*)con.get();
                    peerIn = (int)con->inClosed; peerOut = (int)con->outClosed; peerConn = (int)con->connected;
                }
            }
            klog_fmt("SOCKCLOSE: pid=%d tid=%d close(fd=%llu) kobj=%p use_count=%ld(raw,-1=fdesc) "
                     "self{in=%d out=%d conn=%d} peer=%p peer{in=%d out=%d conn=%d}",
                     (int)cpu->thread->process->id, (int)cpu->thread->id,
                     (unsigned long long)fd, (void*)fdesc->kobject.get(),
                     uc, myIn, myOut, myConn, peer, peerIn, peerOut, peerConn);
        }
    }
    return (U64)(S64)(S32)cpu->thread->process->close((FD)fd);
}

// getdents64(fd, dirp, count) — read directory entries into the guest buffer
// in Linux struct linux_dirent64 layout:
//   u64 d_ino; s64 d_off; u16 d_reclen; u8 d_type; char d_name[]; (NUL-term)
// each record padded to 8 bytes. Mirrors KProcess::getdents' is64 path but
// writes through KMemory64 (the 32-bit version's dirp is a U32 address). The
// FsOpenNode file pointer tracks how far we've iterated, so successive calls
// page through the directory and a final call returns 0 (end).
static U64 sys_getdents64_real(CPU64* cpu, U64 fd, U64 dirp, U64 count) {
    // NULL buffer is EFAULT regardless of process state (matches the kernel
    // contract and the existing self-test, which runs with no real process).
    if (!dirp) return (U64)-K_EFAULT;
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    bool dt = getenv("BW64_DIRTRACE") != nullptr;
    int dtpid = (int)cpu->thread->process->id;
    KFileDescriptorPtr fdesc = cpu->thread->process->getFileDescriptor((FD)fd);
    if (!fdesc) { if (dt) klog_fmt("DIRTRACE pid=%d getdents64 fd=%llu -> EBADF (no fdesc)", dtpid, (unsigned long long)fd); return (U64)-9; } // -EBADF
    std::shared_ptr<KFile> kfile = std::dynamic_pointer_cast<KFile>(fdesc->kobject);
    if (!kfile || !kfile->openFile || !kfile->openFile->node) { if (dt) klog_fmt("DIRTRACE pid=%d getdents64 fd=%llu -> ENOTDIR (no kfile/openFile/node)", dtpid, (unsigned long long)fd); return (U64)-K_ENOTDIR; }
    FsOpenNode* openNode = kfile->openFile;
    if (!openNode->node->isDirectory()) { if (dt) klog_fmt("DIRTRACE pid=%d getdents64 path='%s' -> ENOTDIR (not a directory)", dtpid, openNode->node->path.c_str()); return (U64)-K_ENOTDIR; }

    U32 entries = openNode->getDirectoryEntryCount();
    U64 len = 0;
    U64 pos = dirp;
    // BW64_DIRTRACE: log each getdents64 directory's path, entry count, file
    // pointer (resume index), and whether kernel32.dll is among the names. The
    // residual "could not load kernel32.dll" failure loops openat(O_DIRECTORY)+
    // getdents64 over the wine builtin DLL dir — this proves whether the listing
    // actually surfaces kernel32.dll for the failing process.
    if (getenv("BW64_DIRTRACE")) {
        bool hasK32 = false; int found = 0;
        for (U32 j = 0; j < entries; j++) {
            BString nm; std::shared_ptr<FsNode> e = openNode->getDirectoryEntry(j, nm);
            if (!e) continue;
            found++;
            if (strcasecmp(nm.c_str(), "kernel32.dll") == 0) hasK32 = true;
        }
        klog_fmt("DIRTRACE pid=%d fd=%llu path='%s' entries=%u realFound=%d fp=%u kernel32=%d",
                 (int)cpu->thread->process->id, (unsigned long long)fd,
                 openNode->node->path.c_str(), entries, found,
                 (U32)openNode->getFilePointer(), hasK32 ? 1 : 0);
    }
    for (U32 i = (U32)openNode->getFilePointer(); i < entries; i++) {
        BString name;
        std::shared_ptr<FsNode> entry = openNode->getDirectoryEntry(i, name);
        if (!entry) continue;
        U32 nameLen = (U32)strlen(name.c_str());
        // d_ino(8) d_off(8) d_reclen(2) d_type(1) name(nameLen) NUL(1)
        U32 recordLen = 20 + nameLen;        // 19 header bytes + name + NUL, but
        recordLen = (recordLen + 7) / 8 * 8; // 8-byte aligned (d_off must align)
        if (len + recordLen > count) {
            if (len == 0) return (U64)-K_EINVAL; // buffer too small for one entry
            break;                                // resume here next call
        }
        cpu->memory->writeq(pos,      (U64)entry->id);       // d_ino
        cpu->memory->writeq(pos + 8,  (U64)(i + 1));         // d_off (next pos)
        cpu->memory->writew(pos + 16, (U16)recordLen);       // d_reclen
        cpu->memory->writeb(pos + 18, (U8)entry->getType(true)); // d_type
        cpu->memory->memcpyToGuest(pos + 19, name.c_str(), nameLen + 1); // name+NUL
        pos += recordLen;
        len += recordLen;
        openNode->seek(i + 1);
    }
    return len;
}

// lseek — wired straight to KObject::seek.
static U64 sys_lseek64(CPU64* cpu, U64 fd, U64 offset, U64 whence) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    KFileDescriptorPtr fdesc = cpu->thread->process->getFileDescriptor((FD)fd);
    if (!fdesc) return (U64)-9;
    S64 off = (S64)offset;
    S64 pos;
    if (whence == 0) { // SEEK_SET
        pos = fdesc->kobject->seek(off);
    } else if (whence == 1) { // SEEK_CUR
        pos = fdesc->kobject->getPos() + off;
        pos = fdesc->kobject->seek(pos);
    } else if (whence == 2) { // SEEK_END
        pos = fdesc->kobject->length() + off;
        pos = fdesc->kobject->seek(pos);
    } else {
        return (U64)-K_EINVAL;
    }
    return (U64)pos;
}

// pread64(fd, buf, count, offset) — read at an absolute offset without moving
// the file position. glibc's ld.so uses it to read a DSO's program headers
// before mmap. Emulated as save-pos/seek/read/restore over the KObject layer.
static U64 sys_pread64(CPU64* cpu, U64 fd, U64 buf, U64 count, U64 offset) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    KFileDescriptorPtr fdesc = cpu->thread->process->getFileDescriptor((FD)fd);
    if (!fdesc) return (U64)-9; // -EBADF
    if (!fdesc->canRead()) return (U64)-K_EINVAL;
    if (count == 0) return 0;
    if (count > (1ULL << 20)) count = 1ULL << 20;
    std::vector<U8> tmp((size_t)count);
    U32 got;
    // Same zip-stream hazard as sys_mmap64_file / sys_read64: this seek+read+seek
    // is unsynchronized, and wine's PE loader + glibc ld.so pread DLL/DSO headers
    // from the SHARED per-zip stream. Serialize file reads (KFile only — a
    // blocking socket pread must not hold the global lock). Without this, a
    // header pread races a concurrent mmap of the same zip entry and reads the
    // wrong bytes (the residual "could not load kernel32.dll" path after the
    // mmap/read serialization fixed the segment-map corruption).
    std::shared_ptr<KFile> pkfile = std::dynamic_pointer_cast<KFile>(fdesc->kobject);
    if (pkfile) {
        std::lock_guard<std::mutex> lk(g_fileReadMutex);
        S64 savedPos = fdesc->kobject->getPos();
        fdesc->kobject->seek((S64)offset);
        got = fdesc->kobject->readNative(tmp.data(), (U32)count);
        fdesc->kobject->seek(savedPos);
    } else {
        S64 savedPos = fdesc->kobject->getPos();
        fdesc->kobject->seek((S64)offset);
        got = fdesc->kobject->readNative(tmp.data(), (U32)count);
        fdesc->kobject->seek(savedPos);
    }
    if ((S32)got < 0) return (U64)(S64)(S32)got;
    if (got > 0) cpu->memory->memcpyToGuest(buf, tmp.data(), got);
    return (U64)got;
}

// pwrite64(fd, buf, count, offset) — write at an absolute offset without moving
// the file position. wineserver uses it to populate registry/config files in
// the prefix (it pwrite's records into the .reg/server files). Emulated as
// save-pos/seek/write/restore over the KObject layer, mirroring sys_pread64.
static U64 sys_pwrite64(CPU64* cpu, U64 fd, U64 buf, U64 count, U64 offset) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    KFileDescriptorPtr fdesc = cpu->thread->process->getFileDescriptor((FD)fd);
    if (!fdesc) return (U64)-9; // -EBADF
    if (!fdesc->canWrite()) return (U64)-K_EINVAL;
    if (count == 0) return 0;
    if (count > (1ULL << 20)) count = 1ULL << 20;
    std::vector<U8> tmp((size_t)count);
    cpu->memory->memcpyFromGuest(tmp.data(), buf, (U32)count);
    S64 savedPos = fdesc->kobject->getPos();
    fdesc->kobject->seek((S64)offset);
    U32 wrote = fdesc->kobject->writeNative(tmp.data(), (U32)count);
    fdesc->kobject->seek(savedPos);
    return (U64)(S64)(S32)wrote;
}

// writeStatBuf64 — write the x86-64 Linux struct stat (144 bytes) into
// guest memory. Field offsets match the canonical glibc/kernel layout for
// __NR_fstat / __NR_newfstatat result buffers on x86-64.
static void writeStatBuf64(KMemory64* mem, U64 addr, U64 size, U32 mode,
                            U64 ino, U32 uid, U32 gid, U64 mtime) {
    U8 buf[144];
    std::memset(buf, 0, sizeof(buf));
    auto put64 = [&](U32 off, U64 v) { std::memcpy(buf + off, &v, 8); };
    auto put32 = [&](U32 off, U32 v) { std::memcpy(buf + off, &v, 4); };
    put64(0,  1);             // st_dev (fake)
    put64(8,  ino);           // st_ino
    put64(16, 1);             // st_nlink
    put32(24, mode);          // st_mode
    put32(28, uid);           // st_uid
    put32(32, gid);           // st_gid
    put32(36, 0);             // __pad0
    put64(40, 0);             // st_rdev
    put64(48, size);          // st_size
    put64(56, 4096);          // st_blksize
    put64(64, (size + 511) / 512); // st_blocks (512-byte units)
    put64(72, mtime);         // st_atime
    put64(80, 0);
    put64(88, mtime);         // st_mtime
    put64(96, 0);
    put64(104, mtime);        // st_ctime
    put64(112, 0);
    mem->memcpyToGuest(addr, buf, sizeof(buf));
}

// Forward decl — sys_newfstatat64 may delegate to sys_fstat64 for AT_EMPTY_PATH.
static U64 sys_fstat64(CPU64* cpu, U64 fd, U64 statbuf);

// Path-based stat shared by stat/lstat/newfstatat. followSymlink controls
// the lstat vs stat distinction (Fs::getNodeFromLocalPath's third arg).
static U64 sys_stat_path64(CPU64* cpu, U64 pathAddr, U64 statbuf, bool followSymlink) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    if (!pathAddr || !statbuf) return (U64)-K_EFAULT;
    char path[1024] = {0};
    cpu->memory->memcpyFromGuest(path, pathAddr, sizeof(path) - 1);
    BString bpath = BString::copy(path);
    std::shared_ptr<FsNode> node = Fs::getNodeFromLocalPath(
        cpu->thread->process->currentDirectory, bpath, followSymlink);
    if (getenv("BW64_SYSTRACE")) {
        klog_fmt("sys_stat_path64: '%s' (cwd='%s') -> %s", path,
                 cpu->thread->process->currentDirectory.c_str(),
                 node ? "OK" : "ENOENT");
    }
    // BW64_LDTRACE: light trace of stat/lstat on LaunchDaemons/Library paths so we
    // can see whether glob lstats the literal `*.plist` pattern and our resolver
    // wrongly returns OK (-> glob treats it as a literal, skips readdir).
    if (getenv("BW64_LDTRACE") && (strstr(path, "Launch") || strstr(path, "Library"))) {
        klog_fmt("LDTRACE pid=%d %sstat '%s' -> %s", (int)cpu->thread->process->id,
                 followSymlink ? "" : "l", path, node ? "OK" : "ENOENT");
    }
    if (!node) return (U64)-2; // -ENOENT
    U64 size  = node->length();
    U32 mode  = node->getMode();
    U64 ino   = node->id;
    U64 mtime = node->lastModified() / 1000; // ms → seconds
    writeStatBuf64(cpu->memory, statbuf, size, mode, ino, 1000, 1000, mtime);
    return 0;
}

// newfstatat(dirfd, path, statbuf, flags). AT_EMPTY_PATH (0x1000) means
// "stat the dirfd itself"; AT_SYMLINK_NOFOLLOW (0x100) makes it lstat.
#ifndef K_AT_SYMLINK_NOFOLLOW
#define K_AT_SYMLINK_NOFOLLOW 0x100
#endif
#ifndef K_AT_EMPTY_PATH
#define K_AT_EMPTY_PATH 0x1000
#endif
static U64 sys_newfstatat64(CPU64* cpu, U64 dirfd, U64 pathAddr, U64 statbuf, U64 flags) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    if (!statbuf) return (U64)-K_EFAULT;
    // AT_EMPTY_PATH with NULL/"" path means stat the fd.
    if ((flags & K_AT_EMPTY_PATH) && (!pathAddr || cpu->memory->readb(pathAddr) == 0)) {
        return sys_fstat64(cpu, dirfd, statbuf);
    }
    // We only honour AT_FDCWD or absolute paths for now (matches openat).
    char path[1024] = {0};
    cpu->memory->memcpyFromGuest(path, pathAddr, sizeof(path) - 1);
    bool isAbs = (path[0] == '/');
    if (getenv("BW64_SYSTRACE")) {
        klog_fmt("sys_newfstatat64: dirfd=%d path='%s' flags=0x%llx",
                 (int)(S32)dirfd, path, (unsigned long long)flags);
    }
    if (!isAbs && (S32)dirfd != K_AT_FDCWD) {
        return (U64)-2;
    }
    return sys_stat_path64(cpu, pathAddr, statbuf, !(flags & K_AT_SYMLINK_NOFOLLOW));
}

static U64 sys_fstat64(CPU64* cpu, U64 fd, U64 statbuf) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    if (!statbuf) return (U64)-K_EFAULT;
    KFileDescriptorPtr fdesc = cpu->thread->process->getFileDescriptor((FD)fd);
    if (!fdesc) return (U64)-9; // -EBADF
    // Reach for the underlying KFile to ask the FsNode for metadata.
    std::shared_ptr<KFile> kfile = std::dynamic_pointer_cast<KFile>(fdesc->kobject);
    U64 size = 0;
    U32 mode = 0100644; // S_IFREG | 0644
    U64 ino = 0;
    U64 mtime = 0;
    if (kfile && kfile->openFile) {
        size = (U64)kfile->openFile->length();
        if (kfile->openFile->node) {
            mode  = kfile->openFile->node->getMode();
            ino   = kfile->openFile->node->id;
            mtime = (U64)kfile->openFile->node->lastModified();
        }
    } else {
        // Non-file kobject (socket/pipe): claim S_IFCHR so callers don't
        // assume seekable.
        mode = 0020666;
    }
    writeStatBuf64(cpu->memory, statbuf, size, mode, ino, 1000, 1000, mtime);
    return 0;
}

// File-backed mmap. Reads the requested file region into freshly mmap'd
// pages. Not lazy/COW — eager copy is simple and bounded for ld-linux's
// typical 200 KiB lib mapping.
static U64 sys_mmap64_file(CPU64* cpu, U64 addr, U64 length, U64 prot,
                           U64 flags, U64 fd, U64 offset) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    KFileDescriptorPtr fdesc = cpu->thread->process->getFileDescriptor((FD)fd);
    if (!fdesc) return (U64)-9; // -EBADF
    std::shared_ptr<KFile> kfile = std::dynamic_pointer_cast<KFile>(fdesc->kobject);
    if (!kfile || !kfile->openFile) {
        return (U64)-K_ENOSYS;
    }
    bool reserved = false;
    if (addr == 0) {
        // ld.so's DSO-span reservation (mmap(NULL, span, PROT_NONE, fd)) comes
        // through here; it MUST draw from the same process-wide cursor as
        // anonymous maps so the FIXED sub-segment maps that follow land on
        // disjoint, uncorrupted pages. Atomically reserve+map (closes the
        // MT TOCTOU race two sibling threads hit via the old scan-then-map).
        addr = cpu->memory->mmapReserveAndMap(length, (U32)prot);
        reserved = true; // pages already mapped under the lock; don't re-map/zero
    }
    U64 aligned = addr & ~0xFFFULL;
    U64 mapLen = (length + (addr - aligned) + 0xFFF) & ~0xFFFULL;
    bool dump = getenv("BW64_FMMAP") != nullptr;
    if (dump) {
        klog_fmt("FMMAP [pid=%d] addr=0x%llx aligned=0x%llx len=0x%llx mapLen=0x%llx "
                 "prot=0x%x flags=0x%x off=0x%llx fixed=%d file='%s'",
                 (int)(cpu->thread ? cpu->thread->process->id : -1),
                 (unsigned long long)addr, (unsigned long long)aligned,
                 (unsigned long long)length, (unsigned long long)mapLen,
                 (unsigned)prot, (unsigned)flags, (unsigned long long)offset,
                 (int)((flags & K_MAP_FIXED) != 0),
                 kfile->openFile->node ? kfile->openFile->node->path.c_str() : "?");
    }
    // MAP_SHARED file mapping that must be GENUINELY shared across every process
    // that maps the same file: wine's server shared-memory section
    // (/run/user/.../wine/server-1-*/* incl. tmpmap-*) — wineserver maps it
    // WRITABLE and writes object/sequence state; the CLIENTS map the SAME file
    // (e.g. KUSER_SHARED_DATA at 0x7ffe0000) and read those writes directly. A
    // private read-copy would give each process a stale snapshot and desync the
    // section. So that file's pages must alias ONE shared backing buffer.
    //
    // CRUCIAL: this aliasing is ONLY correct for files that hold genuinely
    // process-shared state. It is WRONG for PE image sections. wine maps a DLL's
    // read-only sections (.text/.rdata) with MAP_SHARED too, but then loads the
    // image at a PER-PROCESS base and calls relocate_image, which mprotects those
    // sections writable and patches absolute addresses by THIS process's load
    // delta. If two processes share the backing, the second process's relocation
    // overwrites the first's already-relocated bytes (with a different delta), so
    // the first process then reads doubly/wrongly-relocated pointers — garbage
    // IAT/function pointers, a wild indirect call into low memory, and the
    // downstream wineserver "corrupted double-linked list"/release_object crash.
    // So restrict the shared-backing divert to the wineserver server-section
    // files; every other MAP_SHARED file map (PE images, .nls, etc.) falls
    // through to the private per-process read-copy below, which is correct
    // because each process relocates its own copy.
    bool serverSection = false;
    if (kfile->openFile->node) {
        const char* p = kfile->openFile->node->path.c_str();
        // The wine server runtime dir is .../wine/server-<disp>-<inst>/...
        if (strstr(p, "/wine/server-") || strstr(p, "/server-1-") ||
            strstr(p, "tmpmap")) {
            serverSection = true;
        }
    }
    if (serverSection && (flags & K_MAP_SHARED) && kfile->openFile->node && !reserved) {
        // Seed bytes for any page of this file not yet in the registry.
        std::vector<U8> seedBuf((size_t)mapLen, 0);
        U64 fileBase = offset & ~0xFFFULL;
        S64 savedFp = kfile->openFile->getFilePointer();
        kfile->openFile->seek((S64)fileBase);
        kfile->openFile->readNative(seedBuf.data(), (U32)mapLen);
        kfile->openFile->seek(savedFp);
        U64 r = cpu->memory->mmapSharedFile(aligned, mapLen, (U32)prot,
                                            kfile->openFile->node->path.c_str(),
                                            fileBase, seedBuf.data(), (U64)seedBuf.size());
        if ((S64)r < 0) return r;
        if (ripSamplerEnabled() && kfile->openFile->node) {
            ripSamplerNoteModule((int)cpu->thread->process->id, aligned, mapLen,
                                 kfile->openFile->node->path.c_str());
        }
        return addr;
    }
    // The page that contains `addr` may already hold valid bytes from a PRIOR
    // overlapping mapping of the SAME DSO (glibc maps the first PT_LOAD over the
    // whole span, then MAP_FIXED-remaps later segments whose file offset is not
    // page-aligned — so [aligned, addr) is the tail of the previous segment).
    // mmapAnonymousFixed ZEROES whole pages, so a blind zero here wipes that
    // tail and never refills it (we only read file content into [addr, ...)),
    // corrupting live code/data. Preserve the leading partial-page bytes across
    // the (re)map: snapshot [aligned, addr) before, restore after.
    // For a FIXED map (addr supplied by ld.so) the target pages may already hold
    // valid bytes from a PRIOR overlapping mapping of the SAME DSO (glibc maps
    // the first PT_LOAD over the whole span, then MAP_FIXED-remaps later segments
    // whose file offset is not page-aligned — so [aligned, addr) is the tail of
    // the previous segment). mmapAnonymousFixed ZEROES whole pages, so a blind
    // zero wipes that tail and never refills it (we only read file content into
    // [addr, ...)), corrupting live code/data. Preserve the partial-page head &
    // tail across the (re)map. SKIPPED when `reserved`: mmapReserveAndMap already
    // mapped a fresh, disjoint range under the lock — nothing to preserve.
    if (!reserved) {
        U64 head = addr - aligned;
        std::vector<U8> headSave;
        if (head > 0 && cpu->memory->isPageMapped(aligned >> 12)) {
            headSave.resize((size_t)head);
            cpu->memory->memcpyFromGuest(headSave.data(), aligned, head);
            if (dump) klog_fmt("FMMAP   preserving 0x%llx head bytes at 0x%llx",
                               (unsigned long long)head, (unsigned long long)aligned);
        }
        U64 fileEnd = addr + length;
        U64 mapEnd  = aligned + mapLen;
        U64 tail = (mapEnd > fileEnd) ? (mapEnd - fileEnd) : 0;
        std::vector<U8> tailSave;
        if (tail > 0 && cpu->memory->isPageMapped((fileEnd) >> 12)) {
            tailSave.resize((size_t)tail);
            cpu->memory->memcpyFromGuest(tailSave.data(), fileEnd, tail);
        }
        U64 mapped = cpu->memory->mmapAnonymousFixed(aligned, mapLen, (U32)prot);
        if ((S64)mapped < 0) {
            return mapped;
        }
        if (!headSave.empty()) cpu->memory->memcpyToGuest(aligned, headSave.data(), head);
        if (!tailSave.empty()) cpu->memory->memcpyToGuest(fileEnd, tailSave.data(), tail);
    }
    // Read [offset, offset+length) and copy into [addr, addr+length).
    // MT-CRITICAL: the seek()+readNative()+seek() sequence is THREE separate calls
    // that must not interleave with another thread's file read. For zip-backed
    // files (wine's DLLs live in wine64.zip) every FsZipOpenNode shares ONE
    // underlying decompression stream (FsZip::zipfile) plus its position state;
    // readNative only locks its own body, so when two wine processes mmap the same
    // DLL concurrently on separate host threads their seek/read interleave and
    // each reads from the OTHER's file position — splattering e.g. winex11.drv's
    // MZ header (file offset 0) over its .text/.data/IAT -> corrupted IAT pointers
    // -> a wild indirect call into low memory (RIP=0x10270) -> "could not load
    // kernel32.dll" -> cascading wineserver heap corruption. A process-global lock
    // across the whole seek+read+restore makes each file-mmap read atomic. DLL
    // loading is not perf-critical, so the serialization cost is acceptable.
    std::vector<U8> buf((size_t)length);
    U32 got;
    {
        std::lock_guard<std::mutex> lk(g_fileReadMutex);
        S64 saved = kfile->openFile->getFilePointer();
        kfile->openFile->seek((S64)offset);
        got = kfile->openFile->readNative(buf.data(), (U32)length);
        kfile->openFile->seek(saved);
    }
    // BW64_MAPWATCH=0xADDR: log every file-mmap that lands in [ADDR, ADDR+0x20000)
    // with its file offset — to catch a segment being (re)mapped from the WRONG
    // file offset (e.g. offset 0 = the MZ header splattered over .text/.data/IAT).
    {
        static const char* mw = std::getenv("BW64_MAPWATCH");
        if (mw) {
            U64 wa = std::strtoull(mw, nullptr, 0);
            if (addr < wa + 0x20000 && addr + length > wa) {
                U64 f8 = 0; if (got >= 8) std::memcpy(&f8, buf.data(), 8);
                klog_fmt("MAPWATCH pid=%d addr=0x%llx len=0x%llx offset=0x%llx prot=0x%x flags=0x%x got=%u first8=0x%llx file='%s'",
                         (int)cpu->thread->process->id, (unsigned long long)addr,
                         (unsigned long long)length, (unsigned long long)offset, (unsigned)prot,
                         (unsigned)flags, got, (unsigned long long)f8,
                         kfile->openFile->node ? kfile->openFile->node->path.c_str() : "?");
            }
        }
    }
    if (got > 0) {
        cpu->memory->memcpyToGuest(addr, buf.data(), got);
    }
    (void)flags;
    // BW64_RIPSAMPLE: record this DSO/PE segment so a sampled spinning RIP can be
    // resolved to file+offset. This is where wine's x86_64-unix .so halves (where
    // the C code that busy-loops lives) become known. Use the same aligned/mapLen
    // span the BW64_FMMAP trace prints above.
    if (ripSamplerEnabled() && kfile->openFile->node) {
        ripSamplerNoteModule((int)cpu->thread->process->id, aligned, mapLen,
                             kfile->openFile->node->path.c_str());
    }
    return addr;
}

// writev — iterate the iovec array, calling write per segment. Each iovec
// entry on x86-64 is { u64 base; u64 len }.
static U64 sys_writev64(CPU64* cpu, U64 fd, U64 iov, U64 iovcnt) {
    U64 total = 0;
    for (U64 i = 0; i < iovcnt; i++) {
        U64 base = cpu->memory->readq(iov + i * 16 + 0);
        U64 len  = cpu->memory->readq(iov + i * 16 + 8);
        if (len == 0) continue;
        S64 wrote = (S64)sys_write64(cpu, fd, base, len);
        if (wrote < 0) {
            return total > 0 ? total : (U64)wrote;
        }
        total += (U64)wrote;
        if ((U64)wrote < len) break; // short write
    }
    return total;
}

// readv(fd, iov, iovcnt) — scatter read. Mirror sys_writev64: walk the
// 64-bit iovec array (struct iovec is {void* base; size_t len} = 16 bytes
// on x86-64) and read into each segment via sys_read64. Stop on the first
// short read (fewer bytes than the segment asked for) — that's EOF / no
// more data right now, same as the kernel. Returns total bytes read, or
// the first segment's error if nothing was read. wine/wineserver read
// server replies through readv, so a missing impl silently breaks the IPC
// reply path (was -ENOSYS).
static U64 sys_readv64(CPU64* cpu, U64 fd, U64 iov, U64 iovcnt) {
    U64 total = 0;
    for (U64 i = 0; i < iovcnt; i++) {
        U64 base = cpu->memory->readq(iov + i * 16 + 0);
        U64 len  = cpu->memory->readq(iov + i * 16 + 8);
        if (len == 0) continue;
        S64 got = (S64)sys_read64(cpu, fd, base, len);
        if (got < 0) {
            return total > 0 ? total : (U64)got;
        }
        total += (U64)got;
        if ((U64)got < len) break; // short read: EOF / drained
    }
    return total;
}

// Read a NUL-terminated guest C-string at addr from 64-bit memory. Bounded so a
// missing terminator can't loop forever; argv/env strings and paths are well
// under this. Reads in small chunks to avoid a huge fixed stack buffer.
static BString readGuestString64(CPU64* cpu, U64 addr) {
    if (!addr) return BString();
    std::string s;
    const U64 MAX = 64 * 1024;
    while (s.size() < MAX) {
        char chunk[256];
        cpu->memory->memcpyFromGuest(chunk, addr, sizeof(chunk));
        U32 n = 0;
        for (; n < sizeof(chunk); n++) {
            if (chunk[n] == 0) { s.append(chunk, n); return BString::copy(s.c_str()); }
        }
        s.append(chunk, sizeof(chunk));
        addr += sizeof(chunk);
    }
    return BString::copy(s.c_str());
}

// Walk a NULL-terminated array of 64-bit guest pointers (argv / envp) and read
// each pointed-to C-string. The 64-bit ABI passes 8-byte pointers (unlike the
// 32-bit execve's 4-byte readd walk).
static void readStringArray64(CPU64* cpu, U64 arrayAddr, std::vector<BString>& out) {
    if (!arrayAddr) return;
    const U32 MAX_ENTRIES = 4096;
    for (U32 i = 0; i < MAX_ENTRIES; i++) {
        U64 p = cpu->memory->readq(arrayAddr);
        if (!p) break;
        arrayAddr += 8;
        out.push_back(readGuestString64(cpu, p));
    }
}

// execve(path, argv, envp) for 64-bit guests. wine64 re-execs itself and spawns
// wineserver64 through this. Marshals the 8-byte-pointer argv/envp arrays out of
// memory64, then drives the shared KProcess::execve, which resets memory and
// re-runs the loader (ElfLoader::loadProgram routes ELF64 -> loadProgram64,
// rebuilding memory64/cpu64 fresh — see KProcess::execve's 64-bit reset). On
// success execve never returns to the caller (the image is replaced); it returns
// -K_CONTINUE which the dispatcher must NOT write into RAX.
static U64 sys_execve64(CPU64* cpu, U64 pathAddr, U64 argvAddr, U64 envpAddr) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    if (!pathAddr) return (U64)-K_EFAULT;
    BString path = readGuestString64(cpu, pathAddr);
    // BW64_RIPSAMPLE: a re-exec replaces this pid's address space, so its old
    // module ranges would mis-attribute the next image's RIPs. Drop them; the
    // new image's segment maps re-populate the table.
    ripSamplerClearPid((int)cpu->thread->process->id);
    std::vector<BString> args;
    std::vector<BString> envs;
    readStringArray64(cpu, argvAddr, args);
    readStringArray64(cpu, envpAddr, envs);
    klog_fmt("sys_execve64: pid=%d path='%s' argv0='%s' argc=%d envc=%d",
             (int)(cpu->thread && cpu->thread->process ? cpu->thread->process->id : -1),
             path.c_str(),
             args.empty() ? "" : args[0].c_str(), (int)args.size(), (int)envs.size());
    // Full argv dump — invaluable for telling which wine subprocess (wineboot/
    // services.exe/rpcss/plugplay/explorer) is being launched in the re-exec
    // chain; the bare argv0 ('/usr/lib/wine/wine64') is identical for all of them.
    if (getenv("BW64_SYSTRACE") || getenv("BW64_EXECDUMP")) {
        for (size_t i = 1; i < args.size(); i++)
            klog_fmt("sys_execve64:   argv[%d]='%s'", (int)i, args[i].c_str());
    }
    for (auto& e : envs) {
        if (strncmp(e.c_str(), "WINELOADER=", 11) == 0)
            klog_fmt("sys_execve64:   env %s", e.c_str());
        if (getenv("BW64_ENVDUMP"))
            klog_fmt("sys_execve64:   ENV %s", e.c_str());
    }
    // Drive the GUI loading-screen progress: the wine boot chain re-execs
    // wine64 with the next PE in argv (e.g. ".../services.exe", "winedevice.exe",
    // the target "notepad.exe"). Feed each .exe basename to the boot-stage
    // tracker so the XWire present tick can render a labeled progress bar until
    // the guest paints its real window.
    for (auto& a : args) {
        if (a.contains(".exe")) { KSystem::noteBootStage(a); break; }
    }
    return (U64)(S64)(S32)cpu->thread->process->execve(cpu->thread, path, args, envs);
}

// readlink(path, buf, bufsize) — resolve a symlink. /proc/self/exe is the
// big-ticket caller for glibc startup; everything else falls back to the
// FsNode link field if present.
static U64 sys_readlink64(CPU64* cpu, U64 pathAddr, U64 buf, U64 sz) {
    if (!cpu->thread || !cpu->thread->process) return (U64)-K_ENOSYS;
    if (!pathAddr || !buf || sz == 0) return (U64)-K_EFAULT;
    char path[1024] = {0};
    cpu->memory->memcpyFromGuest(path, pathAddr, sizeof(path) - 1);
    if (getenv("BW64_LDTRACE") && (strstr(path, "Launch") || strstr(path, "Library"))) {
        klog_fmt("LDTRACE pid=%d readlink '%s'", (int)cpu->thread->process->id, path);
    }
    KProcess* proc = cpu->thread->process.get();
    BString pidExe = B("/proc/") + BString::valueOf(proc->id) + B("/exe");
    BString resolved;
    // The kernel's /proc magic symlinks. glibc/wine's realpath() walks
    // /proc/self/exe component-by-component, so we must resolve BOTH the
    // intermediate /proc/self (-> the numeric pid dir) and the terminal
    // .../exe (-> the executable's real path). Without /proc/self resolving,
    // realpath bails and wine derives a bogus "/proc"-based install dir.
    // /proc/{self,thread-self,<pid>}/fd/<n> -> the real path of open fd <n>.
    // darlingserver resolves the vchroot directory fd this way
    // (setVchrootDirectory: readlink("/proc/self/fd/<n>")). Without this the
    // vchroot path is empty, mldr expands every guest path against "" and
    // launchd's `execv("/sbin/launchd")` opens the bare (nonexistent) path and
    // dies. Accept self / thread-self / our own numeric pid as the proc dir.
    const char* fdTail = nullptr;
    if (std::strncmp(path, "/proc/self/fd/", 14) == 0) {
        fdTail = path + 14;
    } else if (std::strncmp(path, "/proc/thread-self/fd/", 21) == 0) {
        fdTail = path + 21;
    } else {
        BString pidFdPrefix = B("/proc/") + BString::valueOf(proc->id) + B("/fd/");
        if (std::strncmp(path, pidFdPrefix.c_str(), pidFdPrefix.length()) == 0) {
            fdTail = path + pidFdPrefix.length();
        }
    }
    if (fdTail && fdTail[0]) {
        char* end = nullptr;
        long n = std::strtol(fdTail, &end, 10);
        if (end && *end == '\0' && n >= 0) {
            KFileDescriptorPtr fd = proc->getFileDescriptor((FD)n);
            if (fd && fd->kobject) {
                resolved = fd->kobject->selfFd();
            } else {
                return (U64)-K_ENOENT;
            }
        } else {
            return (U64)-22; // -EINVAL
        }
    } else if (std::strcmp(path, "/proc/self") == 0 || std::strcmp(path, "/proc/thread-self") == 0) {
        resolved = BString::valueOf(proc->id);                 // relative target, like Linux
    } else if (std::strcmp(path, "/proc/self/exe") == 0 ||
               std::strcmp(path, "/proc/thread-self/exe") == 0 ||
               pidExe == path) {
        resolved = proc->exe;
    } else {
        std::shared_ptr<FsNode> n = Fs::getNodeFromLocalPath(
            proc->currentDirectory, BString::copy(path), false);
        if (!n || !n->isLink()) return (U64)-22; // -EINVAL on non-symlink
        resolved = n->link;
    }
    U64 toCopy = (U64)resolved.length();
    if (toCopy > sz) toCopy = sz;
    cpu->memory->memcpyToGuest(buf, resolved.c_str(), toCopy);
    return toCopy;
}

// Futex with real per-address waiter bookkeeping.
//
// We still cannot truly block (no KThread64 yet), so WAIT returns -EAGAIN
// even when the word matches. But we DO count would-block events per
// address in cpu->futexWaiters, and WAKE drains up to `val` of them and
// returns the count actually drained — matching the kernel's "number
// woken" semantics. The difference from the old stub:
//
//   - A WAKE that follows a WAIT-on-match now returns 1, not 0, which
//     lets glibc's condvar fast path see that its broadcast wasn't a
//     no-op (the old behaviour caused some __pthread_cond_signal paths
//     to loop forever calling FUTEX_WAKE expecting >0).
//   - Waiter counts are addressable per `uaddr`, so WAKE on one futex
//     does not spuriously claim to wake waiters on another.
//
// Storage is freed automatically when count drops to 0 (erase from map).
// Map lives on CPU64 so it's process-scoped — exactly what FUTEX_PRIVATE
// expects. When multi-thread support lands, the map moves to KProcess64
// with no shape change.
//
//   WAIT / WAIT_BITSET (+ _PRIVATE): read 32-bit word at uaddr; if
//       != val return -EAGAIN immediately. If == val, bump waiter count
//       and ALSO return -EAGAIN (would-block placeholder). The bumped
//       count is consumed by the next WAKE on the same address.
//   WAKE / WAKE_BITSET (+ _PRIVATE): drain min(val, count) from the
//       waiter slot for uaddr and return that drain count.
//   REQUEUE / CMP_REQUEUE / WAKE_OP: 0 (no kernel-side migration yet).
//   Anything else: -ENOSYS so glibc takes the user-space fallback.
//
// uaddr==0 → -EFAULT for all ops (matches kernel).
static U64 sys_futex64(CPU64* cpu, U64 uaddr, U32 op, U32 val, U64 timeoutAddr, U32 val3) {
    if (uaddr == 0) return (U64)-K_EFAULT;

    // Real path: when this CPU64 is driven by a scheduled KThread inside a
    // process (the only way multiple threads exist), delegate to the shared
    // futex table so WAIT actually blocks and WAKE actually wakes siblings.
    if (cpu->thread && cpu->thread->process && cpu->thread->process->memory64) {
        S64 r = cpu->thread->futex64(uaddr, op, val, timeoutAddr, val3);
        if (r == K_FUTEX64_PARKED) {
            // Single-threaded cooperative park: don't write RAX, rewind the
            // SYSCALL on yield so it re-runs after we're woken.
            cpu->reExecuteSyscall = true;
            cpu->yield = true;
            return cpu->reg[X64_RAX].u64; // unused; RAX left intact
        }
        return (U64)r;
    }

    // Threadless fallback for --x64-run-elf / selftest: no real thread to
    // park, so keep the would-block bookkeeping stub (records WAIT-on-match
    // so a later WAKE reports a non-zero count, letting glibc's condvar fast
    // path make forward progress single-threaded).
    U32 baseOp = op & ~(X64_FUTEX_PRIVATE_FLAG | X64_FUTEX_CLOCK_REALTIME);
    switch (baseOp) {
        case X64_FUTEX_WAKE:
        case X64_FUTEX_WAKE_BITSET: {
            auto it = cpu->futexWaiters.find(uaddr);
            if (it == cpu->futexWaiters.end()) return 0;
            U32 toDrain = it->second < val ? it->second : val;
            it->second -= toDrain;
            if (it->second == 0) cpu->futexWaiters.erase(it);
            return toDrain;
        }
        case X64_FUTEX_WAIT:
        case X64_FUTEX_WAIT_BITSET: {
            if (!cpu->memory) return (U64)-K_EFAULT;
            U32 cur = cpu->memory->readd(uaddr);
            if (cur != val) return (U64)-K_EAGAIN;
            cpu->futexWaiters[uaddr] += 1;
            return (U64)-K_EAGAIN;
        }
        case X64_FUTEX_REQUEUE:
        case X64_FUTEX_CMP_REQUEUE:
        case X64_FUTEX_WAKE_OP:
            return 0;
        default:
            return (U64)-K_ENOSYS;
    }
}

// rt_sigtimedwait(set, info, timeout, sigsetsize) — block till a signal in
// `set` arrives or `timeout` elapses. With no delivery implemented, the
// only correct non-hanging answer is -EAGAIN (timeout). Validate sigsetsize
// for the standard 8-byte mask first.
static U64 sys_rt_sigtimedwait64(CPU64* /*cpu*/, U64 setPtr, U64 /*infoPtr*/,
                                  U64 /*timeoutPtr*/, U64 sigsetsize) {
    if (sigsetsize != 8) return (U64)-K_EINVAL;
    if (setPtr == 0) return (U64)-K_EFAULT;
    // No signals pending; timeout result.
    return (U64)-K_EAGAIN;
}

// rt_sigsuspend(mask, sigsetsize) — replace mask, sleep till signal, restore.
// With no delivery, returning -EINTR forces glibc to retry the surrounding
// loop (correct for poll/select-on-signal idioms).
static U64 sys_rt_sigsuspend64(CPU64* /*cpu*/, U64 maskPtr, U64 sigsetsize) {
    if (sigsetsize != 8) return (U64)-K_EINVAL;
    if (maskPtr == 0) return (U64)-K_EFAULT;
    return (U64)-K_EINTR;
}

// rt_sigpending(set, sigsetsize) — write currently-pending signal mask.
// Nothing is ever pending in our world; write zeros and succeed.
static U64 sys_rt_sigpending64(CPU64* cpu, U64 setPtr, U64 sigsetsize) {
    if (sigsetsize != 8) return (U64)-K_EINVAL;
    if (setPtr == 0) return (U64)-K_EFAULT;
    if (!cpu->memory) return (U64)-K_EFAULT;
    cpu->memory->writeq(setPtr, 0);
    return 0;
}

// rt_sigaction(2) — storage-only round-trip. We do not yet deliver signals
// to guest handlers (that needs the signal-frame builder of Milestone B),
// but glibc's startup *registers* SIGFPE/SIGSEGV/SIGPIPE handlers very
// early and later queries them; previously this was a bald no-op so the
// second sigaction(SIG, NULL, &old) call always reported SIG_DFL, which
// confuses libpthread's "did the user install a handler?" check.
//
// x86-64 `struct kernel_sigaction` layout (32 bytes):
//   off  0: sa_handler  (8)
//   off  8: sa_flags    (8)
//   off 16: sa_restorer (8)
//   off 24: sa_mask     (8, = full sigset_t on x86-64)
//
// Signal numbers 1..64 are valid; SIGKILL(9) and SIGSTOP(19) can be queried
// but cannot have their handlers changed — we accept the read and silently
// drop the write, matching kernel behaviour.
static U64 sys_rt_sigaction64(CPU64* cpu, U64 sig, U64 actPtr, U64 oldActPtr,
                              U64 sigsetsize) {
    if (sig < 1 || sig > 64) return (U64)-K_EINVAL;
    if (sigsetsize != 8) return (U64)-K_EINVAL; // x86-64 sigset_t is 8 bytes
    if (!cpu->memory) return (U64)-K_EFAULT;

    CPU64::SigAction& slot = cpu->sigActions[sig];

    if (oldActPtr) {
        cpu->memory->writeq(oldActPtr + 0,  slot.installed ? slot.handler  : 0);
        cpu->memory->writeq(oldActPtr + 8,  slot.installed ? slot.flags    : 0);
        cpu->memory->writeq(oldActPtr + 16, slot.installed ? slot.restorer : 0);
        cpu->memory->writeq(oldActPtr + 24, slot.installed ? slot.mask     : 0);
    }

    if (actPtr) {
        if (sig == 9 || sig == 19) {
            // SIGKILL / SIGSTOP: read accepted, write ignored — matches Linux.
            return 0;
        }
        slot.handler  = cpu->memory->readq(actPtr + 0);
        slot.flags    = cpu->memory->readq(actPtr + 8);
        slot.restorer = cpu->memory->readq(actPtr + 16);
        slot.mask     = cpu->memory->readq(actPtr + 24);
        slot.installed = true;
    }
    return 0;
}

// rt_sigprocmask(2) — storage-only round-trip, paired with rt_sigaction
// above. how=SIG_BLOCK(0)/SIG_UNBLOCK(1)/SIG_SETMASK(2). v1 enforces nothing
// at delivery time (no delivery yet) but lets pthread_sigmask round-trip
// without losing state, which libpthread queries during thread init.
#define X64_SIG_BLOCK   0
#define X64_SIG_UNBLOCK 1
#define X64_SIG_SETMASK 2

static U64 sys_rt_sigprocmask64(CPU64* cpu, U64 how, U64 setPtr, U64 oldSetPtr,
                                U64 sigsetsize) {
    if (sigsetsize != 8) return (U64)-K_EINVAL;
    if (!cpu->memory) return (U64)-K_EFAULT;

    if (oldSetPtr) {
        cpu->memory->writeq(oldSetPtr, cpu->sigMask);
    }
    if (setPtr) {
        U64 incoming = cpu->memory->readq(setPtr);
        // SIGKILL(9) and SIGSTOP(19) can never be blocked — strip them
        // from any incoming mask to match kernel behaviour.
        U64 kernelStrip = (1ULL << (9 - 1)) | (1ULL << (19 - 1));
        incoming &= ~kernelStrip;
        switch (how) {
            case X64_SIG_BLOCK:   cpu->sigMask |=  incoming; break;
            case X64_SIG_UNBLOCK: cpu->sigMask &= ~incoming; break;
            case X64_SIG_SETMASK: cpu->sigMask  =  incoming; break;
            default: return (U64)-K_EINVAL;
        }
    }
    return 0;
}

// sigaltstack(2) — storage-only round-trip, completes the sig{action,
// procmask, altstack} trio. Layout of stack_t on x86-64 (24 bytes):
//   off  0: ss_sp    (8)
//   off  8: ss_flags (4)
//   off 12: pad      (4)
//   off 16: ss_size  (8)
//
// Kernel rules we honour here:
//   - If oldss != NULL, write the current state first.
//   - If ss != NULL with SS_DISABLE(2): clear the registration.
//   - If ss != NULL otherwise: ss_flags must be 0 (or SS_AUTODISARM=0x80000000)
//     and ss_size must be >= MINSIGSTKSZ (~2048). Reject otherwise.
//   - Cannot change altstack while currently executing on it (SS_ONSTACK
//     flag set). We don't track that yet, so the check is skipped.
#define X64_SS_ONSTACK     1
#define X64_SS_DISABLE     2
#define X64_SS_AUTODISARM  0x80000000u
#define X64_MINSIGSTKSZ    2048

static U64 sys_sigaltstack64(CPU64* cpu, U64 ssPtr, U64 oldSsPtr) {
    if (!cpu->memory) return (U64)-K_EFAULT;

    if (oldSsPtr) {
        cpu->memory->writeq(oldSsPtr + 0,  cpu->sigAltStack.ssSp);
        cpu->memory->writed(oldSsPtr + 8,  cpu->sigAltStack.ssFlags);
        cpu->memory->writed(oldSsPtr + 12, 0);
        cpu->memory->writeq(oldSsPtr + 16, cpu->sigAltStack.ssSize);
    }

    if (ssPtr) {
        U64 sp    = cpu->memory->readq(ssPtr + 0);
        U32 flags = cpu->memory->readd(ssPtr + 8);
        U64 size  = cpu->memory->readq(ssPtr + 16);

        if (flags & X64_SS_DISABLE) {
            cpu->sigAltStack.ssSp    = 0;
            cpu->sigAltStack.ssFlags = X64_SS_DISABLE;
            cpu->sigAltStack.ssSize  = 0;
        } else {
            U32 allowed = X64_SS_AUTODISARM;
            if (flags & ~allowed) return (U64)-K_EINVAL;
            if (size < X64_MINSIGSTKSZ) return (U64)-K_ENOMEM;
            cpu->sigAltStack.ssSp    = sp;
            cpu->sigAltStack.ssFlags = flags;
            cpu->sigAltStack.ssSize  = size;
        }
    }
    return 0;
}

// sched_getaffinity(2): glibc + libgomp probe this very early to decide thread
// pool sizes. We expose exactly one CPU. The Linux signature is unusual:
//   ssize_t sched_getaffinity(pid_t pid, size_t cpusetsize, cpu_set_t *mask)
// On success returns the number of bytes the kernel actually wrote (clamped
// to cpusetsize, but must be a multiple of sizeof(long)=8). cpusetsize must
// be a multiple of sizeof(long) and >= 8.
//
// We write 8 bytes (one U64 with bit 0 set) and return 8. Userspace then
// counts the bits to get nproc, which is exactly what we want it to see.
static U64 sys_sched_getaffinity64(CPU64* cpu, U64 pid, U64 cpusetsize, U64 maskPtr) {
    (void)pid; // ignore — we model one process
    if (cpusetsize == 0 || (cpusetsize & 7)) return (U64)-K_EINVAL;
    if (!maskPtr) return (U64)-K_EFAULT;
    if (!cpu->memory) return (U64)-K_EFAULT;

    // Write 1 in the low qword (CPU 0 is in our affinity set), zero the rest
    // up to cpusetsize. Userspace inspects only the bytes the kernel wrote
    // (which is our return value), so 8 bytes is enough.
    cpu->memory->writeq(maskPtr, 1);
    for (U64 off = 8; off < cpusetsize && off < 1024; off += 8) {
        cpu->memory->writeq(maskPtr + off, 0);
    }
    return 8;
}

// sched_setaffinity(2): silently accept any mask — we don't actually move
// the thread anywhere, but reject obviously bogus calls.
static U64 sys_sched_setaffinity64(CPU64* cpu, U64 pid, U64 cpusetsize, U64 maskPtr) {
    (void)cpu; (void)pid; (void)maskPtr;
    if (cpusetsize == 0 || (cpusetsize & 7)) return (U64)-K_EINVAL;
    return 0;
}

// statfs(2) / fstatfs(2) — fixed-shape stub. Layout of x86-64 struct statfs
// (120 bytes, all fields long-sized):
//   off  0: f_type        off 56: f_fsid (8)
//   off  8: f_bsize       off 64: f_namelen
//   off 16: f_blocks      off 72: f_frsize
//   off 24: f_bfree       off 80: f_flags
//   off 32: f_bavail      off 88..119: f_spare[4]
//   off 40: f_files
//   off 48: f_ffree
//
// glibc's dynamic loader probes statfs("/proc"), the system's ld.so.cache
// directory, etc. The load-bearing fields are f_type (to know "is this
// tmpfs/proc/etc?"), f_bsize (cache alignment), and f_namelen (path
// canonicalisation). We claim tmpfs (0x01021994) with 4096-byte blocks
// and 255-byte filenames, zero free/total — glibc tolerates the lie.
#define X64_TMPFS_MAGIC 0x01021994

static U64 sys_statfs64_common(CPU64* cpu, U64 bufPtr) {
    if (!bufPtr) return (U64)-K_EFAULT;
    if (!cpu->memory) return (U64)-K_EFAULT;
    cpu->memory->writeq(bufPtr +  0, X64_TMPFS_MAGIC); // f_type
    cpu->memory->writeq(bufPtr +  8, 4096);            // f_bsize
    cpu->memory->writeq(bufPtr + 16, 0);               // f_blocks
    cpu->memory->writeq(bufPtr + 24, 0);               // f_bfree
    cpu->memory->writeq(bufPtr + 32, 0);               // f_bavail
    cpu->memory->writeq(bufPtr + 40, 0);               // f_files
    cpu->memory->writeq(bufPtr + 48, 0);               // f_ffree
    cpu->memory->writeq(bufPtr + 56, 0);               // f_fsid
    cpu->memory->writeq(bufPtr + 64, 255);             // f_namelen
    cpu->memory->writeq(bufPtr + 72, 4096);            // f_frsize
    cpu->memory->writeq(bufPtr + 80, 0);               // f_flags
    cpu->memory->writeq(bufPtr + 88, 0);
    cpu->memory->writeq(bufPtr + 96, 0);
    cpu->memory->writeq(bufPtr + 104, 0);
    cpu->memory->writeq(bufPtr + 112, 0);
    return 0;
}

// ============================================================================
// Signal-frame layout (Linux x86-64 rt_sigframe / ucontext_t).
// ============================================================================
//
// When the kernel delivers a signal it pushes this structure on the user
// stack and sets RIP = handler, RDI = signo, RSI = &siginfo, RDX = &uctx.
// rt_sigreturn(15) reverses it: read the saved cpu state out of the frame
// at the current RSP and restore.
//
// We use the Linux-glibc layout so any handler compiled for x86-64 Linux
// can read it directly. Field offsets and sizes:
//
//   off  +0   rt_sigframe header                       (8 bytes pretty + pad)
//             — actually just the saved restorer addr (8 bytes), kernel
//               relies on the handler to RET into it; we always set RIP
//               from the saved RIP in mcontext on sigreturn so the header
//               is informational only.
//   off  +8   siginfo_t (128 bytes)
//   off +136  ucontext_t
//      +0     uc_flags          (8)
//      +8     uc_link           (8)
//      +16    uc_stack          (24: ss_sp, ss_flags+pad, ss_size)
//      +40    uc_mcontext.gregs[23]  — see gregs index table below
//                                       (23 * 8 = 184 bytes)
//      +224   uc_mcontext.fpregs (8 — pointer; we set 0 → no FPU restore)
//      +232   uc_mcontext.__reserved[8]  (64 bytes — zeroed)
//      +296   uc_sigmask        (8 — single qword, rest of 128-byte sigset
//                                    region is zero-padded)
//      +424   __fpregs_mem      (we don't write this for now)
//
// Total frame size we allocate on the stack: 16-aligned, round up to 1024.
// (Linux's actual frame is ~600 bytes with fpregs_mem; we shrink because
// we never populate fpregs.)
//
// gregs[] index, matching <sys/ucontext.h> REG_* enum:
//   0:R8   1:R9   2:R10  3:R11  4:R12  5:R13  6:R14  7:R15
//   8:RDI  9:RSI 10:RBP 11:RBX 12:RDX 13:RAX 14:RCX 15:RSP
//  16:RIP 17:EFL 18:CSGSFS 19:ERR 20:TRAPNO 21:OLDMASK 22:CR2
#define X64_SIGFRAME_SIZE          1024
#define X64_UCONTEXT_OFF_IN_FRAME  136   // after siginfo
#define X64_MCONTEXT_OFF_IN_UCTX    40
#define X64_GREGS_OFF_IN_UCTX       X64_MCONTEXT_OFF_IN_UCTX
#define X64_SIGMASK_OFF_IN_UCTX    296

// Indices into mcontext.gregs[23].
enum X64Greg {
    X64_GREG_R8 = 0, X64_GREG_R9, X64_GREG_R10, X64_GREG_R11,
    X64_GREG_R12, X64_GREG_R13, X64_GREG_R14, X64_GREG_R15,
    X64_GREG_RDI, X64_GREG_RSI, X64_GREG_RBP, X64_GREG_RBX,
    X64_GREG_RDX, X64_GREG_RAX, X64_GREG_RCX, X64_GREG_RSP,
    X64_GREG_RIP, X64_GREG_EFL, X64_GREG_CSGSFS, X64_GREG_ERR,
    X64_GREG_TRAPNO, X64_GREG_OLDMASK, X64_GREG_CR2,
};

// Build a signal frame on the stack at `framePtr` capturing cpu's full
// gpr/rflags/rip/sigmask state. Caller has already aligned the stack and
// reserved X64_SIGFRAME_SIZE bytes. Returns the address of the ucontext_t
// within the frame (handler receives this as RDX).
static U64 buildSignalFrame(CPU64* cpu, U64 framePtr) {
    // Zero the entire frame first (siginfo, padding, gaps).
    for (U64 i = 0; i < X64_SIGFRAME_SIZE; i += 8) {
        cpu->memory->writeq(framePtr + i, 0);
    }
    U64 uctxPtr   = framePtr + X64_UCONTEXT_OFF_IN_FRAME;
    U64 mctxPtr   = uctxPtr  + X64_MCONTEXT_OFF_IN_UCTX;
    U64 gregsPtr  = mctxPtr; // gregs starts at mcontext
    // uc_stack: copy the registered altstack so the handler can re-arm if needed.
    cpu->memory->writeq(uctxPtr + 16, cpu->sigAltStack.ssSp);
    cpu->memory->writed(uctxPtr + 24, cpu->sigAltStack.ssFlags);
    cpu->memory->writeq(uctxPtr + 32, cpu->sigAltStack.ssSize);
    // gregs[]
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_R8,  cpu->reg[X64_R8].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_R9,  cpu->reg[X64_R9].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_R10, cpu->reg[X64_R10].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_R11, cpu->reg[X64_R11].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_R12, cpu->reg[X64_R12].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_R13, cpu->reg[X64_R13].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_R14, cpu->reg[X64_R14].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_R15, cpu->reg[X64_R15].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_RDI, cpu->reg[X64_RDI].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_RSI, cpu->reg[X64_RSI].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_RBP, cpu->reg[X64_RBP].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_RBX, cpu->reg[X64_RBX].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_RDX, cpu->reg[X64_RDX].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_RAX, cpu->reg[X64_RAX].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_RCX, cpu->reg[X64_RCX].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_RSP, cpu->reg[X64_RSP].u64);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_RIP, cpu->rip);
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_EFL, (U64)cpu->rflags);
    // CSGSFS: low 16 = CS (we don't model segments → 0x33 USER_CS),
    //         next 16 = GS, next 16 = FS, top 16 = ss. Approximate.
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_CSGSFS,
                        (U64)0x33 | ((U64)0x2B << 48));
    // ERR/TRAPNO/CR2 = 0 (no fault triggered this delivery). A hardware-fault
    // delivery overwrites these afterwards via the fault-info it has.
    // OLDMASK = caller's sigmask before this delivery (we set it to current)
    cpu->memory->writeq(gregsPtr + 8 * X64_GREG_OLDMASK, cpu->sigMask);
    // fpregs pointer = 0 (we don't snapshot XMM/x87 here yet — the next
    // increment after delivery wiring lands)
    cpu->memory->writeq(mctxPtr + 184, 0);
    // uc_sigmask
    cpu->memory->writeq(uctxPtr + X64_SIGMASK_OFF_IN_UCTX, cpu->sigMask);
    return uctxPtr;
}

// Restore cpu state from a signal frame whose ucontext_t lives at the
// current RSP. The kernel's invariant after rt_sigreturn is that RSP
// points one byte *past* the saved-rsp slot (i.e. the frame has been
// popped); we read everything we need, then write cpu->rip and cpu->reg
// values en masse. mcontext lives at RSP + (X64_MCONTEXT_OFF_IN_UCTX).
//
// Returns 0 on success, negative errno otherwise. The kernel actually
// returns the saved RAX as the syscall result so the user code sees the
// pre-signal RAX restored; we mirror that by writing RAX last and
// signalling "skip the normal RAX-as-return-value path" via a special
// sentinel (the caller checks cpu->yield).
static U64 restoreSignalFrame(CPU64* cpu, U64 uctxPtr) {
    U64 mctxPtr   = uctxPtr + X64_MCONTEXT_OFF_IN_UCTX;
    U64 gregsPtr  = mctxPtr;
    cpu->reg[X64_R8].u64  = cpu->memory->readq(gregsPtr + 8 * X64_GREG_R8);
    cpu->reg[X64_R9].u64  = cpu->memory->readq(gregsPtr + 8 * X64_GREG_R9);
    cpu->reg[X64_R10].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_R10);
    cpu->reg[X64_R11].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_R11);
    cpu->reg[X64_R12].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_R12);
    cpu->reg[X64_R13].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_R13);
    cpu->reg[X64_R14].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_R14);
    cpu->reg[X64_R15].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_R15);
    cpu->reg[X64_RDI].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_RDI);
    cpu->reg[X64_RSI].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_RSI);
    cpu->reg[X64_RBP].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_RBP);
    cpu->reg[X64_RBX].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_RBX);
    cpu->reg[X64_RDX].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_RDX);
    cpu->reg[X64_RCX].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_RCX);
    cpu->reg[X64_RSP].u64 = cpu->memory->readq(gregsPtr + 8 * X64_GREG_RSP);
    cpu->rip              = cpu->memory->readq(gregsPtr + 8 * X64_GREG_RIP);
    cpu->rflags           = (U32)cpu->memory->readq(gregsPtr + 8 * X64_GREG_EFL);
    cpu->sigMask          = cpu->memory->readq(uctxPtr   + X64_SIGMASK_OFF_IN_UCTX);
    // RAX is restored last — the kernel returns RAX as the syscall return
    // value so the user-visible RAX is the *pre-signal* value, not whatever
    // rt_sigreturn would compute.
    U64 savedRax = cpu->memory->readq(gregsPtr + 8 * X64_GREG_RAX);
    return savedRax;
}

// SA_ONSTACK = 0x08000000 in glibc's <bits/sigaction.h>. When set, the
// handler runs on the registered sigaltstack instead of the user stack.
#define X64_SA_ONSTACK   0x08000000

// Synchronously deliver `sig` to `cpu` (the same thread). Models the
// kernel's "queue a signal that's pending immediately" path for the
// single-thread case — i.e. raise(), abort(), pthread_kill(self,...).
//
// Caller has already validated the signal number and confirmed that
// cpu->sigActions[sig].installed && handler is a real function pointer
// (not SIG_DFL/SIG_IGN).
//
// Mechanics:
//   1. Pick the frame stack: altstack if SA_ONSTACK set and altstack is
//      live, otherwise current RSP minus a redzone (128 bytes per SysV).
//   2. Round down to 16-byte alignment, subtract frame size.
//   3. Build the ucontext_t at frame_base via buildSignalFrame.
//   4. Set cpu->reg[X64_RSP] = frame_base, RIP = handler, RDI = sig,
//      RSI = 0 (no siginfo), RDX = &uctx, R10 = 0, R8/R9 = 0.
//   5. Mask the signal in cpu->sigMask for the duration of handler
//      execution (kernel adds sig to mask unless SA_NODEFER set).
//   6. The handler ends with `ret`-to-restorer or `syscall(rt_sigreturn)`,
//      which (a) hits our rt_sigreturn case → restoreSignalFrame → state
//      restored, including sigMask.
//
// Returns true on successful delivery (handler will run next), false if
// the handler slot is not installed / is SIG_DFL/SIG_IGN.
static bool deliverSignalSync(CPU64* cpu, U32 sig) {
    if (sig < 1 || sig > 64) return false;
    CPU64::SigAction& sa = cpu->sigActions[sig];
    if (!sa.installed) return false;
    if (sa.handler == 0 /*SIG_DFL*/ || sa.handler == 1 /*SIG_IGN*/) return false;

    // Pick stack: SA_ONSTACK requires a non-DISABLED altstack.
    U64 baseSp;
    if ((sa.flags & X64_SA_ONSTACK) && cpu->sigAltStack.ssSp != 0 &&
        (cpu->sigAltStack.ssFlags & 2 /*SS_DISABLE*/) == 0) {
        baseSp = cpu->sigAltStack.ssSp + cpu->sigAltStack.ssSize;
    } else {
        baseSp = cpu->reg[X64_RSP].u64 - 128; // red zone
    }
    // 16-align then reserve the frame.
    U64 frameBase = (baseSp - X64_SIGFRAME_SIZE) & ~(U64)15;

    U64 uctxPtr = buildSignalFrame(cpu, frameBase);

    // x86-64 signal-frame ABI: the kernel pushes the restorer address *below*
    // the ucontext so the handler's terminating `ret` pops it and jumps to
    // the restorer. The restorer then issues `syscall rt_sigreturn` with RSP
    // pointing at the ucontext (== uctxPtr). Without this, the handler's
    // `ret` pops the first qword of ucontext as garbage and crashes.
    U64 retSlot = uctxPtr - 8;
    cpu->memory->writeq(retSlot, sa.restorer);

    // Mask the signal during handler execution (unless SA_NODEFER=0x40000000).
    if ((sa.flags & 0x40000000) == 0) {
        cpu->sigMask |= (1ULL << (sig - 1));
    }
    cpu->sigMask |= sa.mask;

    // Hand off to the handler. RSP points at restorer_addr so `ret` pops it
    // and leaves RSP = uctxPtr, which is what rt_sigreturn expects.
    cpu->reg[X64_RSP].setU64(retSlot);
    cpu->reg[X64_RDI].setU64(sig);      // arg1: signal number
    cpu->reg[X64_RSI].setU64(0);        // arg2: siginfo (we don't synth one)
    cpu->reg[X64_RDX].setU64(uctxPtr);  // arg3: ucontext pointer
    cpu->rip = sa.handler;

    return true;
}

// Deliver one pending, unmasked, installed async signal queued on this thread by
// a cross-thread tkill/tgkill. Called by the scheduler at the start of the
// thread's slice (the thread is parked, so building a frame on its CPU64 is
// safe). At most one per call — the handler runs, and any further pending
// signals are taken on subsequent slices (after rt_sigreturn unmasks). Returns
// true if a signal was delivered.
bool CPU64::deliverPendingSignals() {
    if (!this->thread) return false;
    U64 pending;
    {
        BOXEDWINE_CRITICAL_SECTION_WITH_MUTEX(this->thread->pendingSignalsMutex);
        pending = this->thread->pendingSignals & ~this->sigMask;
    }
    if (!pending) return false;
    for (U32 sig = 1; sig <= 64; sig++) {
        U64 bit = 1ULL << (sig - 1);
        if (!(pending & bit)) continue;
        // Only consume the bit if we can actually deliver it (a handler is
        // installed). If it's SIG_DFL/IGN/uninstalled, leave it pending — for
        // the wineserver SIGUSR1-APC case the handler is always installed by the
        // time wineserver signals the client; an undeliverable signal shouldn't
        // be silently dropped here.
        if (deliverSignalSync(this, sig)) {
            BOXEDWINE_CRITICAL_SECTION_WITH_MUTEX(this->thread->pendingSignalsMutex);
            this->thread->pendingSignals &= ~bit;
            return true;
        }
    }
    return false;
}

// Synchronously deliver a hardware-trap-derived signal (SIGFPE on #DE,
// SIGSEGV on a page fault, ...) at the faulting instruction. Unlike
// deliverSignalSync (used for raise()/tgkill self), this synthesizes a real
// siginfo and fills the mcontext TRAPNO/ERR/CR2 so wine's (and glibc's)
// signal handlers see a genuine fault — wine's setup_raise_exception maps
// SIGFPE + si_code → EXCEPTION_INT_DIVIDE_BY_ZERO etc, and uses the ucontext
// RIP as the exception address. cpu->rip must still point at the faulting
// instruction when this is called (so the captured RIP is the fault site).
bool CPU64::raiseSyncFault(U32 sig, U32 trapNo, S32 siCode, U64 faultAddr) {
    if (sig < 1 || sig > 64) return false;
    SigAction& sa = this->sigActions[sig];
    if (!sa.installed) return false;
    if (sa.handler == 0 /*SIG_DFL*/ || sa.handler == 1 /*SIG_IGN*/) return false;

    U64 baseSp;
    if ((sa.flags & X64_SA_ONSTACK) && this->sigAltStack.ssSp != 0 &&
        (this->sigAltStack.ssFlags & 2 /*SS_DISABLE*/) == 0) {
        baseSp = this->sigAltStack.ssSp + this->sigAltStack.ssSize;
    } else {
        baseSp = this->reg[X64_RSP].u64 - 128; // red zone
    }
    U64 frameBase = (baseSp - X64_SIGFRAME_SIZE) & ~(U64)15;

    U64 uctxPtr = buildSignalFrame(this, frameBase);

    // Fill the fault-specific mcontext slots the generic builder leaves zero.
    U64 gregsPtr = uctxPtr + X64_MCONTEXT_OFF_IN_UCTX;
    this->memory->writeq(gregsPtr + 8 * X64_GREG_TRAPNO, (U64)trapNo);
    this->memory->writeq(gregsPtr + 8 * X64_GREG_ERR, 0);
    this->memory->writeq(gregsPtr + 8 * X64_GREG_CR2, faultAddr);

    // Synthesize a siginfo_t at the start of the frame (the siginfo region sits
    // before the ucontext at X64_UCONTEXT_OFF_IN_FRAME). Layout (x86-64):
    //   int si_signo @0; int si_errno @4; int si_code @8; then the union,
    //   where the SIGFPE/SIGSEGV variant places void* si_addr @16.
    U64 siPtr = frameBase;
    this->memory->writed(siPtr + 0, sig);
    this->memory->writed(siPtr + 4, 0);
    this->memory->writed(siPtr + 8, (U32)siCode);
    this->memory->writeq(siPtr + 16, faultAddr);

    U64 retSlot = uctxPtr - 8;
    this->memory->writeq(retSlot, sa.restorer);

    if ((sa.flags & 0x40000000) == 0) {
        this->sigMask |= (1ULL << (sig - 1));
    }
    this->sigMask |= sa.mask;

    this->reg[X64_RSP].setU64(retSlot);
    this->reg[X64_RDI].setU64(sig);        // arg1: signal number
    this->reg[X64_RSI].setU64(siPtr);      // arg2: siginfo*
    this->reg[X64_RDX].setU64(uctxPtr);    // arg3: ucontext*
    this->rip = sa.handler;
    return true;
}

// --- 64-bit socket address bounce -------------------------------------------
// The socket object layer (kbind/kconnect/kaccept/kgetsockname and their
// KSocketObject methods) reads the guest sockaddr through `thread->memory` —
// the 32-bit KMemory. For a 64-bit process that memory is allocated but unused
// (the real address space is memory64), so the sockaddr the guest passed lives
// in memory64, not where the object layer looks. sockaddr_un/_in are pointer-
// free (identical layout 32/64), so rather than duplicate every object method
// we BOUNCE: copy the sockaddr bytes out of memory64 into a small scratch page
// in the 32-bit KMemory, then call the existing 32-bit k* socket helper with
// that scratch address. This reuses all the bind/connect/accept/handshake logic
// unchanged. The scratch page is mmap'd once per process (lazily) and reused.
//
// Returns the 32-bit scratch address holding `len` bytes copied from `src64`,
// or 0 on failure. `outLenAddr` (optional) gets a 4-byte slot holding `len`
// for the helpers that take a pointer-to-socklen_t.
// The scratch must be PER THREAD, not per process: each KProcess has its own
// 32-bit KMemory (so an address mmap'd in one process is unmapped in another —
// the forked wine64 client vs. wineserver), AND sibling THREADS of one process
// share that KMemory but run concurrently. A single per-process scratch is
// clobbered when two threads do socket calls at once (services.exe spawns a
// clone3 worker thread that hammers wineserver alongside the main thread) —
// the result is a malformed request that corrupts wineserver's heap ("unsorted
// double linked list"). So cache (threadId -> addr) and mmap a fresh region the
// first time each thread needs one. KThread::id is unique and stable.
static std::unordered_map<U32, U32> g_socketScratchByThread;
static BOXEDWINE_MUTEX g_scratchMutex;
static U32 bounceSockaddrTo32(CPU64* cpu, U64 src64, U32 len, U32* outLenAddr) {
    KThread* thread = cpu->thread;
    if (!thread || !thread->memory || !thread->process) return 0;
    if (len > 256) len = 256; // sockaddr_un is 110 bytes; cap defensively
    U32 addr;
    {
        BOXEDWINE_CRITICAL_SECTION_WITH_MUTEX(g_scratchMutex);
        auto it = g_socketScratchByThread.find(thread->id);
        if (it != g_socketScratchByThread.end()) {
            addr = it->second;
        } else {
            // One page is plenty for a sockaddr + a socklen_t slot.
            addr = thread->memory->mmap(thread, 0, K_PAGE_SIZE,
                K_PROT_READ | K_PROT_WRITE, K_MAP_ANONYMOUS | K_MAP_PRIVATE, -1, 0);
            if (!addr) return 0;
            g_socketScratchByThread[thread->id] = addr;
        }
    }
    if (src64 && len) {
        U8 tmp[256];
        cpu->memory->memcpyFromGuest(tmp, src64, len);
        thread->memory->memcpy(addr, tmp, len);
    }
    if (outLenAddr) {
        U32 lenSlot = addr + 256;
        thread->memory->writed(lenSlot, len);
        *outLenAddr = lenSlot;
    }
    return addr;
}

// Ensure a multi-page scratch region in the 64-bit process's (otherwise unused)
// 32-bit KMemory, big enough for a synthesized 32-bit msghdr + iovec + cmsg +
// a data buffer. Same per-process caching rationale as bounceSockaddrTo32.
// Layout within the region:
//   +0      : 32-bit msghdr (28 bytes: name,namelen,iov,iovlen,control,controllen,flags)
//   +32     : one 32-bit iovec {base,len}
//   +64     : cmsg area (up to a few SCM_RIGHTS fds)
//   +256    : socklen/len scratch
//   +512 .. : data buffer (region size - 512)
#define MSG_SCRATCH_BYTES   (64 * 1024)
#define MSG_SCRATCH_HDR     0
#define MSG_SCRATCH_IOV     32
#define MSG_SCRATCH_CMSG    64
#define MSG_SCRATCH_NAME    384   // sockaddr (msg_name) scratch; <=128 bytes, before DATA
#define MSG_SCRATCH_DATA    512
// Per-THREAD (see bounceSockaddrTo32's note): a per-process msg scratch is
// corrupted when sibling threads sendmsg/recvmsg concurrently.
static std::unordered_map<U32, U32> g_msgScratchByThread;
// BW64_S2C: armed by the first S2C RECV — once set, the syscall dispatcher logs
// every syscall this tid makes, so the post-S2C handler path (munmap+push_reply)
// is fully visible right up to the crash. 0 = disarmed.
int g_s2cTraceTid = 0;
// execve replaces the process address space, so any cached msg-scratch mmap for
// a thread of that process is now a dangling guest address. mldr re-execs ITSELF
// in-place (same pid/tid) when it loads the next Darwin image (e.g. vchroot ->
// launchd); without invalidation the post-exec sendmsg writes to the stale
// scratch -> "performOnMemory failed to get ram" + a garbled checkin send
// (BAD SEND LENGTH). KProcess::execve calls this to drop the stale entries.
void bw64_clearMsgScratchForThread(U32 threadId) {
    BOXEDWINE_CRITICAL_SECTION_WITH_MUTEX(g_scratchMutex);
    g_msgScratchByThread.erase(threadId);
    // bounceSockaddrTo32's per-thread scratch (g_socketScratchByThread) lives in
    // the same replaced 32-bit address space and must be dropped too, or a
    // post-exec connect/bind/getsockname writes the sockaddr family to the stale
    // page (addr=0xc0400000, len=2) and faults.
    g_socketScratchByThread.erase(threadId);
}
// Shared core of select(2)/pselect6(2): translate the three fd_set bitmaps into
// a pollfd array, run kpoll (our real readiness/blocking engine), then translate
// the revents back into freshly-zeroed fd_sets. timeoutMs follows kpoll's
// convention (0 == non-blocking, 0xFFFFFFFF == infinite). Returns the select
// contract: the number of ready bits across all sets, or a negative -errno.
//
// Both the BSD select (timeval timeout) and pselect6 (timespec timeout) cases
// funnel here after normalising their timeout to milliseconds, so neither can
// regress to the old ENOSYS stub — which is exactly what made launchd's
// kqueue_demand_loop (a blocking select(mainkq+1,...) with infinite timeout)
// busy-spin: select=-ENOSYS returned immediately every iteration, the cancelable
// select wrapper then fired __pthread_canceled(0) (dserver #31) each turn, and
// launchd never blocked to await/deliver a kqueue (bootstrap) event.
static S64 doSelect64(CPU64* cpu, U32 nfds, U64 rfdsAddr, U64 wfdsAddr,
                      U64 efdsAddr, U32 timeoutMs) {
    if (!cpu->thread || !cpu->thread->process || !cpu->thread->memory) {
        return -K_ENOSYS;
    }
    if (nfds > 1024) return -K_EINVAL;

    U32 setBytes = (nfds + 7) / 8;
    if (setBytes > 128) setBytes = 128;
    U8 rset[128] = {0}, wset[128] = {0}, eset[128] = {0};
    if (rfdsAddr) cpu->memory->memcpyFromGuest(rset, rfdsAddr, setBytes);
    if (wfdsAddr) cpu->memory->memcpyFromGuest(wset, wfdsAddr, setBytes);
    if (efdsAddr) cpu->memory->memcpyFromGuest(eset, efdsAddr, setBytes);

    auto isSet = [](const U8* s, U32 fd) { return (s[fd >> 3] >> (fd & 7)) & 1; };

    struct PFD { S32 fd; U16 ev; U16 rev; };
    PFD pfds[1024];
    U32 npoll = 0;
    for (U32 fd = 0; fd < nfds && npoll < 1024; fd++) {
        U16 ev = 0;
        if (rfdsAddr && isSet(rset, fd)) ev |= 0x0001; // POLLIN
        if (wfdsAddr && isSet(wset, fd)) ev |= 0x0004; // POLLOUT
        if (efdsAddr && isSet(eset, fd)) ev |= 0x0002; // POLLPRI
        if (ev) { pfds[npoll].fd = (S32)fd; pfds[npoll].ev = ev; pfds[npoll].rev = 0; npoll++; }
    }

    U32 scratch = bounceSockaddrTo32(cpu, 0, 0, nullptr);
    if (!scratch) return -K_EFAULT;
    S32 rc;
    if (npoll == 0) {
        rc = (S32)kpoll(cpu->thread, scratch, 0, timeoutMs);
    } else {
        U8 tmp[K_PAGE_SIZE] = {0};
        for (U32 i = 0; i < npoll; i++) {
            U8* e = tmp + i * 8;
            *(U32*)e = (U32)pfds[i].fd;
            *(U16*)(e + 4) = pfds[i].ev;
            *(U16*)(e + 6) = 0;
        }
        cpu->thread->memory->memcpy(scratch, tmp, npoll * 8);
        rc = (S32)kpoll(cpu->thread, scratch, npoll, timeoutMs);
        cpu->thread->memory->memcpy(tmp, scratch, npoll * 8);
        for (U32 i = 0; i < npoll; i++) pfds[i].rev = *(U16*)(tmp + i * 8 + 6);
    }
    if (rc < 0) return (S64)rc;

    U8 outR[128] = {0}, outW[128] = {0}, outE[128] = {0};
    U32 readyCount = 0;
    for (U32 i = 0; i < npoll; i++) {
        U32 fd = (U32)pfds[i].fd; U16 rev = pfds[i].rev;
        if (rfdsAddr && (rev & (0x0001 | 0x0010 /*POLLHUP*/ ))) { outR[fd>>3] |= (1<<(fd&7)); readyCount++; }
        if (wfdsAddr && (rev & 0x0004)) { outW[fd>>3] |= (1<<(fd&7)); readyCount++; }
        if (efdsAddr && (rev & (0x0002 | 0x0008 /*POLLERR*/))) { outE[fd>>3] |= (1<<(fd&7)); readyCount++; }
    }
    if (rfdsAddr) cpu->memory->memcpyToGuest(rfdsAddr, outR, setBytes);
    if (wfdsAddr) cpu->memory->memcpyToGuest(wfdsAddr, outW, setBytes);
    if (efdsAddr) cpu->memory->memcpyToGuest(efdsAddr, outE, setBytes);
    return (S64)readyCount;
}

static U32 msgScratch(KThread* thread) {
    if (!thread || !thread->memory || !thread->process) return 0;
    BOXEDWINE_CRITICAL_SECTION_WITH_MUTEX(g_scratchMutex);
    auto it = g_msgScratchByThread.find(thread->id);
    if (it != g_msgScratchByThread.end()) return it->second;
    U32 addr = thread->memory->mmap(thread, 0, MSG_SCRATCH_BYTES,
        K_PROT_READ | K_PROT_WRITE, K_MAP_ANONYMOUS | K_MAP_PRIVATE, -1, 0);
    if (!addr) return 0;
    g_msgScratchByThread[thread->id] = addr;
    return addr;
}

// 64-bit struct offsets (x86-64):
//   msghdr {name(0); namelen(8); iov(16); iovlen(24); control(32); controllen(40); flags(48)}  =56
//   iovec  {base(0); len(8)}                                                                    =16
//   cmsghdr{len(0,size_t); level(8,int); type(12,int); data(16)}
// 32-bit (what the socket object expects):
//   msghdr {name(0); namelen(4); iov(8); iovlen(12); control(16); controllen(20); flags(24)}
//   iovec  {base(0); len(4)}
//   cmsghdr{len(0); level(4); type(8); data(12)}  -- 16-byte stride in the object code

// sendmsg(fd, msghdr*, flags) for a 64-bit guest. Gathers the scatter buffers
// into one scratch blob, translates any SCM_RIGHTS cmsg, builds a 32-bit msghdr
// in scratch, and calls the 32-bit ksendmsg (reusing all the AF_UNIX queue +
// fd-passing logic).
static U64 sys_sendmsg64(CPU64* cpu, U64 fd, U64 msg64, U64 flags) {
    KThread* thread = cpu->thread;
    if (!thread || !thread->process) return (U64)-K_ENOSYS;
    U32 base = msgScratch(thread);
    if (!base) return (U64)-K_EFAULT;
    KMemory* m32 = thread->memory;

    U64 name    = cpu->memory->readq(msg64 + 0);
    U32 namelen = cpu->memory->readd(msg64 + 8);
    U64 iov     = cpu->memory->readq(msg64 + 16);
    U64 iovlen  = cpu->memory->readq(msg64 + 24);
    U64 control = cpu->memory->readq(msg64 + 32);
    U64 ctllen  = cpu->memory->readq(msg64 + 40);

    // Destination address (msg_name) — required for SOCK_DGRAM sendto-style sends
    // (e.g. darlingserver's mldr rpc checkin). Copy the sockaddr into scratch and
    // point the 32-bit msghdr at it; the layout is identical between 32/64-bit
    // (sa_family_t + path), so a byte copy is correct.
    U32 name32 = 0, namelen32 = 0;
    if (name && namelen) {
        if (namelen > 128) namelen = 128;
        std::vector<U8> nameTmp((size_t)namelen);
        cpu->memory->memcpyFromGuest(nameTmp.data(), name, namelen);
        m32->memcpy(base + MSG_SCRATCH_NAME, nameTmp.data(), namelen);
        name32 = base + MSG_SCRATCH_NAME;
        namelen32 = namelen;
    }

    // BW64_SMSG: dump the raw 64-bit msghdr + each iov segment BEFORE the gather,
    // so a send that faults mid-gather (an iov base pointing at unmapped guest
    // memory) is still fully captured. The dserver mach_msg_overwrite (#38) body
    // is built by libsystem_kernel's dserver_rpc_hooks_send_message; if any iov
    // base is bogus our memcpyFromGuest faults and the guest sees a short send
    // (the "BAD SEND LENGTH" assertion). Gated; the fd heuristic keeps it on the
    // dserver RPC sockets.
    bool smsg = getenv("BW64_SMSG") && fd >= 0x2000;
    if (smsg) {
        klog_fmt("SMSG pid=%d tid=%d fd=0x%llx HDR name=0x%llx namelen=%u iov=0x%llx iovlen=%llu control=0x%llx ctllen=%llu",
                 (int)(thread->process ? thread->process->id : -1), (int)thread->id,
                 (unsigned long long)fd, (unsigned long long)name, (unsigned)namelen,
                 (unsigned long long)iov, (unsigned long long)iovlen,
                 (unsigned long long)control, (unsigned long long)ctllen);
        for (U64 i = 0; i < iovlen && i < 8; i++) {
            U64 b = cpu->memory->readq(iov + 16 * i);
            U64 l = cpu->memory->readq(iov + 16 * i + 8);
            bool ok = b && cpu->memory->isPageMapped((U32)(b >> 12)) &&
                      cpu->memory->isPageMapped((U32)((b + (l ? l - 1 : 0)) >> 12));
            klog_fmt("SMSG   iov[%llu] base=0x%llx len=%llu mapped=%d",
                     (unsigned long long)i, (unsigned long long)b,
                     (unsigned long long)l, ok ? 1 : 0);
        }
    }

    // Gather all iov segments into the scratch data buffer.
    U32 dataAddr = base + MSG_SCRATCH_DATA;
    U32 total = 0;
    U32 dataCap = MSG_SCRATCH_BYTES - MSG_SCRATCH_DATA;
    for (U64 i = 0; i < iovlen; i++) {
        U64 b = cpu->memory->readq(iov + 16 * i);
        U64 l = cpu->memory->readq(iov + 16 * i + 8);
        if (l == 0) continue;
        if (total + l > dataCap) l = dataCap - total;
        if (l == 0) break;
        std::vector<U8> tmp((size_t)l);
        cpu->memory->memcpyFromGuest(tmp.data(), b, (U32)l);
        m32->memcpy(dataAddr + total, tmp.data(), (U32)l);
        total += (U32)l;
    }

    // BW64_LAUNCHMSG: log every non-trivial sendmsg on a low (non-dserver) guest
    // socket fd, so a launchd-socket submit is visible even if the magic/RunAtLoad
    // content scan misses it. fd < 0x2000 excludes the dserver RPC sockets.
    if (getenv("BW64_LAUNCHMSG") && total > 64 && fd >= 3 && fd < 0x2000) {
        klog_fmt("SOCKWRITE pid=%d tid=%d fd=0x%llx total=%u",
                 (int)(thread->process ? thread->process->id : -1), (int)thread->id,
                 (unsigned long long)fd, (unsigned)total);
    }

    // BW64_LAUNCHMSG (S20): decode a liblaunch submit-job message. launchctl
    // submits each LaunchDaemon to launchd NOT over a Mach MIG RPC but over the
    // launchd AF_UNIX SOCK_STREAM control socket, via launchd_msg_send(): a
    // sendmsg() whose payload is launch_msg_header{u64 len; u64 magic} followed
    // by a launch_data_pack() blob. The blob serializes the job dict as flat
    // type-tagged nodes (host2wire = big-endian), with dictionary KEYS stored as
    // inline NUL-terminated STRINGS. So the keys that decide whether launchd
    // parks or starts a job — "Label", "RunAtLoad", "KeepAlive",
    // "ProgramArguments" — appear verbatim as ASCII in the gathered buffer. We
    // detect the message by its header magic (LAUNCH_MSG_HEADER_MAGIC =
    // 0xD2FEA02366B39A41, stored big-endian on the wire) at byte offset 8, then
    // dump every printable run >=3 chars. If a submitted dict is MISSING
    // RunAtLoad/KeepAlive here, that pins the S20 park to launch_data submit
    // serialization (the dict's start-trigger keys are lost in transit, so
    // jobmgr_dispatch_all finds nothing to start) rather than to launchd's
    // global_on_demand release (which BW64_MACHBODY already proved is delivered).
    if (getenv("BW64_LAUNCHMSG") && total >= 16) {
        // Magic on the wire is big-endian; accept either byte order to be robust.
        static const U8 magBE[8] = {0xD2,0xFE,0xA0,0x23,0x66,0xB3,0x9A,0x41};
        static const U8 magLE[8] = {0x41,0x9A,0xB3,0x66,0x23,0xA0,0xFE,0xD2};
        U8 mg[8];
        for (int i = 0; i < 8; i++) mg[i] = m32->readb(dataAddr + 8 + i);
        bool isLaunchMsg = (memcmp(mg, magBE, 8) == 0) || (memcmp(mg, magLE, 8) == 0);
        // Fallback: even if the header magic is absent (the submit may travel
        // over a path we mis-fingerprint, or split across sendmsg chunks), scan
        // the WHOLE gathered payload for the literal key "RunAtLoad" — a launch
        // job dict on any transport must carry it as inline ASCII. This tells us
        // unambiguously whether the 20 job dicts cross THIS sendmsg at all.
        if (!isLaunchMsg && total >= 16) {
            for (U32 i = 0; i + 9 <= total && i < 1048576; i++) {
                if (m32->readb(dataAddr + i) == 'R' &&
                    m32->readb(dataAddr + i + 1) == 'u' &&
                    m32->readb(dataAddr + i + 2) == 'n' &&
                    m32->readb(dataAddr + i + 3) == 'A' &&
                    m32->readb(dataAddr + i + 8) == 'd') { // "RunAtLoad"
                    isLaunchMsg = true; break;
                }
            }
        }
        if (isLaunchMsg) {
            // Collect printable ASCII runs (>=3 chars) from the packed blob so the
            // dict keys/values (Label, RunAtLoad, ProgramArguments, ...) are legible.
            std::string strs;
            int runLen = 0; char run[256];
            for (U32 i = 16; i < total && i < 16384 && strs.size() < 3500; i++) {
                U8 c = m32->readb(dataAddr + i);
                if (c >= 0x20 && c < 0x7f) {
                    if (runLen < (int)sizeof(run) - 1) run[runLen++] = (char)c;
                } else {
                    if (runLen >= 3) { run[runLen] = 0; strs += run; strs += ' '; }
                    runLen = 0;
                }
            }
            if (runLen >= 3) { run[runLen] = 0; strs += run; }
            klog_fmt("LAUNCHMSG pid=%d tid=%d fd=0x%llx total=%u strs=[%s]",
                     (int)(thread->process ? thread->process->id : -1), (int)thread->id,
                     (unsigned long long)fd, (unsigned)total, strs.c_str());
        }
    }

    // BW64_S2C: dump the wire bytes of an S2C call (server->client memory upcall).
    // call_number == 0x52cca11 (dserver_callnum_s2c). darlingserver, to deliver a
    // Mach msg carrying OUT-OF-LINE memory, sends this on the RECEIVER's RPC
    // socket so the receiver's libsystem_kernel performs the mmap/munmap/mprotect
    // in its own address space. The body is s2c_callhdr{int call_number; int
    // s2c_number} followed by the op args (e.g. s2c_call_munmap{addr;len}). This
    // pins which s2c_number + args go over the wire and whether the send carried
    // its fd. Gated; dserver-socket fd heuristic.
    if (getenv("BW64_S2C") && total >= 8 && fd >= 0x2000) {
        U32 cn = m32->readd(dataAddr + 0);
        // 0x52cca11 = dserver_callnum_s2c (server->client send); 0xbadca11 =
        // the client's push_reply that carries the op result back to the server.
        if (cn == 0x52cca11u || cn == 0xbadca11u) {
            char hex[72 * 3 + 1]; int n = total < 72 ? (int)total : 72; int o = 0;
            for (int i = 0; i < n && o + 3 < (int)sizeof(hex); i++) o += snprintf(hex + o, sizeof(hex) - o, "%02x ", m32->readb(dataAddr + i));
            klog_fmt("S2C SEND pid=%d tid=%d fd=0x%llx total=%u ctl=%llu %s bytes=[%s]",
                     (int)(thread->process ? thread->process->id : -1), (int)thread->id,
                     (unsigned long long)fd, (unsigned)total, (unsigned long long)ctllen,
                     cn == 0xbadca11u ? "PUSH_REPLY" : "S2C_CALL", hex);
        }
    }

    // BW64_RPCSEND: log the darlingserver RPC call number this thread is sending.
    // The dserver_rpc_callhdr_t is the first 16 bytes of the message body
    // { u32 number; s32 pid; s32 tid; u32 arch; }. A launchd RPC that the server
    // never logs receiving = the request didn't reach the server's loop (lost
    // wakeup); the matching recvmsg then blocks forever. Logging the OUTGOING
    // callnum per send pins down exactly which RPC stalls. Cheap, env-gated.
    if (getenv("BW64_RPCSEND") && total >= 16 && cpu->thread) {
        U32 callnum = m32->readd(dataAddr + 0);
        // BW64_RPCARG: also dump the first arg word (body+16) — for #31
        // pthread_canceled this is `action` (0=test,1=enable,2=disable); for
        // other calls it is whatever the RPC's first param is. Pins down WHICH
        // libpthread path drives the TID29 #31 spin (S14).
        // BW64_MACHMSG: decode a mach_msg_overwrite (#38) RPC. The dserver body is
        // callhdr(16) + msg(u64 @16) + option(u32 @24) + send_size(u32 @28) +
        // rcv_size(u32 @32) + rcv_name(u32 @36) + timeout + priority + rcv_msg.
        // `msg` points into the SENDER's guest memory at a mach_msg_header_t:
        //   msgh_bits(0) msgh_size(4) msgh_remote_port(8) msgh_local_port(12)
        //   msgh_voucher_port(16) msgh_id(20).
        // remote_port = the DESTINATION (launchd's bootstrap port for a check_in);
        // local_port = the REPLY port; msgh_id = the MIG routine number. option bit
        // 0x1=MACH_SEND_MSG, 0x2=MACH_RCV_MSG (a combined RPC has both). This pins
        // down whether launchctl's bootstrap #38 is a send+recv to launchd's port
        // and which MIG routine it carries (S15 cross-process bootstrap wall).
        if (getenv("BW64_MACHMSG") && callnum == 38 && total >= 40 && cpu->thread) {
            U64 msgPtr = ((U64)m32->readd(dataAddr + 16)) | (((U64)m32->readd(dataAddr + 20)) << 32);
            U32 option = m32->readd(dataAddr + 24);
            U32 sendSize = m32->readd(dataAddr + 28);
            U32 rcvName = m32->readd(dataAddr + 36);
            U32 bits = 0, remote = 0, local = 0, msgid = 0, sz = 0;
            // The `msg` pointer is a 64-bit guest address (e.g. 0x7fffff...) in
            // the SENDER's address space, so it MUST be dereferenced through the
            // 64-bit guest memory (cpu->memory == KMemory64), NOT thread->memory
            // (the 32-bit KMemory). The original S15 instrument used the 32-bit
            // memory, which FAULTED on the high 64-bit address — that fault was
            // the "Page Fault at FFDFE930" that corrupted the in-flight send and
            // produced the bogus "BAD SEND LENGTH: 46 (expected 56)" abort. It
            // was a tracing artifact, not a real S2C/transport bug.
            if (msgPtr && cpu->memory && (option & 0x1 /*SEND*/)) {
                bits   = cpu->memory->readd(msgPtr + 0);
                sz     = cpu->memory->readd(msgPtr + 4);
                remote = cpu->memory->readd(msgPtr + 8);
                local  = cpu->memory->readd(msgPtr + 12);
                msgid  = cpu->memory->readd(msgPtr + 20);
            }
            klog_fmt("MACHMSG pid=%d tid=%d opt=0x%x(%s%s) sendsz=%u rcvname=0x%x | bits=0x%x size=%u remote=0x%x local=0x%x id=%d",
                     (int)(cpu->thread->process ? cpu->thread->process->id : -1),
                     (int)cpu->thread->id, option,
                     (option & 0x1) ? "SEND" : "", (option & 0x2) ? "|RCV" : "",
                     sendSize, rcvName, bits, sz, remote, local, (int)msgid);
            // BW64_MACHBODY (S20): dump the mach message BODY past the 24-byte
            // mach_msg_header_t. For a COMPLEX message (bits&0x80000000) the body
            // is mach_msg_body_t{u32 descriptor_count} + N descriptors; an OOL
            // (out-of-line) descriptor is {u64 address; u32 size; u8 dealloc; u8
            // copy; u16 type=0x01} and carries the serialized launch_data job dict
            // in the SENDER's memory at `address`. For a simple message the body
            // is the inline MIG args. We dump (a) the first 48 body bytes inline,
            // and (b) for the first COMPLEX descriptor, the first 96 bytes of the
            // OOL payload it points at — that payload is the XPC/launch_data blob
            // whose keys (RunAtLoad, Label, KeepAlive, the global_on_demand op)
            // decide whether launchd parks or dispatches the job. This is the S20
            // instrument: confirm RunAtLoad is present in each submitted job dict
            // and whether a distinct global_on_demand set-false message is sent.
            if (getenv("BW64_MACHBODY") && msgPtr && cpu->memory && (option & 0x1) &&
                (sz >= 24 || sendSize >= 24)) {
                char bhex[48 * 3 + 1]; int bo = 0;
                for (int i = 0; i < 48 && bo + 3 < (int)sizeof(bhex); i++)
                    bo += snprintf(bhex + bo, sizeof(bhex) - bo, "%02x ",
                                   cpu->memory->readb(msgPtr + 24 + i));
                klog_fmt("MACHBODY pid=%d tid=%d id=%d complex=%d body=[%s]",
                         (int)(cpu->thread->process ? cpu->thread->process->id : -1),
                         (int)cpu->thread->id, (int)msgid,
                         (bits & 0x80000000u) ? 1 : 0, bhex);
                if (bits & 0x80000000u) {
                    // Complex body: mach_msg_body_t{u32 descriptor_count} at +24,
                    // then `descriptor_count` descriptors. Descriptors are NOT all
                    // 16 bytes: a 64-bit OOL descriptor (mach_msg_ool_descriptor64_t)
                    // is 16 bytes {u64 address; u32 size; u8 dealloc; u8 copy; u8
                    // pad; u8 type}, a port descriptor is 16 bytes, an OOL-ports
                    // descriptor is also 16. The TYPE byte sits at descriptor+15
                    // (the last byte) in the 64-bit ABI; type 0=port, 1=OOL,
                    // 2=OOL_PORTS, 3=OOL_VOLATILE. We walk each descriptor by its
                    // type so we don't (as the first naive version did) misread a
                    // leading PORT descriptor's bytes as an OOL address — that bug
                    // produced bogus addr=0xb03/size=1.2M lines. For every OOL
                    // descriptor we dump the ASCII strings of its payload, because
                    // a launch_data / XPC job dict stores its keys+values (Label,
                    // RunAtLoad, KeepAlive, ProgramArguments, the daemon label) as
                    // inline strings — the S20 question is whether the 20 submitted
                    // job dicts (and their start-trigger keys) actually cross here.
                    U32 descCount = cpu->memory->readd(msgPtr + 24);
                    U64 dpos = msgPtr + 28; // first descriptor
                    for (U32 di = 0; di < descCount && di < 8; di++) {
                        U8 dtype = cpu->memory->readb(dpos + 15);
                        if (dtype == 1 || dtype == 3) { // OOL / OOL_VOLATILE
                            U64 oolAddr = ((U64)cpu->memory->readd(dpos + 0)) |
                                          (((U64)cpu->memory->readd(dpos + 4)) << 32);
                            U32 oolSize = cpu->memory->readd(dpos + 8);
                            std::string strs; int runLen = 0; char run[256];
                            U32 cap = oolSize < 2048 ? oolSize : 2048;
                            for (U32 i = 0; oolAddr && i < cap; i++) {
                                U8 c = cpu->memory->readb(oolAddr + i);
                                if (c >= 0x20 && c < 0x7f) {
                                    if (runLen < (int)sizeof(run) - 1) run[runLen++] = (char)c;
                                } else {
                                    if (runLen >= 3) { run[runLen] = 0; strs += run; strs += ' '; }
                                    runLen = 0;
                                }
                            }
                            if (runLen >= 3) { run[runLen] = 0; strs += run; }
                            klog_fmt("MACHBODY   desc[%u] OOL addr=0x%llx size=%u strs=[%s]",
                                     (unsigned)di, (unsigned long long)oolAddr,
                                     (unsigned)oolSize, strs.c_str());
                            dpos += 16;
                        } else { // port (0) / ool_ports (2) — 16 bytes, skip
                            klog_fmt("MACHBODY   desc[%u] type=%u (non-OOL, skipped)",
                                     (unsigned)di, (unsigned)dtype);
                            dpos += 16;
                        }
                    }
                }
            }
        }
        if (getenv("BW64_RPCARG") && total >= 20) {
            U32 a0 = m32->readd(dataAddr + 16);
            klog_fmt("RPCSEND pid=%d tid=%d fd=0x%llx callnum=%u len=%u arg0=%d",
                     (int)(cpu->thread->process ? cpu->thread->process->id : -1),
                     (int)cpu->thread->id, (unsigned long long)fd,
                     (unsigned)callnum, (unsigned)total, (int)a0);
        } else {
            klog_fmt("RPCSEND pid=%d tid=%d fd=0x%llx callnum=%u len=%u",
                     (int)(cpu->thread->process ? cpu->thread->process->id : -1),
                     (int)cpu->thread->id, (unsigned long long)fd,
                     (unsigned)callnum, (unsigned)total);
        }
    }

    // Build the 32-bit msghdr: a single iovec covering the gathered blob.
    m32->writed(base + MSG_SCRATCH_IOV + 0, dataAddr);
    m32->writed(base + MSG_SCRATCH_IOV + 4, total);
    m32->writed(base + MSG_SCRATCH_HDR + 0, name32);              // msg_name
    m32->writed(base + MSG_SCRATCH_HDR + 4, namelen32);           // msg_namelen
    m32->writed(base + MSG_SCRATCH_HDR + 8, base + MSG_SCRATCH_IOV); // msg_iov
    m32->writed(base + MSG_SCRATCH_HDR + 12, total ? 1 : 0);       // msg_iovlen
    U32 ctl32 = 0, ctllen32 = 0;
    if (control && ctllen >= 16) {
        // Walk EVERY 64-bit cmsg header, not just the first. darlingserver sends
        // SCM_CREDENTIALS as the FIRST cmsg on every message and SCM_RIGHTS (when
        // it passes an fd, e.g. the kqchan_mach_port_open reply) as a SECOND
        // header; only inspecting cmsg[0] silently dropped every fd it ever sent.
        // 64-bit cmsg layout: {len(u64@0), level(s32@8), type(s32@12), data@16},
        // each header padded to CMSG_ALIGN (8-byte) of cmsg_len. Collect every
        // SCM_RIGHTS fd into the object's compact 16-byte-per-fd recv form (one
        // record per fd, fd at +12), skipping SCM_CREDENTIALS (we synthesize creds
        // on the receive side).
        U32 cm = base + MSG_SCRATCH_CMSG;
        U32 nfds = 0;
        const U32 maxFds = (MSG_SCRATCH_NAME - MSG_SCRATCH_CMSG) / 16; // scratch cap
        U64 off = 0;
        while (off + 16 <= ctllen) {
            U64 clen  = cpu->memory->readq(control + off + 0);
            U32 level = cpu->memory->readd(control + off + 8);
            U32 type  = cpu->memory->readd(control + off + 12);
            if (clen < 16 || off + clen > ctllen) break;
            if (level == K_SOL_SOCKET && type == K_SCM_RIGHTS) {
                U32 thisFds = (U32)((clen - 16) / 4);
                for (U32 i = 0; i < thisFds && nfds < maxFds; i++, nfds++) {
                    U32 hostFd = cpu->memory->readd(control + off + 16 + 4 * i);
                    m32->writed(cm + 16 * nfds + 0, 16);            // cmsg_len
                    m32->writed(cm + 16 * nfds + 4, K_SOL_SOCKET);  // cmsg_level
                    m32->writed(cm + 16 * nfds + 8, K_SCM_RIGHTS);  // cmsg_type
                    m32->writed(cm + 16 * nfds + 12, hostFd);       // fd
                }
            }
            // advance to the next header (cmsg_len rounded up to 8 bytes)
            U64 step = (clen + 7) & ~(U64)7;
            if (step == 0) break;
            off += step;
        }
        if (nfds) {
            ctl32 = cm;
            ctllen32 = nfds * 16;
        }
    }
    m32->writed(base + MSG_SCRATCH_HDR + 16, ctl32);              // msg_control
    m32->writed(base + MSG_SCRATCH_HDR + 20, ctllen32);          // msg_controllen
    m32->writed(base + MSG_SCRATCH_HDR + 24, 0);                 // msg_flags

    U32 rc = ksendmsg(thread, (U32)fd, base + MSG_SCRATCH_HDR, (U32)flags);
    if (smsg) {
        klog_fmt("SMSG pid=%d tid=%d fd=0x%llx GATHERED total=%u ctllen32=%u -> ksendmsg rc=%d",
                 (int)(thread->process ? thread->process->id : -1), (int)thread->id,
                 (unsigned long long)fd, (unsigned)total, (unsigned)ctllen32, (int)(S32)rc);
    }
    // Record the SEND side of fd-passing in the crashring ('S'). get_handle_fd
    // (wineserver -> client) is the request that precedes the deterministic
    // teardown crash; seeing whether/which fd wineserver actually sent (and
    // whether ksendmsg succeeded) is the missing half — recvmsg's 'M'/'F' only
    // capture the receive side. e0 = #fds sent, e1 = the first guest fd value.
    if (wsReadEnabled() && ctllen32) {
        // First emitted SCM_RIGHTS fd (compact form: fd at +12 of the first
        // 16-byte record). Read from the scratch we just built, not control+16 —
        // the guest's first cmsg may be SCM_CREDENTIALS (darlingserver) not RIGHTS.
        U32 firstFd = m32->readd(ctl32 + 12);
        crashRingRecordRead('S', (U32)thread->process->id, (U32)fd,
                            nullptr, 0, ctllen32 / 16, firstFd);
    }
    if (getenv("BW64_IPCDUMP")) {
        klog_fmt("IPC [pid=%d] sendmsg fd=%d datalen=%d ctllen32=%d -> rc=%d",
                 (int)thread->process->id, (int)fd, (int)total, (int)ctllen32, (int)(S32)rc);
    }
    return (U64)(S64)(S32)rc;
}

// recvmsg(fd, msghdr*, flags) for a 64-bit guest. Builds a 32-bit msghdr over a
// scratch data buffer + cmsg area, calls krecvmsg, then scatters the received
// bytes back into the 64-bit iov segments and translates any received
// SCM_RIGHTS fds into the 64-bit cmsg.
static U64 sys_recvmsg64(CPU64* cpu, U64 fd, U64 msg64, U64 flags) {
    KThread* thread = cpu->thread;
    if (!thread || !thread->process) return (U64)-K_ENOSYS;
    // BW64_WSCONC: wineserver reads protocol requests via recvmsg (SCM creds/fds),
    // so the concurrency witness must cover this path too — sys_read64's hook
    // alone reported 0 because the request stream never flows through read().
    // We bracket the whole call (krecvmsg blocks) so a second wineserver host
    // thread entering recvmsg while the first is still inside is visible.
    bool wsConcRm = wsConcEnabled() && thread->process->exe.contains("wineserver");
    struct WsConcGuard {
        bool on; CPU64* cpu;
        WsConcGuard(bool on, CPU64* cpu) : on(on), cpu(cpu) {
            if (on) {
                static bool announced = false;
                int now = ++g_wsConcInflight;
                if (!announced) { announced = true;
                    klog_fmt("WSCONC: wineserver recvmsg path armed (first hit) pid=%d tid=%d",
                             (int)cpu->thread->process->id, (int)cpu->thread->id); }
                if (now > 1)
                    klog_fmt("WSCONC: %d host threads concurrently in wineserver recvmsg! pid=%d tid=%d",
                             now, (int)cpu->thread->process->id, (int)cpu->thread->id);
            }
        }
        ~WsConcGuard() { if (on) --g_wsConcInflight; }
    } wsConcGuard(wsConcRm, cpu);

    // BW64_RPCSEND: bracket recvmsg on a darlingserver RPC socket so a reply that
    // never arrives is visible — log ENTER before the (blocking) recv and RETURN
    // after. If the final ENTER has no matching RETURN while the peer (server)
    // logged sending the reply, the wakeup/reply was lost on the transport. Gated
    // on the same env as the send-side log; the fd heuristic (>=0x2000) matches
    // launchd's dserver sockets (0x27ff/0x27fe) without touching normal fds.
    struct RpcRecvGuard {
        bool on; CPU64* cpu; U64 fd;
        RpcRecvGuard(CPU64* c, U64 f) : cpu(c), fd(f) {
            on = getenv("BW64_RPCSEND") && f >= 0x2000 && c->thread;
            if (on) klog_fmt("RPCRECV pid=%d tid=%d fd=0x%llx ENTER",
                             (int)(cpu->thread->process ? cpu->thread->process->id : -1),
                             (int)cpu->thread->id, (unsigned long long)fd);
        }
        ~RpcRecvGuard() {
            if (on) klog_fmt("RPCRECV pid=%d tid=%d fd=0x%llx RETURN",
                             (int)(cpu->thread->process ? cpu->thread->process->id : -1),
                             (int)cpu->thread->id, (unsigned long long)fd);
        }
    } rpcRecvGuard(cpu, fd);

    U32 base = msgScratch(thread);
    if (!base) return (U64)-K_EFAULT;
    KMemory* m32 = thread->memory;

    // Is this an AF_UNIX SOCK_DGRAM socket? Its recv side returns the sender
    // address (msg_name) and a 12-byte-header cmsg stream (SCM_CREDENTIALS /
    // SCM_RIGHTS), which we translate differently from the connected-stream path.
    bool isDgram = false;
    {
        KFileDescriptorPtr fdesc = thread->process->getFileDescriptor((FD)(S32)fd);
        if (fdesc && fdesc->kobject && fdesc->kobject->type == KTYPE_UNIX_SOCKET) {
            std::shared_ptr<KSocketObject> so = std::dynamic_pointer_cast<KSocketObject>(fdesc->kobject);
            if (so && so->type == K_SOCK_DGRAM) isDgram = true;
        }
    }

    U64 name    = cpu->memory->readq(msg64 + 0);
    U32 namelen = cpu->memory->readd(msg64 + 8);
    U64 iov     = cpu->memory->readq(msg64 + 16);
    U64 iovlen  = cpu->memory->readq(msg64 + 24);
    U64 control = cpu->memory->readq(msg64 + 32);
    U64 ctllen  = cpu->memory->readq(msg64 + 40);

    // Total receive capacity across all iov segments, capped to the scratch buf.
    U32 dataAddr = base + MSG_SCRATCH_DATA;
    U32 dataCap = MSG_SCRATCH_BYTES - MSG_SCRATCH_DATA;
    U32 want = 0;
    for (U64 i = 0; i < iovlen; i++) {
        U64 l = cpu->memory->readq(iov + 16 * i + 8);
        want += (U32)l;
    }
    if (want > dataCap) want = dataCap;

    // If the guest wants the source address (msg_name != NULL, e.g. a SOCK_DGRAM
    // receiver like darlingserver that must reply to the sender), give the object
    // a scratch sockaddr buffer to fill; we copy it back to the 64-bit guest after.
    U32 name32 = 0, namecap32 = 0;
    if (name && namelen) {
        name32 = base + MSG_SCRATCH_NAME;
        namecap32 = (namelen > 128) ? 128 : namelen;
    }

    U32 cmArea = base + MSG_SCRATCH_CMSG;
    U32 cmCap = MSG_SCRATCH_NAME - MSG_SCRATCH_CMSG; // room for cmsg records
    m32->writed(base + MSG_SCRATCH_IOV + 0, dataAddr);
    m32->writed(base + MSG_SCRATCH_IOV + 4, want);
    m32->writed(base + MSG_SCRATCH_HDR + 0, name32);
    m32->writed(base + MSG_SCRATCH_HDR + 4, namecap32);
    m32->writed(base + MSG_SCRATCH_HDR + 8, base + MSG_SCRATCH_IOV);
    m32->writed(base + MSG_SCRATCH_HDR + 12, 1);
    m32->writed(base + MSG_SCRATCH_HDR + 16, (control && ctllen) ? cmArea : 0);
    m32->writed(base + MSG_SCRATCH_HDR + 20, (control && ctllen) ? cmCap : 0);
    m32->writed(base + MSG_SCRATCH_HDR + 24, 0);

    U32 rc = krecvmsg(thread, (U32)fd, base + MSG_SCRATCH_HDR, (U32)flags);
    if (getenv("BW64_IPCDUMP")) {
        klog_fmt("IPC [pid=%d] recvmsg fd=%d want=%d flags=0x%x -> rc=%d ctllen32=%d",
                 (int)thread->process->id, (int)fd, (int)want, (unsigned)flags,
                 (int)(S32)rc, (int)m32->readd(base + MSG_SCRATCH_HDR + 20));
    }
    if (wsReadEnabled() && (S32)rc >= 0) {
        // 'M' record: the wineserver request-reply / fd-pass channel (the select
        // + get_apc_result loop the crash trace runs). hdr = first 16 bytes of
        // the received data; e0 = want, e1 = ctllen32 (bytes of SCM_RIGHTS).
        U8 head[16] = {0};
        U32 n = (rc < 16) ? (U32)rc : 16;
        if (n) m32->memcpy(head, dataAddr, n);
        crashRingRecordRead('M', (U32)thread->process->id, (U32)fd, head, (U32)rc,
                            want, (U32)m32->readd(base + MSG_SCRATCH_HDR + 20));
    }
    // BW64_S2C: dump an S2C datagram as the RECEIVER (e.g. launchd) sees it —
    // call_number 0x52cca11 at the head of the received body. Compare against the
    // S2C SEND dump to verify our transport delivers it intact (byte count +
    // any SCM_RIGHTS fd). If the receiver never logs an S2C RECV while the sender
    // logged an S2C SEND, the datagram was lost/mis-queued; if the bytes/fd
    // differ, the framing is wrong (cf the S6 cmsg bug).
    if (getenv("BW64_S2C") && (S32)rc >= 8 && fd >= 0x2000) {
        U32 cn = m32->readd(dataAddr + 0);
        if (cn == 0x52cca11u) {
            char hex[48 * 3 + 1]; int n = rc < 48 ? (int)rc : 48; int o = 0;
            for (int i = 0; i < n && o + 3 < (int)sizeof(hex); i++) o += snprintf(hex + o, sizeof(hex) - o, "%02x ", m32->readb(dataAddr + i));
            klog_fmt("S2C RECV pid=%d tid=%d fd=0x%llx rc=%d ctllen32=%d s2c_number=%d bytes=[%s]",
                     (int)thread->process->id, (int)thread->id, (unsigned long long)fd,
                     (int)(S32)rc, (int)m32->readd(base + MSG_SCRATCH_HDR + 20),
                     (int)m32->readd(dataAddr + 4), hex);
            // Arm a full syscall trace for THIS thread from here on, so the next
            // few syscalls (the munmap + push_reply the S2C handler is supposed to
            // make) — or the lack of them — are visible right up to the crash.
            extern int g_s2cTraceTid;
            g_s2cTraceTid = (int)thread->id;
        }
    }

    if ((S32)rc < 0) return (U64)(S64)(S32)rc;

    // Scatter the received bytes back into the 64-bit iov segments.
    U32 remaining = (U32)rc;
    U32 off = 0;
    U64 firstIovBase = 0;
    for (U64 i = 0; i < iovlen && remaining; i++) {
        U64 b = cpu->memory->readq(iov + 16 * i);
        U64 l = cpu->memory->readq(iov + 16 * i + 8);
        if (i == 0) firstIovBase = b;
        U32 chunk = (U32)((l < remaining) ? l : remaining);
        if (chunk) {
            std::vector<U8> tmp(chunk);
            m32->memcpy(tmp.data(), dataAddr + off, chunk);
            cpu->memory->memcpyToGuest(b, tmp.data(), chunk);
            off += chunk;
            remaining -= chunk;
        }
    }
    // BW64_S2C: after scattering an S2C datagram into the guest's iov, read the
    // call_number BACK from the guest's iov_base (the 64-bit address the guest's
    // dispatch code will `cmpl $0x52cca11,(iov_base)` against). If this is not
    // 0x52cca11 the scatter mis-placed the data and the guest's dispatch faults.
    // Also re-read msg_iov / iov[0] from the guest msghdr, which the guest derefs
    // as msg_arg->[0x10]->[0] right after recvmsg returns — to confirm those are
    // intact (the suspected crash site: zero syscalls run after S2C RECV).
    if (getenv("BW64_S2C") && fd >= 0x2000 && firstIovBase &&
        m32->readd(dataAddr + 0) == 0x52cca11u) {
        U32 cnBack = cpu->memory->readd(firstIovBase + 0);
        U32 s2cBack = cpu->memory->readd(firstIovBase + 4);
        U64 guestIovPtr = cpu->memory->readq(msg64 + 16);          // msg_iov
        U64 guestIov0Base = guestIovPtr ? cpu->memory->readq(guestIovPtr) : 0;
        klog_fmt("S2C VERIFY iov0base=0x%llx cn@base=0x%x s2c@base=%d | msg_iov=0x%llx iov[0].base=0x%llx (match=%d)",
                 (unsigned long long)firstIovBase, cnBack, (int)s2cBack,
                 (unsigned long long)guestIovPtr, (unsigned long long)guestIov0Base,
                 (guestIov0Base == firstIovBase) ? 1 : 0);
    }

    // SOCK_DGRAM: copy the sender address back to the guest's msg_name, and
    // translate the object's 12-byte-header cmsg stream (creds + rights) into the
    // 64-bit guest cmsg. Done here (not in the shared block below) because the
    // dgram cmsg layout differs from the connected-stream 16-byte-record form.
    if (isDgram) {
        // msg_name: copy the sockaddr the object wrote into scratch back out, and
        // report the actual namelen the object set in the scratch msghdr.
        if (name && namelen) {
            U32 actualNameLen = m32->readd(base + MSG_SCRATCH_HDR + 4);
            U32 copy = actualNameLen;
            if (copy > namelen) copy = namelen;
            for (U32 i = 0; i < copy; i++) {
                cpu->memory->writeb(name + i, m32->readb(base + MSG_SCRATCH_NAME + i));
            }
            cpu->memory->writed(msg64 + 8, actualNameLen); // msg_namelen
        } else {
            cpu->memory->writed(msg64 + 8, 0);
        }
        // Walk the object's cmsg stream: each record is {len(4), level(4), type(4),
        // data...} 8-byte aligned. Re-emit as 64-bit cmsg {len(8), level(4),
        // type(4), data...} 8-byte aligned into the guest control buffer.
        U32 ctllen32 = m32->readd(base + MSG_SCRATCH_HDR + 20);
        U64 outPos = control;
        U64 outEnd = control + ctllen;
        U32 inPos = cmArea;
        U32 inEnd = cmArea + ctllen32;
        while (control && inPos + 12 <= inEnd) {
            U32 clen   = m32->readd(inPos + 0);
            U32 level  = m32->readd(inPos + 4);
            U32 type   = m32->readd(inPos + 8);
            if (clen < 12) break;
            U32 dataLen = clen - 12;
            U64 outRecord = 16 + (U64)dataLen;
            if (outPos + outRecord > outEnd) break; // never overflow guest buffer
            cpu->memory->writeq(outPos + 0, 16 + (U64)dataLen); // 64-bit cmsg_len
            cpu->memory->writed(outPos + 8, level);
            cpu->memory->writed(outPos + 12, type);
            for (U32 i = 0; i < dataLen; i++) {
                cpu->memory->writeb(outPos + 16 + i, m32->readb(inPos + 12 + i));
            }
            outPos += (outRecord + 7) & ~7ull;
            U32 adv = (clen + 7) & ~7u;
            inPos += adv;
        }
        cpu->memory->writeq(msg64 + 40, outPos - control); // msg_controllen
        return (U64)(S64)(S32)rc;
    }

    // Translate any received SCM_RIGHTS fds (32-bit object wrote 16-byte cmsg
    // records, fd at +12) into the 64-bit cmsg the guest provided.
    U32 ctllen32 = m32->readd(base + MSG_SCRATCH_HDR + 20);
    if (control && ctllen >= 16 && ctllen32 >= 16) {
        U32 nfds = ctllen32 / 16;
        // NEVER write past the guest's control buffer (ctllen): a 64-bit cmsg
        // for nfds is 16 (cmsghdr) + nfds*4 bytes. Cap nfds so it fits — an
        // overflow here scribbles past wine/wineserver's heap-allocated control
        // buffer and corrupts its malloc arena ("unsorted double linked list").
        U32 maxFds = (ctllen >= 16) ? (U32)((ctllen - 16) / 4) : 0;
        if (nfds > maxFds) nfds = maxFds;
        U64 cmsgLen = 16 + (U64)nfds * 4; // 64-bit cmsghdr header is 16 bytes
        cpu->memory->writeq(control + 0, cmsgLen);
        cpu->memory->writed(control + 8, K_SOL_SOCKET);
        cpu->memory->writed(control + 12, K_SCM_RIGHTS);
        for (U32 i = 0; i < nfds; i++) {
            U32 fdv = m32->readd(cmArea + 16 * i + 12);
            cpu->memory->writed(control + 16 + 4 * i, fdv);
            if (wsReadEnabled()) {
                // 'F' witness: which fd was just handed to the guest via
                // SCM_RIGHTS. The same delivered fd value reappearing (e1) flags
                // a double-delivered wineserver object handle.
                crashRingRecordRead('F', (U32)thread->process->id, (U32)fd, nullptr, 0, nfds, fdv);
            }
        }
        cpu->memory->writeq(msg64 + 40, cmsgLen); // msg_controllen
    } else {
        cpu->memory->writeq(msg64 + 40, 0);
    }
    return (U64)(S64)(S32)rc;
}

// Map an x86-64 Linux syscall number to a human-readable name. Used only by
// the unimplemented-syscall log path — when running real glibc binaries, the
// first thing you want to see is "which syscall is missing", not "#291".
// Covers both syscalls we already handle (useful for trace) and the obvious
// gaps that are most likely to surface during early Wine/glibc bring-up.
// Returns "?" for unknown numbers; the caller still logs the raw #N.
static const char* x64SyscallName(U64 nr) {
#ifdef BOXEDWINE_OPENGL
    if (nr == GL64_SYSCALL_NR) return "gl64_trap";
#endif
    switch (nr) {
        case 0: return "read";
        case 1: return "write";
        case 2: return "open";
        case 3: return "close";
        case 4: return "stat";
        case 5: return "fstat";
        case 6: return "lstat";
        case 7: return "poll";
        case 8: return "lseek";
        case 9: return "mmap";
        case 10: return "mprotect";
        case 11: return "munmap";
        case 12: return "brk";
        case 13: return "rt_sigaction";
        case 14: return "rt_sigprocmask";
        case 15: return "rt_sigreturn";
        case 16: return "ioctl";
        case 17: return "pread64";
        case 18: return "pwrite64";
        case 19: return "readv";
        case 20: return "writev";
        case 21: return "access";
        case 22: return "pipe";
        case 23: return "select";
        case 24: return "sched_yield";
        case 25: return "mremap";
        case 28: return "madvise";
        case 221: return "fadvise64";
        case 280: return "utimensat";
        case 32: return "dup";
        case 33: return "dup2";
        case 34: return "pause";
        case 35: return "nanosleep";
        case 36: return "getitimer";
        case 38: return "setitimer";
        case 39: return "getpid";
        case 41: return "socket";
        case 42: return "connect";
        case 43: return "accept";
        case 44: return "sendto";
        case 45: return "recvfrom";
        case 46: return "sendmsg";
        case 47: return "recvmsg";
        case 53: return "socketpair";
        case 56: return "clone";
        case 57: return "fork";
        case 58: return "vfork";
        case 59: return "execve";
        case 60: return "exit";
        case 61: return "wait4";
        case 62: return "kill";
        case 63: return "uname";
        case 72: return "fcntl";
        case 79: return "getcwd";
        case 80: return "chdir";
        case 82: return "rename";
        case 86: return "link";
        case 88: return "symlink";
        case 89: return "readlink";
        case 90: return "chmod";
        case 91: return "fchmod";
        case 96: return "gettimeofday";
        case 98: return "getrusage";
        case 99: return "sysinfo";
        case 101: return "ptrace";
        case 102: return "getuid";
        case 165: return "mount";
        case 272: return "unshare";
        case 92: return "chown";
        case 93: return "fchown";
        case 94: return "lchown";
        case 260: return "fchownat";
        case 268: return "fchmodat";
        case 452: return "fchmodat2";
        case 105: return "setuid";
        case 106: return "setgid";
        case 201: return "time";
        case 264: return "renameat";
        case 316: return "renameat2";
        case 104: return "getgid";
        case 107: return "geteuid";
        case 108: return "getegid";
        case 110: return "getppid";
        case 111: return "getpgrp";
        case 117: return "setresuid";
        case 118: return "getresuid";
        case 119: return "setresgid";
        case 120: return "getresgid";
        case 121: return "getpgid";
        case 124: return "getsid";
        case 127: return "rt_sigpending";
        case 128: return "rt_sigtimedwait";
        case 129: return "rt_sigqueueinfo";
        case 130: return "rt_sigsuspend";
        case 131: return "sigaltstack";
        case 29:  return "shmget";
        case 30:  return "shmat";
        case 31:  return "shmctl";
        case 67:  return "shmdt";
        case 137: return "statfs";
        case 138: return "fstatfs";
        case 157: return "prctl";
        case 158: return "arch_prctl";
        case 186: return "gettid";
        case 202: return "futex";
        case 203: return "sched_setaffinity";
        case 204: return "sched_getaffinity";
        case 217: return "getdents64";
        case 218: return "set_tid_address";
        case 228: return "clock_gettime";
        case 229: return "clock_getres";
        case 230: return "clock_nanosleep";
        case 231: return "exit_group";
        case 232: return "epoll_wait";
        case 233: return "epoll_ctl";
        case 200: return "tkill";
        case 234: return "tgkill";
        case 257: return "openat";
        case 262: return "newfstatat";
        case 270: return "pselect6";
        case 273: return "set_robust_list";
        case 290: return "eventfd2";
        case 284: return "eventfd";
        case 434: return "pidfd_open";
        case 310: return "process_vm_readv";
        case 311: return "process_vm_writev";
        case 283: return "timerfd_create";
        case 286: return "timerfd_settime";
        case 287: return "timerfd_gettime";
        case 291: return "epoll_create1";
        case 293: return "pipe2";
        case 302: return "prlimit64";
        case 309: return "getcpu";
        case 318: return "getrandom";
        case 334: return "rseq";
        case 435: return "clone3";
        default:  return "?";
    }
}

void ksyscall64(CPU64* cpu) {
    if (!cpu) return;
    U64 nr   = cpu->reg[X64_RAX].u64;
    U64 a1   = cpu->reg[X64_RDI].u64;
    U64 a2   = cpu->reg[X64_RSI].u64;
    U64 a3   = cpu->reg[X64_RDX].u64;
    U64 a4   = cpu->reg[X64_R10].u64;
    U64 a5   = cpu->reg[X64_R8].u64;
    U64 a6   = cpu->reg[X64_R9].u64;
    U64 ret  = (U64)-K_ENOSYS;

    // Set BW64_SYSTRACE=1 to log every 64-bit syscall — invaluable for wine
    // bring-up (finding where a guest stalls or which syscall is next missing).
    // BW64_TRACEPID=N traces ONLY process N (one cheap compare; doesn't slow the
    // rest of the system, so it can catch a timing-sensitive failure that full
    // SYSTRACE masks). Useful to see exactly which syscall precedes a process's
    // exit_group(1).
    {
        static const char* tracePidEnv = getenv("BW64_TRACEPID");
        static int tracePid = tracePidEnv ? atoi(tracePidEnv) : -1;
        int myPid = (int)(cpu->thread ? cpu->thread->process->id : -1);
        int myTid = (int)(cpu->thread ? cpu->thread->id : -1);
        if (getenv("BW64_SYSTRACE") || (tracePid >= 0 && myPid == tracePid) ||
            (g_s2cTraceTid != 0 && myTid == g_s2cTraceTid)) {
            klog_fmt("SYS64 [pid=%d tid=%d] #%llu %s (a1=0x%llx a2=0x%llx a3=0x%llx) rip=0x%llx",
                     myPid, (int)(cpu->thread ? cpu->thread->id : -1),
                     (unsigned long long)nr, x64SyscallName(nr),
                     (unsigned long long)a1, (unsigned long long)a2,
                     (unsigned long long)a3, (unsigned long long)cpu->rip);
        }
    }

    // BW64_BLOCKDUMP: record entry so a thread parked inside a blocking syscall
    // (mach_msg recvmsg / futex / sched_yield) is visible to the periodic dumper
    // below. Cheap unconditional book-keeping (two stores); the dump itself is
    // env-gated and throttled. inSyscall64 is cleared just before we return RAX.
    if (cpu->thread) {
        cpu->thread->lastSyscall64 = (U32)nr;
        cpu->thread->lastSyscallRip64 = cpu->rip;
        cpu->thread->inSyscall64 = true;
    }
    // BW64_BLOCKDUMP: log the EXACT entry into a blocking syscall (recvmsg /
    // futex / ppoll / pselect / poll / select) per thread, deduplicated on
    // (tid, scRip). A thread parked in mach_msg MACH_RCV blocks in recvmsg; one
    // in an os_unfair_lock blocks in futex. The scRip then maps (offline) to the
    // launchd / libdispatch / libxpc function so we know exactly where it idled.
    if (getenv("BW64_BLOCKDUMP") && cpu->thread) {
        U32 base = (U32)nr;
        bool blocking = (base == 47 /*recvmsg*/ || base == 202 /*futex*/ ||
                         base == 271 /*ppoll*/ || base == 270 /*pselect6*/ ||
                         base == 7 /*poll*/ || base == 23 /*select*/ ||
                         base == 281 /*epoll_pwait*/ || base == 232 /*epoll_wait*/ ||
                         // job_start/runtime_fork proxies: launchd does
                         // socketpair(execspair) right before fork() to spawn a
                         // job. Catching these (per tid/rip) proves whether the
                         // System bootstrapper's job_start path is reached at all.
                         base == 53 /*socketpair*/ || base == 56 /*clone*/ ||
                         base == 435 /*clone3*/ || base == 57 /*fork*/ ||
                         base == 59 /*execve*/);
        if (blocking) {
            static std::mutex bdMutex;
            static std::set<U64> seen;
            U64 key = ((U64)(cpu->thread->id) << 40) ^ cpu->rip;
            bool fresh;
            { std::lock_guard<std::mutex> lk(bdMutex); fresh = seen.insert(key).second; }
            if (fresh) {
                klog_fmt("BLOCKDUMP pid=%d tid=%d ENTER #%u(%s) scRip=0x%llx a1=0x%llx",
                         (int)(cpu->thread->process ? cpu->thread->process->id : -1),
                         (int)cpu->thread->id, base, x64SyscallName(base),
                         (unsigned long long)cpu->rip, (unsigned long long)a1);
                // Walk the RBP chain so the launchd caller (launchd_runtime vs
                // jobmgr_init vs ...) is visible — the 0x1xxxxxxxx frames map
                // directly to launchd offsets, the 0x8xxxxxxxx to the dylibs.
                if (cpu->memory) {
                    U64 rbp = cpu->reg[X64_RBP].u64; U64 fr[10]; int nf = 0;
                    for (int i = 0; i < 10 && rbp >= 0x1000; i++) {
                        fr[nf++] = cpu->memory->readq(rbp + 8);
                        U64 nx = cpu->memory->readq(rbp);
                        if (nx <= rbp) break; rbp = nx;
                    }
                    klog_fmt("BLOCKDUMP   bt tid=%d [%llx %llx %llx %llx %llx %llx %llx %llx]",
                             (int)cpu->thread->id,
                             (unsigned long long)(nf>0?fr[0]:0),(unsigned long long)(nf>1?fr[1]:0),
                             (unsigned long long)(nf>2?fr[2]:0),(unsigned long long)(nf>3?fr[3]:0),
                             (unsigned long long)(nf>4?fr[4]:0),(unsigned long long)(nf>5?fr[5]:0),
                             (unsigned long long)(nf>6?fr[6]:0),(unsigned long long)(nf>7?fr[7]:0));
                    // The RBP chain often runs through GCD/dispatch which doesn't
                    // chain back to launchd. Also SCAN the raw stack for the
                    // first few launchd return addresses (0x100000000..0x101000000)
                    // — those name the launchd.c-level caller (jobmgr_init vs
                    // launchd_runtime vs the update_thread pthread_create), telling
                    // us how far launchd's main() actually got.
                    U64 sp = cpu->reg[X64_RSP].u64; U64 lfr[6]; int lf = 0;
                    for (int i = 0; i < 512 && lf < 6; i++) {
                        U64 w = cpu->memory->readq(sp + (U64)i * 8);
                        if (w >= 0x100000000ULL && w < 0x101000000ULL) lfr[lf++] = w;
                    }
                    klog_fmt("BLOCKDUMP   launchdFrames tid=%d [%llx %llx %llx %llx %llx %llx]",
                             (int)cpu->thread->id,
                             (unsigned long long)(lf>0?lfr[0]:0),(unsigned long long)(lf>1?lfr[1]:0),
                             (unsigned long long)(lf>2?lfr[2]:0),(unsigned long long)(lf>3?lfr[3]:0),
                             (unsigned long long)(lf>4?lfr[4]:0),(unsigned long long)(lf>5?lfr[5]:0));
                }
            }
        }
    }

    // BW64_YIELDSPIN: launchd's main thread (TID 27) busy-spins on a Darwin
    // lock right after jobmgr_init — its swtch_pri/thread_switch yields lower
    // to the HOST glibc sched_yield (RIP lands in libc, not a Darwin dylib),
    // so the only meaningful frame is the deepest Darwin return address on the
    // stack. Log tid + rip + the first Darwin (0x8xxxxxxxx) stack frames once
    // per 4096 yields, and symbolize the spin against the dyld image list. The
    // spin's PEER (TID 29) blocks in mach_msg recvmsg = a two-thread deadlock.
    if (getenv("BW64_YIELDSPIN") && nr == 24 /*sched_yield*/) {
        static U64 yieldCount = 0;
        if ((yieldCount++ & 0xFFF) == 0) {
            // The spin chain is: caller -> libpthread sched_yield -> swtch_pri ->
            // __linux_sched_yield -> SYSCALL. libpthread/libplatform frames keep
            // a frame pointer, so an RBP-CHAIN walk yields the EXACT caller list
            // (far more reliable than scanning the stack for in-range words,
            // which picks up stale data — the bug in the old version). For each
            // frame: saved-RBP @ [rbp], return-addr @ [rbp+8].
            U64 rbp = cpu->reg[X64_RBP].u64;
            U64 frames[10]; int nf = 0;
            if (cpu->memory) {
                for (int i = 0; i < 10 && rbp >= 0x1000; i++) {
                    U64 ret = cpu->memory->readq(rbp + 8);
                    frames[nf++] = ret;
                    U64 next = cpu->memory->readq(rbp);
                    if (next <= rbp) break;       // not ascending -> end of chain
                    rbp = next;
                }
            }
            // The mldr __darling_thread_create spin tests args.pth at [rbp-0x58]
            // (cmpq $0,-0x58(%rbp); je out; call sched_yield; jmp). Read it so we
            // can tell "child cleared pth but parent can't see it" (coherence bug)
            // from "child never cleared pth" (child stuck before line 247).
            U64 pthAddr = cpu->reg[X64_RBP].u64 - 0x58;
            U64 pthVal = cpu->memory ? cpu->memory->readq(pthAddr) : 0xdead;
            klog_fmt("YIELDSPIN: pthAddr=0x%llx pthVal=0x%llx",
                     (unsigned long long)pthAddr, (unsigned long long)pthVal);
            klog_fmt("YIELDSPIN: pid=%d tid=%d count=%llu rip=0x%llx rbp=0x%llx nf=%d [%llx %llx %llx %llx %llx %llx]",
                     (int)(cpu->thread ? cpu->thread->process->id : -1),
                     (int)(cpu->thread ? cpu->thread->id : -1),
                     (unsigned long long)yieldCount, (unsigned long long)cpu->rip,
                     (unsigned long long)cpu->reg[X64_RBP].u64, nf,
                     (unsigned long long)(nf>0?frames[0]:0),
                     (unsigned long long)(nf>1?frames[1]:0),
                     (unsigned long long)(nf>2?frames[2]:0),
                     (unsigned long long)(nf>3?frames[3]:0),
                     (unsigned long long)(nf>4?frames[4]:0),
                     (unsigned long long)(nf>5?frames[5]:0));
#ifdef BOXEDWINE_DARWIN
            if (yieldCount == 1 && cpu->thread && cpu->thread->process) {
                // Dump the image list once (rip arg just picks an owner line).
                bw64_dumpDyldImages(cpu->thread->process->id,
                                    nf > 0 ? frames[0] : cpu->rip);
            }
#endif
        }
    }

    // BW64_MEMSTATS=1 — periodically log the guest-memory footprint + host RSS so
    // we can SEE the leak (mapped pages climb monotonically while munmap is a
    // no-op) and the boot slowdown (per-syscall cost rises with the page map).
    // Throttled to once per ~2s wall so it never perturbs the timing-sensitive
    // race. Env read once (static cache); near-zero cost when off.
    {
        static const bool memStats = getenv("BW64_MEMSTATS") != nullptr;
        if (memStats && cpu->memory && cpu->thread && cpu->thread->process) {
            // Per-pid syscall accounting for the livelock (Mode 2) diagnosis: a
            // busy-poll storm shows one pid spinning the SAME syscall thousands of
            // times between ticks while no real progress is logged. pids stay
            // small during boot; cap the table and fold the rest into slot 0.
            static std::atomic<U32> sysCount[256];
            static std::atomic<U32> lastNr[256];
            int mypid = (int)cpu->thread->process->id;
            U32 slot = (mypid >= 0 && mypid < 256) ? (U32)mypid : 0;
            sysCount[slot].fetch_add(1, std::memory_order_relaxed);
            lastNr[slot].store((U32)nr, std::memory_order_relaxed);

            static std::atomic<U64> lastUs{0};
            U64 nowUs = KSystem::getSystemTimeAsMicroSeconds();
            U64 prev = lastUs.load(std::memory_order_relaxed);
            if (nowUs - prev >= 2000000ULL &&
                lastUs.compare_exchange_strong(prev, nowUs, std::memory_order_relaxed)) {
                KMemory64* mem = cpu->memory;
                U64 mapped = mem->mappedPageCount();
                U64 committed = mem->committedPageCount();
                U64 rss = KSystem::getHostResidentBytes();
                // Find the busiest pid this interval (the livelock suspect) and
                // reset all counters for the next window.
                U32 topPid = 0, topCount = 0, topNr = 0;
                for (U32 i = 0; i < 256; i++) {
                    U32 c = sysCount[i].exchange(0, std::memory_order_relaxed);
                    if (c > topCount) { topCount = c; topPid = i; topNr = lastNr[i].load(std::memory_order_relaxed); }
                }
                klog_fmt("MEMSTATS pid=%d pages=%llu committedKB=%llu rssKB=%llu "
                         "busiest=pid%u/%usc/last=%s",
                         (int)cpu->thread->process->id,
                         (unsigned long long)mapped,
                         (unsigned long long)(committed * 4),
                         (unsigned long long)(rss / 1024),
                         topPid, topCount, x64SyscallName(topNr));
            }
        }
    }

    switch (nr) {
#ifdef BOXEDWINE_OPENGL
        case GL64_SYSCALL_NR:
            // Private guest->host OpenGL trap (see source/opengl/gl64bridge*).
            // RDI=fn id, RSI=guest VA of GL64Args. Result goes back in RAX.
            ret = gl64Bridge(cpu, a1, a2);
            break;
#endif
        case X64_SYS_write:
            ret = sys_write64(cpu, a1, a2, a3);
            break;
        case X64_SYS_writev:
            ret = sys_writev64(cpu, a1, a2, a3);
            break;
        case X64_SYS_prctl:
            // prctl(option, ...). We don't model process control state
            // (thread name, dumpable flag, seccomp, etc.). Return success for
            // the common set-style options glibc/busybox issue at startup
            // (PR_SET_NAME=15, PR_SET_DUMPABLE=4, PR_SET_PDEATHSIG=1,
            // PR_SET_VMA=0x53564d41) so callers don't treat it as fatal;
            // PR_CAPBSET_READ(23)/PR_GET_*(even) return 0. A blanket 0 is the
            // pragmatic choice for a single-process interpreter.
            ret = 0;
            break;
        case X64_SYS_arch_prctl:
            ret = sys_arch_prctl64(cpu, a1, a2);
            break;
        case X64_SYS_chown:
        case X64_SYS_fchown:
        case X64_SYS_lchown:
        case X64_SYS_fchownat:
            // chown family. The emulated FS models a single user and tracks no
            // ownership, so changing owner is a meaningless but harmless
            // operation — accept it. darlingserver chowns prefix files (e.g.
            // mldr) during setup and treats an error as fatal, so a real -ENOSYS
            // here aborts the server; return success instead.
            ret = 0;
            break;
        case X64_SYS_unshare:
            // unshare(flags). Darling's launcher unshares mount/PID/UTS/IPC
            // namespaces to build its container on a real multi-tenant Linux.
            // The emulated kernel already gives each guest its own private VFS
            // view and a writable root, so there is nothing to isolate — accept
            // it as a no-op success. (Darling also honors DARLING_NOOVERLAYFS to
            // skip the overlay mount entirely.)
            ret = 0;
            break;
        case X64_SYS_mount:
            // mount(source, target, fstype, flags, data). Same rationale as
            // unshare: the guest VFS already presents the rootfs/zip layout, so
            // the launcher's overlayfs/bind mounts are unnecessary. Accept as a
            // no-op so prefix setup proceeds. (If a real bind is ever needed,
            // this is where to map it onto the VFS.)
            ret = 0;
            break;
        case X64_SYS_ptrace:
            // ptrace(request, pid, addr, data). Darling's mldr probes ptrace
            // during startup (a Yama/PTRACE_TRACEME check, and darlingserver
            // uses ptrace_sigexc/thupdate for Mach-exception delivery). The
            // emulator has no real ptrace; return -EPERM, exactly as the 32-bit
            // path does (syscall.cpp:syscall_ptrace) and as a Yama-restricted
            // Linux returns — mldr treats that as "tracing unavailable" and
            // continues. Real ptrace-backed exception delivery is a later phase
            // (it pairs with the darlingserver bring-up — see the plan).
            ret = (U64)-K_EPERM;
            break;
        case X64_SYS_brk:
            ret = sys_brk64(cpu, a1);
            break;
        case X64_SYS_mmap:
            ret = sys_mmap64(cpu, a1, a2, a3, a4, a5, a6);
            break;
        case X64_SYS_mprotect:
            // Flags-only: record the new protection on the page flags (real impl
            // in KMemory64::mprotect). The interpreter does NOT enforce
            // protection (it reads/writes unconditionally, and RELRO/JIT rely on
            // that lenience), so this is pure bookkeeping — it lets munmap and the
            // gap search reason about wine's PROT_NONE reservations vs committed
            // anon pages. We do NOT free buffers on PROT_NONE: that is the same
            // lazy-re-read hazard that makes decommit-on-munmap unsafe.
            //
            // KMemory64::mprotect returns the addr (mmap-style) on success; the
            // mprotect SYSCALL must return 0. Translate: pass through a negative
            // errno, otherwise report success. (Returning addr made ld.so read it
            // as -errno -> "cannot apply additional memory protection after
            // relocation" -> exit 127.)
            {
                U64 r = cpu->memory->mprotect(a1, a2, a3);
                ret = ((S64)r < 0) ? r : 0;
            }
            break;
        case X64_SYS_munmap:
            // Address-space-only free: KMemory64::munmap trims the ranges
            // reservation record so the region is reusable and the gap search
            // stays fast, WITHOUT freeing page backing buffers. Freeing buffers
            // regresses boot (wine/wineserver lazily re-read munmap'd regions —
            // zero-filled reads trip asserts), so the backing store is kept; the
            // memory is already bounded by lazy commit on the mmap side.
            // BW64_S2C: a large munmap in the 0x800000000+ Mach OOL range is the
            // guest-side S2C munmap handler running — log it so we see whether the
            // S2C upcall reaches the actual munmap and what it returns.
            if (getenv("BW64_S2C") && a2 >= 0x100000 && a1 >= 0x800000000ull) {
                klog_fmt("S2C MUNMAP pid=%d tid=%d addr=0x%llx len=0x%llx",
                         (int)(cpu->thread && cpu->thread->process ? cpu->thread->process->id : -1),
                         (int)(cpu->thread ? cpu->thread->id : -1),
                         (unsigned long long)a1, (unsigned long long)a2);
            }
            ret = cpu->memory->munmap(a1, a2);
            break;
        case X64_SYS_shmget:
            ret = sys_shmget64(cpu, a1, a2, a3);
            break;
        case X64_SYS_shmat:
            ret = sys_shmat64(cpu, a1, a2, a3);
            break;
        case X64_SYS_shmctl:
            ret = sys_shmctl64(cpu, a1, a2, a3);
            break;
        case X64_SYS_shmdt:
            ret = sys_shmdt64(cpu, a1);
            break;
        case X64_SYS_set_tid_address:
            // set_tid_address(tidptr): records the address the kernel must
            // zero + futex-wake when this thread exits (CLONE_CHILD_CLEARTID
            // semantics). glibc calls this for every thread; pthread_join
            // relies on the wake. Returns the caller's tid.
            if (cpu->thread) {
                cpu->thread->clear_child_tid64 = a1;
            }
            ret = cpu->thread ? cpu->thread->id : 1;
            break;
        case X64_SYS_rt_sigaction:
            ret = sys_rt_sigaction64(cpu, a1, a2, a3, a4);
            break;
        case X64_SYS_rt_sigprocmask:
            ret = sys_rt_sigprocmask64(cpu, a1, a2, a3, a4);
            break;
        case X64_SYS_sigaltstack:
            ret = sys_sigaltstack64(cpu, a1, a2);
            break;
        case X64_SYS_utimensat:
            // utimensat(dirfd, path, times[2], flags) — set file atime/mtime.
            // fontconfig touches its cache files' timestamps; returning -ENOSYS
            // made it retry (43+ calls seen). We don't model per-file mtime
            // precisely, so report success — the cache write itself already
            // persisted the data. (a1=dirfd, a2=path, a3=times, a4=flags.)
            ret = 0;
            break;
        case X64_SYS_set_robust_list:
        case X64_SYS_madvise:
        case X64_SYS_fadvise64:
            // ld-linux makes these calls before main; safe to no-op.
            // fadvise64(fd, offset, len, advice): a pure readahead hint
            // (fontconfig POSIX_FADV_WILLNEED/RANDOM on its cache mmaps).
            // The interpreter has no page cache to advise, so ignoring it is
            // correct — the data is still read on demand.
            ret = 0;
            break;
        case X64_SYS_ioctl: {
            // ioctl(fd, request, arg). The old blanket no-op (return 0) made
            // wine believe a device-type probe on a regular file SUCCEEDED, so
            // it spun forever re-issuing ioctl(0x82307201) on the PE exe it had
            // just opened. But routing blindly to kobject->ioctl is also wrong:
            // the tty/console ioctls (TCGETS, FIONREAD, VT_*, ...) write their
            // result struct back through thread->memory (the 32-bit KMemory),
            // so for a 64-bit guest they scribble the wrong address and fault.
            //
            // For a 64-bit guest the correct, safe answers here are:
            //  - FIONBIO (0x5421): set/clear non-blocking — route to the kobject
            //    via fcntl semantics; the arg is a single int we read ourselves.
            //  - FIONREAD (0x541B): bytes available — we don't track it; report 0.
            //  - everything else (TCGETS device probes, the 0x82307201 query,
            //    KDSKBMUTE, ...): -ENOTTY, which is what a real kernel returns
            //    for a regular file / non-tty and what wine's fallback expects.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
#ifdef BOXEDWINE_DARWIN
            // Darwin_Computa: Darling fires Mach/psynch/kqueue traps as
            // ioctl(/dev/mach, DARLING_MACH_API_BASE + trap, paramv). If this fd
            // is the /dev/mach device, route the (64-bit) paramv to the trap
            // dispatcher, which uses cpu->memory (KMemory64) directly. Detected
            // by the open node's dynamic type, so non-/dev/mach fds are
            // unaffected and the wine path below is untouched.
            {
                KFileDescriptorPtr mfd = cpu->thread->process->getFileDescriptor((FD)(S32)a1);
                if (mfd) {
                    std::shared_ptr<KFile> mkfile = std::dynamic_pointer_cast<KFile>(mfd->kobject);
                    if (mkfile && mkfile->openFile) {
                        S64 r = devMachIoctl(mkfile->openFile, cpu, (U64)a2, (U64)a3);
                        if (r != (S64)-K_ENODEV) { ret = (U64)r; break; }
                        // -ENODEV == "not a DevMach": fall through to the normal
                        // ioctl handling below.
                    }
                }
            }
#endif
            U32 cmd = (U32)a2;
            if (cmd == 0x5421) { // FIONBIO: arg = int* (0=blocking, !=0 nonblocking)
                U32 on = a3 ? cpu->memory->readd(a3) : 0;
                cpu->thread->process->fcntrl(cpu->thread, (FD)(S32)a1, K_F_SETFL,
                                             on ? K_O_NONBLOCK : 0);
                ret = 0;
            } else if (cmd == 0x541B) { // FIONREAD: report 0 bytes pending
                if (a3) cpu->memory->writed(a3, 0);
                ret = 0;
            } else {
                ret = (U64)-K_ENOTTY;
            }
            break;
        }
        case X64_SYS_chdir: {
            // chdir(path) — MUST be real: wine chdir's into its WINEPREFIX and
            // then stats "." to validate it. A no-op left cwd at the (missing)
            // default /home/username, so that "." stat failed with ENOENT and
            // wine reported "could not find the prefix". Route to KProcess::chdir.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            char path[1024] = {0};
            cpu->memory->memcpyFromGuest(path, a1, sizeof(path) - 1);
            ret = (U64)(S64)(S32)cpu->thread->process->chdir(BString::copy(path));
            break;
        }
        case X64_SYS_mremap:
            // mremap(old, oldlen, newlen, flags, newaddr). v1: return old
            // address — glibc malloc only resizes when MREMAP_MAYMOVE is set
            // and tolerates a noop if no growth happens. This is wrong but
            // surfaces obvious failures at the malloc level, not later.
            ret = a1;
            break;
        case X64_SYS_dup:
            if (cpu->thread && cpu->thread->process) {
                U32 newFd = cpu->thread->process->dup((U32)a1);
                ret = (S32)newFd < 0 ? (U64)(S64)(S32)newFd : (U64)newFd;
            } else {
                ret = (U64)-K_ENOSYS;
            }
            break;
        case X64_SYS_dup2:
            if (cpu->thread && cpu->thread->process) {
                U32 newFd = cpu->thread->process->dup2((FD)a1, (FD)a2);
                ret = (S32)newFd < 0 ? (U64)(S64)(S32)newFd : (U64)newFd;
            } else {
                ret = (U64)-K_ENOSYS;
            }
            break;
        case X64_SYS_getcwd: {
            // getcwd(buf, size) — copy current directory string out. Returns
            // a pointer to buf on success, -ERANGE if size is too small.
            if (!a1 || a2 == 0) { ret = (U64)-K_EFAULT; break; }
            // No-process standalone runner: default cwd to "/".
            BString cwd = (cpu->thread && cpu->thread->process)
                              ? cpu->thread->process->currentDirectory : B("/");
            if (!cwd.length()) cwd = B("/");
            U64 need = (U64)cwd.length() + 1;
            if (need > a2) { ret = (U64)-34; /* -ERANGE */ break; }
            cpu->memory->memcpyToGuest(a1, cwd.c_str(), need);
            ret = a1;
            break;
        }
        case X64_SYS_fcntl: {
            // fcntl(fd, cmd, arg). Route to the width-agnostic KProcess::fcntrl,
            // which returns the *real* per-fd state — crucially F_GETFL must
            // report the fd's actual access mode (O_RDONLY/WRONLY/RDWR). The
            // old stub returned 0 (== O_RDONLY) for every get, which made
            // glibc's fdopen(fd, "w") fail with EINVAL when wineserver wrote
            // its registry temp file (O_WRONLY) — that was the "could not save
            // registry branch ... Invalid argument" abort.
            //
            // The lock commands (F_GETLK/F_SETLK/F_SETLKW) take a `struct flock*`
            // in `arg`; fcntrl reads/writes it through thread->memory (the 32-bit
            // KMemory), but for a 64-bit guest the struct lives in cpu->memory
            // (KMemory64). So for those we bounce the flock through the 32-bit
            // scratch and use the 64-bit cmd variant (readFileLock(is64=true)
            // layout: l_type@0 w, l_whence@2 w, l_start@4 q, l_len@12 q,
            // l_pid@20 d — 24 bytes). wineserver F_SETLKs its registry/lock
            // files; without this it page-faulted reading the lock arg from the
            // empty 32-bit memory.
            if (!cpu->thread || !cpu->thread->process || !cpu->thread->memory) {
                ret = (U64)-K_ENOSYS; break;
            }
            U32 cmd = (U32)a2;
            bool isLock = (cmd == K_F_GETLK || cmd == K_F_SETLK || cmd == K_F_SETLKW ||
                           cmd == K_F_GETLK64 || cmd == K_F_SETLK64 || cmd == K_F_SETLKW64);
            if (!isLock) {
                ret = (U64)(S64)(S32)cpu->thread->process->fcntrl(
                    cpu->thread, (FD)(S32)a1, cmd, (U32)a3);
                break;
            }
            // Lock command: marshal the 24-byte 64-bit flock into scratch.
            const U32 FLOCK64_BYTES = 24;
            U32 scratch = bounceSockaddrTo32(cpu, 0, 0, nullptr);
            if (!scratch) { ret = (U64)-K_EFAULT; break; }
            {
                U8 tmp[FLOCK64_BYTES];
                cpu->memory->memcpyFromGuest(tmp, a3, FLOCK64_BYTES);
                cpu->thread->memory->memcpy(scratch, tmp, FLOCK64_BYTES);
            }
            // Use the *64-bit* cmd variant so fcntrl's readFileLock reads the
            // 64-bit layout from the scratch we just populated.
            U32 cmd64 = (cmd == K_F_GETLK)  ? K_F_GETLK64
                      : (cmd == K_F_SETLK)  ? K_F_SETLK64
                      : (cmd == K_F_SETLKW) ? K_F_SETLKW64
                      : cmd;
            ret = (U64)(S64)(S32)cpu->thread->process->fcntrl(
                cpu->thread, (FD)(S32)a1, cmd64, scratch);
            // F_GETLK writes the resulting lock back into the struct.
            if (cmd == K_F_GETLK || cmd == K_F_GETLK64) {
                U8 tmp[FLOCK64_BYTES];
                cpu->thread->memory->memcpy(tmp, scratch, FLOCK64_BYTES);
                cpu->memory->memcpyToGuest(a3, tmp, FLOCK64_BYTES);
            }
            break;
        }
        case X64_SYS_tkill:   // tkill(tid, sig)         — a2 unused (tid in a1)
        case X64_SYS_tgkill: { // tgkill(tgid, tid, sig) — tid in a2
            // Deliver a signal to a specific thread, possibly in ANOTHER process.
            // wineserver does exactly this: send_thread_signal() (server/ptrace.c)
            // does tkill/tgkill(client_pid, client_tid, SIGUSR1) to make a client
            // thread run a queued APC. The old handler only ever signaled SELF
            // (returned ESRCH for any tid != our own), so wineserver's APC
            // delivery ALWAYS failed -> queue_apc() returned 0 -> async_terminate
            // fell through to a SYNCHRONOUS async_set_result that dropped the
            // async-queue's reference EARLY -> free_async_queue then released it
            // AGAIN -> the deterministic teardown double-free (bug #2: the
            // release_object refcount assert / tcache / double-linked-list faces).
            // Now: tgkill carries tid in a2, tkill in a1; route cross-thread
            // through a real per-thread delivery.
            bool isTgkill = (nr == X64_SYS_tgkill);
            U32 targetTid = (U32)(isTgkill ? a2 : a1);
            U32 sig       = (U32)(isTgkill ? a3 : a2);
            U64 ourTid    = cpu->thread ? (U64)cpu->thread->id : 1;
            if (targetTid != (U32)ourTid) {
                KThread* target = KSystem::getThreadById(targetTid);
                if (!target) { ret = (U64)-K_ESRCH; break; }
                if (sig == 0) { ret = 0; break; } // liveness probe — target exists
                // Don't arm a pending signal on a thread that is already tearing
                // down: it will never reach a normal scheduler slice to take it,
                // and a thread parked in futex64's wait loop during exit would
                // otherwise keep trying to deliver it mid-kill — a teardown
                // deadlock. The caller still sees success (the thread is on its
                // way out, which is what a signal would have accomplished).
                if (target->terminating) { ret = 0; break; }
                // Async cross-thread delivery: arm the target's pending-signal;
                // the 64-bit scheduler delivers it (deliverSignalSync) at the
                // target's next slice, before it runs guest code. We can't build
                // a signal frame here because the target may be executing on a
                // different host thread.
                {
                    BOXEDWINE_CRITICAL_SECTION_WITH_MUTEX(target->pendingSignalsMutex);
                    target->pendingSignals |= (1ULL << (sig - 1));
                }
                ret = 0;
                break;
            }
            if (sig == 0) {
                // sig=0 to our own tid is a liveness probe — we're alive.
                ret = 0;
                break;
            }
            // Set RAX to the syscall's return value *before* building the
            // signal frame so the frame captures RAX=0 (success). Otherwise
            // rt_sigreturn restores RAX to whatever was in it at entry
            // (the syscall number 234), and userspace sees tgkill "fail".
            cpu->reg[X64_RAX].setU64(0);
            if (deliverSignalSync(cpu, sig)) {
                // Handler will run next; ret=0 (kernel reports success
                // *before* handler runs, and the syscall return value is
                // overwritten by RAX-restore at rt_sigreturn anyway).
                ret = 0;
            } else {
                // No handler installed / SIG_DFL / SIG_IGN. For a signal whose
                // default action is fatal (SIGABRT from abort(), SIGSEGV, SIGILL,
                // SIGFPE, SIGKILL, ...) we must terminate the process like the
                // real kernel — otherwise the guest keeps executing past its own
                // abort() and runs into garbage (a stray HLT, a re-raise loop).
                // SIG_IGN'd or non-fatal-default signals (SIGCHLD/SIGURG/SIGWINCH)
                // are correctly dropped.
                bool ignored = (sig >= 1 && sig <= 64) &&
                               cpu->sigActions[sig].installed &&
                               cpu->sigActions[sig].handler == 1 /*SIG_IGN*/;
                if (sigDefaultIsFatal(sig) && !ignored) {
                    klog_fmt("ksyscall64: tgkill self sig=%u (fatal default) — terminating process", sig);
                    // BW64_ABRTBT: log the abort RIP + any return addresses on the
                    // stack so the failing image/site can be located. (A Mach-O
                    // header back-walk was tried and removed — this Darling dyld
                    // does not keep image headers contiguous with code at runtime,
                    // so frames must be mapped via the slide trick offline.)
                    if (getenv("BW64_ABRTBT") && cpu->memory) {
                        U64 sp = cpu->reg[X64_RSP].u64;
                        klog_fmt("ABRTBT: RIP=0x%llx RSP=0x%llx", (unsigned long long)cpu->rip, (unsigned long long)sp);
                        for (int i = 0; i < 48; i++) {
                            U64 w = cpu->memory->readq(sp + i * 8);
                            if (w >= 0x100000000ULL && w < 0x800000000ULL)
                                klog_fmt("ABRTBT:   [rsp+0x%x]=0x%llx", i * 8, (unsigned long long)w);
                        }
                        // The abort actually originates in the HOST glibc linked
                        // into mldr/launchd (the RIP is libc's pthread_kill, called
                        // from raise() from abort()). glibc stashes the abort
                        // message in its global `__abort_msg` pointer. The faulting
                        // RIP is pthread_kill+0x11c, and pthread_kill sits at libc
                        // vaddr 0x9ea10, so libc base = RIP - 0x9eb2c; __abort_msg
                        // global is at libc vaddr 0x204b40 and points to
                        //   struct { unsigned size; unsigned unused; char msg[]; }
                        // (string at +8). Print it — it names the assert directly.
                        {
                            U64 libcBase = cpu->rip - 0x9eb2cULL;
                            U64 abortMsgPtr = cpu->memory->readq(libcBase + 0x204b40ULL);
                            klog_fmt("ABRTBT: glibc base=0x%llx __abort_msg=0x%llx",
                                     (unsigned long long)libcBase, (unsigned long long)abortMsgPtr);
                            if (abortMsgPtr >= 0x1000) {
                                char msg[512] = {0};
                                cpu->memory->memcpyFromGuest(msg, abortMsgPtr + 8, sizeof(msg) - 1);
                                klog_fmt("ABRTBT: glibc abort message: %s", msg);
                            }
                        }
#ifdef BOXEDWINE_DARWIN
                        // Symbolize the abort RIP (and the in-range stack frames)
                        // against the guest's dyld_all_image_infos image list.
                        if (cpu->thread && cpu->thread->process) {
                            bw64_dumpDyldImages(cpu->thread->process->id, cpu->rip);
                        }
#endif
                    }
                    cpu->yield = true;
                    if (cpu->thread && cpu->thread->process) {
                        cpu->thread->process->exitgroup(cpu->thread, 128 + sig);
                    }
                    ret = 0;
                } else {
                    klog_fmt("ksyscall64: tgkill self sig=%u — no handler, default non-fatal/ignored", sig);
                    ret = 0;
                }
            }
            break;
        }
        case X64_SYS_rt_sigreturn: {
            // x86-64 ABI: at signal-delivery time the kernel set
            //   RSP = uctxPtr - 8     // points at pushed restorer_addr
            // The handler's terminating `ret` pops that slot, leaving
            //   RSP = uctxPtr         // which is what the restorer sees
            // before issuing `syscall rt_sigreturn`. The ucontext_t
            // therefore lives at the *current* RSP. We read all
            // gprs/rip/rflags/sigmask out of it and overwrite our state.
            // The saved RAX becomes the syscall return value (kernel
            // restores the pre-signal RAX, *not* a sigreturn status).
            if (!cpu->memory) { ret = (U64)-K_EFAULT; break; }
            U64 uctxPtr = cpu->reg[X64_RSP].u64;
            ret = restoreSignalFrame(cpu, uctxPtr);
            // restoreSignalFrame wrote rip/rsp/gprs (all except RAX) directly.
            // The dispatcher writes `ret` (savedRax) into RAX after the break,
            // completing the restore. The cpu->rip we just wrote is final —
            // SYSCALL only advances RIP *before* ksyscall64() is invoked, so
            // our mid-handler write to cpu->rip survives.
            break;
        }
        case X64_SYS_read:
            ret = sys_read64(cpu, a1, a2, a3);
            break;
        case X64_SYS_open:
        case X64_SYS_openat:
            // open(path, flags, mode) — same arg layout once we shift one.
            if (nr == X64_SYS_open) ret = sys_openat64(cpu, ~0ULL, a1, a2, a3);
            else                    ret = sys_openat64(cpu, a1,    a2, a3, a4);
            break;
        case X64_SYS_close:
            ret = sys_close64(cpu, a1);
            break;
        case X64_SYS_fstat:
            ret = sys_fstat64(cpu, a1, a2);
            break;
        case X64_SYS_stat:
            ret = sys_stat_path64(cpu, a1, a2, true);
            break;
        case X64_SYS_lstat:
            ret = sys_stat_path64(cpu, a1, a2, false);
            break;
        case X64_SYS_newfstatat:
            ret = sys_newfstatat64(cpu, a1, a2, a3, a4);
            break;
        case X64_SYS_statfs:
            // a1 = path (ignored — same lie for every fs), a2 = struct statfs*
            ret = sys_statfs64_common(cpu, a2);
            break;
        case X64_SYS_fstatfs:
            // a1 = fd (ignored), a2 = struct statfs*
            ret = sys_statfs64_common(cpu, a2);
            break;
        // Extended attributes: our guest FS has none. get*xattr -> -ENODATA
        // ("attribute does not exist"), the answer Linux gives for a file with
        // no xattrs — this is what wine's ntdll probes for and tolerates. The
        // set*/list*/remove* variants likewise report "unsupported/empty".
        // Without these, wine64 startup tripped the unimplemented-syscall path
        // (#191 getxattr) during prefix/service bring-up.
        case 191: // getxattr
        case 192: // lgetxattr
        case 193: // fgetxattr
            ret = (U64)-K_ENODATA;
            break;
        case 194: // listxattr
        case 195: // llistxattr
        case 196: // flistxattr
            ret = 0; // empty attribute list
            break;
        case 188: // setxattr
        case 189: // lsetxattr
        case 190: // fsetxattr
        case 197: // removexattr
        case 198: // lremovexattr
        case 199: // fremovexattr
            ret = (U64)-K_ENOTSUP;
            break;
        case X64_SYS_lseek:
            ret = sys_lseek64(cpu, a1, a2, a3);
            break;
        case X64_SYS_pread64:
            ret = sys_pread64(cpu, a1, a2, a3, a4);
            break;
        case X64_SYS_readlink:
            ret = sys_readlink64(cpu, a1, a2, a3);
            break;
        case X64_SYS_readlinkat:
            // readlinkat(dirfd, path, buf, bufsiz). Modern glibc/wine ntdll use
            // THIS, not readlink(89), to resolve /proc/self/exe (the basis for
            // wine's loader/module dir derivation). dirfd is AT_FDCWD or the
            // path is absolute (/proc/self/exe is), so we can ignore dirfd and
            // reuse the readlink resolver on (path=a2, buf=a3, sz=a4).
            ret = sys_readlink64(cpu, a2, a3, a4);
            break;
        case X64_SYS_access:
        case X64_SYS_faccessat:
        case X64_SYS_faccessat2: {
            // access(path, mode) / faccessat(dirfd, path, mode[, flags]) /
            // faccessat2(dirfd, path, mode, flags). We don't model EUID perms
            // yet, so existence is the only check (mode/flags ignored). For the
            // *at forms the path is arg2 (dirfd is AT_FDCWD or the path is
            // absolute — wine probes ntdll.so by absolute path). wine uses
            // faccessat/faccessat2 to confirm its module dir before loading
            // ntdll, so without these it reports "cannot get path to ntdll.so".
            // Standalone runner (no KProcess) -> ENOENT, matching ld.so probes.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-2; break; }
            U64 pathArg = (nr == X64_SYS_access) ? a1 : a2;
            char path[1024] = {0};
            cpu->memory->memcpyFromGuest(path, pathArg, sizeof(path) - 1);
            std::shared_ptr<FsNode> n = Fs::getNodeFromLocalPath(
                cpu->thread->process->currentDirectory, BString::copy(path), true);
            ret = n ? 0 : (U64)-2;
            break;
        }
        case X64_SYS_mkdir:
        case X64_SYS_mkdirat: {
            // mkdir(path, mode) / mkdirat(dirfd, path, mode). wineboot creates
            // its prefix tree (WINEPREFIX, drive_c, windows, ...) through these.
            // path is arg1 (mkdir) or arg2 (mkdirat); dirfd is AT_FDCWD or the
            // path is absolute. Routes to the existing KProcess mkdir, which
            // writes into the native (writable) root overlay.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            U64 pathArg = (nr == X64_SYS_mkdir) ? a1 : a2;
            char path[1024] = {0};
            cpu->memory->memcpyFromGuest(path, pathArg, sizeof(path) - 1);
            BString full = Fs::getFullPath(cpu->thread->process->currentDirectory,
                                           BString::copy(path));
            ret = (U64)(S64)(S32)cpu->thread->process->mkdir(full);
            if (getenv("BW64_SYSTRACE")) {
                klog_fmt("sys_mkdir64: '%s' full='%s' -> %d", path, full.c_str(),
                         (int)(S32)ret);
            }
            break;
        }
        case X64_SYS_symlink:
        case X64_SYS_symlinkat: {
            // symlink(target, linkpath) / symlinkat(target, dirfd, linkpath).
            // wineboot builds dosdevices/c: -> ../drive_c and z: -> / symlinks
            // when initializing the prefix. target is arg1; linkpath is arg2
            // (symlink) or arg3 (symlinkat, dirfd=arg2 is AT_FDCWD/absolute).
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            char target[1024] = {0};
            char linkpath[1024] = {0};
            cpu->memory->memcpyFromGuest(target, a1, sizeof(target) - 1);
            U64 linkArg = (nr == X64_SYS_symlink) ? a2 : a3;
            cpu->memory->memcpyFromGuest(linkpath, linkArg, sizeof(linkpath) - 1);
            BString fullLink = Fs::getFullPath(cpu->thread->process->currentDirectory,
                                               BString::copy(linkpath));
            ret = (U64)(S64)(S32)cpu->thread->process->symlink(
                BString::copy(target), fullLink);
            if (getenv("BW64_SCDUMP")) {
                klog_fmt("sys_symlink64: target='%s' link='%s' (cwd='%s') -> %d",
                         target, fullLink.c_str(),
                         cpu->thread->process->currentDirectory.c_str(), (int)(S32)ret);
            }
            break;
        }
        case X64_SYS_link:
        case X64_SYS_linkat: {
            // link(oldpath, newpath) / linkat(olddirfd, oldpath, newdirfd,
            // newpath, flags). fontconfig builds its on-disk cache atomically by
            // writing a temp file, link()-ing it to the final cache name, then
            // unlink()-ing the temp — so a missing link() leaves the cache
            // perpetually un-built and fontconfig re-scans every font dir on
            // every process launch (the boot-storm font-scan loop). Route to
            // KProcess::link, which hard-links (or copies) in the writable
            // overlay. linkat's dirfds are AT_FDCWD/absolute in this path.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            U64 oldArg = (nr == X64_SYS_link) ? a1 : a2;
            U64 newArg = (nr == X64_SYS_link) ? a2 : a4;
            char oldp[1024] = {0};
            char newp[1024] = {0};
            cpu->memory->memcpyFromGuest(oldp, oldArg, sizeof(oldp) - 1);
            cpu->memory->memcpyFromGuest(newp, newArg, sizeof(newp) - 1);
            BString fullOld = Fs::getFullPath(cpu->thread->process->currentDirectory,
                                              BString::copy(oldp));
            BString fullNew = Fs::getFullPath(cpu->thread->process->currentDirectory,
                                              BString::copy(newp));
            ret = (U64)(S64)(S32)cpu->thread->process->link(fullOld, fullNew);
            if (getenv("BW64_SCDUMP")) {
                klog_fmt("sys_link64: old='%s' new='%s' -> %d",
                         fullOld.c_str(), fullNew.c_str(), (int)(S32)ret);
            }
            break;
        }
        case X64_SYS_rename:
        case X64_SYS_renameat:
        case X64_SYS_renameat2: {
            // rename(from, to) / renameat(olddirfd, from, newdirfd, to) /
            // renameat2(olddirfd, from, newdirfd, to, flags). wineserver saves
            // each registry branch by writing a temp file and rename()-ing it
            // into place (system.reg/user.reg/userdef.reg) — without this the
            // prefix never persists ("could not save registry branch ... :
            // Invalid argument"). Reuse KProcess::rename/renameat, which route
            // through the FsNode layer to the native rename in the writable
            // overlay. renameat2 with a plain (flags==0) rename is identical to
            // renameat; the NOREPLACE/EXCHANGE/WHITEOUT flag bits aren't
            // supported, so reject them with EINVAL (glibc/wine fall back to a
            // plain rename when renameat2 fails).
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            char from[1024] = {0};
            char to[1024] = {0};
            if (nr == X64_SYS_rename) {
                cpu->memory->memcpyFromGuest(from, a1, sizeof(from) - 1);
                cpu->memory->memcpyFromGuest(to,   a2, sizeof(to) - 1);
                ret = (U64)(S64)(S32)cpu->thread->process->rename(
                    BString::copy(from), BString::copy(to));
            } else {
                if (nr == X64_SYS_renameat2 && (a5 & ~0ULL) != 0) {
                    // any flag set -> unsupported in this path
                    ret = (U64)-K_EINVAL; break;
                }
                FD olddirfd = (FD)(S32)a1;
                FD newdirfd = (FD)(S32)a3;
                cpu->memory->memcpyFromGuest(from, a2, sizeof(from) - 1);
                cpu->memory->memcpyFromGuest(to,   a4, sizeof(to) - 1);
                ret = (U64)(S64)(S32)cpu->thread->process->renameat(
                    olddirfd, BString::copy(from), newdirfd, BString::copy(to));
            }
            if (getenv("BW64_SYSTRACE")) {
                klog_fmt("sys_rename64: '%s' -> '%s' ret=%d", from, to, (int)(S32)ret);
            }
            break;
        }
        case X64_SYS_socketpair: {
            // socketpair(domain, type, protocol, sv[2]). wineserver's first IPC
            // call — it creates the AF_UNIX request/reply channel. Reuse the
            // socket-object wiring (ksocketpairFds, no guest-memory access) and
            // write the two FDs into memory64 (pointer-free 4-byte ints, same
            // layout 32/64). `type` carries SOCK_CLOEXEC/NONBLOCK flag bits.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            U32 type = (U32)a2 & 0xFF;
            U32 sockFlags = (U32)a2 & ~0xFFu; // SOCK_CLOEXEC(0x80000)/NONBLOCK(0x800)
            U32 passFlags = 0;
            if (sockFlags & 0x80000) passFlags |= K_O_CLOEXEC;
            if (sockFlags & 0x800)   passFlags |= K_O_NONBLOCK;
            FD fd1 = 0, fd2 = 0;
            S32 rc = ksocketpairFds(cpu->thread, (U32)a1, type, (U32)a3, passFlags, fd1, fd2);
            if (rc) { ret = (U64)(S64)rc; break; }
            cpu->memory->writed(a4, (U32)fd1);
            cpu->memory->writed(a4 + 4, (U32)fd2);
            ret = 0;
            break;
        }
        case X64_SYS_shutdown:
            // shutdown(sockfd, how). No guest memory; reuse the 32-bit handler.
            // wineserver's sock_check_pollhup shuts down one end of its pair to
            // probe POLLHUP behaviour during init.
            if (!cpu->thread) { ret = (U64)-K_ENOSYS; break; }
            ret = (U64)(S64)(S32)kshutdown(cpu->thread, (U32)a1, (U32)a2);
            break;
        case X64_SYS_socket: {
            // socket(domain, type, protocol). wineserver creates its listening
            // AF_UNIX socket. ksocket takes no guest memory — call directly. The
            // type's high bits are SOCK_CLOEXEC(0x80000)/SOCK_NONBLOCK(0x800);
            // strip them for ksocket and apply via fcntl after.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            U32 sockType = (U32)a2 & 0xFF;
            FD sfd = (FD)(S32)ksocket((U32)a1, sockType, (U32)a3);
            if ((S32)sfd >= 0) {
                if ((U32)a2 & 0x80000) cpu->thread->process->fcntrl(cpu->thread, sfd, K_F_SETFD, FD_CLOEXEC);
                if ((U32)a2 & 0x800)   cpu->thread->process->fcntrl(cpu->thread, sfd, K_F_SETFL, K_O_NONBLOCK);
            }
            ret = (U64)(S64)(S32)sfd;
            break;
        }
        case X64_SYS_bind: {
            // bind(sockfd, addr, addrlen) — wineserver binds its listening
            // AF_UNIX socket (wineserver.sock). Bounce the sockaddr into 32-bit
            // scratch and reuse kbind + the object layer.
            if (!cpu->thread) { ret = (U64)-K_ENOSYS; break; }
            U32 s32 = bounceSockaddrTo32(cpu, a2, (U32)a3, nullptr);
            if (!s32) { ret = (U64)-K_EFAULT; break; }
            ret = (U64)(S64)(S32)kbind(cpu->thread, (U32)a1, s32, (U32)a3);
            break;
        }
        case X64_SYS_connect: {
            // connect(sockfd, addr, addrlen) — wine64 connects to wineserver's
            // socket. Same bounce.
            if (!cpu->thread) { ret = (U64)-K_ENOSYS; break; }
            U32 s32 = bounceSockaddrTo32(cpu, a2, (U32)a3, nullptr);
            if (!s32) { ret = (U64)-K_EFAULT; break; }
            ret = (U64)(S64)(S32)kconnect(cpu->thread, (U32)a1, s32, (U32)a3);
            if (getenv("BW64_SCDUMP")) {
                // sockaddr_un: family@0 (2), sun_path@2. sockaddr_in: family@0,
                // port@2 (BE u16), addr@4 (BE u32). Decode both so we can tell a
                // unix X11 connect (/tmp/.X11-unix/X0) from a TCP X connect
                // (port 6000+display) from plain DNS.
                U16 fam = cpu->memory->readw(a2);
                char detail[128] = {0};
                if (fam == 1 /*AF_UNIX*/) {
                    cpu->memory->memcpyFromGuest(detail, a2 + 2, sizeof(detail) - 1);
                } else if (fam == 2 /*AF_INET*/) {
                    U16 portBE = cpu->memory->readw(a2 + 2);
                    U32 ipBE   = cpu->memory->readd(a2 + 4);
                    U16 port = (U16)((portBE >> 8) | (portBE << 8));
                    snprintf(detail, sizeof(detail), "%u.%u.%u.%u:%u",
                             (ipBE) & 0xff, (ipBE >> 8) & 0xff,
                             (ipBE >> 16) & 0xff, (ipBE >> 24) & 0xff, port);
                } else {
                    snprintf(detail, sizeof(detail), "(family %d)", (int)fam);
                }
                klog_fmt("sys_connect64: fd=%d family=%d %s -> %d",
                         (int)a1, (int)fam, detail, (int)(S32)ret);
            }
            break;
        }
        case X64_SYS_listen:
            // listen(sockfd, backlog) — no guest memory.
            if (!cpu->thread) { ret = (U64)-K_ENOSYS; break; }
            ret = (U64)(S64)(S32)klisten(cpu->thread, (U32)a1, (U32)a2);
            break;
        case X64_SYS_accept: {
            // accept(sockfd, addr, addrlen) — wineserver accepts a wine64 client.
            // addr/addrlen are optional out-params; pass a scratch slot when set
            // and copy the result back to memory64.
            if (!cpu->thread) { ret = (U64)-K_ENOSYS; break; }
            U32 lenSlot = 0;
            U32 s32 = a2 ? bounceSockaddrTo32(cpu, 0, 256, &lenSlot) : 0;
            ret = (U64)(S64)(S32)kaccept(cpu->thread, (U32)a1, s32, lenSlot, 0);
            // (peer sockaddr writeback omitted — AF_UNIX accept returns an empty
            // name; wine doesn't rely on it for the server connection.)
            break;
        }
        case X64_SYS_getsockname:
        case X64_SYS_getpeername: {
            // get{sock,peer}name(fd, addr, addrlen*). Bounce; copy the resulting
            // sockaddr + length back into memory64.
            if (!cpu->thread || !a2 || !a3) { ret = (U64)-K_EFAULT; break; }
            U32 inLen = cpu->memory->readd(a3);
            U32 lenSlot = 0;
            U32 s32 = bounceSockaddrTo32(cpu, 0, inLen, &lenSlot);
            if (!s32) { ret = (U64)-K_EFAULT; break; }
            U32 rc = (nr == X64_SYS_getsockname)
                ? kgetsockname(cpu->thread, (U32)a1, s32, lenSlot)
                : kgetpeername(cpu->thread, (U32)a1, s32, lenSlot);
            if ((S32)rc >= 0) {
                U32 outLen = cpu->thread->memory->readd(lenSlot);
                if (outLen > 256) outLen = 256;
                U8 tmp[256];
                cpu->thread->memory->memcpy(tmp, s32, outLen);
                cpu->memory->memcpyToGuest(a2, tmp, outLen);
                cpu->memory->writed(a3, outLen);
            }
            ret = (U64)(S64)(S32)rc;
            break;
        }
        case X64_SYS_fchdir:
            // fchdir(fd) — chdir to a directory held open by descriptor. No
            // guest memory. wineserver fchdir's into the prefix's server dir;
            // without it, it mapped ENOSYS to a file error and asserted.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            ret = (U64)(S64)(S32)cpu->thread->process->fchdir((FD)a1);
            break;
        case X64_SYS_ftruncate:
            // ftruncate(fd, length) — wineserver sizes its registry/mapping
            // files. No guest memory.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            ret = (U64)(S64)(S32)cpu->thread->process->ftruncate64((FD)a1, a2);
            break;
        case X64_SYS_umask:
            // umask(mask) — returns the previous mask. wine sets it during init.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            ret = (U64)cpu->thread->process->umask((U32)a1);
            break;
        case X64_SYS_setsockopt: {
            // setsockopt(fd, level, name, optval, optlen). wineserver sets
            // socket options (SO_PASSCRED etc.) on its connection. optval is a
            // small pointer-free buffer — bounce it into 32-bit scratch.
            if (!cpu->thread) { ret = (U64)-K_ENOSYS; break; }
            U32 optlen = (U32)a5;
            U32 v32 = (a4 && optlen) ? bounceSockaddrTo32(cpu, a4, optlen, nullptr) : 0;
            ret = (U64)(S64)(S32)ksetsockopt(cpu->thread, (U32)a1, (U32)a2, (U32)a3, v32, optlen);
            break;
        }
        case X64_SYS_getsockopt: {
            // getsockopt(fd, level, name, optval, optlen*). optlen is a pointer
            // to socklen_t (in/out). Bounce optval + the length slot, run the
            // helper, copy the result + new length back to memory64.
            if (!cpu->thread || !a5) { ret = (U64)-K_EFAULT; break; }
            U32 inLen = cpu->memory->readd(a5);
            U32 lenSlot = 0;
            U32 v32 = bounceSockaddrTo32(cpu, a4, inLen, &lenSlot);
            if (!v32) { ret = (U64)-K_EFAULT; break; }
            U32 rc = kgetsockopt(cpu->thread, (U32)a1, (U32)a2, (U32)a3, v32, lenSlot);
            if ((S32)rc >= 0) {
                U32 outLen = cpu->thread->memory->readd(lenSlot);
                if (outLen > 256) outLen = 256;
                U8 tmp[256];
                cpu->thread->memory->memcpy(tmp, v32, outLen);
                cpu->memory->memcpyToGuest(a4, tmp, outLen);
                cpu->memory->writed(a5, outLen);
            }
            ret = (U64)(S64)(S32)rc;
            break;
        }
        case X64_SYS_sendmsg:
            // sendmsg(fd, msghdr*, flags) — the wineserver request channel.
            ret = sys_sendmsg64(cpu, a1, a2, a3);
            break;
        case X64_SYS_recvmsg:
            // recvmsg(fd, msghdr*, flags) — the wineserver reply channel
            // (carries SCM_RIGHTS fds for shared mappings).
            ret = sys_recvmsg64(cpu, a1, a2, a3);
            break;
        case X64_SYS_sendto:
        case X64_SYS_recvfrom: {
            // sendto(fd, buf, len, flags, dest_addr, addrlen) /
            // recvfrom(fd, buf, len, flags, src_addr, addrlen). wine's unix ntdll
            // uses these on the (connected AF_UNIX) wineserver socket, so the
            // addr argument is unused — pass NULL addr to k*. Bounce the data
            // buffer through the 32-bit msg scratch (k* read/write thread->memory)
            // and copy results back to the 64-bit guest buffer via cpu->memory.
            if (!cpu->thread || !cpu->thread->process || !cpu->thread->memory) {
                ret = (U64)-K_ENOSYS; break;
            }
            U32 scratch = msgScratch(cpu->thread);
            if (!scratch) { ret = (U64)-K_EFAULT; break; }
            U32 dataAddr = scratch + MSG_SCRATCH_DATA;
            U32 cap = MSG_SCRATCH_BYTES - MSG_SCRATCH_DATA;
            U64 len = a3; if (len > cap) len = cap;
            if (nr == X64_SYS_sendto) {
                U8 tmp[4096];
                U64 off = 0;
                // copy guest buffer -> 32-bit scratch in chunks
                while (off < len) {
                    U32 chunk = (U32)((len - off > sizeof(tmp)) ? sizeof(tmp) : (len - off));
                    cpu->memory->memcpyFromGuest(tmp, a2 + off, chunk);
                    cpu->thread->memory->memcpy(dataAddr + (U32)off, tmp, chunk);
                    off += chunk;
                }
                // Translate the destination sockaddr (a5, a6) into the scratch and
                // pass it to ksendto. Dropping it (the old code passed 0,0) breaks
                // any sendto on an UNCONNECTED AF_UNIX dgram socket: the darling
                // S2C push_reply is exactly such a send — libsystem_kernel's
                // __dserver_rpc_hooks_push_reply does sendto(rpc_fd, reply, len, 0,
                // &darlingserver_addr, addrlen) to return an S2C op result. With the
                // dest dropped the reply never reached darlingserver, the S2C never
                // completed, and launchd's mach_msg_overwrite aborted with -107.
                // sockaddr_un is layout-identical 32/64-bit (family + path), so a
                // byte copy into MSG_SCRATCH_NAME is correct.
                U32 destAddr32 = 0, destLen32 = 0;
                if (a5 && a6) {
                    U32 dl = (U32)a6; if (dl > 128) dl = 128;
                    std::vector<U8> sa((size_t)dl);
                    cpu->memory->memcpyFromGuest(sa.data(), a5, dl);
                    cpu->thread->memory->memcpy(scratch + MSG_SCRATCH_NAME, sa.data(), dl);
                    destAddr32 = scratch + MSG_SCRATCH_NAME;
                    destLen32 = dl;
                }
                ret = (U64)(S64)(S32)ksendto(cpu->thread, (U32)a1, dataAddr, (U32)len,
                                             (U32)a4, destAddr32, destLen32);
            } else {
                static const bool kqtrace = getenv("BW64_KQTRACE") != nullptr;
                if (kqtrace) {
                    klog_fmt("KQTRACE pid=%d tid=%d recvfrom ENTER fd=%d len=%d flags=%x",
                             (int)(cpu->thread->process?cpu->thread->process->id:-1),
                             (int)cpu->thread->id, (int)a1, (int)len, (int)a4);
                }
                S32 rc = (S32)krecvfrom(cpu->thread, (U32)a1, dataAddr, (U32)len,
                                        (U32)a4, 0, 0);
                if (kqtrace) {
                    U32 b0=0,b1=0,b2=0;
                    if (rc >= 4) b0 = cpu->thread->memory->readd(dataAddr);
                    if (rc >= 8) b1 = cpu->thread->memory->readd(dataAddr+4);
                    if (rc >= 12) b2 = cpu->thread->memory->readd(dataAddr+8);
                    klog_fmt("KQTRACE pid=%d tid=%d recvfrom EXIT fd=%d rc=%d bytes=[%08x %08x %08x]",
                             (int)(cpu->thread->process?cpu->thread->process->id:-1),
                             (int)cpu->thread->id, (int)a1, (int)rc, b0, b1, b2);
                }
                if (rc > 0) {
                    U8 tmp[4096];
                    U64 off = 0;
                    while (off < (U64)rc) {
                        U32 chunk = (U32)(((U64)rc - off > sizeof(tmp)) ? sizeof(tmp) : ((U64)rc - off));
                        cpu->thread->memory->memcpy(tmp, dataAddr + (U32)off, chunk);
                        cpu->memory->memcpyToGuest(a2 + off, tmp, chunk);
                        off += chunk;
                    }
                }
                ret = (U64)(S64)rc;
            }
            break;
        }
        case X64_SYS_sendmmsg:
        case X64_SYS_recvmmsg: {
            // sendmmsg(fd, mmsghdr* msgvec, vlen, flags[, timeout]) /
            // recvmmsg(...). wine's unix ntdll uses sendmmsg on the wineserver
            // socket. struct mmsghdr = { struct msghdr msg_hdr; unsigned msg_len }:
            // the x86-64 msghdr is 56 bytes, msg_len at +56, stride 64 (8-byte
            // aligned). Loop the existing single-message 64-bit path over each
            // entry, writing back the per-message byte count, and return the
            // number of messages processed (Linux semantics). Stop early on the
            // first error after >=1 success (like the kernel).
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            U64 fd = a1, vec = a2; U32 vlen = (U32)a3; U64 flags = a4;
            const U64 MMSG_STRIDE = 64;   // sizeof(struct mmsghdr) on x86-64
            const U64 MSGLEN_OFF  = 56;   // offsetof(mmsghdr, msg_len)
            U32 done = 0;
            S64 lastErr = 0;
            for (U32 i = 0; i < vlen; i++) {
                U64 hdr = vec + i * MMSG_STRIDE;
                S64 rc = (nr == X64_SYS_sendmmsg)
                       ? (S64)(S32)sys_sendmsg64(cpu, fd, hdr, flags)
                       : (S64)(S32)sys_recvmsg64(cpu, fd, hdr, flags);
                if (rc < 0) { lastErr = rc; break; }
                cpu->memory->writed(hdr + MSGLEN_OFF, (U32)rc);
                done++;
            }
            ret = done ? (U64)done : (U64)lastErr;
            break;
        }
        case X64_SYS_process_vm_readv:
        case X64_SYS_process_vm_writev: {
            // process_vm_readv(pid, local_iov, liovcnt, remote_iov, riovcnt, flags)
            // and the writev counterpart: copy directly between THIS process's
            // address space (local_iov) and the target pid's (remote_iov), no
            // ptrace stop needed. darlingserver uses readv to fetch a checking-in
            // process's strings/structs (e.g. the executable path in
            // set_executable_path) — without it the checkin RPC fails and mldr
            // aborts ("Failed to tell darlingserver about our executable path").
            // Each struct iovec is { void* iov_base (8), size_t iov_len (8) }.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            bool isRead = (nr == X64_SYS_process_vm_readv);
            U32 targetPid = (U32)a1;
            U64 localIov = a2; U64 liovcnt = a3;
            U64 remoteIov = a4; U64 riovcnt = a5;
            KProcessPtr target = KSystem::getProcess(targetPid);
            if (getenv("BW64_VMRW")) {
                klog_fmt("VMRW: pid=%d %s target=%u found=%d liovcnt=%llu riovcnt=%llu",
                         (int)cpu->thread->process->id, isRead ? "readv" : "writev",
                         targetPid, target ? 1 : 0,
                         (unsigned long long)liovcnt, (unsigned long long)riovcnt);
            }
            if (!target) { ret = (U64)-K_ESRCH; break; }
            KMemory64* localMem  = cpu->memory;          // this process's 64-bit mem
            KMemory64* remoteMem = target->memory64;     // target's 64-bit mem
            if (!remoteMem) { ret = (U64)-K_EFAULT; break; }
            // Walk both iovec lists in lockstep, transferring min(local_remaining,
            // remote_remaining) bytes at a time via a host bounce buffer. Returns
            // the total bytes transferred (Linux semantics).
            U64 total = 0;
            U64 li = 0, ri = 0;          // current local/remote iovec index
            U64 lOff = 0, rOff = 0;      // byte offset within the current iovec
            while (li < liovcnt && ri < riovcnt) {
                U64 lBase = cpu->memory->readq(localIov + li * 16);
                U64 lLen  = cpu->memory->readq(localIov + li * 16 + 8);
                U64 rBase = cpu->memory->readq(remoteIov + ri * 16);
                U64 rLen  = cpu->memory->readq(remoteIov + ri * 16 + 8);
                U64 lRem = (lOff < lLen) ? (lLen - lOff) : 0;
                U64 rRem = (rOff < rLen) ? (rLen - rOff) : 0;
                if (lRem == 0) { li++; lOff = 0; continue; }
                if (rRem == 0) { ri++; rOff = 0; continue; }
                U64 chunk = (lRem < rRem) ? lRem : rRem;
                if (chunk > 65536) chunk = 65536; // bounce in bounded steps
                std::vector<U8> buf((size_t)chunk);
                if (isRead) {
                    // BW64_S2C: for a LARGE remote read (the OOL Mach buffer the
                    // S2C path copies out), probe how many source pages are
                    // actually committed. memcpyFromGuest ZERO-FILLS uncommitted
                    // pages, so an OOL region that the sender only reserved (lazy
                    // commit) would be read as zeros here -> a corrupt Mach msg ->
                    // launchd mach_msg -107. Count committed vs total pages touched.
                    if (getenv("BW64_S2C") && rLen >= 0x100000) {
                        U64 pg0 = (rBase + rOff) >> 12;
                        U64 pgN = ((rBase + rOff + chunk - 1) >> 12);
                        U64 comm = 0, tot = 0;
                        for (U64 p = pg0; p <= pgN; p++, tot++)
                            if (remoteMem->getCommittedPagePtr(p)) comm++;
                        static U64 s2cReadComm = 0, s2cReadTot = 0;
                        s2cReadComm += comm; s2cReadTot += tot;
                        if (rOff + chunk >= rLen)
                            klog_fmt("S2C READ-PROBE remoteBase=0x%llx rLen=0x%llx committedPages=%llu/%llu (uncommitted read as ZERO)",
                                     (unsigned long long)rBase, (unsigned long long)rLen,
                                     (unsigned long long)s2cReadComm, (unsigned long long)s2cReadTot);
                    }
                    // read from remote -> write to local
                    remoteMem->memcpyFromGuest(buf.data(), rBase + rOff, chunk);
                    localMem->memcpyToGuest(lBase + lOff, buf.data(), chunk);
                } else {
                    // read from local -> write to remote
                    localMem->memcpyFromGuest(buf.data(), lBase + lOff, chunk);
                    remoteMem->memcpyToGuest(rBase + rOff, buf.data(), chunk);
                }
                lOff += chunk; rOff += chunk; total += chunk;
            }
            ret = (U64)total;
            break;
        }
        case X64_SYS_setsid:
            // setsid() — new session; we don't model sessions, return the pid
            // (matches the 32-bit stub). wineserver daemonizes with this.
            ret = (cpu->thread && cpu->thread->process) ? (U64)cpu->thread->process->id : 1;
            break;
        case X64_SYS_unlink:
        case X64_SYS_unlinkat: {
            // unlink(path) / unlinkat(dirfd, path, flags). wine removes stale
            // lock/socket files in its prefix. path is arg1 (unlink) or arg2
            // (unlinkat, dirfd AT_FDCWD/absolute). Route to KProcess::unlinkFile.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            U64 pathArg = (nr == X64_SYS_unlink) ? a1 : a2;
            char path[1024] = {0};
            cpu->memory->memcpyFromGuest(path, pathArg, sizeof(path) - 1);
            ret = (U64)(S64)(S32)cpu->thread->process->unlinkFile(
                BString(Fs::getFullPath(cpu->thread->process->currentDirectory,
                                        BString::copy(path))));
            break;
        }
        case X64_SYS_pipe:
        case X64_SYS_pipe2: {
            // pipe(fds) / pipe2(fds, flags). Boxedwine models pipes as a
            // connected AF_UNIX stream pair (same as the 32-bit path). wineserver
            // uses a pipe for its signal/wakeup fd. Write the two FDs to memory64.
            // EFAULT before the process check: the bare --x64-selftest runner
            // has no KProcess, and the pipe(NULL) self-test expects -EFAULT.
            if (a1 == 0) { ret = (U64)-K_EFAULT; break; }  // pipefd must be valid
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            U32 pipeFlags = (nr == X64_SYS_pipe2) ? (U32)a2 : 0;
            U32 passFlags = 0;
            if (pipeFlags & 0x80000) passFlags |= K_O_CLOEXEC;  // O_CLOEXEC
            if (pipeFlags & 0x800)   passFlags |= K_O_NONBLOCK; // O_NONBLOCK
            FD fd1 = 0, fd2 = 0;
            S32 rc = ksocketpairFds(cpu->thread, K_AF_UNIX, K_SOCK_STREAM, 0, passFlags, fd1, fd2);
            if (rc) { ret = (U64)(S64)rc; break; }
            cpu->memory->writed(a1, (U32)fd1);
            cpu->memory->writed(a1 + 4, (U32)fd2);
            ret = 0;
            break;
        }
        case X64_SYS_uname:
            ret = sys_uname64(cpu, a1);
            break;
        case X64_SYS_getrandom:
            ret = sys_getrandom64(cpu, a1, a2, a3);
            break;
        case X64_SYS_getcpu:
            // getcpu(unsigned* cpu, unsigned* node, struct getcpu_cache*).
            // Darling's libsystem (via _os_cpu_number) calls this right after
            // the commpage CPU-count read. We present a single CPU/NUMA node, so
            // always report cpu 0 / node 0. The 3rd arg (tcache) is unused since
            // Linux 2.6.24.
            if (a1) cpu->memory->writed(a1, 0);
            if (a2) cpu->memory->writed(a2, 0);
            ret = 0;
            break;
        case X64_SYS_prlimit64:
            ret = sys_prlimit64_64(cpu, a1, a2, a3, a4);
            break;
        case X64_SYS_getrlimit:
            // getrlimit(resource, struct rlimit* {unsigned long cur,max}).
            // wine's unix ntdll queries RLIMIT_STACK/NOFILE/AS during thread
            // setup. Pretend "no limit" (RLIM_INFINITY) — except RLIMIT_NOFILE,
            // which must be finite (Darling's libkqueue sizes a map from it; see
            // the note on sys_prlimit64_64).
            if (a2) {
                if (a1 == K_RLIMIT_NOFILE) {
                    cpu->memory->writeq(a2, K_RLIMIT_NOFILE_CUR);
                    cpu->memory->writeq(a2 + 8, K_RLIMIT_NOFILE_MAX);
                } else {
                    cpu->memory->writeq(a2, ~0ULL);
                    cpu->memory->writeq(a2 + 8, ~0ULL);
                }
            }
            ret = 0;
            break;
        case X64_SYS_setrlimit:
            ret = 0; // accept and ignore — we don't enforce limits
            break;
        case X64_SYS_sched_getscheduler:
            ret = 0; // SCHED_OTHER
            break;
        case X64_SYS_sched_setscheduler:
            ret = 0; // accept; we have one scheduling class
            break;
        case X64_SYS_sched_getparam:
            // sched_param { int sched_priority } — report priority 0.
            if (a2) cpu->memory->writed(a2, 0);
            ret = 0;
            break;
        case X64_SYS_mlockall:
        case X64_SYS_munlockall:
        case X64_SYS_mlock:
        case X64_SYS_munlock:
            // We never page guest memory out, so locking is a no-op success.
            ret = 0;
            break;
        case X64_SYS_clock_gettime:
            ret = sys_clock_gettime64(cpu, a1, a2);
            break;
        case X64_SYS_getuid:
        case X64_SYS_geteuid:
        case X64_SYS_getgid:
        case X64_SYS_getegid:
#ifdef BOXEDWINE_DARWIN
            // Darling's darlingserver (the macOS "kernel" process) requires
            // uid/gid 0 and exits otherwise. In Darwin mode report root.
            if (KSystem::darwinMode) { ret = 0; break; }
#endif
            ret = 1000; // pretend uid/gid 1000
            break;
        case X64_SYS_setuid:
        case X64_SYS_setgid:
#ifdef BOXEDWINE_DARWIN
            if (KSystem::darwinMode) { ret = 0; break; } // root: accept any
#endif
            // We model exactly one user (uid/gid 1000). Tools like coreutils
            // ls/id call setuid/setgid to drop privileges at startup; accept
            // any request to set our own id and reject others with EPERM, the
            // same way a real kernel would for an unprivileged process.
            ret = (a1 == 1000) ? 0 : (U64)-1; // -EPERM
            break;
        case 118: // getresuid(ruid*, euid*, suid*)
        case 120: // getresgid(rgid*, egid*, sgid*)
            // wine's ntdll queries these during process init. We model one
            // user, so real==effective==saved==1000. Each arg is a uid_t* (4
            // bytes); a NULL pointer would be EFAULT but wine always passes
            // valid stack slots.
            if (!a1 || !a2 || !a3) { ret = (U64)-K_EFAULT; break; }
            {
                U32 id = 1000;
#ifdef BOXEDWINE_DARWIN
                if (KSystem::darwinMode) id = 0; // root
#endif
                cpu->memory->writed(a1, id);
                cpu->memory->writed(a2, id);
                cpu->memory->writed(a3, id);
            }
            ret = 0;
            break;
        case 117: // setresuid(ruid, euid, suid)
        case 119: // setresgid(rgid, egid, sgid)
#ifdef BOXEDWINE_DARWIN
            // In Darwin mode we model root (see getuid), and root may set any
            // id. darlingserver temp-drops then regains privileges around prefix
            // setup; accept every change so that dance succeeds.
            if (KSystem::darwinMode) { ret = 0; break; }
#endif
            // Accept setting our own id (1000 or -1 = "unchanged"); reject any
            // attempt to switch to a different user with EPERM, mirroring an
            // unprivileged process. -1 (0xffffffff) means leave that id alone.
            {
                auto ok = [](U64 v){ return v == 1000 || v == 0xffffffffULL; };
                ret = (ok(a1) && ok(a2) && ok(a3)) ? 0 : (U64)-1; // -EPERM
            }
            break;
        case X64_SYS_time: {
            // time(tloc): seconds since epoch; writes to *tloc when non-null.
            U64 sec = KSystem::getSystemTimeAsMicroSeconds() / 1000000ULL;
            if (a1) cpu->memory->writeq(a1, sec);
            ret = sec;
            break;
        }
        case X64_SYS_getpid:
            // PID-namespace view: a process forked with CLONE_NEWPID (the
            // darlingserver launchd container) reports nsPid (==1 for the ns
            // root) rather than its flat emulator id. launchd's startup guard
            // and pid1_magic both hinge on the ns root seeing getpid()==1.
            if (cpu->thread && cpu->thread->process && cpu->thread->process->nsPid) {
                ret = cpu->thread->process->nsPid;
            } else {
                ret = cpu->thread ? cpu->thread->id : 1;
            }
            break;
        case X64_SYS_gettid:
            // PID-namespace view (mirrors getpid above): a thread inside a pid
            // namespace reports its ns-relative tid. The ns process's main thread
            // has nsTid == nsPid, so getpid()==gettid() holds on it — mldr's
            // runtime asserts exactly that right after the dyld checkin.
            if (cpu->thread && cpu->thread->nsTid) {
                ret = cpu->thread->nsTid;
            } else {
                ret = cpu->thread ? cpu->thread->id : 1;
            }
            break;
        case X64_SYS_futex:
            ret = sys_futex64(cpu, a1, (U32)a2, (U32)a3, a4, (U32)a6);
            break;
        case X64_SYS_poll:
        case X64_SYS_ppoll: {
            // poll(fds, nfds, timeout_ms) / ppoll(fds, nfds, timespec*, sigmask).
            // wineserver's sock_init runs sock_check_pollhup(): it closes one end
            // of a socketpair and polls the other, requiring POLLHUP — the old
            // stub (return 0) failed that check and aborted server startup. Bounce
            // the pollfd array (8 bytes each: {int fd; short events; short revents}
            // — layout-identical 32/64) into the process's 32-bit scratch KMemory,
            // call the width-agnostic kpoll (which drives internal_poll's real
            // readiness/blocking + POLLHUP detection), then copy the array back so
            // the updated revents reach the 64-bit guest.
            if (!cpu->thread || !cpu->thread->process || !cpu->thread->memory) {
                ret = (U64)-K_ENOSYS; break;
            }
            U32 nfds = (U32)a2;
            // kpoll's timeout convention (see internal_poll): 0 == return
            // immediately (non-blocking); a value > 0xF0000000 == wait forever;
            // anything in between is a millisecond deadline. The userspace poll
            // ABI maps onto this directly — poll(timeout=-1) is 0xFFFFFFFF
            // (>0xF0000000 == infinite) and poll(timeout=0) is non-blocking — so
            // the 32-bit path passes the raw arg straight through. We do the same.
            U32 timeoutMs;
            if (nr == X64_SYS_ppoll) {
                // ppoll: a3 is a timespec* (NULL == infinite wait).
                if (a3 == 0) {
                    timeoutMs = 0xFFFFFFFFu; // infinite
                } else {
                    U64 sec  = cpu->memory->readq(a3);
                    U64 nsec = cpu->memory->readq(a3 + 8);
                    U64 ms = sec * 1000 + nsec / 1000000;
                    // A real zero timespec is a non-blocking poll (kpoll: 0).
                    timeoutMs = (U32)ms;
                }
            } else {
                // poll: a3 is a signed int ms; pass through (-1 -> 0xFFFFFFFF).
                timeoutMs = (U32)a3;
            }
            if (nfds == 0) {
                // No fds: kpoll with our scratch still honors the timeout sleep.
                U32 scratch0 = bounceSockaddrTo32(cpu, 0, 0, nullptr);
                ret = (U64)(S64)(S32)kpoll(cpu->thread, scratch0, 0, timeoutMs);
                break;
            }
            U32 bytes = nfds * 8;
            // Reuse the multi-page socket scratch (>= one page); cap nfds so the
            // array fits comfortably within a single page.
            if (bytes > K_PAGE_SIZE) { ret = (U64)-K_EINVAL; break; }
            U32 scratch = bounceSockaddrTo32(cpu, 0, 0, nullptr);
            if (!scratch) { ret = (U64)-K_EFAULT; break; }
            // Copy the guest pollfd array into the 32-bit scratch.
            {
                U8 tmp[K_PAGE_SIZE];
                cpu->memory->memcpyFromGuest(tmp, a1, bytes);
                cpu->thread->memory->memcpy(scratch, tmp, bytes);
            }
            S32 rc = (S32)kpoll(cpu->thread, scratch, nfds, timeoutMs);
            // Copy the (revents-updated) array back to the 64-bit guest.
            {
                U8 tmp[K_PAGE_SIZE];
                cpu->thread->memory->memcpy(tmp, scratch, bytes);
                cpu->memory->memcpyToGuest(a1, tmp, bytes);
            }
            ret = (U64)(S64)rc;
            break;
        }
        case X64_SYS_pselect6: {
            // pselect6(nfds, readfds*, writefds*, exceptfds*, timespec*, sigmask).
            // We have no native select, but kpoll() is the real readiness/blocking
            // engine — see doSelect64. Without this, wine (winex11/msg-loop) spins
            // on pselect6=ENOSYS and never reaches GL.
            U64 tsAddr = a5;
            // Timeout: a5 is a timespec* (NULL == infinite). Match kpoll's
            // convention (0 == non-blocking, 0xFFFFFFFF == infinite).
            U32 timeoutMs;
            if (tsAddr == 0) {
                timeoutMs = 0xFFFFFFFFu;
            } else {
                U64 sec  = cpu->memory->readq(tsAddr);
                U64 nsec = cpu->memory->readq(tsAddr + 8);
                timeoutMs = (U32)(sec * 1000 + nsec / 1000000);
            }
            ret = (U64)doSelect64(cpu, (U32)a1, a2, a3, a4, timeoutMs);
            break;
        }
        case X64_SYS_sched_yield:
            // Relinquish the host CPU so a sibling guest thread/process that must
            // run to signal an awaited event isn't starved while this thread
            // spin-then-yields (RtlpWaitForCriticalSection, a server_select retry,
            // or wine's NtDelayExecution short-sleep loop).
            //
            // In the MULTI-THREADED build each guest thread runs on its own host
            // thread, so std::this_thread::yield() is the whole job. We must NOT
            // set cpu->yield here: the MT run loop (normalPlatformMultiThreaded.cpp)
            // treats `yield==true && !terminating` as "this thread is done" and
            // BREAKS out — deleting the thread. That made any guest sched_yield
            // (notably wine's Sleep() short-delay spin) silently destroy the
            // calling thread mid-run -> the process went idle/hung. cpu->yield is
            // only meaningful for the single-threaded cooperative scheduler.
#ifndef BOXEDWINE_MULTI_THREADED
            cpu->yield = true;
#endif
            std::this_thread::yield();
            ret = 0;
            break;
        case X64_SYS_sched_getaffinity:
            ret = sys_sched_getaffinity64(cpu, a1, a2, a3);
            break;
        case X64_SYS_sched_setaffinity:
            ret = sys_sched_setaffinity64(cpu, a1, a2, a3);
            break;
        case X64_SYS_kill: {
            // kill(pid, sig). For a real target pid>0 route through the shared
            // KSystem::kill so it consults the live process table — wineserver
            // probes client liveness with kill(pid,0) and force-reaps dead
            // clients with kill(pid,SIGKILL) during the multi-process boot
            // teardown. The old "single-process world" stub answered kill(pid,0)
            // as ALWAYS-alive (sig==0 short-circuited to 0 for ANY pid) and
            // kill(otherpid,sig) as ALWAYS -ESRCH, so wineserver could neither
            // detect a dead client nor kill it -> its reap state machine wedged
            // and double-freed a process object (the "unsorted double linked
            // list"/release_object heap corruption during boot-helper exit).
            // KSystem::kill returns -ESRCH for a nonexistent pid and 0 for a
            // live one (sig==0), matching POSIX and the 32-bit syscall_kill.
            U32 sig = (U32)a2;
            S64 spid = (S64)a1;
            U64 ourPid = cpu->thread && cpu->thread->process ?
                         (U64)cpu->thread->process->id : 1;
            if (spid > 0 && (U64)spid != ourPid) {
                ret = (U64)(S64)(S32)KSystem::kill((S32)spid, sig);
                break;
            }
            // pid<=0 (process group / broadcast) or our own pid: deliver to self
            // synchronously, as before. sig==0 is a permission/liveness probe.
            if (sig == 0) { ret = 0; break; }
            if (deliverSignalSync(cpu, sig)) {
                ret = 0;
            } else {
                bool ignored = (sig >= 1 && sig <= 64) &&
                               cpu->sigActions[sig].installed &&
                               cpu->sigActions[sig].handler == 1 /*SIG_IGN*/;
                if (sigDefaultIsFatal(sig) && !ignored) {
                    klog_fmt("ksyscall64: kill self sig=%u (fatal default) — terminating process", sig);
                    cpu->yield = true;
                    if (cpu->thread && cpu->thread->process) {
                        cpu->thread->process->exitgroup(cpu->thread, 128 + sig);
                    }
                    ret = 0;
                } else {
                    klog_fmt("ksyscall64: kill self sig=%u — no handler, default non-fatal/ignored", sig);
                    ret = 0;
                }
            }
            break;
        }
        case X64_SYS_rt_sigtimedwait:
            ret = sys_rt_sigtimedwait64(cpu, a1, a2, a3, a4);
            break;
        case X64_SYS_rt_sigsuspend:
            ret = sys_rt_sigsuspend64(cpu, a1, a2);
            break;
        case X64_SYS_rt_sigpending:
            ret = sys_rt_sigpending64(cpu, a1, a2);
            break;
        case X64_SYS_rt_sigqueueinfo:
            // rt_sigqueueinfo(tgid, sig, info) — like kill but with siginfo.
            // We don't deliver, so report success the same way kill does.
            ret = 0;
            break;
        case X64_SYS_pause:
            // pause() blocks till any signal; we never deliver, so the
            // glibc-compatible answer is -EINTR (caller's loop retries).
            ret = (U64)-K_EINTR;
            break;
        case X64_SYS_wait4: {
            // wait4(pid, status*, options, rusage*) — reap a forked child (e.g.
            // wineboot waiting on the wineserver it fork+exec'd). Reuse the
            // arch-neutral reaper and write the status into memory64. rusage
            // (a4) is ignored.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ECHILD; break; }
            int status = 0;
            U32 rc = KSystem::reapChild(cpu->thread, (S32)a1, (U32)a3, a2 ? &status : nullptr);
            if ((S32)rc > 0 && a2) {
                cpu->memory->writed(a2, (U32)status);
            }
            ret = (U64)(S64)(S32)rc;
            break;
        }
        case X64_SYS_clone:
            // x86-64 clone arg order: (flags=rdi, stack=rsi, parent_tid=rdx,
            // child_tid=r10, tls=r8). Create a real thread sharing this
            // process + memory64. Falls back to -ENOSYS for non-thread clones.
            if (cpu->thread && cpu->thread->process && cpu->thread->process->memory64) {
                ret = cpu->thread->process->clone64(cpu->thread, a1, a2, a3, a5, a4);
            } else {
                klog_fmt("ksyscall64: clone(flags=0x%llx) with no process/memory64",
                         (unsigned long long)a1);
                ret = (U64)-K_ENOSYS;
            }
            break;
        case X64_SYS_execve:
            // Replaces the process image. On success returns -K_CONTINUE (the
            // new program's RAX is already set by loadProgram64); the dispatcher
            // skips the RAX write for -K_CONTINUE so we don't clobber it.
            ret = sys_execve64(cpu, a1, a2, a3);
            break;
        case X64_SYS_getitimer:
        case X64_SYS_setitimer:
            // Interval timers are rarely used by modern glibc (timer_create
            // is preferred); explicit ENOSYS keeps callers honest.
            ret = (U64)-K_ENOSYS;
            break;
        case X64_SYS_clone3:
            // glibc 2.34+ prefers clone3. Implement it directly (its ENOSYS
            // fallback to clone is fragile in our interpreter).
            if (cpu->thread && cpu->thread->process && cpu->thread->process->memory64) {
                ret = cpu->thread->process->clone364(cpu->thread, a1, a2);
            } else {
                ret = (U64)-K_ENOSYS;
            }
            break;
        case X64_SYS_eventfd:
        case X64_SYS_eventfd2:
            // eventfd(initval, flags) / eventfd2 — a counter fd that is readable/
            // writable/pollable, used for epoll wakeups. Darling's darlingserver
            // REQUIRES it ("Failed to create eventfd for on-demand epoll
            // wakeups") and throws std::system_error on -ENOSYS. Reuse the
            // existing KEvent implementation (source/kernel/kevent.cpp), the same
            // one the 32-bit path uses, which wires read/write/poll correctly.
            if (!cpu->thread) { ret = (U64)-K_ENOSYS; break; }
            {
                U32 flags = (nr == X64_SYS_eventfd2) ? (U32)a2 : 0;
                U32 r = syscall_eventfd2(cpu->thread, (U32)a1, flags);
                ret = (U64)(S64)(S32)r;
            }
            break;
        case X64_SYS_timerfd_create:
            // timerfd_create(clockid, flags) — scalar args, route to the shared
            // KProcess impl (creates a KTimer-backed fd). darlingserver needs it
            // for timed epoll wakeups ("Failed to create timer descriptor").
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            ret = (U64)(S64)(S32)cpu->thread->process->timerfd_create((U32)a1, (U32)a2);
            break;
        case X64_SYS_pidfd_open:
            // pidfd_open(pid, flags) — an epoll-able fd that becomes readable when
            // the target process dies. darlingserver opens one per tracked macOS
            // process (src/process.cpp:39, when no lifetime pipe) and monitors it
            // for death; it throws "Failed to open pidfd for process" on failure,
            // which stalled the mldr checkin (the server couldn't finish handling
            // the checkin without a process monitor, so it never replied).
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            ret = (U64)(S64)(S32)syscall_pidfd_open(cpu->thread, (U32)a1, (U32)a2);
            break;
        case X64_SYS_timerfd_settime: {
            // timerfd_settime(fd, flags, new*, old*). The struct is a 64-bit
            // itimerspec { it_interval{tv_sec u64, tv_nsec u64}, it_value{...} }
            // (4 x 8 bytes) — NOT the 32-bit layout the KProcess helper reads —
            // so marshal it here against cpu->memory (KMemory64) and drive the
            // KTimer directly via setTimes(microInterval, microNextTimer).
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            KFileDescriptorPtr fd = cpu->thread->process->getFileDescriptor((FD)(S32)a1);
            if (!fd) { ret = (U64)-K_EBADF; break; }
            std::shared_ptr<KTimer> timer = std::dynamic_pointer_cast<KTimer>(fd->kobject);
            if (!timer) { ret = (U64)-K_EINVAL; break; }
            if (!a3) { ret = (U64)-K_EFAULT; break; }
            if (a4) { // write old value (itimerspec64)
                U64 microInterval = timer->getMicroInterval();
                U64 microNext = timer->getMicroNextTimer();
                cpu->memory->writeq(a4,      microInterval / 1000000);
                cpu->memory->writeq(a4 + 8,  (microInterval % 1000000) * 1000);
                U64 now = KSystem::getSystemTimeAsMicroSeconds();
                S64 diff = microNext ? (S64)microNext - (S64)now : 0;
                if (diff < 0) diff = 0;
                cpu->memory->writeq(a4 + 16, (U64)diff / 1000000);
                cpu->memory->writeq(a4 + 24, ((U64)diff % 1000000) * 1000);
            }
            U64 interval = cpu->memory->readq(a3) * 1000000 + cpu->memory->readq(a3 + 8) / 1000;
            U64 next     = cpu->memory->readq(a3 + 16) * 1000000 + cpu->memory->readq(a3 + 24) / 1000;
            if ((a2 & 1) == 0 && next) next += KSystem::getSystemTimeAsMicroSeconds(); // !ABSTIME
            timer->setTimes(interval, next);
            ret = 0;
            break;
        }
        case X64_SYS_timerfd_gettime: {
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            KFileDescriptorPtr fd = cpu->thread->process->getFileDescriptor((FD)(S32)a1);
            if (!fd) { ret = (U64)-K_EBADF; break; }
            std::shared_ptr<KTimer> timer = std::dynamic_pointer_cast<KTimer>(fd->kobject);
            if (!timer) { ret = (U64)-K_EINVAL; break; }
            if (!a2) { ret = (U64)-K_EFAULT; break; }
            U64 microInterval = timer->getMicroInterval();
            U64 microNext = timer->getMicroNextTimer();
            cpu->memory->writeq(a2,     microInterval / 1000000);
            cpu->memory->writeq(a2 + 8, (microInterval % 1000000) * 1000);
            U64 now = KSystem::getSystemTimeAsMicroSeconds();
            S64 diff = microNext ? (S64)microNext - (S64)now : 0;
            if (diff < 0) diff = 0;
            cpu->memory->writeq(a2 + 16, (U64)diff / 1000000);
            cpu->memory->writeq(a2 + 24, ((U64)diff % 1000000) * 1000);
            ret = 0;
            break;
        }
        case X64_SYS_epoll_create:
        case X64_SYS_epoll_create1:
            // epoll_create(size) / epoll_create1(flags) — allocate an epoll set.
            // No guest memory. wineserver's main loop is epoll-driven. The
            // process epoll machinery is reused as-is.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_ENOSYS; break; }
            ret = (U64)(S64)(S32)cpu->thread->process->epollcreate(
                (nr == X64_SYS_epoll_create) ? (U32)a1 : 0,
                (nr == X64_SYS_epoll_create1) ? (U32)a1 : 0);
            break;
        case X64_SYS_epoll_ctl: {
            // epoll_ctl(epfd, op, fd, event*). The epoll_event (12 bytes, packed
            // on x86-64: u32 events; u64 data) is layout-identical 32/64 but the
            // object reads it via thread->memory — bounce the 12 bytes through
            // 32-bit scratch. EPOLL_CTL_DEL passes a NULL event. No process
            // (bare selftest) → -EBADF, matching the kernel + the self-test.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_EBADF; break; }
            U32 ev32 = 0;
            if (a4) ev32 = bounceSockaddrTo32(cpu, a4, 12, nullptr);
            ret = (U64)(S64)(S32)cpu->thread->process->epollctl((FD)a1, (U32)a2, (FD)a3, ev32);
            if (getenv("BW64_IPCDUMP")) {
                U32 events = a4 ? cpu->thread->memory->readd(ev32 + 0) : 0;
                klog_fmt("IPC epoll_ctl(epfd=%d, op=%d, fd=%d, events=0x%x) -> %d",
                         (int)a1, (int)a2, (int)a3, events, (int)(S32)ret);
            }
            break;
        }
        case X64_SYS_epoll_wait: {
            // epoll_wait(epfd, events, maxevents, timeout). Bounce: let the
            // object write the result events into 32-bit scratch, then copy them
            // back to memory64. Cap maxevents so the scratch page holds them.
            // No process (bare selftest) → -EBADF.
            if (!cpu->thread || !cpu->thread->process) { ret = (U64)-K_EBADF; break; }
            U32 maxevents = (U32)a3;
            if (maxevents > 64) maxevents = 64;       // 64*12=768 < page
            U32 ev32 = bounceSockaddrTo32(cpu, 0, maxevents * 12, nullptr);
            if (!ev32) { ret = (U64)-K_EFAULT; break; }
            U32 rc = cpu->thread->process->epollwait(cpu->thread, (FD)a1, ev32, maxevents, (U32)a4);
            if ((S32)rc > 0) {
                U32 bytes = rc * 12;
                U8 tmp[64 * 12];
                cpu->thread->memory->memcpy(tmp, ev32, bytes);
                cpu->memory->memcpyToGuest(a2, tmp, bytes);
            }
            if (getenv("BW64_IPCDUMP") && (S32)rc > 0) {
                // Only log non-timeout waits — a returned event means a fd in the
                // set (wineserver socket or wait pipe) became readable.
                char fds[256] = {0}; int off = 0;
                for (U32 i = 0; i < rc && off < 230; i++) {
                    U32 ev   = cpu->thread->memory->readd(ev32 + i*12 + 0);
                    U64 data = cpu->thread->memory->readq(ev32 + i*12 + 4);
                    off += snprintf(fds + off, sizeof(fds) - off,
                                    "{ev=0x%x,data=0x%llx} ", ev,
                                    (unsigned long long)data);
                }
                klog_fmt("IPC epoll_wait(epfd=%d,to=%d) -> %d  %s",
                         (int)a1, (int)(S32)a4, (int)rc, fds);
            }
            // BW64_EPSPIN: identify a perpetually-ready fd (the Mode 2 spinner).
            // For each returned event, the epoll `data` is the guest fd number;
            // log that fd's kobject type so we can see WHAT keeps firing EPOLLIN.
            if (getenv("BW64_EPSPIN") && (S32)rc > 0) {
                for (U32 i = 0; i < rc; i++) {
                    U32 ev   = cpu->thread->memory->readd(ev32 + i*12 + 0);
                    U64 data = cpu->thread->memory->readq(ev32 + i*12 + 4);
                    KFileDescriptorPtr rfd = cpu->thread->process->getFileDescriptor((FD)data);
                    const char* kind = "none";
                    long recvUsed = -1, msgsN = -1; int inClosed = -1;
                    long pendTot = -1, pendLive = -1;
                    if (rfd && rfd->kobject) {
                        switch (rfd->kobject->type) {
                            case KTYPE_FILE: kind="file"; break;
                            case KTYPE_UNIX_SOCKET: {
                                kind="unixsock";
                                std::shared_ptr<KUnixSocketObject> us =
                                    std::dynamic_pointer_cast<KUnixSocketObject>(rfd->kobject);
                                if (us) { recvUsed=(long)us->debugRecvUsed(); msgsN=(long)us->debugMsgsSize(); inClosed=us->debugInClosed()?1:0; pendTot=(long)us->debugPendingTotal(); pendLive=(long)us->debugPendingLive(); }
                                break;
                            }
                            case KTYPE_NATIVE_SOCKET: kind="natsock"; break;
                            case KTYPE_EPOLL: kind="epoll"; break;
                            case KTYPE_EVENT: kind="event"; break;
                            case KTYPE_TIMER: kind="timer"; break;
                            case KTYPE_SIGNAL: kind="signal"; break;
                            default: kind="other"; break;
                        }
                    }
                    klog_fmt("EPSPIN pid=%d epfd=%d to=%d readyfd=%llu ev=0x%x kind=%s recvUsed=%ld msgs=%ld inClosed=%d pendTot=%ld pendLive=%ld",
                             (int)cpu->thread->process->id, (int)a1, (int)(S32)a4,
                             (unsigned long long)data, ev, kind, recvUsed, msgsN, inClosed, pendTot, pendLive);
                }
            }
            ret = (U64)(S64)(S32)rc;
            break;
        }
        case X64_SYS_getdents64:
            ret = sys_getdents64_real(cpu, a1, a2, a3);
            break;
        case X64_SYS_pwrite64:
            // pwrite64(fd, buf, count, offset) — wineserver populates registry/
            // config files in the prefix with it.
            if (a2 == 0) { ret = (U64)-K_EFAULT; break; }
            ret = sys_pwrite64(cpu, a1, a2, a3, a4);
            break;
        case X64_SYS_readv:
            // Scatter-gather read — walk the iovec, read into each segment.
            if (a2 == 0) { ret = (U64)-K_EFAULT; break; }
            ret = sys_readv64(cpu, a1, a2, a3);
            break;
        case X64_SYS_select: {
            // select(nfds, readfds*, writefds*, exceptfds*, timeval*). Same engine
            // as pselect6 (doSelect64 / kpoll); the only difference is the timeout
            // struct is a `struct timeval {long sec; long usec}` (a5, NULL ==
            // infinite). launchd's kqueue_demand_loop blocks here on
            // select(mainkq+1, &rfds, NULL, NULL, NULL) — the ENOSYS stub made it
            // busy-spin (and fire dserver #31 pthread_canceled every turn); now it
            // truly blocks until the kqueue/bootstrap fd is readable.
            U64 tvAddr = a5;
            U32 timeoutMs;
            if (tvAddr == 0) {
                timeoutMs = 0xFFFFFFFFu;
            } else {
                U64 sec  = cpu->memory->readq(tvAddr);
                U64 usec = cpu->memory->readq(tvAddr + 8);
                timeoutMs = (U32)(sec * 1000 + usec / 1000);
            }
            ret = (U64)doSelect64(cpu, (U32)a1, a2, a3, a4, timeoutMs);
            break;
        }
        case X64_SYS_chmod:
        case X64_SYS_fchmod:
        case X64_SYS_fchmodat:
        case X64_SYS_fchmodat2:
            // No-op success: rootfs is effectively read-only for our purpose
            // and glibc's installer paths frequently call chmod on temp
            // files. Returning 0 avoids spurious install-time failures
            // without actually touching anything. darlingserver chmods prefix
            // files during setup (via fchmodat) and treats failure as fatal.
            ret = 0;
            break;
        case X64_SYS_gettimeofday: {
            // struct timeval { U64 sec; U64 usec; }
            if (a1) {
                U64 us = KSystem::getSystemTimeAsMicroSeconds();
                cpu->memory->writeq(a1,     us / 1000000ULL);
                cpu->memory->writeq(a1 + 8, us % 1000000ULL);
            }
            if (a2) {
                // struct timezone — minutes_west, dsttime. Zero both.
                cpu->memory->writed(a2,     0);
                cpu->memory->writed(a2 + 4, 0);
            }
            ret = 0;
            break;
        }
        case X64_SYS_getrusage:
            // struct rusage is large; for v1 just zero-fill 144 bytes.
            // glibc only inspects ru_utime and ru_stime on the startup path.
            if (a2) cpu->memory->memsetGuest(a2, 0, 144);
            ret = 0;
            break;
        case X64_SYS_sysinfo:
            // struct sysinfo — zero-fill the standard 64-byte layout.
            // ld-linux doesn't actually read these; some binaries call it
            // anyway as part of /proc startup probes.
            if (a1) cpu->memory->memsetGuest(a1, 0, 112);
            ret = 0;
            break;
        case X64_SYS_getppid:
            // PID-namespace view: the ns root's parent (darlingserver) lives
            // outside the namespace, so it reports getppid()==0 like a real
            // PID-1 init. Descendants inside the ns report their parent's nsPid.
            if (cpu->thread && cpu->thread->process && cpu->thread->process->nsPid) {
                ret = cpu->thread->process->nsParentId;
            } else {
                ret = cpu->thread && cpu->thread->process ? cpu->thread->process->parentId : 1;
            }
            break;
        case X64_SYS_getpgrp:
        case X64_SYS_getpgid:
        case X64_SYS_getsid:
            ret = cpu->thread ? cpu->thread->id : 1;
            break;
        case X64_SYS_clock_getres:
            // 1 ns resolution claim. Some libc time helpers use this to size
            // a struct timespec field.
            if (a2) {
                cpu->memory->writeq(a2,     0);
                cpu->memory->writeq(a2 + 8, 1);
            }
            ret = 0;
            break;
        case X64_SYS_nanosleep:
        case X64_SYS_clock_nanosleep:
            // No-op sleep. Real Wine workloads will need pacing here, but
            // for ld.so startup it's fine to return immediately.
            ret = 0;
            break;
        case X64_SYS_rseq:
            // restartable-sequences registration. glibc 2.35+ calls this on
            // every thread start. Pretend it's not supported so glibc falls
            // back to plain mutexes.
            ret = (U64)-K_ENOSYS;
            break;
        case X64_SYS_exit:
            ret = sys_exit64(cpu, a1, false);
            break;
        case X64_SYS_exit_group:
            ret = sys_exit64(cpu, a1, true);
            break;
        default:
            klog_fmt("ksyscall64: unimplemented syscall #%llu (%s) at RIP=0x%llx — RDI=0x%llx RSI=0x%llx RDX=0x%llx R10=0x%llx R8=0x%llx R9=0x%llx",
                     (unsigned long long)nr,
                     x64SyscallName(nr),
                     (unsigned long long)cpu->rip,
                     (unsigned long long)a1,
                     (unsigned long long)a2,
                     (unsigned long long)a3,
                     (unsigned long long)a4,
                     (unsigned long long)a5,
                     (unsigned long long)a6);
            // TEMP DIAGNOSTIC: dump the bytes around the syscall RIP and the
            // full register set so we can tell a real Linux syscall from a
            // wine __wine_unix_call / NT thunk landing here. syscallRip points
            // at the 0F 05 instruction.
            if (getenv("BW64_SCDUMP")) {
                U64 r = cpu->syscallRip;
                U8 b[16];
                for (int i = 0; i < 16; i++) b[i] = cpu->memory->readb(r - 6 + i);
                klog_fmt("  SCDUMP bytes@RIP-6: %02x %02x %02x %02x %02x %02x [%02x %02x] %02x %02x %02x %02x %02x %02x %02x %02x",
                         b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]);
                klog_fmt("  SCDUMP RAX=%llx RBX=%llx RCX=%llx RBP=%llx RSP=%llx R12=%llx fsbase=%llx gsbase=%llx",
                         (unsigned long long)cpu->reg[X64_RAX].u64,
                         (unsigned long long)cpu->reg[X64_RBX].u64,
                         (unsigned long long)cpu->reg[X64_RCX].u64,
                         (unsigned long long)cpu->reg[X64_RBP].u64,
                         (unsigned long long)cpu->reg[X64_RSP].u64,
                         (unsigned long long)cpu->reg[X64_R12].u64,
                         (unsigned long long)cpu->fsbase,
                         (unsigned long long)cpu->gsbase);
            }
            ret = (U64)-K_ENOSYS;
            break;
    }

    // execve (and any future blocking/restart paths) return -K_CONTINUE to mean
    // "the new image / restart already set the registers — do NOT overwrite RAX
    // with this sentinel." Mirrors the 32-bit dispatcher (syscall.cpp).
    if (ret == (U64)(S64)-K_CONTINUE || ret == (U64)(S64)-K_WAIT) {
        return;
    }
    if (cpu->thread) cpu->thread->inSyscall64 = false;
    cpu->reg[X64_RAX].setU64(ret);
}

#endif // BOXEDWINE_GUEST_X64
