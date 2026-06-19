/*
 * urlcli.m — M27: filesystem-path manipulation via NSString path methods + URL
 * parsing/composition via NSURL. A fundamental, deterministic, headless Foundation
 * capability (every file/asset/link operation decomposes paths and URLs). Pure
 * Foundation (the proven M3 runtime); no networking — NSURL here is pure parsing,
 * not fetching. Complements M16 (NSFileManager).
 *
 * All selectors used here were VERIFIED PRESENT in the staged guest Foundation
 * before authoring (the M22 lesson). NSURL is CF-resident, so build-urlcli.sh links
 * CoreFoundation BY PATH (the M17 finding).
 *
 *   - NSString path ops on "/usr/local/bin/darwin.app":
 *       lastPathComponent, pathExtension, stringByDeletingLastPathComponent,
 *       stringByAppendingPathComponent:, pathComponents count,
 *   - NSURL parse of "https://example.com:8080/a/b/file.json?q=1":
 *       scheme/host/path/lastPathComponent,
 *   - NSURL file URL compose: fileURLWithPath: + URLByAppendingPathComponent:.
 *
 *   M27-LAST-<s>           lastPathComponent  (== "darwin.app")
 *   M27-EXT-<s>            pathExtension      (== "app")
 *   M27-DELLAST-<s>        deleting last component (== "/usr/local/bin")
 *   M27-APPEND-<s>         appending "Contents" (== "/usr/local/bin/darwin.app/Contents")
 *   M27-NCOMP-<n>          pathComponents count (== 5: "/","usr","local","bin","darwin.app")
 *   M27-URL-SCHEME-<s>     parsed URL scheme (== "https")
 *   M27-URL-HOST-<s>       parsed URL host   (== "example.com")
 *   M27-URL-PATH-<s>       parsed URL path   (== "/a/b/file.json")
 *   M27-URL-LAST-<s>       parsed URL lastPathComponent (== "file.json")
 *   M27-FILEURL-OK         fileURLWithPath:+append yields the expected path
 *   M27-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- NSString path manipulation ----------------------------------- */
        NSString* p = @"/usr/local/bin/darwin.app";
        printf("M27-LAST-%s\n", [[p lastPathComponent] UTF8String]); fflush(stdout);
        printf("M27-EXT-%s\n", [[p pathExtension] UTF8String]); fflush(stdout);
        printf("M27-DELLAST-%s\n", [[p stringByDeletingLastPathComponent] UTF8String]); fflush(stdout);
        printf("M27-APPEND-%s\n", [[p stringByAppendingPathComponent:@"Contents"] UTF8String]); fflush(stdout);
        printf("M27-NCOMP-%lu\n", (unsigned long)[[p pathComponents] count]); fflush(stdout);

        /* ---- NSURL parse -------------------------------------------------- */
        NSURL* u = [NSURL URLWithString:@"https://example.com:8080/a/b/file.json?q=1"];
        printf("M27-URL-SCHEME-%s\n", [[u scheme] UTF8String]); fflush(stdout);
        printf("M27-URL-HOST-%s\n", [[u host] UTF8String]); fflush(stdout);
        printf("M27-URL-PATH-%s\n", [[u path] UTF8String]); fflush(stdout);
        printf("M27-URL-LAST-%s\n", [[u lastPathComponent] UTF8String]); fflush(stdout);

        /* ---- NSURL file URL compose --------------------------------------- */
        NSURL* base = [NSURL fileURLWithPath:@"/tmp/darwin"];
        NSURL* child = [base URLByAppendingPathComponent:@"data.bin"];
        BOOL fileOK = child && [[child path] isEqualToString:@"/tmp/darwin/data.bin"];
        printf("M27-FILEURL-%s\n", fileOK ? "OK" : "FAIL"); fflush(stdout);

        printf("M27-DONE\n"); fflush(stdout);
    }
    return 0;
}
