/*
 * parcli.m — M57: CONCURRENCY SYNTHESIS, the first one exercising the GCD tier. A
 * "parallel-process -> aggregate -> sign" pipeline composing the new concurrency
 * primitives (M55 dispatch_apply / M56 barrier) with the data + crypto tiers,
 * proving GCD interoperates with the rest of the userland:
 *
 *   NSJSONSerialization (M7) -> dispatch_apply parallel map (M55) +
 *   dispatch_barrier_sync guarded accumulate (M56) -> HMAC-SHA256 (M20)
 *
 * Flow: parse a JSON array of {score} records, process them CONCURRENTLY with
 * dispatch_apply (each iteration squares its score and adds it to a shared sum,
 * guarded by a dispatch_barrier on a concurrent queue), then HMAC-SHA256 the decimal
 * sum string with a fixed key and verify the hex against the authoritative host value.
 * Foundation + libdispatch (M55) + the modern libcrypto (M20); no networking.
 *
 * Links Foundation + CoreFoundation (M17) + libcrypto.44 (M20) BY PATH; HMAC + the
 * block runtime resolve via libSystem re-exports. All symbols pre-vetted (M22).
 *
 *   M57-PARSE-<n>          parsed record count  (== 4)
 *   M57-SUM-<n>            concurrent sum of squares 10^2+20^2+30^2+40^2  (== 3000)
 *   M57-SUM-OK            == 3000 (parallel accumulate under the barrier is correct)
 *   M57-HMAC-<hex>         HMAC-SHA256 of "3000" (key "k3y")
 *   M57-HMAC-OK           == the authoritative host HMAC hex
 *   M57-DONE
 */
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

extern unsigned char* HMAC(const void* evp_md, const void* key, int key_len,
                           const unsigned char* d, size_t n,
                           unsigned char* md, unsigned int* md_len);
extern const void* EVP_sha256(void);
#define SHA256_LEN 32
enum { M_NSUTF8 = 4 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        const char* json =
            "[{\"score\":10},{\"score\":20},{\"score\":30},{\"score\":40}]";
        NSData* jd = [NSData dataWithBytes:json length:strlen(json)];
        NSArray* recs = [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL];
        printf("M57-PARSE-%lu\n", (unsigned long)[recs count]); fflush(stdout);

        /* ---- parallel map (square each score) + barrier-guarded sum ------- */
        __block long sum = 0;
        dispatch_queue_t guard = dispatch_queue_create("p.guard", DISPATCH_QUEUE_CONCURRENT);
        dispatch_apply([recs count], dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                       ^(size_t i) {
            long s = (long)[[[recs objectAtIndex:i] objectForKey:@"score"] integerValue];
            long sq = s * s;
            dispatch_barrier_sync(guard, ^{ sum += sq; });   /* exclusive write */
        });
        printf("M57-SUM-%ld\n", sum); fflush(stdout);
        printf("M57-SUM-%s\n", (sum == 3000) ? "OK" : "FAIL"); fflush(stdout);

        /* ---- HMAC-SHA256 the aggregate ----------------------------------- */
        NSString* sumStr = [NSString stringWithFormat:@"%ld", sum];
        NSData* sb = [sumStr dataUsingEncoding:M_NSUTF8];
        const char* key = "k3y";
        unsigned char mac[SHA256_LEN]; unsigned int mlen = 0;
        HMAC(EVP_sha256(), key, (int)strlen(key),
             (const unsigned char*)[sb bytes], (size_t)[sb length], mac, &mlen);
        char hex[2*SHA256_LEN+1]; static const char* H = "0123456789abcdef";
        for (int i = 0; i < (int)mlen; i++) { hex[2*i]=H[mac[i]>>4]; hex[2*i+1]=H[mac[i]&0xf]; }
        hex[2*mlen] = '\0';
        printf("M57-HMAC-%s\n", hex); fflush(stdout);

        const char* kHMAC = "037a2255f3256aa18e342505d4394099ec22ce8107a96f15b3ba5da148bef4c6";
        printf("M57-HMAC-%s\n", strcmp(hex, kHMAC) == 0 ? "OK" : "FAIL"); fflush(stdout);

        printf("M57-DONE\n"); fflush(stdout);
    }
    return 0;
}
