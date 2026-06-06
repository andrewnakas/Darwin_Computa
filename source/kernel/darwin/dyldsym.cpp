// dyldsym.cpp — Darwin dyld image symbolizer (bring-up diagnostic).
// See dyldsym.h for the why. Env-gated by BW64_ABRTBT at the call sites.
#include "boxedwine.h"

#ifdef BOXEDWINE_DARWIN
#include "dyldsym.h"
#include "kmemory64.h"
#include "kprocess.h"
#include "ksystem.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <map>
#include <mutex>
#include <string>
#include <vector>

// darlingserver RPC: dserver_rpc_callhdr_t { uint32 number; int32 pid; int32 tid;
// uint32 architecture; } == 16 bytes, then the call body (8-byte aligned). For
// set_dyld_info (callnum 17) the body is { uint64 address; uint64 length; }.
static const U32 DSERVER_CALLNUM_SET_DYLD_INFO = 17;
static const U64 SET_DYLD_INFO_BODY_OFF = 16; // address at +16, length at +24

// Captured all-image-infos location, keyed by the reporting guest pid. mldr
// re-execs into launchd keeping the same pid, and the address lives in that
// (post-exec) address space, so a single per-pid slot is correct.
static std::mutex g_dyldMutex;
static std::map<U32, U64> g_dyldInfoAddr; // pid -> dyld_all_image_infos VA
static std::map<U32, U64> g_dyldInfoLen;  // pid -> reported size

void bw64_recordDyldInfo(U32 pid, U64 addr, U64 length) {
    std::lock_guard<std::mutex> lk(g_dyldMutex);
    g_dyldInfoAddr[pid] = addr;
    g_dyldInfoLen[pid] = length;
    klog_fmt("DYLDSYM: captured all_image_infos for pid=%u addr=0x%llx len=0x%llx",
             pid, (unsigned long long)addr, (unsigned long long)length);
}

void bw64_sniffDyldInfoRpc(U32 pid, const U8* data, U64 len) {
    if (!data || len < SET_DYLD_INFO_BODY_OFF + 16) return;
    U32 callnum = (U32)data[0] | ((U32)data[1] << 8) | ((U32)data[2] << 16) | ((U32)data[3] << 24);
    if (callnum != DSERVER_CALLNUM_SET_DYLD_INFO) return;
    auto rd64 = [&](U64 off) -> U64 {
        U64 v = 0;
        for (int i = 0; i < 8; i++) v |= (U64)data[off + i] << (8 * i);
        return v;
    };
    U64 addr = rd64(SET_DYLD_INFO_BODY_OFF);
    U64 length = rd64(SET_DYLD_INFO_BODY_OFF + 8);
    bw64_recordDyldInfo(pid, addr, length);
}

// Read a NUL-terminated guest C string (bounded) from a target's memory64.
static std::string readGuestCStr(KMemory64* mem, U64 va, U32 maxLen = 1024) {
    std::string s;
    if (!va) return s;
    for (U32 i = 0; i < maxLen; i++) {
        U8 c = 0;
        mem->memcpyFromGuest(&c, va + i, 1);
        if (!c) break;
        s.push_back((char)c);
    }
    return s;
}

