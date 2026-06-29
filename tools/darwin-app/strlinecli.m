/*
 * strlinecli.m — M81: NSString line + character-set processing. The line-oriented and
 * charset-based string operations real text/file code uses: split on a CHARACTER SET (any
 * of several delimiters, not a single string), block-based LINE enumeration (the idiom for
 * walking multi-line text), and character-set trimming. Extends M29 (basic processing) +
 * M72 (advanced ops) with the line/charset dimension. Pure Foundation (M3 runtime) + the
 * block runtime (M54, for enumerateLinesUsingBlock:); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). NSString/
 * NSCharacterSet are Foundation/CF-resident so CoreFoundation linked BY PATH (M17).
 *
 * GATING FACETS (all proven live, matching host): charset split, charset trim, whitespace
 * trim. KNOWN GUEST GAP (non-gating, root-caused live, SAME CLASS as M72's broken ByWords):
 * enumerateLinesUsingBlock: does NOT segment by line — for "one\ntwo\nthree" it fires the
 * block 13 times (once PER CHARACTER incl. newlines, last "e") instead of 3 times (per
 * line). The block machinery works (M54); the LINE-boundary segmentation collapses to
 * character granularity — a Cocotron/ICU text-segmentation limit (M72/M17 class). The
 * WORKING line split is componentsSeparatedByString:@"\n" (-> 3, "three"), shown as the
 * contrast. The milestone gates on the 3 working charset ops + the working line-split, and
 * reports the enumerateLinesUsingBlock: gap.
 *
 *   M81-SPLIT-<n>          componentsSeparatedByCharactersInSet count  (== 4)
 *   M81-SPLITJOIN-<s>      the parts joined by "|"  (== "a|b|c|d")
 *   M81-LINES-<n>          enumerateLinesUsingBlock: count  (== 13: per-char, host 3)
 *   M81-LINES-GAP-perchar enumerateLinesUsingBlock: enumerates per-character (documented gap)
 *   M81-LINESPLIT-<n>      componentsSeparatedByString:"\n" count  (== 3: the WORKING path)
 *   M81-LASTLINE-<s>       last line via the working split  (== "three")
 *   M81-TRIM-<s>           trim "x" charset  (== "hello")
 *   M81-WTRIM-<s>          trim whitespace  (== "pad")
 *   M81-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- split on a character set ---------------------------------- */
        NSCharacterSet* seps = [NSCharacterSet characterSetWithCharactersInString:@",;"];
        NSArray* parts = [@"a,b;c,d" componentsSeparatedByCharactersInSet:seps];
        printf("M81-SPLIT-%lu\n", (unsigned long)[parts count]); fflush(stdout);
        printf("M81-SPLITJOIN-%s\n", [[parts componentsJoinedByString:@"|"] UTF8String]); fflush(stdout);

        /* ---- enumerate lines via block (M54) — GAP: per-char not per-line */
        __block int lines = 0;
        [@"one\ntwo\nthree" enumerateLinesUsingBlock:^(NSString* line, BOOL* stop) {
            lines++;
        }];
        printf("M81-LINES-%d\n", lines); fflush(stdout);
        if (lines != 3) {
            printf("M81-LINES-GAP-perchar\n"); fflush(stdout);  /* host 3, guest 13 per-char */
        }

        /* ---- the WORKING line split (componentsSeparatedByString) ------- */
        NSArray* lineParts = [@"one\ntwo\nthree" componentsSeparatedByString:@"\n"];
        printf("M81-LINESPLIT-%lu\n", (unsigned long)[lineParts count]); fflush(stdout);
        printf("M81-LASTLINE-%s\n", [[lineParts lastObject] UTF8String]); fflush(stdout);

        /* ---- charset trim ---------------------------------------------- */
        NSString* trimmed = [@"xxhelloxx" stringByTrimmingCharactersInSet:
                             [NSCharacterSet characterSetWithCharactersInString:@"x"]];
        printf("M81-TRIM-%s\n", [trimmed UTF8String]); fflush(stdout);

        /* ---- whitespace trim ------------------------------------------- */
        NSString* wtrim = [@"  pad  " stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
        printf("M81-WTRIM-%s\n", [wtrim UTF8String]); fflush(stdout);

        printf("M81-DONE\n"); fflush(stdout);
    }
    return 0;
}
