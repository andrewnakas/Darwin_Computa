/*
 * datacli.m — M30: binary buffer manipulation via NSData / NSMutableData — slicing,
 * searching, mutable building, in-place patching, and reading bytes out. The layer
 * under every parser/serializer/codec (and the substrate the M20-M22 crypto/base64
 * probes lean on). Pure Foundation (the proven M3 runtime); no networking.
 *
 * All selectors used here were VERIFIED PRESENT in the staged guest Foundation
 * before authoring (the M22 lesson). NSData/NSMutableData are CF-resident, so
 * build-datacli.sh links CoreFoundation BY PATH (the M17 finding).
 *
 *   - BUILD: NSMutableData, appendData: "DARWIN" + appendBytes: " COMPUTA" ->
 *     length 14, bytes == "DARWIN COMPUTA",
 *   - SLICE: subdataWithRange: {7,7} -> "COMPUTA",
 *   - SEARCH: rangeOfData: "COMP" -> location 7,
 *   - PATCH: replaceBytesInRange: {0,6} with "darwin" -> "darwin COMPUTA",
 *   - READ: getBytes:range: pulls 6 bytes back out == "darwin".
 *
 *   M30-LEN-<n>            built buffer length  (== 14)
 *   M30-BUILD-<s>          built bytes as string  (== "DARWIN COMPUTA")
 *   M30-SLICE-<s>          subdataWithRange:{7,7}  (== "COMPUTA")
 *   M30-FIND-<n>           rangeOfData: "COMP" location  (== 7)
 *   M30-PATCH-<s>          after replaceBytesInRange:  (== "darwin COMPUTA")
 *   M30-GET-<s>            getBytes:range:{0,6}  (== "darwin")
 *   M30-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

/* NSDataSearchOptions: 0 == default forward search. */
enum { M_NSDataSearchDefault = 0 };

static NSString* dataAsString(NSData* d) {
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- BUILD via NSMutableData -------------------------------------- */
        NSMutableData* m = [NSMutableData data];
        [m appendData:[@"DARWIN" dataUsingEncoding:NSUTF8StringEncoding]];
        const char* tail = " COMPUTA";
        [m appendBytes:tail length:strlen(tail)];
        printf("M30-LEN-%lu\n", (unsigned long)[m length]); fflush(stdout);
        printf("M30-BUILD-%s\n", [dataAsString(m) UTF8String]); fflush(stdout);

        /* ---- SLICE -------------------------------------------------------- */
        NSData* slice = [m subdataWithRange:NSMakeRange(7, 7)];
        printf("M30-SLICE-%s\n", [dataAsString(slice) UTF8String]); fflush(stdout);

        /* ---- SEARCH ------------------------------------------------------- */
        NSData* needle = [@"COMP" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange found = [m rangeOfData:needle options:M_NSDataSearchDefault
                                 range:NSMakeRange(0, [m length])];
        printf("M30-FIND-%ld\n", (found.location == NSNotFound) ? -1L : (long)found.location);
        fflush(stdout);

        /* ---- PATCH in place ----------------------------------------------- */
        const char* lower = "darwin";   /* same length as "DARWIN" */
        [m replaceBytesInRange:NSMakeRange(0, 6) withBytes:lower];
        printf("M30-PATCH-%s\n", [dataAsString(m) UTF8String]); fflush(stdout);

        /* ---- READ bytes out ----------------------------------------------- */
        char buf[7]; memset(buf, 0, sizeof(buf));
        [m getBytes:buf range:NSMakeRange(0, 6)];
        printf("M30-GET-%s\n", buf); fflush(stdout);

        printf("M30-DONE\n"); fflush(stdout);
    }
    return 0;
}
