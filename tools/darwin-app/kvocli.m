/*
 * kvocli.m — M83: Key-Value Observing (KVO). A cornerstone Cocoa mechanism — automatic
 * change notification when an observed property mutates — and the engine behind bindings.
 * KVO's AUTOMATIC path works by isa-swizzling: on addObserver:, the runtime synthesizes a
 * subclass that overrides the setter to fire observeValueForKeyPath:. This is a deep
 * runtime test (distinct from M70 NSNotificationCenter pub/sub + M58 KVC). Pure Foundation
 * (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). CF linked BY PATH
 * (M17). Probes BOTH the automatic path (setter -> notification, needs isa-swizzling) AND
 * the manual path (willChangeValueForKey:/didChangeValueForKey:) so the result precisely
 * characterizes which KVO mechanism the substrate supports.
 *
 *   - addObserver:forKeyPath:@"value" options:New, then m.value=42 (automatic),
 *     observer's observeValueForKeyPath: should fire with change[New]==42,
 *   - manual: willChangeValueForKey:@"manual" / set / didChangeValueForKey: should fire too.
 *
 *   M83-AUTOHITS-<n>       observer fire count after the automatic setter  (host == 1)
 *   M83-AUTOLAST-<n>       change[New] delivered by the automatic path  (host == 42)
 *   M83-AUTO-<OK|GAP-noswizzle>   automatic isa-swizzling KVO worked / did not
 *   M83-MANUALHITS-<n>     fire count after manual will/didChangeValueForKey:
 *   M83-MANUAL-<OK|GAP>    the manual KVO path worked / did not
 *   M83-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

@interface Model : NSObject
@property (assign) NSInteger value;
@property (assign) NSInteger manual;
@end
@implementation Model
@end

@interface Obs : NSObject
@property (assign) int hits;
@property (assign) NSInteger last;
@end
@implementation Obs
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object
                        change:(NSDictionary*)change context:(void*)context {
    self.hits++;
    id v = [change objectForKey:NSKeyValueChangeNewKey];
    if (v) self.last = [v integerValue];
}
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        Model* m = [Model new];

        /* ---- automatic KVO (isa-swizzling on the setter) --------------- */
        Obs* autoObs = [Obs new];
        [m addObserver:autoObs forKeyPath:@"value"
               options:NSKeyValueObservingOptionNew context:NULL];
        m.value = 42;                       /* should fire via synthesized setter */
        printf("M83-AUTOHITS-%d\n", autoObs.hits); fflush(stdout);
        printf("M83-AUTOLAST-%ld\n", (long)autoObs.last); fflush(stdout);
        printf("M83-AUTO-%s\n",
               (autoObs.hits == 1 && autoObs.last == 42) ? "OK" : "GAP-noswizzle"); fflush(stdout);
        [m removeObserver:autoObs forKeyPath:@"value"];

        /* ---- manual KVO (explicit will/didChange) ---------------------- */
        Obs* manObs = [Obs new];
        [m addObserver:manObs forKeyPath:@"manual"
               options:NSKeyValueObservingOptionNew context:NULL];
        [m willChangeValueForKey:@"manual"];
        [m setManual:7];                    /* mutate, explicitly bracketed by will/did */
        [m didChangeValueForKey:@"manual"];
        printf("M83-MANUALHITS-%d\n", manObs.hits); fflush(stdout);
        printf("M83-MANUAL-%s\n", (manObs.hits >= 1) ? "OK" : "GAP"); fflush(stdout);
        [m removeObserver:manObs forKeyPath:@"manual"];

        printf("M83-DONE\n"); fflush(stdout);
    }
    return 0;
}
