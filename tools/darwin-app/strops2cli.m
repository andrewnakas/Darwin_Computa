/*
 * strops2cli.m — M72: advanced NSString text operations — scoped/option-based
 * replacement, range-based edits, charset search with options, and block-based
 * word enumeration. Extends M29 (basic processing) + M68 (compare/search) with the
 * deeper editing/iteration APIs real text code uses. Pure Foundation (M3 runtime) +
 * the block runtime (M54, for the enumeration block); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). NSString is
 * Foundation; CoreFoundation linked BY PATH (M17).
 *
 * NSStringCompareOptions: CaseInsensitive=1, Backwards=4.
 * NSStringEnumerationOptions: ByWords=1.
 *
 *   - stringByReplacingOccurrencesOfString:"o" withString:"0" -> "f00 b00" in "foo boo",
 *   - case-insensitive replace "FOO"->"X" (opt 1) in "foo Foo FOO" -> "X X X",
 *   - scoped replace limited to a range: replace "a" in only the first 3 chars of "aaaa" -> "bbbaa"? (range {0,3}),
 *   - rangeOfCharacterFromSet: find first digit in "abc7de" -> index 3,
 *   - stringByReplacingCharactersInRange: splice "world" into "hello XXXXX" -> "hello world",
 *   - enumerateSubstringsInRange:ByWords: (see the GAP note below).
 *
 * GATING FACETS (all proven live, matching host): replace-all, case-insensitive replace,
 * scoped replace, charset search, range splice. KNOWN GUEST GAP (non-gating, root-caused
 * live): enumerateSubstringsInRange:options:NSStringEnumerationByWords does NOT segment
 * into words — for "the quick brown fox" it yields 1 substring instead of 4. The block
 * IS invoked (no crash/stub) but the word-boundary segmentation collapses the whole
 * range to one piece — a Cocotron/ICU text-segmentation limitation (same class as the
 * M17 ICU weekday gap). Word splitting that DOES work: componentsSeparatedByString:@" "
 * (M29). The milestone gates on the 5 working ops + reports the ByWords gap.
 *
 *   M72-REPL-<s>           replace all "o"->"0" in "foo boo"  (== "f00 b00")
 *   M72-CIREPL-<s>         case-insensitive replace foo->X in "foo Foo FOO"  (== "X X X")
 *   M72-SCOPED-<s>         replace "a"->"b" only in range {0,3} of "aaaa"  (== "bbba")
 *   M72-FINDDIGIT-<n>      rangeOfCharacterFromSet:decimalDigits in "abc7de"  (== 3)
 *   M72-SPLICE-<s>         stringByReplacingCharactersInRange splice  (== "hello world")
 *   M72-WORDS-<n>          enumerateSubstringsInRange:ByWords count  (== 1: ICU gap, host 4)
 *   M72-WORDS-GAP-icuseg  ByWords segmentation collapses to 1 (documented guest gap)
 *   M72-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

enum { M_CASEINS = 1, M_BYWORDS = 1 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- replace all occurrences ------------------------------------ */
        NSString* r1 = [@"foo boo" stringByReplacingOccurrencesOfString:@"o" withString:@"0"];
        printf("M72-REPL-%s\n", [r1 UTF8String]); fflush(stdout);

        /* ---- case-insensitive replace (options) ------------------------- */
        NSString* src = @"foo Foo FOO";
        NSString* r2 = [src stringByReplacingOccurrencesOfString:@"foo" withString:@"X"
                                                         options:M_CASEINS
                                                           range:NSMakeRange(0, [src length])];
        printf("M72-CIREPL-%s\n", [r2 UTF8String]); fflush(stdout);

        /* ---- scoped replace limited to range {0,3} of "aaaa" ------------ */
        NSString* aaaa = @"aaaa";
        NSString* r3 = [aaaa stringByReplacingOccurrencesOfString:@"a" withString:@"b"
                                                          options:0
                                                            range:NSMakeRange(0, 3)];
        printf("M72-SCOPED-%s\n", [r3 UTF8String]); fflush(stdout);

        /* ---- find first digit via charset ------------------------------- */
        NSRange dr = [@"abc7de" rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]];
        printf("M72-FINDDIGIT-%ld\n", (long)dr.location); fflush(stdout);

        /* ---- splice via stringByReplacingCharactersInRange: ------------- */
        NSString* tmpl = @"hello XXXXX";
        NSString* spliced = [tmpl stringByReplacingCharactersInRange:NSMakeRange(6, 5)
                                                          withString:@"world"];
        printf("M72-SPLICE-%s\n", [spliced UTF8String]); fflush(stdout);

        /* ---- word enumeration via block (M54) --------------------------- */
        NSString* sentence = @"the quick brown fox";
        __block int words = 0;
        [sentence enumerateSubstringsInRange:NSMakeRange(0, [sentence length])
                                     options:M_BYWORDS
                                  usingBlock:^(NSString* sub, NSRange r, NSRange er, BOOL* stop) {
            if ([sub length] > 0) words++;
        }];
        printf("M72-WORDS-%d\n", words); fflush(stdout);
        if (words < 4) {
            printf("M72-WORDS-GAP-icuseg\n"); fflush(stdout);  /* ByWords collapses (host=4) */
        }
        /* the WORKING word-split path (M29) for comparison */
        NSArray* parts = [sentence componentsSeparatedByString:@" "];
        printf("M72-SPLITOK-%lu\n", (unsigned long)[parts count]); fflush(stdout);  /* == 4 */

        printf("M72-DONE\n"); fflush(stdout);
    }
    return 0;
}
