/*
 * akapp.c — the S38 REAL .app BUNDLE for Darwin_Computa.
 *
 * akrun (S36/S37) proved a LIVE interactive AppKit app: NSWindow -> X11Window ->
 * XCreateWindow/XMapWindow -> XWire -> SDL, with real clicks/keys arriving as
 * NSEvents and pixels presenting through the gl64 trap-GL/EGL bridge. But akrun
 * is a bare /usr/bin executable — there is no bundle around it.
 *
 * akapp is the same app DELIVERED AS A PROPER MAC APP BUNDLE:
 *
 *   DarwinComputa.app/
 *     Contents/
 *       Info.plist                 (CFBundleExecutable/Identifier/Name, APPL)
 *       MacOS/DarwinComputa        (this binary)
 *       Resources/Welcome.txt      (a bundle resource, read at runtime)
 *
 * Launching it execs Contents/MacOS/DarwinComputa, so Darling's CoreFoundation
 * derives the MAIN BUNDLE by walking the executable path up to the .app. The
 * NEW thing akapp proves over akrun: it introspects its OWN bundle and logs the
 * evidence —
 *
 *   [NSBundle mainBundle] -> bundlePath, bundleIdentifier
 *   -[NSBundle objectForInfoDictionaryKey:@"CFBundleName"]  (drives the title)
 *   -[NSBundle pathForResource:@"Welcome" ofType:@"txt"] + read its contents
 *
 * If those resolve to the .app (not "/usr/bin" or nil), the bundle launch path
 * is real. The window then behaves exactly like akrun (button toggles bg, text
 * field accepts typing, every NSEvent logged) so it stays a hands-on demo.
 *
 * Header-less ObjC-via-runtime, same cross-build recipe as akrun (see
 * build-akapp.sh): -nostdlib -e _main -no_pie against the staged guest dylibs.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>   /* strstr — resolved from the staged libSystem */

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
extern const char* object_getClassName(id obj);

typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat w, h; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

enum {
    NSWindowStyleMaskTitled         = 1 << 0,
    NSWindowStyleMaskClosable       = 1 << 1,
    NSWindowStyleMaskResizable      = 1 << 3,
};
enum { NSBackingStoreBuffered = 2 };
enum { NSApplicationActivationPolicyRegular = 0 };
#define NSAnyEventMask 0xffffffffffffffffUL

static SEL S(const char* n) { return sel_registerName(n); }

/* Convenience: [NSString stringWithUTF8String:cstr] */
static id NSStr(const char* c) {
    Class NSString = objc_getClass("NSString");
    if (!NSString || !c) return 0;
    return ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSString, S("stringWithUTF8String:"), c);
}
/* Convenience: [obj UTF8String] (obj an NSString or nil) */
static const char* CStr(id nsstr) {
    if (!nsstr) return 0;
    return ((const char*(*)(id,SEL))objc_msgSend)(nsstr, S("UTF8String"));
}

/* ---- button target (runtime class), identical behavior to akrun ---------- */
static id g_win = 0;
static id g_btn = 0;
static long g_clicks = 0;

static id ak_bump(id self, SEL _cmd, id sender) {
    g_clicks++;
    fprintf(stderr, "akapp: BUTTON CLICKED! (count=%ld) — toggling background\n", g_clicks);
    fflush(stderr);
    Class NSColor = objc_getClass("NSColor");
    if (NSColor && g_win) {
        id c = ((id(*)(id,SEL))objc_msgSend)((id)NSColor,
                S((g_clicks & 1) ? "blueColor" : "redColor"));
        if (c) ((void(*)(id,SEL,id))objc_msgSend)(g_win, S("setBackgroundColor:"), c);
        ((void(*)(id,SEL))objc_msgSend)(g_win, S("display"));
    }
    return 0;
}

/* ---- THE S38 PROOF: introspect our own bundle --------------------------- */
/* Returns the CFBundleName from Info.plist (an NSString) or nil. Logs the full
 * bundle evidence to stderr as it goes. */
