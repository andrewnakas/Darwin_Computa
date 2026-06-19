/*
 * deccli.m — M26: exact base-10 arithmetic via NSDecimalNumber + multiset counting
 * via NSCountedSet. Two fundamental, deterministic, headless Foundation
 * capabilities. NSDecimalNumber does arbitrary-precision DECIMAL math (the kind
 * money needs — binary float cannot represent 0.10 + 0.20 exactly, decimal can).
 * NSCountedSet is a frequency multiset (counts occurrences). Pure Foundation (the
 * proven M3 runtime); no networking.
 *
 * All selectors used here were VERIFIED PRESENT in the staged guest Foundation
 * before authoring (the M22 lesson). NSDecimalNumber/NSCountedSet are Foundation
 * classes, but we link CoreFoundation BY PATH anyway (the M17 finding) since
 * NSString formatting can touch CF-resident machinery.
 *
 *   - DECIMAL: 0.10 + 0.20 == exactly 0.30 (where double gives 0.30000000000000004),
 *     and 19.99 * 3 == exactly 59.97, each compared to the expected decimal string,
 *   - the same 0.10 + 0.20 computed in C double is shown to DIFFER from 0.3 (proving
 *     the decimal path is doing something float cannot),
 *   - COUNTED SET: count occurrences in [a,b,a,c,a,b] -> a:3 b:2 c:1, total 6 / 3 uniq.
 *
 *   M26-DEC-SUM-<s>        decimal 0.10 + 0.20 as a string (== "0.3")
 *   M26-DEC-SUM-OK        == "0.3" exactly
 *   M26-DOUBLE-DIFFERS-OK  the C double 0.1+0.2 != 0.3 (decimal succeeded where float fails)
 *   M26-DEC-MUL-<s>        decimal 19.99 * 3 as a string (== "59.97")
 *   M26-DEC-MUL-OK        == "59.97" exactly
 *   M26-CSET-A-<n>         NSCountedSet count for "a" (== 3)
 *   M26-CSET-OK           counts are a:3 b:2 c:1, total 6, 3 unique
 *   M26-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <math.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- NSDecimalNumber: exact base-10 addition ---------------------- */
        NSDecimalNumber* a = [NSDecimalNumber decimalNumberWithString:@"0.10"];
        NSDecimalNumber* b = [NSDecimalNumber decimalNumberWithString:@"0.20"];
        NSDecimalNumber* sum = [a decimalNumberByAdding:b];
        NSString* sumStr = [sum stringValue];
        printf("M26-DEC-SUM-%s\n", [sumStr UTF8String]); fflush(stdout);
        printf("M26-DEC-SUM-%s\n", [sumStr isEqualToString:@"0.3"] ? "OK" : "FAIL"); fflush(stdout);

        /* The same sum in C double is NOT 0.3 — proves decimal did the exact thing. */
        double df = 0.1 + 0.2;
        printf("M26-DOUBLE-DIFFERS-%s\n", (df != 0.3) ? "OK" : "FAIL"); fflush(stdout);

        /* ---- NSDecimalNumber: exact multiplication (money) ---------------- */
        NSDecimalNumber* price = [NSDecimalNumber decimalNumberWithString:@"19.99"];
        NSDecimalNumber* three = [NSDecimalNumber decimalNumberWithString:@"3"];
        NSDecimalNumber* total = [price decimalNumberByMultiplyingBy:three];
        NSString* totStr = [total stringValue];
        printf("M26-DEC-MUL-%s\n", [totStr UTF8String]); fflush(stdout);
        printf("M26-DEC-MUL-%s\n", [totStr isEqualToString:@"59.97"] ? "OK" : "FAIL"); fflush(stdout);

        /* ---- NSCountedSet: frequency multiset ----------------------------- */
        NSCountedSet* cs = [[NSCountedSet alloc] init];
        NSArray* items = @[ @"a", @"b", @"a", @"c", @"a", @"b" ];
        for (NSString* it in items) [cs addObject:it];
        NSUInteger ca = [cs countForObject:@"a"];
        NSUInteger cb = [cs countForObject:@"b"];
        NSUInteger cc = [cs countForObject:@"c"];
        printf("M26-CSET-A-%lu\n", (unsigned long)ca); fflush(stdout);
        BOOL csOK = (ca == 3) && (cb == 2) && (cc == 1)
                    && ([items count] == 6) && ([cs count] == 3);
        printf("M26-CSET-%s\n", csOK ? "OK" : "FAIL"); fflush(stdout);

        printf("M26-DONE\n"); fflush(stdout);
    }
    return 0;
}
