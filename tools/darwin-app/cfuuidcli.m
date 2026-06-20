/*
 * cfuuidcli.m — M44: CFUUID + CFString via the CoreFoundation C API. The CF C-layer
 * counterpart to M23's NSUUID (Obj-C layer): generate a UUID with CFUUIDCreate,
 * format to a CFStringRef, parse a known UUID string back via CFUUIDCreateFromString,
 * and extract its 16 bytes — exercising the CFString<->CFUUID bridge with the pure-C
 * CoreFoundation API (NO ObjC runtime in the path at all). No networking.
 *
 * This is intentionally a PURE-C probe (no #import <Foundation>) so the file compiles
 * against our extern CF declarations with no SDK-header collision (the Foundation
 * umbrella would otherwise pull in the real CFUUID.h and conflict). All symbols were
 * VERIFIED EXPORTED in the staged CoreFoundation before authoring (the M22 lesson);
 * CoreFoundation is linked BY PATH (the M17 finding). CFUUIDBytes is a fixed 16-byte
 * struct (stable ABI), mirrored here as MyCFUUIDBytes.
 *
 *   - CFUUIDCreate -> CFUUIDCreateString -> a 36-char "8-4-4-4-12" string,
 *   - two generated UUID strings differ,
 *   - CFUUIDCreateFromString on a known UUID -> CFUUIDGetUUIDBytes == the known bytes.
 *
 *   M44-CFVER-<n>          kCFCoreFoundationVersionNumber (the CF C lib is live; > 0)
 *   M44-GENLEN-<n>         generated UUID string length  (== 36)
 *   M44-DASHES-<n>         number of '-' in the generated string  (== 4)
 *   M44-UNIQUE-OK          two generated UUID strings differ
 *   M44-BYTES-<hex>        bytes of a known UUID parsed from its string
 *   M44-BYTES-OK          == the authoritative host bytes
 *   M44-DONE
 */
#include <stdio.h>
#include <string.h>

/* ---- CoreFoundation C API (extern; no CF headers imported) ---------------- */
typedef const void* CFTypeRef;
typedef const struct __CFUUID* CFUUIDRef;
typedef const struct __CFString* CFStringRef;
typedef const struct __CFAllocator* CFAllocatorRef;
typedef long CFIndex;
typedef unsigned int CFStringEncoding;
typedef unsigned char Boolean;
typedef struct { unsigned char b[16]; } MyCFUUIDBytes;   /* mirrors CFUUIDBytes (16 bytes) */

extern double kCFCoreFoundationVersionNumber;
extern CFUUIDRef   CFUUIDCreate(CFAllocatorRef);
extern CFStringRef CFUUIDCreateString(CFAllocatorRef, CFUUIDRef);
extern CFUUIDRef   CFUUIDCreateFromString(CFAllocatorRef, CFStringRef);
extern MyCFUUIDBytes CFUUIDGetUUIDBytes(CFUUIDRef);
extern CFIndex     CFStringGetLength(CFStringRef);
extern Boolean     CFStringGetCString(CFStringRef, char*, CFIndex, CFStringEncoding);
extern CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char*, CFStringEncoding);
extern void        CFRelease(CFTypeRef);
#define kCFStringEncodingUTF8 0x08000100

static int genUUIDString(char* out, int cap) {
    CFUUIDRef u = CFUUIDCreate(NULL);
    CFStringRef s = CFUUIDCreateString(NULL, u);
    Boolean ok = CFStringGetCString(s, out, cap, kCFStringEncodingUTF8);
    int len = (int)CFStringGetLength(s);
    CFRelease(s); CFRelease(u);
    return ok ? len : -1;
}

int main(int argc, const char* argv[]) {
    printf("M44-CFVER-%d\n", (int)kCFCoreFoundationVersionNumber); fflush(stdout);

    char a[64]; int la = genUUIDString(a, sizeof(a));
    printf("M44-GENLEN-%d\n", la); fflush(stdout);
    int dashes = 0; for (char* p = a; *p; p++) if (*p == '-') dashes++;
    printf("M44-DASHES-%d\n", dashes); fflush(stdout);

    char b[64]; genUUIDString(b, sizeof(b));
    printf("M44-UNIQUE-%s\n", strcmp(a, b) != 0 ? "OK" : "FAIL"); fflush(stdout);

    /* parse a known UUID string -> bytes */
    const char* known = "01234567-89AB-4CDE-8F01-23456789ABCD";
    const char* kBytes = "0123456789ab4cde8f0123456789abcd";
    CFStringRef ks = CFStringCreateWithCString(NULL, known, kCFStringEncodingUTF8);
    CFUUIDRef ku = CFUUIDCreateFromString(NULL, ks);
    MyCFUUIDBytes by = CFUUIDGetUUIDBytes(ku);
    char hex[33]; static const char* H = "0123456789abcdef";
    for (int i = 0; i < 16; i++) { hex[2*i] = H[by.b[i] >> 4]; hex[2*i+1] = H[by.b[i] & 0xf]; }
    hex[32] = '\0';
    CFRelease(ku); CFRelease(ks);
    printf("M44-BYTES-%s\n", hex); fflush(stdout);
    printf("M44-BYTES-%s\n", strcmp(hex, kBytes) == 0 ? "OK" : "FAIL"); fflush(stdout);

    printf("M44-DONE\n"); fflush(stdout);
    return 0;
}
