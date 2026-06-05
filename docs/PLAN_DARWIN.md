# Darwin_Computa — a portable macOS emulator (Darling on emulated Linux)

## Context

Boxedwine is a *userland* emulator: it implements an x86/x86_64 CPU **plus a fake Linux
kernel** (no real Linux host required), then runs **Wine** on top so Windows apps run on
macOS/Windows/Linux/Web. The user wants the same trick for **Darling** — the
macOS-compatibility layer that normally runs on real Linux — to get a *portable macOS
emulator* that runs everywhere Boxedwine does (Mac, Windows, Linux, browser/WASM).

The substrate already exists at `/Users/nakas/Documents/boxedwine64/Boxedwine64`
("Boxedwine64"), a mature fork that **already emulates 64-bit Linux** well enough to boot
real Debian `wine64` to a GUI on macOS arm64. It already has: ELF64 dynamic loading
(glibc 2.36, TLS, IFUNC, versioned symbols), real threads (`clone`/`clone3`/futex,
per-thread CPU), `fork`/`execve`/`wait4`, full AF_UNIX + epoll + `sendmsg`/`recvmsg` +
`SCM_RIGHTS`, SysV shm, ~90 Linux syscalls (`source/kernel/syscall64.cpp`), a virtual
device + ioctl framework (`source/kernel/devs/`), a zip rootfs system, and WASM build
targets. **The Linux half Darling needs is essentially done.**

**Darling's architecture** (verified from its docs/source): `mldr` is an ordinary Linux
ELF that mmaps a Mach-O, loads Apple's `dyld`, and hands off — so *entering* Darling on
emulated Linux is just running an ELF, which Boxedwine64 already does. macOS userspace
gets its "kernel" from a Linux kernel module exposed as the **misc device `/dev/mach`**:
userspace does `open("/dev/mach")` then `ioctl(fd, DARLING_MACH_API_BASE + trap_num,
paramv)`, dispatched through a `mach_traps[]` table of ~80–90 traps (Mach IPC, psynch,
kqueue, pthread, task/thread, semaphores, vchroot/container). Normal Darwin **BSD
syscalls** go through the regular Linux `syscall` path, which Boxedwine64 already emulates.

**Therefore the new work is small and bounded:** emulate Darling's LKM trap interface as a
Boxedwine virtual device `/dev/mach`, build a Darling rootfs zip, add a launcher + harness,
and iterate via the same "run a real binary, implement the next failing thing" loop that
built the wine64 path. **Outcome:** a trivial Mach-O `hello`, then real CLI tools (`bash`,
`ls`), running headless via the emulated kernel — with GUI and WASM as later phases.

### Decisions (confirmed with user)
- **Repo:** copy the whole Boxedwine64 tree into `/Users/nakas/Documents/Darwin_Computa`
  and develop in place. The substrate is the product. Gate all new code behind an additive
  `BOXEDWINE_DARWIN` define (depends on `BOXEDWINE_GUEST_X64`) so the wine path is never
  disturbed. Record the copied upstream commit (currently `8569a962`) in `UPSTREAM.md`.
- **v1 milestone:** headless CLI first (Mach-O `hello` → `bash`/`ls`). GUI + WASM are
  planned phases, not the v1 commitment.
- **Rootfs:** build Darling's amd64 userland via a Docker `linux/amd64` image and stage it
  into a Boxedwine zip rootfs, exactly like `tools/rootfs64/` does for wine64.

## Key load-bearing findings (verified by reading the substrate)

1. **The ioctl seam is the crux.** The base device method `ioctl(KThread* thread, U32
   request)` receives **no arg pointer** and existing devices read args through the
   **32-bit** `thread->memory`. The 64-bit ioctl handler in
   `source/kernel/syscall64.cpp` (`case X64_SYS_ioctl`, ~line 2892) deliberately refuses
   to route device ioctls for that reason (only handles `FIONBIO`/`FIONREAD`, else
   `-ENOTTY`). **Darling's entire kernel interface is `ioctl(fd, BASE+trap, paramv)` with a
   64-bit `paramv`.** So we add a new routing case: when the fd resolves to a `DevMach`,
   call a new `mach_ioctl(CPU64* cpu, U64 request, U64 paramv)` that uses the **64-bit
   `cpu->memory`** (KMemory64, `source/kernel/kmemory64.cpp`) and the real `a3` pointer.
2. **Devices** subclass `FsVirtualOpenNode` (`source/io/fsvirtualopennode.h`) and register
   via `Fs::addVirtualFile(...)` in `source/sdl/startupArgs.cpp` (~lines 125–149).
   `source/kernel/devs/devurandom.cpp` is the minimal template.
