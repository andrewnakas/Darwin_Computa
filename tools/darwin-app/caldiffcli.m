/*
 * caldiffcli.m — M41: calendar date construction + date-difference via NSCalendar /
 * NSDateComponents. The INVERSE direction of M17 (which extracted components from a
 * date): here we BUILD a date from explicit Y/M/D components and compute the span
 * between two dates in days and months. Deliberately avoids the M17 ICU weekday gap
 * (no weekday facet). Pure Foundation (the proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSCalendar/NSDateComponents are CF-resident, so
 * build-caldiffcli.sh links CoreFoundation BY PATH (the M17 finding). We use the
 * @"gregorian" identifier literal (per M17) and a UTC time zone for determinism.
 *
 *   - BUILD date A = 2026-01-15 and date B = 2026-02-24 from components
 *     (dateFromComponents:), then read each back via components:fromDate: to confirm
 *     the round trip,
 *   - DIFF: components:fromDate:A toDate:B with day unit -> 40 days,
 *   - DIFF: same with month+day units -> 1 month, 9 days (Jan15 -> Feb24).
 *
 *   M41-BUILDA-<y>-<m>-<d>   round-tripped components of date A  (== 2026-1-15)
 *   M41-BUILDB-<y>-<m>-<d>   round-tripped components of date B  (== 2026-2-24)
 *   M41-DIFFDAYS-<n>         day span A->B  (== 40)
 *   M41-DIFFMON-<m>-<d>      month+day span A->B  (== 1 month, 9 days)
 *   M41-ORDER-OK            A is earlier than B (compare:)
 *   M41-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

enum {
    M_NSCalendarUnitDay   = (1 << 4),
    M_NSCalendarUnitMonth = (1 << 3),
    M_NSCalendarUnitYear  = (1 << 2),
};

static NSDate* buildDate(NSCalendar* cal, int y, int mo, int d) {
    NSDateComponents* c = [[NSDateComponents alloc] init];
    [c setYear:y]; [c setMonth:mo]; [c setDay:d];
    return [cal dateFromComponents:c];
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSCalendar* cal = [[NSCalendar alloc] initWithCalendarIdentifier:@"gregorian"];
        [cal setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        NSUInteger ymd = M_NSCalendarUnitYear | M_NSCalendarUnitMonth | M_NSCalendarUnitDay;

        NSDate* a = buildDate(cal, 2026, 1, 15);
        NSDate* b = buildDate(cal, 2026, 2, 24);

        /* round-trip A + B through extraction */
        NSDateComponents* ca = [cal components:ymd fromDate:a];
        printf("M41-BUILDA-%ld-%ld-%ld\n", (long)[ca year], (long)[ca month], (long)[ca day]); fflush(stdout);
        NSDateComponents* cb = [cal components:ymd fromDate:b];
        printf("M41-BUILDB-%ld-%ld-%ld\n", (long)[cb year], (long)[cb month], (long)[cb day]); fflush(stdout);

        /* day span */
        NSDateComponents* dd = [cal components:M_NSCalendarUnitDay fromDate:a toDate:b options:0];
        printf("M41-DIFFDAYS-%ld\n", (long)[dd day]); fflush(stdout);

        /* month + day span */
        NSDateComponents* md = [cal components:(M_NSCalendarUnitMonth | M_NSCalendarUnitDay)
                                      fromDate:a toDate:b options:0];
        printf("M41-DIFFMON-%ld-%ld\n", (long)[md month], (long)[md day]); fflush(stdout);

        /* ordering */
        BOOL order = ([a compare:b] == NSOrderedAscending);
        printf("M41-ORDER-%s\n", order ? "OK" : "FAIL"); fflush(stdout);

        printf("M41-DONE\n"); fflush(stdout);
    }
    return 0;
}
