/*
 * pipecli2.m — M73: NSPipe + NSFileHandle pipe I/O. The in-process / inter-process
 * byte-pipe primitive (the channel behind NSTask subprocess stdin/stdout wiring): an
 * NSPipe gives a connected read-end + write-end NSFileHandle pair; write bytes to one,
 * read them from the other. Extends M37 (single-handle FD I/O) with the pipe pair.
 * Pure Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). NSPipe/
 * NSFileHandle are Foundation; CoreFoundation linked BY PATH (M17).
 *
 * To avoid a blocking read, the probe writes a known payload, CLOSES the write end
 * (so the read end sees EOF), then reads. It uses readDataOfLength: for the exact
 * byte count and a second pipe + readDataToEndOfFile for the read-to-EOF path.
 *
 *   - pipe A: write "DARWIN" (6 bytes), close write end, readDataOfLength:6 -> "DARWIN",
 *   - pipe B: write "computa pipe" , close write end, readDataToEndOfFile -> 12 bytes ==,
 *   - the read-end handle's fileDescriptor is a valid (>=0) descriptor.
 *
 *   M73-LEN-<n>            bytes read via readDataOfLength:  (== 6)
 *   M73-DATA-<s>           the round-tripped payload  (== "DARWIN")
 *   M73-EOFLEN-<n>         readDataToEndOfFile length  (== 12)
 *   M73-EOFDATA-<s>        the EOF-read payload  (== "computa pipe")
 *   M73-FD-1              read-end fileDescriptor is valid (>= 0)
 *   M73-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- pipe A: exact-length read ---------------------------------- */
        NSPipe* a = [NSPipe pipe];
        NSFileHandle* aw = [a fileHandleForWriting];
        NSFileHandle* ar = [a fileHandleForReading];
        [aw writeData:[@"DARWIN" dataUsingEncoding:NSUTF8StringEncoding]];
        [aw closeFile];                      /* signal EOF to the read end */
        NSData* got = [ar readDataOfLength:6];
        printf("M73-LEN-%lu\n", (unsigned long)[got length]); fflush(stdout);
        NSString* gotStr = [[NSString alloc] initWithData:got encoding:NSUTF8StringEncoding];
        printf("M73-DATA-%s\n", [gotStr UTF8String]); fflush(stdout);

        int fd = [ar fileDescriptor];
        printf("M73-FD-%d\n", (fd >= 0) ? 1 : 0); fflush(stdout);
        [ar closeFile];

        /* ---- pipe B: read to EOF ---------------------------------------- */
        NSPipe* b = [NSPipe pipe];
        NSFileHandle* bw = [b fileHandleForWriting];
        NSFileHandle* br = [b fileHandleForReading];
        [bw writeData:[@"computa pipe" dataUsingEncoding:NSUTF8StringEncoding]];
        [bw closeFile];
        NSData* all = [br readDataToEndOfFile];
        printf("M73-EOFLEN-%lu\n", (unsigned long)[all length]); fflush(stdout);
        NSString* allStr = [[NSString alloc] initWithData:all encoding:NSUTF8StringEncoding];
        printf("M73-EOFDATA-%s\n", [allStr UTF8String]); fflush(stdout);
        [br closeFile];

        printf("M73-DONE\n"); fflush(stdout);
    }
    return 0;
}
