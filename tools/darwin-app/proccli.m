/*
 * proccli.m — M35: process + environment introspection via NSProcessInfo. A
 * fundamental runtime capability (programs read env vars, their own name, the OS
 * version, CPU/memory facts, and mint unique ids). Pure Foundation (the proven M3
 * runtime); no networking.
 *
 * Because these values describe the GUEST's own runtime (env, cpu, mem differ from
 * the host), the gating checks are STRUCTURAL — non-empty / sane-range / well-formed
 * — not exact host-equality. All selectors were VERIFIED PRESENT in the staged guest
 * Foundation before authoring (the M22 lesson). NSProcessInfo is a Foundation class;
 * we still link CoreFoundation BY PATH (M17) since the env dict / strings touch CF.
 *
 *   - environment: an NSDictionary with > 0 entries, and a key we set via the
 *     spawn env (PATH is reliably present) reads back non-empty,
 *   - processName: non-empty,
 *   - operatingSystemVersionString: non-empty (e.g. "Version 11.x ..."),
 *   - processorCount: >= 1,
 *   - physicalMemory: > 0,
 *   - globallyUniqueString: two calls differ and are non-trivially long.
 *
 *   M35-ENV-COUNT-<n>      number of environment entries (> 0)
 *   M35-ENV-HASPATH-<0|1>  PATH present + non-empty in the environment
 *   M35-PROCNAME-<s>       processName (non-empty)
 *   M35-OSVER-OK           operatingSystemVersionString is non-empty
 *   M35-CPUS-<n>           processorCount (>= 1)
 *   M35-MEM-OK             physicalMemory > 0
 *   M35-GUID-OK            two globallyUniqueString calls differ and look well-formed
 *   M35-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSProcessInfo* pi = [NSProcessInfo processInfo];

        NSDictionary* env = [pi environment];
        printf("M35-ENV-COUNT-%lu\n", (unsigned long)[env count]); fflush(stdout);
        NSString* path = [env objectForKey:@"PATH"];
        printf("M35-ENV-HASPATH-%d\n", (path && [path length] > 0) ? 1 : 0); fflush(stdout);

        NSString* name = [pi processName];
        printf("M35-PROCNAME-%s\n", (name && [name length]) ? [name UTF8String] : "(empty)"); fflush(stdout);

        NSString* osv = [pi operatingSystemVersionString];
        printf("M35-OSVER-%s\n", (osv && [osv length] > 0) ? "OK" : "FAIL"); fflush(stdout);

        printf("M35-CPUS-%lu\n", (unsigned long)[pi processorCount]); fflush(stdout);

        unsigned long long mem = [pi physicalMemory];
        printf("M35-MEM-%s\n", (mem > 0) ? "OK" : "FAIL"); fflush(stdout);

        NSString* g1 = [pi globallyUniqueString];
        NSString* g2 = [pi globallyUniqueString];
        BOOL guidOK = g1 && g2 && ![g1 isEqualToString:g2] && [g1 length] >= 8;
        printf("M35-GUID-%s\n", guidOK ? "OK" : "FAIL"); fflush(stdout);

        printf("M35-DONE\n"); fflush(stdout);
    }
    return 0;
}
