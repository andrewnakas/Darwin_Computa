# Upstream provenance

Darwin_Computa is a fork of **Boxedwine64** (itself a fork of
[Boxedwine](https://github.com/danoon2/Boxedwine) by danoon2), copied in place so the
emulated-Linux substrate can be reused directly to run **Darling** (the macOS
compatibility layer) instead of Wine.

- **Copied from:** `/Users/nakas/Documents/boxedwine64/Boxedwine64`
- **Upstream commit at copy time:** `8569a962e4d666bd119a8f9cbd28af5047972b3f`
  (`wasm64-mt: WebGL2 backend for the gl64 OpenGL bridge`)
- **Copied:** 2026-06-05

## What was excluded from the copy
Regenerable build outputs and the Wine64 rootfs payload were NOT copied (they are
rebuilt locally):
- `project/mac-xcode/build_dd`, `build_asan`, `build_refwatch`, `build_baseline`
- `project/mac-xcode/Boxedwine/build`
- `tools/rootfs64/{root,dist,work}` (the built wine64 zips — regenerate with
  `tools/rootfs64/build-wine64-zip.sh` if the wine path is needed)
- `.git`, `*.o`, `.DS_Store`

## Merging upstream Boxedwine64 fixes
All Darwin_Computa additions are gated behind `BOXEDWINE_DARWIN` (which depends on
`BOXEDWINE_GUEST_X64`) and live in new files where possible, so the Wine/64-bit path is
untouched. To pull a core fix from upstream boxedwine64, cherry-pick by hand against the
commit recorded above.

## Darwin-specific additions (see the plan)
- `source/kernel/devs/devmach.cpp` — emulated `/dev/mach` (Darling LKM trap interface)
- `source/kernel/darwin/{machtraps.h, machtrap_dispatch.cpp}` — Mach/BSD trap dispatch
- `source/emulation/cpu/cpu64DarwinRun.cpp` — `--darwin-run` harness
- `tools/rootfs-darling/build-darling-zip.sh`, `tools/run_darling_cli.sh`
- ioctl routing hook in `source/kernel/syscall64.cpp`; device registration in
  `source/sdl/startupArgs.cpp`; harness flags in `source/sdl/main.cpp`
