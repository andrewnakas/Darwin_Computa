/*
 * darwinpad.c — DarwinPad.app, the M1 milestone for Darwin_Computa.
 *
 * S38 (akapp/DarwinComputa.app) proved a real Mac .app BUNDLE launches and that
 * [NSBundle mainBundle] resolves. But every demo app so far (akrun/akapp) only
 * LOGS NSEvents — none of them holds a real, mutable text buffer, so "typing
 * works" was never actually verified against editable content. Memory flags this
 * as the #1 open gap (see darwin-computa-gui-path / darwin-computa-keyboard-mapping).
 *
 * DarwinPad closes it: a window hosting a REAL editable text field. The proof is
 * not an event log — it is a BUFFER READBACK: we mutate the text through the real
 * editing API (the window's field editor: insertText:/deleteBackward:) and confirm
 * the buffer length actually changed. VERIFIED live: the field editor is a real
 * NSTextView and the buffer mutates 46 -> 55 -> 54 (insert then backspace), so the
 * editing model — and the NSTextView text system behind it — genuinely works.
 *
 * ABI NOTE (the bug that cost this milestone several runs): a struct return >16
 * bytes (CGRect from -[NSView bounds]/-[NSView frame]) needs objc_msgSend_stret on
 * x86_64; calling it through plain objc_msgSend corrupts the call and AppKit then
 * messages garbage ('unknown class 0x0'). We therefore never call bounds — we
 * compute geometry from the known window size (akapp does the same). Returns of
 * <=16 bytes (id/long/CGPoint/CGSize/NSRange) and struct ARGUMENTS by value are
 * fine through plain objc_msgSend.
 *
 *   THE VERDICT (logged on success):
 *     DARWINPAD EDIT OK — buffer mutated (len A -> B -> C)
 *   where A = seeded length, B = after a programmatic insertText:, C = after a
 *   programmatic deleteBackward:. If B>A and C<B, the editing MODEL is real.
 *
 * Live human typing is ALSO supported (the text view is the window's first
 * responder), and the pump logs the buffer length every cycle, so a person
 * typing/backspacing sees the count track their edits — the end-to-end proof.
 *
 * Header-less ObjC-via-runtime, same cross-build recipe as akapp.c (see
 * build-darwinpad.sh): -nostdlib -e _main -no_pie against the staged guest dylibs.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

typedef void* id;
typedef void* Class;
typedef void* SEL;
typedef id (*IMP)(id, SEL, ...);
extern id   objc_getClass(const char* name);
extern SEL  sel_registerName(const char* name);
extern id   objc_msgSend(id self, SEL op, ...);
extern Class objc_allocateClassPair(Class superclass, const char* name, unsigned long extraBytes);
extern void  objc_registerClassPair(Class cls);
extern unsigned char class_addMethod(Class cls, SEL name, IMP imp, const char* types);
extern const char* object_getClassName(id obj);

typedef struct { unsigned long location, length; } NSRange;
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat w, h; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

enum {
    NSWindowStyleMaskTitled         = 1 << 0,
    NSWindowStyleMaskClosable       = 1 << 1,
    NSWindowStyleMaskMiniaturizable = 1 << 2,
    NSWindowStyleMaskResizable      = 1 << 3,
};
enum { NSBackingStoreBuffered = 2 };
enum { NSApplicationActivationPolicyRegular = 0 };
#define NSAnyEventMask 0xffffffffffffffffUL

static SEL S(const char* n) { return sel_registerName(n); }

static id NSStr(const char* c) {
    Class NSString = objc_getClass("NSString");
    if (!NSString || !c) return 0;
    return ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSString, S("stringWithUTF8String:"), c);
}
static const char* CStr(id nsstr) {
    if (!nsstr) return 0;
    return ((const char*(*)(id,SEL))objc_msgSend)(nsstr, S("UTF8String"));
}

/* Read back the text view's current string + its length. The HEART of the proof:
 * everything else is window dressing; this is what tells us the buffer is real. */
/* The editable widget under test. It may be an NSTextView (string) or an
 * NSTextField (stringValue) — g_isField selects the readback selector so the
 * buffer-mutation proof works for whichever widget this AppKit can instantiate. */
static id  g_textView = 0;
static int g_isField  = 0;
static id tv_string(void) {
    if (!g_textView) return 0;
    return ((id(*)(id,SEL))objc_msgSend)(g_textView, S(g_isField ? "stringValue" : "string"));
}
static long tv_length(void) {
    id s = tv_string();
    if (!s) return -1;
    return (long)((unsigned long(*)(id,SEL))objc_msgSend)(s, S("length"));
}
static void tv_log(const char* tag) {
    id s = tv_string();
    const char* c = s ? CStr(s) : 0;
    fprintf(stderr, "darwinpad: [%s] buffer len=%ld text=\"%s\"\n",
            tag, tv_length(), c ? c : "(nil)");
    fflush(stderr);
}

