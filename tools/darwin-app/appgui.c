/*
 * appgui.c — M14 (SYNTHESIS, capstone): a real Mac app combining THREE heavy
 * proven subsystems in one window — JavaScriptCore + SQLite + AppKit list.
 *
 * "Compute & Save": click the button -> JavaScript computes a value (via JSC) ->
 * the value is INSERTed into a SQLite table -> the window re-renders the list of
 * all saved values from the DB. So one user action exercises JS execution,
 * SQL persistence, and GUI list rendering together — the shape of a genuinely
 * capable application, proving the userland composes, not just runs pieces.
 *
 * Builds on M11 (JSC), M12 (SQLite), M13 (list rendering) + the GUI chain
 * (S37/S38). KEY ORDERING (M11 lesson): create the JSC context AND open the DB
 * AFTER the window+views are built but BEFORE makeKeyAndOrderFront — JSC's GC/JIT
 * threads must not race AppKit's X11 event-pump threads in the darlingserver
 * thread-checkin (the S34/S35 wedge).
 *
 *   M14-WINDOW-OK          NSWindow + views built
 *   M14-JSC-OK             JSC context up
 *   M14-DB-OK              SQLite opened + table created
 *   M14-COMPUTE-<n>        a click: JS computed n, INSERTed to SQLite
 *   M14-LIST-<count>       the saved-values list re-rendered (count rows)
 *   M14-DONE               window mapped; pump running
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- ObjC runtime ---------------------------------------------------------- */
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

/* ---- JavaScriptCore C API -------------------------------------------------- */
typedef const struct OpaqueJSContext* JSContextRef;
typedef struct OpaqueJSContext*       JSGlobalContextRef;
typedef struct OpaqueJSString*        JSStringRef;
typedef const struct OpaqueJSValue*   JSValueRef;
typedef struct OpaqueJSClass*         JSClassRef;
extern JSGlobalContextRef JSGlobalContextCreate(JSClassRef);
extern JSStringRef JSStringCreateWithUTF8CString(const char*);
extern void        JSStringRelease(JSStringRef);
extern JSValueRef  JSEvaluateScript(JSContextRef, JSStringRef, JSValueRef, JSStringRef, int, JSValueRef*);
extern double      JSValueToNumber(JSContextRef, JSValueRef, JSValueRef*);
static JSGlobalContextRef g_ctx = 0;
static double jsNum(const char* src) {
    JSStringRef s = JSStringCreateWithUTF8CString(src);
    JSValueRef exc = 0; JSValueRef v = JSEvaluateScript(g_ctx, s, 0, 0, 1, &exc);
    JSStringRelease(s);
    if (exc || !v) return (double)0.0/0.0;
    return JSValueToNumber(g_ctx, v, 0);
}

/* ---- SQLite C API ---------------------------------------------------------- */
typedef struct sqlite3 sqlite3; typedef struct sqlite3_stmt sqlite3_stmt;
extern int sqlite3_open(const char*, sqlite3**);
extern int sqlite3_exec(sqlite3*, const char*, int(*)(void*,int,char**,char**), void*, char**);
extern int sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
extern int sqlite3_step(sqlite3_stmt*);
extern int sqlite3_column_int(sqlite3_stmt*, int);
extern int sqlite3_finalize(sqlite3_stmt*);
#define SQLITE_OK 0
#define SQLITE_ROW 100
#define DBPATH "/var/root/m14app.db"
static sqlite3* g_db = 0;

/* ---- GUI globals + the combined action ------------------------------------ */
static id g_win = 0, g_content = 0, g_status = 0;
static id g_rows[16]; static int g_nrows = 0;
static long g_clicks = 0;
static Class NSTextField_;

