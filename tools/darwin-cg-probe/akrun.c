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
extern id   objc_getClass(const char* name);
extern SEL  sel_registerName(const char* name);
extern id objc_msgSend(id self, SEL op, ...);

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
            fprintf(stderr, "akrun: event type=%ld at (%.0f,%.0f) [#%ld]\n", type, loc.x, loc.y, events);
            fflush(stderr);
            ((void(*)(id,SEL,id))objc_msgSend)(app, S("sendEvent:"), ev);
        }
        n++;
        if ((n % 3) == 0) {
            ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
        }
        if ((n % 10) == 0) {
            fprintf(stderr, "akrun: pump alive (waits=%ld events=%ld)\n", n, events);
            fflush(stderr);
        }
    }
    return 0;
}
