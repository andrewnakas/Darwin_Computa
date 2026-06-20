/*
 * scan2cli.m — M52: deeper NSScanner scanning — float, hex int, long long, and
 * character-set based scanning. Extends M23 (int/double/token) to the numeric-format
 * and charset-driven scanning paths used by config/format parsers. Pure Foundation
 * (the proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSScanner pulls in NSCharacterSet (CF-resident), so
 * build-scan2cli.sh links CoreFoundation BY PATH (the M17 finding).
 *
 *   - scanFloat: on "3.14rest" -> 3.14,
 *   - scanHexInt: on "0x2A" -> 42 (0x2a),
 *   - scanLongLong: on "9000000000" -> 9000000000 (> 32-bit),
 *   - scanCharactersFromSet: letters on "abcDEF123" -> "abcDEF" (stops at digit),
 *   - scanUpToCharactersFromSet: digits on "name=123" -> "name=" (up to first digit).
 *
 *   M52-FLOAT-<f>          scanFloat: of "3.14rest"  (== 3.14)
 *   M52-HEX-<n>            scanHexInt: of "0x2A"  (== 42)
 *   M52-LL-<n>             scanLongLong: of "9000000000"  (== 9000000000)
 *   M52-CHARS-<s>          scanCharactersFromSet:letters on "abcDEF123"  (== "abcDEF")
 *   M52-UPTO-<s>           scanUpToCharactersFromSet:digits on "name=123"  (== "name=")
 *   M52-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- scanFloat: --------------------------------------------------- */
        float fv = 0;
        [[NSScanner scannerWithString:@"3.14rest"] scanFloat:&fv];
        printf("M52-FLOAT-%.2f\n", fv); fflush(stdout);

        /* ---- scanHexInt: -------------------------------------------------- */
        unsigned int hx = 0;
        [[NSScanner scannerWithString:@"0x2A"] scanHexInt:&hx];
        printf("M52-HEX-%u\n", hx); fflush(stdout);

        /* ---- scanLongLong: (> 32-bit) ------------------------------------- */
        long long ll = 0;
        [[NSScanner scannerWithString:@"9000000000"] scanLongLong:&ll];
        printf("M52-LL-%lld\n", ll); fflush(stdout);

        /* ---- scanCharactersFromSet: letters ------------------------------- */
        NSScanner* sc = [NSScanner scannerWithString:@"abcDEF123"];
        NSString* letters = nil;
        [sc scanCharactersFromSet:[NSCharacterSet letterCharacterSet] intoString:&letters];
        printf("M52-CHARS-%s\n", letters ? [letters UTF8String] : "(nil)"); fflush(stdout);

        /* ---- scanUpToCharactersFromSet: digits ---------------------------- */
        NSScanner* sc2 = [NSScanner scannerWithString:@"name=123"];
        NSString* upto = nil;
        [sc2 scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:&upto];
        printf("M52-UPTO-%s\n", upto ? [upto UTF8String] : "(nil)"); fflush(stdout);

        printf("M52-DONE\n"); fflush(stdout);
    }
    return 0;
}
