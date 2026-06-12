/*
 * sqlitecli.m — M6' (the M6 pivot): real on-disk SQLite persistence via the
 * staged libsqlite3, sidestepping Darling's broken Cocotron CoreData.
 *
 * CoreData failed (M6) because its Cocotron model layer is incomplete — but
 * libsqlite3.dylib (the full 2.4MB SQLite) is staged and its C API is exported.
 * This proves the actual persistence capability directly: open a DB file, CREATE
 * a table, INSERT rows, then CLOSE and RE-OPEN the file and SELECT — so the data
 * is read back from DISK by a second connection, not from memory.
 *
 * The SQLite C API is declared extern (no sqlite3.h is staged; the ABI is rock
 * stable). Foundation is linked only for an NSString cross-check of a fetched row.
 *
 *   M6P-VERSION-<v>        sqlite3_libversion() (the lib loaded + runs)
 *   M6P-OPEN-OK            sqlite3_open() created/opened the file
 *   M6P-CREATE-OK          CREATE TABLE executed
 *   M6P-INSERT-3           3 rows inserted
 *   M6P-FILE-<bytes>       the .db file exists on disk with non-zero size
 *   M6P-REOPEN-OK          a SECOND sqlite3_open() of the same file succeeded
 *   M6P-SELECT-3           SELECT COUNT(*) read 3 rows back from disk
 *   M6P-VALUE-NOTE-2-42    the row with count=42 round-tripped (title+count)
 *   M6P-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

// --- Minimal SQLite C API extern decls (no header staged; ABI is stable). ------
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
extern int         sqlite3_open(const char* filename, sqlite3** ppDb);
extern int         sqlite3_close(sqlite3*);
extern int         sqlite3_exec(sqlite3*, const char* sql,
                                int (*cb)(void*, int, char**, char**),
                                void*, char** errmsg);
extern int         sqlite3_prepare_v2(sqlite3*, const char* sql, int nByte,
                                      sqlite3_stmt** ppStmt, const char** pzTail);
extern int         sqlite3_step(sqlite3_stmt*);
extern int         sqlite3_column_int(sqlite3_stmt*, int iCol);
extern const unsigned char* sqlite3_column_text(sqlite3_stmt*, int iCol);
extern int         sqlite3_finalize(sqlite3_stmt*);
extern const char* sqlite3_libversion(void);
extern const char* sqlite3_errmsg(sqlite3*);
#define SQLITE_OK   0
#define SQLITE_ROW  100
#define SQLITE_DONE 101

#define DBPATH "/var/root/m6notes.db"

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        printf("M6P-VERSION-%s\n", sqlite3_libversion()); fflush(stdout);
        unlink(DBPATH); // deterministic counts across runs

        // --- Phase 1: create + insert ---
        sqlite3* db = NULL;
        if (sqlite3_open(DBPATH, &db) != SQLITE_OK) {
            printf("M6P-OPEN-FAIL-%s\n", db ? sqlite3_errmsg(db) : "nil"); fflush(stdout);
            printf("M6P-DONE\n"); return 0;
        }
        printf("M6P-OPEN-OK\n"); fflush(stdout);

        char* err = NULL;
        if (sqlite3_exec(db, "CREATE TABLE note(title TEXT, count INTEGER);", NULL, NULL, &err) != SQLITE_OK) {
            printf("M6P-CREATE-FAIL-%s\n", err ? err : "?"); fflush(stdout); printf("M6P-DONE\n"); return 0;
        }
        printf("M6P-CREATE-OK\n"); fflush(stdout);

        // Row i==2 carries the recognizable value 42 (6*7).
        const char* inserts[3] = {
            "INSERT INTO note VALUES('note-0', 0);",
            "INSERT INTO note VALUES('note-1', 1);",
            "INSERT INTO note VALUES('note-2', 42);",
        };
        int n = 0;
        for (int i = 0; i < 3; i++) {
            if (sqlite3_exec(db, inserts[i], NULL, NULL, &err) == SQLITE_OK) n++;
        }
        printf("M6P-INSERT-%d\n", n); fflush(stdout);
        sqlite3_close(db); // flush to disk + drop the connection

        struct stat st;
        if (stat(DBPATH, &st) == 0) { printf("M6P-FILE-%lld\n", (long long)st.st_size); fflush(stdout); }
        else { printf("M6P-FILE-MISSING\n"); fflush(stdout); }

        // --- Phase 2: re-open a FRESH connection + read back from disk ---
        sqlite3* db2 = NULL;
        if (sqlite3_open(DBPATH, &db2) != SQLITE_OK) {
            printf("M6P-REOPEN-FAIL\n"); fflush(stdout); printf("M6P-DONE\n"); return 0;
        }
        printf("M6P-REOPEN-OK\n"); fflush(stdout);

        // Count rows.
        sqlite3_stmt* stmt = NULL;
        int rows = -1;
        if (sqlite3_prepare_v2(db2, "SELECT COUNT(*) FROM note;", -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) rows = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }
        printf("M6P-SELECT-%d\n", rows); fflush(stdout);

        // Fetch the count==42 row and verify its title round-tripped (via NSString).
        if (sqlite3_prepare_v2(db2, "SELECT title, count FROM note WHERE count=42;", -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                const unsigned char* title = sqlite3_column_text(stmt, 0);
                int cnt = sqlite3_column_int(stmt, 1);
                NSString* t = title ? [NSString stringWithUTF8String:(const char*)title] : @"NIL";
                printf("M6P-VALUE-%s-%d\n", [[t uppercaseString] UTF8String], cnt); fflush(stdout);
            }
            sqlite3_finalize(stmt);
        }
        sqlite3_close(db2);

        printf("M6P-DONE\n"); fflush(stdout);
    }
    return 0;
}
