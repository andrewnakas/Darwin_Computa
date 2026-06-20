/*
 * cfcollcli.m — M45: CFArray + CFDictionary + CFNumber via the CoreFoundation C API.
 * Extends M44's CF C-layer proof to the CONTAINER types: build a CFArray of CFStrings
 * and a CFDictionary of CFString->CFNumber via the pure-C interface, then read counts,
 * indexed values, and key lookups — exercising the CF retain/callback machinery
 * (kCFTypeArrayCallBacks etc.) with NO ObjC runtime in the path. No networking.
 *
 * PURE-C probe (no #import <Foundation>) per the M44 trick, so our extern CF decls
 * don't collide with the real CF headers the Foundation umbrella would pull in. All
 * symbols pre-vetted exported (M22); CoreFoundation linked BY PATH (M17). The
 * callback-struct globals are passed by address to the create functions.
 *
 *   - CFArray of 3 CFStrings: count == 3, value at index 1 compares-equal to "beta",
 *   - CFDictionary {"answer"->42, "n"->7}: count == 2, lookup "answer" -> 42.
 *
 *   M45-ARRCOUNT-<n>       CFArrayGetCount  (== 3)
 *   M45-ARRIDX-OK         CFArrayGetValueAtIndex(1) equals "beta" (CFStringCompare==0)
 *   M45-DICTCOUNT-<n>      CFDictionaryGetCount  (== 2)
 *   M45-DICTVAL-<n>        CFNumber for key "answer" via CFDictionaryGetValue  (== 42)
 *   M45-DICTVAL-OK        == 42
 *   M45-DONE
 */
#include <stdio.h>
#include <string.h>

typedef const void* CFTypeRef;
typedef const struct __CFString* CFStringRef;
typedef const struct __CFArray*  CFArrayRef;
typedef const struct __CFDictionary* CFDictionaryRef;
typedef const struct __CFNumber* CFNumberRef;
typedef const struct __CFAllocator* CFAllocatorRef;
typedef long CFIndex;
typedef unsigned int CFStringEncoding;
typedef CFIndex CFComparisonResult;     /* 0 == kCFCompareEqualTo */
typedef CFIndex CFNumberType;
#define kCFNumberIntType 9
#define kCFStringEncodingUTF8 0x08000100

/* opaque callback-struct globals (passed by address) */
extern const void* kCFTypeArrayCallBacks;
extern const void* kCFTypeDictionaryKeyCallBacks;
extern const void* kCFTypeDictionaryValueCallBacks;

extern CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char*, CFStringEncoding);
extern CFComparisonResult CFStringCompare(CFStringRef, CFStringRef, unsigned long);
extern CFArrayRef  CFArrayCreate(CFAllocatorRef, const void** values, CFIndex n, const void* cb);
extern CFIndex     CFArrayGetCount(CFArrayRef);
extern const void* CFArrayGetValueAtIndex(CFArrayRef, CFIndex);
extern CFNumberRef CFNumberCreate(CFAllocatorRef, CFNumberType, const void* valuePtr);
extern unsigned char CFNumberGetValue(CFNumberRef, CFNumberType, void* out);
extern CFDictionaryRef CFDictionaryCreate(CFAllocatorRef, const void** keys,
                                          const void** vals, CFIndex n,
                                          const void* keyCB, const void* valCB);
extern CFIndex     CFDictionaryGetCount(CFDictionaryRef);
extern const void* CFDictionaryGetValue(CFDictionaryRef, const void* key);
extern void        CFRelease(CFTypeRef);

int main(int argc, const char* argv[]) {
    /* ---- CFArray of CFStrings ----------------------------------------------- */
    CFStringRef s0 = CFStringCreateWithCString(NULL, "alpha", kCFStringEncodingUTF8);
    CFStringRef s1 = CFStringCreateWithCString(NULL, "beta",  kCFStringEncodingUTF8);
    CFStringRef s2 = CFStringCreateWithCString(NULL, "gamma", kCFStringEncodingUTF8);
    const void* items[3] = { s0, s1, s2 };
    CFArrayRef arr = CFArrayCreate(NULL, items, 3, &kCFTypeArrayCallBacks);
    printf("M45-ARRCOUNT-%ld\n", (long)CFArrayGetCount(arr)); fflush(stdout);

    CFStringRef at1 = (CFStringRef)CFArrayGetValueAtIndex(arr, 1);
    CFStringRef beta = CFStringCreateWithCString(NULL, "beta", kCFStringEncodingUTF8);
    printf("M45-ARRIDX-%s\n", (CFStringCompare(at1, beta, 0) == 0) ? "OK" : "FAIL"); fflush(stdout);

    /* ---- CFDictionary CFString -> CFNumber --------------------------------- */
    int v42 = 42, v7 = 7;
    CFNumberRef n42 = CFNumberCreate(NULL, kCFNumberIntType, &v42);
    CFNumberRef n7  = CFNumberCreate(NULL, kCFNumberIntType, &v7);
    CFStringRef kAns = CFStringCreateWithCString(NULL, "answer", kCFStringEncodingUTF8);
    CFStringRef kN   = CFStringCreateWithCString(NULL, "n",      kCFStringEncodingUTF8);
    const void* keys[2] = { kAns, kN };
    const void* vals[2] = { n42, n7 };
    CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, vals, 2,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    printf("M45-DICTCOUNT-%ld\n", (long)CFDictionaryGetCount(dict)); fflush(stdout);

    CFNumberRef got = (CFNumberRef)CFDictionaryGetValue(dict, kAns);
    int out = -1;
    if (got) CFNumberGetValue(got, kCFNumberIntType, &out);
    printf("M45-DICTVAL-%d\n", out); fflush(stdout);
    printf("M45-DICTVAL-%s\n", (out == 42) ? "OK" : "FAIL"); fflush(stdout);

    CFRelease(arr); CFRelease(dict);
    CFRelease(s0); CFRelease(s1); CFRelease(s2); CFRelease(beta);
    CFRelease(n42); CFRelease(n7); CFRelease(kAns); CFRelease(kN);
    printf("M45-DONE\n"); fflush(stdout);
    return 0;
}
