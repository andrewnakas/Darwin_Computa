/*
 * recap.m — M42: NSRegularExpression capture groups + template replacement. A DEEPER
 * exercise of the regex engine than M9 (which proved basic matching): extract
 * numbered capture-group substrings from a match, count multiple matches across a
 * string, and perform $1-style template (backreference) replacement. Pure Foundation
 * (the proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSRegularExpression is a Foundation class; we still link
 * CoreFoundation BY PATH (M17) since NSString/ranges touch CF.
 *
 *   - pattern (\w+)=(\d+) against "qty=42" -> capture 1 == "qty", capture 2 == "42",
 *   - count matches of \d+ in "a1 b22 c333" -> 3,
 *   - template replace: pattern (\w+)=(\d+) on "qty=42" with template "$2:$1"
 *     -> "42:qty" (numbered backreferences),
 *   - a global template replace on "x=1 y=2" -> "1=x 2=y".
 *
 *   M42-CAP1-<s>           first capture group  (== "qty")
 *   M42-CAP2-<s>           second capture group  (== "42")
 *   M42-NRANGES-<n>        numberOfRanges of the match  (== 3: whole + 2 groups)
 *   M42-COUNT-<n>          number of \d+ matches in "a1 b22 c333"  (== 3)
 *   M42-TEMPLATE-<s>       "$2:$1" replace on "qty=42"  (== "42:qty")
 *   M42-GLOBAL-<s>         global swap on "x=1 y=2"  (== "1=x 2=y")
 *   M42-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

static NSString* sub(NSString* s, NSRange r) {
    return (r.location == NSNotFound) ? @"(none)" : [s substringWithRange:r];
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSError* err = nil;

        /* ---- capture groups ----------------------------------------------- */
        NSRegularExpression* kv =
            [NSRegularExpression regularExpressionWithPattern:@"(\\w+)=(\\d+)"
                                                      options:0 error:&err];
        NSString* s = @"qty=42";
        NSTextCheckingResult* m =
            [kv firstMatchInString:s options:0 range:NSMakeRange(0, [s length])];
        printf("M42-CAP1-%s\n", [sub(s, [m rangeAtIndex:1]) UTF8String]); fflush(stdout);
        printf("M42-CAP2-%s\n", [sub(s, [m rangeAtIndex:2]) UTF8String]); fflush(stdout);
        printf("M42-NRANGES-%lu\n", (unsigned long)[m numberOfRanges]); fflush(stdout);

        /* ---- count matches ------------------------------------------------ */
        NSRegularExpression* num =
            [NSRegularExpression regularExpressionWithPattern:@"\\d+" options:0 error:&err];
        NSString* t = @"a1 b22 c333";
        NSUInteger n = [num numberOfMatchesInString:t options:0 range:NSMakeRange(0, [t length])];
        printf("M42-COUNT-%lu\n", (unsigned long)n); fflush(stdout);

        /* ---- template replacement (numbered backrefs) --------------------- */
        NSString* swapped =
            [kv stringByReplacingMatchesInString:s options:0
                                           range:NSMakeRange(0, [s length])
                                    withTemplate:@"$2:$1"];
        printf("M42-TEMPLATE-%s\n", [swapped UTF8String]); fflush(stdout);

        /* ---- global template replace -------------------------------------- */
        NSString* g = @"x=1 y=2";
        NSString* gout =
            [kv stringByReplacingMatchesInString:g options:0
                                           range:NSMakeRange(0, [g length])
                                    withTemplate:@"$2=$1"];
        printf("M42-GLOBAL-%s\n", [gout UTF8String]); fflush(stdout);

        printf("M42-DONE\n"); fflush(stdout);
    }
    return 0;
}
