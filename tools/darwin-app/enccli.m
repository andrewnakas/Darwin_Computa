/*
 * enccli.m — M38: text encoding conversion + encoded file I/O via NSString. Exercises
 * the encoding-conversion machinery (UTF-8 / UTF-16 / ASCII) and reading/writing text
 * files with an explicit encoding — distinct from M22 (base64/percent) and M29 (plain
 * string ops). Pure Foundation (the proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSString is CF-resident, so build-enccli.sh links
 * CoreFoundation BY PATH (the M17 finding). Avoids the M16 removeItemAtPath gap.
 *
 * Uses a string with a multi-byte char ("Darwin café") to make the encodings differ:
 *   - UTF-8 byte length (café's é is 2 bytes -> 12 for "Darwin café"),
 *   - UTF-16 byte length (11 code units * 2 == 22),
 *   - round-trip the UTF-8 bytes back to an equal NSString,
 *   - canBeConvertedToEncoding: ASCII == NO (the é can't be ASCII),
 *   - write the string to a file as UTF-8 and read it back with the UTF-8 reader,
 *     confirming equality.
 *
 *   M38-UTF8LEN-<n>        lengthOfBytesUsingEncoding:UTF8  (== 12)
 *   M38-UTF16LEN-<n>       lengthOfBytesUsingEncoding:UTF16 code-unit bytes (== 22)
 *   M38-ROUNDTRIP-OK       NSString -> UTF8 NSData -> NSString equals the original
 *   M38-ASCII-<0|1>        canBeConvertedToEncoding:ASCII (== 0, the é blocks it)
 *   M38-FILE-OK            writeToFile:encoding:UTF8 then stringWithContentsOfFile == original
 *   M38-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

/* NSStringEncoding values (stable ABI). */
enum {
    M_NSASCIIStringEncoding   = 1,
    M_NSUTF8StringEncoding    = 4,
    M_NSUTF16StringEncoding   = 10,
};

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSString* s = @"Darwin café";   /* 11 chars; é is multi-byte in UTF-8 */

        NSUInteger u8 = [s lengthOfBytesUsingEncoding:M_NSUTF8StringEncoding];
        printf("M38-UTF8LEN-%lu\n", (unsigned long)u8); fflush(stdout);

        NSUInteger u16 = [s lengthOfBytesUsingEncoding:M_NSUTF16StringEncoding];
        printf("M38-UTF16LEN-%lu\n", (unsigned long)u16); fflush(stdout);

        /* round-trip via UTF-8 NSData */
        NSData* d = [s dataUsingEncoding:M_NSUTF8StringEncoding];
        NSString* back = [[NSString alloc] initWithData:d encoding:M_NSUTF8StringEncoding];
        printf("M38-ROUNDTRIP-%s\n", (back && [back isEqualToString:s]) ? "OK" : "FAIL"); fflush(stdout);

        /* the é cannot be represented in ASCII */
        BOOL ascii = [s canBeConvertedToEncoding:M_NSASCIIStringEncoding];
        printf("M38-ASCII-%d\n", ascii ? 1 : 0); fflush(stdout);

        /* write as UTF-8, read back with the UTF-8 reader */
        NSString* path = @"/var/root/m38.txt";
        NSError* err = nil;
        BOOL wrote = [s writeToFile:path atomically:NO
                          encoding:M_NSUTF8StringEncoding error:&err];
        NSString* readback = wrote
            ? [NSString stringWithContentsOfFile:path encoding:M_NSUTF8StringEncoding error:&err]
            : nil;
        printf("M38-FILE-%s\n", (readback && [readback isEqualToString:s]) ? "OK" : "FAIL"); fflush(stdout);

        printf("M38-DONE\n"); fflush(stdout);
    }
    return 0;
}
