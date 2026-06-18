/*
 * jsguiapp.c — M11 (SYNTHESIS): a real AppKit GUI app that runs JavaScript through
 * JavaScriptCore and DISPLAYS the result in its window. Composes two proven layers:
 *   - the GUI chain (S37/S38: NSWindow + NSTextField + AppKit X11 backend + GL
 *     present + the libX11/x11wire/SDL bridge), and
 *   - JavaScriptCore (M5a: the JSC C API executing real JS on the substrate).
 *
 * This is what "full userland support" means to a user: a windowed Mac app doing
 * real work, not an isolated headless probe. At startup the app evaluates JS via
 * JSC, sets the NSTextField's stringValue to the result (visible in the window),
 * and logs a verdict line. A button re-evaluates a JS expression on click.
 *
 * Built like akapp (hand-rolled objc_msgSend, -nostdlib -e _main -no_pie) PLUS the
 * staged JavaScriptCore.framework. See build-jsguiapp.sh.
 *
 *   M11-JSC-CTX-OK         JSGlobalContextCreate succeeded (JSC up inside the GUI app)
 *   M11-WINDOW-OK          NSWindow created + made key
 *   M11-JS-EVAL-42         JS "6*7" -> 42 (evaluated inside the GUI process)
 *   M11-JS-STR-DARWIN      JS "'darwin'.toUpperCase()" -> DARWIN
 *   M11-FIELD-SET          the NSTextField now shows the JS result string
 *   M11-DONE               (printed once the window is up + field set; pump continues)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- ObjC runtime (hand-rolled, the proven akapp pattern) ----------------- */
typedef void* id;
typedef void* Class;
typedef void* SEL;
typedef id (*IMP)(id, SEL, ...);
extern id   objc_getClass(const char* name);
extern SEL  sel_registerName(const char* name);
extern id   objc_msgSend(id self, SEL op, ...);
extern Class objc_allocateClassPair(Class superclass, const char* name, unsigned long extraBytes);
extern void  objc_registerClassPair(Class cls);
extern unsigned char class_addMethod(Class cls, SEL name, IMP imp, const char* types);

typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat w, h; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
enum { NSWindowStyleMaskTitled = 1<<0, NSWindowStyleMaskClosable = 1<<1, NSWindowStyleMaskResizable = 1<<3 };
enum { NSBackingStoreBuffered = 2 };
enum { NSApplicationActivationPolicyRegular = 0 };
#define NSAnyEventMask 0xffffffffffffffffUL
static SEL S(const char* n) { return sel_registerName(n); }
static id NSStr(const char* c) {
    Class NSString = objc_getClass("NSString");
    if (!NSString || !c) return 0;
    return ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSString, S("stringWithUTF8String:"), c);
}

/* ---- JavaScriptCore C API (extern; the proven jscli decls) ---------------- */
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
extern JSStringRef JSValueToStringCopy(JSContextRef, JSValueRef, JSValueRef*);
extern size_t      JSStringGetUTF8CString(JSStringRef, char*, size_t);
extern size_t      JSStringGetMaximumUTF8CStringSize(JSStringRef);

static JSGlobalContextRef g_ctx = 0;
static double jsNum(const char* src) {
    JSStringRef s = JSStringCreateWithUTF8CString(src);
    JSValueRef exc = 0;
    JSValueRef v = JSEvaluateScript(g_ctx, s, 0, 0, 1, &exc);
    JSStringRelease(s);
    if (exc || !v) return (double)0.0/0.0;
    return JSValueToNumber(g_ctx, v, 0);
}
static void jsStr(const char* src, char* out, size_t cap) {
    out[0] = 0;
    JSStringRef s = JSStringCreateWithUTF8CString(src);
    JSValueRef exc = 0;
    JSValueRef v = JSEvaluateScript(g_ctx, s, 0, 0, 1, &exc);
    JSStringRelease(s);
    if (exc || !v) return;
    JSStringRef str = JSValueToStringCopy(g_ctx, v, 0);
    if (str) { JSStringGetUTF8CString(str, out, cap); JSStringRelease(str); }
}

