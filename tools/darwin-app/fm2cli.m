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
 * enumerator, copy, AND raw POSIX symlink (create + readlink) — the symlink path was
 * fixed in the emulator at M67 (S111): getMode() withheld the write bit for darling
 * guest paths (all under the /usr/libexec/darling chroot prefix, so the /tmp,/var,/home
 * writable heuristic never matched), so symlinkInDirectory's canWrite() gate returned
 * EACCES; M67 strips the darling prefix before the prefix test, so symlink() now works.
 *
 * KNOWN GUEST GAP (non-gating, COCOTRON not substrate): NSFileManager
 * createSymbolicLinkAtPath:link withDestinationPath:dest issues the symlink() syscall
 * with the args SWAPPED (it makes dest->link instead of link->dest; the syscall itself
 * returns 0), so destinationOfSymbolicLinkAtPath:link finds nothing. Proven substrate-
 * correct by the RAW POSIX symlink below succeeding (M66-RAWSYM-0/M66-RAWREAD-a.txt).
 *
 *   M66-SUBPATHS-<n>       subpathsOfDirectoryAtPath: count  (>= 3)
 *   M66-TXTCOUNT-<n>       .txt files via recursive enumeratorAtPath:  (== 2)
 *   M66-COPY-OK           copyItemAtPath: succeeded
 *   M66-COPYREAD-<s>       the copied file's contents  (== "DARWIN")
 *   M66-RAWSYM-0          raw POSIX symlink("a.txt", ".../rawlink") succeeded (M67 fix)
 *   M66-RAWREAD-<s>        readlink(".../rawlink") resolves  (== "a.txt")
 *   M66-SYM-GAP-nocreate  NSFileManager createSymbolicLinkAtPath: arg-swap (Cocotron gap)
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

        /* ---- symbolic link via NSFileManager (KNOWN GAP — non-gating) ----- */
        NSString* link = @"/var/root/m66/link";
        [fm createSymbolicLinkAtPath:link withDestinationPath:@"a.txt" error:NULL];
        NSString* dest = [fm destinationOfSymbolicLinkAtPath:link error:NULL];
        if (dest) {
            printf("M66-SYMDEST-%s\n", [dest UTF8String]); fflush(stdout);
        } else {
            printf("M66-SYM-GAP-nocreate\n"); fflush(stdout);
        }

        /* ---- RAW posix symlink() to bisect Cocotron-wrapper vs VFS -------- */
        extern int symlink(const char* target, const char* linkpath);
        int rs = symlink("a.txt", "/var/root/m66/rawlink");   /* POSIX: link->target */
        printf("M66-RAWSYM-%d\n", rs); fflush(stdout);
        struct { char b[256]; } rb;
        extern long readlink(const char*, char*, unsigned long);
        long n = readlink("/var/root/m66/rawlink", rb.b, 255);
        if (n > 0) { rb.b[n] = 0; printf("M66-RAWREAD-%s\n", rb.b); }
        else printf("M66-RAWREAD-fail-%ld\n", n);
        fflush(stdout);

        printf("M66-DONE\n"); fflush(stdout);
    }
    return 0;
}
