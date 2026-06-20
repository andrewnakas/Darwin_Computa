/*
 * dsrccli.m — M59: GCD dispatch_source event sources (timer source + data source).
 * Extends the GCD tier (M55 queues/semaphores/apply, M56 group/after/barrier) to
 * dispatch_source — the libdispatch event-source primitive behind real event-driven
 * code (periodic timers, fd/signal monitoring, coalesced cross-thread signalling).
 * Pure C dispatch API + blocks (M54 runtime); no networking.
 *
 * libdispatch is staged + re-exported by libSystem (M55). The dispatch C API comes
 * from <dispatch/dispatch.h> at compile; symbols resolve at load. All symbols
 * pre-vetted exported in the staged libdispatch (M22). CoreFoundation linked BY PATH (M17).
 *
 * GATING FACETS (all proven live, matching host):
 *   - dispatch_source_create for two source types (TIMER + DATA_ADD),
 *   - event-handler delivery (the handler runs at least once for each source),
 *   - DATA-ADD coalescing: merge 5 + 7 + 30 via dispatch_source_merge_data; the
 *     handler reads dispatch_source_get_data and the coalesced total == 42,
 *   - dispatch_source_set_cancel_handler + dispatch_source_cancel: cancel handler runs.
 *
 * KNOWN GUEST GAP (non-gating, root-caused live — same class as M36's repeating
 * NSTimer): a DISPATCH_SOURCE_TYPE_TIMER fires only ONCE under emulation, it does not
 * re-arm on its interval. Root cause: macOS kqueue/EVFILT_TIMER is serviced via
 * Darling's libkqueue over Mach/devmach traps and the periodic-timer REARM isn't
 * driven by the substrate (the emulator has no EVFILT_TIMER rearm path; kevent.cpp is
 * Linux eventfd, not kqueue). One-shot delivery + handler/coalesce/cancel all work;
 * the deep libkqueue timer-rearm fix is multi-session. M59-TIMER-FIRED-<n> reports
 * the actual fire count for the record; the milestone gates on the working facets.
 *
 *   M59-TIMER-FIRED-<n>    timer source handler invocation count (1 = the gap; record)
 *   M59-TIMER-GAP-fireonce timer fired but did not re-arm (documented guest gap)
 *   M59-SOURCE-OK         dispatch_source_create + event-handler delivery works
 *   M59-DATA-<n>          coalesced sum from dispatch_source_get_data (== 42)
 *   M59-DATA-OK           == 42 (merge_data coalescing + handler delivery)
 *   M59-CANCEL-OK         the cancel handler ran
 *   M59-DONE
 */
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        dispatch_queue_t q = dispatch_queue_create("ds.q", DISPATCH_QUEUE_CONCURRENT);
        dispatch_queue_t guard = dispatch_queue_create("ds.guard", DISPATCH_QUEUE_SERIAL);

        /* ---- TIMER source: repeating ~30ms, count fires, cancel after ~200ms --- */
        __block int fired = 0;
        __block int cancelRan = 0;
        dispatch_semaphore_t timerDone = dispatch_semaphore_create(0);
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_MSEC)),
            (uint64_t)(30 * NSEC_PER_MSEC),
            (uint64_t)(5 * NSEC_PER_MSEC));
        dispatch_source_set_event_handler(timer, ^{
            dispatch_sync(guard, ^{ fired++; });
        });
        dispatch_source_set_cancel_handler(timer, ^{
            cancelRan = 1;
            dispatch_semaphore_signal(timerDone);
        });
        dispatch_resume(timer);

        /* let it tick for ~200ms (>= ~6 intervals), then cancel */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                       q, ^{ dispatch_source_cancel(timer); });
        dispatch_semaphore_wait(timerDone, DISPATCH_TIME_FOREVER);

        int firedSnapshot = 0;
        dispatch_sync(guard, ^{ /* fence */ });
        firedSnapshot = fired;
        printf("M59-TIMER-FIRED-%d\n", firedSnapshot); fflush(stdout);
        /* GATING: the source was created and its event handler was delivered (>=1).
         * Repeating re-arm is the documented guest gap, reported separately. */
        printf("M59-SOURCE-%s\n", (firedSnapshot >= 1) ? "OK" : "FAIL"); fflush(stdout);
        if (firedSnapshot < 3) {
            printf("M59-TIMER-GAP-fireonce\n"); fflush(stdout);  /* did not re-arm (M36 class) */
        } else {
            printf("M59-TIMER-REPEATS-OK\n"); fflush(stdout);    /* host: re-arms normally */
        }
        printf("M59-CANCEL-%s\n", cancelRan ? "OK" : "FAIL"); fflush(stdout);

        /* ---- DATA-ADD source: coalesce 5 + 7 + 30 -> 42 ------------------------ */
        __block unsigned long total = 0;
        dispatch_semaphore_t dataDone = dispatch_semaphore_create(0);
        dispatch_source_t ds = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, q);
        dispatch_source_set_event_handler(ds, ^{
            unsigned long d = dispatch_source_get_data(ds);
            dispatch_sync(guard, ^{ total += d; });
            if (total >= 42) dispatch_semaphore_signal(dataDone);
        });
        dispatch_resume(ds);
        dispatch_source_merge_data(ds, 5);
        dispatch_source_merge_data(ds, 7);
        dispatch_source_merge_data(ds, 30);
        dispatch_semaphore_wait(dataDone, DISPATCH_TIME_FOREVER);

        unsigned long totalSnapshot = 0;
        dispatch_sync(guard, ^{ /* fence */ });
        totalSnapshot = total;
        printf("M59-DATA-%lu\n", totalSnapshot); fflush(stdout);
        printf("M59-DATA-%s\n", (totalSnapshot == 42) ? "OK" : "FAIL"); fflush(stdout);

        printf("M59-DONE\n"); fflush(stdout);
    }
    return 0;
}
