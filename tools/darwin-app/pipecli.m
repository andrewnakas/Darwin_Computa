/*
 * pipecli.m — M31: CLI SYNTHESIS. Composes four separately-proven capabilities into
 * one data pipeline in a single process — the CLI analog of the M11-M14 GUI
 * synthesis tier. It proves the capabilities INTEROPERATE, not just run in isolation:
 *
 *   JSON (M7)  ->  NSPredicate filter (M24)  ->  NSKeyedArchiver (M25)  ->  SHA-256 (M20)
 *
 * Flow: parse a JSON array of {name,qty} records, filter qty >= 20 with an
 * NSPredicate, keyed-archive the filtered NSArray to NSData, then SHA-256 the
 * archive bytes. Because the input is fixed and the archive is deterministic, the
 * digest is stable — we run the whole pipeline TWICE and confirm the two digests are
 * identical (proving determinism end to end), and check the filtered count + a
 * round-trip unarchive.
 *
 * Pure Foundation + the modern libcrypto (the M20 layer). All selectors pre-vetted
 * (M22); CoreFoundation linked BY PATH (M17) for the CF-resident classes; modern
 * libcrypto.44 linked by path for SHA-256.
 *
 *   M31-JSON-OK            JSON parsed into an array of records
 *   M31-COUNT-<n>          records after qty>=20 filter  (== 3)
 *   M31-NAMES-<s>          filtered names, comma-joined  (== "beta,gamma,delta")
 *   M31-ARCHIVE-LEN-<n>    keyed-archive byte length (> 0)
 *   M31-SHA-<hex>          SHA-256 of the archive bytes
 *   M31-STABLE-OK          the pipeline run twice yields the SAME digest (determinism)
 *   M31-UNARCHIVE-OK       unarchive(archive) deep-equals the filtered array
 *   M31-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

extern unsigned char* SHA256(const unsigned char* d, size_t n, unsigned char* md);
#define SHA256_LEN 32

static void tohex(const unsigned char* b, int n, char* out) {
    static const char* H = "0123456789abcdef";
    for (int i = 0; i < n; i++) { out[2*i] = H[b[i] >> 4]; out[2*i+1] = H[b[i] & 0xf]; }
    out[2*n] = '\0';
}

/* The composed pipeline: JSON -> predicate-filter -> keyed-archive -> NSData. */
static NSData* runPipeline(NSArray** outFiltered) {
    const char* json =
        "[{\"name\":\"alpha\",\"qty\":10},"
        " {\"name\":\"beta\",\"qty\":20},"
        " {\"name\":\"gamma\",\"qty\":42},"
        " {\"name\":\"delta\",\"qty\":30}]";
    NSData* jd = [NSData dataWithBytes:json length:strlen(json)];
    NSArray* recs = [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL];
    if (![recs isKindOfClass:[NSArray class]]) return nil;

    NSPredicate* p = [NSPredicate predicateWithFormat:@"qty >= 20"];
    NSArray* filtered = [recs filteredArrayUsingPredicate:p];
    if (outFiltered) *outFiltered = filtered;

    return [NSKeyedArchiver archivedDataWithRootObject:filtered];
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSArray* filtered = nil;
        NSData* arch = runPipeline(&filtered);
        printf("M31-JSON-%s\n", filtered ? "OK" : "FAIL"); fflush(stdout);
        if (!arch) { printf("M31-DONE\n"); return 0; }

        printf("M31-COUNT-%lu\n", (unsigned long)[filtered count]); fflush(stdout);
        NSMutableArray* names = [NSMutableArray array];
        for (NSDictionary* d in filtered) [names addObject:[d objectForKey:@"name"]];
        printf("M31-NAMES-%s\n", [[names componentsJoinedByString:@","] UTF8String]); fflush(stdout);

        printf("M31-ARCHIVE-LEN-%lu\n", (unsigned long)[arch length]); fflush(stdout);

        unsigned char sha[SHA256_LEN]; char hex[2*SHA256_LEN+1];
        SHA256((const unsigned char*)[arch bytes], (size_t)[arch length], sha);
        tohex(sha, SHA256_LEN, hex);
        printf("M31-SHA-%s\n", hex); fflush(stdout);

        /* Run the whole pipeline AGAIN and confirm the digest is identical — proves
         * the composed flow is deterministic end to end. */
        NSData* arch2 = runPipeline(NULL);
        unsigned char sha2[SHA256_LEN]; char hex2[2*SHA256_LEN+1];
        SHA256((const unsigned char*)[arch2 bytes], (size_t)[arch2 length], sha2);
        tohex(sha2, SHA256_LEN, hex2);
        printf("M31-STABLE-%s\n", (strcmp(hex, hex2) == 0) ? "OK" : "FAIL"); fflush(stdout);

        /* Round-trip: unarchive deep-equals the filtered array. */
        id restored = [NSKeyedUnarchiver unarchiveObjectWithData:arch];
        printf("M31-UNARCHIVE-%s\n", (restored && [restored isEqual:filtered]) ? "OK" : "FAIL");
        fflush(stdout);

        printf("M31-DONE\n"); fflush(stdout);
    }
    return 0;
}