static id report_bundle(void) {
    Class NSBundle = objc_getClass("NSBundle");
    if (!NSBundle) { fprintf(stderr, "akapp: NSBundle class missing\n"); fflush(stderr); return 0; }
    id main = ((id(*)(id,SEL))objc_msgSend)((id)NSBundle, S("mainBundle"));
    if (!main) { fprintf(stderr, "akapp: [NSBundle mainBundle] == nil\n"); fflush(stderr); return 0; }

    id bpath = ((id(*)(id,SEL))objc_msgSend)(main, S("bundlePath"));
    id bid   = ((id(*)(id,SEL))objc_msgSend)(main, S("bundleIdentifier"));
    id name  = ((id(*)(id,SEL,id))objc_msgSend)(main, S("objectForInfoDictionaryKey:"), NSStr("CFBundleName"));
    id disp  = ((id(*)(id,SEL,id))objc_msgSend)(main, S("objectForInfoDictionaryKey:"), NSStr("CFBundleDisplayName"));
    id exe   = ((id(*)(id,SEL,id))objc_msgSend)(main, S("objectForInfoDictionaryKey:"), NSStr("CFBundleExecutable"));

    fprintf(stderr, "akapp: ===== MAIN BUNDLE =====\n");
    fprintf(stderr, "akapp:   bundlePath        = %s\n", CStr(bpath) ? CStr(bpath) : "(nil)");
    fprintf(stderr, "akapp:   bundleIdentifier  = %s\n", CStr(bid)   ? CStr(bid)   : "(nil)");
    fprintf(stderr, "akapp:   CFBundleName      = %s\n", CStr(name)  ? CStr(name)  : "(nil)");
    fprintf(stderr, "akapp:   CFBundleDisplayName = %s\n", CStr(disp) ? CStr(disp) : "(nil)");
    fprintf(stderr, "akapp:   CFBundleExecutable  = %s\n", CStr(exe)  ? CStr(exe)  : "(nil)");
    fflush(stderr);

    /* Read a bundled resource — the real test that Resources/ resolves under
     * the .app and the file is reachable through the guest VFS. */
    id resPath = ((id(*)(id,SEL,id,id))objc_msgSend)(main, S("pathForResource:ofType:"),
                                                     NSStr("Welcome"), NSStr("txt"));
    if (resPath) {
        fprintf(stderr, "akapp:   Welcome.txt path  = %s\n", CStr(resPath) ? CStr(resPath) : "(nil)");
        Class NSString = objc_getClass("NSString");
        /* +[NSString stringWithContentsOfFile:encoding:error:], encoding 4 = UTF-8 */
        id contents = ((id(*)(id,SEL,id,unsigned long,id*))objc_msgSend)(
            (id)NSString, S("stringWithContentsOfFile:encoding:error:"),
            resPath, (unsigned long)4, (id*)0);
        if (contents) {
            const char* c = CStr(contents);
            fprintf(stderr, "akapp:   Welcome.txt body  = \"%s\"\n", c ? c : "(nil)");
        } else {
            fprintf(stderr, "akapp:   Welcome.txt read FAILED (file unreadable)\n");
        }
    } else {
        fprintf(stderr, "akapp:   Welcome.txt NOT FOUND in bundle (Resources/ unresolved)\n");
    }
    fprintf(stderr, "akapp: =======================\n");
    fflush(stderr);

    /* Verdict line: did the bundle resolve to a real .app (not /usr/bin)? */
    const char* bp = CStr(bpath);
    if (bp && strstr(bp, ".app")) {
        fprintf(stderr, "akapp: BUNDLE OK — mainBundle resolved to a .app (%s)\n", bp);
    } else {
        fprintf(stderr, "akapp: BUNDLE MISS — mainBundle is not a .app (%s)\n", bp ? bp : "(nil)");
    }
    fflush(stderr);
    return name;
}

