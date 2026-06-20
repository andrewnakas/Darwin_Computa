/*
 * fhcli.m — M37: descriptor-level file I/O via NSFileHandle. Complements M16
 * (NSFileManager path ops) and M30 (in-memory NSData) with streaming read/write/seek
 * over a real on-disk file descriptor — the layer logs, readers, and stream parsers
 * use. Pure Foundation (the proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSFileHandle is a Foundation class; we still link
 * CoreFoundation BY PATH (M17) since NSData / strings touch CF.
 *
 * Note: avoids removeItemAtPath: (the M16 documented removal gap) — uses a fresh
 * path and a clean-via-NSData-overwrite where needed, and does not assert deletion.
 *
 *   - WRITE: create the file (NSData writeToFile), open a writing handle, write
 *     "DARWIN" then " COMPUTA" (two writeData: calls) -> file holds "DARWIN COMPUTA",
 *   - READ-ALL: a reading handle readDataToEndOfFile -> "DARWIN COMPUTA",
 *   - SEEK + PARTIAL: seekToFileOffset:7 then readDataOfLength:7 -> "COMPUTA",
 *   - OFFSET: offsetInFile after the partial read == 14.
 *
 *   M37-WRITE-OK           write handle wrote the two chunks
 *   M37-READALL-<s>        readDataToEndOfFile  (== "DARWIN COMPUTA")
 *   M37-SEEKREAD-<s>       seek to 7 + readDataOfLength:7  (== "COMPUTA")
 *   M37-OFFSET-<n>         offsetInFile after the partial read  (== 14)
 *   M37-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

static NSString* dataStr(NSData* d) {
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSString* path = @"/var/root/m37.txt";
        NSFileManager* fm = [NSFileManager defaultManager];

        /* Ensure the file exists + is empty (NSData write — proven in M16). */
        [[NSData data] writeToFile:path atomically:NO];

        /* ---- WRITE via a writing file handle ------------------------------ */
        NSFileHandle* wh = [NSFileHandle fileHandleForWritingAtPath:path];
        int wok = 0;
        if (wh) {
            [wh writeData:[@"DARWIN" dataUsingEncoding:NSUTF8StringEncoding]];
            [wh writeData:[@" COMPUTA" dataUsingEncoding:NSUTF8StringEncoding]];
            [wh closeFile];
            wok = 1;
        }
        printf("M37-WRITE-%s\n", wok ? "OK" : "FAIL"); fflush(stdout);

        /* ---- READ ALL via a reading file handle --------------------------- */
        NSFileHandle* rh = [NSFileHandle fileHandleForReadingAtPath:path];
        NSData* all = rh ? [rh readDataToEndOfFile] : nil;
        printf("M37-READALL-%s\n", all ? [dataStr(all) UTF8String] : "(nil)"); fflush(stdout);
        [rh closeFile];

        /* ---- SEEK + PARTIAL READ ------------------------------------------ */
        NSFileHandle* rh2 = [NSFileHandle fileHandleForReadingAtPath:path];
        unsigned long long off = 0;
        NSData* part = nil;
        if (rh2) {
            [rh2 seekToFileOffset:7];
            part = [rh2 readDataOfLength:7];
            off = [rh2 offsetInFile];
            [rh2 closeFile];
        }
        printf("M37-SEEKREAD-%s\n", part ? [dataStr(part) UTF8String] : "(nil)"); fflush(stdout);
        printf("M37-OFFSET-%llu\n", off); fflush(stdout);

        /* leave the file in place (avoid the M16 removeItemAtPath gap). */
        (void)fm;
        printf("M37-DONE\n"); fflush(stdout);
    }
    return 0;
}
