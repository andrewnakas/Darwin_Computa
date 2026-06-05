# tools/rootfs-darling — the Darling (macOS userland) rootfs

This stages **Darling's amd64 userland** into the layered zips that Darwin_Computa
mounts to run Mach-O binaries on the emulated-Linux substrate. It is the Darwin
analogue of [`tools/rootfs64`](../rootfs64) (which does the same for wine64).

## What gets produced

`build-darling-zip.sh` writes two zips into `dist/` (gitignored — build artifacts):

| Zip | Role |
|-----|------|
| `glibc-rootfs64.zip` | **Base.** glibc dynamic linker + libc + the Linux `.so` closure of `mldr`. `mldr` is an ordinary x86_64 **Linux** ELF, so it needs a Linux `ld.so`/`libc` to start — exactly like wine64. (Same name/role as the wine64 base, so the launcher mounts it unchanged.) |
| `darling.zip` | **Overlay.** Darling's install tree: `mldr` at `/usr/libexec/darling/mldr`, plus the Darwin prefix (dyld, `libSystem`, frameworks) it loads. |

## How to build it

It needs **Docker** (for a `linux/amd64` image with Darling installed) because
Darling ships amd64 binaries and the interpreter executes x86_64.

1. **Build the base image once** (slow — emulated amd64 — but one time). The
   recipe is in the header comment of `build-darling-zip.sh`; the short version,
   using Darling's published `.deb`:

   ```sh
   docker run --name darlingbuild --platform linux/amd64 ubuntu:24.04 bash -c '
     export DEBIAN_FRONTEND=noninteractive
     apt-get update -qq && apt-get install -y -qq wget ca-certificates
     wget -q -O /tmp/darling.deb <URL-of-darling_amd64.deb>   # see darling releases
     apt-get install -y -qq /tmp/darling.deb'
   docker commit darlingbuild darwin-computa/darling:base
   docker rm darlingbuild
   ```

   (Or build Darling from source — see
   [darlinghq/darling-docker](https://github.com/darlinghq/darling-docker).)

2. **Stage + zip:**

   ```sh
   tools/rootfs-darling/build-darling-zip.sh
   ```

   Override `DARLING_IMAGE` to point at a different image, or `DARLING_PREFIX` if
   your image puts the Darwin root somewhere other than
   `/usr/local/libexec/darling`.

## How to run something from it

```sh
tools/run_darling_cli.sh /usr/bin/sw_vers
# trace the Mach traps the guest issues (the discovery-loop instrument):
BW64_DEVMACHTRACE=1 tools/run_darling_cli.sh /usr/bin/sw_vers
```

## Notes

- The zips are **large** (Darling's prefix is a near-complete macOS userland).
  That's expected; Phase I makes the rootfs lazily streamable for the web build.
- This repo contains **no** Apple or Darling binaries — they are fetched/staged
  here at build time, never committed (`dist/` is gitignored).
