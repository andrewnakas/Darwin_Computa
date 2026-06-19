/*
 * strcli.m — M29: everyday NSString text processing — splitting, trimming, joining,
 * case folding, searching, and substitution. The bread-and-butter of text handling
 * (config parsing, CSV-ish splitting, normalization), complementing M9 (regex) and
 * M23 (NSScanner) with the plain-string-ops layer. Pure Foundation (the proven M3
 * runtime); no networking.
 *
 * All selectors used here were VERIFIED PRESENT in the staged guest Foundation
 * before authoring (the M22 lesson). The character-set ops pull in NSCharacterSet
 * (CF-resident), so build-strcli.sh links CoreFoundation BY PATH (the M17 finding).
 *
 *   - SPLIT "a,b,c,d" on "," -> 4 components, join with "|" -> "a|b|c|d",
 *   - SPLIT on a character set (comma OR semicolon) "a,b;c" -> 3,
 *   - TRIM whitespace/newlines from "  hi \n" -> "hi",
 *   - case: uppercaseString of "Darwin" -> "DARWIN", lowercase -> "darwin",
 *   - SEARCH: rangeOfString:"COMP" in "DARWIN COMPUTA" -> location 7,
 *   - REPLACE: stringByReplacingOccurrencesOfString -> "DARWIN ROCKS",
 *   - hasPrefix/hasSuffix checks.
 *
 *   M29-SPLIT-<n>          components of "a,b,c,d" split on ","  (== 4)
 *   M29-JOIN-<s>           re-joined with "|"  (== "a|b|c|d")
 *   M29-SPLITSET-<n>       split "a,b;c" on [,;]  (== 3)
 *   M29-TRIM-<s>           trimmed "  hi \n"  (== "hi")
 *   M29-UPPER-<s>          uppercaseString  (== "DARWIN")
 *   M29-LOWER-<s>          lowercaseString  (== "darwin")
 *   M29-FIND-<n>           location of "COMP" in "DARWIN COMPUTA"  (== 7)
 *   M29-REPLACE-<s>        replace "COMPUTA"->"ROCKS"  (== "DARWIN ROCKS")
 *   M29-PREFIX-<n>         hasPrefix:"DARWIN"  (== 1)
 *   M29-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- split + join ------------------------------------------------- */
        NSArray* parts = [@"a,b,c,d" componentsSeparatedByString:@","];
        printf("M29-SPLIT-%lu\n", (unsigned long)[parts count]); fflush(stdout);
        printf("M29-JOIN-%s\n", [[parts componentsJoinedByString:@"|"] UTF8String]); fflush(stdout);

        /* ---- split on a character set ------------------------------------- */
        NSCharacterSet* seps = [NSCharacterSet characterSetWithCharactersInString:@",;"];
        NSArray* p2 = [@"a,b;c" componentsSeparatedByCharactersInSet:seps];
        printf("M29-SPLITSET-%lu\n", (unsigned long)[p2 count]); fflush(stdout);

        /* ---- trim --------------------------------------------------------- */
        NSString* trimmed = [@"  hi \n"
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        printf("M29-TRIM-%s\n", [trimmed UTF8String]); fflush(stdout);

        /* ---- case --------------------------------------------------------- */
        printf("M29-UPPER-%s\n", [[@"Darwin" uppercaseString] UTF8String]); fflush(stdout);
        printf("M29-LOWER-%s\n", [[@"Darwin" lowercaseString] UTF8String]); fflush(stdout);

        /* ---- search ------------------------------------------------------- */
        NSString* hay = @"DARWIN COMPUTA";
        NSRange r = [hay rangeOfString:@"COMP"];
        printf("M29-FIND-%ld\n", (r.location == NSNotFound) ? -1L : (long)r.location); fflush(stdout);

        /* ---- replace ------------------------------------------------------ */
        NSString* rep = [hay stringByReplacingOccurrencesOfString:@"COMPUTA" withString:@"ROCKS"];
        printf("M29-REPLACE-%s\n", [rep UTF8String]); fflush(stdout);

        /* ---- prefix/suffix ------------------------------------------------ */
        BOOL pre = [hay hasPrefix:@"DARWIN"] && [hay hasSuffix:@"COMPUTA"];
        printf("M29-PREFIX-%d\n", pre ? 1 : 0); fflush(stdout);

        printf("M29-DONE\n"); fflush(stdout);
    }
    return 0;
}
