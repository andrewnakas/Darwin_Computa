/*
 * cryptocli.m — M20: cryptographic digests + HMAC via the modern staged libcrypto
 * (OpenSSL). A fundamental, deterministic, headless capability (hashing underpins
 * integrity checks, signatures, content-addressing, password storage). Pure crypto,
 * no networking — distinct from M4c which used libssl for the TLS handshake.
 *
 * Uses the MODERN libcrypto.44 (the M4c lesson: NOT the ancient 0.9.x). It computes:
 *   - SHA-256 of a known string via the one-shot SHA256(), checked vs a known hex,
 *   - SHA-256 again via the STREAMING EVP API (DigestInit/Update/Final over an
 *     opaque EVP_MD_CTX) and confirms it matches the one-shot (proves the EVP path),
 *   - MD5 one-shot, checked vs a known hex,
 *   - HMAC-SHA256 with a known key, checked vs a known hex.
 * Each digest is verified against the authoritative value computed on the host.
 *
 * libcrypto is the modern staged OpenSSL (the M4c layer that works); linked BY PATH
 * like libz/libxml2. Its C API is declared extern (no openssl headers staged; the
 * digest output sizes are fixed constants and EVP_MD_CTX is an opaque handle, so
 * nothing needs struct mirroring). Foundation is linked only for an NSString hex
 * cross-check. No use of the comment-ending two-char sequence inside prose.
 *
 *   M20-SSLVER-<s>         OpenSSL_version (the lib loaded + runs)
 *   M20-SHA256-<hex>       one-shot SHA256 of "DARWIN COMPUTA"
 *   M20-SHA256-OK          == the known SHA-256 hex
 *   M20-EVP-MATCH-OK       streaming EVP SHA-256 == the one-shot result
 *   M20-MD5-<hex>          one-shot MD5
 *   M20-MD5-OK             == the known MD5 hex
 *   M20-HMAC-<hex>         HMAC-SHA256 with key "k3y"
 *   M20-HMAC-OK            == the known HMAC hex
 *   M20-NSSTRING-OK        the SHA-256 hex equals the known value via NSString
 *   M20-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

/* ---- libcrypto C API (extern; no openssl headers staged) ------------------ */
typedef struct evp_md_ctx_st EVP_MD_CTX;   /* opaque */
typedef struct evp_md_st     EVP_MD;       /* opaque */
typedef struct engine_st     ENGINE;       /* opaque */

extern const char* OpenSSL_version(int t);
extern unsigned char* SHA256(const unsigned char* d, size_t n, unsigned char* md);
extern unsigned char* MD5(const unsigned char* d, size_t n, unsigned char* md);

extern EVP_MD_CTX* EVP_MD_CTX_new(void);
extern void        EVP_MD_CTX_free(EVP_MD_CTX*);
extern const EVP_MD* EVP_sha256(void);
extern int EVP_DigestInit_ex(EVP_MD_CTX*, const EVP_MD*, ENGINE*);
extern int EVP_DigestUpdate(EVP_MD_CTX*, const void* d, size_t cnt);
extern int EVP_DigestFinal_ex(EVP_MD_CTX*, unsigned char* md, unsigned int* s);

extern unsigned char* HMAC(const EVP_MD* evp_md, const void* key, int key_len,
                           const unsigned char* d, size_t n,
                           unsigned char* md, unsigned int* md_len);

#define SHA256_LEN 32
#define MD5_LEN    16
#define OPENSSL_VERSION 0

static void tohex(const unsigned char* b, int n, char* out) {
    static const char* H = "0123456789abcdef";
    for (int i = 0; i < n; i++) { out[2*i] = H[b[i] >> 4]; out[2*i+1] = H[b[i] & 0xf]; }
    out[2*n] = '\0';
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        printf("M20-SSLVER-%s\n", OpenSSL_version(OPENSSL_VERSION)); fflush(stdout);

        const char* msg = "DARWIN COMPUTA";
        size_t mlen = strlen(msg);

        const char* kSHA = "c7bbdfec326f5aa460b61ff28e740fd8b07ce8be2f67fefef3e1eb1736e15b9f";
        const char* kMD5 = "6eb72306fea322c734ab4282e23e4f33";
        const char* kHMAC = "05e12228e5edb67f0d6b32dc906b09b01b397568a7bdcbc91c0590206c2e3cde";

        /* one-shot SHA-256 */
        unsigned char sha[SHA256_LEN]; char shaHex[2*SHA256_LEN+1];
        SHA256((const unsigned char*)msg, mlen, sha);
        tohex(sha, SHA256_LEN, shaHex);
        printf("M20-SHA256-%s\n", shaHex); fflush(stdout);
        printf("M20-SHA256-%s\n", strcmp(shaHex, kSHA) == 0 ? "OK" : "FAIL"); fflush(stdout);

        /* streaming EVP SHA-256 -> must match the one-shot */
        unsigned char esha[SHA256_LEN]; unsigned int elen = 0; char eHex[2*SHA256_LEN+1];
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        int evpOK = ctx
            && EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) == 1
            && EVP_DigestUpdate(ctx, msg, mlen) == 1
            && EVP_DigestFinal_ex(ctx, esha, &elen) == 1;
        if (ctx) EVP_MD_CTX_free(ctx);
        tohex(esha, SHA256_LEN, eHex);
        printf("M20-EVP-MATCH-%s\n",
               (evpOK && elen == SHA256_LEN && strcmp(eHex, shaHex) == 0) ? "OK" : "FAIL");
        fflush(stdout);

        /* one-shot MD5 */
        unsigned char md5[MD5_LEN]; char md5Hex[2*MD5_LEN+1];
        MD5((const unsigned char*)msg, mlen, md5);
        tohex(md5, MD5_LEN, md5Hex);
        printf("M20-MD5-%s\n", md5Hex); fflush(stdout);
        printf("M20-MD5-%s\n", strcmp(md5Hex, kMD5) == 0 ? "OK" : "FAIL"); fflush(stdout);

        /* HMAC-SHA256, key "k3y" */
        const char* key = "k3y";
        unsigned char hmac[SHA256_LEN]; unsigned int hlen = 0; char hmacHex[2*SHA256_LEN+1];
        HMAC(EVP_sha256(), key, (int)strlen(key), (const unsigned char*)msg, mlen, hmac, &hlen);
        tohex(hmac, (int)hlen, hmacHex);
        printf("M20-HMAC-%s\n", hmacHex); fflush(stdout);
        printf("M20-HMAC-%s\n", strcmp(hmacHex, kHMAC) == 0 ? "OK" : "FAIL"); fflush(stdout);

        /* Foundation cross-check on the SHA-256 hex. */
        NSString* ns = [NSString stringWithUTF8String:shaHex];
        printf("M20-NSSTRING-%s\n",
               [ns isEqualToString:[NSString stringWithUTF8String:kSHA]] ? "OK" : "FAIL");
        fflush(stdout);

        printf("M20-DONE\n"); fflush(stdout);
    }
    return 0;
}
