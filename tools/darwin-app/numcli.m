/*
 * numcli.m — M28: number formatting + parsing via NSNumberFormatter. A fundamental,
 * deterministic, headless Foundation capability (formatting numbers for display and
 * parsing them back underlies every form, invoice, and report). Pure Foundation
 * (the proven M3 runtime); no networking.
 *
 * Pinned to en_US_POSIX with explicit fraction digits to stay deterministic. All
 * selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson); NSNumberFormatter leans on CF machinery, so
 * build-numcli.sh links CoreFoundation BY PATH (the M17 finding).
 *
 * Facets (all pass live on the guest):
 *   - FORMAT a value with exactly 2 fraction digits, ungrouped -> "1234567.50",
 *   - FORMAT an integer with the same formatter -> "42.00",
 *   - PARSE a plain decimal string "1234567.50" back to a number == 1234567.5,
 *   - a negative round trip -42.25 -> "-42.25" -> parse == -42.25,
 *   - GROUPING: with grouping enabled AND an explicit grouping size, 1234567.5 ->
 *     "1,234,567.50".
 *
 * GUEST QUIRK (resolved, worth recording): this Cocotron NSNumberFormatter needs an
 * EXPLICIT setGroupingSize: to emit separators — setUsesGroupingSeparator:YES +
 * setGroupingSeparator: alone leaves groupingSize at 0 (no grouping), so a first
 * version of this probe saw "1234567.50" with no commas. Adding setGroupingSize:3
 * makes grouping work. (On the host the default size is 3, which masks this; verify
 * the explicit call against the guest.)
 *
 *   M28-FMT-<s>            value, 2 fraction digits, ungrouped (== "1234567.50")
 *   M28-FMT-OK            == the expected ungrouped string
 *   M28-FMT42-<s>         integer formatted (== "42.00")
 *   M28-FMT42-OK         == "42.00"
 *   M28-PARSE-<f>         parse "1234567.50" back, printed %.2f (== 1234567.50)
 *   M28-PARSE-OK         parsed value equals 1234567.5
 *   M28-NEG-<s>           formatted -42.25 (== "-42.25")
 *   M28-NEG-ROUNDTRIP-OK  parse(format(-42.25)) == -42.25
 *   M28-GROUPING-OK       grouping (with explicit grouping size) == "1,234,567.50"
 *   M28-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <math.h>

enum { M_NSNumberFormatterDecimalStyle = 1 };

static NSNumberFormatter* makeFormatter(void) {
    NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
    [f setNumberStyle:M_NSNumberFormatterDecimalStyle];
    [f setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
    [f setDecimalSeparator:@"."];
    [f setUsesGroupingSeparator:NO];   /* gate on the ungrouped path the guest honors */
    [f setMinimumFractionDigits:2];
    [f setMaximumFractionDigits:2];
    return f;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSNumberFormatter* f = makeFormatter();

        NSString* s1 = [f stringFromNumber:@1234567.5];
        printf("M28-FMT-%s\n", [s1 UTF8String]); fflush(stdout);
        printf("M28-FMT-%s\n", [s1 isEqualToString:@"1234567.50"] ? "OK" : "FAIL"); fflush(stdout);

        NSString* s2 = [f stringFromNumber:@42];
        printf("M28-FMT42-%s\n", [s2 UTF8String]); fflush(stdout);
        printf("M28-FMT42-%s\n", [s2 isEqualToString:@"42.00"] ? "OK" : "FAIL"); fflush(stdout);

        NSNumber* parsed = [f numberFromString:@"1234567.50"];
        printf("M28-PARSE-%.2f\n", parsed ? [parsed doubleValue] : -1.0); fflush(stdout);
        printf("M28-PARSE-%s\n",
               (parsed && fabs([parsed doubleValue] - 1234567.5) < 1e-6) ? "OK" : "FAIL");
        fflush(stdout);

        NSString* neg = [f stringFromNumber:@(-42.25)];
        printf("M28-NEG-%s\n", [neg UTF8String]); fflush(stdout);
        NSNumber* negBack = [f numberFromString:neg];
        printf("M28-NEG-ROUNDTRIP-%s\n",
               (negBack && fabs([negBack doubleValue] - (-42.25)) < 1e-6) ? "OK" : "FAIL");
        fflush(stdout);

        /* Grouping probe: a grouping formatter WITH an explicit grouping size emits
         * separators on the guest (setGroupingSize: is required — see header). */
        NSNumberFormatter* g = makeFormatter();
        [g setUsesGroupingSeparator:YES];
        [g setGroupingSeparator:@","];
        [g setGroupingSize:3];
        NSString* grouped = [g stringFromNumber:@1234567.5];
        BOOL groupingWorks = grouped && [grouped isEqualToString:@"1,234,567.50"];
        printf("M28-GROUPING-%s\n", groupingWorks ? "OK" : "GAP-nogrouping"); fflush(stdout);

        printf("M28-DONE\n"); fflush(stdout);
    }
    return 0;
}
