/*
 * neturl.m — M4b: high-level URL loading via ASYNC NSURLConnection + a delegate,
 * pumping NSRunLoop myself.
 *
 * M4 proved the transport (DNS + TCP + parsed HTTP over the guest->host socket
 * bridge). The high-level loaders failed: NSURLSession throws on
 * +[__NSCFURLSessionConfiguration defaultSessionConfiguration]; NSURLConnection
 * +sendSynchronousRequest: returns -1015 (chunked) / -1001 (its PRIVATE runloop
 * completion never fires). This probe drives NSURLConnection ASYNCHRONOUSLY with
 * a delegate scheduled on the CURRENT run loop, then pumps that run loop in a
 * bounded loop — so completion depends on a run loop I control, not CFNetwork's
 * private one. If the delegate callbacks fire, a real high-level URL load
 * completes on the substrate (the M4b goal).
 *
 *   N4B-START                connection created + started
 *   N4B-RESPONSE-<code>      connection:didReceiveResponse: (HTTP status)
 *   N4B-DATA-<n>             cumulative bytes via connection:didReceiveData:
 *   N4B-FINISH-<total>       connectionDidFinishLoading: (success — the gate)
 *   N4B-FAIL-<err>           connection:didFailWithError:
 *   N4B-TIMEOUT              run loop pumped N iterations with no terminal callback
 *   N4B-DONE
 *
 * Target httpforever.com: plain HTTP (no TLS), reliably reachable, and crucially
 * a NON-chunked Content-Length body. The first attempt (example.com, chunked) got
 * N4B-RESPONSE-200 — the delegate callbacks DO fire on the pumped run loop, the
 * run-loop machinery works — but then N4B-FAIL -1015
 * (NSURLErrorCannotDecodeContentData): CFNetwork's CHUNKED transfer decoder is
 * the actual bug, not the run loop. A Content-Length body never invokes that
 * decoder, so connectionDidFinishLoading: should fire (N4B-FINISH). See
 * [[darwin-computa-networking-m4]].
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

// The delegate prints per-host tagged lines so ONE boot can probe several hosts
// and we see exactly which (reachability x framing) combination completes.
@interface Collector : NSObject
@property(nonatomic) BOOL done;
@property(nonatomic) long total;
@property(nonatomic, copy) NSString* tag;
@end

@implementation Collector
- (void)connection:(NSURLConnection*)c didReceiveResponse:(NSURLResponse*)resp {
    long code = -1;
    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
        code = (long)[(NSHTTPURLResponse*)resp statusCode];
    }
    printf("N4B-%s-RESPONSE-%ld\n", [self.tag UTF8String], code); fflush(stdout);
}
- (void)connection:(NSURLConnection*)c didReceiveData:(NSData*)data {
    self.total += (long)[data length];
}
- (void)connectionDidFinishLoading:(NSURLConnection*)c {
    printf("N4B-%s-FINISH-%ld\n", [self.tag UTF8String], self.total); fflush(stdout);
    self.done = YES;
}
- (void)connection:(NSURLConnection*)c didFailWithError:(NSError*)error {
    printf("N4B-%s-FAIL-%ld\n", [self.tag UTF8String], (long)[error code]); fflush(stdout);
    self.done = YES;
}
@end

// Fetch one URL via async NSURLConnection on a run loop we pump ourselves, with a
// bounded budget. Returns after a terminal delegate callback or timeout, printing
// N4B-<tag>-{RESPONSE,FINISH,FAIL,TIMEOUT}. Reusing one process for several hosts
// keeps each candidate to ~seconds instead of a fresh 6-8min boot.
static void fetch(const char* tag, NSString* urlStr) {
    @autoreleasepool {
        printf("N4B-%s-START\n", tag); fflush(stdout);
        NSURL* url = [NSURL URLWithString:urlStr];
        NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url
                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                        timeoutInterval:20.0];
        [req setValue:@"close" forHTTPHeaderField:@"Connection"];
        Collector* col = [[Collector alloc] init];
        col.tag = [NSString stringWithUTF8String:tag];
        NSURLConnection* conn = [[NSURLConnection alloc] initWithRequest:req
                                                               delegate:col
                                                       startImmediately:NO];
        [conn scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        [conn start];
        NSRunLoop* rl = [NSRunLoop currentRunLoop];
        int iters = 0;
        const int maxIters = 250; // 250 * 0.1s = 25s ceiling per host
        while (!col.done && iters < maxIters) {
            @autoreleasepool {
                [rl runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
            iters++;
        }
        if (!col.done) { printf("N4B-%s-TIMEOUT\n", tag); fflush(stdout); }
    }
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // Probe several hosts in ONE boot. CF = Cloudflare-fronted (chunked, but
        // proven guest-reachable in M4); CL = a Content-Length (non-chunked) host.
        // Whichever prints N4B-*-FINISH is the M4b proof; the matrix also tells us
        // whether failures are decode (-1015 after a RESPONSE) vs reachability
        // (-1001/timeout with no RESPONSE).
        fetch("EXAMPLE", @"http://example.com/");      // chunked, reachable
        fetch("HTTPFOREVER", @"http://httpforever.com/"); // Content-Length
        fetch("GNU", @"http://www.gnu.org/licenses/gpl-3.0.txt"); // Content-Length, big
        printf("N4B-DONE\n"); fflush(stdout);
    }
    return 0;
}
