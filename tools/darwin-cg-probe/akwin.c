/*
 * akwin.c — AppKit NSWindow probe for Darwin_Computa GUI bring-up (S31).
 *
 * S30 proved CGSNewWindow is a dead end: CoreGraphics' X11.backend implements only
 * screen/display query + input; its -[CGSConnectionX11 newWindow:] is a no-op stub
 * and it imports NO XCreateWindow/XMapWindow. The REAL window backend lives in
 * AppKit: AppKit.framework/.../Backends/X11.backend has X11Display/X11Window which
 * import XCreateWindow + XMapWindow and implement newWindowWithDelegate:/ensureMapped.
 * AppKit loads it via +[NSDisplay currentDisplay] enumerating <AppKit.framework>/Backends.
 *
 * So this probe drives the AppKit window path:
 *   [NSApplication sharedApplication]                  (init AppKit, load backend)
 *   win = [[NSWindow alloc] initWithContentRect:styleMask:backing:defer:]
 *       -> +[NSDisplay currentDisplay] -> X11Display -> -[X11Display newWindowWithDelegate:]
 *       -> X11Window -> XCreateWindow                  (the real X window)
 *   [win makeKeyAndOrderFront:nil]
 *       -> -[X11Window ensureMapped] -> XMapWindow      (the tripwire)
 * Expected log: `XWire: first window mapped (present sink=SDL)` + pixels in SDL.
 *
 * We talk to ObjC entirely through the runtime (objc_getClass/sel_registerName/
 * objc_msgSend) declared inline — no AppKit/Foundation headers are staged, but the
 * ObjC ABI is stable. CGRect is passed by value to initWithContentRect:; on x86_64
 * a 32-byte struct goes in xmm0..xmm3 per the SysV ABI, which the C compiler handles
 * when we declare the msgSend variant with the right prototype.
 *
 * Cross-built as an x86_64 Mach-O (-nostdlib -e _main -no_pie) linked against the
 * staged guest AppKit + Foundation + CoreGraphics + libSystem so install names point
 * at the guest frameworks. Run via DSERVER_INIT=/usr/bin/akwin under the emulator.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>

/* --- ObjC runtime (inline decls; libobjc is inside libSystem on Darwin) --- */
typedef void* id;
typedef void* Class;
typedef void* SEL;
extern id   objc_getClass(const char* name);
extern SEL  sel_registerName(const char* name);
/* objc_msgSend has no real prototype — we cast it per call so the C ABI marshals
 * each argument list correctly (esp. the float/struct cases). */
extern id objc_msgSend(id self, SEL op, ...);

/* CGRect (Foundation NSRect == CGRect on 64-bit): 4 doubles. */
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat w, h; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

/* NSWindowStyleMask bits */
enum {
    NSWindowStyleMaskBorderless     = 0,
    NSWindowStyleMaskTitled         = 1 << 0,
    NSWindowStyleMaskClosable       = 1 << 1,
    NSWindowStyleMaskMiniaturizable = 1 << 2,
    NSWindowStyleMaskResizable      = 1 << 3,
};
/* NSBackingStoreType */
enum { NSBackingStoreBuffered = 2 };
/* NSApplicationActivationPolicy */
enum { NSApplicationActivationPolicyRegular = 0 };

static SEL S(const char* n) { return sel_registerName(n); }

int main(int argc, char** argv) {
    const char* disp = getenv("DISPLAY");
    fprintf(stderr, "akwin: starting; DISPLAY=%s\n", disp ? disp : "(unset)");
    fflush(stderr);

    /* 1) NSApplication sharedApplication — initializes AppKit, which (lazily, on
     *    first window/display use) loads the X11 backend via NSDisplay. */
    Class NSApplication = objc_getClass("NSApplication");
    if (!NSApplication) { fprintf(stderr, "akwin: NSApplication class missing — AppKit not loaded\n"); fflush(stderr); return 2; }
    id app = ((id(*)(id,SEL))objc_msgSend)((id)NSApplication, S("sharedApplication"));
    fprintf(stderr, "akwin: NSApplication sharedApplication = %p\n", app);
    fflush(stderr);
    if (!app) { fprintf(stderr, "akwin: sharedApplication returned nil — abort\n"); fflush(stderr); return 3; }

    /* Make it a regular (windowed) app so windows can be ordered front. */
    ((void(*)(id,SEL,long))objc_msgSend)(app, S("setActivationPolicy:"), (long)NSApplicationActivationPolicyRegular);

    /* 2) Allocate + init an NSWindow. This is where +[NSDisplay currentDisplay]
     *    loads X11Display and -[X11Display newWindowWithDelegate:] -> XCreateWindow. */
    Class NSWindow = objc_getClass("NSWindow");
    if (!NSWindow) { fprintf(stderr, "akwin: NSWindow class missing — abort\n"); fflush(stderr); return 4; }
    id win = ((id(*)(id,SEL))objc_msgSend)((id)NSWindow, S("alloc"));
    fprintf(stderr, "akwin: NSWindow alloc = %p\n", win);
    fflush(stderr);

    CGRect frame = { { 100.0, 100.0 }, { 480.0, 320.0 } };
    unsigned long style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
    /* initWithContentRect:styleMask:backing:defer: — CGRect by value (xmm0..xmm3),
     * then 3 integer/long args. defer:NO so the X window is created NOW (not lazily). */
    win = ((id(*)(id,SEL,CGRect,unsigned long,unsigned long,signed char))objc_msgSend)(
        win, S("initWithContentRect:styleMask:backing:defer:"),
        frame, style, (unsigned long)NSBackingStoreBuffered, (signed char)0 /*defer:NO*/);
    fprintf(stderr, "akwin: initWithContentRect:... = %p\n", win);
    fflush(stderr);
    if (!win) { fprintf(stderr, "akwin: window init returned nil — backend likely failed to connect\n"); fflush(stderr); return 5; }

    /* Give it a title (exercises XStoreName-ish path; harmless if stubbed). */
    Class NSString = objc_getClass("NSString");
    if (NSString) {
        id title = ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSString, S("stringWithUTF8String:"), "Darwin_Computa");
        if (title) ((void(*)(id,SEL,id))objc_msgSend)(win, S("setTitle:"), title);
    }

    /* 3) Order it on-screen — drives -[X11Window ensureMapped] -> XMapWindow. */
    fprintf(stderr, "akwin: makeKeyAndOrderFront: — expect XMapWindow / 'XWire: first window mapped'\n");
    fflush(stderr);
    ((void(*)(id,SEL,id))objc_msgSend)(win, S("makeKeyAndOrderFront:"), (id)0);
    ((void(*)(id,SEL,id))objc_msgSend)(app, S("activateIgnoringOtherApps:"), (id)1);

    fprintf(stderr, "akwin: window ordered front; holding to let the wire server present\n");
    fflush(stderr);

    /* Pump a few events + hold so the backend flushes the map to x11wire -> SDL. */
    for (int i = 0; i < 60; i++) {
        /* [app nextEventMatchingMask:untilDate:inMode:dequeue:] would need NSDate;
         * a plain hold is enough to let the backend's own thread map + present. */
        usleep(100 * 1000); /* 100ms; ~6s total */
    }

    fprintf(stderr, "akwin: done\n");
    fflush(stderr);
    return 0;
}
