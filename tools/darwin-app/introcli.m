/*
 * introcli.m — M82: NSObject runtime introspection + dynamic dispatch. The reflective
 * core of the Objective-C runtime that real frameworks (KVC, archiving, bindings, XPC)
 * lean on: class membership tests, selector probing, protocol conformance, and DYNAMIC
 * method dispatch via performSelector:. Exercises the objc runtime directly. Pure
 * Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). Avoids every known
 * broken class (no ICU date/text-seg, no NSDecimalNumberHandler rounding, no block text-
 * enumeration). CoreFoundation linked BY PATH (M17).
 *
 *   - [@"x" isKindOfClass:[NSString class]]            -> YES (NSString IS-A NSObject sub),
 *   - [@5 isKindOfClass:[NSString class]]              -> NO  (NSNumber is not NSString),
 *   - [@"x" respondsToSelector:@selector(uppercaseString)] -> YES,
 *   - [@"x" respondsToSelector:@selector(bogusXYZ)]    -> NO,
 *   - [@"darwin" performSelector:@selector(uppercaseString)] -> "DARWIN",
 *   - [@"a,b,c" performSelector:@selector(componentsSeparatedByString:) withObject:@","] -> 3 items,
 *   - [@"x" conformsToProtocol:@protocol(NSCopying)]   -> YES (NSString is copyable).
 *
 *   M82-KIND-1            NSString instance isKindOfClass:NSString
 *   M82-KINDNO-0          NSNumber instance is NOT isKindOfClass:NSString
 *   M82-RESP-1            respondsToSelector: a real selector
 *   M82-RESPNO-0          respondsToSelector: a bogus selector
 *   M82-PERFORM-<s>       performSelector: dynamic dispatch result  (== "DARWIN")
 *   M82-PERFORMARG-<n>    performSelector:withObject: result count  (== 3)
 *   M82-PROTO-1           conformsToProtocol:NSCopying
 *   M82-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- class membership ------------------------------------------ */
        NSString* s = @"x";
        NSNumber* n = @5;
        printf("M82-KIND-%d\n", [s isKindOfClass:[NSString class]] ? 1 : 0); fflush(stdout);
        printf("M82-KINDNO-%d\n", [n isKindOfClass:[NSString class]] ? 1 : 0); fflush(stdout);

        /* ---- selector probing ------------------------------------------ */
        printf("M82-RESP-%d\n", [s respondsToSelector:@selector(uppercaseString)] ? 1 : 0); fflush(stdout);
        printf("M82-RESPNO-%d\n", [s respondsToSelector:@selector(bogusSelectorXYZ)] ? 1 : 0); fflush(stdout);

        /* ---- dynamic dispatch: performSelector: ------------------------ */
        id up = [@"darwin" performSelector:@selector(uppercaseString)];
        printf("M82-PERFORM-%s\n", [(NSString*)up UTF8String]); fflush(stdout);

        /* ---- dynamic dispatch with an argument ------------------------- */
        id parts = [@"a,b,c" performSelector:@selector(componentsSeparatedByString:)
                                   withObject:@","];
        printf("M82-PERFORMARG-%lu\n", (unsigned long)[(NSArray*)parts count]); fflush(stdout);

        /* ---- protocol conformance -------------------------------------- */
        printf("M82-PROTO-%d\n", [s conformsToProtocol:@protocol(NSCopying)] ? 1 : 0); fflush(stdout);

        printf("M82-DONE\n"); fflush(stdout);
    }
    return 0;
}
