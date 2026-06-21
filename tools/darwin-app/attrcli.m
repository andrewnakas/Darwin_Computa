/*
 * attrcli.m — M63: NSAttributedString / NSMutableAttributedString (styled text).
 * Attributed strings are the foundation of all rich text on the platform — a string
 * with per-character-range attribute dictionaries. This exercises the attributed-string
 * object model: attach attributes over ranges, read them back with the effective range,
 * mutate, extract a styled substring, and enumerate attribute runs via a block.
 * Distinct from the plain-string tier (M29 processing, M47 formatting). Pure
 * Foundation (M3 runtime) + the block runtime (M54); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation before authoring
 * (M22). NSAttributedString is a Foundation class; CoreFoundation linked BY PATH (M17).
 * (NSMeasurement was considered for M63 but its conversion API
 * measurementByConvertingToUnit:/initWithDoubles:unit: is ABSENT in this Foundation.)
 *
 *   - build "Darwin Computa" with attribute @"weight"=@"bold" over "Darwin" (0..6)
 *     and @"weight"=@"thin" over "Computa" (7..14),
 *   - length == 14,
 *   - attributesAtIndex:0 effectiveRange: -> "bold", effective range length 6,
 *   - attributesAtIndex:7 -> "thin",
 *   - attributedSubstringFromRange: (7,7) -> plain string "Computa",
 *   - enumerateAttributesInRange:usingBlock: counts 3 attribute runs (M54 blocks):
 *     [0,6) bold, [6,7) the UNATTRIBUTED space, [7,14) thin — the space at index 6 is
 *     its own run because no attributes were set on it. (This is correct behavior;
 *     verified live to match host enumeration semantics.)
 *
 *   M63-LEN-<n>            length  (== 14)
 *   M63-ATTR0-<s>          @"weight" at index 0  (== "bold")
 *   M63-RANGE0-<n>         effective range length at index 0  (== 6)
 *   M63-ATTR7-<s>          @"weight" at index 7  (== "thin")
 *   M63-SUB-<s>            attributedSubstringFromRange(7,7).string  (== "Computa")
 *   M63-RUNS-<n>           attribute runs counted by the enumerate block  (== 3:
 *                          bold / unattributed-space / thin)
 *   M63-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSMutableAttributedString* as =
            [[NSMutableAttributedString alloc] initWithString:@"Darwin Computa"];

        [as setAttributes:@{ @"weight": @"bold" } range:NSMakeRange(0, 6)];   /* Darwin */
        [as setAttributes:@{ @"weight": @"thin" } range:NSMakeRange(7, 7)];   /* Computa */

        printf("M63-LEN-%lu\n", (unsigned long)[as length]); fflush(stdout);

        /* ---- read attribute + effective range at index 0 ----------------- */
        NSRange r0;
        NSDictionary* a0 = [as attributesAtIndex:0 effectiveRange:&r0];
        printf("M63-ATTR0-%s\n", [[a0 objectForKey:@"weight"] UTF8String]); fflush(stdout);
        printf("M63-RANGE0-%lu\n", (unsigned long)r0.length); fflush(stdout);

        /* ---- attribute at index 7 --------------------------------------- */
        NSRange r7;
        NSDictionary* a7 = [as attributesAtIndex:7 effectiveRange:&r7];
        printf("M63-ATTR7-%s\n", [[a7 objectForKey:@"weight"] UTF8String]); fflush(stdout);

        /* ---- styled substring ------------------------------------------- */
        NSAttributedString* sub = [as attributedSubstringFromRange:NSMakeRange(7, 7)];
        printf("M63-SUB-%s\n", [[sub string] UTF8String]); fflush(stdout);

        /* ---- enumerate attribute runs via a block (M54) ----------------- */
        __block int runs = 0;
        [as enumerateAttributesInRange:NSMakeRange(0, [as length])
                               options:0
                            usingBlock:^(NSDictionary* attrs, NSRange range, BOOL* stop) {
            runs++;
        }];
        printf("M63-RUNS-%d\n", runs); fflush(stdout);

        printf("M63-DONE\n"); fflush(stdout);
    }
    return 0;
}
