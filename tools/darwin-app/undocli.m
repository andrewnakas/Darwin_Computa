/*
 * undocli.m — M71: NSUndoManager (undo/redo edit history). The foundational Cocoa
 * mechanism behind every document app's undo stack: register an inverse action with a
 * target+selector, then -undo invokes it to revert state (and re-registers the inverse
 * so -redo works). Exercises register/undo/redo, canUndo/canRedo, and undo grouping.
 * Pure Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22) — NOTE the
 * block-based registerUndoWithTarget:handler: is ABSENT, so this probe uses the classic
 * selector-based prepareWithInvocationTarget: (NSInvocation forwarding). CoreFoundation
 * BY PATH (M17). GUEST REQUIREMENT (root-caused from a first-version live exception):
 * this Cocotron NSUndoManager THROWS 'forwardInvocation called without first opening an
 * undo group' if you register an undo with no open group — and with groupsByEvent NO
 * there is no automatic group. So every edit-registration here is wrapped in an explicit
 * beginUndoGrouping/endUndoGrouping. (This also confirms the ObjC exception runtime, M40.)
 *
 * Model: a Counter object whose -setValue: registers the inverse (set back to the old
 * value) on the undo manager. So setValue:10 then setValue:20, then -undo restores 10,
 * then -redo re-applies 20 — the standard undo/redo round trip.
 *
 *   M71-START-<n>          counter after two setValue: (10 then 20)  (== 20)
 *   M71-CANUNDO-1         canUndo is YES after edits
 *   M71-UNDO-<n>           value after -undo  (== 10)
 *   M71-CANREDO-1         canRedo is YES after an undo
 *   M71-REDO-<n>           value after -redo  (== 20)
 *   M71-GROUP-<n>          a grouped pair of edits undone as ONE step  (== 0, both reverted)
 *   M71-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

@interface Counter : NSObject
@property (assign) NSInteger value;
@property (strong) NSUndoManager* undo;
- (void)setValueUndoably:(NSNumber*)v;
@end

@implementation Counter
- (void)setValueUndoably:(NSNumber*)v {
    NSNumber* old = @(self.value);
    [[self.undo prepareWithInvocationTarget:self] setValueUndoably:old];
    self.value = [v integerValue];
}
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSUndoManager* um = [[NSUndoManager alloc] init];
        [um setGroupsByEvent:NO];          /* manual grouping for deterministic steps */
        Counter* c = [[Counter alloc] init];
        c.undo = um;

        /* ---- two undoable edits, each its own undo group: 0 -> 10 -> 20 -- */
        [um beginUndoGrouping];
        [c setValueUndoably:@10];
        [um endUndoGrouping];
        [um beginUndoGrouping];
        [c setValueUndoably:@20];
        [um endUndoGrouping];
        printf("M71-START-%ld\n", (long)c.value); fflush(stdout);
        printf("M71-CANUNDO-%d\n", [um canUndo] ? 1 : 0); fflush(stdout);

        /* ---- undo -> back to 10 ----------------------------------------- */
        [um undo];
        printf("M71-UNDO-%ld\n", (long)c.value); fflush(stdout);
        printf("M71-CANREDO-%d\n", [um canRedo] ? 1 : 0); fflush(stdout);

        /* ---- redo -> back to 20 ----------------------------------------- */
        [um redo];
        printf("M71-REDO-%ld\n", (long)c.value); fflush(stdout);

        /* ---- grouped edits undone as one step --------------------------- */
        /* reset to a clean state, then group two edits and undo once */
        Counter* g = [[Counter alloc] init];
        g.undo = um;
        [um removeAllActions];
        [um beginUndoGrouping];
        [g setValueUndoably:@1];
        [g setValueUndoably:@2];
        [um endUndoGrouping];
        [um undo];   /* one undo reverts BOTH grouped edits -> back to 0 */
        printf("M71-GROUP-%ld\n", (long)g.value); fflush(stdout);

        printf("M71-DONE\n"); fflush(stdout);
    }
    return 0;
}