3. **Syscall dispatch** is a flat switch in `ksyscall64(CPU64* cpu)`
   (`source/kernel/syscall64.cpp` ~line 2707), args `a1=RDI..a6=R9`. Adding Darwin's Linux
   syscalls = adding `case` arms, with the built-in `SYS64` tracer naming each on first hit.
4. **Harness** `--x64-selftest` / `--x64-run-elf` dispatch at the top of `boxedmain`
   (`source/sdl/main.cpp` ~lines 216–230); `--darwin-run` slots in identically.
5. **Rootfs tooling** `tools/rootfs64/build-wine64-zip.sh` Docker-stages a Debian amd64
   tree, computes the dep closure, and zips into layered `FsZip` mounts (`-zip` in
   `startupArgs.cpp` ~line 162). The `FsZip::guestIs64` marker trips on `x86_64-linux-gnu/`.
6. **WASM** goals in `project/emscripten/makefile` (`wasm64-selftest`, `wasm64-runelf`,
   `wasm64-mt`) are copyable to a `wasm64-darwin` goal with `-DBOXEDWINE_DARWIN`.

## Mach-O loading: stays in guest userspace for v1
`mldr` (a Linux ELF) does the Mach-O mmap + dyld load itself, in *guest* user code that the
existing interpreter runs. **No host-side Mach-O loader is needed for v1.** Caveat to
verify in Phase 0: some Darling builds do part of the Mach-O/commpage setup in the LKM; if
so it surfaces as specific `/dev/mach` traps or a device `mmap`, which we implement in
`DevMach` (still no host Mach-O parser). Pin an explicit Darling commit/tag so
`DARLING_MACH_API_BASE` and `mach_traps[]` are stable.

## Highest-risk unknowns (de-risk first)
- (a) **Unknown Linux syscalls** Darling's libsystem hits that wine never did (e.g.
  `statx`, `memfd_create`, `eventfd2`, `signalfd`, `clock_nanosleep`, `unshare`/namespace
  calls). The `SYS64` tracer enumerates them.
- (b) **Minimal Mach IPC + psynch fidelity** needed for dyld+libSystem init to *complete*
  (not "all of Mach"). Deepest unknown.
- (c) **LKM-side commpage/Mach-O setup** in the pinned build (drives the device `mmap`).
- (d) **Rootfs buildability** via Docker.

### Phase 0 spike (smallest end-to-end)
An emulated `/dev/mach` that answers `get_api_version` + `mach_reply_port` (and anything the
trap dump shows is hit first) so guest dyld/libSystem clears the kernel handshake and we can
read the *next* failure. Steps: (1) stage a Darling rootfs zip with `mldr`+`dyld`+`libsystem*`;
(2) add `--darwin-run <mach-o>` running `mldr <mach-o>` with `/dev/mach` registered, the
`SYS64` tracer on, and a new `DEV_MACH_TRACE` logging every `BASE+trap` decoded by name;
(3) run a trivial Mach-O `hello`, capture the trace, implement the handshake traps, iterate.
Deliverable: the trace + two working traps, turning unknowns (a)/(b)/(c) into a checklist.

## Phased roadmap (mirrors Boxedwine64's A–I)

**Phase A — Fork, gate, harness.** Copy tree to `/Users/nakas/Documents/Darwin_Computa`;
add `BOXEDWINE_DARWIN` to the Xcode scheme and the emscripten makefile (new `wasm64-darwin`
goal); new `source/emulation/cpu/cpu64DarwinRun.cpp` (modeled on `cpu64RunElf.cpp`); hook
`--darwin-run` in `source/sdl/main.cpp` (~216–230). *Verify:* `--x64-selftest` still
234/234; `--darwin-run` loads `mldr` and the `SYS64` trace reaches `open("/dev/mach")`.

**Phase B — `/dev/mach` device + ioctl seam (the spike).** New
`source/kernel/devs/devmach.cpp` (`DevMach : FsVirtualOpenNode`, template `devurandom.cpp`);
register in `startupArgs.cpp` (~125–149) with Darling's expected `rdev`; **new ioctl routing
in `syscall64.cpp` `case X64_SYS_ioctl` (~2892)** → `devMach->mach_ioctl(cpu, request, a3)`;
new `source/kernel/darwin/{machtraps.h, machtrap_dispatch.cpp}` (trap enum transcribed from
the pinned Darling `mach_traps[]`; big switch analogous to `ksyscall64`; trap-name table for
`DEV_MACH_TRACE`). *Verify:* handshake traps answered; add `--darwin-selftest` asserting
`get_api_version`.

**Phase C — Mach IPC core + commpage mmap.** `mach_reply_port`, minimal
`mach_msg_overwrite_trap`, `thread_self_trap`, `task_self`/`task_for_pid` (self only);
implement `DevMach::map(...)` for the commpage (if the pinned build needs it). Model ports
as a small in-fake-kernel table on a `DarwinProcess` context hung off `KProcess`. *Verify:*
`--darwin-run hello` reaches the Mach-O's real `main` (first app-code `write(1,...)`).

