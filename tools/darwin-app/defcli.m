/*
 * defcli.m — M65: NSUserDefaults persistent preferences. The standard Cocoa config
 * store — typed key/value preferences persisted to a per-domain plist on disk. Builds
 * on the proven plist serialization tier (M25) + Foundation runtime (M3); the natural
 * "app settings" capability. No networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation before authoring (M22).
 * NSUserDefaults is a Foundation class; CoreFoundation linked BY PATH (M17). NOTE:
 * NSUserDefaults relies on the cfprefsd/plist-on-disk machinery — if that's a stub or
 * non-persisting under emulation the read-backs return nil/0; the probe reports each
 * read so the result is honest either way.
 *
 *   - set a string, an integer, and an array under keys; synchronize,
 *   - read them all back in the SAME process (proves the in-memory store works),
 *   - read the integer via integerForKey: typed accessor,
 *   - removeObjectForKey: one key -> it reads back nil.
 *
 *   M65-STR-<s>            stringForKey:@"name" after set  (== "darwin")
 *   M65-INT-<n>            integerForKey:@"count" after set  (== 42)
 *   M65-ARR-<n>            arrayForKey:@"items" count  (== 3)
 *   M65-SYNC-<d>           synchronize return (1 = ok)
 *   M65-REMOVED-1         after removeObjectForKey:@"name", stringForKey: is nil
 *   M65-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSUserDefaults* d = [NSUserDefaults standardUserDefaults];

        /* ---- set typed values -------------------------------------------- */
        [d setObject:@"darwin" forKey:@"name"];
        [d setInteger:42 forKey:@"count"];
        [d setObject:@[ @"a", @"b", @"c" ] forKey:@"items"];
        BOOL synced = [d synchronize];

        /* ---- read back in-process --------------------------------------- */
        NSString* name = [d stringForKey:@"name"];
        printf("M65-STR-%s\n", name ? [name UTF8String] : "nil"); fflush(stdout);

        long count = (long)[d integerForKey:@"count"];
        printf("M65-INT-%ld\n", count); fflush(stdout);

        NSArray* items = [d arrayForKey:@"items"];
        printf("M65-ARR-%lu\n", (unsigned long)(items ? [items count] : 0)); fflush(stdout);

        printf("M65-SYNC-%d\n", synced ? 1 : 0); fflush(stdout);

        /* ---- remove + confirm gone -------------------------------------- */
        [d removeObjectForKey:@"name"];
        NSString* gone = [d stringForKey:@"name"];
        printf("M65-REMOVED-%d\n", (gone == nil) ? 1 : 0); fflush(stdout);

        printf("M65-DONE\n"); fflush(stdout);
    }
    return 0;
}
