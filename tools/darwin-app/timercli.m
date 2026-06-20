/*
 * timercli.m — M36: event-loop machinery via NSTimer + NSRunLoop. A fundamental
 * runtime capability distinct from the synchronous data/format probes: scheduling
 * deferred work and pumping the run loop to deliver it — the substrate GUI apps and
 * async code depend on. Pure Foundation (the proven M3 runtime); no networking.
 *
 * All selectors used were VERIFIED PRESENT in the staged guest Foundation before
 * authoring (the M22 lesson). NSRunLoop/NSTimer + the NSDefaultRunLoopMode constant
 * are CF-resident, so build-timercli.sh links CoreFoundation BY PATH (the M17 finding).
 *
 * GATED on what the guest does correctly: schedule a ONE-SHOT NSTimer on the current
 * run loop, pump the run loop, and confirm the callback is DELIVERED and NSDate time
 * advanced (the loop actually waited and dispatched the event).
 *
 * KNOWN GUEST GAPS (non-gating, like the M17 ICU weekday / M28 grouping findings):
 *   1) a REPEATING NSTimer fires only ONCE under emulation (a first version of this
 *      probe with repeats:YES + a run-until-count>=3 loop saw FIRED-1, never 3);
 *   2) -[NSThread sleepForTimeInterval:] HANGS under emulation (the first version
 *      wedged the process right after the run-loop section). We avoid both: one-shot
 *      timer, and no NSThread sleep — timing is measured via NSDate around the
 *      run-loop pump instead.
 *
 *   M36-FIRED-<n>          one-shot timer callbacks delivered (== 1)
 *   M36-FIRED-OK          the one-shot timer fired (run loop delivered the event)
 *   M36-ELAPSED-OK        NSDate advanced across the run-loop pump (loop waited)
 *   M36-MAINTHREAD-<n>    isMainThread (1)
 *   M36-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

@interface Ticker : NSObject { @public int count; }
- (void)onTick:(NSTimer*)t;
@end
@implementation Ticker
- (void)onTick:(NSTimer*)t { count++; }
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        Ticker* tk = [[Ticker alloc] init];
        tk->count = 0;

        NSRunLoop* rl = [NSRunLoop currentRunLoop];
        /* ONE-SHOT timer (repeats:NO) — the reliable case in-guest. */
        [NSTimer scheduledTimerWithTimeInterval:0.05
                                         target:tk
                                       selector:@selector(onTick:)
                                       userInfo:nil
                                        repeats:NO];

        NSDate* start = [NSDate date];
        /* Pump the run loop in short slices until the callback fires or a ~2s cap. */
        while (tk->count < 1 && [[NSDate date] timeIntervalSinceDate:start] < 2.0) {
            NSDate* until = [NSDate dateWithTimeIntervalSinceNow:0.05];
            [rl runMode:NSDefaultRunLoopMode beforeDate:until];
        }
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:start];

        printf("M36-FIRED-%d\n", tk->count); fflush(stdout);
        printf("M36-FIRED-%s\n", (tk->count >= 1) ? "OK" : "FAIL"); fflush(stdout);
        printf("M36-ELAPSED-%s\n", (elapsed >= 0.03) ? "OK" : "FAIL"); fflush(stdout);
        printf("M36-MAINTHREAD-%d\n", [NSThread isMainThread] ? 1 : 0); fflush(stdout);

        printf("M36-DONE\n"); fflush(stdout);
    }
    return 0;
}