/* Re-render the saved-values list from SQLite into NSTextField rows. */
static int render_list(void) {
    /* clear previous row views */
    for (int i = 0; i < g_nrows; i++) {
        if (g_rows[i]) ((void(*)(id,SEL))objc_msgSend)(g_rows[i], S("removeFromSuperview"));
        g_rows[i] = 0;
    }
    g_nrows = 0;
    sqlite3_stmt* st = 0; int count = 0;
    if (sqlite3_prepare_v2(g_db, "SELECT val FROM saved ORDER BY id;", -1, &st, 0) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW && g_nrows < 16) {
            int v = sqlite3_column_int(st, 0);
            char row[64]; snprintf(row, sizeof(row), "saved[%d] = %d", g_nrows, v);
            id tf = ((id(*)(id,SEL))objc_msgSend)((id)NSTextField_, S("alloc"));
            CGRect rr = { { 30.0, 150.0 - (CGFloat)g_nrows * 26.0 }, { 360.0, 22.0 } };
            tf = ((id(*)(id,SEL,CGRect))objc_msgSend)(tf, S("initWithFrame:"), rr);
            ((void(*)(id,SEL,id))objc_msgSend)(tf, S("setStringValue:"), NSStr(row));
            ((void(*)(id,SEL,id))objc_msgSend)(g_content, S("addSubview:"), tf);
            g_rows[g_nrows++] = tf;
            count++;
        }
        sqlite3_finalize(st);
    }
    if (g_win) ((void(*)(id,SEL))objc_msgSend)(g_win, S("display"));
    return count;
}

/* Button action: JS computes a value -> INSERT to SQLite -> re-render list. */
static id compute_save(id self, SEL _cmd, id sender) {
    g_clicks++;
    /* a JS expression that varies per click (so the saved list grows distinctly) */
    char src[96]; snprintf(src, sizeof(src), "Math.pow(2,%ld) + %ld", g_clicks, g_clicks);
    int n = (int)jsNum(src);
    char sql[96]; snprintf(sql, sizeof(sql), "INSERT INTO saved(val) VALUES(%d);", n);
    sqlite3_exec(g_db, sql, 0, 0, 0);
    fprintf(stderr, "appgui: M14-COMPUTE-%d (JS '%s' -> SQLite)\n", n, src); fflush(stderr);
    int c = render_list();
    fprintf(stderr, "appgui: M14-LIST-%d\n", c); fflush(stderr);
    char status[64]; snprintf(status, sizeof(status), "Computed %d via JS, saved to SQLite (%d rows)", n, c);
    if (g_status) ((void(*)(id,SEL,id))objc_msgSend)(g_status, S("setStringValue:"), NSStr(status));
    return 0;
}

