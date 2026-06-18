/*
 * dbguiapp.c — M12 (SYNTHESIS): a real AppKit GUI app backed by a SQLite database.
 * Composes the proven GUI chain (S37/S38: NSWindow + AppKit X11 backend + GL
 * present + libX11/x11wire/SDL) with on-disk SQLite persistence (M6').
 *
 * A tiny "notes" app: opens a SQLite DB on disk, CREATE TABLE, and on startup +
 * each "Add note" button click INSERTs a row and shows the live COUNT in the
 * window. To prove real DISK persistence (not in-memory), it CLOSES and RE-OPENS
 * the DB before the final count read. This is a DB-backed Mac app on the substrate.
 *
 * Built like jsguiapp (hand-rolled objc_msgSend, -nostdlib -e _main -no_pie) PLUS
 * the staged libsqlite3.dylib. Reuses the M11 threading lesson (do the heavy
 * non-AppKit init in the quiet gap after window-build, before makeKeyAndOrderFront).
 * SQLite is single-threaded so the wedge risk is lower than JSC, but we keep the
 * safe ordering anyway.
 *
 *   M12-WINDOW-OK          NSWindow + field + button created
 *   M12-DB-OPEN-OK         sqlite3_open created/opened the file
 *   M12-DB-INSERT-1        first row inserted (startup note) + count read
 *   M12-FIELD-SET          the NSTextField shows "Notes: N"
 *   M12-DB-REOPEN-3        after 2 button-click inserts, a FRESH connection reads 3
 *   M12-DONE               window mapped with the live DB count; pump running
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- ObjC runtime (the proven akapp/jsgui pattern) ------------------------ */
typedef void* id; typedef void* Class; typedef void* SEL; typedef id (*IMP)(id, SEL, ...);
extern id   objc_getClass(const char*);
extern SEL  sel_registerName(const char*);
extern id   objc_msgSend(id, SEL, ...);
extern Class objc_allocateClassPair(Class, const char*, unsigned long);
extern void  objc_registerClassPair(Class);
extern unsigned char class_addMethod(Class, SEL, IMP, const char*);
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat w, h; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
enum { NSWindowStyleMaskTitled=1<<0, NSWindowStyleMaskClosable=1<<1, NSWindowStyleMaskResizable=1<<3 };
enum { NSBackingStoreBuffered=2 }; enum { NSApplicationActivationPolicyRegular=0 };
#define NSAnyEventMask 0xffffffffffffffffUL
static SEL S(const char* n) { return sel_registerName(n); }
static id NSStr(const char* c) {
    Class NSString = objc_getClass("NSString");
    if (!NSString || !c) return 0;
    return ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSString, S("stringWithUTF8String:"), c);
}

/* ---- SQLite C API (extern; the proven sqlitecli decls) -------------------- */
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
extern int  sqlite3_open(const char*, sqlite3**);
extern int  sqlite3_close(sqlite3*);
extern int  sqlite3_exec(sqlite3*, const char*, int(*)(void*,int,char**,char**), void*, char**);
extern int  sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
extern int  sqlite3_step(sqlite3_stmt*);
extern int  sqlite3_column_int(sqlite3_stmt*, int);
extern int  sqlite3_finalize(sqlite3_stmt*);
extern const char* sqlite3_libversion(void);
#define SQLITE_OK 0
#define SQLITE_ROW 100

#define DBPATH "/var/root/m12notes.db"

/* Insert one note row into an already-open db. */
static void db_insert(sqlite3* db) {
    sqlite3_exec(db, "INSERT INTO note(body) VALUES('note from the GUI');", 0, 0, 0);
}
/* Count rows via a fresh prepared statement. */
static int db_count(sqlite3* db) {
    sqlite3_stmt* st = 0; int n = -1;
    if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM note;", -1, &st, 0) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
    }
    return n;
}

/* ---- GUI globals + button target (insert a note on click, update field) --- */
static sqlite3* g_db = 0;
static id g_field = 0;
static id g_win = 0;
static void update_field(int count) {
    char buf[64]; snprintf(buf, sizeof(buf), "Notes in SQLite: %d", count);
    if (g_field) ((void(*)(id,SEL,id))objc_msgSend)(g_field, S("setStringValue:"), NSStr(buf));
    if (g_win)   ((void(*)(id,SEL))objc_msgSend)(g_win, S("display"));
}
static id add_note(id self, SEL _cmd, id sender) {
    if (g_db) { db_insert(g_db); int c = db_count(g_db);
        fprintf(stderr, "dbgui: add note -> count=%d\n", c); fflush(stderr);
        update_field(c); }
    return 0;
}

