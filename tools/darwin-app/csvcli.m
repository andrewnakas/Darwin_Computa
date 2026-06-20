/*
 * csvcli.m — M39: CLI SYNTHESIS #4, a realistic "ingest a data file, compute, emit
 * JSON" pipeline composing four proven Foundation capabilities in one process,
 * proving they interoperate:
 *
 *   NSFileHandle read (M37) -> NSString split (M29) -> NSDecimalNumber sum (M26) -> JSON (M7)
 *
 * Flow: write a small CSV-ish file ("name,amount" rows), read it back with an
 * NSFileHandle, split into lines and fields with NSString, sum the amount column with
 * NSDecimalNumber (exact base-10 — money), build a result NSDictionary
 * {count, total, names}, and serialize it to JSON via NSJSONSerialization. Pure
 * Foundation; deterministic; no networking.
 *
 * All selectors pre-vetted (M22). CoreFoundation linked BY PATH (M17). Avoids the
 * M16 removeItemAtPath gap (leaves the file in place).
 *
 *   M39-READ-<n>           bytes read back from the file via NSFileHandle (> 0)
 *   M39-ROWS-<n>           data rows parsed (== 3, header skipped)
 *   M39-TOTAL-<s>          NSDecimalNumber sum of the amount column (== "63.84")
 *   M39-JSON-<s>           the emitted JSON (compact, key order count/total/names)
 *   M39-JSON-OK            JSON re-parses and total/count survive the round trip
 *   M39-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

enum { M_NSUTF8 = 4 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSString* path = @"/var/root/m39.csv";
        NSString* csv = @"name,amount\nalpha,19.99\nbeta,12.50\ngamma,31.35\n";
        /* total = 19.99 + 12.50 + 31.35 = 63.84 (exact in decimal). */

        /* seed the file (NSData write — proven M16/M37). */
        [[csv dataUsingEncoding:M_NSUTF8] writeToFile:path atomically:NO];

        /* ---- READ back via NSFileHandle (M37) ----------------------------- */
        NSFileHandle* fh = [NSFileHandle fileHandleForReadingAtPath:path];
        NSData* data = fh ? [fh readDataToEndOfFile] : nil;
        [fh closeFile];
        printf("M39-READ-%lu\n", (unsigned long)[data length]); fflush(stdout);
        NSString* text = [[NSString alloc] initWithData:data encoding:M_NSUTF8];

        /* ---- SPLIT into lines/fields (M29) + SUM with NSDecimalNumber (M26) - */
        NSArray* lines = [text componentsSeparatedByString:@"\n"];
        NSDecimalNumber* total = [NSDecimalNumber zero];
        NSMutableArray* names = [NSMutableArray array];
        int rows = 0;
        for (NSUInteger i = 1; i < [lines count]; i++) {   /* skip header row 0 */
            NSString* line = [lines objectAtIndex:i];
            if ([line length] == 0) continue;              /* trailing blank */
            NSArray* f = [line componentsSeparatedByString:@","];
            if ([f count] < 2) continue;
            [names addObject:[f objectAtIndex:0]];
            NSDecimalNumber* amt = [NSDecimalNumber decimalNumberWithString:[f objectAtIndex:1]];
            total = [total decimalNumberByAdding:amt];
            rows++;
        }
        printf("M39-ROWS-%d\n", rows); fflush(stdout);
        printf("M39-TOTAL-%s\n", [[total stringValue] UTF8String]); fflush(stdout);

        /* ---- emit JSON (M7) ----------------------------------------------- */
        NSDictionary* result = @{ @"count": @(rows),
                                  @"total": [total stringValue],
                                  @"names": names };
        NSData* json = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        NSString* jstr = [[NSString alloc] initWithData:json encoding:M_NSUTF8];
        printf("M39-JSON-%s\n", [jstr UTF8String]); fflush(stdout);

        /* round-trip the JSON and confirm total + count survived. */
        NSDictionary* back = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
        BOOL ok = back
            && [[back objectForKey:@"total"] isEqualToString:@"63.84"]
            && [[back objectForKey:@"count"] integerValue] == 3;
        printf("M39-JSON-%s\n", ok ? "OK" : "FAIL"); fflush(stdout);

        printf("M39-DONE\n"); fflush(stdout);
    }
    return 0;
}
