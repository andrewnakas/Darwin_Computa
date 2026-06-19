/*
 * aescli.m — M21: AES-256-CBC symmetric encryption via the modern libcrypto EVP
 * cipher API. A fundamental, deterministic, headless capability (symmetric crypto
 * underpins at-rest encryption, secure storage, envelopes). Extends M20 (digests)
 * to the CIPHER path of the same proven modern OpenSSL; pure crypto, no networking.
 *
 * Deterministic round trip with a FIXED key + IV (so the ciphertext is reproducible
 * and verifiable against the authoritative host value):
 *   ENCRYPT  plaintext -> ciphertext via EVP_EncryptInit/Update/Final over an
 *            opaque EVP_CIPHER_CTX with EVP_aes_256_cbc and PKCS#7 padding,
 *   CHECK    the ciphertext hex equals the known host-computed value, is longer
 *            than the plaintext (block-padded), and differs from the plaintext,
 *   DECRYPT  ciphertext -> plaintext via EVP_DecryptInit/Update/Final, and confirm
 *            byte-for-byte identity with the original.
 *
 * Uses the MODERN libcrypto.44 (the M4c lesson; in-guest it is LibreSSL 2.8.3 under
 * the OpenSSL-44 versioning, per M20). Linked BY PATH like libz/libxml2. The C API
 * is declared extern (no openssl headers staged; EVP_CIPHER_CTX is an opaque handle
 * and cipher block size is a fixed constant, ABI-validated header-free on host).
 * Foundation is linked for an NSData identity cross-check. No comment-ending
 * two-char sequence appears inside prose here.
 *
 *   M21-SSLVER-<s>         OpenSSL_version (the lib loaded + runs)
 *   M21-ENC-LEN-<n>        ciphertext length in bytes (== 32 for this vector)
 *   M21-CIPHER-<hex>       ciphertext hex
 *   M21-CIPHER-OK          == the known host AES-256-CBC ciphertext hex
 *   M21-DIFFERS-OK         ciphertext differs from the plaintext bytes
 *   M21-DEC-LEN-<n>        recovered plaintext length (== 31)
 *   M21-ROUNDTRIP-OK       decrypt(encrypt(pt)) == pt (byte-identical)
 *   M21-NSDATA-OK          recovered plaintext equals the original via NSData
 *   M21-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

/* ---- libcrypto EVP cipher C API (extern; no openssl headers staged) ------- */
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;   /* opaque */
typedef struct evp_cipher_st     EVP_CIPHER;       /* opaque */
typedef struct engine_st         ENGINE;           /* opaque */

extern const char* OpenSSL_version(int t);
extern EVP_CIPHER_CTX* EVP_CIPHER_CTX_new(void);
extern void            EVP_CIPHER_CTX_free(EVP_CIPHER_CTX*);
extern const EVP_CIPHER* EVP_aes_256_cbc(void);
extern int EVP_EncryptInit_ex(EVP_CIPHER_CTX*, const EVP_CIPHER*, ENGINE*,
                              const unsigned char* key, const unsigned char* iv);
extern int EVP_EncryptUpdate(EVP_CIPHER_CTX*, unsigned char* out, int* outl,
                             const unsigned char* in, int inl);
extern int EVP_EncryptFinal_ex(EVP_CIPHER_CTX*, unsigned char* out, int* outl);
extern int EVP_DecryptInit_ex(EVP_CIPHER_CTX*, const EVP_CIPHER*, ENGINE*,
                              const unsigned char* key, const unsigned char* iv);
extern int EVP_DecryptUpdate(EVP_CIPHER_CTX*, unsigned char* out, int* outl,
                             const unsigned char* in, int inl);
extern int EVP_DecryptFinal_ex(EVP_CIPHER_CTX*, unsigned char* out, int* outl);

#define OPENSSL_VERSION 0

static void tohex(const unsigned char* b, int n, char* out) {
    static const char* H = "0123456789abcdef";
    for (int i = 0; i < n; i++) { out[2*i] = H[b[i] >> 4]; out[2*i+1] = H[b[i] & 0xf]; }
    out[2*n] = '\0';
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        printf("M21-SSLVER-%s\n", OpenSSL_version(OPENSSL_VERSION)); fflush(stdout);

        /* Fixed 32-byte key + 16-byte IV (matches the host openssl vector). */
        unsigned char key[32], iv[16];
        for (int i = 0; i < 32; i++) key[i] = (unsigned char)i;
        for (int i = 0; i < 16; i++) iv[i]  = (unsigned char)i;

        const char* pt = "DARWIN COMPUTA aes round-trip!!";   /* 31 bytes */
        int ptLen = (int)strlen(pt);

        const char* kCipher =
            "7b99647d37fd2150d8bdca1e9f2c45719650f53887881e54f09c9e016108308f";

        /* ---- ENCRYPT ------------------------------------------------------ */
        unsigned char ct[64]; int clen = 0, ctmp = 0;
        EVP_CIPHER_CTX* ec = EVP_CIPHER_CTX_new();
        int encOK = ec
            && EVP_EncryptInit_ex(ec, EVP_aes_256_cbc(), NULL, key, iv) == 1
            && EVP_EncryptUpdate(ec, ct, &clen, (const unsigned char*)pt, ptLen) == 1
            && EVP_EncryptFinal_ex(ec, ct + clen, &ctmp) == 1;
        clen += ctmp;
        if (ec) EVP_CIPHER_CTX_free(ec);
        if (!encOK) { printf("M21-ENC-FAIL\n"); fflush(stdout); printf("M21-DONE\n"); return 0; }

        char ctHex[2*64+1]; tohex(ct, clen, ctHex);
        printf("M21-ENC-LEN-%d\n", clen); fflush(stdout);
        printf("M21-CIPHER-%s\n", ctHex); fflush(stdout);
        printf("M21-CIPHER-%s\n", strcmp(ctHex, kCipher) == 0 ? "OK" : "FAIL"); fflush(stdout);

        int differs = (clen != ptLen) || (memcmp(ct, pt, ptLen) != 0);
        printf("M21-DIFFERS-%s\n", differs ? "OK" : "FAIL"); fflush(stdout);

        /* ---- DECRYPT ------------------------------------------------------ */
        unsigned char rt[64]; int rlen = 0, rtmp = 0;
        EVP_CIPHER_CTX* dc = EVP_CIPHER_CTX_new();
        int decOK = dc
            && EVP_DecryptInit_ex(dc, EVP_aes_256_cbc(), NULL, key, iv) == 1
            && EVP_DecryptUpdate(dc, rt, &rlen, ct, clen) == 1
            && EVP_DecryptFinal_ex(dc, rt + rlen, &rtmp) == 1;
        rlen += rtmp;
        if (dc) EVP_CIPHER_CTX_free(dc);
        if (!decOK) { printf("M21-DEC-FAIL\n"); fflush(stdout); printf("M21-DONE\n"); return 0; }

        printf("M21-DEC-LEN-%d\n", rlen); fflush(stdout);
        int roundtrip = (rlen == ptLen) && (memcmp(rt, pt, ptLen) == 0);
        printf("M21-ROUNDTRIP-%s\n", roundtrip ? "OK" : "FAIL"); fflush(stdout);

        /* Foundation cross-check on the recovered plaintext. */
        NSData* a = [NSData dataWithBytes:pt length:ptLen];
        NSData* b = [NSData dataWithBytes:rt length:rlen];
        printf("M21-NSDATA-%s\n", [a isEqualToData:b] ? "OK" : "FAIL"); fflush(stdout);

        printf("M21-DONE\n"); fflush(stdout);
    }
    return 0;
}
