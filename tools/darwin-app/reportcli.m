/*
 * reportcli.m — M50: CAPSTONE CLI SYNTHESIS. A realistic "ingest -> query -> report
 * -> sign" pipeline composing FIVE separately-proven capabilities in one process,
 * proving they interoperate end to end:
 *
 *   NSFileHandle read (M37) -> NSJSONSerialization (M7) -> NSPredicate filter +
 *   NSSortDescriptor (M24) -> NSString format report (M47) -> HMAC-SHA256 (M20)
 *
 * Flow: write a JSON file of {name,score} records, read it back with an NSFileHandle,
 * parse it, filter score >= 80 with an NSPredicate, sort the survivors by score
 * descending, format a deterministic plain-text report with NSString, then HMAC-SHA256
 * the report bytes with a fixed key and verify the hex against the authoritative host
 * value. Foundation + the modern libcrypto (the M20 layer); no networking.
 *
 * Links Foundation + CoreFoundation (M17) + libcrypto.44 (M20) BY PATH; HMAC declared
 * extern. All selectors pre-vetted (M22). Avoids the M16 removeItemAtPath gap.
 *
 *   M50-READ-<n>           bytes read from the JSON file via NSFileHandle (> 0)
 *   M50-PARSE-<n>          parsed record count  (== 4)
 *   M50-FILTER-<n>         records with score >= 80  (== 3)
 *   M50-TOP-<s>            highest-score name after descending sort  (== "gamma")
 *   M50-REPORT-<s>         the formatted report, newlines shown as '|'
 *   M50-HMAC-<hex>         HMAC-SHA256 of the report bytes (fixed key "k3y")
 *   M50-HMAC-OK           == the authoritative host HMAC hex
 *   M50-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

extern unsigned char* HMAC(const void* evp_md, const void* key, int key_len,
                           const unsigned char* d, size_t n,
                           unsigned char* md, unsigned int* md_len);
extern const void* EVP_sha256(void);
#define SHA256_LEN 32
enum { M_NSUTF8 = 4, M_NSCalendarUnitNone = 0 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSString* path = @"/var/root/m50.json";
        const char* json =
            "[{\"name\":\"alpha\",\"score\":72},"
            " {\"name\":\"beta\",\"score\":88},"
            " {\"name\":\"gamma\",\"score\":95},"
            " {\"name\":\"delta\",\"score\":80}]";
        [[NSData dataWithBytes:json length:strlen(json)] writeToFile:path atomically:NO];

        /* ---- READ via NSFileHandle (M37) ---------------------------------- */
        NSFileHandle* fh = [NSFileHandle fileHandleForReadingAtPath:path];
        NSData* data = fh ? [fh readDataToEndOfFile] : nil;
        [fh closeFile];
        printf("M50-READ-%lu\n", (unsigned long)[data length]); fflush(stdout);

        /* ---- PARSE JSON (M7) ---------------------------------------------- */
        NSArray* recs = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        printf("M50-PARSE-%lu\n", (unsigned long)[recs count]); fflush(stdout);

        /* ---- FILTER + SORT (M24) ----------------------------------------- */
        NSArray* keep = [recs filteredArrayUsingPredicate:
                         [NSPredicate predicateWithFormat:@"score >= 80"]];
        printf("M50-FILTER-%lu\n", (unsigned long)[keep count]); fflush(stdout);
        NSArray* sorted = [keep sortedArrayUsingDescriptors:
                           @[[NSSortDescriptor sortDescriptorWithKey:@"score" ascending:NO]]];
        printf("M50-TOP-%s\n", [[[sorted firstObject] objectForKey:@"name"] UTF8String]); fflush(stdout);

        /* ---- FORMAT report (M47) ----------------------------------------- */
        NSMutableString* report = [NSMutableString string];
        [report appendString:@"REPORT\n"];
        for (NSDictionary* d in sorted) {
            [report appendFormat:@"%@=%d\n",
             [d objectForKey:@"name"], (int)[[d objectForKey:@"score"] integerValue]];
        }
        /* show with '|' for newlines so the single-line marker is readable */
        NSString* shown = [report stringByReplacingOccurrencesOfString:@"\n" withString:@"|"];
        printf("M50-REPORT-%s\n", [shown UTF8String]); fflush(stdout);

        /* ---- HMAC-SHA256 sign (M20) -------------------------------------- */
        NSData* rbytes = [report dataUsingEncoding:M_NSUTF8];
        const char* key = "k3y";
        unsigned char mac[SHA256_LEN]; unsigned int mlen = 0;
        HMAC(EVP_sha256(), key, (int)strlen(key),
             (const unsigned char*)[rbytes bytes], (size_t)[rbytes length], mac, &mlen);
        char hex[2*SHA256_LEN+1]; static const char* H = "0123456789abcdef";
        for (int i = 0; i < (int)mlen; i++) { hex[2*i]=H[mac[i]>>4]; hex[2*i+1]=H[mac[i]&0xf]; }
        hex[2*mlen] = '\0';
        printf("M50-HMAC-%s\n", hex); fflush(stdout);

        /* authoritative host HMAC of the exact report bytes (filled in after host run) */
        const char* kHMAC = "dcdf8e93da9f190fe4305c07d7f2fbffac38b1331b3a75c92c531176f51db741";
        printf("M50-HMAC-%s\n", strcmp(hex, kHMAC) == 0 ? "OK" : "FAIL"); fflush(stdout);

        printf("M50-DONE\n"); fflush(stdout);
    }
    return 0;
}