int main(int argc, char** argv) {
    fprintf(stderr, "akapp: starting; argv[0]=%s DISPLAY=%s\n",
            argc > 0 ? argv[0] : "(none)", getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
    fflush(stderr);

    /* Report the bundle BEFORE building the UI — it is the headline result and
     * we want it logged even if the window path later stalls. */
    id bundleName = report_bundle();

    Class NSApplication = objc_getClass("NSApplication");
    if (!NSApplication) { fprintf(stderr, "akapp: NSApplication missing\n"); return 2; }
    id app = ((id(*)(id,SEL))objc_msgSend)((id)NSApplication, S("sharedApplication"));
    if (!app) { fprintf(stderr, "akapp: sharedApplication nil\n"); return 3; }
    ((void(*)(id,SEL,long))objc_msgSend)(app, S("setActivationPolicy:"), (long)NSApplicationActivationPolicyRegular);
    fprintf(stderr, "akapp: NSApplication up\n"); fflush(stderr);

    Class NSWindow = objc_getClass("NSWindow");
    if (!NSWindow) { fprintf(stderr, "akapp: NSWindow missing\n"); return 4; }
    id win = ((id(*)(id,SEL))objc_msgSend)((id)NSWindow, S("alloc"));
    CGRect frame = { { 100.0, 100.0 }, { 480.0, 320.0 } };
    unsigned long style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
    win = ((id(*)(id,SEL,CGRect,unsigned long,unsigned long,signed char))objc_msgSend)(
        win, S("initWithContentRect:styleMask:backing:defer:"),
        frame, style, (unsigned long)NSBackingStoreBuffered, (signed char)0);
    if (!win) { fprintf(stderr, "akapp: window init nil\n"); return 5; }
    fprintf(stderr, "akapp: NSWindow = %p\n", win); fflush(stderr);

    /* Title from the bundle's CFBundleName — visible proof in the title bar that
     * the Info.plist was read. Fall back to a literal if it didn't resolve. */
    id title = bundleName ? bundleName : NSStr("Darwin Computa");
    if (title) ((void(*)(id,SEL,id))objc_msgSend)(win, S("setTitle:"), title);

    Class NSColor = objc_getClass("NSColor");
    if (NSColor) {
        id red = ((id(*)(id,SEL))objc_msgSend)((id)NSColor, S("redColor"));
        if (red) ((void(*)(id,SEL,id))objc_msgSend)(win, S("setBackgroundColor:"), red);
    }

    /* Controls — same as akrun: a button that toggles bg, a text field to type. */
    g_win = win;
    id content = ((id(*)(id,SEL))objc_msgSend)(win, S("contentView"));
    Class NSObject = objc_getClass("NSObject");
    Class AkTarget = objc_allocateClassPair(NSObject, "AkAppTarget", 0);
    id target = 0;
    if (AkTarget) {
        class_addMethod(AkTarget, S("bump:"), (IMP)ak_bump, "@@:@");
        objc_registerClassPair(AkTarget);
        target = ((id(*)(id,SEL))objc_msgSend)((id)AkTarget, S("new"));
    }
    Class NSButton = objc_getClass("NSButton");
    if (NSButton && content) {
        id btn = ((id(*)(id,SEL))objc_msgSend)((id)NSButton, S("alloc"));
        CGRect bf = { { 160.0, 140.0 }, { 160.0, 40.0 } };
        btn = ((id(*)(id,SEL,CGRect))objc_msgSend)(btn, S("initWithFrame:"), bf);
        if (btn) {
            id bt = NSStr("Click me!");
            if (bt) ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTitle:"), bt);
            if (target) {
                ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTarget:"), target);
                ((void(*)(id,SEL,SEL))objc_msgSend)(btn, S("setAction:"), S("bump:"));
            }
            ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), btn);
            g_btn = btn;
            fprintf(stderr, "akapp: NSButton added (click toggles background)\n"); fflush(stderr);
        }
    }
    Class NSTextField = objc_getClass("NSTextField");
    if (NSTextField && content) {
        id tf = ((id(*)(id,SEL))objc_msgSend)((id)NSTextField, S("alloc"));
        CGRect tfr = { { 120.0, 80.0 }, { 240.0, 28.0 } };
        tf = ((id(*)(id,SEL,CGRect))objc_msgSend)(tf, S("initWithFrame:"), tfr);
        if (tf) {
            id ph = NSStr("type here");
            if (ph) ((void(*)(id,SEL,id))objc_msgSend)(tf, S("setStringValue:"), ph);
            ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), tf);
            fprintf(stderr, "akapp: NSTextField added\n"); fflush(stderr);
        }
    }

    ((void(*)(id,SEL,id))objc_msgSend)(win, S("makeKeyAndOrderFront:"), (id)0);
    ((void(*)(id,SEL,id))objc_msgSend)(app, S("activateIgnoringOtherApps:"), (id)1);
    ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    fprintf(stderr, "akapp: window front + displayed; entering event pump\n"); fflush(stderr);

    Class NSDate = objc_getClass("NSDate");
    id mode = NSStr("kCFRunLoopDefaultMode");

    long n = 0, events = 0;
    for (;;) {
        id until = NSDate ? ((id(*)(id,SEL,double))objc_msgSend)((id)NSDate, S("dateWithTimeIntervalSinceNow:"), 1.0) : 0;
        id ev = ((id(*)(id,SEL,unsigned long,id,id,signed char))objc_msgSend)(
            app, S("nextEventMatchingMask:untilDate:inMode:dequeue:"),
            NSAnyEventMask, until, mode, (signed char)1);
        if (ev) {
            long type = ((long(*)(id,SEL))objc_msgSend)(ev, S("type"));
            CGPoint loc = ((CGPoint(*)(id,SEL))objc_msgSend)(ev, S("locationInWindow"));
            events++;
            const char* hitName = "?";
            id content2 = ((id(*)(id,SEL))objc_msgSend)(win, S("contentView"));
            id frameView = content2 ? ((id(*)(id,SEL))objc_msgSend)(content2, S("superview")) : 0;
            if (frameView) {
                id hit = ((id(*)(id,SEL,CGPoint))objc_msgSend)(frameView, S("hitTest:"), loc);
                if (hit) hitName = object_getClassName(hit);
            }
            const char* chars = "";
            if (type == 10 || type == 11) {
                id cs = ((id(*)(id,SEL))objc_msgSend)(ev, S("characters"));
                if (cs) { const char* u = CStr(cs); if (u) chars = u; }
            }
            fprintf(stderr, "akapp: event type=%ld at (%.0f,%.0f) hit=%s chars='%s' [#%ld]\n",
                    type, loc.x, loc.y, hitName, chars, events);
            fflush(stderr);
            ((void(*)(id,SEL,id))objc_msgSend)(app, S("sendEvent:"), ev);
        }
        n++;
        if ((n % 3) == 0) {
            ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
        }
        if (n == 5 && g_btn) {
            fprintf(stderr, "akapp: performClick: (programmatic) — expect background flip\n");
            fflush(stderr);
            ((void(*)(id,SEL,id))objc_msgSend)(g_btn, S("performClick:"), (id)0);
        }
        if ((n % 10) == 0) {
            fprintf(stderr, "akapp: pump alive (waits=%ld events=%ld)\n", n, events);
            fflush(stderr);
        }
    }
    return 0;
}
