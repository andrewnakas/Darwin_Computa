/*
 * valcli.m — M49: NSValue boxing of C structs (NSRange / NSPoint / NSSize) + storage
 * in an NSArray. The Foundation pattern for putting non-object C structs into object
 * collections: box a struct in an NSValue, store it, pull it back out, unbox, and
 * compare. Pure Foundation (the proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSValue is a Foundation class; we still link
 * CoreFoundation BY PATH (M17) since NSArray/NSValue touch CF.
 *
 *   - box NSRange{3,7} -> NSValue, unbox -> {3,7},
 *   - box NSPoint{1.5,2.5} -> NSValue, unbox -> {1.5,2.5},
 *   - box NSSize{40,80} -> NSValue, unbox -> {40,80},
 *   - two NSValues boxing the same NSRange compare isEqualToValue: == YES,
 *   - store the three NSValues in an NSArray, pull index 1, unbox the point.
 *
 *   M49-RANGE-<loc>-<len>  unboxed NSRange  (== 3-7)
 *   M49-POINT-<x>-<y>      unboxed NSPoint  (== 1.5-2.5)
 *   M49-SIZE-<w>-<h>       unboxed NSSize   (== 40-80)
 *   M49-EQ-<n>             two equal-range NSValues isEqualToValue:  (== 1)
 *   M49-ARR-POINT-<x>-<y>  NSValue pulled from NSArray[1], unboxed point (== 1.5-2.5)
 *   M49-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- NSRange box/unbox ------------------------------------------- */
        NSValue* rv = [NSValue valueWithRange:NSMakeRange(3, 7)];
        NSRange r = [rv rangeValue];
        printf("M49-RANGE-%lu-%lu\n", (unsigned long)r.location, (unsigned long)r.length); fflush(stdout);

        /* ---- NSPoint box/unbox ------------------------------------------- */
        NSValue* pv = [NSValue valueWithPoint:NSMakePoint(1.5, 2.5)];
        NSPoint p = [pv pointValue];
        printf("M49-POINT-%g-%g\n", p.x, p.y); fflush(stdout);

        /* ---- NSSize box/unbox -------------------------------------------- */
        NSValue* sv = [NSValue valueWithSize:NSMakeSize(40, 80)];
        NSSize sz = [sv sizeValue];
        printf("M49-SIZE-%g-%g\n", sz.width, sz.height); fflush(stdout);

        /* ---- equality of two equal-range NSValues ------------------------ */
        NSValue* rv2 = [NSValue valueWithRange:NSMakeRange(3, 7)];
        printf("M49-EQ-%d\n", [rv isEqualToValue:rv2] ? 1 : 0); fflush(stdout);

        /* ---- store in NSArray, pull back, unbox ------------------------- */
        NSArray* arr = @[ rv, pv, sv ];
        NSValue* fromArr = [arr objectAtIndex:1];
        NSPoint p2 = [fromArr pointValue];
        printf("M49-ARR-POINT-%g-%g\n", p2.x, p2.y); fflush(stdout);

        printf("M49-DONE\n"); fflush(stdout);
    }
    return 0;
}