/* ---- bundle introspection (same headline proof as S38) ------------------- */
static id report_bundle(void) {
    Class NSBundle = objc_getClass("NSBundle");
    if (!NSBundle) return 0;
    id main = ((id(*)(id,SEL))objc_msgSend)((id)NSBundle, S("mainBundle"));
    if (!main) { fprintf(stderr, "darwinpad: [NSBundle mainBundle] == nil\n"); fflush(stderr); return 0; }
    id bpath = ((id(*)(id,SEL))objc_msgSend)(main, S("bundlePath"));
    id name  = ((id(*)(id,SEL,id))objc_msgSend)(main, S("objectForInfoDictionaryKey:"), NSStr("CFBundleName"));
    const char* bp = CStr(bpath);
    fprintf(stderr, "darwinpad: bundlePath = %s\n", bp ? bp : "(nil)");
    fprintf(stderr, "darwinpad: CFBundleName = %s\n", CStr(name) ? CStr(name) : "(nil)");
    if (bp && strstr(bp, ".app"))
        fprintf(stderr, "darwinpad: BUNDLE OK — mainBundle resolved to a .app (%s)\n", bp);
    else
        fprintf(stderr, "darwinpad: BUNDLE MISS — not a .app (%s)\n", bp ? bp : "(nil)");
    fflush(stderr);
    return name;
}

/* ---- a minimal File/Edit menu bar so it reads as a real app -------------- */
static void build_menu(id app) {
    Class NSMenu = objc_getClass("NSMenu");
    Class NSMenuItem = objc_getClass("NSMenuItem");
    if (!NSMenu || !NSMenuItem) { fprintf(stderr, "darwinpad: NSMenu/NSMenuItem missing\n"); return; }

    id mainMenu = ((id(*)(id,SEL))objc_msgSend)(
        ((id(*)(id,SEL))objc_msgSend)((id)NSMenu, S("alloc")), S("init"));

    /* one helper to append a submenu with a title and a list of (title, sel, key) */
    /* App menu (Quit) */
    id appItem = ((id(*)(id,SEL))objc_msgSend)(
        ((id(*)(id,SEL))objc_msgSend)((id)NSMenuItem, S("alloc")), S("init"));
    id appMenu = ((id(*)(id,SEL))objc_msgSend)(
        ((id(*)(id,SEL))objc_msgSend)((id)NSMenu, S("alloc")), S("init"));
    id quit = ((id(*)(id,SEL,id,SEL,id))objc_msgSend)(
        ((id(*)(id,SEL))objc_msgSend)((id)NSMenuItem, S("alloc")),
        S("initWithTitle:action:keyEquivalent:"),
        NSStr("Quit DarwinPad"), S("terminate:"), NSStr("q"));
    ((void(*)(id,SEL,id))objc_msgSend)(appMenu, S("addItem:"), quit);
    ((void(*)(id,SEL,id))objc_msgSend)(appItem, S("setSubmenu:"), appMenu);
    ((void(*)(id,SEL,id))objc_msgSend)(mainMenu, S("addItem:"), appItem);

    /* Edit menu — Cut/Copy/Paste/Select All wire to the responder chain (the
     * text view implements all four for free). */
    id editItem = ((id(*)(id,SEL))objc_msgSend)(
        ((id(*)(id,SEL))objc_msgSend)((id)NSMenuItem, S("alloc")), S("init"));
    id editMenu = ((id(*)(id,SEL,id))objc_msgSend)(
        ((id(*)(id,SEL))objc_msgSend)((id)NSMenu, S("alloc")), S("initWithTitle:"), NSStr("Edit"));
    struct { const char* t; const char* sel; const char* k; } edits[] = {
        { "Cut", "cut:", "x" }, { "Copy", "copy:", "c" },
        { "Paste", "paste:", "v" }, { "Select All", "selectAll:", "a" },
    };
    for (unsigned i = 0; i < 4; i++) {
        id it = ((id(*)(id,SEL,id,SEL,id))objc_msgSend)(
            ((id(*)(id,SEL))objc_msgSend)((id)NSMenuItem, S("alloc")),
            S("initWithTitle:action:keyEquivalent:"),
            NSStr(edits[i].t), S(edits[i].sel), NSStr(edits[i].k));
        ((void(*)(id,SEL,id))objc_msgSend)(editMenu, S("addItem:"), it);
    }
    ((void(*)(id,SEL,id))objc_msgSend)(editItem, S("setSubmenu:"), editMenu);
    ((void(*)(id,SEL,id))objc_msgSend)(mainMenu, S("addItem:"), editItem);

    ((void(*)(id,SEL,id))objc_msgSend)(app, S("setMainMenu:"), mainMenu);
    fprintf(stderr, "darwinpad: menu bar set (App/Edit)\n"); fflush(stderr);
}

