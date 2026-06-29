/*
 * numf2cli.m — M78: NSNumberFormatter formatting controls (fraction digits, rounding
 * mode, padding, custom positive-format pattern). Extends M28 (which proved basic decimal
 * formatting + the grouping-size quirk) with the precise number-PRESENTATION controls real
 * code uses: min/max fraction digits, formatter-driven rounding, zero-padding to a minimum
 * scale, and an explicit positiveFormat pattern. Pure Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). Locale is PINNED to
 * en_US_POSIX (the M28 lesson: locale-default grouping/separators differ + mask behavior).
 * NSNumberFormatter/NSLocale are CF-resident so CoreFoundation is linked BY PATH (M17).
 * Outputs checked against authoritative HOST NSNumberFormatter values.
 *
 *   - min2/max2 fraction digits on 3.14159     -> "3.14"   (round to 2 places)
 *   - RoundHalfUp on 2.555 at 2 places         -> "2.56"   (NOT banker's 2.55)
 *   - min3 fraction digits on 5                 -> "5.000"  (zero-pad to scale 3)
 *
 * GATING FACETS (all proven live, matching host): fraction-digit control, RoundHalfUp
 * (NOTE: the FORMATTER's rounding works here — distinct from M53's BROKEN
 * NSDecimalNumberHandler rounding; structured formatter controls round correctly),
 * min-fraction zero padding. KNOWN GUEST GAP (non-gating, root-caused live): an explicit
 * setPositiveFormat:@"0.0" PATTERN STRING is IGNORED — 7 formats as "7" not "7.0" (the
 * formatter falls back to default style instead of honoring the ICU/Cocotron pattern). So
 * use the STRUCTURED setters (min/max fraction digits) to control scale, NOT raw pattern
 * strings. The milestone gates on the 3 working structured controls + reports the gap.
 *
 *   M78-FRAC2-<s>          min2/max2 on 3.14159  (== "3.14")
 *   M78-ROUNDUP-<s>        RoundHalfUp 2.555@2   (== "2.56")
 *   M78-PAD3-<s>           min3 on 5             (== "5.000")
 *   M78-POSFMT-<s>         positiveFormat 0.0 on 7  (host "7.0"; guest "7": gap)
 *   M78-POSFMT-GAP-pattern positiveFormat pattern string ignored (documented gap)
 *   M78-CTRLS-OK          the 3 structured controls all match the host values
 *   M78-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

/* NSNumberFormatterDecimalStyle = 1 ; NSNumberFormatterRoundHalfUp = 4 */
enum { M_DECIMAL = 1, M_HALFUP = 4 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSLocale* posix = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];

        /* ---- (1) fraction-digit control -------------------------------- */
        NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
        [f setLocale:posix];
        [f setNumberStyle:M_DECIMAL];
        [f setUsesGroupingSeparator:NO];
        [f setMinimumFractionDigits:2];
        [f setMaximumFractionDigits:2];
        NSString* frac2 = [f stringFromNumber:@3.14159];
        printf("M78-FRAC2-%s\n", [frac2 UTF8String]); fflush(stdout);

        /* ---- (2) rounding mode HALF_UP --------------------------------- */
        [f setRoundingMode:M_HALFUP];
        NSString* roundup = [f stringFromNumber:@2.555];
        printf("M78-ROUNDUP-%s\n", [roundup UTF8String]); fflush(stdout);

        /* ---- (3) min-fraction zero padding ----------------------------- */
        NSNumberFormatter* p = [[NSNumberFormatter alloc] init];
        [p setLocale:posix];
        [p setNumberStyle:M_DECIMAL];
        [p setUsesGroupingSeparator:NO];
        [p setMinimumFractionDigits:3];
        [p setMaximumFractionDigits:3];
        NSString* pad3 = [p stringFromNumber:@5];
        printf("M78-PAD3-%s\n", [pad3 UTF8String]); fflush(stdout);

        /* ---- (4) explicit positiveFormat pattern ----------------------- */
        NSNumberFormatter* g = [[NSNumberFormatter alloc] init];
        [g setLocale:posix];
        [g setNumberStyle:M_DECIMAL];
        [g setPositiveFormat:@"0.0"];
        NSString* posfmt = [g stringFromNumber:@7];
        printf("M78-POSFMT-%s\n", [posfmt UTF8String]); fflush(stdout);
        if (![posfmt isEqualToString:@"7.0"]) {
            printf("M78-POSFMT-GAP-pattern\n"); fflush(stdout);  /* host "7.0", guest ignores pattern */
        }

        /* ---- gate on the 3 working STRUCTURED controls ----------------- */
        BOOL ok = [frac2 isEqualToString:@"3.14"] &&
                  [roundup isEqualToString:@"2.56"] &&
                  [pad3 isEqualToString:@"5.000"];
        printf("M78-CTRLS-%s\n", ok ? "OK" : "FAIL"); fflush(stdout);

        printf("M78-DONE\n"); fflush(stdout);
    }
    return 0;
}
