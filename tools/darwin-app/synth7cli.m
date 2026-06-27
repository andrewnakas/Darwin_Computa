/*
 * synth7cli.m — M75: SYNTHESIS #7. Proves the freshly-landed capabilities COMPOSE with
 * the established data/crypto tiers in one process — a realistic end-to-end pipeline:
 *
 *   NSPipe byte transport (M73)  ->  NSJSONSerialization parse (M7)
 *     ->  integer aggregate  ->  modern NSData Base64 encode (M74)
 *     ->  HMAC-SHA256 sign (M20)  ->  verify against the authoritative host value.
 *
 * Each link was proven in isolation (M73 pipe, M7 JSON, M74 modern base64, M20 HMAC);
 * this confirms they interoperate without interference (shared autorelease pool, the
 * libcrypto-by-path link alongside Foundation/CF, FD-backed NSFileHandle feeding the
 * JSON parser). Pure Foundation + libcrypto.44 (M20) BY PATH (M17); no networking.
 *
 * Deterministic flow (so host values are exact):
 *   - JSON payload [{"v":3},{"v":4},{"v":5}] is WRITTEN through an NSPipe and read back,
 *   - parsed via NSJSONSerialization; sum of "v" == 12 -> the string "sum=12",
 *   - base64EncodedStringWithOptions:0 of "sum=12" == "c3VtPTEy" (host `base64`),
 *   - HMAC-SHA256(that base64 string, key "darwin") ==
 *       f00b042dfee99bdc8ee07961493b172c26fbba3d174267c81cb9ed28aa11a766 (host openssl).
 *
 *   M75-PIPED-<n>          bytes of JSON read back from the pipe  (== payload length)
 *   M75-SUM-<n>            sum of the parsed "v" fields  (== 12)
 *   M75-B64-<s>            base64 of "sum=12"  (== "c3VtPTEy")
 *   M75-B64-OK            == authoritative host base64
 *   M75-HMAC-<hex>         HMAC-SHA256 of the base64 string, key "darwin"
 *   M75-HMAC-OK           == authoritative host HMAC hex  (the full chain verified)
 *   M75-DONE
 */
#import <Foundation/Foundation.h>
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
        /* ---- 1. transport the JSON payload through an NSPipe (M73) ------- */
        const char* json = "[{\"v\":3},{\"v\":4},{\"v\":5}]";
        NSPipe* p = [NSPipe pipe];
        NSFileHandle* w = [p fileHandleForWriting];
        NSFileHandle* r = [p fileHandleForReading];
        [w writeData:[NSData dataWithBytes:json length:strlen(json)]];
        [w closeFile];                                   /* EOF so the read returns */
        NSData* piped = [r readDataToEndOfFile];
        [r closeFile];
        printf("M75-PIPED-%lu\n", (unsigned long)[piped length]); fflush(stdout);

        /* ---- 2. parse the piped bytes as JSON (M7) ---------------------- */
        NSArray* recs = [NSJSONSerialization JSONObjectWithData:piped options:0 error:NULL];
        long sum = 0;
        for (NSDictionary* rec in recs) {
            sum += (long)[[rec objectForKey:@"v"] integerValue];
        }
        printf("M75-SUM-%ld\n", sum); fflush(stdout);    /* == 12 */

        /* ---- 3. modern base64 of the aggregate string (M74) ------------- */
        NSString* sumStr = [NSString stringWithFormat:@"sum=%ld", sum];
        NSData* sumData = [sumStr dataUsingEncoding:M_NSUTF8];
        NSString* b64 = [sumData base64EncodedStringWithOptions:0];
        printf("M75-B64-%s\n", [b64 UTF8String]); fflush(stdout);
        printf("M75-B64-%s\n", [b64 isEqualToString:@"c3VtPTEy"] ? "OK" : "FAIL"); fflush(stdout);

        /* ---- 4. HMAC-SHA256 the base64 string (M20) --------------------- */
        NSData* b64bytes = [b64 dataUsingEncoding:M_NSUTF8];
        const char* key = "darwin";
        unsigned char mac[SHA256_LEN]; unsigned int mlen = 0;
        HMAC(EVP_sha256(), key, (int)strlen(key),
             (const unsigned char*)[b64bytes bytes], (size_t)[b64bytes length], mac, &mlen);
        char hex[2*SHA256_LEN+1]; static const char* H = "0123456789abcdef";
        for (int i = 0; i < (int)mlen; i++) { hex[2*i]=H[mac[i]>>4]; hex[2*i+1]=H[mac[i]&0xf]; }
        hex[2*mlen] = '\0';
        printf("M75-HMAC-%s\n", hex); fflush(stdout);
        const char* kHMAC = "f00b042dfee99bdc8ee07961493b172c26fbba3d174267c81cb9ed28aa11a766";
        printf("M75-HMAC-%s\n", strcmp(hex, kHMAC) == 0 ? "OK" : "FAIL"); fflush(stdout);

        printf("M75-DONE\n"); fflush(stdout);
    }
    return 0;
}