int main(int argc, char** argv) {
    fprintf(stderr, "dbgui: starting; DISPLAY=%s sqlite=%s\n",
            getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)", sqlite3_libversion());
    fflush(stderr);

    /* 1) Build the AppKit window (proven path) — BEFORE the DB/heavy init. */
    Class NSApplication = objc_getClass("NSApplication");
    id app = ((id(*)(id,SEL))objc_msgSend)((id)NSApplication, S("sharedApplication"));
    ((void(*)(id,SEL,long))objc_msgSend)(app, S("setActivationPolicy:"), (long)NSApplicationActivationPolicyRegular);

    Class NSWindow = objc_getClass("NSWindow");
    id win = ((id(*)(id,SEL))objc_msgSend)((id)NSWindow, S("alloc"));
    CGRect frame = { { 100.0, 100.0 }, { 480.0, 200.0 } };
    unsigned long style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
    win = ((id(*)(id,SEL,CGRect,unsigned long,unsigned long,signed char))objc_msgSend)(
        win, S("initWithContentRect:styleMask:backing:defer:"), frame, style, (unsigned long)NSBackingStoreBuffered, (signed char)0);
    if (!win) { fprintf(stderr, "dbgui: window init nil\n"); return 5; }
    g_win = win;
    ((void(*)(id,SEL,id))objc_msgSend)(win, S("setTitle:"), NSStr("SQLite Notes — Darwin Computa"));
    fprintf(stderr, "dbgui: M12-WINDOW-OK\n"); fflush(stderr);

    id content = ((id(*)(id,SEL))objc_msgSend)(win, S("contentView"));
    Class NSTextField = objc_getClass("NSTextField");
    id tf = ((id(*)(id,SEL))objc_msgSend)((id)NSTextField, S("alloc"));
    CGRect tfr = { { 40.0, 110.0 }, { 400.0, 28.0 } };
    tf = ((id(*)(id,SEL,CGRect))objc_msgSend)(tf, S("initWithFrame:"), tfr);
    ((void(*)(id,SEL,id))objc_msgSend)(tf, S("setStringValue:"), NSStr("(opening DB...)"));
    ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), tf);
    g_field = tf;

    Class NSObject = objc_getClass("NSObject");
    Class T = objc_allocateClassPair(NSObject, "DbGuiTarget", 0);
    id target = 0;
    if (T) { class_addMethod(T, S("add:"), (IMP)add_note, "@@:@"); objc_registerClassPair(T);
             target = ((id(*)(id,SEL))objc_msgSend)((id)T, S("new")); }
    Class NSButton = objc_getClass("NSButton");
    if (NSButton && content) {
        id btn = ((id(*)(id,SEL))objc_msgSend)((id)NSButton, S("alloc"));
        CGRect bf = { { 160.0, 40.0 }, { 160.0, 40.0 } };
        btn = ((id(*)(id,SEL,CGRect))objc_msgSend)(btn, S("initWithFrame:"), bf);
        ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTitle:"), NSStr("Add note"));
        if (target) { ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTarget:"), target);
                      ((void(*)(id,SEL,SEL))objc_msgSend)(btn, S("setAction:"), S("add:")); }
        ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), btn);
    }

    /* 2) Open the SQLite DB HERE (after window build, before makeKeyAndOrderFront —
     *    the M11 safe-ordering gap; SQLite is single-threaded so low risk, but keep
     *    the discipline). Fresh file each run for deterministic counts. */
    remove(DBPATH);
    if (sqlite3_open(DBPATH, &g_db) != SQLITE_OK || !g_db) {
        fprintf(stderr, "dbgui: M12-DB-OPEN-FAIL\n"); fflush(stderr); return 2;
    }
    fprintf(stderr, "dbgui: M12-DB-OPEN-OK\n"); fflush(stderr);
    sqlite3_exec(g_db, "CREATE TABLE note(id INTEGER PRIMARY KEY, body TEXT);", 0, 0, 0);
    db_insert(g_db);                 /* startup note */
    int c0 = db_count(g_db);
    fprintf(stderr, "dbgui: M12-DB-INSERT-1 (count=%d)\n", c0); fflush(stderr);
    update_field(c0);
    fprintf(stderr, "dbgui: M12-FIELD-SET (shows Notes=%d)\n", c0); fflush(stderr);

    /* 3) Map the window with the live DB count already shown. */
    ((void(*)(id,SEL,id))objc_msgSend)(win, S("makeKeyAndOrderFront:"), (id)0);
    ((void(*)(id,SEL,id))objc_msgSend)(app, S("activateIgnoringOtherApps:"), (id)1);
    ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    fprintf(stderr, "dbgui: M12-DONE — window mapped with live SQLite count; entering pump\n"); fflush(stderr);

    /* event pump (proven akapp loop) */
    Class NSDate = objc_getClass("NSDate");
    id mode = NSStr("kCFRunLoopDefaultMode");
    long n = 0; int didReopen = 0;
    for (;;) {
        id until = NSDate ? ((id(*)(id,SEL,double))objc_msgSend)((id)NSDate, S("dateWithTimeIntervalSinceNow:"), 1.0) : 0;
        id ev = ((id(*)(id,SEL,unsigned long,id,id,signed char))objc_msgSend)(
            app, S("nextEventMatchingMask:untilDate:inMode:dequeue:"), NSAnyEventMask, until, mode, (signed char)1);
        if (ev) ((void(*)(id,SEL,id))objc_msgSend)(app, S("sendEvent:"), ev);
        if (n == 5) { /* two programmatic "Add note" clicks -> 3 rows total */
            fprintf(stderr, "dbgui: programmatic Add note x2\n"); fflush(stderr);
            add_note(0,0,0); add_note(0,0,0);
        }
        if (n == 7 && !didReopen) {
            /* prove DISK persistence: close + reopen a FRESH connection, count. */
            didReopen = 1;
            sqlite3_close(g_db); g_db = 0;
            sqlite3* db2 = 0;
            if (sqlite3_open(DBPATH, &db2) == SQLITE_OK && db2) {
                int c = db_count(db2);
                fprintf(stderr, "dbgui: M12-DB-REOPEN-%d (read back from disk via a fresh connection)\n", c);
                fflush(stderr);
                g_db = db2; update_field(c);
            } else {
                fprintf(stderr, "dbgui: M12-DB-REOPEN-FAIL\n"); fflush(stderr);
            }
        }
        if ((++n % 3) == 0) ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    }
    return 0;
}
