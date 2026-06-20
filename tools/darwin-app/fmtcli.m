/*
 * fmtcli.m — M47: NSString formatting + NSMutableString building. The string-
 * construction layer used everywhere (printf-style formatting + in-place mutation),
 * distinct from M29 (split/search/case) and M38 (encodings). Pure Foundation (the
 * proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSString/NSMutableString are CF-resident, so
 * build-fmtcli.sh links CoreFoundation BY PATH (the M17 finding).
 *
 *   - stringWithFormat: with mixed specifiers (%@, %d, %.2f, %x) ->
 *     "Darwin #42 = 19.99 [2a]",
 *   - NSMutableString: appendString:"DARWIN" + appendFormat:" v%d" -> "DARWIN v2",
 *   - insertString:"<<" atIndex:0 -> "<<DARWIN v2",
 *   - replaceCharactersInRange:{0,2} withString:">>" -> ">>DARWIN v2",
 *   - stringByPaddingToLength:8 -> "Darwin.." (pad with ".").
 *
 *   M47-FMT-<s>            stringWithFormat: result  (== "Darwin #42 = 19.99 [2a]")
 *   M47-APPEND-<s>         mutable append + appendFormat:  (== "DARWIN v2")
 *   M47-INSERT-<s>         insertString:atIndex:0  (== "<<DARWIN v2")
 *   M47-REPLACE-<s>        replaceCharactersInRange:  (== ">>DARWIN v2")
 *   M47-PAD-<s>            stringByPaddingToLength:8 with "."  (== "Darwin..")
 *   M47-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- stringWithFormat: mixed specifiers ---------------------------- */
        NSString* name = @"Darwin";
        NSString* fmt = [NSString stringWithFormat:@"%@ #%d = %.2f [%x]", name, 42, 19.99, 42];
        printf("M47-FMT-%s\n", [fmt UTF8String]); fflush(stdout);

        /* ---- NSMutableString append + appendFormat: ----------------------- */
        NSMutableString* m = [NSMutableString string];
        [m appendString:@"DARWIN"];
        [m appendFormat:@" v%d", 2];
        printf("M47-APPEND-%s\n", [m UTF8String]); fflush(stdout);

        /* ---- insertString:atIndex: ---------------------------------------- */
        [m insertString:@"<<" atIndex:0];
        printf("M47-INSERT-%s\n", [m UTF8String]); fflush(stdout);

        /* ---- replaceCharactersInRange:withString: ------------------------- */
        [m replaceCharactersInRange:NSMakeRange(0, 2) withString:@">>"];
        printf("M47-REPLACE-%s\n", [m UTF8String]); fflush(stdout);

        /* ---- stringByPaddingToLength: ------------------------------------- */
        NSString* pad = [name stringByPaddingToLength:8 withString:@"." startingAtIndex:0];
        printf("M47-PAD-%s\n", [pad UTF8String]); fflush(stdout);

        printf("M47-DONE\n"); fflush(stdout);
    }
    return 0;
}
