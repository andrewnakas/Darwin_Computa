/*
 * predcli.m — M24: collection querying via NSPredicate + NSSortDescriptor +
 * NSExpression. A fundamental, deterministic, headless Foundation capability:
 * filtering/sorting/evaluating over in-memory object graphs underlies fetch
 * requests, search UIs, and rule engines. Pure Foundation (the proven M3 runtime);
 * no networking.
 *
 * All selectors used here were VERIFIED PRESENT in the staged guest Foundation
 * before authoring (the M22 lesson). NSPredicate format parsing leans on
 * NSCharacterSet-adjacent CF machinery; like the date/encoding probes we link
 * CoreFoundation BY PATH (the M17 finding) so any CF-resident class resolves.
 *
 * Over an array of {name, qty} dictionaries:
 *   - FILTER with predicateWithFormat:@"qty >= 20" -> count + the surviving names,
 *   - SORT the survivors by qty descending via NSSortDescriptor,
 *   - EVALUATE an arithmetic NSExpression (sum-like) to prove the expression engine,
 *   - a compound predicate (AND) to prove boolean composition.
 *
 *   M24-COUNT-<n>          total records (== 4)
 *   M24-FILTER-<n>         records with qty >= 20 (== 3)
 *   M24-FILTER-NAMES-<s>   their names, comma-joined, in original order
 *   M24-SORT-TOP-<s>       highest-qty name after descending sort (== "gamma")
 *   M24-SORT-ORDER-<s>     all names after descending-by-qty sort
 *   M24-EXPR-<n>           NSExpression 6*7 evaluated (== 42)
 *   M24-AND-<n>            compound predicate qty>=20 AND name BEGINSWITH 'b' (== 1)
 *   M24-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

static NSString* joinNames(NSArray* arr) {
    NSMutableArray* names = [NSMutableArray array];
    for (NSDictionary* d in arr) [names addObject:[d objectForKey:@"name"]];
    return [names componentsJoinedByString:@","];
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSArray* records = @[
            @{ @"name": @"alpha", @"qty": @10 },
            @{ @"name": @"beta",  @"qty": @20 },
            @{ @"name": @"gamma", @"qty": @42 },
            @{ @"name": @"delta", @"qty": @30 },
        ];
        printf("M24-COUNT-%lu\n", (unsigned long)[records count]); fflush(stdout);

        /* ---- FILTER: qty >= 20 -------------------------------------------- */
        NSPredicate* p = [NSPredicate predicateWithFormat:@"qty >= 20"];
        NSArray* filtered = [records filteredArrayUsingPredicate:p];
        printf("M24-FILTER-%lu\n", (unsigned long)[filtered count]); fflush(stdout);
        printf("M24-FILTER-NAMES-%s\n", [joinNames(filtered) UTF8String]); fflush(stdout);

        /* ---- SORT: by qty descending -------------------------------------- */
        NSSortDescriptor* sd = [NSSortDescriptor sortDescriptorWithKey:@"qty" ascending:NO];
        NSArray* sorted = [filtered sortedArrayUsingDescriptors:@[sd]];
        NSString* top = [[sorted firstObject] objectForKey:@"name"];
        printf("M24-SORT-TOP-%s\n", [top UTF8String]); fflush(stdout);
        printf("M24-SORT-ORDER-%s\n", [joinNames(sorted) UTF8String]); fflush(stdout);

        /* ---- EVALUATE an arithmetic NSExpression -------------------------- */
        NSExpression* e = [NSExpression expressionWithFormat:@"6 * 7"];
        id val = [e expressionValueWithObject:nil context:nil];
        printf("M24-EXPR-%ld\n", (long)[val integerValue]); fflush(stdout);

        /* ---- compound predicate (boolean composition) --------------------- */
        NSPredicate* cp = [NSPredicate predicateWithFormat:@"qty >= 20 AND name BEGINSWITH 'b'"];
        NSArray* both = [records filteredArrayUsingPredicate:cp];
        printf("M24-AND-%lu\n", (unsigned long)[both count]); fflush(stdout);

        printf("M24-DONE\n"); fflush(stdout);
    }
    return 0;
}
