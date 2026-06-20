/*
 * cfdatacli.m — M46: CFData + CFString operations via the CoreFoundation C API.
 * Extends the proven CF C-layer (M44 CFUUID/CFString-create, M45 containers) to data
 * buffers and string ops: build a CFMutableData by appending bytes, read it back, and
 * do CFString find / substring / prefix — all via the pure-C interface with NO ObjC
 * runtime in the path. No networking.
 *
 * PURE-C probe (no #import <Foundation>) per the M44 trick so our extern CF decls
 * don't collide with the real CF headers the Foundation umbrella would pull in. All
 * symbols pre-vetted exported (M22); CoreFoundation linked BY PATH (M17). CFRange is
 * a fixed {CFIndex location, CFIndex length} struct (stable ABI), mirrored here.
 *
 *   - CFMutableData: append "DARWIN" then " COMPUTA" -> length 14, bytes == that text,
 *   - CFStringFind "COMP" in "DARWIN COMPUTA" -> location 7,
 *   - CFStringCreateWithSubstring {7,7} -> "COMPUTA",
 *   - CFStringHasPrefix "DARWIN COMPUTA","DARWIN" -> true.
 *
 *   M46-DATALEN-<n>        CFMutableData length after appends  (== 14)
 *   M46-DATA-OK           the data bytes equal "DARWIN COMPUTA"
 *   M46-FIND-<n>           CFStringFind "COMP" location  (== 7)
 *   M46-SUBSTR-OK         CFStringCreateWithSubstring {7,7} == "COMPUTA"
 *   M46-PREFIX-<n>         CFStringHasPrefix(...,"DARWIN")  (== 1)
 *   M46-DONE
 */
#include <stdio.h>
#include <string.h>

typedef const void* CFTypeRef;
typedef const struct __CFString* CFStringRef;
typedef const struct __CFData* CFDataRef;
typedef struct __CFData* CFMutableDataRef;
typedef const struct __CFAllocator* CFAllocatorRef;
typedef long CFIndex;
typedef unsigned int CFStringEncoding;
typedef unsigned char Boolean;
typedef unsigned long CFStringCompareFlags;
typedef struct { CFIndex location; CFIndex length; } CFRange;   /* mirrors CFRange */
#define kCFStringEncodingUTF8 0x08000100

extern CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char*, CFStringEncoding);
extern CFIndex     CFStringGetLength(CFStringRef);
extern Boolean     CFStringGetCString(CFStringRef, char*, CFIndex, CFStringEncoding);
extern Boolean     CFStringFindWithOptions(CFStringRef, CFStringRef, CFRange, CFStringCompareFlags, CFRange* result);
extern CFStringRef CFStringCreateWithSubstring(CFAllocatorRef, CFStringRef, CFRange);
extern Boolean     CFStringHasPrefix(CFStringRef, CFStringRef);
extern CFMutableDataRef CFDataCreateMutable(CFAllocatorRef, CFIndex capacity);
extern void        CFDataAppendBytes(CFMutableDataRef, const unsigned char*, CFIndex);
extern CFIndex     CFDataGetLength(CFDataRef);
extern const unsigned char* CFDataGetBytePtr(CFDataRef);
extern void        CFRelease(CFTypeRef);

int main(int argc, const char* argv[]) {
    /* ---- CFMutableData append + read --------------------------------------- */
    CFMutableDataRef md = CFDataCreateMutable(NULL, 0);
    CFDataAppendBytes(md, (const unsigned char*)"DARWIN", 6);
    CFDataAppendBytes(md, (const unsigned char*)" COMPUTA", 8);
    CFIndex dl = CFDataGetLength((CFDataRef)md);
    printf("M46-DATALEN-%ld\n", (long)dl); fflush(stdout);
    const unsigned char* bp = CFDataGetBytePtr((CFDataRef)md);
    int dok = (dl == 14) && (memcmp(bp, "DARWIN COMPUTA", 14) == 0);
    printf("M46-DATA-%s\n", dok ? "OK" : "FAIL"); fflush(stdout);

    /* ---- CFString find / substring / prefix ------------------------------- */
    CFStringRef hay = CFStringCreateWithCString(NULL, "DARWIN COMPUTA", kCFStringEncodingUTF8);
    CFStringRef needle = CFStringCreateWithCString(NULL, "COMP", kCFStringEncodingUTF8);
    CFRange whole = { 0, CFStringGetLength(hay) };
    CFRange found = { -1, 0 };
    Boolean has = CFStringFindWithOptions(hay, needle, whole, 0, &found);
    printf("M46-FIND-%ld\n", has ? (long)found.location : -1L); fflush(stdout);

    CFRange sr = { 7, 7 };
    CFStringRef substr = CFStringCreateWithSubstring(NULL, hay, sr);
    char buf[32]; CFStringGetCString(substr, buf, sizeof(buf), kCFStringEncodingUTF8);
    printf("M46-SUBSTR-%s\n", (strcmp(buf, "COMPUTA") == 0) ? "OK" : "FAIL"); fflush(stdout);

    CFStringRef pre = CFStringCreateWithCString(NULL, "DARWIN", kCFStringEncodingUTF8);
    printf("M46-PREFIX-%d\n", CFStringHasPrefix(hay, pre) ? 1 : 0); fflush(stdout);

    CFRelease(md); CFRelease(hay); CFRelease(needle); CFRelease(substr); CFRelease(pre);
    printf("M46-DONE\n"); fflush(stdout);
    return 0;
}
