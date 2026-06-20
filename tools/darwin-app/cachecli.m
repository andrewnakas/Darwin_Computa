/*
 * cachecli.m — M62: NSCache in-memory key/value cache. NSCache is Foundation's
 * thread-safe, auto-evicting object cache (the store behind image/data caches in
 * real apps) — distinct from NSDictionary (M58 KVC / general dict use) in that it is
 * purpose-built for cache semantics (cost accounting, eviction, thread safety).
 * Pure Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation before authoring
 * (M22) — NOTE setCountLimit:/countLimit are ABSENT in this Cocotron Foundation, so
 * this probe deliberately uses only the present selectors (setObject:forKey:,
 * setObject:forKey:cost:, objectForKey:, removeObjectForKey:, removeAllObjects).
 * CoreFoundation linked BY PATH (M17).
 *
 *   - setObject:forKey: store 3 entries, objectForKey: reads them back,
 *   - objectForKey: a missing key -> nil,
 *   - setObject:forKey:cost: store with an explicit cost, read back,
 *   - removeObjectForKey: one entry -> that key now nil, others remain,
 *   - removeAllObjects -> a previously-present key now nil.
 *
 *   M62-GET-<s>            objectForKey:@"b" after storing  (== "beta")
 *   M62-MISS-1            objectForKey:@"zzz" is nil  (== 1)
 *   M62-COST-<s>          objectForKey: of a cost-stored entry  (== "gamma")
 *   M62-REMOVE-1          after removeObjectForKey:@"a", objectForKey:@"a" is nil
 *   M62-REMAIN-<s>        objectForKey:@"b" still present after removing "a"  (== "beta")
 *   M62-REMOVEALL-1       after removeAllObjects, objectForKey:@"b" is nil
 *   M62-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSCache* cache = [[NSCache alloc] init];
        [cache setName:@"m62.cache"];

        /* ---- store + read back ------------------------------------------- */
        [cache setObject:@"alpha" forKey:@"a"];
        [cache setObject:@"beta"  forKey:@"b"];
        [cache setObject:@"gamma" forKey:@"c"];

        id b = [cache objectForKey:@"b"];
        printf("M62-GET-%s\n", b ? [b UTF8String] : "nil"); fflush(stdout);

        /* ---- missing key -> nil ----------------------------------------- */
        id miss = [cache objectForKey:@"zzz"];
        printf("M62-MISS-%d\n", (miss == nil) ? 1 : 0); fflush(stdout);

        /* ---- cost-based set (re-store c with a cost) --------------------- */
        [cache setObject:@"gamma" forKey:@"c" cost:100];
        id c = [cache objectForKey:@"c"];
        printf("M62-COST-%s\n", c ? [c UTF8String] : "nil"); fflush(stdout);

        /* ---- remove one ------------------------------------------------- */
        [cache removeObjectForKey:@"a"];
        id a = [cache objectForKey:@"a"];
        printf("M62-REMOVE-%d\n", (a == nil) ? 1 : 0); fflush(stdout);
        id bStill = [cache objectForKey:@"b"];
        printf("M62-REMAIN-%s\n", bStill ? [bStill UTF8String] : "nil"); fflush(stdout);

        /* ---- remove all ------------------------------------------------- */
        [cache removeAllObjects];
        id bGone = [cache objectForKey:@"b"];
        printf("M62-REMOVEALL-%d\n", (bGone == nil) ? 1 : 0); fflush(stdout);

        printf("M62-DONE\n"); fflush(stdout);
    }
    return 0;
}