void bw64_dumpDyldImages(U32 pid, U64 rip) {
    U64 infoAddr = 0;
    {
        std::lock_guard<std::mutex> lk(g_dyldMutex);
        auto it = g_dyldInfoAddr.find(pid);
        if (it != g_dyldInfoAddr.end()) infoAddr = it->second;
    }
    if (!infoAddr) {
        klog_fmt("DYLDSYM: no all_image_infos captured for pid=%u — cannot symbolize", pid);
        return;
    }
    KProcessPtr proc = KSystem::getProcess(pid);
    if (!proc || !proc->memory64) {
        klog_fmt("DYLDSYM: pid=%u not found / no memory64", pid);
        return;
    }
    KMemory64* mem = proc->memory64;

    // struct dyld_all_image_infos (x86_64):
    //   uint32 version            @ 0
    //   uint32 infoArrayCount     @ 4
    //   const dyld_image_info* infoArray @ 8
    U32 version = (U32)mem->readq(infoAddr) & 0xffffffffu;
    U32 count = (U32)(mem->readq(infoAddr) >> 32);
    U64 infoArray = mem->readq(infoAddr + 8);
    klog_fmt("DYLDSYM: all_image_infos@0x%llx version=%u infoArrayCount=%u infoArray=0x%llx",
             (unsigned long long)infoAddr, version, count, (unsigned long long)infoArray);

    // Even when the public infoArray isn't populated yet (early dyld), other
    // fields of dyld_all_image_infos are. Surface the most useful ones:
    //   0x10 notification, 0x20 dyldImageLoadAddress (dyld's own base),
    //   0x30 dyldVersion (char*), 0x38 errorMessage (char*),
    //   0x48 uuidArrayCount, 0x50 uuidArray, 0x60 dyldAllImageInfosAddress,
    //   0xC8 sharedCacheBaseAddress, 0xF0 errorKind, 0xF8 errorClientOfDylibPath,
    //   0x100 errorTargetDylibPath, 0x108 errorSymbol.
    U64 dyldBase   = mem->readq(infoAddr + 0x20);
    U64 dyldVerPtr = mem->readq(infoAddr + 0x30);
    U64 errMsgPtr  = mem->readq(infoAddr + 0x38);
    std::string dyldVer = readGuestCStr(mem, dyldVerPtr);
    std::string errMsg  = readGuestCStr(mem, errMsgPtr);
    klog_fmt("DYLDSYM: dyldImageLoadAddress=0x%llx dyldVersion='%s'",
             (unsigned long long)dyldBase, dyldVer.c_str());
    if (!errMsg.empty())
        klog_fmt("DYLDSYM: dyld errorMessage='%s'", errMsg.c_str());
    // dyld error detail block (set when dyld is about to abort on a load error)
    U64 errKind     = mem->readq(infoAddr + 0xF0) & 0xffffffffu;
    std::string errClient = readGuestCStr(mem, mem->readq(infoAddr + 0xF8));
    std::string errTarget = readGuestCStr(mem, mem->readq(infoAddr + 0x100));
    std::string errSymbol = readGuestCStr(mem, mem->readq(infoAddr + 0x108));
    if (errKind || !errClient.empty() || !errTarget.empty() || !errSymbol.empty()) {
        klog_fmt("DYLDSYM: dyld errorKind=%llu client='%s' target='%s' symbol='%s'",
                 (unsigned long long)errKind, errClient.c_str(),
                 errTarget.c_str(), errSymbol.c_str());
    }
    // Raw hexdump of the struct so any populated pointer is visible offline.
    {
        char line[160]; line[0] = 0;
        for (U64 off = 0; off < 0x118; off += 8) {
            U64 w = mem->readq(infoAddr + off);
            char one[48];
            snprintf(one, sizeof(one), "+0x%03llx=%016llx ", (unsigned long long)off, (unsigned long long)w);
            strncat(line, one, sizeof(line) - strlen(line) - 1);
            if (((off / 8) % 3) == 2) { klog_fmt("DYLDSYM: raw %s", line); line[0] = 0; }
        }
        if (line[0]) klog_fmt("DYLDSYM: raw %s", line);
    }
    if (count > 4096) {
        klog_fmt("DYLDSYM: implausible infoArrayCount=%u — struct layout wrong or not yet populated", count);
        return;
    }

    // struct dyld_image_info { const mach_header* imageLoadAddress @ 0;
    //                          const char* imageFilePath @ 8;
    //                          uintptr_t imageFileModDate @ 16; } == 24 bytes
    const char* ripOwner = nullptr;
    static std::string ripOwnerStr;
    U64 ripOwnerBase = 0;
    for (U32 i = 0; i < count; i++) {
        U64 ent = infoArray + (U64)i * 24;
        U64 loadAddr = mem->readq(ent + 0);
        U64 pathPtr = mem->readq(ent + 8);
        std::string path = readGuestCStr(mem, pathPtr);
        klog_fmt("DYLDSYM:   img[%u] base=0x%llx path=%s", i,
                 (unsigned long long)loadAddr, path.empty() ? "(null)" : path.c_str());
        if (rip && loadAddr && rip >= loadAddr) {
            // Best-effort owner: the image with the greatest base <= rip.
            if (loadAddr > ripOwnerBase) {
                ripOwnerBase = loadAddr;
                ripOwnerStr = path;
                ripOwner = ripOwnerStr.c_str();
            }
        }
    }
    if (rip) {
        if (ripOwner && ripOwnerBase) {
            klog_fmt("DYLDSYM: RIP 0x%llx is in %s + 0x%llx  (base 0x%llx)",
                     (unsigned long long)rip, ripOwner,
                     (unsigned long long)(rip - ripOwnerBase),
                     (unsigned long long)ripOwnerBase);
        } else {
            klog_fmt("DYLDSYM: RIP 0x%llx not contained in any listed image", (unsigned long long)rip);
        }
    }
}

#endif // BOXEDWINE_DARWIN
