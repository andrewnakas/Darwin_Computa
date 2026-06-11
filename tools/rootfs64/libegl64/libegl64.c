/*
 *  Copyright (C) 2012-2026  The BoxedWine Team
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

// Guest libEGL.so.1 for the Darling GUI path. Darling's OpenGL.framework
// implements CGL on EGL (src/frameworks/OpenGL/OpenGL.c): CGLRegisterNativeDisplay
// -> eglGetDisplay/eglInitialize/eglChooseConfig/eglBindAPI, CGLGetWindow ->
// eglCreateWindowSurface(display, config, X_WINDOW_XID, NULL), CGLCreateContext ->
// eglCreateContext, CGLSetCurrentContext -> eglMakeCurrent, CGLFlushDrawable ->
// eglSwapBuffers. The Mesa libEGL this replaces needs DRI drivers (swrast =
// LLVM under emulation) and can never initialize here.
//
// This shim maps that EGL surface onto the SAME host gl64 bridge the trap
// libGL.so.1 uses (see tools/rootfs64/libgl64 + source/opengl/gl64bridge*):
//   - an EGLSurface IS the X window XID it was created for (non-zero, opaque
//     to the caller; CGL just passes it back to eglMakeCurrent/eglSwapBuffers)
//   - eglCreateContext  -> GL64_fn_glXCreateContext   (host SDL GL context)
//   - eglMakeCurrent    -> GL64_fn_glXMakeCurrent(drawable=XID, ctx)
//   - eglSwapBuffers    -> GL64_fn_glXSwapBuffers(XID) (host glReadPixels ->
//     BGRX -> X11-wire present sink -> the SDL window)
// Display/config handles are constants; there is one host context.
//
// Freestanding like libgl64.c: no libc headers, no DT_NEEDED.

typedef unsigned char       uint8_t;
typedef unsigned int        uint32_t;
typedef int                 int32_t;
typedef unsigned long long  uint64_t;
typedef unsigned long       uintptr_t;

static int egl_strcmp(const char* a, const char* b) {
    while (*a && (*a == *b)) { a++; b++; } return (int)((unsigned char)*a) - (int)((unsigned char)*b);
}

// ---- ABI shared with the host (gl64bridge_abi.h conventions) ---------------
#define GL64_SYSCALL_NR  ((uint64_t)0x474C0000ULL)
#define GL64_MAX_ARGS 16
typedef struct GL64Args { uint64_t a[GL64_MAX_ARGS]; } GL64Args;

enum {
    GL64_fn_glXCreateContext = 5,
    GL64_fn_glXMakeCurrent = 12,
    GL64_fn_glXSwapBuffers = 14,
    GL64_fn_glXDestroyContext = 15,
    GL64_fn_glXSwapIntervalEXT = 23
};

static inline uint64_t gl64_trap(uint64_t fnId, GL64Args* args) {
    uint64_t ret;
    register uint64_t rdi __asm__("rdi") = fnId;
    register uint64_t rsi __asm__("rsi") = (uint64_t)(uintptr_t)args;
    __asm__ __volatile__(
        "syscall"
        : "=a"(ret)
        : "a"(GL64_SYSCALL_NR), "r"(rdi), "r"(rsi)
        : "rcx", "r11", "memory");
    return ret;
}

#define API __attribute__((visibility("default")))

// ---- EGL types + constants (self-contained) ---------------------------------
typedef void*        EGLDisplay;
typedef void*        EGLConfig;
typedef void*        EGLContext;
typedef void*        EGLSurface;
typedef void*        EGLClientBuffer;
typedef void*        EGLSync;
typedef void*        EGLImage;
typedef int32_t      EGLint;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef uint64_t     EGLTime;
typedef unsigned long EGLNativeWindowType;   // the X11 Window XID
typedef void*        EGLNativeDisplayType;
typedef unsigned long EGLNativePixmapType;

#define EGL_TRUE   1u
#define EGL_FALSE  0u
#define EGL_SUCCESS 0x3000
#define EGL_VENDOR 0x3053
#define EGL_VERSION 0x3054
#define EGL_EXTENSIONS 0x3055
#define EGL_CLIENT_APIS 0x308D

// One fake display/config; one tracked current context+surface (CGL drives a
// single GL window per process here; the host bridge has one context anyway).
#define EGL_DPY ((EGLDisplay)0x4547u)   // any non-zero value ('EG')
#define EGL_CFG ((EGLConfig)0x1u)

static EGLContext g_currentCtx = 0;
static EGLSurface g_currentSurf = 0;

// ---- core EGL ---------------------------------------------------------------
API EGLDisplay eglGetDisplay(EGLNativeDisplayType native) {
    (void)native;
    return EGL_DPY;
}
API EGLDisplay eglGetPlatformDisplay(EGLenum platform, void* native, const EGLint* attribs) {
    (void)platform; (void)native; (void)attribs;
    return EGL_DPY;
}
API EGLBoolean eglInitialize(EGLDisplay dpy, EGLint* major, EGLint* minor) {
    (void)dpy;
    if (major) *major = 1;
    if (minor) *minor = 4;
    return EGL_TRUE;
}
API EGLBoolean eglTerminate(EGLDisplay dpy) { (void)dpy; return EGL_TRUE; }
API EGLint eglGetError(void) { return EGL_SUCCESS; }
API EGLBoolean eglBindAPI(EGLenum api) { (void)api; return EGL_TRUE; }
API EGLenum eglQueryAPI(void) { return 0x30A2; /* EGL_OPENGL_API */ }
API EGLBoolean eglReleaseThread(void) { return EGL_TRUE; }

