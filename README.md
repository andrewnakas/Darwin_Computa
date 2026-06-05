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

Pre-alpha. The emulated-Linux substrate is mature (it boots 64-bit Wine to a rendered GUI); the Darwin layer is under active bring-up. Current milestones:

- **Boot harness** — `--darwin-run <mach-o>` stages the Darling rootfs and runs `mldr` → `dyld` through the standard emulator path.
- **Additive build gate** — all Darwin work is behind `BOXEDWINE_DARWIN`; the Wine path is unchanged and `--x64-selftest` passes **234/234**. `--darwin-selftest` passes **12/12**.
- **Real Darling runs under emulation** — the Docker rootfs build stages the actual Darling release (`v0.1.20260222`); `mldr` runs through glibc/`ld.so` init, the `ptrace` startup probe, and opens/mmaps the target Mach-O.
- **`darlingserver` boots to the `launchd` exec** — Darling's userspace kernel runs its full startup on the emulated kernel: prefix setup, Unix-socket bind, epoll loop, container-init fork, and the exec of `launchd` via `mldr vchroot`. Reaching this required implementing the syscalls the trace surfaced — `eventfd`/`timerfd` (mapped onto the emulator's existing event/timer objects), the `chown`/`chmod` families, root credentials (`setuid`/`setres*`), `/etc/passwd`, `/proc/sys/fs/nr_open`, and no-op `unshare`/`mount` (the guest VFS is already private, so no real namespaces/overlay are needed).
- **Prefix-init walk eliminated** — darlingserver previously mirrored the entire ~375 MB prefix onto itself on every launch (`copyAndSetAttributes`, ~400k `stat`/`utimensat`/`fchownat`/`fchmodat` syscalls, minutes per boot). Selecting darlingserver's overlayfs path (a single no-op `mount`) instead of the non-overlay copy path removes the walk entirely; startup now reaches the `launchd` exec in seconds.

**Next:** carry `launchd` through `mldr`+`vchroot` inside the prefix (current blocker: the `vchroot` helper path), then the `mldr ↔ darlingserver` `dserver_rpc_*` checkin over AF_UNIX, then `/proc/<pid>/maps` and ptrace-backed Mach-exception delivery — at which point a Mach-O reaches `main`. The longer roadmap targets a headless CLI, then `bash`/`ls`, then a Cocoa window, then WebAssembly.

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
"$BW" --darwin-run /usr/bin/hello     # boot a Mach-O under emulated Darling
```

The `Boxedwine` / Debug scheme defines `BOXEDWINE_GUEST_X64=1` and `BOXEDWINE_DARWIN=1`. Sources live in an Xcode synchronized folder group, so new files under `source/` compile automatically without project edits.

The Darling rootfs (Darling's amd64 userland, staged into a zip the same way Boxedwine stages a Wine prefix) is built via Docker; see [`tools/rootfs-darling/`](tools/rootfs-darling/). It is built once on a Linux-capable host and then runs anywhere.

### Tracing

| Variable | Effect |
| --- | --- |
| `BW64_SYSTRACE=1` | Trace emulated Linux syscalls |
| `BW64_DEVMACHTRACE=1` | Trace Mach traps through the `/dev/mach` device |
| `BW64_DIRTRACE=1` | Trace directory reads (`getdents64`) |

Driver script for the darlingserver bring-up: [`tools/run_darling_cli.sh`](tools/run_darling_cli.sh).

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
