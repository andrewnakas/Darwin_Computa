/*
 * stackprobe.c — M5a diagnosis: print what the guest's pthread stack-introspection
 * actually returns, to pinpoint WHY JSC's WTF StackBounds::isGrowingDownwards()
 * asserts (origin <= bound).
 *
 * WTF computes: origin = pthread_get_stackaddr_np(self)  (stack TOP / high addr)
 *               bound  = origin - pthread_get_stacksize_np(self)
 * and asserts origin > bound. We print stackaddr, stacksize, a local var's address
 * (which lies INSIDE the live stack), and pthread_main_np(), so we can see whether
 * stackaddr is sane (should be a high addr just above &local) or bogus (0/low), and
 * whether origin>bound actually holds.
 *
 * Pure C (no Foundation/ObjC) so it loads fast and has a tiny dependency surface.
 */
#include <stdio.h>
#include <pthread.h>

int main(int argc, char** argv) {
    int localOnStack = 0;
    void* addr = pthread_get_stackaddr_np(pthread_self());
    size_t size = pthread_get_stacksize_np(pthread_self());
    int isMain = pthread_main_np();
    unsigned long origin = (unsigned long)addr;
    unsigned long bound = origin - (unsigned long)size;

    printf("STK-ADDR-%016lx\n", origin);                 fflush(stdout);
    printf("STK-SIZE-%lx\n", (unsigned long)size);       fflush(stdout);
    printf("STK-LOCAL-%016lx\n", (unsigned long)&localOnStack); fflush(stdout);
    printf("STK-BOUND-%016lx\n", bound);                 fflush(stdout);
    printf("STK-MAIN-%d\n", isMain);                     fflush(stdout);
    // The exact WTF check. If this prints DOWN, JSC would NOT assert; if UP/EQUAL,
    // that's the bug (and the numbers above say whether addr or size is wrong).
    printf("STK-GROWS-%s\n", (origin > bound) ? "DOWN" : "UP-OR-EQ"); fflush(stdout);
    // Is the live stack pointer actually inside [bound, origin]? (sanity on addr)
    unsigned long sp = (unsigned long)&localOnStack;
    printf("STK-SPIN-%s\n", (sp <= origin && sp > bound) ? "YES" : "NO"); fflush(stdout);
    printf("STK-DONE\n"); fflush(stdout);
    (void)argc; (void)argv;
    return 0;
}
