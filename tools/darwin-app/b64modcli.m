/*
 * b64modcli.m — M74: MODERN NSData Base64 API. M22 proved the LEGACY base64 path; this
 * confirms the modern, standard API real code uses: base64EncodedStringWithOptions: /
 * initWithBase64EncodedString:options: / initWithBase64EncodedData:options:. Encode
 * bytes to a base64 string, decode back to identical bytes, and decode from an NSData
 * holding base64 text. Pure Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). NSData is
 * Foundation; CoreFoundation linked BY PATH (M17). The encoded string is checked
 * against the authoritative host value (host `base64` of "Darwin Computa").
 *
 *   - base64EncodedStringWithOptions:0 of "Darwin Computa" -> "RGFyd2luIENvbXB1dGE=",
 *   - initWithBase64EncodedString:options:0 -> bytes == original "Darwin Computa",
 *   - initWithBase64EncodedData:options:0 (decode from an NSData of the b64 text) -> same.
 *
 *   M74-ENC-<s>            base64EncodedStringWithOptions: result
 *   M74-ENC-OK            == "RGFyd2luIENvbXB1dGE=" (authoritative host value)
 *   M74-DEC-<s>            initWithBase64EncodedString: decoded back  (== "Darwin Computa")
 *   M74-ROUNDTRIP-OK      decoded bytes byte-identical to the original
 *   M74-DECDATA-OK        initWithBase64EncodedData: (decode from NSData) matches too
 *   M74-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        const char* orig = "Darwin Computa";
        NSData* src = [NSData dataWithBytes:orig length:strlen(orig)];

        /* ---- encode ----------------------------------------------------- */
        NSString* enc = [src base64EncodedStringWithOptions:0];
        printf("M74-ENC-%s\n", [enc UTF8String]); fflush(stdout);
        const char* kHost = "RGFyd2luIENvbXB1dGE=";
        printf("M74-ENC-%s\n", [enc isEqualToString:[NSString stringWithUTF8String:kHost]] ? "OK" : "FAIL"); fflush(stdout);

        /* ---- decode from string ----------------------------------------- */
        NSData* dec = [[NSData alloc] initWithBase64EncodedString:enc options:0];
        NSString* decStr = [[NSString alloc] initWithData:dec encoding:NSUTF8StringEncoding];
        printf("M74-DEC-%s\n", [decStr UTF8String]); fflush(stdout);
        BOOL rt = ([dec length] == strlen(orig) &&
                   memcmp([dec bytes], orig, strlen(orig)) == 0);
        printf("M74-ROUNDTRIP-%s\n", rt ? "OK" : "FAIL"); fflush(stdout);

        /* ---- decode from NSData holding the base64 text ----------------- */
        NSData* b64data = [enc dataUsingEncoding:NSUTF8StringEncoding];
        NSData* dec2 = [[NSData alloc] initWithBase64EncodedData:b64data options:0];
        BOOL ok2 = (dec2 && [dec2 length] == strlen(orig) &&
                    memcmp([dec2 bytes], orig, strlen(orig)) == 0);
        printf("M74-DECDATA-%s\n", ok2 ? "OK" : "FAIL"); fflush(stdout);

        printf("M74-DONE\n"); fflush(stdout);
    }
    return 0;
}
