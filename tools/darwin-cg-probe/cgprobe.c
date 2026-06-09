/*
 * cgprobe.c — minimal CoreGraphics client for Darwin_Computa GUI bring-up (S29).
 *
 * Purpose: drive the REAL Darwin GUI stack one layer above S28's raw-Xlib probe.
 * S28 (xprobe) proved the libX11.dylib native-bridge -> Linux libX11.so.6 ->
 * /tmp/.X11-unix/X0 -> Boxedwine x11wire -> SDL chain by calling Xlib directly.
 * This probe instead exercises CoreGraphics' own backend machinery:
 *
 *     CGSInitialize() / CGMainDisplayID() / CGSMainConnectionID()
 *        -> _CGSLoadBackend  (CoreGraphics)
 *        -> NSBundle enumerates CoreGraphics.framework/.../Resources/Backends
 *        -> loads X11.backend, takes its principal class CGSConnectionX11
 *        -> [[CGSConnectionX11 alloc] initWithConnectionID:]
 *        -> XOpenDisplay(getenv("DISPLAY"))   (links /usr/lib/native/libX11.dylib)
 *        -> [the S28-proven bridge] -> SDL window
 *
 * If the backend loads and its CGSConnectionX11 opens the display, CoreGraphics
 * is now talking to the same SDL wire server a Cocoa app would use. Failure
 * modes we want the boot log to surface:
 *   - "CGSConnectionX11: XOpenDisplay() failed"  (backend loaded, X connect died)
 *   - a missing native X extension lib dlopen (libXext/libXrender/...): stage it
 *     the S28 way (Debian .so.N at the SONAME path).
 *
 * Built as an x86_64 Mach-O on the macOS host (Apple clang cross-target) and
 * linked against the *staged guest* CoreGraphics + Foundation + libSystem so the
 * install names point at the guest frameworks and it loads under /usr/lib/dyld.
 * Run via DSERVER_INIT=/usr/bin/cgprobe through the normal mldr->dyld pipeline.
 *
 * We declare the handful of CG/CGS symbols we use directly — no CG headers are
 * staged in the rootfs, but the ABI is stable and CoreGraphics exports them.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* --- CoreGraphics / CGS types + functions we call (C ABI) --- */
typedef unsigned int   CGDirectDisplayID;
typedef int            CGSConnectionID;
typedef unsigned long  CGSize_packed; /* opaque; we only need the address */

/* CGMainDisplayID forces the display subsystem (and thus the backend) up. */
extern CGDirectDisplayID CGMainDisplayID(void);
/* CGSMainConnectionID -> _CGSDefaultConnection -> CGSInitialize -> load backend
 * -> CGSConnectionX11 initWithConnectionID: -> XOpenDisplay. THE trigger. */
extern CGSConnectionID   CGSMainConnectionID(void);
extern void              CGSInitialize(void);
extern size_t            CGDisplayPixelsWide(CGDirectDisplayID display);
extern size_t            CGDisplayPixelsHigh(CGDirectDisplayID display);

int main(int argc, char** argv) {
    const char* disp = getenv("DISPLAY");
    fprintf(stderr, "cgprobe: starting; DISPLAY=%s\n", disp ? disp : "(unset)");
    fflush(stderr);

    /* Force CoreGraphics to bring up the window-server connection. This is the
     * call that, inside CoreGraphics, runs _CGSLoadBackend (NSBundle enumerates
     * the X11.backend) and instantiates CGSConnectionX11 -> XOpenDisplay. */
    fprintf(stderr, "cgprobe: calling CGSInitialize() — expect _CGSLoadBackend -> X11.backend\n");
    fflush(stderr);
    CGSInitialize();

    fprintf(stderr, "cgprobe: calling CGSMainConnectionID()\n");
    fflush(stderr);
    CGSConnectionID cid = CGSMainConnectionID();
    fprintf(stderr, "cgprobe: CGSMainConnectionID() = %d\n", (int)cid);
    fflush(stderr);

    /* Query the main display geometry — this goes through the backend's
     * CGSConnectionX11 screen list (populated from the X server we connected to).
     * If the X connection failed the backend prints "XOpenDisplay() failed" and
     * these return 0. */
    CGDirectDisplayID main_disp = CGMainDisplayID();
    size_t w = CGDisplayPixelsWide(main_disp);
    size_t h = CGDisplayPixelsHigh(main_disp);
    fprintf(stderr, "cgprobe: CGMainDisplayID()=%u  display %zux%zu\n",
            (unsigned)main_disp, w, h);
    fflush(stderr);

    if (w == 0 || h == 0) {
        fprintf(stderr, "cgprobe: display is 0x0 — backend present but X connect likely failed\n");
    } else {
        fprintf(stderr, "cgprobe: NON-ZERO display geometry — CoreGraphics is talking to the X backend!\n");
    }
    fflush(stderr);

    /* Hold briefly so the wire server can present / so logs flush. */
    for (int i = 0; i < 30; i++) {
        usleep(100 * 1000); /* 100ms */
    }

    fprintf(stderr, "cgprobe: done\n");
    fflush(stderr);
    return (w && h) ? 0 : 3;
}
