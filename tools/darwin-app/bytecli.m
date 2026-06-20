/*
 * bytecli.m — M51: human-readable byte-count formatting via NSByteCountFormatter.
 * Turns raw byte counts into "1 KB" / "1 MB"-style strings — the formatter every
 * file/download UI uses. Pure Foundation (the proven M3 runtime); no networking.
 *
 * Byte-count formatting can be locale/ICU-influenced (separators, spacing) and the
 * guest's ICU has known quirks (M17 weekday, M28 grouping), so the gating checks are
 * STRUCTURAL: the result is non-empty and contains the expected UNIT substring (bytes/
 * KB/MB), and a count-only vs unit-only split behaves. We pin a fixed count style for
 * determinism. All selectors pre-vetted present (M22); NSByteCountFormatter is a
 * Foundation class, CoreFoundation linked BY PATH (M17).
 *
 *   - 512 bytes (decimal style) -> non-empty, contains "byte"/"bytes",
 *   - 1500 -> contains "KB" (decimal style: 1000-based, so 1500 ~ 1.5 KB),
 *   - 1500000 -> contains "MB",
 *   - includesUnit:NO, includesCount:YES on 1500 -> a non-empty count with NO "KB".
 *
 *   M51-B512-<s>           formatted 512  (contains "byte")
 *   M51-B512-OK           non-empty and mentions bytes
 *   M51-KB-<s>             formatted 1500 (contains "KB")
 *   M51-KB-OK             contains "KB"
 *   M51-MB-OK             formatted 1500000 contains "MB"
 *   M51-NOUNIT-OK         includesUnit:NO yields a string WITHOUT "KB"
 *   M51-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

/* NSByteCountFormatterCountStyle: Decimal == 1 (1000-based). */
enum { M_NSByteCountFormatterCountStyleDecimal = 1 };

static int contains(NSString* s, NSString* sub) {
    return (s && [s rangeOfString:sub].location != NSNotFound) ? 1 : 0;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSByteCountFormatter* f = [[NSByteCountFormatter alloc] init];
        [f setCountStyle:M_NSByteCountFormatterCountStyleDecimal];

        NSString* b512 = [f stringFromByteCount:512];
        printf("M51-B512-%s\n", [b512 UTF8String]); fflush(stdout);
        printf("M51-B512-%s\n", ([b512 length] > 0 && contains(b512, @"byte")) ? "OK" : "FAIL"); fflush(stdout);

        NSString* kb = [f stringFromByteCount:1500];
        printf("M51-KB-%s\n", [kb UTF8String]); fflush(stdout);
        printf("M51-KB-%s\n", contains(kb, @"KB") ? "OK" : "FAIL"); fflush(stdout);

        NSString* mb = [f stringFromByteCount:1500000];
        printf("M51-MB-%s\n", contains(mb, @"MB") ? "OK" : "FAIL"); fflush(stdout);

        /* count only, no unit */
        NSByteCountFormatter* g = [[NSByteCountFormatter alloc] init];
        [g setCountStyle:M_NSByteCountFormatterCountStyleDecimal];
        [g setIncludesUnit:NO];
        [g setIncludesCount:YES];
        NSString* nounit = [g stringFromByteCount:1500];
        printf("M51-NOUNIT-%s\n", ([nounit length] > 0 && !contains(nounit, @"KB")) ? "OK" : "FAIL");
        fflush(stdout);

        printf("M51-DONE\n"); fflush(stdout);
    }
    return 0;
}