API const char* eglQueryString(EGLDisplay dpy, EGLint name) {
    (void)dpy;
    switch (name) {
        case EGL_VENDOR:      return "Boxedwine64";
        case EGL_VERSION:     return "1.4 Boxedwine64";
        case EGL_CLIENT_APIS: return "OpenGL";
        case EGL_EXTENSIONS:
        default:              return "";
    }
}

API EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint* attribs,
                               EGLConfig* configs, EGLint size, EGLint* num) {
    (void)dpy; (void)attribs;
    if (configs && size >= 1) configs[0] = EGL_CFG;
    if (num) *num = (configs && size >= 1) ? 1 : 1;
    return EGL_TRUE;
}
API EGLBoolean eglGetConfigs(EGLDisplay dpy, EGLConfig* configs, EGLint size, EGLint* num) {
    return eglChooseConfig(dpy, 0, configs, size, num);
}
API EGLBoolean eglGetConfigAttrib(EGLDisplay dpy, EGLConfig config, EGLint attrib, EGLint* value) {
    (void)dpy; (void)config;
    if (!value) return EGL_TRUE;
    switch (attrib) {
        case 0x3033 /*EGL_SURFACE_TYPE*/:    *value = 0x4 /*EGL_WINDOW_BIT*/; break;
        case 0x3040 /*EGL_RENDERABLE_TYPE*/: *value = 0x8 /*EGL_OPENGL_BIT*/; break;
        case 0x302E /*EGL_NATIVE_VISUAL_ID*/:*value = 0x21; break;
        case 0x3025 /*EGL_DEPTH_SIZE*/:      *value = 24; break;
        default:                             *value = 8; break;   // R/G/B/A sizes etc.
    }
    return EGL_TRUE;
}

// The EGLSurface handle IS the native X window XID: CGL stores it and hands it
// straight back to eglMakeCurrent/eglSwapBuffers, and the host present pipeline
// is keyed by that same XID (XWire window registry).
API EGLSurface eglCreateWindowSurface(EGLDisplay dpy, EGLConfig config,
                                      EGLNativeWindowType window, const EGLint* attribs) {
    (void)dpy; (void)config; (void)attribs;
    return (EGLSurface)window;
}
API EGLSurface eglCreatePlatformWindowSurface(EGLDisplay dpy, EGLConfig config,
                                              void* native_window, const EGLint* attribs) {
    // native_window is a pointer to the window handle on this path.
    unsigned long win = native_window ? *(unsigned long*)native_window : 0;
    (void)dpy; (void)config; (void)attribs;
    return (EGLSurface)win;
}
API EGLSurface eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config, const EGLint* attribs) {
    (void)dpy; (void)config; (void)attribs;
    return (EGLSurface)0x1; // off-screen: any non-zero handle; never presented
}
API EGLSurface eglCreatePixmapSurface(EGLDisplay dpy, EGLConfig config,
                                      EGLNativePixmapType pixmap, const EGLint* attribs) {
    (void)dpy; (void)config; (void)attribs;
    return (EGLSurface)pixmap;
}
API EGLSurface eglCreatePlatformPixmapSurface(EGLDisplay dpy, EGLConfig config,
                                              void* pixmap, const EGLint* attribs) {
    (void)dpy; (void)config; (void)attribs; (void)pixmap;
    return (EGLSurface)0x1;
}
API EGLSurface eglCreatePbufferFromClientBuffer(EGLDisplay dpy, EGLenum buftype,
                                                EGLClientBuffer buffer, EGLConfig config,
                                                const EGLint* attribs) {
    (void)dpy; (void)buftype; (void)buffer; (void)config; (void)attribs;
    return (EGLSurface)0x1;
}
API EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface surface) {
    (void)dpy;
    if (surface == g_currentSurf) g_currentSurf = 0;
    return EGL_TRUE;
}

API EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config,
                                EGLContext share, const EGLint* attribs) {
    (void)dpy; (void)config; (void)attribs;
    GL64Args a = {{0}};
    a.a[0] = 0;                          // vis* (unused by the host)
    a.a[1] = (uint64_t)(uintptr_t)share;
    a.a[2] = 1;                          // direct
    uint64_t ctx = gl64_trap(GL64_fn_glXCreateContext, &a);
    return (EGLContext)(uintptr_t)ctx;   // 0 == EGL_NO_CONTEXT on host failure
}
API EGLBoolean eglDestroyContext(EGLDisplay dpy, EGLContext ctx) {
    (void)dpy;
    GL64Args a = {{0}};
    a.a[0] = (uint64_t)(uintptr_t)ctx;
    (void)gl64_trap(GL64_fn_glXDestroyContext, &a);
    if (ctx == g_currentCtx) g_currentCtx = 0;
    return EGL_TRUE;
}

API EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx) {
    (void)dpy; (void)read;
    GL64Args a = {{0}};
    a.a[0] = (uint64_t)(uintptr_t)draw;  // the X window XID (or 0 to unbind)
    a.a[1] = (uint64_t)(uintptr_t)ctx;
    uint64_t ok = gl64_trap(GL64_fn_glXMakeCurrent, &a);
    if (ok || !ctx) { g_currentCtx = ctx; g_currentSurf = draw; }
    return (ctx && !ok) ? EGL_FALSE : EGL_TRUE;
}
API EGLContext eglGetCurrentContext(void) { return g_currentCtx; }
API EGLDisplay eglGetCurrentDisplay(void) { return g_currentCtx ? EGL_DPY : 0; }
API EGLSurface eglGetCurrentSurface(EGLint readdraw) { (void)readdraw; return g_currentSurf; }

API EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
    (void)dpy;
    GL64Args a = {{0}};
    a.a[0] = (uint64_t)(uintptr_t)surface;   // XID -> host readback + present
    (void)gl64_trap(GL64_fn_glXSwapBuffers, &a);
    return EGL_TRUE;
}
API EGLBoolean eglSwapInterval(EGLDisplay dpy, EGLint interval) {
    (void)dpy;
    GL64Args a = {{0}};
    a.a[0] = (uint64_t)(uintptr_t)g_currentSurf;
    a.a[1] = (uint64_t)(uint32_t)interval;
    (void)gl64_trap(GL64_fn_glXSwapIntervalEXT, &a);
    return EGL_TRUE;
}
API EGLBoolean eglCopyBuffers(EGLDisplay dpy, EGLSurface surface, EGLNativePixmapType target) {
    (void)dpy; (void)surface; (void)target;
    return EGL_TRUE;
}

API EGLBoolean eglQueryContext(EGLDisplay dpy, EGLContext ctx, EGLint attrib, EGLint* value) {
    (void)dpy; (void)ctx; (void)attrib;
    if (value) *value = 0;
    return EGL_TRUE;
}
API EGLBoolean eglQuerySurface(EGLDisplay dpy, EGLSurface surface, EGLint attrib, EGLint* value) {
    (void)dpy; (void)surface; (void)attrib;
    if (value) *value = 0;
    return EGL_TRUE;
}
API EGLBoolean eglSurfaceAttrib(EGLDisplay dpy, EGLSurface surface, EGLint attrib, EGLint value) {
    (void)dpy; (void)surface; (void)attrib; (void)value;
    return EGL_TRUE;
}
API EGLBoolean eglBindTexImage(EGLDisplay dpy, EGLSurface surface, EGLint buffer) {
    (void)dpy; (void)surface; (void)buffer;
    return EGL_TRUE;
}
API EGLBoolean eglReleaseTexImage(EGLDisplay dpy, EGLSurface surface, EGLint buffer) {
    (void)dpy; (void)surface; (void)buffer;
    return EGL_TRUE;
}

