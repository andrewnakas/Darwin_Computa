/*
 *  Copyright (C) 2012-2026  The BoxedWine Team
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#include "boxedwine.h"

// Storage for the legacy pgl*/ext_gl* OpenGL function-pointer tables in the
// 64-bit-guest DESKTOP build.
//
// glcommon.cpp / glext.cpp (which normally define these) are compiled out for
// BOXEDWINE_GUEST_X64 because they pull in the full 32-bit GL marshaling and
// the gl64bridge replaces that path for the x64 guest. But the SDL/OSMesa GL
// backends (source/opengl/sdl/sdlgl.cpp, source/opengl/osmesa/osmesa.cpp) still
// populate pgl*/ext_gl* from {SDL,OSMesa}_GL_GetProcAddress and call
// glExtensionsLoaded() during context init — so without these definitions a
// clean x64 desktop build fails to link (undefined _pglVertex4d, … as seen from
// initSdlOpenGL/initMesaOpenGL).
//
// This unit provides ONLY the pointer storage and a no-op glExtensionsLoaded(),
// reusing the exact x-macro expansion glcommon.cpp uses. No 32-bit guest types,
// no CPU dependency — just symbol storage. It is excluded from the WASM build,
// which has no native GL header (GLH) and uses the WebGL2 gl64 backend instead.
#if defined(BOXEDWINE_OPENGL) && defined(BOXEDWINE_GUEST_X64) && !defined(__EMSCRIPTEN__)

#include GLH
#include "glcommon.h"

// pgl<func> storage (matches glcommon.cpp's "create variables to hold standard
// opengl calls" block).
#undef GL_FUNCTION
#define GL_FUNCTION(func, RET, PARAMS, ARGS, PRE, POST, LOG) gl##func##_func pgl##func;
#undef GL_FUNCTION_FMT
#define GL_FUNCTION_FMT(func, RET, PARAMS, ARGS, PRE, POST, LOG) gl##func##_func pgl##func;
#undef GL_FUNCTION_CUSTOM
#define GL_FUNCTION_CUSTOM(func, RET, PARAMS) gl##func##_func pgl##func;
// ext_gl<func> storage (matches glcommon.cpp's GL_EXT_FUNCTION storage block).
#undef GL_EXT_FUNCTION
#define GL_EXT_FUNCTION(func, RET, PARAMS) gl##func##_func ext_gl##func;

#include "glfunctions.h"

// glext.cpp normally defines this; it walks the extension string and is a no-op
// for the x64 desktop GL backends here (they probe ext_gl* directly).
void glExtensionsLoaded() {}

#endif