int main(int argc, char** argv) {
    fprintf(stderr, "appgui: starting; DISPLAY=%s\n", getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
    fflush(stderr);

    /* 1) Build the window (proven path). */
    Class NSApplication = objc_getClass("NSApplication");
    id app = ((id(*)(id,SEL))objc_msgSend)((id)NSApplication, S("sharedApplication"));
    ((void(*)(id,SEL,long))objc_msgSend)(app, S("setActivationPolicy:"), (long)NSApplicationActivationPolicyRegular);
    Class NSWindow = objc_getClass("NSWindow");
    id win = ((id(*)(id,SEL))objc_msgSend)((id)NSWindow, S("alloc"));
    CGRect frame = { { 100.0, 100.0 }, { 440.0, 300.0 } };
    unsigned long style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
    win = ((id(*)(id,SEL,CGRect,unsigned long,unsigned long,signed char))objc_msgSend)(
        win, S("initWithContentRect:styleMask:backing:defer:"), frame, style, (unsigned long)NSBackingStoreBuffered, (signed char)0);
    if (!win) { fprintf(stderr, "appgui: window init nil\n"); return 5; }
    g_win = win;
    ((void(*)(id,SEL,id))objc_msgSend)(win, S("setTitle:"), NSStr("JS + SQLite — Darwin Computa"));
    fprintf(stderr, "appgui: M14-WINDOW-OK\n"); fflush(stderr);
    id content = ((id(*)(id,SEL))objc_msgSend)(win, S("contentView"));
    g_content = content;
    NSTextField_ = objc_getClass("NSTextField");

    id status = ((id(*)(id,SEL))objc_msgSend)((id)NSTextField_, S("alloc"));
    CGRect sf = { { 20.0, 250.0 }, { 400.0, 24.0 } };
    status = ((id(*)(id,SEL,CGRect))objc_msgSend)(status, S("initWithFrame:"), sf);
    ((void(*)(id,SEL,id))objc_msgSend)(status, S("setStringValue:"), NSStr("Click 'Compute & Save' (JS -> SQLite -> list)"));
    ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), status);
    g_status = status;

    Class NSObject = objc_getClass("NSObject");
    Class T = objc_allocateClassPair(NSObject, "AppGuiTarget", 0);
    id target = 0;
    if (T) { class_addMethod(T, S("go:"), (IMP)compute_save, "@@:@"); objc_registerClassPair(T);
             target = ((id(*)(id,SEL))objc_msgSend)((id)T, S("new")); }
    Class NSButton = objc_getClass("NSButton");
    if (NSButton) {
        id btn = ((id(*)(id,SEL))objc_msgSend)((id)NSButton, S("alloc"));
        CGRect bf = { { 140.0, 200.0 }, { 180.0, 36.0 } };
        btn = ((id(*)(id,SEL,CGRect))objc_msgSend)(btn, S("initWithFrame:"), bf);
        ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTitle:"), NSStr("Compute & Save"));
        if (target) { ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTarget:"), target);
                      ((void(*)(id,SEL,SEL))objc_msgSend)(btn, S("setAction:"), S("go:")); }
        ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), btn);
    }

    /* 2) Bring up JSC + SQLite HERE (post window-build, pre makeKeyAndOrderFront). */
    g_ctx = JSGlobalContextCreate(0);
    if (!g_ctx) { fprintf(stderr, "appgui: M14-JSC-FAIL\n"); fflush(stderr); return 2; }
    fprintf(stderr, "appgui: M14-JSC-OK\n"); fflush(stderr);
    remove(DBPATH);
    if (sqlite3_open(DBPATH, &g_db) != SQLITE_OK || !g_db) { fprintf(stderr, "appgui: M14-DB-FAIL\n"); fflush(stderr); return 3; }
    sqlite3_exec(g_db, "CREATE TABLE saved(id INTEGER PRIMARY KEY, val INTEGER);", 0, 0, 0);
    fprintf(stderr, "appgui: M14-DB-OK\n"); fflush(stderr);

    /* 3) Map the window. */
    ((void(*)(id,SEL,id))objc_msgSend)(win, S("makeKeyAndOrderFront:"), (id)0);
    ((void(*)(id,SEL,id))objc_msgSend)(app, S("activateIgnoringOtherApps:"), (id)1);
    ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    fprintf(stderr, "appgui: M14-DONE — window mapped (JS+SQLite+list app); entering pump\n"); fflush(stderr);

    Class NSDate = objc_getClass("NSDate");
    id mode = NSStr("kCFRunLoopDefaultMode");
    long n = 0;
    for (;;) {
        id until = NSDate ? ((id(*)(id,SEL,double))objc_msgSend)((id)NSDate, S("dateWithTimeIntervalSinceNow:"), 1.0) : 0;
        id ev = ((id(*)(id,SEL,unsigned long,id,id,signed char))objc_msgSend)(
            app, S("nextEventMatchingMask:untilDate:inMode:dequeue:"), NSAnyEventMask, until, mode, (signed char)1);
        if (ev) ((void(*)(id,SEL,id))objc_msgSend)(app, S("sendEvent:"), ev);
        if (n == 5 || n == 7 || n == 9) { /* three programmatic clicks -> 3 saved values */
            fprintf(stderr, "appgui: programmatic Compute & Save\n"); fflush(stderr);
            compute_save(0, 0, 0);
        }
        if ((++n % 3) == 0) ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    }
    return 0;
}
