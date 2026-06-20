/*
 * idxcli.m — M48: NSIndexSet / NSMutableIndexSet index-set operations. A real
 * Foundation collection (the model behind table/list row selection): build index sets
 * from ranges, add indices, test membership, count, and iterate in order. Distinct
 * from M34's NSSet/NSOrderedSet (object sets) — this is an integer-index set with
 * range semantics. Pure Foundation (the proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSIndexSet is a Foundation class; we still link
 * CoreFoundation BY PATH (M17) since it touches CF.
 *
 *   - indexSetWithIndexesInRange:{2,3} -> {2,3,4}: count 3, contains 3, !contains 5,
 *   - mutable: addIndexesInRange:{2,3} then addIndex:10 -> count 4, first 2, last 10,
 *   - ordered iteration via firstIndex/indexGreaterThanIndex: -> "2,3,4,10".
 *
 *   M48-COUNT-<n>          count of indexSetWithIndexesInRange:{2,3}  (== 3)
 *   M48-HAS3-<n>           contains index 3  (== 1)
 *   M48-HAS5-<n>           contains index 5  (== 0)
 *   M48-MUTCOUNT-<n>       mutable set count after adds  (== 4)
 *   M48-FIRST-<n>          firstIndex  (== 2)
 *   M48-LAST-<n>           lastIndex   (== 10)
 *   M48-ITER-<s>           ordered iteration  (== "2,3,4,10")
 *   M48-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- immutable range index set ------------------------------------ */
        NSIndexSet* s = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 3)]; /* {2,3,4} */
        printf("M48-COUNT-%lu\n", (unsigned long)[s count]); fflush(stdout);
        printf("M48-HAS3-%d\n", [s containsIndex:3] ? 1 : 0); fflush(stdout);
        printf("M48-HAS5-%d\n", [s containsIndex:5] ? 1 : 0); fflush(stdout);

        /* ---- mutable: add a range + a single index ------------------------ */
        NSMutableIndexSet* m = [NSMutableIndexSet indexSet];
        [m addIndexesInRange:NSMakeRange(2, 3)];   /* {2,3,4} */
        [m addIndex:10];                            /* {2,3,4,10} */
        printf("M48-MUTCOUNT-%lu\n", (unsigned long)[m count]); fflush(stdout);
        printf("M48-FIRST-%lu\n", (unsigned long)[m firstIndex]); fflush(stdout);
        printf("M48-LAST-%lu\n", (unsigned long)[m lastIndex]); fflush(stdout);

        /* ---- ordered iteration via firstIndex / indexGreaterThanIndex: ---- */
        NSMutableString* it = [NSMutableString string];
        NSUInteger i = [m firstIndex];
        while (i != NSNotFound) {
            if ([it length]) [it appendString:@","];
            [it appendFormat:@"%lu", (unsigned long)i];
            i = [m indexGreaterThanIndex:i];
        }
        printf("M48-ITER-%s\n", [it UTF8String]); fflush(stdout);

        printf("M48-DONE\n"); fflush(stdout);
    }
    return 0;
}
