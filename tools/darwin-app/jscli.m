/*
 * jscli.m — M5a: execute real JavaScript through JavaScriptCore on the substrate.
 *
 * WebKit's rendering surface needs WebCore (NOT staged here — WebKit.framework is
 * a small loader, WebCore is absent), so full page rendering is out of reach. But
 * JavaScriptCore.framework IS staged (the full 65MB engine) and exports the
 * complete JSC C API. M5a proves the JS ENGINE itself runs: create a context,
 * evaluate real JavaScript (arithmetic, a string method, a function call, and a
 * loop that computes a value), and read the results back into C — so each printed
 * line only appears if JSC actually compiled and ran the script.
 *
 * Uses the JSC C API (stable ABI) declared extern — no JSC headers are staged.
 * Foundation is linked for the runtime + an NSString cross-check of a JS string.
 *
 *   M5A-EVAL-42            JSEvaluateScript("6*7") -> JSValueToNumber == 42
 *   M5A-STR-DARWIN         a JS String method result read back ("darwin".toUpperCase())
 *   M5A-FUNC-120           a JS function (factorial(5)) executed -> 120
 *   M5A-LOOP-4950          a JS for-loop sum 0..99 -> 4950 (real bytecode exec)
 *   M5A-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

// --- JavaScriptCore C API extern decls (stable ABI; no headers staged). -------
typedef const struct OpaqueJSContext* JSContextRef;
typedef struct OpaqueJSContext*       JSGlobalContextRef;
typedef struct OpaqueJSString*        JSStringRef;
typedef const struct OpaqueJSValue*   JSValueRef;
typedef struct OpaqueJSClass*         JSClassRef;

extern JSGlobalContextRef JSGlobalContextCreate(JSClassRef globalObjectClass);
extern void               JSGlobalContextRelease(JSGlobalContextRef ctx);
extern JSStringRef        JSStringCreateWithUTF8CString(const char* string);
extern void               JSStringRelease(JSStringRef string);
extern JSValueRef         JSEvaluateScript(JSContextRef ctx, JSStringRef script,
                                           JSValueRef thisObject, JSStringRef sourceURL,
                                           int startingLineNumber, JSValueRef* exception);
extern double             JSValueToNumber(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
extern JSStringRef        JSValueToStringCopy(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
extern size_t             JSStringGetUTF8CString(JSStringRef string, char* buffer, size_t bufferSize);
extern size_t             JSStringGetMaximumUTF8CStringSize(JSStringRef string);

// Evaluate `src` in ctx, return its value as a double (or NAN on exception).
static double evalNum(JSGlobalContextRef ctx, const char* src) {
    JSStringRef s = JSStringCreateWithUTF8CString(src);
    JSValueRef exc = NULL;
    JSValueRef v = JSEvaluateScript(ctx, s, NULL, NULL, 1, &exc);
    JSStringRelease(s);
    if (exc || !v) return (double)0.0 / 0.0; // NAN
    return JSValueToNumber(ctx, v, NULL);
}

// Evaluate `src`, return its value as a freshly-malloc'd UTF-8 C string (caller
// frees), or NULL on exception.
static char* evalStr(JSGlobalContextRef ctx, const char* src) {
    JSStringRef s = JSStringCreateWithUTF8CString(src);
    JSValueRef exc = NULL;
    JSValueRef v = JSEvaluateScript(ctx, s, NULL, NULL, 1, &exc);
    JSStringRelease(s);
    if (exc || !v) return NULL;
    JSStringRef str = JSValueToStringCopy(ctx, v, NULL);
    if (!str) return NULL;
    size_t cap = JSStringGetMaximumUTF8CStringSize(str);
    char* buf = (char*)malloc(cap);
    JSStringGetUTF8CString(str, buf, cap);
    JSStringRelease(str);
    return buf;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
        if (!ctx) { printf("M5A-CONTEXT-FAIL\n"); fflush(stdout); printf("M5A-DONE\n"); return 0; }

        // 1) Arithmetic — the simplest "JS ran" proof.
        printf("M5A-EVAL-%d\n", (int)evalNum(ctx, "6 * 7")); fflush(stdout);

        // 2) A String method — exercises JSC's built-in objects.
        char* up = evalStr(ctx, "'darwin'.toUpperCase()");
        printf("M5A-STR-%s\n", up ? up : "FAIL"); fflush(stdout);
        // Cross-check the JS string through Foundation too.
        if (up) {
            NSString* ns = [NSString stringWithUTF8String:up];
            if (![ns isEqualToString:@"DARWIN"]) printf("M5A-STR-MISMATCH\n");
            free(up);
        }

        // 3) A user-defined function — exercises closures/call frames.
        printf("M5A-FUNC-%d\n",
               (int)evalNum(ctx, "function f(n){return n<=1?1:n*f(n-1)} f(5)")); fflush(stdout);

        // 4) A loop — real bytecode execution over many iterations.
        printf("M5A-LOOP-%d\n",
               (int)evalNum(ctx, "var s=0; for(var i=0;i<100;i++) s+=i; s")); fflush(stdout);

        JSGlobalContextRelease(ctx);
        printf("M5A-DONE\n"); fflush(stdout);
    }
    return 0;
}