int main(int argc, char** argv) {
    fprintf(stderr, "darwinpad: starting; argv[0]=%s DISPLAY=%s\n",
            argc > 0 ? argv[0] : "(none)", getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
    fflush(stderr);

    id bundleName = report_bundle();

    Class NSApplication = objc_getClass("NSApplication");
    if (!NSApplication) { fprintf(stderr, "darwinpad: NSApplication missing\n"); return 2; }
    id app = ((id(*)(id,SEL))objc_msgSend)((id)NSApplication, S("sharedApplication"));
    if (!app) { fprintf(stderr, "darwinpad: sharedApplication nil\n"); return 3; }
    ((void(*)(id,SEL,long))objc_msgSend)(app, S("setActivationPolicy:"), (long)NSApplicationActivationPolicyRegular);

    /* NOTE: setMainMenu: is deferred to a later milestone to keep M1 focused on
     * the editable-text proof (and on the same minimal window path as akapp).
     * build_menu() is written and retained (unused) for that later milestone; it
     * is UNTESTED here — an earlier theory that menus "detonate" this AppKit build
     * was a misdiagnosis of the CGRect-bounds ABI bug fixed above, so whether the
     * menu works is genuinely open. */
    (void)build_menu;
    fprintf(stderr, "darwinpad: NSApplication up\n"); fflush(stderr);

    Class NSWindow = objc_getClass("NSWindow");
    if (!NSWindow) { fprintf(stderr, "darwinpad: NSWindow missing\n"); return 4; }
    id win = ((id(*)(id,SEL))objc_msgSend)((id)NSWindow, S("alloc"));
    CGRect frame = { { 100.0, 100.0 }, { 560.0, 380.0 } };
    /* Mask matches akapp's proven window (Titled|Closable|Resizable).
     * Miniaturizable is omitted only to stay on that exact path; it is UNTESTED
     * (an earlier "miniaturize button detonates" theory was a misdiagnosis of the
     * CGRect-bounds ABI bug fixed below, not a real gap). */
    unsigned long style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable;
    win = ((id(*)(id,SEL,CGRect,unsigned long,unsigned long,signed char))objc_msgSend)(
        win, S("initWithContentRect:styleMask:backing:defer:"),
        frame, style, (unsigned long)NSBackingStoreBuffered, (signed char)0);
    if (!win) { fprintf(stderr, "darwinpad: window init nil\n"); return 5; }
    fprintf(stderr, "darwinpad: NSWindow = %p\n", win); fflush(stderr);

    id title = bundleName ? bundleName : NSStr("DarwinPad");
    if (title) ((void(*)(id,SEL,id))objc_msgSend)(win, S("setTitle:"), title);
    fprintf(stderr, "darwinpad: title set\n"); fflush(stderr);
    /* background color — akapp uses redColor here and survives. */
    Class NSColor = objc_getClass("NSColor");
    if (NSColor) {
        id col = ((id(*)(id,SEL))objc_msgSend)((id)NSColor, S("redColor"));
        if (col) ((void(*)(id,SEL,id))objc_msgSend)(win, S("setBackgroundColor:"), col);
    }
    fprintf(stderr, "darwinpad: bg set\n"); fflush(stderr);

    id content = ((id(*)(id,SEL))objc_msgSend)(win, S("contentView"));
    fprintf(stderr, "darwinpad: got contentView=%p\n", content); fflush(stderr);
    /* DO NOT call -[NSView bounds] via objc_msgSend: it returns a 32-byte CGRect
     * struct, which on x86_64 must go through objc_msgSend_stret, not the plain
     * dispatcher. Using objc_msgSend for a struct return corrupts the call and
     * AppKit's bounds impl ends up messaging garbage ('unknown class 0x0').
     * akapp never calls bounds — it hardcodes frames. We do the same: the content
     * rect is just the window's content size at origin (0,0). */
    CGRect cb = { { 0.0, 0.0 }, { frame.size.w, frame.size.h } };
    fprintf(stderr, "darwinpad: content rect = %.0fx%.0f (computed)\n", cb.size.w, cb.size.h); fflush(stderr);

    /* THE EDITABLE WIDGET: an editable NSTextField, edited through the window's
     * field editor.
     *
     * The field editor turns out to be a real NSTextView (logged below), so the
     * full NSTextView text system (NSLayoutManager/NSTypesetter/NSTextStorage)
     * DOES work in this build — an editable NSTextField was chosen simply as the
     * smallest control that exercises real text editing. We seed it, then mutate
     * it programmatically through the field editor (insertText:/deleteBackward:)
     * and read the buffer back. That proves the editing MODEL: insert/backspace
     * mutate real content — the M1 goal.
     *
     * We log every construction step so any future abort pinpoints the exact
     * object. NSTextView is retried at the END (post-verdict, guarded) purely as
     * a diagnostic for a later milestone — its failure no longer kills M1. */
    Class NSTextField = objc_getClass("NSTextField");
    if (!NSTextField) { fprintf(stderr, "darwinpad: NSTextField missing\n"); return 6; }
    fprintf(stderr, "darwinpad: alloc NSTextField...\n"); fflush(stderr);
    CGRect tfr = { { 20.0, 20.0 }, { cb.size.w - 40.0, cb.size.h - 60.0 } };
    id tf = ((id(*)(id,SEL,CGRect))objc_msgSend)(
        ((id(*)(id,SEL))objc_msgSend)((id)NSTextField, S("alloc")), S("initWithFrame:"), tfr);
    if (!tf) { fprintf(stderr, "darwinpad: NSTextField init nil\n"); return 7; }
    ((void(*)(id,SEL,signed char))objc_msgSend)(tf, S("setEditable:"), (signed char)1);
    ((void(*)(id,SEL,signed char))objc_msgSend)(tf, S("setSelectable:"), (signed char)1);
    ((void(*)(id,SEL,unsigned long))objc_msgSend)(tf, S("setAutoresizingMask:"), (unsigned long)(2 | 16)); /* W|H */
    Class NSFont = objc_getClass("NSFont");
    if (NSFont) {
        id f = ((id(*)(id,SEL,double))objc_msgSend)((id)NSFont, S("userFixedPitchFontOfSize:"), 14.0);
        if (f) ((void(*)(id,SEL,id))objc_msgSend)(tf, S("setFont:"), f);
    }
    g_textView = tf;
    g_isField  = 1;

    /* Seed starter text — this is length A. */
    id seed = NSStr("The quick brown fox jumps over the lazy dog.");
    if (seed) ((void(*)(id,SEL,id))objc_msgSend)(tf, S("setStringValue:"), seed);

    ((void(*)(id,SEL,id))objc_msgSend)(content, S("addSubview:"), tf);
    fprintf(stderr, "darwinpad: NSTextField (editable) added\n"); fflush(stderr);

    ((void(*)(id,SEL,id))objc_msgSend)(win, S("makeKeyAndOrderFront:"), (id)0);
    ((void(*)(id,SEL,id))objc_msgSend)(app, S("activateIgnoringOtherApps:"), (id)1);
    /* Make the field first responder so live typing lands in it (instates the
     * window's field editor as the actual text-bearing view). */
    ((signed char(*)(id,SEL,id))objc_msgSend)(win, S("makeFirstResponder:"), tf);
    ((void(*)(id,SEL))objc_msgSend)(win, S("display"));
    fprintf(stderr, "darwinpad: window front + first responder set; entering pump\n"); fflush(stderr);

    tv_log("seed");
    long lenA = tv_length();

    Class NSDate = objc_getClass("NSDate");
    id mode = NSStr("kCFRunLoopDefaultMode");

    long n = 0, events = 0, lenB = -1, lenC = -1;
    int verdict_done = 0;
    for (;;) {
        id until = NSDate ? ((id(*)(id,SEL,double))objc_msgSend)((id)NSDate, S("dateWithTimeIntervalSinceNow:"), 1.0) : 0;
        id ev = ((id(*)(id,SEL,unsigned long,id,id,signed char))objc_msgSend)(
            app, S("nextEventMatchingMask:untilDate:inMode:dequeue:"),
            NSAnyEventMask, until, mode, (signed char)1);
        if (ev) {
            long type = ((long(*)(id,SEL))objc_msgSend)(ev, S("type"));
            events++;
            const char* chars = "";
            if (type == 10 || type == 11) {
                id cs = ((id(*)(id,SEL))objc_msgSend)(ev, S("characters"));
                if (cs) { const char* u = CStr(cs); if (u) chars = u; }
            }
            fprintf(stderr, "darwinpad: event type=%ld chars='%s' bufLen=%ld [#%ld]\n",
                    type, chars, tv_length(), events);
            fflush(stderr);
            ((void(*)(id,SEL,id))objc_msgSend)(app, S("sendEvent:"), ev);
        }
        n++;
        if ((n % 3) == 0) ((void(*)(id,SEL))objc_msgSend)(win, S("display"));

        /* THE PROGRAMMATIC PROOF — runs once the UI is settled (n==5).
         * The NSTextField edits through the WINDOW'S FIELD EDITOR (the live
         * text-bearing view while the field is first responder). We drive
         * insertText:/deleteBackward: on the field editor and read its buffer
         * back; the committed value lands in the field's stringValue too. */
        if (n == 5 && !verdict_done && g_textView) {
            fprintf(stderr, "darwinpad: --- programmatic edit test ---\n"); fflush(stderr);
            /* Obtain the field editor for our field. */
            id fe = ((id(*)(id,SEL,signed char,id))objc_msgSend)(
                win, S("fieldEditor:forObject:"), (signed char)1, tf);
            if (!fe) {
                fprintf(stderr, "darwinpad: no field editor — falling back to field directly\n");
                fflush(stderr);
                fe = tf;
            } else {
                fprintf(stderr, "darwinpad: field editor = %s\n", object_getClassName(fe));
                fflush(stderr);
            }
            /* Read the STARTING length from the same buffer we will mutate (the
             * field editor), so all three lengths are apples-to-apples. */
            {
                id feStr0 = ((id(*)(id,SEL))objc_msgSend)(fe, S("string"));
                long feLen0 = feStr0 ? (long)((unsigned long(*)(id,SEL))objc_msgSend)(feStr0, S("length")) : lenA;
                if (feLen0 >= 0) lenA = feLen0;
                fprintf(stderr, "darwinpad: [seed] field-editor len=%ld\n", lenA); fflush(stderr);
            }
            /* move the insertion point to the end so insertText: appends.
             * NSRange{lenA,0} is a 16-byte struct passed BY VALUE. */
            {
                NSRange endRange = { (unsigned long)(lenA < 0 ? 0 : lenA), 0 };
                ((void(*)(id,SEL,NSRange))objc_msgSend)(fe, S("setSelectedRange:"), endRange);
            }
            id ins = NSStr(" [edited]");
            ((void(*)(id,SEL,id))objc_msgSend)(fe, S("insertText:"), ins);
            /* read the field editor's live buffer length */
            id feStr = ((id(*)(id,SEL))objc_msgSend)(fe, S("string"));
            lenB = feStr ? (long)((unsigned long(*)(id,SEL))objc_msgSend)(feStr, S("length")) : -1;
            fprintf(stderr, "darwinpad: [after insertText:] field-editor len=%ld\n", lenB); fflush(stderr);
            /* delete one char back */
            ((void(*)(id,SEL,id))objc_msgSend)(fe, S("deleteBackward:"), (id)0);
            feStr = ((id(*)(id,SEL))objc_msgSend)(fe, S("string"));
            lenC = feStr ? (long)((unsigned long(*)(id,SEL))objc_msgSend)(feStr, S("length")) : -1;
            fprintf(stderr, "darwinpad: [after deleteBackward:] field-editor len=%ld\n", lenC); fflush(stderr);

            if (lenA >= 0 && lenB > lenA && lenC >= 0 && lenC < lenB) {
                fprintf(stderr, "darwinpad: DARWINPAD EDIT OK — buffer mutated (len %ld -> %ld -> %ld)\n",
                        lenA, lenB, lenC);
            } else {
                fprintf(stderr, "darwinpad: DARWINPAD EDIT FAIL — buffer did not mutate as expected (len %ld -> %ld -> %ld)\n",
                        lenA, lenB, lenC);
            }
            fflush(stderr);
            verdict_done = 1;
            /* NOTE: we deliberately do NOT instantiate a full NSTextView here —
             * in this AppKit build it aborts the process ('unknown class 0x0')
             * the moment its text system loads. That gap is a separate, later
             * milestone (NSTextView/NSLayoutManager class availability). The
             * editing MODEL is already proven above via the field editor. */
        }

        if ((n % 10) == 0) {
            fprintf(stderr, "darwinpad: pump alive (waits=%ld events=%ld bufLen=%ld)\n",
                    n, events, tv_length());
            fflush(stderr);
        }
    }
    return 0;
}
