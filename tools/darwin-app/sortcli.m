/*
 * sortcli.m — M69: NSSortDescriptor multi-key sorting. Extends the M24 query tier
 * (NSPredicate/NSSortDescriptor/NSExpression) to MULTI-KEY descriptor sorting — sort
 * an array of records by a primary key, breaking ties with a secondary key, plus a
 * descending sort and a selector-based (localized) comparator. The everyday "sort a
 * table by column, then sub-sort" operation. Pure Foundation (M3 runtime); no net.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). NSSortDescriptor
 * is Foundation; CoreFoundation linked BY PATH (M17). (M69 first tried the NSDecimal C
 * struct API but the by-value-struct bridge hung the guest — see ladder; pivoted here.)
 *
 *   records: [{dept:eng,name:bob},{dept:eng,name:amy},{dept:hr,name:cara},{dept:eng,name:amy2... }]
 *   - sort by dept ASC, then name ASC -> eng/amy, eng/amy2? ... (multi-key tie-break),
 *   - sort by name DESC -> reverse alpha order,
 *   - selector localizedCaseInsensitiveCompare: orders case-insensitively.
 *
 *   M69-MULTI-<s>          dept ASC,name ASC -> first record's "name"  (== "amy")
 *   M69-MULTI2-<s>         ... second record's "name"  (== "bob")  [eng: amy<bob, hr last]
 *   M69-DESC-<s>           name DESC -> first record's "name"  (== "cara")
 *   M69-TIEBREAK-<s>       within dept=eng, name ASC tie-break -> "amy,bob"
 *   M69-CI-<s>             selector localizedCaseInsensitiveCompare sort of [B,a,C] -> "a,B,C"
 *   M69-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSArray* recs = @[
            @{ @"dept": @"eng", @"name": @"bob"  },
            @{ @"dept": @"hr",  @"name": @"cara" },
            @{ @"dept": @"eng", @"name": @"amy"  },
        ];

        /* ---- multi-key: dept ASC, then name ASC -------------------------- */
        NSSortDescriptor* byDept = [NSSortDescriptor sortDescriptorWithKey:@"dept" ascending:YES];
        NSSortDescriptor* byName = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];
        NSArray* multi = [recs sortedArrayUsingDescriptors:@[ byDept, byName ]];
        printf("M69-MULTI-%s\n", [[[multi objectAtIndex:0] objectForKey:@"name"] UTF8String]); fflush(stdout);
        printf("M69-MULTI2-%s\n", [[[multi objectAtIndex:1] objectForKey:@"name"] UTF8String]); fflush(stdout);

        /* tie-break check: within dept=eng the two eng names sort amy,bob */
        NSMutableArray* engNames = [NSMutableArray array];
        for (NSDictionary* r in multi) {
            if ([[r objectForKey:@"dept"] isEqualToString:@"eng"])
                [engNames addObject:[r objectForKey:@"name"]];
        }
        printf("M69-TIEBREAK-%s\n", [[engNames componentsJoinedByString:@","] UTF8String]); fflush(stdout);

        /* ---- descending by name -> cara,bob,amy -------------------------- */
        NSSortDescriptor* nameDesc = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:NO];
        NSArray* desc = [recs sortedArrayUsingDescriptors:@[ nameDesc ]];
        printf("M69-DESC-%s\n", [[[desc objectAtIndex:0] objectForKey:@"name"] UTF8String]); fflush(stdout);

        /* ---- selector-based (case-insensitive) sort of plain strings ----- */
        NSArray* mixed = @[ @"B", @"a", @"C" ];
        NSSortDescriptor* ci = [NSSortDescriptor sortDescriptorWithKey:@"self"
                                                            ascending:YES
                                                             selector:@selector(localizedCaseInsensitiveCompare:)];
        NSArray* ciSorted = [mixed sortedArrayUsingDescriptors:@[ ci ]];
        printf("M69-CI-%s\n", [[ciSorted componentsJoinedByString:@","] UTF8String]); fflush(stdout);

        printf("M69-DONE\n"); fflush(stdout);
    }
    return 0;
}
