/*
 * opqcli.m — M61: NSOperationQueue + NSBlockOperation. The higher-level Cocoa
 * concurrency abstraction that sits ABOVE GCD (M55-M57): an operation queue
 * schedules NSOperation objects, honoring inter-operation DEPENDENCIES and a
 * max-concurrency cap, and can block until all operations finish. This is the
 * NSOperation runtime, distinct from the raw libdispatch C API. Pure Foundation
 * (M3 runtime) + the block runtime (M54); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation before authoring
 * (M22). NSOperationQueue/NSBlockOperation are Foundation classes; CoreFoundation
 * linked BY PATH (M17). The block runtime resolves via libSystem (M54).
 *
 *   - addOperationWithBlock: enqueue 3 blocks on a serial queue (max concurrency 1),
 *     each appends its tag under a guarded mutable string; waitUntilAll... then the
 *     count is 3 (all ran),
 *   - DEPENDENCIES: with maxConcurrent > 1, make opA depend on opB depend on opC;
 *     the dependency graph forces execution order C -> B -> A regardless of add order,
 *     producing the ordered string "CBA",
 *   - NSBlockOperation executes its block synchronously when started directly (start).
 *
 *   M61-RAN-<n>            count of the 3 serial-queue block ops that ran  (== 3)
 *   M61-ORDER-<s>          dependency-forced order string  (== "CBA")
 *   M61-BLOCKOP-OK        a directly-started NSBlockOperation ran its block
 *   M61-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSLock* lock = [[NSLock alloc] init];

        /* ---- serial queue: 3 block ops all run ---------------------------- */
        __block int ran = 0;
        NSOperationQueue* serial = [[NSOperationQueue alloc] init];
        [serial setMaxConcurrentOperationCount:1];
        for (int i = 0; i < 3; i++) {
            [serial addOperationWithBlock:^{
                [lock lock]; ran++; [lock unlock];
            }];
        }
        [serial waitUntilAllOperationsAreFinished];
        printf("M61-RAN-%d\n", ran); fflush(stdout);

        /* ---- dependencies force order C -> B -> A ------------------------- */
        NSMutableString* order = [NSMutableString string];
        NSOperationQueue* q = [[NSOperationQueue alloc] init];
        [q setMaxConcurrentOperationCount:4];   /* concurrent; deps must serialize */
        NSBlockOperation* opA = [NSBlockOperation blockOperationWithBlock:^{
            [lock lock]; [order appendString:@"A"]; [lock unlock];
        }];
        NSBlockOperation* opB = [NSBlockOperation blockOperationWithBlock:^{
            [lock lock]; [order appendString:@"B"]; [lock unlock];
        }];
        NSBlockOperation* opC = [NSBlockOperation blockOperationWithBlock:^{
            [lock lock]; [order appendString:@"C"]; [lock unlock];
        }];
        [opA addDependency:opB];   /* A waits for B */
        [opB addDependency:opC];   /* B waits for C */
        /* add in a deliberately-wrong order; dependencies must still yield CBA */
        [q addOperation:opA];
        [q addOperation:opB];
        [q addOperation:opC];
        [q waitUntilAllOperationsAreFinished];
        printf("M61-ORDER-%s\n", [order UTF8String]); fflush(stdout);

        /* ---- a directly-started NSBlockOperation runs its block ----------- */
        __block int blockOpRan = 0;
        NSBlockOperation* solo = [NSBlockOperation blockOperationWithBlock:^{
            blockOpRan = 1;
        }];
        [solo start];   /* synchronous on the calling thread */
        printf("M61-BLOCKOP-%s\n", blockOpRan ? "OK" : "FAIL"); fflush(stdout);

        printf("M61-DONE\n"); fflush(stdout);
    }
    return 0;
}
