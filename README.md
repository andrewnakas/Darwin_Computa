# Darwin_Computa

**Run Darling's macOS userland on an emulated Linux kernel, with no real kernel, no root, and no host OS dependency — including in the browser.**

[![License: GPL v2](https://img.shields.io/badge/License-GPLv2-blue.svg)](license.txt)
[![Built on Boxedwine](https://img.shields.io/badge/built%20on-Boxedwine64-8a2be2.svg)](https://github.com/danoon2/Boxedwine)
[![Status: WIP](https://img.shields.io/badge/status-pre--alpha-yellow.svg)](#status)

Darwin_Computa runs [**Darling**](https://github.com/darlinghq/darling) — the open-source macOS compatibility layer — on top of [**Boxedwine**](https://github.com/danoon2/Boxedwine)'s userspace Linux-kernel emulator. Because the kernel is emulated rather than required, Darling's userland (`dyld`, `libSystem`, the frameworks, `launchd`) can run on macOS, Windows, Linux, and WebAssembly without a real Linux kernel underneath.

This repository reimplements **no** macOS functionality. It runs Darling's actual binaries unmodified and supplies the kernel surface they expect. All credit for the macOS userland belongs to [Darling](https://github.com/darlinghq/darling); please support that project.

---

## Background

Darling provides macOS binary compatibility on Linux the way Wine does for Windows: an honest reimplementation of the userland (Cocoa, Foundation, the Objective-C runtime, `dyld`, `libSystem`) with no Apple code. It depends on a **real Linux kernel** to deliver the Mach traps, BSD syscalls, namespaces, and ptrace-based exception handling that Darwin binaries require.

Boxedwine takes a different approach to portability: instead of virtualizing hardware, it implements an x86 CPU interpreter plus a **Linux kernel emulated in userspace**, and runs Wine on top. No VM, no hypervisor, no root, no real Linux — which is what lets it run Windows applications in a browser tab ([boxedwine.org](https://www.boxedwine.org)).

Darwin_Computa combines the two: it runs Darling on Boxedwine64's emulated kernel instead of Wine, so Darling's userland becomes portable to any target the CPU emulator runs on.

This repo is a fork of **Boxedwine64** (the 64-bit-guest fork of Boxedwine); the Darwin-specific work is gated behind the additive `BOXEDWINE_DARWIN` build define so the upstream Wine path is unchanged. See [`UPSTREAM.md`](UPSTREAM.md) for the exact base commit and the upstream-merge procedure.

---

## Architecture

```
   macOS binary (Mach-O)
        │
        ▼
   Darling userland: mldr → dyld → libSystem → frameworks      (Darling's real binaries)
        │                              │
   BSD syscalls            Mach traps / RPC to darlingserver
        │                              │
        ▼                              ▼
   ┌────────────────────────────────────────────────────────┐
   │  Darwin_Computa = Boxedwine64's userspace Linux kernel  │
   │  + the host syscalls Darling/darlingserver require      │
   │  (AF_UNIX, epoll, eventfd, timerfd, ptrace, procfs, …)  │
   └────────────────────────────────────────────────────────┘
        │
        ▼
   x86-64 interpreter  →  macOS / Windows / Linux / WebAssembly
```

Modern Darling does **not** use the historical `/dev/mach` kernel module. It runs
**`darlingserver`**, a userspace Linux process that acts as the macOS "kernel" (it
embeds a port of XNU); macOS processes reach it over a Unix socket via the
`dserver_rpc_*` protocol. This is structurally the same model as Boxedwine's own
`wineserver`, and the emulator already implements the primitives darlingserver
relies on (AF_UNIX + `SCM_RIGHTS`, `epoll`, `eventfd`, `timerfd`, `clone`/`futex`).

The plan is therefore to run Darling's real `darlingserver` on the emulated kernel and
fill the remaining host-syscall gaps, rather than reimplement the Mach ABI in C++. An
earlier emulated `/dev/mach` trap device (`DARLING_MACH_API_VERSION 19`,
`--darwin-selftest`) remains in-tree but targets the older LKM ABI and is largely
vestigial for the current Darling release.

---

## Status

Pre-alpha — but **real macOS command-line binaries now run end-to-end and print correct output** under the emulator. The emulated-Linux substrate is mature (it boots 64-bit Wine to a rendered GUI); the Darwin layer reaches a working `mldr → dyld → libSystem → darlingserver` app pipeline.

### ✅ Working today

Real Darling/macOS Mach-O CLIs execute through the full pipeline and exit cleanly (`exit_group` status 0):

| Binary | Output under Darwin_Computa |
| --- | --- |
| `/usr/bin/sw_vers` | `ProductName: macOS` · `ProductVersion: 11.7.4` · `BuildVersion: Darling` |
| `/usr/bin/uname` | `Darwin` |
| `/usr/bin/arch` | `i386` |
| `/usr/bin/hostname` | `boxedwine64` |
| `/bin/date` | `Sun Jun  7 00:10:05 UTC 2026` |

One command runs and shows the output like a terminal (the `--window` flag opens it in a macOS Terminal.app window):

```sh
tools/run_darling_app.sh /usr/bin/sw_vers            # prints to this terminal
tools/run_darling_app.sh /usr/bin/sw_vers --window   # opens a Terminal.app window
```

This works by having `darlingserver` exec the target binary as its container **init** process (via the `DSERVER_INIT` env var the harness forwards), so a self-contained CLI runs without needing `launchd`'s service bootstrap. First run is ~60–90 s (prefix walk + `dyld`).

### Milestones

- **Boot harness** — `--darwin-run <mach-o>` stages the Darling rootfs and runs `mldr` → `dyld` through the standard emulator path.
- **Additive build gate** — all Darwin work is behind `BOXEDWINE_DARWIN`; the Wine path is unchanged and `--x64-selftest` passes **234/234**. `--darwin-selftest` passes **12/12**.
- **Real Darling runs under emulation** — the Docker rootfs build stages the actual Darling release (`v0.1.20260222`); `mldr` runs through glibc/`ld.so` init, the `ptrace` startup probe, and opens/mmaps the target Mach-O.
- **`darlingserver` boots and forks the container init** — Darling's userspace kernel runs its full startup on the emulated kernel: prefix setup, Unix-socket bind, epoll loop, PID-namespace container fork, and `mldr vchroot`. Reaching this required implementing the syscalls the trace surfaced — `eventfd`/`timerfd`, the `chown`/`chmod` families, root credentials, `/etc/passwd`, `/proc/sys/fs/nr_open`, PID-namespace modeling for `CLONE_NEWPID`, and no-op `unshare`/`mount`.
- **`mldr ↔ darlingserver` checkin works** — full `dserver_rpc_*` checkin over AF_UNIX with `SCM_RIGHTS` fd-passing, `process_vm_readv/writev`, `pidfd_open`, `/proc/<pid>/maps`, kqueue Mach-port channels, and the commpage. A Mach-O reaches and runs `main`, does real Mach IPC, and returns output.
- **`launchd` boots to a clean idle** — as PID 1 it runs `launchd_runtime_init` → banner → `jobmgr_init` → `launchd_runtime`, then parks both threads in `mach_msg`. (A run that looked like a deadlock was a tracing artifact; untraced it idles cleanly.)

**Next:**
- **Args to apps** (`echo hi`, `bash -c …`) — `DSERVER_INIT` passes only a path; needs an argv extension to the init exec, or the `launchd`/`launchctl` route.
- **Multiple apps / an interactive shell / windowed GUI apps** — requires fixing the `launchd` service bootstrap: `jobmgr_init` runs but `job_dispatch` never `fork`+`exec`s the System bootstrapper (`/bin/launchctl bootstrap -S System`) — no `socketpair`/`fork` is issued — so `launchctl`/`shellspawn`/`darling shell` never start. This is the current frontier.
- The longer roadmap then targets a Cocoa window and WebAssembly.

See [`docs/PLAN_DARWIN.md`](docs/PLAN_DARWIN.md) for the phased roadmap and [`docs/BOXEDWINE64.md`](docs/BOXEDWINE64.md) for the emulated-Linux substrate.

---

## Build and run (macOS arm64)

```sh
cd project/mac-xcode/Boxedwine
xcodebuild -project Boxedwine.xcodeproj -scheme Boxedwine \
           -configuration Debug -arch arm64 CODE_SIGNING_ALLOWED=NO \
           -derivedDataPath build_darwin build

BW=build_darwin/Build/Products/Debug/Boxedwine.app/Contents/MacOS/Boxedwine

"$BW" --x64-selftest                  # inherited substrate; expects 234/234
"$BW" --darwin-selftest               # Darwin /dev/mach trap layer; expects 12/12

# Run a real macOS CLI binary under emulated Darling and show its output:
tools/run_darling_app.sh /usr/bin/sw_vers            # prints to this terminal
tools/run_darling_app.sh /usr/bin/sw_vers --window   # opens a Terminal.app window
tools/run_darling_app.sh /usr/bin/uname              # other working examples:
tools/run_darling_app.sh /usr/bin/arch               #   arch, hostname, date, ...
```

The `Boxedwine` / Debug scheme defines `BOXEDWINE_GUEST_X64=1` and `BOXEDWINE_DARWIN=1`. Sources live in an Xcode synchronized folder group, so new files under `source/` compile automatically without project edits.

The Darling rootfs (Darling's amd64 userland, staged into a zip the same way Boxedwine stages a Wine prefix) is built via Docker; see [`tools/rootfs-darling/`](tools/rootfs-darling/). It is built once on a Linux-capable host and then runs anywhere.

### Tracing

| Variable | Effect |
| --- | --- |
| `BW64_SYSTRACE=1` | Trace emulated Linux syscalls |
| `BW64_DEVMACHTRACE=1` | Trace Mach traps through the `/dev/mach` device |
| `BW64_DIRTRACE=1` | Trace directory reads (`getdents64`) |

Driver scripts: [`tools/run_darling_app.sh`](tools/run_darling_app.sh) (run a macOS CLI app and show its output, `--window` for a Terminal.app window) and [`tools/run_darling_cli.sh`](tools/run_darling_cli.sh) (lower-level darlingserver bring-up driver).

---

## Project layout

| Path | Contents |
| --- | --- |
| `source/kernel/syscall64.cpp` | x86-64 Linux syscall dispatch (the Darwin-facing host surface) |
| `source/sdl/main.cpp` | Entry points, `--darwin-run` / selftest harnesses, `setupDarwinRun()` |
| `source/io/` | Emulated VFS, zip-backed rootfs (`FsZip`), path resolution |
| `tools/rootfs-darling/` | Docker tooling that stages the Darling userland into a rootfs zip |
| `docs/PLAN_DARWIN.md` | Phased bring-up roadmap and design notes |
| `docs/BOXEDWINE64.md` | Technical writeup of the emulated-Linux substrate |
| `UPSTREAM.md` | Base Boxedwine64 commit and upstream-merge procedure |

---

## Relationship to upstream projects

- **[Darling](https://github.com/darlinghq/darling)** — the macOS userland this project runs. Darwin_Computa reimplements none of it and exists only to make it portable. [Support Darling.](https://github.com/sponsors/darlinghq)
- **[Boxedwine](https://github.com/danoon2/Boxedwine)** (by danoon2) — the userspace CPU-and-kernel emulator this is built on.
- **Boxedwine64** — the 64-bit-guest fork this repository is derived from (see [`UPSTREAM.md`](UPSTREAM.md)).
- **[Wine](https://www.winehq.org)** and Apple's open-source [XNU/Darwin](https://github.com/apple-oss-distributions/xnu) — the prior art and the kernel ABI being implemented, respectively.

---

## License

GPL v2, inherited from Boxedwine — see [`license.txt`](license.txt). This repository contains **no** Apple or Darling source; the Darling userland is fetched and staged at build time, never vendored. Darling, `dyld`, `libSystem`, and related components retain their own licenses.
```
