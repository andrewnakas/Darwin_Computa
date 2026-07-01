/*
 * rtcli.m — M85: Objective-C runtime C-API — associated objects + class introspection.
 * The C-level counterpart to M82's ObjC-level introspection: exercise libobjc directly via
 * <objc/runtime.h>, the layer real low-level framework code (and Swift interop) uses.
 * Continues the productive runtime/reflection vein (M82 introspection, M83 KVO, M84
 * NSInvocation — all clean). Pure Foundation (M3 runtime) + libobjc C API; no networking.
 *
 * All C-runtime symbols VERIFIED PRESENT in the staged libobjc (nm, M22 discipline):
 * objc_setAssociatedObject/objc_getAssociatedObject, class_getName, class_getSuperclass,
 * class_copyMethodList, object_getClass. Built -fno-objc-arc (standard). CF by-path (M17).
 *
 *   - objc_setAssociatedObject(host, &key, @"attached-darwin", RETAIN) then get -> same,
 *   - class_getName([NSString class]) -> "NSString",
 *   - class_getName(class_getSuperclass([NSMutableString class])) -> "NSString",
 *   - class_copyMethodList([NSObject class], &n) -> n > 0,
 *   - class_getName(object_getClass(@"x")) -> a *String* class (constant-string class name
 *     varies host vs Cocotron, so gate STRUCTURALLY: non-empty and contains "String").
 *
 *   M85-ASSOC-<s>          associated object round trip  (== "attached-darwin")
 *   M85-CLSNAME-<s>        class_getName([NSString class])  (== "NSString")
 *   M85-SUPER-<s>          superclass name of NSMutableString  (== "NSString")
 *   M85-METHODS-1          class_copyMethodList count > 0
 *   M85-INSTCLS-1          object_getClass(@"x") is a *String* class (structural)
 *   M85-DONE
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char kAssocKey;

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- associated objects ---------------------------------------- */
        NSObject* host = [NSObject new];
        objc_setAssociatedObject(host, &kAssocKey, @"attached-darwin",
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString* got = objc_getAssociatedObject(host, &kAssocKey);
        printf("M85-ASSOC-%s\n", [got UTF8String]); fflush(stdout);

        /* ---- class name ------------------------------------------------ */
        printf("M85-CLSNAME-%s\n", class_getName([NSString class])); fflush(stdout);

        /* ---- superclass chain ------------------------------------------ */
        Class superOfMutable = class_getSuperclass([NSMutableString class]);
        printf("M85-SUPER-%s\n", class_getName(superOfMutable)); fflush(stdout);

        /* ---- method-list introspection --------------------------------- */
        unsigned int n = 0;
        Method* methods = class_copyMethodList([NSObject class], &n);
        printf("M85-METHODS-%d\n", (n > 0) ? 1 : 0); fflush(stdout);
        if (methods) free(methods);

        /* ---- object_getClass (structural: a String class) -------------- */
        const char* instCls = class_getName(object_getClass(@"x"));
        int isStringCls = (instCls && strstr(instCls, "String") != NULL) ? 1 : 0;
        printf("M85-INSTCLS-%d\n", isStringCls); fflush(stdout);

        printf("M85-DONE\n"); fflush(stdout);
    }
    return 0;
}
