/*
 * akrun.c — the S36 INTERACTIVE AppKit probe for Darwin_Computa.
 *
 * akwin (S31-S35) proved the window path: NSWindow -> X11Window -> XCreateWindow/
 * XMapWindow -> XWire -> SDL, and S36 lit the present path (flushBuffer ->
 * QuartzCore renderSurface -> trap libGL/libEGL -> gl64 host bridge -> pixels in
 * the SDL window). akrun goes the last step: a LIVE app with a real event pump,
 * so host keyboard/mouse (SDL -> XWire KeyPress/ButtonPress -> the backend's
 * X11Display event source -> NSEvent) actually reaches AppKit, and the window
 * stays up for a human to test.
 *
 *   [NSApplication sharedApplication]; window + red background; orderFront
 *   loop: ev = [app nextEventMatchingMask:NSAnyEventMask
 *                untilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]
 *                inMode:NSDefaultRunLoopMode dequeue:YES]
 *         -> log "akrun: event type=N at (x,y)" (THE input tripwire)
 *         -> [app sendEvent:ev]
 *         re-[win display] every ~2s so the window keeps presenting.
 *
 * NSEvent types (proof decoding): 1=LeftMouseDown 2=LeftMouseUp 5=MouseMoved
 * 10=KeyDown 11=KeyUp. Pair with the emulator's BW64_FAKEINPUT=1 instrument
 * (xwirepresentSDL) which injects a synthetic click + 'a' keypress after the
 * first presented frame — autonomous end-to-end input verification.
 *
 * Same cross-build recipe as akwin (see akwin.c header).
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>

typedef void* id;
typedef void* Class;
typedef void* SEL;
typedef id (*IMP)(id, SEL, ...);
extern id   objc_getClass(const char* name);
extern SEL  sel_registerName(const char* name);
extern id objc_msgSend(id self, SEL op, ...);
/* Runtime class creation — lets this header-less probe own a target/action
 * method (the button click handler) without compiling ObjC. */
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

/* ---- the button's target (runtime-created class) -------------------------
 * Clicking the NSButton fires -[AkTarget bump:]: toggle the window background
 * red<->blue and log — VISIBLE proof that a click traveled host SDL -> X11
 * wire -> AppKit -> NSButton hit-test -> target/action. */
static id g_win = 0;
static id g_btn = 0;
static long g_clicks = 0;

