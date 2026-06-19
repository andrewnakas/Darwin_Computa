/*
 * datecli.m — M17: real date/time handling via NSDateFormatter + NSCalendar +
 * NSDateComponents. A fundamental, deterministic, headless Foundation capability
 * (parsing/formatting dates and doing calendar arithmetic underpins logging,
 * scheduling, file timestamps — almost every real program).
 *
 * Pure Foundation (the proven runtime, M3) plus the ICU-backed date machinery.
 * It exercises the full round trip:
 *   - parse a fixed date string with NSDateFormatter (a known UTC instant),
 *   - format that same NSDate back out and confirm it reproduces the input,
 *   - reformat it under a DIFFERENT pattern (proves the ICU formatter engine),
 *   - decompose it into NSDateComponents via a Gregorian NSCalendar (year/month/
 *     day/weekday — proves the calendar engine),
 *   - do calendar arithmetic: add 40 days and confirm the resulting date,
 *   - measure the interval between the two dates in seconds.
 *
 * KNOWN GUEST GAP (non-gating, like the M16 removeItemAtPath gap): the ICU-backed
 * day-of-week derivation is wrong under emulation. Live on the substrate, the same
 * instant whose YMD extracts correctly as 2026-01-15 (a Thursday) reports weekday 1
 * (Sunday) from BOTH the NSCalendar weekday component AND the EEE formatter — i.e.
 * an internally-consistent off-by-4. Everything else matches the host exactly. ICU
 * is embedded in libicucore (symbol _icudt66_dat; no external .dat load), so this
 * is not a data-file/mmap issue and not a TZ slip (YMD is right). It is a prebuilt
 * ICU-66 day-of-week defect under emulation, not recompilable in-tree. We surface it
 * via the WEEKDAY-MATCH marker and cross-check the authoritative weekday with Zeller's
 * congruence (which DOES work in-guest, since it's pure integer arithmetic on the
 * correct YMD) — so apps needing a weekday on the substrate can derive it that way.
 * The milestone gate is the 6 working facets: parse / format / alt-format / YMD /
 * calendar arithmetic / interval.
 *
 * KEY LINK FINDING (resolves the M8 "NSCharacterSet not resolvable by-path"
 * gotcha): NSDate / NSCalendar / NSLocale / NSTimeZone / NSDateComponents — like
 * NSCharacterSet — are DEFINED IN CoreFoundation and only imported (U) into
 * Foundation, which RE-EXPORTS CoreFoundation. Linking Foundation by path does
 * NOT pull its re-export targets by path, so those classes go unresolved. The
 * fix is to also link CoreFoundation BY PATH (see build-datecli.sh). With that,
 * the whole NSDate/NSCalendar family resolves. We use the @"gregorian" calendar
 * identifier string literal instead of the NSCalendarIdentifierGregorian extern
 * NSString constant to keep the link surface minimal.
 *
 *   M17-PARSE-OK           NSDateFormatter parsed "2026-01-15 12:00:00 +0000"
 *   M17-FORMAT-<s>         the parsed NSDate formatted back == the input string
 *   M17-ALTFMT-<s>         same instant under a different pattern (EEE, dd MMM yyyy)
 *   M17-YMD-<y>-<m>-<d>    NSDateComponents year/month/day from a Gregorian calendar
 *   M17-WEEKDAY-<n>        weekday component from NSCalendar/ICU (1=Sun … 7=Sat)
 *   M17-WEEKDAY-ZELLER-<n> weekday computed arithmetically (Zeller) from the YMD
 *   M17-WEEKDAY-MATCH-{OK|MISMATCH}  ICU vs Zeller; MISMATCH in-guest = the ICU gap
 *                          (host: OK/Thu/5; guest: MISMATCH, ICU=1 vs Zeller=5)
 *   M17-PLUS40-<s>         date + 40 days, formatted (calendar arithmetic)
 *   M17-INTERVAL-<n>       seconds between the two dates (== 40*86400 == 3456000)
 *   M17-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

/* NSCalendarUnit bits (stable ABI; declared to avoid relying on header enums). */
enum {
    M_NSCalendarUnitDay     = (1 << 4),
    M_NSCalendarUnitMonth   = (1 << 3),
    M_NSCalendarUnitYear    = (1 << 2),
    M_NSCalendarUnitWeekday = (1 << 9),
};

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* A fixed UTC instant so the run is fully deterministic regardless of the
         * guest's local timezone. */
        NSString* input = @"2026-01-15 12:00:00 +0000";
        NSString* pattern = @"yyyy-MM-dd HH:mm:ss Z";

        NSDateFormatter* df = [[NSDateFormatter alloc] init];
        /* Pin locale + timezone so parsing/formatting is reproducible. POSIX locale
         * keeps month/weekday names in English; UTC keeps the wall clock fixed. */
        [df setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
        [df setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        [df setDateFormat:pattern];

        NSDate* date = [df dateFromString:input];
        printf("M17-PARSE-%s\n", date ? "OK" : "FAIL"); fflush(stdout);
        if (!date) { printf("M17-DONE\n"); return 0; }

        /* Round-trip format: should reproduce the input exactly. */
        NSString* back = [df stringFromDate:date];
        printf("M17-FORMAT-%s\n", [back UTF8String]); fflush(stdout);

        /* A different pattern over the same instant — proves the formatter engine,
         * not just identity. */
        [df setDateFormat:@"EEE, dd MMM yyyy"];
        NSString* alt = [df stringFromDate:date];
        printf("M17-ALTFMT-%s\n", [alt UTF8String]); fflush(stdout);

        /* Calendar decomposition: build a Gregorian calendar in UTC and pull
         * year/month/day/weekday components. */
        NSCalendar* cal = [[NSCalendar alloc] initWithCalendarIdentifier:@"gregorian"];
        [cal setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        NSUInteger units = M_NSCalendarUnitYear | M_NSCalendarUnitMonth |
                           M_NSCalendarUnitDay  | M_NSCalendarUnitWeekday;
        NSDateComponents* c = [cal components:units fromDate:date];
        long yy = (long)[c year], mm = (long)[c month], dd = (long)[c day];
        printf("M17-YMD-%ld-%ld-%ld\n", yy, mm, dd); fflush(stdout);

        /* Weekday two ways. The calendar/ICU weekday is the value under test; we
         * cross-check it against Zeller's congruence computed from the (verified)
         * YMD, so the milestone has an authoritative weekday that does NOT depend
         * on the ICU day-of-week path. Both use the convention 1=Sun..7=Sat. */
        long calWd = (long)[c weekday];
        /* Zeller (Gregorian): h = 0=Sat,1=Sun,2=Mon,...,6=Fri. Map to 1=Sun..7=Sat. */
        long zy = yy, zm = mm;
        if (zm < 3) { zm += 12; zy -= 1; }
        long K = zy % 100, J = zy / 100;
        long h = (dd + (13*(zm+1))/5 + K + K/4 + J/4 + 5*J) % 7;  /* 0=Sat..6=Fri */
        long zellerWd = ((h + 6) % 7) + 1;                        /* ->1=Sun..7=Sat */
        printf("M17-WEEKDAY-%ld\n", calWd); fflush(stdout);
        printf("M17-WEEKDAY-ZELLER-%ld\n", zellerWd); fflush(stdout);
        printf("M17-WEEKDAY-MATCH-%s\n", (calWd == zellerWd) ? "OK" : "MISMATCH"); fflush(stdout);

        /* Calendar arithmetic: add 40 days. */
        NSDateComponents* add = [[NSDateComponents alloc] init];
        [add setDay:40];
        NSDate* later = [cal dateByAddingComponents:add toDate:date options:0];
        [df setDateFormat:pattern];
        NSString* laterStr = later ? [df stringFromDate:later] : @"(nil)";
        printf("M17-PLUS40-%s\n", [laterStr UTF8String]); fflush(stdout);

        /* Interval in seconds between the two dates. 40 days == 3,456,000 s. */
        NSTimeInterval delta = later ? [later timeIntervalSinceDate:date] : 0;
        printf("M17-INTERVAL-%ld\n", (long)delta); fflush(stdout);

        printf("M17-DONE\n"); fflush(stdout);
    }
    return 0;
}
