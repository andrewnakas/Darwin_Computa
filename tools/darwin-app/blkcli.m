/*
 * blkcli.m — M54: Obj-C BLOCKS through Foundation's block-based APIs. Exercises a
 * distinct runtime feature (closures + the block runtime) not yet directly proven:
 * sort with a comparator block, find with a predicate-test block, accumulate via
 * enumerate-with-block, and dictionary enumerate-with-block. Pure Foundation (the
 * proven M3 runtime) + the block runtime (libsystem_blocks, re-exported by libSystem);
 * no networking.
 *
 * The block runtime symbols (__NSConcreteStackBlock / __NSConcreteGlobalBlock,
 * _Block_copy/_Block_release) are defined in libsystem_blocks.dylib and re-exported
 * by libSystem, so blocks link + run. All selectors pre-vetted present (M22); NSArray/
 * NSDictionary are CF-resident so build-blkcli.sh links CoreFoundation BY PATH (M17).
 *
 *   - sortedArrayUsingComparator: a numeric-descending comparator block on
 *     @[3,1,2] -> [3,2,1],
 *   - indexOfObjectPassingTest: first element > 1 in @[1,2,3] -> index 1,
 *   - enumerateObjectsUsingBlock: sum 1+2+3 via a captured __block accumulator -> 6,
 *   - enumerateKeysAndObjectsUsingBlock: sum dict values {a:10,b:32} -> 42.
 *
 *   M54-SORT-<s>           descending comparator-block sort of [3,1,2]  (== "3,2,1")
 *   M54-FINDIDX-<n>        indexOfObjectPassingTest: first >1 in [1,2,3]  (== 1)
 *   M54-SUM-<n>            enumerateObjectsUsingBlock: sum [1,2,3]  (== 6)
 *   M54-DICTSUM-<n>        enumerateKeysAndObjectsUsingBlock: sum {a:10,b:32}  (== 42)
 *   M54-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSArray* nums = @[ @3, @1, @2 ];

        /* ---- sortedArrayUsingComparator: (comparator block) -------------- */
        NSArray* sorted = [nums sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [b compare:a];   /* descending */
        }];
        NSMutableArray* parts = [NSMutableArray array];
        for (NSNumber* n in sorted) [parts addObject:[n stringValue]];
        printf("M54-SORT-%s\n", [[parts componentsJoinedByString:@","] UTF8String]); fflush(stdout);

        /* ---- indexOfObjectPassingTest: (predicate block) ----------------- */
        NSArray* asc = @[ @1, @2, @3 ];
        NSUInteger idx = [asc indexOfObjectPassingTest:^BOOL(id obj, NSUInteger i, BOOL* stop) {
            if ([obj integerValue] > 1) { *stop = YES; return YES; }
            return NO;
        }];
        printf("M54-FINDIDX-%lu\n", (unsigned long)idx); fflush(stdout);

        /* ---- enumerateObjectsUsingBlock: (__block accumulator) ----------- */
        __block NSInteger sum = 0;
        [asc enumerateObjectsUsingBlock:^(id obj, NSUInteger i, BOOL* stop) {
            sum += [obj integerValue];
        }];
        printf("M54-SUM-%ld\n", (long)sum); fflush(stdout);

        /* ---- enumerateKeysAndObjectsUsingBlock: (dictionary block) ------- */
        NSDictionary* d = @{ @"a": @10, @"b": @32 };
        __block NSInteger dsum = 0;
        [d enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL* stop) {
            dsum += [v integerValue];
        }];
        printf("M54-DICTSUM-%ld\n", (long)dsum); fflush(stdout);

        printf("M54-DONE\n"); fflush(stdout);
    }
    return 0;
}
