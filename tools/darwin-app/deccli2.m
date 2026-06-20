/*
 * deccli2.m — M53: NSDecimalNumber division + power-of-10 scaling + comparison.
 * Extends M26 (exact add/multiply) to the division/scaling/compare paths. Pure
 * Foundation (the proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSDecimalNumber is a Foundation class; CoreFoundation
 * linked BY PATH (M17).
 *
 * GATED facets (the guest does these correctly):
 *   - exact no-handler division: 1/4 -> "0.25", 10/2 -> "5" (terminating, exact),
 *   - power-of-10 scaling: 19.99 * 10^2 -> "1999",
 *   - comparison: 3.33 < 3.34 -> ascending (-1).
 *
 * KNOWN GUEST GAP (non-gating, like the M17 ICU weekday / M28 grouping findings):
 * NSDecimalNumberHandler-controlled rounding is BROKEN under emulation. A first
 * version used decimalNumberByDividingBy:withBehavior: (handler: plain rounding,
 * scale 2); the guest IGNORED the scale/rounding and even misinterpreted the handler
 * arg — 10/3 gave "3.33333" (not "3.33") and 1/8 gave "0.0922337" (not "0.13";
 * 1/8 is 0.125). The non-handler division/scaling/compare paths are all correct;
 * only the NSDecimalNumberHandler behavior is broken. We surface it as a GAP marker
 * and gate on the proven paths. (Apps needing rounded decimals on the guest can scale
 * by powers of 10 + truncate, which the POW path shows works.)
 *
 *   M53-DIV4-<s>           1/4 exact (no handler)  (== "0.25")
 *   M53-DIV2-<s>           10/2 exact (no handler)  (== "5")
 *   M53-POW-<s>            19.99 * 10^2  (== "1999")
 *   M53-CMP-<n>            compare 3.33 vs 3.34  (== -1 ascending)
 *   M53-HANDLER-<OK|GAP-norounding>  whether the rounding handler is honored
 *   M53-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

enum { M_NSRoundPlain = 0 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSDecimalNumber* one  = [NSDecimalNumber decimalNumberWithString:@"1"];
        NSDecimalNumber* four = [NSDecimalNumber decimalNumberWithString:@"4"];
        NSDecimalNumber* ten  = [NSDecimalNumber decimalNumberWithString:@"10"];
        NSDecimalNumber* two  = [NSDecimalNumber decimalNumberWithString:@"2"];

        /* ---- exact no-handler division (terminating decimals) ------------- */
        NSDecimalNumber* d4 = [one decimalNumberByDividingBy:four];
        printf("M53-DIV4-%s\n", [[d4 stringValue] UTF8String]); fflush(stdout);
        NSDecimalNumber* d2 = [ten decimalNumberByDividingBy:two];
        printf("M53-DIV2-%s\n", [[d2 stringValue] UTF8String]); fflush(stdout);

        /* ---- power-of-10 scaling ----------------------------------------- */
        NSDecimalNumber* price = [NSDecimalNumber decimalNumberWithString:@"19.99"];
        NSDecimalNumber* pow = [price decimalNumberByMultiplyingByPowerOf10:2];
        printf("M53-POW-%s\n", [[pow stringValue] UTF8String]); fflush(stdout);

        /* ---- comparison -------------------------------------------------- */
        NSDecimalNumber* a = [NSDecimalNumber decimalNumberWithString:@"3.33"];
        NSDecimalNumber* b = [NSDecimalNumber decimalNumberWithString:@"3.34"];
        printf("M53-CMP-%ld\n", (long)[a compare:b]); fflush(stdout);

        /* ---- handler-controlled rounding (documented non-gating gap) ------
         * On the host this rounds 10/3 to "3.33"; on the guest the handler is
         * ignored (yields unrounded/garbage). Report OK only if it actually
         * produced the rounded value. */
        NSDecimalNumberHandler* h =
            [NSDecimalNumberHandler decimalNumberHandlerWithRoundingMode:M_NSRoundPlain
                scale:2 raiseOnExactness:NO raiseOnOverflow:NO
                raiseOnUnderflow:NO raiseOnDivideByZero:NO];
        NSDecimalNumber* three = [NSDecimalNumber decimalNumberWithString:@"3"];
        NSDecimalNumber* r = [ten decimalNumberByDividingBy:three withBehavior:h];
        BOOL handlerOK = [[r stringValue] isEqualToString:@"3.33"];
        printf("M53-HANDLER-%s\n", handlerOK ? "OK" : "GAP-norounding"); fflush(stdout);

        printf("M53-DONE\n"); fflush(stdout);
    }
    return 0;
}
