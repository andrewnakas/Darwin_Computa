// dyldsym.h — Darwin dyld image symbolizer (bring-up diagnostic).
//
// Purpose: when launchd (or any Darwin guest) aborts before installing a Mach
// exception handler, we have only a raw RIP and a few stack words. To name the
// faulting image we capture the guest's `dyld_all_image_infos` pointer — which
// mldr hands darlingserver in the `set_dyld_info` RPC (call #17) over the
// AF_UNIX socket — then, on abort, walk that array IN THE GUEST'S memory to map
// every loaded image base -> install-name, and report which image owns the RIP.
//
// All of this is env-gated diagnostic scaffolding (BW64_ABRTBT); it has no
// effect on normal execution. See memory darwin-computa-next-prefix-walk.
#ifndef __DYLDSYM_H__
#define __DYLDSYM_H__

#ifdef BOXEDWINE_DARWIN
#include "platformtypes.h"

// Record the dyld_all_image_infos location reported by `pid` via the
// set_dyld_info RPC. Called from the AF_UNIX dgram send path when it recognizes
// callnum 17. `addr`/`length` are the RPC's `address`/`length` body fields.
void bw64_recordDyldInfo(U32 pid, U64 addr, U64 length);

// Inspect a just-sent darlingserver RPC datagram payload. If it is a
// set_dyld_info call (callnum 17), capture its all-image-infos pointer.
// `data`/`len` is the raw datagram body; `pid` is the sending guest process.
void bw64_sniffDyldInfoRpc(U32 pid, const U8* data, U64 len);

// Walk `pid`'s dyld_all_image_infos and klog every loaded image base->path.
// If `rip` is non-zero, also report which image (and offset) contains it.
// No-op if we never captured an all-image-infos pointer for `pid`.
void bw64_dumpDyldImages(U32 pid, U64 rip);

#endif // BOXEDWINE_DARWIN
#endif // __DYLDSYM_H__
