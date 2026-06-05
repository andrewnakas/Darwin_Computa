/*
 *  Copyright (C) 2012-2026  The BoxedWine Team
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#include "boxedwine.h"

#ifdef BOXEDWINE_DARWIN

#include <cstdio>

// --darwin-selftest: the Darwin/_dev/mach trap-layer smoke test. Mirrors
// runX64SelfTest()'s role for the 64-bit core: a CI-able, headless assertion
// that the emulated Darling kernel interface answers correctly.
//
// Phase A: this is a placeholder that reports the harness is wired. Phase B
// fills it in to open /dev/mach and assert get_api_version returns the pinned
// DARLING_MACH_API_VERSION, then grows alongside the trap dispatcher.
int runDarwinSelfTest() {
    printf("\n=== Darwin_Computa self-test ===\n");
    printf("darwin-selftest: harness wired (Phase A).\n");
    printf("darwin-selftest: /dev/mach trap assertions land in Phase B.\n");
    printf("=== darwin-selftest: 0 checks, 0 failures (placeholder) ===\n");
    return 0;
}

#endif // BOXEDWINE_DARWIN
