/*
 * foundationcli.m — M3: a NORMAL Objective-C Foundation program.
 *
 * Unlike akapp.c / darwinpad.c (which hand-roll `objc_msgSend` via extern decls
 * and cast-through calls — a shim that bypasses the compiler's ObjC codegen),
 * this is REAL Objective-C: `[obj message]`, `@"literals"`, `@[...]` arrays,
 * `@autoreleasepool`. The compiler emits the genuine objc_msgSend / autorelease
 * / class-ref / selector-uniquing machinery, so running it validates dyld + the
 * ObjC runtime + Foundation through the SAME path every normal Mac tool uses.
 *
 * It is built normally (clang -fobjc-arc -framework Foundation against the staged
 * guest frameworks) — see build-foundationcli.sh.
 *
 * Each printed M3-* line only appears if real Foundation objects constructed and
 * responded, so the transcript is the proof:
 *   M3-STRING-HELLO, DARWIN     (NSString stringWithFormat: + uppercaseString)
 *   M3-ARRAY-COUNT-3            (NSArray literal + count, a scalar return)
 *   M3-JOIN-a-b-c               (componentsJoinedByString:)
 *   M3-NUM-42                   (NSNumber boxing + intValue, scalar return)
 *   M3-PROC-<name>             (NSProcessInfo processName — a live singleton)
 *   M3-DONE
 *
 * All methods used return scalars or objects (NSUInteger/int/id) — NOT structs
 * >16 bytes — so the objc_msgSend struct-return ABI trap (NSRect/NSRange) is
 * avoided entirely.
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // 1) NSString construction + a method that returns a new NSString.
        NSString* greeting = [NSString stringWithFormat:@"%@, %@", @"hello", @"darwin"];
        NSString* upper = [greeting uppercaseString];
        printf("M3-STRING-%s\n", [upper UTF8String]);
        fflush(stdout);

        // 2) NSArray literal + count (NSUInteger scalar return through msgSend).
        NSArray* parts = @[@"a", @"b", @"c"];
        printf("M3-ARRAY-COUNT-%lu\n", (unsigned long)[parts count]);
        fflush(stdout);

        // 3) componentsJoinedByString: — exercises array enumeration + NSString.
        NSString* joined = [parts componentsJoinedByString:@"-"];
        printf("M3-JOIN-%s\n", [joined UTF8String]);
        fflush(stdout);

        // 4) NSNumber boxing + intValue (int scalar return). 6*7 proves it is a
        //    real computed value flowing through the object, not a literal.
        NSNumber* n = @(6 * 7);
        printf("M3-NUM-%d\n", [n intValue]);
        fflush(stdout);

        // 5) NSProcessInfo — a live Foundation singleton with a class method.
        NSString* procName = [[NSProcessInfo processInfo] processName];
        printf("M3-PROC-%s\n", [procName UTF8String]);
        fflush(stdout);

        printf("M3-DONE\n");
        fflush(stdout);
    }
    return 0;
}
