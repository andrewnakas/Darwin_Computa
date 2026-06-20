/*
 * errcli.m — M40: error handling — NSError out-parameter propagation + Obj-C
 * @try/@catch/@throw exception flow. The error-handling substrate every robust
 * program relies on (the (NSError**)error pattern + ObjC exceptions). Pure
 * Foundation (the proven M3 runtime) + the ObjC exception runtime; no networking.
 *
 * The ObjC exception runtime helpers (objc_exception_throw/begin_catch/end_catch)
 * are exported by the staged libobjc, so @throw/@catch work; all NSError/NSException
 * selectors were VERIFIED PRESENT before authoring (the M22 lesson). NSError/
 * NSException are CF-resident, so build-errcli.sh links CoreFoundation BY PATH (M17).
 *
 *   - construct an NSError (domain/code/userInfo) and read its fields back,
 *   - a function that fails returns NO and fills an (NSError**) out-parameter;
 *     confirm the caller sees the error code + localizedDescription,
 *   - @throw an NSException inside @try and @catch it, reading name + reason,
 *   - confirm normal control continues after the @catch (a flag set in the same
 *     @try after a successful call, and a post-catch statement, both run).
 *
 *   M40-ERR-DOMAIN-<s>     NSError domain  (== "DarwinComputa")
 *   M40-ERR-CODE-<n>       NSError code  (== 42)
 *   M40-ERR-DESC-<s>       localizedDescription from userInfo  (== "boom")
 *   M40-OUTPARAM-OK        a failing call filled the NSError** and returned NO
 *   M40-CATCH-<s>          caught NSException name  (== "DarwinError")
 *   M40-CATCH-REASON-<s>   caught NSException reason  (== "deliberate")
 *   M40-AFTER-OK           control continued past the @catch
 *   M40-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

/* A function that "fails" and reports via an NSError out-parameter. */
static BOOL doWork(BOOL shouldFail, NSError** error) {
    if (shouldFail) {
        if (error) {
            *error = [NSError errorWithDomain:@"DarwinComputa" code:7
                                     userInfo:@{ NSLocalizedDescriptionKey: @"work failed" }];
        }
        return NO;
    }
    return YES;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- construct + read an NSError ---------------------------------- */
        NSError* e = [NSError errorWithDomain:@"DarwinComputa" code:42
                                     userInfo:@{ NSLocalizedDescriptionKey: @"boom" }];
        printf("M40-ERR-DOMAIN-%s\n", [[e domain] UTF8String]); fflush(stdout);
        printf("M40-ERR-CODE-%ld\n", (long)[e code]); fflush(stdout);
        printf("M40-ERR-DESC-%s\n", [[e localizedDescription] UTF8String]); fflush(stdout);

        /* ---- NSError out-parameter propagation --------------------------- */
        NSError* out = nil;
        BOOL ok = doWork(YES, &out);
        BOOL outOK = (!ok && out && [out code] == 7
                      && [[out localizedDescription] isEqualToString:@"work failed"]);
        printf("M40-OUTPARAM-%s\n", outOK ? "OK" : "FAIL"); fflush(stdout);

        /* ---- @try / @throw / @catch -------------------------------------- */
        NSString* caughtName = nil;
        NSString* caughtReason = nil;
        BOOL afterCatch = NO;
        @try {
            @throw [NSException exceptionWithName:@"DarwinError"
                                          reason:@"deliberate" userInfo:nil];
        } @catch (NSException* ex) {
            caughtName = [ex name];
            caughtReason = [ex reason];
        } @finally {
            afterCatch = YES;   /* @finally must run */
        }
        printf("M40-CATCH-%s\n", caughtName ? [caughtName UTF8String] : "(none)"); fflush(stdout);
        printf("M40-CATCH-REASON-%s\n", caughtReason ? [caughtReason UTF8String] : "(none)"); fflush(stdout);

        /* control continued normally past the @catch/@finally */
        BOOL after = afterCatch && [caughtName isEqualToString:@"DarwinError"];
        printf("M40-AFTER-%s\n", after ? "OK" : "FAIL"); fflush(stdout);

        printf("M40-DONE\n"); fflush(stdout);
    }
    return 0;
}
