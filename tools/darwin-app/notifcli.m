/*
 * notifcli.m — M70: NSNotificationCenter (observer / publish-subscribe). The
 * foundational Cocoa decoupling mechanism — objects post named notifications and any
 * number of observers receive them, carrying an optional object + userInfo dict. This
 * exercises both the classic selector-based observer AND the block-based observer
 * (M54 blocks), plus userInfo delivery and removeObserver. Pure Foundation (M3
 * runtime) + the block runtime (M54); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22).
 * NSNotificationCenter is Foundation; CoreFoundation linked BY PATH (M17).
 *
 *   - selector observer: addObserver:selector:name:object:, post -> handler runs,
 *     reads userInfo[@"k"] == "v",
 *   - block observer: addObserverForName:object:queue:usingBlock:, post -> block runs,
 *   - removeObserver: then post -> the selector handler does NOT run again.
 *
 *   M70-SEL-1            selector observer received the notification  (count == 1)
 *   M70-USERINFO-<s>      userInfo[@"k"] delivered to the handler  (== "v")
 *   M70-BLOCK-1          block observer received the notification  (count == 1)
 *   M70-REMOVED-1        after removeObserver:, a re-post does NOT re-fire (still 1)
 *   M70-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

static int g_selCount = 0;
static const char* g_userInfoVal = "none";

@interface M70Observer : NSObject
- (void)onNote:(NSNotification*)n;
@end
@implementation M70Observer
- (void)onNote:(NSNotification*)n {
    g_selCount++;
    id v = [[n userInfo] objectForKey:@"k"];
    if (v) g_userInfoVal = [v UTF8String];
}
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        NSString* kName = @"M70.Event";

        /* ---- selector-based observer ------------------------------------ */
        M70Observer* obs = [[M70Observer alloc] init];
        [nc addObserver:obs selector:@selector(onNote:) name:kName object:nil];
        [nc postNotificationName:kName object:nil userInfo:@{ @"k": @"v" }];
        printf("M70-SEL-%d\n", g_selCount); fflush(stdout);
        printf("M70-USERINFO-%s\n", g_userInfoVal); fflush(stdout);

        /* ---- block-based observer (M54 blocks) -------------------------- */
        __block int blockCount = 0;
        id token = [nc addObserverForName:kName object:nil queue:nil
                               usingBlock:^(NSNotification* n) { blockCount++; }];
        [nc postNotificationName:kName object:nil];
        printf("M70-BLOCK-%d\n", blockCount); fflush(stdout);

        /* ---- removeObserver: stops delivery ----------------------------- */
        [nc removeObserver:obs];
        int before = g_selCount;
        [nc postNotificationName:kName object:nil];   /* obs is removed -> no re-fire */
        printf("M70-REMOVED-%d\n", (g_selCount == before) ? 1 : 0); fflush(stdout);

        [nc removeObserver:token];
        printf("M70-DONE\n"); fflush(stdout);
    }
    return 0;
}
