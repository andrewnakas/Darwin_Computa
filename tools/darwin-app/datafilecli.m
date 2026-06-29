/*
 * datafilecli.m — M79: NSData filesystem persistence + byte search. The NSData
 * convenience layer that real code uses to persist/load binary blobs and locate byte
 * patterns: writeToFile:atomically: -> dataWithContentsOfFile: round trip (byte-identical),
 * rangeOfData:options:range: forward + backward search, and subdataWithRange: slicing.
 * Ties together M16 (filesystem), M30 (NSData buffers), M37 (file I/O) at the NSData
 * convenience-API level. Pure Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). NSData is
 * Foundation; CoreFoundation linked BY PATH (M17). Scratch file under /tmp (guest-writable
 * per M16/M65). Atomic write exercises the temp-file + rename path on the substrate FS.
 *
 *   - build 16 bytes "DARWIN-COMPUTA!\n", writeToFile:atomically:YES, read back ==,
 *   - rangeOfData: "-" forward -> location 6 (DARWIN-),
 *   - rangeOfData: "A" backwards -> last 'A' (in COMPUTA),
 *   - subdataWithRange:{7,7} -> "COMPUTA".
 *
 *   M79-WROTE-<n>          bytes written to disk  (== 16)
 *   M79-READBACK-<n>       bytes read back via dataWithContentsOfFile:  (== 16)
 *   M79-ROUNDTRIP-OK       read-back data isEqualToData: the original (byte-identical)
 *   M79-FINDFWD-<n>        rangeOfData:"-" forward location  (== 6)
 *   M79-FINDBACK-<n>       rangeOfData:"A" backwards location (last 'A')
 *   M79-SLICE-<s>          subdataWithRange:{7,7} as text  (== "COMPUTA")
 *   M79-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

/* NSDataSearchBackwards = 1 << 0 within the search-options mask used by rangeOfData: */
enum { M_BACKWARDS = 1 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        const char* raw = "DARWIN-COMPUTA!\n";   /* 16 bytes */
        NSData* orig = [NSData dataWithBytes:raw length:strlen(raw)];
        NSString* path = @"/tmp/m79_blob.bin";

        /* ---- persist + reload ------------------------------------------ */
        BOOL wrote = [orig writeToFile:path atomically:YES];
        printf("M79-WROTE-%lu\n", wrote ? (unsigned long)[orig length] : 0UL); fflush(stdout);

        NSData* back = [NSData dataWithContentsOfFile:path];
        printf("M79-READBACK-%lu\n", (unsigned long)[back length]); fflush(stdout);
        printf("M79-ROUNDTRIP-%s\n", [back isEqualToData:orig] ? "OK" : "FAIL"); fflush(stdout);

        /* ---- forward byte search --------------------------------------- */
        NSData* dash = [NSData dataWithBytes:"-" length:1];
        NSRange fwd = [back rangeOfData:dash options:0 range:NSMakeRange(0, [back length])];
        printf("M79-FINDFWD-%ld\n", (long)fwd.location); fflush(stdout);

        /* ---- backward byte search -------------------------------------- */
        NSData* aData = [NSData dataWithBytes:"A" length:1];
        NSRange bwd = [back rangeOfData:aData options:M_BACKWARDS range:NSMakeRange(0, [back length])];
        printf("M79-FINDBACK-%ld\n", (long)bwd.location); fflush(stdout);

        /* ---- slice ----------------------------------------------------- */
        NSData* slice = [back subdataWithRange:NSMakeRange(7, 7)];   /* "COMPUTA" */
        NSString* sliceStr = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
        printf("M79-SLICE-%s\n", [sliceStr UTF8String]); fflush(stdout);

        printf("M79-DONE\n"); fflush(stdout);
    }
    return 0;
}
