/*
 *  Copyright (C) 2012-2026  The BoxedWine Team
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef __DARWIN_DEVMACH_H__
#define __DARWIN_DEVMACH_H__

#ifdef BOXEDWINE_DARWIN

class FsNode;
class FsOpenNode;
class CPU64;

// Factory for the /dev/mach virtual device (registered in startupArgs.cpp).
FsOpenNode* openDevMach(const std::shared_ptr<FsNode>& node, U32 flags, U32 data);

// Route a 64-bit ioctl(fd, DARLING_MACH_API_BASE+trap, paramv) to the /dev/mach
// trap dispatcher. Returns -K_ENODEV if openNode is not a DevMach, else the
// guest-visible ioctl return value. Called from syscall64.cpp's ioctl handler.
S64 devMachIoctl(FsOpenNode* openNode, CPU64* cpu, U64 request, U64 paramv);

// The trap dispatcher proper (device-independent). Exposed for --darwin-selftest
// so the handshake logic can be exercised without the FsOpenNode/VFS machinery.
S64 darwinMachTrapDispatch(CPU64* cpu, U64 request, U64 paramv);

#endif // BOXEDWINE_DARWIN
#endif // __DARWIN_DEVMACH_H__
