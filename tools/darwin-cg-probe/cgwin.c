/*
 * cgwin.c — CoreGraphics window-creation probe for Darwin_Computa GUI bring-up (S30).
 *
 * S29's cgprobe proved that the REAL CoreGraphics stack loads its X11.backend and
 * opens a live CGS connection to the SDL wire server (CGSMainConnectionID()=1,
 * CGMainDisplayID 1024x768) — but it only QUERIED; it never created a window, so
 * no pixels reached the SDL window. cgwin goes the next step: it actually creates
 * and orders a CGS window, which inside the X11.backend's CGSConnectionX11 should
 * call XCreateWindow + XMapWindow over the same libX11 native bridge — and that
 * map is exactly the tripwire xprobe lit in S28:
 *     XWire: first window mapped (present sink=SDL)
 *
 * Chain exercised:
 *   CGSInitialize -> _CGSLoadBackend -> CGSConnectionX11
 *   CGSNewRegionWithRect(rect) -> [CGSRegion setRect:]            (the window bounds)
 *   CGSNewWindow(cid, backing, left, top, region, &wid)
 *       -> -[CGSConnectionX11 newWindow:] -> XCreateWindow        (X11.backend)
 *   CGSOrderWindow(cid, wid, kCGSOrderAbove, 0)
 *       -> -[CGSWindowX11 orderWindow:relativeTo:] -> XMapWindow   (the tripwire)
 *
 * Signatures recovered by disassembling the staged CoreGraphics (otool -tV):
 *   CGError CGSNewRegionWithRect(const CGRect *rect, CGSRegionRef *outRegion);
 *       rdi=rect-by-ptr (4 quadwords = CGRect), rsi=out region.
 *   CGError CGSNewWindow(CGSConnectionID cid, int backingStoreType,
 *                        float left, float top,
 *                        CGSRegionRef region, CGSWindowID *outWID);
 *       edi=cid, esi=backing, xmm0=left, xmm1=top, rdx=region, rcx=outWID;
 *       internally: -[CGSConnectionForID(cid) newWindow:region] then [-windowId].
 *   CGError CGSOrderWindow(CGSConnectionID cid, CGSWindowID wid,
 *                          int place, CGSWindowID relativeToWID);
 *       edi=cid, esi=wid, edx=place, ecx=relativeTo;
 *       internally: orderWindow:relativeTo: on the resolved CGSWindowX11.
 *
 * Same cross-build recipe as cgprobe (x86_64 Mach-O, -nostdlib -e _main -no_pie,
 * linked against the staged guest CoreGraphics + Foundation + libSystem). Run via
 * DSERVER_INIT=/usr/bin/cgwin through mldr->dyld under the emulator.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* --- CG / CGS types --- */
typedef unsigned int   CGDirectDisplayID;
typedef int            CGSConnectionID;
typedef int            CGSWindowID;
typedef void*          CGSRegionRef;
typedef double         CGFloat;          /* 64-bit on x86_64 */
typedef int            CGError;

/* CGRect is 4 CGFloats (origin.x, origin.y, size.width, size.height) — matches the
 * 4 quadwords CGSNewRegionWithRect reads through its rect pointer. */
typedef struct { CGFloat x, y, w, h; } CGRectLike;

/* kCGSOrderAbove = 1 (order above relativeTo; relativeTo=0 means above all). */
enum { kCGSOrderBelow = -1, kCGSOrderOut = 0, kCGSOrderAbove = 1 };
/* Backing store: 2 == kCGSBackingStoreBuffered (standard). */
enum { kCGSBackingNonRetained = 0, kCGSBackingRetained = 1, kCGSBackingBuffered = 2 };

extern void              CGSInitialize(void);
extern CGSConnectionID   CGSMainConnectionID(void);
extern CGDirectDisplayID CGMainDisplayID(void);
extern size_t            CGDisplayPixelsWide(CGDirectDisplayID);
extern size_t            CGDisplayPixelsHigh(CGDirectDisplayID);

extern CGError CGSNewRegionWithRect(const CGRectLike *rect, CGSRegionRef *outRegion);
extern CGError CGSNewWindow(CGSConnectionID cid, int backingStoreType,
                            float left, float top,
                            CGSRegionRef region, CGSWindowID *outWID);
extern CGError CGSOrderWindow(CGSConnectionID cid, CGSWindowID wid,
                              int place, CGSWindowID relativeToWID);

int main(int argc, char** argv) {
    const char* disp = getenv("DISPLAY");
    fprintf(stderr, "cgwin: starting; DISPLAY=%s\n", disp ? disp : "(unset)");
    fflush(stderr);

    fprintf(stderr, "cgwin: CGSInitialize() — bring up the X11.backend\n");
    fflush(stderr);
    CGSInitialize();

    CGSConnectionID cid = CGSMainConnectionID();
    fprintf(stderr, "cgwin: CGSMainConnectionID() = %d\n", (int)cid);
    fflush(stderr);
    if (cid <= 0) {
        fprintf(stderr, "cgwin: no CGS connection — backend did not connect; abort\n");
        fflush(stderr);
        return 2;
    }

    CGDirectDisplayID md = CGMainDisplayID();
    size_t dw = CGDisplayPixelsWide(md), dh = CGDisplayPixelsHigh(md);
    fprintf(stderr, "cgwin: CGMainDisplayID()=%u display %zux%zu\n", (unsigned)md, dw, dh);
    fflush(stderr);

    /* 1) Build a region for the window's content rect (400x300 near top-left). */
    CGRectLike rect = { 80.0, 80.0, 400.0, 300.0 };
    CGSRegionRef region = NULL;
    CGError e = CGSNewRegionWithRect(&rect, &region);
    fprintf(stderr, "cgwin: CGSNewRegionWithRect -> err=%d region=%p\n", (int)e, region);
    fflush(stderr);
    if (e != 0 || region == NULL) {
        fprintf(stderr, "cgwin: region creation failed; abort\n");
        fflush(stderr);
        return 3;
    }

    /* 2) Create the window. Inside the X11.backend this is XCreateWindow. */
    CGSWindowID wid = 0;
    e = CGSNewWindow(cid, kCGSBackingBuffered, 80.0f, 80.0f, region, &wid);
    fprintf(stderr, "cgwin: CGSNewWindow -> err=%d wid=%d\n", (int)e, (int)wid);
    fflush(stderr);
    if (e != 0 || wid == 0) {
        fprintf(stderr, "cgwin: window creation failed; abort\n");
        fflush(stderr);
        return 4;
    }

    /* 3) Order it on-screen. Inside the X11.backend this is XMapWindow — the
     *    tripwire 'XWire: first window mapped (present sink=SDL)' should fire. */
    e = CGSOrderWindow(cid, wid, kCGSOrderAbove, 0);
    fprintf(stderr, "cgwin: CGSOrderWindow(above) -> err=%d\n", (int)e);
    fflush(stderr);
    if (e != 0) {
        fprintf(stderr, "cgwin: order failed (window created but not mapped)\n");
        fflush(stderr);
    } else {
        fprintf(stderr, "cgwin: WINDOW ORDERED ON-SCREEN — watch for 'XWire: first window mapped'\n");
        fflush(stderr);
    }

    /* Hold so the wire server can present the mapped window to SDL. */
    for (int i = 0; i < 50; i++) {
        usleep(100 * 1000); /* 100ms; ~5s total */
    }

    fprintf(stderr, "cgwin: done (wid=%d)\n", (int)wid);
    fflush(stderr);
    return 0;
}