API EGLBoolean eglWaitClient(void) { return EGL_TRUE; }
API EGLBoolean eglWaitGL(void) { return EGL_TRUE; }
API EGLBoolean eglWaitNative(EGLint engine) { (void)engine; return EGL_TRUE; }

// Sync/image objects: benign handles, immediate completion (single host context,
// strictly ordered trap stream — nothing to synchronize).
API EGLSync eglCreateSync(EGLDisplay dpy, EGLenum type, const EGLint* attribs) {
    (void)dpy; (void)type; (void)attribs;
    return (EGLSync)0x1;
}
API EGLBoolean eglDestroySync(EGLDisplay dpy, EGLSync sync) { (void)dpy; (void)sync; return EGL_TRUE; }
API EGLint eglClientWaitSync(EGLDisplay dpy, EGLSync sync, EGLint flags, EGLTime timeout) {
    (void)dpy; (void)sync; (void)flags; (void)timeout;
    return 0x30F6; // EGL_CONDITION_SATISFIED
}
API EGLBoolean eglWaitSync(EGLDisplay dpy, EGLSync sync, EGLint flags) {
    (void)dpy; (void)sync; (void)flags;
    return EGL_TRUE;
}
API EGLBoolean eglGetSyncAttrib(EGLDisplay dpy, EGLSync sync, EGLint attrib, EGLint* value) {
    (void)dpy; (void)sync; (void)attrib;
    if (value) *value = 0x30F2; // EGL_SIGNALED
    return EGL_TRUE;
}
API EGLImage eglCreateImage(EGLDisplay dpy, EGLContext ctx, EGLenum target,
                            EGLClientBuffer buffer, const EGLint* attribs) {
    (void)dpy; (void)ctx; (void)target; (void)buffer; (void)attribs;
    return 0; // EGL_NO_IMAGE: callers (none on the CGL path) must fall back
}
API EGLBoolean eglDestroyImage(EGLDisplay dpy, EGLImage image) { (void)dpy; (void)image; return EGL_TRUE; }

// ---- eglGetProcAddress -------------------------------------------------------
typedef void (*EGLproc)(void);
struct eglProcEntry { const char* name; EGLproc fn; };
#define E(n) { #n, (EGLproc)n }
static const struct eglProcEntry g_eglProcs[] = {
    E(eglGetDisplay), E(eglGetPlatformDisplay), E(eglInitialize), E(eglTerminate),
    E(eglGetError), E(eglBindAPI), E(eglQueryAPI), E(eglReleaseThread),
    E(eglQueryString), E(eglChooseConfig), E(eglGetConfigs), E(eglGetConfigAttrib),
    E(eglCreateWindowSurface), E(eglCreatePlatformWindowSurface),
    E(eglCreatePbufferSurface), E(eglCreatePixmapSurface),
    E(eglCreatePlatformPixmapSurface), E(eglCreatePbufferFromClientBuffer),
    E(eglDestroySurface), E(eglCreateContext), E(eglDestroyContext),
    E(eglMakeCurrent), E(eglGetCurrentContext), E(eglGetCurrentDisplay),
    E(eglGetCurrentSurface), E(eglSwapBuffers), E(eglSwapInterval),
    E(eglCopyBuffers), E(eglQueryContext), E(eglQuerySurface), E(eglSurfaceAttrib),
    E(eglBindTexImage), E(eglReleaseTexImage), E(eglWaitClient), E(eglWaitGL),
    E(eglWaitNative), E(eglCreateSync), E(eglDestroySync), E(eglClientWaitSync),
    E(eglWaitSync), E(eglGetSyncAttrib), E(eglCreateImage), E(eglDestroyImage),
};
#undef E
#define NEGLPROCS (sizeof(g_eglProcs)/sizeof(g_eglProcs[0]))

API EGLproc eglGetProcAddress(const char* name) {
    if (!name) return 0;
    for (unsigned i = 0; i < NEGLPROCS; i++) {
        if (egl_strcmp(g_eglProcs[i].name, name) == 0) return g_eglProcs[i].fn;
    }
    return 0;
}
