/*
 * plist2cli.m — M80: NSPropertyListSerialization XML + binary round-trip + format
 * DETECTION. Goes deeper than M25 (which proved a binary-plist round trip): serialize the
 * SAME dictionary to BOTH the XML and binary plist formats, read each back, and confirm the
 * reader reports WHICH format it parsed (the format out-param) — the mechanism behind every
 * .plist config file on macOS. Pure Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). NSPropertyList-
 * Serialization is Foundation; CoreFoundation linked BY PATH (M17). Gating on STRUCTURAL
 * facts (round-trip equality + format-detect value + XML-is-readable), NOT exact byte
 * lengths (encoding overhead can differ from host, per the M25 lesson).
 *
 * NSPropertyListXMLFormat_v1_0 = 100 ; NSPropertyListBinaryFormat_v1_0 = 200.
 *
 *   - dict {name:darwin, count:42, items:[a,b]} -> XML data starting "<?xml",
 *   - read XML back: format out-param == 100, dict deep-equal,
 *   - same dict -> binary data, read back: format out-param == 200, dict deep-equal.
 *
 *   M80-XMLHEAD-1          XML serialization begins with "<?xml" (human-readable plist)
 *   M80-XMLFMT-100         reading the XML back reports format 100 (XML_v1_0)
 *   M80-XMLEQ-OK           XML round trip is deep-equal to the original dict
 *   M80-BINFMT-200         reading the binary back reports format 200 (Binary_v1_0)
 *   M80-BINEQ-OK           binary round trip is deep-equal to the original dict
 *   M80-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

/* format enum values (stable Foundation constants) */
enum { M_XML = 100, M_BIN = 200 };

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSDictionary* d = [NSDictionary dictionaryWithObjectsAndKeys:
                           @"darwin", @"name",
                           @42,       @"count",
                           [NSArray arrayWithObjects:@"a", @"b", nil], @"items",
                           nil];

        /* ---- XML format serialize -------------------------------------- */
        NSData* xml = [NSPropertyListSerialization dataWithPropertyList:d
                          format:M_XML options:0 error:NULL];
        NSString* xmlStr = [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];
        printf("M80-XMLHEAD-%d\n", [xmlStr hasPrefix:@"<?xml"] ? 1 : 0); fflush(stdout);

        /* ---- read XML back + detect format ----------------------------- */
        NSPropertyListFormat xfmt = 0;
        NSDictionary* xback = [NSPropertyListSerialization propertyListWithData:xml
                                  options:0 format:&xfmt error:NULL];
        printf("M80-XMLFMT-%d\n", (int)xfmt); fflush(stdout);
        printf("M80-XMLEQ-%s\n", [xback isEqualToDictionary:d] ? "OK" : "FAIL"); fflush(stdout);

        /* ---- binary format serialize + read back + detect -------------- */
        NSData* bin = [NSPropertyListSerialization dataWithPropertyList:d
                          format:M_BIN options:0 error:NULL];
        NSPropertyListFormat bfmt = 0;
        NSDictionary* bback = [NSPropertyListSerialization propertyListWithData:bin
                                  options:0 format:&bfmt error:NULL];
        printf("M80-BINFMT-%d\n", (int)bfmt); fflush(stdout);
        printf("M80-BINEQ-%s\n", [bback isEqualToDictionary:d] ? "OK" : "FAIL"); fflush(stdout);

        printf("M80-DONE\n"); fflush(stdout);
    }
    return 0;
}
