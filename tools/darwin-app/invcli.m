/*
 * invcli.m — M84: NSInvocation dynamic method construction. Build and dispatch a method
 * call entirely at runtime: derive an NSMethodSignature for a selector, create an
 * NSInvocation, set the target/selector/arguments, invoke, and read the return value.
 * This is the reflective-dispatch machinery behind NSUndoManager (M71 used
 * prepareWithInvocationTarget:), forwardInvocation:, and XPC. Deep runtime/reflection
 * vein (continues M82 introspection + M83 KVO). Pure Foundation (M3 runtime); no networking.
 *
 * All selectors VERIFIED PRESENT in the staged guest Foundation (M22). CF linked BY PATH
 * (M17). Built -fno-objc-arc (the standard probe flag; ARC + getReturnValue: into an
 * object pointer segfaults on the host, irrelevant to this non-ARC build). Exercises BOTH
 * an OBJECT-returning method (stringByAppendingString:) and a SCALAR-returning one
 * (intValue) to confirm getReturnValue: handles both a boxed pointer and a primitive.
 *
 *   - sig for stringByAppendingString: has 3 args (self,_cmd,arg),
 *   - invoke [@"darwin" stringByAppendingString:@"-computa"] -> "darwin-computa",
 *   - invoke [@"5" intValue] -> 5 (scalar return via getReturnValue:).
 *
 *   M84-NARGS-<n>          numberOfArguments of the method signature  (== 3)
 *   M84-RET-<s>            object return value from the dynamic invoke  (== "darwin-computa")
 *   M84-INTRET-<n>         scalar (int) return value from a dynamic invoke  (== 5)
 *   M84-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- object-returning dynamic call ----------------------------- */
        NSString* target = @"darwin";
        SEL sel = @selector(stringByAppendingString:);
        NSMethodSignature* sig = [target methodSignatureForSelector:sel];
        printf("M84-NARGS-%lu\n", (unsigned long)[sig numberOfArguments]); fflush(stdout);

        NSInvocation* inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:target];
        [inv setSelector:sel];
        NSString* arg = @"-computa";
        [inv setArgument:&arg atIndex:2];       /* index 0=self, 1=_cmd, 2=first real arg */
        [inv retainArguments];
        [inv invoke];
        NSString* ret = nil;
        [inv getReturnValue:&ret];
        printf("M84-RET-%s\n", [ret UTF8String]); fflush(stdout);

        /* ---- scalar-returning dynamic call ----------------------------- */
        SEL isel = @selector(intValue);
        NSInvocation* i2 = [NSInvocation invocationWithMethodSignature:
                            [@"5" methodSignatureForSelector:isel]];
        [i2 setTarget:@"5"];
        [i2 setSelector:isel];
        [i2 invoke];
        int r2 = 0;
        [i2 getReturnValue:&r2];
        printf("M84-INTRET-%d\n", r2); fflush(stdout);

        printf("M84-DONE\n"); fflush(stdout);
    }
    return 0;
}
