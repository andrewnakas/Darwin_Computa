/*
 * swizzlecli.m — M87: method swizzling (method_exchangeImplementations). The classic
 * runtime dispatch-table manipulation used by analytics/testing/AOP frameworks: exchange
 * two methods' IMPs on an existing class so calling selector A runs B's code and vice
 * versa. Distinct from M86 (creating a NEW class) — this MODIFIES an existing class's
 * method table at runtime. The last major objc-runtime primitive to confirm (after M82
 * introspection, M83 KVO, M84 NSInvocation, M85 C-API, M86 class creation — all clean).
 * Pure Foundation (M3 runtime) + libobjc C API; no networking.
 *
 * All symbols pre-vetted PRESENT in the staged libobjc (nm, M22). CF by-path (M17).
 * -fno-objc-arc; host-validated before the guest build.
 *
 *   - class Widget with -(NSString*)label -> "original" and -(NSString*)swizzledLabel
 *     -> "swizzled",
 *   - BEFORE swizzle: [w label] == "original",
 *   - method_exchangeImplementations(label, swizzledLabel),
 *   - AFTER swizzle: [w label] == "swizzled" (dispatch table rewired),
 *     and [w swizzledLabel] == "original" (the exchange is symmetric).
 *
 *   M87-BEFORE-<s>         [w label] before swizzling  (== "original")
 *   M87-AFTER-<s>          [w label] after the exchange  (== "swizzled")
 *   M87-SYMM-<s>           [w swizzledLabel] after the exchange  (== "original")
 *   M87-SWIZZLE-OK        the exchange rewired dispatch both ways
 *   M87-DONE
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

@interface Widget : NSObject
- (NSString*)label;
- (NSString*)swizzledLabel;
@end
@implementation Widget
- (NSString*)label        { return @"original"; }
- (NSString*)swizzledLabel { return @"swizzled"; }
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        Widget* w = [Widget new];

        NSString* before = [w label];
        printf("M87-BEFORE-%s\n", [before UTF8String]); fflush(stdout);

        /* ---- exchange the two methods' implementations ----------------- */
        Method a = class_getInstanceMethod([Widget class], @selector(label));
        Method b = class_getInstanceMethod([Widget class], @selector(swizzledLabel));
        method_exchangeImplementations(a, b);

        NSString* after = [w label];            /* now runs swizzledLabel's IMP */
        printf("M87-AFTER-%s\n", [after UTF8String]); fflush(stdout);

        NSString* symm = [w swizzledLabel];     /* now runs label's IMP (symmetric) */
        printf("M87-SYMM-%s\n", [symm UTF8String]); fflush(stdout);

        BOOL ok = [after isEqualToString:@"swizzled"] && [symm isEqualToString:@"original"];
        printf("M87-SWIZZLE-%s\n", ok ? "OK" : "FAIL"); fflush(stdout);

        printf("M87-DONE\n"); fflush(stdout);
    }
    return 0;
}
