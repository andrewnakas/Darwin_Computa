<div align="center">

# 🖥️ Darwin_Computa

### Run macOS apps anywhere. No Mac required. No Linux required either.

*A portable macOS userland — [**Darling**](https://www.darlinghq.org) running on an
**emulated** Linux kernel, so Darwin can go where it's never gone before: Windows, the
browser, your toaster (toaster support is on the roadmap).*

[![License: GPL v2](https://img.shields.io/badge/License-GPLv2-blue.svg)](license.txt)
[![Built on Boxedwine](https://img.shields.io/badge/built%20on-Boxedwine-8a2be2.svg)](https://github.com/danoon2/Boxedwine)
[![Amplifies Darling](https://img.shields.io/badge/mission-amplify%20Darling-orange.svg)](https://www.darlinghq.org)
[![Status: gloriously WIP](https://img.shields.io/badge/status-gloriously%20WIP-yellow.svg)](#current-state)

</div>

---

## The thirty-second pitch

[**Darling**](https://github.com/darlinghq/darling) is the heroic, decade-spanning effort
to do for macOS what Wine does for Windows: run its apps on Linux, honestly and without a
copy of macOS in sight. It is brilliant. It is also, by necessity, **stuck to Linux** — it
needs a real Linux kernel (historically a kernel module, these days a deep tangle of Linux
syscalls, namespaces, and a duct-taped XNU) to give Darwin binaries the Mach traps and BSD
syscalls they expect.

[**Boxedwine**](https://github.com/danoon2/Boxedwine) had the cheekiest idea in emulation:
*don't emulate a whole computer — emulate just the kernel.* It implements an x86 CPU and a
**fake Linux kernel in userland**, then runs Wine on top. No VM, no hypervisor, no root, no
real Linux. It runs Windows apps on macOS, Windows, Linux, **and in a browser tab.**

**Darwin_Computa** is what happens when those two ideas have a baby and the baby is raised
on spite and ambition:

> Take Boxedwine's fake-Linux-kernel-in-userland.
> Run **Darling** on it instead of Wine.
> Now macOS's userland runs *literally anywhere a CPU emulator can run.*

Windows → (Wine) → Boxedwine → everywhere. **macOS → (Darling) → Darwin_Computa → everywhere.**

It's emulators all the way down, and we are at peace with that.

---

## Wait, why does this exist? (The mission: amplify Darling)

**This project's entire reason for being is to make Darling reach further.**

Darling is doing the hard, unglamorous, profoundly important work — reimplementing Cocoa,
Foundation, the Objective-C runtime, dyld, libSystem, the lot. That work is *the* moat.
Darwin_Computa doesn't reimplement a single line of it. We are not a competitor, a fork, or
a "better Darling." We're a **delivery truck**:

- **Darling does the macOS.** We do the "anywhere."
- Every Mach trap Darling expects, we answer from a fake kernel instead of a Linux one.
- Every BSD syscall Darling makes, we serve from an interpreter instead of a host.
- The day Darling supports a new framework, Darwin_Computa carries it to Windows and the
  web **for free**, because we run *Darling's actual binaries* — we don't reimplement them.

If this project is ever useful, the credit is Darling's and Boxedwine's. We just removed the
word "Linux" from the system requirements. 🚚💨

> **Love Darling? [Go star it.](https://github.com/darlinghq/darling) [Go fund it.](https://github.com/sponsors/darlinghq) [Go contribute to it.](https://github.com/darlinghq/darling)**
> Darwin_Computa is worthless without the thing it amplifies. Upstream first, always.

---

## How it works (the trick)

A normal macOS binary on Linux, under Darling, talks to a Linux **kernel module** for its
Mach-y soul: it does `open("/dev/mach")` and then fires its Mach traps as `ioctl()`s against
that device — `mach_msg`, `mach_reply_port`, `thread_self_trap`, `psynch_*`, `task_for_pid`,
and ~80 friends. Its BSD syscalls go straight to the Linux kernel.

Boxedwine already emulates that Linux kernel in userland — ELF64 loading, real threads
(`clone`/`futex`), `fork`/`execve`, AF_UNIX sockets, `epoll`, `sendmsg` with `SCM_RIGHTS`,
~90 syscalls — well enough to boot real Debian `wine64` to a *rendered, clickable window.*
So the substrate Darling needs is **already sitting there**.

Darwin_Computa adds the one piece that was missing:

```
   macOS app (Mach-O)
        │
        ▼
   Darling: mldr → dyld → libSystem → Cocoa/Foundation     ← Darling's real binaries
        │                              │
   BSD syscalls                   ioctl(/dev/mach, BASE+trap, …)   ← the Mach kernel ABI
        │                              │
        ▼                              ▼
   ┌──────────────────────────────────────────────────────┐
   │  Darwin_Computa  =  Boxedwine's fake Linux kernel      │
   │  + an emulated /dev/mach that answers Darling's traps  │   ← the new bit (a virtual
   │  (Mach IPC, psynch, kqueue, the commpage) in C++       │      device, not a Linux LKM)
   └──────────────────────────────────────────────────────┘
        │
        ▼
   x86-64 interpreter  →  runs on macOS / Windows / Linux / WebAssembly
```

The kernel module that Darling needs on Linux becomes, here, **a virtual device inside the
emulator** — no root, no LKM, no real kernel. The same `ioctl(BASE+trap)` ABI, answered in
software. That's the whole magic trick.

---

## Current state

Honest status: **early, but the foundation is real and the hard part already works.**

The emulated-Linux substrate (inherited from
[Boxedwine64](https://github.com/danoon2/Boxedwine)) is mature — it boots real 64-bit Wine
to a GUI. On top of that, Darwin_Computa has:

- ✅ **The Darling boot harness** — `--darwin-run <mach-o>` stages the Darling rootfs and
  launches `mldr` → `dyld` through the normal emulator path.
- ✅ **`BOXEDWINE_DARWIN` build gate** — every Darwin addition is additive; the Wine path is
  bit-for-bit untouched and its self-test still passes **234/234**.
- ✅ **A self-test hook** — `--darwin-selftest` (the CI tripwire for the `/dev/mach` layer).
- 🚧 **The `/dev/mach` trap device** — Mach IPC + psynch + the commpage (in progress; this
  is the spike that gets `dyld`/libSystem past the kernel handshake).
- 🗺️ **Then:** a trivial Mach-O prints headless → `bash`/`ls` → Cocoa window → a browser tab.

See [`docs/PLAN_DARWIN.md`](docs/PLAN_DARWIN.md) for the phased roadmap (A→I, shamelessly
modeled on Boxedwine64's own bring-up log), [`UPSTREAM.md`](UPSTREAM.md) for exactly which
Boxedwine64 commit this was forked from and how to merge upstream fixes, and
[`docs/BOXEDWINE64.md`](docs/BOXEDWINE64.md) for the deep technical writeup of the
emulated-Linux substrate we build on.

---

## Build & run (macOS arm64, dev path)

```sh
cd project/mac-xcode/Boxedwine
xcodebuild -project Boxedwine.xcodeproj -scheme Boxedwine \
           -configuration Debug -arch arm64 CODE_SIGNING_ALLOWED=NO \
           -derivedDataPath build_darwin build

BW=build_darwin/Build/Products/Debug/Boxedwine.app/Contents/MacOS/Boxedwine

"$BW" --x64-selftest        # the inherited substrate (should print 234/234)
"$BW" --darwin-selftest     # the Darwin /dev/mach trap layer
"$BW" --darwin-run /usr/bin/hello   # boot a Mach-O under emulated Darling
```

The Darling rootfs (Darling's actual amd64 userland, staged into a zip the same way
Boxedwine stages a Wine prefix) is built via Docker — see
[`tools/rootfs-darling/`](tools/rootfs-darling/). You build it once and then it runs on a
machine that has never heard of Linux.

---

## FAQ for the reasonably skeptical

**Is this just a worse Darling?**
No — it's *the same* Darling, wearing a jetpack. We run Darling's real binaries. If Darling
can't do something, neither can we. If Darling learns to do something, we get it for free.

**Why not just run Darling in a VM / WSL / a Docker container?**
Those need a real Linux kernel (and often root, and a Linux to begin with). The point of the
Boxedwine approach is **no real kernel at all** — which is the only way you get the browser,
locked-down corporate Windows boxes, and weird embedded targets. A VM can't run in a `<canvas>`.

**Is it fast?**
It is an interpreter emulating an x86-64 CPU running a macOS compatibility layer running
your app. Speed is a Phase H problem. Manage your expectations and bring a snack.

**macOS GUI apps in a browser tab — for real?**
That's the north star, exactly like [boxedwine.org](https://www.boxedwine.org) does for
Windows apps today. We're not there yet. We're building toward it in the open.

**Did you ship a single line of macOS reimplementation?**
Not one. That's Darling's genius and Darling's glory. We ship a fake kernel and a delivery
truck. [Go support the people who built the actual thing.](https://github.com/darlinghq/darling)

---

## Standing on the shoulders of giants

Darwin_Computa is a thin idea on top of an enormous amount of other people's brilliance:

- **[Darling](https://github.com/darlinghq/darling)** by the DarlingHQ team — the macOS
  userland we run and the reason this project exists. **This is the project we exist to
  amplify.** Please support it.
- **[Boxedwine](https://github.com/danoon2/Boxedwine)** by **danoon2** — the userland
  CPU-and-fake-kernel emulator that makes "no real OS required" possible. The technical
  parent of this repo.
- **Boxedwine64** — the 64-bit-guest fork this is copied from (see [`UPSTREAM.md`](UPSTREAM.md)).
- **[Wine](https://www.winehq.org)** — for proving the whole "honest reimplementation, no
  pirated OS" philosophy decades ago, and for being the spiritual sibling of Darling.
- **Apple's open-source [XNU](https://github.com/apple-oss-distributions/xnu) / Darwin** —
  the actual kernel ABI everyone here is politely impersonating.

If you're going to spend your stars and your dollars on one project in this list,
**make it [Darling](https://github.com/darlinghq/darling).** We mean it.

---

## License

GPL v2, inherited from Boxedwine — see [`license.txt`](license.txt). Darling, dyld,
libSystem, and friends carry their own (mostly APSL/permissive) licenses; this repo contains
**no** Apple code and **no** Darling code — the Darling userland is fetched and staged at
build time, never vendored.

---

<div align="center">

*Built with reverence for Darling, larceny of Boxedwine's best idea, and the firm belief
that "you need a Mac to run Mac apps" was always more of a suggestion.*

🍎 → 🐧 → 🪟🌐🐧🍏 &nbsp;&nbsp; **Darwin, unstuck.**

</div>
