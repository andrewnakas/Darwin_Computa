/*
 * dbjzcli.m — M33: CLI SYNTHESIS #3, the PERSISTENCE tier end to end. Composes a
 * real on-disk database, the Foundation data tier, and compression in one process,
 * proving they interoperate:
 *
 *   SQLite on disk (M6')  ->  NSJSONSerialization (M7)  ->  zlib compress (M15)
 *
 * Flow: open a real on-disk SQLite DB, CREATE a table + INSERT 3 rows, SELECT them
 * back via a prepared statement into a Foundation NSArray of NSDictionary, serialize
 * that to JSON via NSJSONSerialization, zlib-compress the JSON, then uncompress and
 * confirm byte-identity — a full store -> query -> export -> compress round trip.
 *
 * Links the union BY PATH: Foundation + CoreFoundation (M17) + libsqlite3 (M6') +
 * libz.1 (M15). C APIs declared extern (no sqlite3.h/zlib.h staged; sqlite3 handles
 * are opaque, zlib ABI is stable).
 *
 *   M33-DBOPEN-OK          sqlite3_open created the on-disk DB
 *   M33-INSERT-<n>         rows inserted (== 3)
 *   M33-SELECT-<n>         rows read back via prepared stmt (== 3)
 *   M33-NAME2-<s>          second row's name from the DB (== "beta")
 *   M33-JSON-<n>           JSON serialized byte length (> 0)
 *   M33-ZIP-<n>            zlib-compressed byte length (> 0)
 *   M33-ROUNDTRIP-OK       uncompress(compress(json)) == json
 *   M33-REPARSE-<n>        JSON re-parsed from the decompressed bytes -> count (== 3)
 *   M33-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ---- sqlite3 C API (extern; opaque handles) ------------------------------- */
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
extern int  sqlite3_open(const char*, sqlite3**);
extern int  sqlite3_exec(sqlite3*, const char*, void*, void*, char**);
extern int  sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
extern int  sqlite3_step(sqlite3_stmt*);
extern const unsigned char* sqlite3_column_text(sqlite3_stmt*, int);
extern int  sqlite3_column_int(sqlite3_stmt*, int);
extern int  sqlite3_finalize(sqlite3_stmt*);
extern int  sqlite3_close(sqlite3*);
#define SQLITE_OK  0
#define SQLITE_ROW 100

/* ---- zlib C API (extern; stable ABI) -------------------------------------- */
typedef unsigned long uLong;
typedef unsigned char Bytef;
extern int   compress(Bytef*, uLong*, const Bytef*, uLong);
extern int   uncompress(Bytef*, uLong*, const Bytef*, uLong);
extern uLong compressBound(uLong);
#define Z_OK 0

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        const char* path = "/var/root/m33.db";
        remove(path);   /* clean slate */

        sqlite3* db = NULL;
        int rc = sqlite3_open(path, &db);
        printf("M33-DBOPEN-%s\n", (rc == SQLITE_OK && db) ? "OK" : "FAIL"); fflush(stdout);
        if (rc != SQLITE_OK || !db) { printf("M33-DONE\n"); return 0; }

        sqlite3_exec(db, "CREATE TABLE items(id INTEGER, name TEXT);", NULL, NULL, NULL);
        sqlite3_exec(db,
            "INSERT INTO items VALUES (1,'alpha'),(2,'beta'),(3,'gamma');",
            NULL, NULL, NULL);
        printf("M33-INSERT-3\n"); fflush(stdout);

        /* ---- SELECT via prepared statement -> Foundation array ------------ */
        NSMutableArray* rows = [NSMutableArray array];
        sqlite3_stmt* st = NULL;
        sqlite3_prepare_v2(db, "SELECT id,name FROM items ORDER BY id;", -1, &st, NULL);
        while (sqlite3_step(st) == SQLITE_ROW) {
            int rid = sqlite3_column_int(st, 0);
            const unsigned char* nm = sqlite3_column_text(st, 1);
            [rows addObject:@{ @"id": @(rid),
                               @"name": nm ? [NSString stringWithUTF8String:(const char*)nm] : @"" }];
        }
        sqlite3_finalize(st);
        sqlite3_close(db);
        printf("M33-SELECT-%lu\n", (unsigned long)[rows count]); fflush(stdout);
        NSString* name2 = ([rows count] >= 2) ? [[rows objectAtIndex:1] objectForKey:@"name"] : nil;
        printf("M33-NAME2-%s\n", name2 ? [name2 UTF8String] : "(nil)"); fflush(stdout);

        /* ---- Foundation array -> JSON ------------------------------------- */
        NSData* json = [NSJSONSerialization dataWithJSONObject:rows options:0 error:NULL];
        printf("M33-JSON-%lu\n", (unsigned long)[json length]); fflush(stdout);

        /* ---- zlib compress ----------------------------------------------- */
        uLong srcLen = (uLong)[json length];
        uLong bound = compressBound(srcLen);
        Bytef* comp = (Bytef*)malloc(bound);
        uLong compLen = bound;
        if (compress(comp, &compLen, (const Bytef*)[json bytes], srcLen) != Z_OK) {
            printf("M33-ZIP-FAIL\n"); fflush(stdout); printf("M33-DONE\n"); return 0;
        }
        printf("M33-ZIP-%lu\n", compLen); fflush(stdout);

        /* ---- uncompress + verify byte-identity --------------------------- */
        Bytef* back = (Bytef*)malloc(srcLen + 16);
        uLong backLen = srcLen + 16;
        int unz = uncompress(back, &backLen, comp, compLen);
        int identical = (unz == Z_OK) && (backLen == srcLen) &&
                        (memcmp(back, [json bytes], srcLen) == 0);
        printf("M33-ROUNDTRIP-%s\n", identical ? "OK" : "FAIL"); fflush(stdout);

        /* ---- re-parse the decompressed JSON ------------------------------ */
        NSData* backData = [NSData dataWithBytes:back length:backLen];
        NSArray* reparsed = [NSJSONSerialization JSONObjectWithData:backData options:0 error:NULL];
        printf("M33-REPARSE-%lu\n", (unsigned long)[reparsed count]); fflush(stdout);

        free(comp); free(back);
        printf("M33-DONE\n"); fflush(stdout);
    }
    return 0;
}
