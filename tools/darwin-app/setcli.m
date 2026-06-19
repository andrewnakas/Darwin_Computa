/*
 * setcli.m — M34: set algebra via NSSet/NSMutableSet + ordered-unique collections
 * via NSOrderedSet. Fundamental collection capabilities (membership, dedup, union/
 * intersect/difference, subset tests, and order-preserving uniqueness) that round
 * out the collections tier alongside M24 (predicate/sort) and M26 (counted set).
 * Pure Foundation (the proven M3 runtime); no networking.
 *
 * All selectors used here were VERIFIED PRESENT in the staged guest Foundation
 * before authoring (the M22 lesson). NSSet/NSOrderedSet are CF-resident, so
 * build-setcli.sh links CoreFoundation BY PATH (the M17 finding).
 *
 *   - MEMBERSHIP: set {a,b,c} contains "b", not "z",
 *   - DEDUP: setWithArray:[a,b,a,c,b] -> count 3,
 *   - UNION: {a,b,c} U {c,d} -> 4 unique,
 *   - INTERSECT: {a,b,c} ∩ {b,c,d} -> {b,c} (2),
 *   - MINUS: {a,b,c} - {b} -> {a,c} (2),
 *   - SUBSET: {a,b} ⊆ {a,b,c} == YES,
 *   - ORDERED: orderedSetWithArray:[c,a,b,a] -> count 3, index of "a" == 1,
 *     object at 0 == "c" (insertion order preserved, dups dropped).
 *
 *   M34-HAS-<n>            membership: contains b(1) and not z -> 1 if correct
 *   M34-DEDUP-<n>          setWithArray dedup count  (== 3)
 *   M34-UNION-<n>          union count  (== 4)
 *   M34-INTERSECT-<n>      intersection count  (== 2)
 *   M34-MINUS-<n>          difference count  (== 2)
 *   M34-SUBSET-<n>         isSubsetOfSet: -> 1
 *   M34-ORDERED-CNT-<n>    NSOrderedSet count after dedup  (== 3)
 *   M34-ORDERED-IDX-<n>    index of "a" in ordered set  (== 1)
 *   M34-ORDERED-FIRST-<s>  object at index 0  (== "c")
 *   M34-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSSet* abc = [NSSet setWithArray:@[@"a", @"b", @"c"]];

        /* membership */
        int has = ([abc containsObject:@"b"] && ![abc containsObject:@"z"]) ? 1 : 0;
        printf("M34-HAS-%d\n", has); fflush(stdout);

        /* dedup */
        NSSet* dd = [NSSet setWithArray:@[@"a", @"b", @"a", @"c", @"b"]];
        printf("M34-DEDUP-%lu\n", (unsigned long)[dd count]); fflush(stdout);

        /* union */
        NSMutableSet* u = [NSMutableSet setWithArray:@[@"a", @"b", @"c"]];
        [u unionSet:[NSSet setWithArray:@[@"c", @"d"]]];
        printf("M34-UNION-%lu\n", (unsigned long)[u count]); fflush(stdout);

        /* intersect */
        NSMutableSet* in = [NSMutableSet setWithArray:@[@"a", @"b", @"c"]];
        [in intersectSet:[NSSet setWithArray:@[@"b", @"c", @"d"]]];
        printf("M34-INTERSECT-%lu\n", (unsigned long)[in count]); fflush(stdout);

        /* minus */
        NSMutableSet* mn = [NSMutableSet setWithArray:@[@"a", @"b", @"c"]];
        [mn minusSet:[NSSet setWithArray:@[@"b"]]];
        printf("M34-MINUS-%lu\n", (unsigned long)[mn count]); fflush(stdout);

        /* subset */
        BOOL sub = [[NSSet setWithArray:@[@"a", @"b"]] isSubsetOfSet:abc];
        printf("M34-SUBSET-%d\n", sub ? 1 : 0); fflush(stdout);

        /* ordered set: insertion order preserved, duplicates dropped */
        NSOrderedSet* os = [NSOrderedSet orderedSetWithArray:@[@"c", @"a", @"b", @"a"]];
        printf("M34-ORDERED-CNT-%lu\n", (unsigned long)[os count]); fflush(stdout);
        printf("M34-ORDERED-IDX-%ld\n", (long)[os indexOfObject:@"a"]); fflush(stdout);
        printf("M34-ORDERED-FIRST-%s\n", [[os objectAtIndex:0] UTF8String]); fflush(stdout);

        printf("M34-DONE\n"); fflush(stdout);
    }
    return 0;
}