/* ---- button target: re-evaluate JS on click, update the field ------------- */
static id g_field = 0;
static long g_clicks = 0;
static id js_click(id self, SEL _cmd, id sender) {
    g_clicks++;
    /* a JS expression that depends on the click count — proves live JS per click */
    char src[128]; snprintf(src, sizeof(src), "(%ld * 7) + ' from JS'", g_clicks);
    char buf[256]; jsStr(src, buf, sizeof(buf));
    fprintf(stderr, "jsgui: click %ld -> JS says '%s'\n", g_clicks, buf); fflush(stderr);
    if (g_field && buf[0]) ((void(*)(id,SEL,id))objc_msgSend)(g_field, S("setStringValue:"), NSStr(buf));
    return 0;
}

int main(int argc, char** argv) {
    fprintf(stderr, "jsgui: starting; DISPLAY=%s\n", getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
    fflush(stderr);

    /* ORDERING NOTE (M11, why window-first): creating the JSC context FIRST spawns
     * JSC's GC/JIT helper threads, which then contend with AppKit's NSWindow-init
     * helper threads during the darlingserver thread-checkin (the S34/S35 wedge) —
     * jsguiapp DETERMINISTICALLY stalled in window-init when JSC came up first.
     * FIX: build + map the window FIRST (AppKit's init runs with no other threads
     * competing), THEN create the JSC context and run JS to update the field. */

    /* 1) Build the AppKit window (the proven akapp path) — BEFORE JSC. */
    Class NSApplication = objc_getClass("NSApplication");
    id app = ((id(*)(id,SEL))objc_msgSend)((id)NSApplication, S("sharedApplication"));
    ((void(*)(id,SEL,long))objc_msgSend)(app, S("setActivationPolicy:"), (long)NSApplicationActivationPolicyRegular);

    Class NSWindow = objc_getClass("NSWindow");
    id win = ((id(*)(id,SEL))objc_msgSend)((id)NSWindow, S("alloc"));
    CGRect frame = { { 100.0, 100.0 }, { 480.0, 200.0 } };
    unsigned long style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
    win = ((id(*)(id,SEL,CGRect,unsigned long,unsigned long,signed char))objc_msgSend)(
        win, S("initWithContentRect:styleMask:backing:defer:"), frame, style, (unsigned long)NSBackingStoreBuffered, (signed char)0);
    if (!win) { fprintf(stderr, "jsgui: window init nil\n"); return 5; }
    ((void(*)(id,SEL,id))objc_msgSend)(win, S("setTitle:"), NSStr("JS in Darwin Computa"));
    fprintf(stderr, "jsgui: M11-WINDOW-OK\n"); fflush(stderr);

    id content = ((id(*)(id,SEL))objc_msgSend)(win, S("contentView"));

    /* a label/field showing the JS result */
    Class NSTextField = objc_getClass("NSTextField");
    id tf = ((id(*)(id,SEL))objc_msgSend)((id)NSTextField, S("alloc"));
    CGRect tfr = { { 40.0, 110.0 }, { 400.0, 28.0 } };
    tf = ((id(*)(id,SEL,CGRect))objc_msgSend)(tf, S("initWithFrame:"), tfr);
    ((void(*)(id,SEL,id))objc_msgSend)(tf, S("setStringValue:"), NSStr("(evaluating JS...)"));
    ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), tf);
    g_field = tf;

    /* a button that re-runs JS on click */
    Class NSObject = objc_getClass("NSObject");
    Class T = objc_allocateClassPair(NSObject, "JsGuiTarget", 0);
    id target = 0;
    if (T) { class_addMethod(T, S("clicked:"), (IMP)js_click, "@@:@"); objc_registerClassPair(T);
             target = ((id(*)(id,SEL))objc_msgSend)((id)T, S("new")); }
    Class NSButton = objc_getClass("NSButton");
    if (NSButton && content) {
        id btn = ((id(*)(id,SEL))objc_msgSend)((id)NSButton, S("alloc"));
        CGRect bf = { { 160.0, 40.0 }, { 160.0, 40.0 } };
        btn = ((id(*)(id,SEL,CGRect))objc_msgSend)(btn, S("initWithFrame:"), bf);
        ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTitle:"), NSStr("Run JS"));
        if (target) { ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTarget:"), target);
                      ((void(*)(id,SEL,SEL))objc_msgSend)(btn, S("setAction:"), S("clicked:")); }
        ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), btn);
    }

    /* 2) Bring up JavaScriptCore HERE — after the window+views are built but BEFORE
     * makeKeyAndOrderFront. Empirically (M11 runs): JSC-first wedged AppKit init,
     * and JSC-after-MAP wedged too (JSC's GC/JIT thread creation races the X11
     * event-pump threads that makeKeyAndOrderFront starts, in the darlingserver
     * thread-checkin = the S34/S35 wedge). Creating JSC's threads in this quiet
     * window — AppKit framework init done (sharedApplication ran), but the window
     * not yet mapped so no X11 event threads — avoids the contention. */
    g_ctx = JSGlobalContextCreate(0);
    if (!g_ctx) { fprintf(stderr, "jsgui: M11-JSC-CTX-FAIL\n"); fflush(stderr); return 2; }
    fprintf(stderr, "jsgui: M11-JSC-CTX-OK\n"); fflush(stderr);

    int answer = (int)jsNum("6 * 7");
    fprintf(stderr, "jsgui: M11-JS-EVAL-%d\n", answer); fflush(stderr);
    char up[64]; jsStr("'darwin'.toUpperCase()", up, sizeof(up));
    fprintf(stderr, "jsgui: M11-JS-STR-%s\n", up[0] ? up : "FAIL"); fflush(stderr);
    char display[160];
    snprintf(display, sizeof(display), "JS: 6*7=%d, '%s'", answer, up);
    ((void(*)(id,SEL,id))objc_msgSend)(g_field, S("setStringValue:"), NSStr(display));
    fprintf(stderr, "jsgui: M11-FIELD-SET (window will show '%s')\n", display); fflush(stderr);

    /* 3) NOW map the window (with the JS result already in the field). */
    ((void(*)(id,SEL,id))objc_msgSend)(win, S("makeKeyAndOrderFront:"), (id)0);
    ((void(*)(id,SEL,id))objc_msgSend)(app, S("activateIgnoringOtherApps:"), (id)1);
    ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    fprintf(stderr, "jsgui: M11-DONE — window mapped with live JS result; entering pump\n"); fflush(stderr);

    /* event pump (proven akapp loop) */
    Class NSDate = objc_getClass("NSDate");
    id mode = NSStr("kCFRunLoopDefaultMode");
    long n = 0;
    for (;;) {
        id until = NSDate ? ((id(*)(id,SEL,double))objc_msgSend)((id)NSDate, S("dateWithTimeIntervalSinceNow:"), 1.0) : 0;
        id ev = ((id(*)(id,SEL,unsigned long,id,id,signed char))objc_msgSend)(
            app, S("nextEventMatchingMask:untilDate:inMode:dequeue:"), NSAnyEventMask, until, mode, (signed char)1);
        if (ev) ((void(*)(id,SEL,id))objc_msgSend)(app, S("sendEvent:"), ev);
        if (++n == 5) { /* programmatic click to prove the JS-on-click path even headless */
            fprintf(stderr, "jsgui: programmatic Run JS click\n"); fflush(stderr);
            js_click(0, 0, 0);
        }
        if ((n % 3) == 0) ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    }
    return 0;
}
