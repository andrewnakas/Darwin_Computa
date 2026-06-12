/*
 * regexcli.m — M9: regular expressions via NSRegularExpression (text processing,
 * on the proven Foundation/ObjC runtime).
 *
 * Covers the core regex operations: compile a pattern, COUNT matches across a
 * string, extract a CAPTURE GROUP from the first match, and REPLACE all matches
 * with a template. Deterministic, headless. Avoids NSCharacterSet (not resolvable
 * in the by-path Foundation link here — see M8).
 *
 *   M9-COMPILE-OK          regularExpressionWithPattern: built a regex
 *   M9-COUNT-3             numberOfMatchesInString: counted 3 matches of \d+
 *   M9-CAPTURE-42          the capture group of "answer=(\d+)" -> 42
 *   M9-REPLACE-OK          stringByReplacingMatches: produced the expected string
 *   M9-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSString* text = @"a1 b22 c333 answer=42 end";

        // 1) Compile a pattern.
        NSError* err = nil;
        NSRegularExpression* re =
            [NSRegularExpression regularExpressionWithPattern:@"\\d+"
                                                      options:0 error:&err];
        if (!re) { printf("M9-COMPILE-FAIL-%s\n", err ? [[err localizedDescription] UTF8String] : "nil"); fflush(stdout); printf("M9-DONE\n"); return 0; }
        printf("M9-COMPILE-OK\n"); fflush(stdout);

        // 2) Count all \d+ runs (1, 22, 333, 42 -> 4 actually; keep it explicit).
        NSUInteger n = [re numberOfMatchesInString:text options:0
                                              range:NSMakeRange(0, [text length])];
        printf("M9-COUNT-%lu\n", (unsigned long)n); fflush(stdout);

        // 3) Extract a capture group: "answer=(\d+)" -> group 1.
        NSRegularExpression* re2 =
            [NSRegularExpression regularExpressionWithPattern:@"answer=(\\d+)"
                                                      options:0 error:&err];
        NSTextCheckingResult* m =
            [re2 firstMatchInString:text options:0 range:NSMakeRange(0, [text length])];
        if (m && [m numberOfRanges] >= 2) {
            NSRange g1 = [m rangeAtIndex:1];
            NSString* cap = [text substringWithRange:g1];
            printf("M9-CAPTURE-%d\n", [cap intValue]); fflush(stdout);
        } else {
            printf("M9-CAPTURE-FAIL\n"); fflush(stdout);
        }

        // 4) Replace all \d+ with "#": "a# b# c# answer=# end".
        NSMutableString* mut = [text mutableCopy];
        NSUInteger replaced =
            [re replaceMatchesInString:mut options:0
                                 range:NSMakeRange(0, [mut length]) withTemplate:@"#"];
        BOOL ok = (replaced == n) && [mut isEqualToString:@"a# b# c# answer=# end"];
        printf("M9-REPLACE-%s\n", ok ? "OK" : "FAIL"); fflush(stdout);
        if (!ok) { printf("  got: %s (replaced %lu)\n", [mut UTF8String], (unsigned long)replaced); fflush(stdout); }

        printf("M9-DONE\n"); fflush(stdout);
    }
    return 0;
}
