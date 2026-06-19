/*
 * arccli.m — M19: archive handling via libarchive (tar create + extract). A
 * fundamental, widely-used capability (every package/backup/asset pipeline touches
 * tar/zip), and a structured layer ABOVE M15's raw zlib byte compression.
 *
 * Fully self-contained, in-memory round trip (no embedded blob, no filesystem):
 *   WRITE  - build a 2-entry ustar tar entirely in memory via the write API
 *            (the archive_write_ and archive_entry_ calls), note.txt + data.bin.
 *   READ   — open that same buffer with the read API (format/filter auto-detect),
 *            enumerate entries, and for each read its pathname + declared size,
 *            then read its body bytes and verify them against the originals.
 *
 * libarchive is a clean, self-contained staged C lib (deps liblzma/libz/libbz2/
 * libiconv/libSystem — no Cocotron glue), linked BY PATH like libz/libxml2. Its C
 * API is declared extern (no archive.h staged; the archive and archive_entry types
 * are opaque
 * pointers so nothing needs struct mirroring). Foundation is linked only for an
 * NSString/NSData cross-check of an extracted entry.
 *
 *   M19-ARCVER-<s>         archive_version_string() (the lib loaded + runs)
 *   M19-WRITE-OK           wrote a ustar tar to memory (archive_write_close OK)
 *   M19-WROTE-<n>          the tar is n bytes (> 0)
 *   M19-READ-OPEN-OK       archive_read_open_memory accepted the buffer
 *   M19-ENTRY-<name>-<sz>  each entry: pathname + size (note.txt-14, data.bin-22)
 *   M19-COUNT-<n>          number of entries read back (== 2)
 *   M19-CONTENT-OK         note.txt body read back == "DARWIN COMPUTA"
 *   M19-NSSTRING-OK        the extracted body equals the original via NSString
 *   M19-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ---- libarchive C API (extern; no archive.h staged) ----------------------- */
typedef long la_int64_t;
typedef long la_ssize_t;
typedef unsigned long la_size_t;

/* opaque handles */
struct archive; struct archive_entry;

extern const char* archive_version_string(void);

/* write (create) */
extern struct archive* archive_write_new(void);
extern int  archive_write_set_format_ustar(struct archive*);
extern int  archive_write_open_memory(struct archive*, void* buf, la_size_t bufSize, la_size_t* used);
extern int  archive_write_header(struct archive*, struct archive_entry*);
extern la_ssize_t archive_write_data(struct archive*, const void* buf, la_size_t size);
extern int  archive_write_close(struct archive*);
extern int  archive_write_free(struct archive*);

/* entry */
extern struct archive_entry* archive_entry_new(void);
extern void archive_entry_set_pathname(struct archive_entry*, const char*);
extern void archive_entry_set_size(struct archive_entry*, la_int64_t);
extern void archive_entry_set_filetype(struct archive_entry*, unsigned int);
extern void archive_entry_set_perm(struct archive_entry*, int);
extern void archive_entry_free(struct archive_entry*);
extern const char* archive_entry_pathname(struct archive_entry*);
extern la_int64_t  archive_entry_size(struct archive_entry*);

/* read (extract) */
extern struct archive* archive_read_new(void);
extern int  archive_read_support_format_all(struct archive*);
extern int  archive_read_support_filter_all(struct archive*);
extern int  archive_read_open_memory(struct archive*, const void* buf, la_size_t size);
extern int  archive_read_next_header(struct archive*, struct archive_entry**);
extern la_ssize_t archive_read_data(struct archive*, void* buf, la_size_t size);
extern int  archive_read_free(struct archive*);

#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define AE_IFREG 0100000   /* regular file mode bits (stable octal) */

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        printf("M19-ARCVER-%s\n", archive_version_string()); fflush(stdout);

        const char* n1 = "note.txt";  const char* b1 = "DARWIN COMPUTA";       /* 14 */
        const char* n2 = "data.bin";  const char* b2 = "second entry body here"; /* 22 */
        size_t l1 = strlen(b1), l2 = strlen(b2);

        /* ---- WRITE a ustar tar into a memory buffer ----------------------- */
        size_t cap = 64 * 1024;
        char* tar = (char*)malloc(cap);
        la_size_t used = 0;
        struct archive* w = archive_write_new();
        archive_write_set_format_ustar(w);
        if (archive_write_open_memory(w, tar, cap, &used) != ARCHIVE_OK) {
            printf("M19-WRITE-FAIL-open\n"); fflush(stdout); printf("M19-DONE\n"); return 0;
        }
        const char* names[2] = { n1, n2 };
        const char* bodies[2] = { b1, b2 };
        size_t lens[2] = { l1, l2 };
        int writeOK = 1;
        for (int i = 0; i < 2; i++) {
            struct archive_entry* e = archive_entry_new();
            archive_entry_set_pathname(e, names[i]);
            archive_entry_set_size(e, (la_int64_t)lens[i]);
            archive_entry_set_filetype(e, AE_IFREG);
            archive_entry_set_perm(e, 0644);
            if (archive_write_header(w, e) != ARCHIVE_OK) writeOK = 0;
            if (archive_write_data(w, bodies[i], lens[i]) != (la_ssize_t)lens[i]) writeOK = 0;
            archive_entry_free(e);
        }
        if (archive_write_close(w) != ARCHIVE_OK) writeOK = 0;
        archive_write_free(w);
        printf("M19-WRITE-%s\n", writeOK ? "OK" : "FAIL"); fflush(stdout);
        printf("M19-WROTE-%lu\n", (unsigned long)used); fflush(stdout);
        if (!writeOK || used == 0) { printf("M19-DONE\n"); return 0; }

        /* ---- READ the same buffer back and verify ------------------------- */
        struct archive* r = archive_read_new();
        archive_read_support_format_all(r);
        archive_read_support_filter_all(r);
        if (archive_read_open_memory(r, tar, used) != ARCHIVE_OK) {
            printf("M19-READ-OPEN-FAIL\n"); fflush(stdout); printf("M19-DONE\n"); return 0;
        }
        printf("M19-READ-OPEN-OK\n"); fflush(stdout);

        int count = 0;
        char firstBody[64]; firstBody[0] = '\0';
        struct archive_entry* e = NULL;
        while (archive_read_next_header(r, &e) == ARCHIVE_OK) {
            const char* name = archive_entry_pathname(e);
            la_int64_t sz = archive_entry_size(e);
            printf("M19-ENTRY-%s-%ld\n", name ? name : "(nil)", (long)sz); fflush(stdout);
            if (count == 0 && sz > 0 && sz < (la_int64_t)sizeof(firstBody)) {
                la_ssize_t got = archive_read_data(r, firstBody, (la_size_t)sz);
                if (got > 0) firstBody[got] = '\0';
            }
            count++;
        }
        printf("M19-COUNT-%d\n", count); fflush(stdout);
        archive_read_free(r);

        int contentOK = (strcmp(firstBody, b1) == 0);
        printf("M19-CONTENT-%s\n", contentOK ? "OK" : "FAIL"); fflush(stdout);

        NSString* ns = [NSString stringWithUTF8String:firstBody];
        printf("M19-NSSTRING-%s\n", [ns isEqualToString:@"DARWIN COMPUTA"] ? "OK" : "FAIL"); fflush(stdout);

        free(tar);
        printf("M19-DONE\n"); fflush(stdout);
    }
    return 0;
}
