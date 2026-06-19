/*
 * scancli.m — M23: string tokenizing via NSScanner + UUID generation/round-trip
 * via NSUUID. Two fundamental, deterministic, headless Foundation capabilities:
 * NSScanner underlies hand-rolled parsers / config readers / tokenizers; NSUUID
 * underlies identity, keys, and content addressing. Pure Foundation (the proven M3
 * runtime); no networking.
 *
 * All selectors used here were VERIFIED PRESENT in the staged guest Foundation
 * before authoring (the M22 lesson: check the binary, don't assume a modern API).
 * NSScanner/charactersToBeSkipped pull in NSCharacterSet which (like NSData) is
 * defined in CoreFoundation, so build-scancli.sh links CoreFoundation BY PATH (the
 * M17 finding).
 *
 * NSScanner: from "qty=42 price=19.95 name=Darwin;rest" scan the int after "qty=",
 * the double after "price=", and the token after "name=" up to the ';', then
 * confirm the remaining tail. NSUUID: parse a known UUID string and verify its 16
 * bytes against the authoritative host value, round-trip UUIDString, and confirm a
 * freshly generated +UUID is well-formed (36 chars, 4 dashes) and unique.
 *
 *   M23-SCAN-INT-<n>       scanned int after "qty="   (== 42)
 *   M23-SCAN-DBL-<d>       scanned double after "price=" (== 19.95)
 *   M23-SCAN-TOK-<s>       scanned token after "name=" up to ';' (== "Darwin")
 *   M23-SCAN-TAIL-OK       the remaining text after ';' is "rest" and isAtEnd
 *   M23-UUID-BYTES-<hex>   bytes of the known UUID
 *   M23-UUID-BYTES-OK     == the authoritative host bytes
 *   M23-UUID-ROUNDTRIP-OK  UUIDString of the parsed UUID equals the input
 *   M23-UUID-GEN-OK        a generated +UUID is 36 chars / 4 dashes / differs
 *   M23-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- NSScanner ---------------------------------------------------- */
        NSString* src = @"qty=42 price=19.95 name=Darwin;rest";
        NSScanner* sc = [NSScanner scannerWithString:src];

        int qty = 0;
        [sc scanUpToString:@"qty=" intoString:NULL];
        [sc scanString:@"qty=" intoString:NULL];
        [sc scanInt:&qty];
        printf("M23-SCAN-INT-%d\n", qty); fflush(stdout);

        double price = 0;
        [sc scanUpToString:@"price=" intoString:NULL];
        [sc scanString:@"price=" intoString:NULL];
        [sc scanDouble:&price];
        printf("M23-SCAN-DBL-%.2f\n", price); fflush(stdout);

        NSString* name = nil;
        [sc scanUpToString:@"name=" intoString:NULL];
        [sc scanString:@"name=" intoString:NULL];
        [sc scanUpToString:@";" intoString:&name];
        printf("M23-SCAN-TOK-%s\n", name ? [name UTF8String] : "(nil)"); fflush(stdout);

        [sc scanString:@";" intoString:NULL];
        NSString* tail = nil;
        [sc scanUpToString:@"\n" intoString:&tail];   /* rest of the line */
        BOOL tailOK = tail && [tail isEqualToString:@"rest"] && [sc isAtEnd];
        printf("M23-SCAN-TAIL-%s\n", tailOK ? "OK" : "FAIL"); fflush(stdout);

        /* ---- NSUUID ------------------------------------------------------- */
        const char* kBytes = "0123456789ab4cde8f0123456789abcd";
        NSString* known = @"01234567-89AB-4CDE-8F01-23456789ABCD";
        NSUUID* u = [[NSUUID alloc] initWithUUIDString:known];
        unsigned char b[16]; [u getUUIDBytes:b];
        char hex[33]; static const char* H = "0123456789abcdef";
        for (int i = 0; i < 16; i++) { hex[2*i] = H[b[i] >> 4]; hex[2*i+1] = H[b[i] & 0xf]; }
        hex[32] = '\0';
        printf("M23-UUID-BYTES-%s\n", hex); fflush(stdout);
        printf("M23-UUID-BYTES-%s\n", strcmp(hex, kBytes) == 0 ? "OK" : "FAIL"); fflush(stdout);

        NSString* rt = [u UUIDString];
        printf("M23-UUID-ROUNDTRIP-%s\n",
               (rt && [[rt uppercaseString] isEqualToString:known]) ? "OK" : "FAIL"); fflush(stdout);

        NSString* gen = [[NSUUID UUID] UUIDString];
        int dashes = 0; for (const char* p = [gen UTF8String]; *p; p++) if (*p == '-') dashes++;
        BOOL genOK = gen && [gen length] == 36 && dashes == 4 && ![gen isEqualToString:rt];
        printf("M23-UUID-GEN-%s\n", genOK ? "OK" : "FAIL"); fflush(stdout);

        printf("M23-DONE\n"); fflush(stdout);
    }
    return 0;
}
