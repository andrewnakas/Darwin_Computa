/*
 * archcli.m — M25: object-graph serialization via NSKeyedArchiver/Unarchiver +
 * binary-plist round trip via NSPropertyListSerialization. A fundamental
 * persistence/IPC capability (archiving an object graph to bytes and restoring it
 * underlies document save/load, pasteboard, defaults, and XPC). Pure Foundation
 * (the proven M3 runtime); no networking.
 *
 * All selectors used here were VERIFIED PRESENT in the staged guest Foundation
 * before authoring (the M22 lesson). The guest predates secure-coding-required
 * archiving, so we use the LEGACY archivedDataWithRootObject: /
 * unarchiveObjectWithData: which ARE present (same vintage call as the M22 percent
 * API). NSPropertyListSerialization is CF-resident, so build-archcli.sh links
 * CoreFoundation BY PATH (the M17 finding).
 *
 * Round trips verified against the originals:
 *   - KEYED ARCHIVE a nested object graph (dict containing a string, number, and an
 *     array) to NSData, then UNARCHIVE it back and confirm deep equality,
 *   - BINARY-PLIST serialize the same graph via NSPropertyListSerialization and
 *     deserialize it back, confirming equality and that the data is non-empty.
 *
 *   M25-ARCH-LEN-<n>       keyed-archive byte length (> 0)
 *   M25-ARCH-OK           unarchive(archive(graph)) deep-equals the original
 *   M25-ARCH-STR-<s>       a string pulled from the unarchived graph (== "Darwin")
 *   M25-ARCH-NUM-<n>       a number pulled from the unarchived graph (== 42)
 *   M25-PLIST-LEN-<n>      binary-plist byte length (> 0)
 *   M25-PLIST-OK          plist round trip deep-equals the original
 *   M25-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

/* NSPropertyListFormat / options (stable ABI values; declared to avoid headers). */
enum { M_NSPropertyListBinaryFormat = 200 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSDictionary* graph = @{
            @"name":  @"Darwin",
            @"answer": @42,
            @"tags":  @[ @"alpha", @"beta", @"gamma" ],
        };

        /* ---- NSKeyedArchiver round trip ----------------------------------- */
        NSData* arch = [NSKeyedArchiver archivedDataWithRootObject:graph];
        printf("M25-ARCH-LEN-%lu\n", (unsigned long)[arch length]); fflush(stdout);

        id restored = [NSKeyedUnarchiver unarchiveObjectWithData:arch];
        BOOL archOK = restored && [restored isEqual:graph];
        printf("M25-ARCH-%s\n", archOK ? "OK" : "FAIL"); fflush(stdout);

        NSString* s = [restored objectForKey:@"name"];
        printf("M25-ARCH-STR-%s\n", s ? [s UTF8String] : "(nil)"); fflush(stdout);
        NSNumber* n = [restored objectForKey:@"answer"];
        printf("M25-ARCH-NUM-%ld\n", n ? (long)[n integerValue] : -1L); fflush(stdout);

        /* ---- NSPropertyListSerialization binary-plist round trip ---------- */
        NSError* err = nil;
        NSData* plist = [NSPropertyListSerialization dataWithPropertyList:graph
                            format:M_NSPropertyListBinaryFormat options:0 error:&err];
        printf("M25-PLIST-LEN-%lu\n", (unsigned long)[plist length]); fflush(stdout);

        id back = plist ? [NSPropertyListSerialization propertyListWithData:plist
                              options:0 format:NULL error:&err] : nil;
        BOOL plistOK = back && [back isEqual:graph];
        printf("M25-PLIST-%s\n", plistOK ? "OK" : "FAIL"); fflush(stdout);

        printf("M25-DONE\n"); fflush(stdout);
    }
    return 0;
}
