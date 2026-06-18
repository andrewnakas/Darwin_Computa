/*
 * listguiapp.c — M13 (SYNTHESIS): a real AppKit GUI app that PARSES JSON data and
 * renders the records as an on-screen list. Composes the proven GUI chain
 * (S37/S38: NSWindow + AppKit X11 backend + GL present) with NSJSONSerialization
 * (M7) — and uses Foundation collection enumeration (NSArray/NSDictionary, M3).
 *
 * A tiny "data list" app: parses an embedded JSON array of {name, score} records
 * into an NSArray of NSDictionary, then creates ONE NSTextField per record in the
 * window — a real list view of parsed data. This is the "fetch/parse -> display"
 * shape of most real apps (here the data is embedded, since the live-network fetch
 * M10 is blocked on a guest-TLS issue; the parse->GUI composition is the point).
 *
 * Built like dbguiapp (hand-rolled objc_msgSend, -nostdlib -e _main -no_pie).
 * JSON is pure Foundation (already linked) — no extra lib, no extra threads.
 *
 *   M13-WINDOW-OK          NSWindow created
 *   M13-JSON-PARSE-3       JSONObjectWithData -> a 3-element NSArray
 *   M13-ROW-<i>-<name>-<score>   each parsed record rendered to a field
 *   M13-ROWS-SHOWN-3       3 NSTextField rows added to the window
 *   M13-DONE               window mapped showing the parsed list; pump running
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- ObjC runtime (the proven pattern) ------------------------------------ */
typedef void* id; typedef void* Class; typedef void* SEL; typedef id (*IMP)(id, SEL, ...);
extern id   objc_getClass(const char*);
extern SEL  sel_registerName(const char*);
extern id   objc_msgSend(id, SEL, ...);
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
static const char* CStr(id s) {
    if (!s) return 0;
    return ((const char*(*)(id,SEL))objc_msgSend)(s, S("UTF8String"));
}

/* Embedded JSON: an array of records, the kind a real app would fetch+parse. */
static const char* JSON_DATA =
    "[ {\"name\":\"alpha\",\"score\":10},"
    "  {\"name\":\"bravo\",\"score\":42},"
    "  {\"name\":\"charlie\",\"score\":7} ]";

