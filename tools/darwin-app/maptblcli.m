/*
 * maptblcli.m — M64: NSMapTable + NSHashTable (pointer-based collections). These are
 * the configurable-ownership collections (NSMapTable = a dictionary-like map,
 * NSHashTable = a set-like store, both supporting strong/weak reference policies) —
 * the lower-level cousins of NSDictionary/NSSet, used where weak references or custom
 * pointer semantics matter (caches, observer registries, object graphs). Distinct from
 * the collections tier so far (M24 predicate, M26 counted set, M34 NSSet/NSOrderedSet,
 * M45 CFArray/CFDictionary C-API, M60 CFSet/CFBag). Pure Foundation (M3); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation before authoring (M22).
 * NSMapTable/NSHashTable are Foundation classes; CoreFoundation linked BY PATH (M17).
 * (NSDateComponentsFormatter/NSLengthFormatter were considered for M64 but their format
 * selectors are ABSENT; NSLinguisticTagger is a STUB — see the ladder dead-ends.)
 *
 *   - NSMapTable (strongToStrong): set 3 key->value, objectForKey: reads them back,
 *     count == 3, removeObjectForKey: one -> count 2, missing key -> nil,
 *   - NSHashTable: add 3 (one duplicate) -> count 3, containsObject: yes/no.
 *
 *   M64-MAPGET-<s>         NSMapTable objectForKey:@"b"  (== "beta")
 *   M64-MAPCOUNT-<n>       count after 3 inserts  (== 3)
 *   M64-MAPREMOVE-<n>      count after removeObjectForKey:@"a"  (== 2)
 *   M64-MAPMISS-1         objectForKey:@"zzz" is nil  (== 1)
 *   M64-HASHCOUNT-<n>      NSHashTable count after adding {x,y,z,y}  (== 3)
 *   M64-HASHHAS-1         containsObject:@"y"  (== 1)
 *   M64-HASHNO-0          containsObject:@"q"  (== 0)
 *   M64-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- NSMapTable (strong keys -> strong values) ------------------- */
        NSMapTable* map = [NSMapTable strongToStrongObjectsMapTable];
        [map setObject:@"alpha" forKey:@"a"];
        [map setObject:@"beta"  forKey:@"b"];
        [map setObject:@"gamma" forKey:@"c"];

        id b = [map objectForKey:@"b"];
        printf("M64-MAPGET-%s\n", b ? [b UTF8String] : "nil"); fflush(stdout);
        printf("M64-MAPCOUNT-%lu\n", (unsigned long)[map count]); fflush(stdout);

        [map removeObjectForKey:@"a"];
        printf("M64-MAPREMOVE-%lu\n", (unsigned long)[map count]); fflush(stdout);

        id miss = [map objectForKey:@"zzz"];
        printf("M64-MAPMISS-%d\n", (miss == nil) ? 1 : 0); fflush(stdout);

        /* ---- NSHashTable (set-like) -------------------------------------- */
        NSHashTable* hash = [NSHashTable hashTableWithOptions:0];
        [hash addObject:@"x"];
        [hash addObject:@"y"];
        [hash addObject:@"z"];
        [hash addObject:@"y"];   /* duplicate -> no growth */
        printf("M64-HASHCOUNT-%lu\n", (unsigned long)[hash count]); fflush(stdout);
        printf("M64-HASHHAS-%d\n", [hash containsObject:@"y"] ? 1 : 0); fflush(stdout);
        printf("M64-HASHNO-%d\n", [hash containsObject:@"q"] ? 1 : 0); fflush(stdout);

        printf("M64-DONE\n"); fflush(stdout);
    }
    return 0;
}
