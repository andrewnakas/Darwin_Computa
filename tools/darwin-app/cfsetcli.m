/*
 * cfsetcli.m — M60: CFSet + CFBag via the CoreFoundation C API. Extends the proven
 * CF C-layer (M44 CFUUID/CFString, M45 CFArray/CFDictionary/CFNumber, M46 CFData)
 * to the SET and MULTISET container types — the pure-C counterparts to M34's NSSet
 * and M26's NSCountedSet. Exercises CFSet uniqueness/membership and CFBag's
 * per-value occurrence counts via the pure-C interface, driving the CF
 * retain/callback machinery (kCFTypeSetCallBacks / kCFTypeBagCallBacks) with NO
 * ObjC runtime in the path. No networking.
 *
 * PURE-C probe (no #import <Foundation>) per the M44 trick, so our extern CF decls
 * don't collide with the real CF headers the Foundation umbrella would pull in. All
 * symbols pre-vetted exported (M22); CoreFoundation linked BY PATH (M17). The
 * callback-struct globals are passed by address to the create functions.
 *
 *   - CFSet from {alpha, beta, gamma, beta}: dedups to count 3; CFSetContainsValue
 *     finds "beta" and rejects "delta",
 *   - CFMutableSet: add 2 then remove 1 -> count 1,
 *   - CFBag (multiset) from {a, a, a, b, b, c}: total count 6; CFBagGetCountOfValue
 *     for "a" == 3, for "c" == 1 (per-value occurrence counts).
 *
 *   M60-SETCOUNT-<n>       CFSetGetCount after dedup  (== 3)
 *   M60-SETHAS-1          CFSetContainsValue("beta")  (== 1)
 *   M60-SETNO-0           CFSetContainsValue("delta")  (== 0)
 *   M60-MUTSET-<n>         CFMutableSet add 2 / remove 1 -> count  (== 1)
 *   M60-BAGTOTAL-<n>       CFBagGetCount (total with multiplicity)  (== 6)
 *   M60-BAGA-<n>          CFBagGetCountOfValue("a")  (== 3)
 *   M60-BAGC-<n>          CFBagGetCountOfValue("c")  (== 1)
 *   M60-DONE
 */
#include <stdio.h>
#include <string.h>

typedef const void* CFTypeRef;
typedef const struct __CFString* CFStringRef;
typedef const struct __CFSet* CFSetRef;
typedef struct __CFSet* CFMutableSetRef;
typedef const struct __CFBag* CFBagRef;
typedef const struct __CFAllocator* CFAllocatorRef;
typedef long CFIndex;
typedef unsigned int CFStringEncoding;
#define kCFStringEncodingUTF8 0x08000100

/* opaque callback-struct globals (passed by address) */
extern const void* kCFTypeSetCallBacks;
extern const void* kCFTypeBagCallBacks;

extern CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char*, CFStringEncoding);

extern CFSetRef        CFSetCreate(CFAllocatorRef, const void** values, CFIndex n, const void* cb);
extern CFIndex         CFSetGetCount(CFSetRef);
extern unsigned char   CFSetContainsValue(CFSetRef, const void* value);
extern CFMutableSetRef CFSetCreateMutable(CFAllocatorRef, CFIndex capacity, const void* cb);
extern void            CFSetAddValue(CFMutableSetRef, const void* value);
extern void            CFSetRemoveValue(CFMutableSetRef, const void* value);

extern CFBagRef        CFBagCreate(CFAllocatorRef, const void** values, CFIndex n, const void* cb);
extern CFIndex         CFBagGetCount(CFBagRef);
extern CFIndex         CFBagGetCountOfValue(CFBagRef, const void* value);

extern void            CFRelease(CFTypeRef);

int main(int argc, const char* argv[]) {
    CFStringRef alpha = CFStringCreateWithCString(NULL, "alpha", kCFStringEncodingUTF8);
    CFStringRef beta  = CFStringCreateWithCString(NULL, "beta",  kCFStringEncodingUTF8);
    CFStringRef gamma = CFStringCreateWithCString(NULL, "gamma", kCFStringEncodingUTF8);
    CFStringRef delta = CFStringCreateWithCString(NULL, "delta", kCFStringEncodingUTF8);

    /* ---- CFSet: uniqueness + membership ------------------------------------- */
    const void* items[4] = { alpha, beta, gamma, beta };   /* beta twice -> dedups */
    CFSetRef set = CFSetCreate(NULL, items, 4, &kCFTypeSetCallBacks);
    printf("M60-SETCOUNT-%ld\n", (long)CFSetGetCount(set)); fflush(stdout);
    printf("M60-SETHAS-%d\n", CFSetContainsValue(set, beta) ? 1 : 0); fflush(stdout);
    printf("M60-SETNO-%d\n", CFSetContainsValue(set, delta) ? 1 : 0); fflush(stdout);

    /* ---- CFMutableSet: add 2, remove 1 ------------------------------------- */
    CFMutableSetRef ms = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    CFSetAddValue(ms, alpha);
    CFSetAddValue(ms, beta);
    CFSetRemoveValue(ms, alpha);
    printf("M60-MUTSET-%ld\n", (long)CFSetGetCount(ms)); fflush(stdout);

    /* ---- CFBag: multiset with per-value occurrence counts ------------------- */
    CFStringRef a = CFStringCreateWithCString(NULL, "a", kCFStringEncodingUTF8);
    CFStringRef b = CFStringCreateWithCString(NULL, "b", kCFStringEncodingUTF8);
    CFStringRef c = CFStringCreateWithCString(NULL, "c", kCFStringEncodingUTF8);
    const void* bagItems[6] = { a, a, a, b, b, c };
    CFBagRef bag = CFBagCreate(NULL, bagItems, 6, &kCFTypeBagCallBacks);
    printf("M60-BAGTOTAL-%ld\n", (long)CFBagGetCount(bag)); fflush(stdout);
    printf("M60-BAGA-%ld\n", (long)CFBagGetCountOfValue(bag, a)); fflush(stdout);
    printf("M60-BAGC-%ld\n", (long)CFBagGetCountOfValue(bag, c)); fflush(stdout);

    CFRelease(set); CFRelease(ms); CFRelease(bag);
    CFRelease(alpha); CFRelease(beta); CFRelease(gamma); CFRelease(delta);
    CFRelease(a); CFRelease(b); CFRelease(c);
    printf("M60-DONE\n"); fflush(stdout);
    return 0;
}
