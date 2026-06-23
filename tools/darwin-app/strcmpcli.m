/*
 * strcmpcli.m — M68: NSString comparison + options-based search. The everyday string
 * ordering/searching operations real code relies on: compare:options: with numeric +
 * case-insensitive ordering, caseInsensitiveCompare:, and rangeOfString:options: with
 * backwards + anchored search. Built purely on the proven Foundation string runtime
 * (M29 processing, M47 formatting); deterministic, host-comparable. No networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation before authoring (M22).
 * NSString is Foundation; CoreFoundation linked BY PATH (M17).
 *
 *   - compare: "apple" vs "banana" -> NSOrderedAscending (-1),
 *   - caseInsensitiveCompare: "Darwin" vs "darwin" -> NSOrderedSame (0),
 *   - NSNumericSearch compare: "file9" vs "file10" -> Ascending (-1) (9 < 10 numerically),
 *   - rangeOfString:"o" options:NSBackwardsSearch in "foo boo" -> last 'o' at index 6,
 *   - rangeOfString:"foo" options:NSAnchoredSearch in "foobar" -> found at 0,
 *   - rangeOfString:"bar" options:NSAnchoredSearch in "foobar" -> NOT found (anchored to start).
 *
 *   M68-CMP-<n>            compare:"apple","banana"  (== -1, Ascending)
 *   M68-CI-<n>            caseInsensitiveCompare:"Darwin","darwin"  (== 0, Same)
 *   M68-NUM-<n>           NSNumericSearch "file9" vs "file10"  (== -1, Ascending)
 *   M68-BACK-<n>          NSBackwardsSearch last "o" in "foo boo"  (index == 6)
 *   M68-ANCHOR-1         NSAnchoredSearch "foo" at start of "foobar"  (found)
 *   M68-ANCHORNO-1       NSAnchoredSearch "bar" NOT at start of "foobar"  (not found)
 *   M68-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

/* NSComparisonResult: Ascending=-1, Same=0, Descending=1
 * NSStringCompareOptions: CaseInsensitive=1, Backwards=4, Anchored=8, Numeric=64 */
enum { M_CASEINS = 1, M_BACKWARDS = 4, M_ANCHORED = 8, M_NUMERIC = 64 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- ordered compare -------------------------------------------- */
        NSComparisonResult c1 = [@"apple" compare:@"banana"];
        printf("M68-CMP-%ld\n", (long)c1); fflush(stdout);

        /* ---- case-insensitive ------------------------------------------- */
        NSComparisonResult c2 = [@"Darwin" caseInsensitiveCompare:@"darwin"];
        printf("M68-CI-%ld\n", (long)c2); fflush(stdout);

        /* ---- numeric ordering (file9 < file10) -------------------------- */
        NSComparisonResult c3 = [@"file9" compare:@"file10" options:M_NUMERIC];
        printf("M68-NUM-%ld\n", (long)c3); fflush(stdout);

        /* ---- backwards search: last 'o' in "foo boo" (index 6) ---------- */
        NSRange rb = [@"foo boo" rangeOfString:@"o" options:M_BACKWARDS];
        printf("M68-BACK-%ld\n", (long)rb.location); fflush(stdout);

        /* ---- anchored search: "foo" at start of "foobar" --------------- */
        NSRange ra = [@"foobar" rangeOfString:@"foo" options:M_ANCHORED];
        printf("M68-ANCHOR-%d\n", (ra.location == 0) ? 1 : 0); fflush(stdout);

        /* ---- anchored search: "bar" NOT at start of "foobar" ----------- */
        NSRange rn = [@"foobar" rangeOfString:@"bar" options:M_ANCHORED];
        printf("M68-ANCHORNO-%d\n", (rn.location == NSNotFound) ? 1 : 0); fflush(stdout);

        printf("M68-DONE\n"); fflush(stdout);
    }
    return 0;
}
