/*
 * b64cli.m — M22: Base64 + URL percent-encoding via Foundation. A fundamental,
 * deterministic, headless capability (Base64 underlies data URIs / auth headers /
 * MIME; percent-encoding underlies every URL). Pure Foundation (the proven M3
 * runtime); no networking, no third-party C lib.
 *
 * This milestone EXERCISES the M17 CoreFoundation-by-path finding for a real
 * capability: NSData and NSCharacterSet are DEFINED in CoreFoundation and only
 * imported into Foundation, which re-exports CF. Linking CoreFoundation BY PATH
 * (see build-b64cli.sh) makes them resolve. We use NSCharacterSet (the exact class
 * that was the original M8 blocker) via the long-present +characterSetWithCharacters
 * InString: / -characterIsMember: selectors, proving the CF link on that class.
 *
 * KEY GUEST API FINDING: this Darling/Cocotron Foundation predates the OS X 10.9
 * percent-encoding API. +[NSCharacterSet URLQueryAllowedCharacterSet] and
 * -[NSString stringByAddingPercentEncodingWithAllowedCharacters:] are ABSENT (an
 * initial version of this probe threw "+[NSCharacterSet URLQueryAllowedCharacterSet]:
 * unrecognized selector"). But the LEGACY percent-escape API IS present:
 * -stringByAddingPercentEscapesUsingEncoding: and
 * -stringByReplacingPercentEscapesUsingEncoding:. We use those — still a real URL
 * percent-encoding round trip on the API the guest actually ships.
 *
 * Round trips verified against authoritative host values:
 *   - Base64 ENCODE "DARWIN COMPUTA" via -[NSData base64EncodedStringWithOptions:],
 *   - Base64 DECODE that string via -[NSData initWithBase64EncodedString:options:]
 *     and confirm byte-identity with the original,
 *   - NSCharacterSet membership check (proves the class works in-guest),
 *   - LEGACY percent-ENCODE "a b/c?d#e é" via stringByAddingPercentEscapes, then
 *     percent-DECODE it back and confirm identity with the original.
 *
 *   M22-B64-<s>            base64 of "DARWIN COMPUTA"
 *   M22-B64-OK            == the known base64 (REFSV0lOIENPTVBVVEE=)
 *   M22-B64-DECODE-OK     decode(encode(x)) == x (byte-identical NSData)
 *   M22-CSET-OK          NSCharacterSet membership works ('/' in the set, 'a' not)
 *   M22-PCT-<s>           legacy percent-encoded "a b/c?d#e é"
 *   M22-PCT-OK           == the known encoding (a%20b/c?d%23e%20%C3%A9)
 *   M22-PCT-DECODE-OK    percent-decode round-trips back to the original
 *   M22-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        const char* kB64 = "REFSV0lOIENPTVBVVEE=";
        const char* kPct = "a%20b/c?d%23e%20%C3%A9";

        /* ---- Base64 encode ------------------------------------------------ */
        NSString* plain = @"DARWIN COMPUTA";
        NSData* pd = [plain dataUsingEncoding:NSUTF8StringEncoding];
        NSString* b64 = [pd base64EncodedStringWithOptions:0];
        printf("M22-B64-%s\n", [b64 UTF8String]); fflush(stdout);
        printf("M22-B64-%s\n", [b64 isEqualToString:[NSString stringWithUTF8String:kB64]] ? "OK" : "FAIL");
        fflush(stdout);

        /* ---- Base64 decode (round trip) ----------------------------------- */
        NSData* decoded = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        printf("M22-B64-DECODE-%s\n", (decoded && [decoded isEqualToData:pd]) ? "OK" : "FAIL");
        fflush(stdout);

        /* ---- NSCharacterSet membership (the M17 CF-link proof on this class) --
         * Use the long-present +characterSetWithCharactersInString: (the guest's
         * Foundation predates the URL*AllowedCharacterSet factories — see header). */
        NSCharacterSet* cset = [NSCharacterSet characterSetWithCharactersInString:@"/?#"];
        BOOL memberSlash = [cset characterIsMember:'/'];
        BOOL memberA     = [cset characterIsMember:'a'];
        printf("M22-CSET-%s\n", (memberSlash && !memberA) ? "OK" : "FAIL"); fflush(stdout);

        /* ---- LEGACY URL percent-encode (the API the guest actually ships) --- */
        NSString* raw = @"a b/c?d#e é";
        NSString* pct = [raw stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        printf("M22-PCT-%s\n", pct ? [pct UTF8String] : "(nil)"); fflush(stdout);
        printf("M22-PCT-%s\n", (pct && [pct isEqualToString:[NSString stringWithUTF8String:kPct]]) ? "OK" : "FAIL");
        fflush(stdout);

        /* ---- percent-decode (round trip) ---------------------------------- */
        NSString* back = [pct stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        printf("M22-PCT-DECODE-%s\n", (back && [back isEqualToString:raw]) ? "OK" : "FAIL");
        fflush(stdout);

        printf("M22-DONE\n"); fflush(stdout);
    }
    return 0;
}
