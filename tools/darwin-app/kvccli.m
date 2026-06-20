/*
 * kvccli.m — M58: Key-Value Coding (KVC) + block-based NSPredicate. KVC is a core
 * Cocoa mechanism (the backbone of bindings / Core Data / much of AppKit): access
 * properties by string key, traverse key paths, and apply collection operators
 * (@sum/@avg/@max) over an array. Plus predicateWithBlock: for arbitrary filtering.
 * Pure Foundation (the proven M3 runtime) + the block runtime (M54); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSArray/NSDictionary are CF-resident; CoreFoundation
 * linked BY PATH (M17). The block runtime resolves via libSystem (M54).
 *
 *   - valueForKey: pull "name" from a dictionary -> "beta",
 *   - valueForKeyPath: nested "inner.x" -> 7,
 *   - KVC collection operator @sum.score over an array of dicts -> 90,
 *   - KVC @avg.score -> 30, @max.score -> 50,
 *   - predicateWithBlock: filter score > 25 -> 2 of 3.
 *
 *   M58-KEY-<s>            valueForKey:"name"  (== "beta")
 *   M58-KEYPATH-<n>        valueForKeyPath:"inner.x"  (== 7)
 *   M58-SUM-<n>            @sum.score over [10,30,50]  (== 90)
 *   M58-AVG-<n>            @avg.score  (== 30)
 *   M58-MAX-<n>            @max.score  (== 50)
 *   M58-BLOCKPRED-<n>      predicateWithBlock: score > 25 count  (== 2)
 *   M58-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- valueForKey: ------------------------------------------------- */
        NSDictionary* rec = @{ @"name": @"beta", @"score": @42 };
        printf("M58-KEY-%s\n", [[rec valueForKey:@"name"] UTF8String]); fflush(stdout);

        /* ---- valueForKeyPath: (nested) ----------------------------------- */
        NSDictionary* nested = @{ @"inner": @{ @"x": @7 } };
        printf("M58-KEYPATH-%ld\n", (long)[[nested valueForKeyPath:@"inner.x"] integerValue]); fflush(stdout);

        /* ---- KVC collection operators over an array of dicts ------------- */
        NSArray* arr = @[ @{@"score": @10}, @{@"score": @30}, @{@"score": @50} ];
        NSNumber* sum = [arr valueForKeyPath:@"@sum.score"];
        printf("M58-SUM-%ld\n", (long)[sum integerValue]); fflush(stdout);
        NSNumber* avg = [arr valueForKeyPath:@"@avg.score"];
        printf("M58-AVG-%ld\n", (long)[avg integerValue]); fflush(stdout);
        NSNumber* mx = [arr valueForKeyPath:@"@max.score"];
        printf("M58-MAX-%ld\n", (long)[mx integerValue]); fflush(stdout);

        /* ---- predicateWithBlock: ----------------------------------------- */
        NSPredicate* p = [NSPredicate predicateWithBlock:^BOOL(id obj, NSDictionary* bind) {
            return [[obj objectForKey:@"score"] integerValue] > 25;
        }];
        NSArray* kept = [arr filteredArrayUsingPredicate:p];
        printf("M58-BLOCKPRED-%lu\n", (unsigned long)[kept count]); fflush(stdout);

        printf("M58-DONE\n"); fflush(stdout);
    }
    return 0;
}
