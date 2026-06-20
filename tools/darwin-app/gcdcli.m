/*
 * gcdcli.m — M55: Grand Central Dispatch (libdispatch) C API. A major Darwin
 * concurrency subsystem, built on the Obj-C block runtime (proven M54) and distinct
 * from NSRunLoop (M36): dispatch a block to a queue, hand off via a semaphore,
 * synchronously dispatch, and run a parallel dispatch_apply. Pure C dispatch API +
 * blocks; no networking.
 *
 * libdispatch is staged + re-exported by libSystem; the block runtime is in
 * libsystem_blocks (M54). The dispatch C API is declared via <dispatch/dispatch.h>
 * (provided by the host SDK at compile time; the symbols resolve at load from the
 * staged libdispatch). All symbols pre-vetted exported (M22). CoreFoundation linked
 * BY PATH (M17) for consistency with the probe template.
 *
 *   - dispatch_async a block to a concurrent queue that sets a value + signals a
 *     semaphore; the main thread waits on the semaphore then reads the value -> 42,
 *   - dispatch_sync a block on a serial queue that increments a counter -> ran,
 *   - dispatch_apply 5 parallel iterations each adding its index into an atomic-ish
 *     sum guarded by a serial queue -> 0+1+2+3+4 == 10.
 *
 *   M55-ASYNC-<n>          value set by an async block, read after semaphore wait (== 42)
 *   M55-ASYNC-OK          the async block ran and handed off via the semaphore
 *   M55-SYNC-OK           a dispatch_sync block ran (counter incremented)
 *   M55-APPLY-<n>         dispatch_apply(5) sum of indices  (== 10)
 *   M55-DONE
 */
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- dispatch_async + semaphore handoff --------------------------- */
        __block int asyncVal = 0;
        dispatch_queue_t cq = dispatch_queue_create("dc.async", DISPATCH_QUEUE_CONCURRENT);
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(cq, ^{
            asyncVal = 42;
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        printf("M55-ASYNC-%d\n", asyncVal); fflush(stdout);
        printf("M55-ASYNC-%s\n", (asyncVal == 42) ? "OK" : "FAIL"); fflush(stdout);

        /* ---- dispatch_sync on a serial queue ------------------------------ */
        __block int counter = 0;
        dispatch_queue_t sq = dispatch_queue_create("dc.serial", DISPATCH_QUEUE_SERIAL);
        dispatch_sync(sq, ^{ counter++; });
        printf("M55-SYNC-%s\n", (counter == 1) ? "OK" : "FAIL"); fflush(stdout);

        /* ---- dispatch_apply parallel iteration (sum guarded by serial q) -- */
        __block int sum = 0;
        dispatch_queue_t guard = dispatch_queue_create("dc.guard", DISPATCH_QUEUE_SERIAL);
        dispatch_apply(5, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t i) {
            dispatch_sync(guard, ^{ sum += (int)i; });
        });
        printf("M55-APPLY-%d\n", sum); fflush(stdout);

        printf("M55-DONE\n"); fflush(stdout);
    }
    return 0;
}