int main(int argc, char** argv) {
    fprintf(stderr, "listgui: starting; DISPLAY=%s\n", getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
    fflush(stderr);

    /* 1) Build the AppKit window (proven path) — before the parse. */
    Class NSApplication = objc_getClass("NSApplication");
    id app = ((id(*)(id,SEL))objc_msgSend)((id)NSApplication, S("sharedApplication"));
    ((void(*)(id,SEL,long))objc_msgSend)(app, S("setActivationPolicy:"), (long)NSApplicationActivationPolicyRegular);

    Class NSWindow = objc_getClass("NSWindow");
    id win = ((id(*)(id,SEL))objc_msgSend)((id)NSWindow, S("alloc"));
    CGRect frame = { { 100.0, 100.0 }, { 420.0, 260.0 } };
    unsigned long style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
    win = ((id(*)(id,SEL,CGRect,unsigned long,unsigned long,signed char))objc_msgSend)(
        win, S("initWithContentRect:styleMask:backing:defer:"), frame, style, (unsigned long)NSBackingStoreBuffered, (signed char)0);
    if (!win) { fprintf(stderr, "listgui: window init nil\n"); return 5; }
    ((void(*)(id,SEL,id))objc_msgSend)(win, S("setTitle:"), NSStr("JSON List — Darwin Computa"));
    fprintf(stderr, "listgui: M13-WINDOW-OK\n"); fflush(stderr);
    id content = ((id(*)(id,SEL))objc_msgSend)(win, S("contentView"));

    /* a header field */
    Class NSTextField = objc_getClass("NSTextField");
    id hdr = ((id(*)(id,SEL))objc_msgSend)((id)NSTextField, S("alloc"));
    CGRect hf = { { 20.0, 220.0 }, { 380.0, 24.0 } };
    hdr = ((id(*)(id,SEL,CGRect))objc_msgSend)(hdr, S("initWithFrame:"), hf);
    ((void(*)(id,SEL,id))objc_msgSend)(hdr, S("setStringValue:"), NSStr("Parsed JSON records:"));
    ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), hdr);

    /* 2) Parse the JSON (pure Foundation; before makeKeyAndOrderFront for ordering
     *    consistency with M11/M12 — though JSON spawns no threads). */
    Class NSData = objc_getClass("NSData");
    id data = ((id(*)(id,SEL,const void*,unsigned long))objc_msgSend)(
        (id)NSData, S("dataWithBytes:length:"), JSON_DATA, (unsigned long)strlen(JSON_DATA));
    Class NSJSON = objc_getClass("NSJSONSerialization");
    id arr = ((id(*)(id,SEL,id,unsigned long,id*))objc_msgSend)(
        (id)NSJSON, S("JSONObjectWithData:options:error:"), data, 0UL, (id*)0);
    Class NSArray = objc_getClass("NSArray");
    int isArr = arr && ((signed char(*)(id,SEL,id))objc_msgSend)(arr, S("isKindOfClass:"), (id)NSArray);
    unsigned long count = isArr ? (unsigned long)((id(*)(id,SEL))objc_msgSend)(arr, S("count")) : 0;
    fprintf(stderr, "listgui: M13-JSON-PARSE-%lu\n", count); fflush(stderr);

    /* 3) Render ONE NSTextField per parsed record — a real list of data. */
    int shown = 0;
    for (unsigned long i = 0; i < count; i++) {
        id rec = ((id(*)(id,SEL,unsigned long))objc_msgSend)(arr, S("objectAtIndex:"), i);
        id namev  = ((id(*)(id,SEL,id))objc_msgSend)(rec, S("objectForKey:"), NSStr("name"));
        id scorev = ((id(*)(id,SEL,id))objc_msgSend)(rec, S("objectForKey:"), NSStr("score"));
        const char* nm = CStr(namev);
        int sc = scorev ? (int)((long(*)(id,SEL))objc_msgSend)(scorev, S("integerValue")) : -1;
        char row[128]; snprintf(row, sizeof(row), "%lu. %s = %d", i + 1, nm ? nm : "(nil)", sc);
        fprintf(stderr, "listgui: M13-ROW-%lu-%s-%d\n", i, nm ? nm : "nil", sc); fflush(stderr);

        id tf = ((id(*)(id,SEL))objc_msgSend)((id)NSTextField, S("alloc"));
        CGRect rr = { { 30.0, 180.0 - (CGFloat)i * 34.0 }, { 360.0, 26.0 } };
        tf = ((id(*)(id,SEL,CGRect))objc_msgSend)(tf, S("initWithFrame:"), rr);
        ((void(*)(id,SEL,id))objc_msgSend)(tf, S("setStringValue:"), NSStr(row));
        ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), tf);
        shown++;
    }
    fprintf(stderr, "listgui: M13-ROWS-SHOWN-%d\n", shown); fflush(stderr);

    /* 4) Map the window showing the parsed list. */
    ((void(*)(id,SEL,id))objc_msgSend)(win, S("makeKeyAndOrderFront:"), (id)0);
    ((void(*)(id,SEL,id))objc_msgSend)(app, S("activateIgnoringOtherApps:"), (id)1);
    ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    fprintf(stderr, "listgui: M13-DONE — window mapped with the parsed JSON list; entering pump\n"); fflush(stderr);

    Class NSDate = objc_getClass("NSDate");
    id mode = NSStr("kCFRunLoopDefaultMode");
    long n = 0;
    for (;;) {
        id until = NSDate ? ((id(*)(id,SEL,double))objc_msgSend)((id)NSDate, S("dateWithTimeIntervalSinceNow:"), 1.0) : 0;
        id ev = ((id(*)(id,SEL,unsigned long,id,id,signed char))objc_msgSend)(
            app, S("nextEventMatchingMask:untilDate:inMode:dequeue:"), NSAnyEventMask, until, mode, (signed char)1);
        if (ev) ((void(*)(id,SEL,id))objc_msgSend)(app, S("sendEvent:"), ev);
        if ((++n % 3) == 0) ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    }
    return 0;
}