static id ak_bump(id self, SEL _cmd, id sender) {
    g_clicks++;
    fprintf(stderr, "akrun: BUTTON CLICKED! (count=%ld) — toggling background\n", g_clicks);
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

int main(int argc, char** argv) {
    fprintf(stderr, "akrun: starting; DISPLAY=%s\n", getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
    fflush(stderr);

    Class NSApplication = objc_getClass("NSApplication");
    if (!NSApplication) { fprintf(stderr, "akrun: NSApplication missing\n"); return 2; }
    id app = ((id(*)(id,SEL))objc_msgSend)((id)NSApplication, S("sharedApplication"));
    if (!app) { fprintf(stderr, "akrun: sharedApplication nil\n"); return 3; }
    ((void(*)(id,SEL,long))objc_msgSend)(app, S("setActivationPolicy:"), (long)NSApplicationActivationPolicyRegular);
    fprintf(stderr, "akrun: NSApplication up\n"); fflush(stderr);

    Class NSWindow = objc_getClass("NSWindow");
    if (!NSWindow) { fprintf(stderr, "akrun: NSWindow missing\n"); return 4; }
    id win = ((id(*)(id,SEL))objc_msgSend)((id)NSWindow, S("alloc"));
    CGRect frame = { { 100.0, 100.0 }, { 480.0, 320.0 } };
    unsigned long style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
    win = ((id(*)(id,SEL,CGRect,unsigned long,unsigned long,signed char))objc_msgSend)(
        win, S("initWithContentRect:styleMask:backing:defer:"),
        frame, style, (unsigned long)NSBackingStoreBuffered, (signed char)0);
    if (!win) { fprintf(stderr, "akrun: window init nil\n"); return 5; }
    fprintf(stderr, "akrun: NSWindow = %p\n", win); fflush(stderr);

    Class NSString = objc_getClass("NSString");
    if (NSString) {
        id title = ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSString, S("stringWithUTF8String:"), "Darwin_Computa — akrun");
        if (title) ((void(*)(id,SEL,id))objc_msgSend)(win, S("setTitle:"), title);
    }
    Class NSColor = objc_getClass("NSColor");
    if (NSColor) {
        id red = ((id(*)(id,SEL))objc_msgSend)((id)NSColor, S("redColor"));
        if (red) ((void(*)(id,SEL,id))objc_msgSend)(win, S("setBackgroundColor:"), red);
    }

    /* S37: real controls. A button that toggles the background color when
     * clicked (target/action through a runtime-created class) and a text field
     * to type into — the window visibly RESPONDS to input. */
    g_win = win;
    id content = ((id(*)(id,SEL))objc_msgSend)(win, S("contentView"));
    Class NSObject = objc_getClass("NSObject");
    Class AkTarget = objc_allocateClassPair(NSObject, "AkTarget", 0);
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
            if (NSString) {
                id bt = ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSString, S("stringWithUTF8String:"), "Click me!");
                if (bt) ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTitle:"), bt);
            }
            if (target) {
                ((void(*)(id,SEL,id))objc_msgSend)(btn, S("setTarget:"), target);
                ((void(*)(id,SEL,SEL))objc_msgSend)(btn, S("setAction:"), S("bump:"));
            }
            ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), btn);
            g_btn = btn;
            fprintf(stderr, "akrun: NSButton added (click toggles background)\n"); fflush(stderr);
        }
    }
    Class NSTextField = objc_getClass("NSTextField");
    if (NSTextField && content) {
        id tf = ((id(*)(id,SEL))objc_msgSend)((id)NSTextField, S("alloc"));
        CGRect tfr = { { 120.0, 80.0 }, { 240.0, 28.0 } };
        tf = ((id(*)(id,SEL,CGRect))objc_msgSend)(tf, S("initWithFrame:"), tfr);
        if (tf) {
            if (NSString) {
                id ph = ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSString, S("stringWithUTF8String:"), "type here");
                if (ph) ((void(*)(id,SEL,id))objc_msgSend)(tf, S("setStringValue:"), ph);
            }
            ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), tf);
            fprintf(stderr, "akrun: NSTextField added\n"); fflush(stderr);
        }
    }

    ((void(*)(id,SEL,id))objc_msgSend)(win, S("makeKeyAndOrderFront:"), (id)0);
    ((void(*)(id,SEL,id))objc_msgSend)(app, S("activateIgnoringOtherApps:"), (id)1);
    ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    fprintf(stderr, "akrun: window front + displayed; entering event pump\n"); fflush(stderr);

    Class NSDate = objc_getClass("NSDate");
    id mode = NSString ? ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSString, S("stringWithUTF8String:"), "kCFRunLoopDefaultMode") : 0;

    /* Event pump: 1s timeout per wait so we can periodically re-display and emit
     * a heartbeat even with no input. Logs EVERY NSEvent — the input tripwire. */
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
            /* S37 diag: which view does this event actually land on? Ground
             * truth for the click-coordinate translation (X11 top-down y vs
             * AppKit bottom-up y vs titlebar offset). hitTest: from the frame
             * view (contentView's superview) covers controls + titlebar. */
            const char* hitName = "?";
            id content2 = ((id(*)(id,SEL))objc_msgSend)(win, S("contentView"));
            id frameView = content2 ? ((id(*)(id,SEL))objc_msgSend)(content2, S("superview")) : 0;
            if (frameView) {
                id hit = ((id(*)(id,SEL,CGPoint))objc_msgSend)(frameView, S("hitTest:"), loc);
                if (hit) hitName = object_getClassName(hit);
            }
            /* Key events: log the translated characters — the XIM/XLookupString
             * verdict. Empty chars on type=10 == the keymap/XIM path is broken. */
            const char* chars = "";
            if (type == 10 || type == 11) {
                id cs = ((id(*)(id,SEL))objc_msgSend)(ev, S("characters"));
                if (cs) {
                    const char* u = ((const char*(*)(id,SEL))objc_msgSend)(cs, S("UTF8String"));
                    if (u) chars = u;
                }
            }
            fprintf(stderr, "akrun: event type=%ld at (%.0f,%.0f) hit=%s chars='%s' [#%ld]\n",
                    type, loc.x, loc.y, hitName, chars, events);
            fflush(stderr);
            ((void(*)(id,SEL,id))objc_msgSend)(app, S("sendEvent:"), ev);
        }
        n++;
        if ((n % 3) == 0) {
            ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
        }
        /* S37 diag: prove the action+redraw path independent of hit-testing —
         * fire the button programmatically once. The background flipping to
         * blue ON ITS OWN a few seconds after the window appears == target/
         * action + setBackgroundColor + display all work; any remaining
         * deadness is purely click->view coordinate translation. */
        if (n == 5 && g_btn) {
            fprintf(stderr, "akrun: performClick: (programmatic) — expect background flip\n");
            fflush(stderr);
            ((void(*)(id,SEL,id))objc_msgSend)(g_btn, S("performClick:"), (id)0);
        }
        if ((n % 10) == 0) {
            fprintf(stderr, "akrun: pump alive (waits=%ld events=%ld)\n", n, events);
            fflush(stderr);
        }
    }
    return 0;
}
