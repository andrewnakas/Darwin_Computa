/*
 * dynclscli.m — M86: DYNAMIC CLASS CREATION at runtime. The deepest ObjC-runtime test:
 * build an entire class from scratch at runtime — objc_allocateClassPair(super, name, 0),
 * class_addMethod(cls, sel, IMP, types) to attach a method backed by a C function pointer,
 * class_addIvar for storage, objc_registerClassPair(cls) — then instantiate it and CALL
 * the synthesized method, proving it dispatches to our IMP. This is what NSKeyedUnarchiver,
 * KVO (M83, which synthesizes a subclass), and bridging layers do internally. Continues the
 * runtime/reflection vein (M82/M83/M84/M85 all clean). Pure Foundation (M3) + libobjc C API.
 *
 * All C-runtime symbols pre-vetted PRESENT in the staged libobjc (nm, M22). CF by-path
 * (M17). -fno-objc-arc (the standard probe flag; also required — ARC forbids some runtime
 * calls). Host-validated before the guest build.
 *
 *   - create class "DarwinDyn" : NSObject with an ivar "tag" (int) and two methods:
 *       -(int)answer   -> returns 42     (added via class_addMethod + a C IMP),
 *       -(void)setTag: / -(int)tag ivar accessors,
 *   - register it, alloc/init an instance, verify [obj answer]==42 and the ivar round-trips,
 *   - verify the instance's class name is "DarwinDyn" and it isKindOfClass:NSObject.
 *
 *   M86-ALLOC-1            objc_allocateClassPair returned a non-nil class
 *   M86-ANSWER-42         [instance answer] dispatched to our C IMP and returned 42
 *   M86-IVAR-7            the added ivar round-trips (set 7 -> get 7)
 *   M86-CLSNAME-DarwinDyn object_getClass name of the instance
 *   M86-ISA-1             the instance isKindOfClass:[NSObject class]
 *   M86-DONE
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>

/* IMP for -(int)answer — a plain C function; self/_cmd are the hidden ObjC args. */
static int imp_answer(id self, SEL _cmd) {
    return 42;
}
/* IMP for -(void)setTag:(int) and -(int)tag using the "tag" ivar via KVC-free ivar access */
static void imp_setTag(id self, SEL _cmd, int v) {
    Ivar iv = class_getInstanceVariable(object_getClass(self), "tag");
    if (iv) *(int*)((char*)self + ivar_getOffset(iv)) = v;
}
static int imp_tag(id self, SEL _cmd) {
    Ivar iv = class_getInstanceVariable(object_getClass(self), "tag");
    return iv ? *(int*)((char*)self + ivar_getOffset(iv)) : -1;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- allocate a fresh class pair ------------------------------- */
        Class cls = objc_allocateClassPair([NSObject class], "DarwinDyn", 0);
        printf("M86-ALLOC-%d\n", (cls != Nil) ? 1 : 0); fflush(stdout);

        /* ---- add an ivar + methods (before registering) ---------------- */
        class_addIvar(cls, "tag", sizeof(int), sizeof(int) == 4 ? 2 : 3, "i");
        class_addMethod(cls, @selector(answer), (IMP)imp_answer, "i@:");
        class_addMethod(cls, @selector(setTag:), (IMP)imp_setTag, "v@:i");
        class_addMethod(cls, @selector(tag), (IMP)imp_tag, "i@:");
        objc_registerClassPair(cls);

        /* ---- instantiate + call the synthesized method ----------------- */
        id obj = [[cls alloc] init];
        int answer = ((int (*)(id, SEL))objc_msgSend)(obj, @selector(answer));
        printf("M86-ANSWER-%d\n", answer); fflush(stdout);

        /* ---- ivar round trip ------------------------------------------- */
        ((void (*)(id, SEL, int))objc_msgSend)(obj, @selector(setTag:), 7);
        int t = ((int (*)(id, SEL))objc_msgSend)(obj, @selector(tag));
        printf("M86-IVAR-%d\n", t); fflush(stdout);

        /* ---- identity checks ------------------------------------------- */
        printf("M86-CLSNAME-%s\n", class_getName(object_getClass(obj))); fflush(stdout);
        printf("M86-ISA-%d\n", [obj isKindOfClass:[NSObject class]] ? 1 : 0); fflush(stdout);

        printf("M86-DONE\n"); fflush(stdout);
    }
    return 0;
}
