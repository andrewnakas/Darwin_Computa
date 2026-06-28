/*
 * arrcli.m — M76: NSArray higher-order operations. The everyday immutable-array
 * transformation toolkit real Cocoa code leans on: selector-based sort, predicate
 * filtering, slicing, KVC projection, and joining. Extends the collections tier
 * (M24 predicate/sort, M34 sets, M54 block-sort, M69 descriptor-sort) with the
 * NSArray-native transforms. Pure Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). A few modern
 * mutable-array selectors (sortUsingComparator:/removeObjectsInArray:/exchange...) are
 * ABSENT in this Cocotron vintage and are deliberately AVOIDED. CF linked BY PATH (M17).
 *
 *   - sortedArrayUsingSelector:@selector(compare:) on [3,1,2] -> [1,2,3],
 *   - filteredArrayUsingPredicate: SELF>1 on [1,2,3] -> [2,3] (count 2),
 *   - subarrayWithRange:{1,2} on [a,b,c,d] -> [b,c],
 *   - componentsJoinedByString:@"-" on [a,b,c] -> "a-b-c",
 *   - valueForKey:@"uppercaseString" on [a,b] -> [A,B] (KVC projection),
 *   - objectsAtIndexes: {0,2} on [a,b,c] -> [a,c].
 *
 *   M76-SORT-<csv>         sortedArrayUsingSelector:compare:  (== "1,2,3")
 *   M76-FILTER-<n>         filteredArrayUsingPredicate: SELF>1 count  (== 2)
 *   M76-SLICE-<csv>        subarrayWithRange:{1,2}  (== "b,c")
 *   M76-JOIN-<s>           componentsJoinedByString:"-"  (== "a-b-c")
 *   M76-KVC-<csv>          valueForKey:uppercaseString  (== "A,B")
 *   M76-PICK-<csv>         objectsAtIndexes:{0,2}  (== "a,c")
 *   M76-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

static const char* csvNum(NSArray* a) {
    NSMutableArray* s = [NSMutableArray array];
    for (NSNumber* n in a) [s addObject:[n stringValue]];
    return [[s componentsJoinedByString:@","] UTF8String];
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- selector-based sort --------------------------------------- */
        NSArray* nums = [NSArray arrayWithObjects:@3, @1, @2, nil];
        NSArray* sorted = [nums sortedArrayUsingSelector:@selector(compare:)];
        printf("M76-SORT-%s\n", csvNum(sorted)); fflush(stdout);

        /* ---- predicate filter ------------------------------------------ */
        NSPredicate* gt1 = [NSPredicate predicateWithFormat:@"SELF > 1"];
        NSArray* filtered = [nums filteredArrayUsingPredicate:gt1];
        printf("M76-FILTER-%lu\n", (unsigned long)[filtered count]); fflush(stdout);

        /* ---- slice ----------------------------------------------------- */
        NSArray* letters = [NSArray arrayWithObjects:@"a", @"b", @"c", @"d", nil];
        NSArray* slice = [letters subarrayWithRange:NSMakeRange(1, 2)];
        printf("M76-SLICE-%s\n", [[slice componentsJoinedByString:@","] UTF8String]); fflush(stdout);

        /* ---- join ------------------------------------------------------ */
        NSArray* abc = [NSArray arrayWithObjects:@"a", @"b", @"c", nil];
        printf("M76-JOIN-%s\n", [[abc componentsJoinedByString:@"-"] UTF8String]); fflush(stdout);

        /* ---- KVC projection (valueForKey: maps over elements) ---------- */
        NSArray* ab = [NSArray arrayWithObjects:@"a", @"b", nil];
        NSArray* upper = [ab valueForKey:@"uppercaseString"];
        printf("M76-KVC-%s\n", [[upper componentsJoinedByString:@","] UTF8String]); fflush(stdout);

        /* ---- objectsAtIndexes: ----------------------------------------- */
        NSMutableIndexSet* idx = [NSMutableIndexSet indexSet];
        [idx addIndex:0]; [idx addIndex:2];
        NSArray* picked = [abc objectsAtIndexes:idx];
        printf("M76-PICK-%s\n", [[picked componentsJoinedByString:@","] UTF8String]); fflush(stdout);

        printf("M76-DONE\n"); fflush(stdout);
    }
    return 0;
}