**Phase D — psynch + threading + BSD gaps → `hello` prints headless.** psynch traps mapped
onto the existing futex machinery; `pthread_kill`; fill Linux syscall gaps revealed by the
trace as `case` arms in `ksyscall64`. *Verify:* `--darwin-run hello` exits 0 and tees
"hello" to host stdout; lock in as a regression in `--darwin-selftest`.

**Phase E — Real Darling rootfs (Docker).** New `tools/rootfs-darling/build-darling-zip.sh`
cloned from `tools/rootfs64/build-wine64-zip.sh` (Docker `linux/amd64`, dyld/ldd closure
staging, 64-bit marker path for `FsZip::guestIs64`); new `tools/run_darling_cli.sh` cloned
from `tools/run_wine64.sh`; add `-zip` mounts in `startupArgs.cpp` (~162). *Verify:*
`run_darling_cli.sh /usr/bin/sw_vers` runs from the zip rootfs.

**Phase F — Real CLI: `bash`, then coreutils.** Iterate `ksyscall64` +
`machtrap_dispatch.cpp` against traces; add a `kqueue`/`kevent` trap arm mapped onto
existing epoll if needed. *Verify:* `run_darling_cli.sh /bin/bash -c 'echo hi; ls /'`
produces correct headless output. **(v1 target reached here.)**

**Phase G — launchd / container plumbing (faked namespaces).** Darling's overlayfs +
PID/IPC/UTS namespaces are **faked, not real** in the emulated kernel: vchroot traps become
no-op/identity in `DevMach`, container is a path remap near the FS/zip mount. *Verify:*
Darling bootstrap reaches steady state without faults.

**Phase H — Cocoa/AppKit GUI.** Reuse Boxedwine64's existing X11/SDL window-map + GL bridge
(`source/kernel/devs/devfb.cpp`, the `gl64`/WebGL2 bridge); fill GUI-path traps/syscalls as
traces demand. *Verify:* a minimal AppKit app shows a window with content.

**Phase I — WASM (macOS emulator in a browser tab).** New `wasm64-darwin`/`wasm64-darwin-mt`
makefile goals (clone `wasm64-runelf`/`wasm64-mt` + `-DBOXEDWINE_DARWIN`); `darwin.html`
launcher cloned from `wine64.html`; serve the Darling zip rootfs like the wine64 one.
*Verify:* `node ... --darwin-run hello` headless under Node, then the CLI in a tab.

## Files to touch
**New:** `source/kernel/devs/devmach.cpp`; `source/kernel/darwin/{machtraps.h,
machtrap_dispatch.cpp}`; `source/emulation/cpu/cpu64DarwinRun.cpp`;
`tools/rootfs-darling/build-darling-zip.sh`; `tools/run_darling_cli.sh`; emscripten
`wasm64-darwin` goal(s); `darwin.html`; `UPSTREAM.md`.
**Edited (small hooks):** `source/kernel/syscall64.cpp` (ioctl routing ~2892; new Darwin
syscall `case`s in `ksyscall64` ~2707); `source/sdl/startupArgs.cpp` (device reg ~125–149,
zip mounts ~162); `source/sdl/main.cpp` (`--darwin-run`/`--darwin-selftest` ~216–230);
Xcode scheme + `project/emscripten/makefile` (`BOXEDWINE_DARWIN`).

## Reuse (new code is minimal)
ELF64 loader (`loader64.cpp`/`kelf64.h`), KMemory64 (`kmemory64.cpp`), threads/futex/
`clone`/`fork`/`execve`/`wait4`, AF_UNIX/epoll/`sendmsg`/`SCM_RIGHTS`, SysV shm, the
`FsVirtualOpenNode` device framework, `FsZip` rootfs mounting, the `SYS64` tracer, the
GL/X11/devfb GUI surface, and the emscripten build scaffolding — all reused unchanged.

## Verification (end-to-end)
1. Build (Xcode `Boxedwine` scheme with `BOXEDWINE_DARWIN`) and confirm `--x64-selftest`
   stays **234/234** (no wine-path regression) and `--darwin-selftest` passes.
2. `--darwin-run <hello.macho>` with `DEV_MACH_TRACE=1` + `SYS64` tracing → exits 0, prints
   "hello" to host stdout (Phases B–D).
3. `tools/run_darling_cli.sh /bin/bash -c 'echo hi; ls /'` → correct output from the Docker
   -built zip rootfs (Phases E–F) — the **v1 success criterion**.
4. (Later) `--darwin-run` an AppKit app → window on screen (Phase H); `node ... --darwin-run
   hello` and a browser tab (Phase I).
