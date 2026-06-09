/*
 * xprobe.c — minimal raw-Xlib client for Darwin_Computa GUI bring-up (S28).
 *
 * Purpose: isolate the in-process X11 wire-server -> SDL bridge WITHOUT the
 * whole AppKit/CoreGraphics stack. It does the bare libX11 dance:
 *   XOpenDisplay(":0") -> XCreateSimpleWindow -> XMapWindow -> XFlush
 * then sits in a short event loop. If the emulator's kunixsocket X11 intercept
 * (XWireServer::isXDisplayPath) hands the connect to the SDL wire server, the
 * window maps and xwireconnection.cpp logs:
 *     XWire: first window mapped (present sink=SDL)
 * which proves the GUI path end-to-end. If libX11 never connects, XOpenDisplay
 * returns NULL and we print the failure so the boot log shows it.
 *
 * We declare the handful of Xlib symbols we use directly — no X11 headers are
 * staged in the rootfs, but the ABI is stable and libX11.dylib exports them.
 * Built as an x86_64 Mach-O on the macOS host (Apple clang cross-target) and
 * run via DSERVER_INIT=/usr/bin/xprobe through the normal mldr->dyld pipeline.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* --- opaque Xlib types (we only ever pass pointers / ids around) --- */
typedef struct _XDisplay Display;
typedef unsigned long XID;
typedef XID Window;
typedef XID Drawable;
typedef XID Colormap;
typedef unsigned long Atom;

/* --- the Xlib functions we call (subset, C ABI, from libX11.dylib) --- */
extern Display* XOpenDisplay(const char* display_name);
extern int      XCloseDisplay(Display* d);
extern Window   XDefaultRootWindow(Display* d);
extern int      XDefaultScreen(Display* d);
extern unsigned long XWhitePixel(Display* d, int screen);
extern unsigned long XBlackPixel(Display* d, int screen);
extern Window   XCreateSimpleWindow(Display* d, Window parent,
                                    int x, int y,
                                    unsigned int w, unsigned int h,
                                    unsigned int border_width,
                                    unsigned long border, unsigned long background);
extern int      XStoreName(Display* d, Window w, const char* name);
extern int      XSelectInput(Display* d, Window w, long event_mask);
extern int      XMapWindow(Display* d, Window w);
extern int      XFlush(Display* d);
extern int      XSync(Display* d, int discard);
extern int      XPending(Display* d);

/* StructureNotifyMask|ExposureMask — value isn't load-bearing for the probe */
#define EVENT_MASK 0x020000L /* ExposureMask */

int main(int argc, char** argv) {
    const char* disp = getenv("DISPLAY");
    fprintf(stderr, "xprobe: starting; DISPLAY=%s\n", disp ? disp : "(unset)");
    fflush(stderr);

    Display* d = XOpenDisplay(disp);
    if (!d) {
        fprintf(stderr, "xprobe: XOpenDisplay(%s) FAILED — no X server / wire bridge\n",
                disp ? disp : ":0");
        fflush(stderr);
        return 2;
    }
    fprintf(stderr, "xprobe: XOpenDisplay OK — connected to the X wire bridge\n");
    fflush(stderr);

    int screen = XDefaultScreen(d);
    Window root = XDefaultRootWindow(d);
    unsigned long white = XWhitePixel(d, screen);
    unsigned long black = XBlackPixel(d, screen);

    Window win = XCreateSimpleWindow(d, root, 0, 0, 320, 200, 2, black, white);
    fprintf(stderr, "xprobe: created window id=0x%lx\n", (unsigned long)win);
    fflush(stderr);

    XStoreName(d, win, "Darwin_Computa X11 probe");
    XSelectInput(d, win, EVENT_MASK);
    XMapWindow(d, win);
    XFlush(d);
    XSync(d, 0);
    fprintf(stderr, "xprobe: mapped window + flushed — watch for 'XWire: first window mapped'\n");
    fflush(stderr);

    /* Keep the connection alive briefly so the wire server can present the
     * window to SDL; spin a bounded number of cycles then exit cleanly. */
    for (int i = 0; i < 50; i++) {
        XPending(d);
        XFlush(d);
        usleep(100 * 1000); /* 100ms */
    }

    fprintf(stderr, "xprobe: done; closing display\n");
    fflush(stderr);
    XCloseDisplay(d);
    return 0;
}
