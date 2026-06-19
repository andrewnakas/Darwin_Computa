/*
 * zcli.m — M15: data compression via the staged libz (zlib). A deterministic,
 * headless capability on a proven-style staged C library (like libsqlite3/OpenSSL),
 * needing no networking. Widely used (gzip/zlib is everywhere).
 *
 * Round-trip: take a known input, compress() it, confirm the compressed form is
 * smaller, uncompress() it back, and verify byte-for-byte identity + a crc32 check.
 * The zlib C API is declared extern (no zlib.h staged; ABI is stable). Foundation
 * is linked only for an NSString equality cross-check of the restored data.
 *
 *   M15-ZVER-<v>           zlibVersion() (the lib loaded + runs)
 *   M15-ORIG-<n>           original byte length
 *   M15-COMPRESSED-<n>     compressed byte length (should be < original here)
 *   M15-SMALLER-<0|1>      compressed < original
 *   M15-CRC-<hex>          crc32 of the original
 *   M15-ROUNDTRIP-OK       uncompress(compress(x)) == x (byte-identical)
 *   M15-NSSTRING-OK        the restored bytes equal the original via NSString
 *   M15-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

/* ---- zlib C API (extern; no zlib.h staged) -------------------------------- */
typedef unsigned long uLong;
typedef unsigned char Bytef;
typedef unsigned int uInt;
extern const char* zlibVersion(void);
extern int   compress(Bytef* dest, uLong* destLen, const Bytef* source, uLong sourceLen);
extern int   uncompress(Bytef* dest, uLong* destLen, const Bytef* source, uLong sourceLen);
extern uLong compressBound(uLong sourceLen);
extern uLong crc32(uLong crc, const Bytef* buf, uInt len);
#define Z_OK 0

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        printf("M15-ZVER-%s\n", zlibVersion()); fflush(stdout);

        /* A compressible input (repetitive, so compression clearly shrinks it). */
        char orig[1024];
        for (int i = 0; i < (int)sizeof(orig); i++) orig[i] = "DARWIN_COMPUTA_"[i % 15];
        uLong origLen = sizeof(orig);
        printf("M15-ORIG-%lu\n", origLen); fflush(stdout);

        /* crc32 of the original. */
        uLong crc = crc32(0, (const Bytef*)orig, (uInt)origLen);
        printf("M15-CRC-%08lx\n", crc & 0xffffffffUL); fflush(stdout);

        /* compress(). */
        uLong bound = compressBound(origLen);
        Bytef* comp = (Bytef*)malloc(bound);
        uLong compLen = bound;
        if (compress(comp, &compLen, (const Bytef*)orig, origLen) != Z_OK) {
            printf("M15-COMPRESS-FAIL\n"); fflush(stdout); printf("M15-DONE\n"); return 0;
        }
        printf("M15-COMPRESSED-%lu\n", compLen); fflush(stdout);
        printf("M15-SMALLER-%d\n", (compLen < origLen) ? 1 : 0); fflush(stdout);

        /* uncompress() back and verify byte-identity. */
        Bytef* back = (Bytef*)malloc(origLen + 16);
        uLong backLen = origLen + 16;
        if (uncompress(back, &backLen, comp, compLen) != Z_OK) {
            printf("M15-UNCOMPRESS-FAIL\n"); fflush(stdout); printf("M15-DONE\n"); return 0;
        }
        int identical = (backLen == origLen) && (memcmp(back, orig, origLen) == 0);
        printf("M15-ROUNDTRIP-%s\n", identical ? "OK" : "FAIL"); fflush(stdout);

        /* Foundation cross-check: restored bytes equal the original as NSData/NSString. */
        NSData* a = [NSData dataWithBytes:orig length:origLen];
        NSData* b = [NSData dataWithBytes:back length:backLen];
        printf("M15-NSSTRING-%s\n", [a isEqualToData:b] ? "OK" : "FAIL"); fflush(stdout);

        free(comp); free(back);
        printf("M15-DONE\n"); fflush(stdout);
    }
    return 0;
}
