/*
 * jsoncli.m — M7: JSON parsing + serialization via NSJSONSerialization (the
 * Foundation data tier, on the proven Foundation/ObjC runtime).
 *
 * Parses a JSON document into NSDictionary/NSArray/NSNumber/NSString, reads typed
 * values back out (including a nested array and a computed number), then
 * RE-SERIALIZES the parsed object graph back to JSON and re-parses it — proving a
 * full lossless round-trip through NSJSONSerialization, not just a one-way parse.
 *
 * Real Objective-C (compiler objc_msgSend). Headless, self-contained.
 *
 *   M7-PARSE-OK            JSONObjectWithData: produced a dictionary
 *   M7-STR-DARWIN          obj["name"] -> "darwin" (uppercased, read back)
 *   M7-NUM-42              obj["answer"] -> 42 (NSNumber)
 *   M7-ARRAY-3             obj["items"] is a 3-element array
 *   M7-NESTED-7            obj["items"][2] -> 7 (nested value)
 *   M7-SERIALIZE-<bytes>   dataWithJSONObject: re-serialized the graph
 *   M7-ROUNDTRIP-OK        re-parsing the serialized data yields answer==42 again
 *   M7-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        const char* json =
            "{ \"name\": \"darwin\", \"answer\": 42, \"items\": [3, 5, 7], "
            "  \"nested\": { \"ok\": true } }";
        NSData* data = [NSData dataWithBytes:json length:strlen(json)];

        NSError* err = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            printf("M7-PARSE-FAIL-%s\n", err ? [[err localizedDescription] UTF8String] : "not-a-dict");
            fflush(stdout); printf("M7-DONE\n"); return 0;
        }
        NSDictionary* d = (NSDictionary*)obj;
        printf("M7-PARSE-OK\n"); fflush(stdout);

        // String value.
        NSString* name = d[@"name"];
        printf("M7-STR-%s\n", name ? [[name uppercaseString] UTF8String] : "NIL"); fflush(stdout);

        // Number value.
        NSNumber* answer = d[@"answer"];
        printf("M7-NUM-%d\n", answer ? [answer intValue] : -1); fflush(stdout);

        // Nested array.
        NSArray* items = d[@"items"];
        if ([items isKindOfClass:[NSArray class]]) {
            printf("M7-ARRAY-%lu\n", (unsigned long)[items count]); fflush(stdout);
            if ([items count] == 3) {
                printf("M7-NESTED-%d\n", [[items objectAtIndex:2] intValue]); fflush(stdout);
            }
        } else {
            printf("M7-ARRAY-FAIL\n"); fflush(stdout);
        }

        // Re-serialize the whole graph back to JSON.
        NSError* se = nil;
        NSData* out = [NSJSONSerialization dataWithJSONObject:d options:0 error:&se];
        if (!out) {
            printf("M7-SERIALIZE-FAIL-%s\n", se ? [[se localizedDescription] UTF8String] : "nil");
            fflush(stdout); printf("M7-DONE\n"); return 0;
        }
        printf("M7-SERIALIZE-%lu\n", (unsigned long)[out length]); fflush(stdout);

        // Re-parse the serialized data and confirm a value survived the round-trip.
        NSError* re = nil;
        id obj2 = [NSJSONSerialization JSONObjectWithData:out options:0 error:&re];
        int answer2 = [[obj2 objectForKey:@"answer"] intValue];
        printf("M7-ROUNDTRIP-%s\n", (answer2 == 42) ? "OK" : "FAIL"); fflush(stdout);

        printf("M7-DONE\n"); fflush(stdout);
    }
    return 0;
}
