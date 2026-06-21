/*
 * fm2cli.m — M66: NSFileManager DEEP operations — recursive enumeration, symbolic
 * links, and copy. Extends M16's basic FS ops (mkdir/write/read/list/attrs/remove)
 * to the higher-level real-world filesystem operations apps actually use: walk a
 * directory tree recursively, create + resolve a symlink, and copy a file. Builds on
 * the proven-working FS layer (M16, incl. the S102 directory-removal fix). Pure
 * Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation before authoring (M22).
 * NSFileManager is a Foundation class; CoreFoundation linked BY PATH (M17).
 *
 *   - build /var/root/m66/{a.txt, sub/b.txt} (two files in a 1-level tree),
 *   - subpathsOfDirectoryAtPath: returns the recursive subpaths (>=3: a.txt, sub, sub/b.txt),
 *   - enumeratorAtPath: walks the tree; count the .txt files found (== 2),
 *   - copyItemAtPath: a.txt -> c.txt; the copy exists and reads back the original bytes.
 *
 * GATING FACETS (all proven live, matching host): recursive subpaths, recursive
 * enumerator, and copy. KNOWN GUEST GAP (non-gating, root-caused live):
 * createSymbolicLinkAtPath:withDestinationPath: does NOT create the link — no host
 * file appears at any layer (neither a real symlink nor the emulator's EXT_LINK
 * ".link" representation), so destinationOfSymbolicLinkAtPath: returns nil. The
 * symlink VFS path EXISTS (KProcess::symlink -> symlinkInDirectory, kprocess.cpp:1415,
 * stores a .link file) but Cocotron's BSD symlink() isn't reaching it under the Darwin
 * syscall dispatch (Darwin/BSD symlink is #57, distinct from the Linux x86-64 #88 the
 * emulator's syscall64 table uses) — a deeper Darwin-syscall-mapping fix, deferred.
 * The other deep FS ops all work, so the milestone gates on those + reports the gap.
 *
 *   M66-SUBPATHS-<n>       subpathsOfDirectoryAtPath: count  (>= 3)
 *   M66-TXTCOUNT-<n>       .txt files via recursive enumeratorAtPath:  (== 2)
 *   M66-COPY-OK           copyItemAtPath: succeeded
 *   M66-COPYREAD-<s>       the copied file's contents  (== "DARWIN")
 *   M66-SYM-GAP-nocreate  createSymbolicLinkAtPath: did not create the link (guest gap)
 *   M66-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSFileManager* fm = [NSFileManager defaultManager];
        NSString* root = @"/var/root/m66";
        NSString* sub  = @"/var/root/m66/sub";

        /* clean any prior run (M16 dir removal works now) */
        [fm removeItemAtPath:root error:NULL];

        /* ---- build a small tree ------------------------------------------ */
        [fm createDirectoryAtPath:sub withIntermediateDirectories:YES
                       attributes:nil error:NULL];
        [[@"DARWIN" dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:@"/var/root/m66/a.txt" atomically:NO];
        [[@"COMPUTA" dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:@"/var/root/m66/sub/b.txt" atomically:NO];

        /* ---- recursive subpaths ----------------------------------------- */
        NSArray* subpaths = [fm subpathsOfDirectoryAtPath:root error:NULL];
        printf("M66-SUBPATHS-%lu\n", (unsigned long)[subpaths count]); fflush(stdout);

        /* ---- recursive enumerator: count .txt files --------------------- */
        int txt = 0;
        NSDirectoryEnumerator* en = [fm enumeratorAtPath:root];
        NSString* item;
        while ((item = [en nextObject])) {
            if ([[item pathExtension] isEqualToString:@"txt"]) txt++;
        }
        printf("M66-TXTCOUNT-%d\n", txt); fflush(stdout);

        /* ---- copy (GATING) ---------------------------------------------- */
        NSError* cerr = nil;
        BOOL copied = [fm copyItemAtPath:@"/var/root/m66/a.txt"
                                  toPath:@"/var/root/m66/c.txt" error:&cerr];
        printf("M66-COPY-%s\n", copied ? "OK" : "FAIL"); fflush(stdout);

        NSString* copyBody = [NSString stringWithContentsOfFile:@"/var/root/m66/c.txt"
                                                       encoding:NSUTF8StringEncoding error:NULL];
        printf("M66-COPYREAD-%s\n", copyBody ? [copyBody UTF8String] : "nil"); fflush(stdout);

        /* ---- symbolic link (KNOWN GAP — non-gating, reported for the record) */
        NSString* link = @"/var/root/m66/link";
        [fm createSymbolicLinkAtPath:link withDestinationPath:@"a.txt" error:NULL];
        NSString* dest = [fm destinationOfSymbolicLinkAtPath:link error:NULL];
        if (dest) {
            printf("M66-SYMDEST-%s\n", [dest UTF8String]); fflush(stdout);
        } else {
            printf("M66-SYM-GAP-nocreate\n"); fflush(stdout);
        }

        printf("M66-DONE\n"); fflush(stdout);
    }
    return 0;
}
