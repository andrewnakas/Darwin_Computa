/*
 * gcd2cli.m — M56: GCD coordination primitives (dispatch_group / dispatch_after /
 * dispatch_barrier). Deepens M55's GCD proof to the COORDINATION patterns real
 * concurrent code uses: fan out N tasks into a group and wait for all, run deferred
 * work with dispatch_after, and serialize a write on a concurrent queue with a
 * barrier. Pure C dispatch API + blocks (M54 runtime); no networking.
 *
 * libdispatch is staged + re-exported by libSystem (M55). The dispatch C API comes
 * from <dispatch/dispatch.h> at compile; symbols resolve at load. All symbols
 * pre-vetted exported (M22). CoreFoundation linked BY PATH (M17).
 *
 *   - dispatch_group: enqueue 4 tasks (each adds 1 under a serial guard) to a group,
 *     dispatch_group_wait FOREVER, then the count == 4,
 *   - dispatch_after: schedule a block ~50ms out, wait on a semaphore -> it ran,
 *   - dispatch_barrier_sync: on a concurrent queue, a barrier block runs exclusively
 *     and sets a flag -> ran.
 *
 *   M56-GROUP-<n>          count after dispatch_group_wait of 4 grouped tasks (== 4)
 *   M56-GROUP-OK          all four group tasks completed before wait returned
 *   M56-AFTER-OK          a dispatch_after block ran (semaphore signalled)
 *   M56-BARRIER-OK        a dispatch_barrier_sync block ran on a concurrent queue
 *   M56-DONE
 */
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        dispatch_queue_t conc = dispatch_queue_create("dc.conc", DISPATCH_QUEUE_CONCURRENT);
        dispatch_queue_t guard = dispatch_queue_create("dc.guard", DISPATCH_QUEUE_SERIAL);

        /* ---- dispatch_group: fan out 4, wait for all --------------------- */
        __block int count = 0;
        dispatch_group_t grp = dispatch_group_create();
        for (int i = 0; i < 4; i++) {
            dispatch_group_async(grp, conc, ^{
                dispatch_sync(guard, ^{ count++; });
            });
        }
        dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);
        printf("M56-GROUP-%d\n", count); fflush(stdout);
        printf("M56-GROUP-%s\n", (count == 4) ? "OK" : "FAIL"); fflush(stdout);

        /* ---- dispatch_after: deferred block ------------------------------ */
        __block int afterRan = 0;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC));
        dispatch_after(when, conc, ^{
            afterRan = 1;
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        printf("M56-AFTER-%s\n", afterRan ? "OK" : "FAIL"); fflush(stdout);

        /* ---- dispatch_barrier_sync on a concurrent queue ----------------- */
        __block int barrierRan = 0;
        dispatch_barrier_sync(conc, ^{ barrierRan = 1; });
        printf("M56-BARRIER-%s\n", barrierRan ? "OK" : "FAIL"); fflush(stdout);

        printf("M56-DONE\n"); fflush(stdout);
    }
    return 0;
}
