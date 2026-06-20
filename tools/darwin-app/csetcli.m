/*
 * csetcli.m — M43: NSCharacterSet predefined character classes + membership /
 * inversion. Deepens the NSCharacterSet coverage (M22 used membership; M29 used it
 * for splitting) by exercising the PREDEFINED class sets (decimalDigit / letter /
 * whitespace / alphanumeric), a custom set, and inverted-set semantics. Pure
 * Foundation (the proven M3 runtime); no networking.
 *
 * Uses the pre-10.9 class methods (decimalDigitCharacterSet etc.) — the guest ships
 * these (unlike the absent 10.9 URL* sets, per the M22 finding). All selectors were
 * VERIFIED PRESENT before authoring (the M22 lesson). NSCharacterSet is CF-resident,
 * so build-csetcli.sh links CoreFoundation BY PATH (the M17 finding).
 *
 *   - decimalDigit: '7' is a member, 'x' is not,
 *   - letter: 'x' is a member, '7' is not,
 *   - whitespace: ' ' is a member, 'x' is not,
 *   - alphanumeric: both '7' and 'x' are members, '!' is not,
 *   - custom set "xyz": 'y' member, 'a' not,
 *   - inverted decimalDigit: 'x' member (non-digit), '7' not.
 *
 *   M43-DIGIT-<n>          decimalDigit: ('7' && !'x')  -> 1 if correct
 *   M43-LETTER-<n>         letter: ('x' && !'7')  -> 1
 *   M43-WS-<n>             whitespace: (' ' && !'x')  -> 1
 *   M43-ALNUM-<n>          alphanumeric: ('7' && 'x' && !'!')  -> 1
 *   M43-CUSTOM-<n>         custom "xyz": ('y' && !'a')  -> 1
 *   M43-INVERTED-<n>       inverted decimalDigit: ('x' && !'7')  -> 1
 *   M43-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSCharacterSet* digit = [NSCharacterSet decimalDigitCharacterSet];
        int d = ([digit characterIsMember:'7'] && ![digit characterIsMember:'x']) ? 1 : 0;
        printf("M43-DIGIT-%d\n", d); fflush(stdout);

        NSCharacterSet* letter = [NSCharacterSet letterCharacterSet];
        int l = ([letter characterIsMember:'x'] && ![letter characterIsMember:'7']) ? 1 : 0;
        printf("M43-LETTER-%d\n", l); fflush(stdout);

        NSCharacterSet* ws = [NSCharacterSet whitespaceCharacterSet];
        int w = ([ws characterIsMember:' '] && ![ws characterIsMember:'x']) ? 1 : 0;
        printf("M43-WS-%d\n", w); fflush(stdout);

        NSCharacterSet* alnum = [NSCharacterSet alphanumericCharacterSet];
        int a = ([alnum characterIsMember:'7'] && [alnum characterIsMember:'x']
                 && ![alnum characterIsMember:'!']) ? 1 : 0;
        printf("M43-ALNUM-%d\n", a); fflush(stdout);

        NSCharacterSet* custom = [NSCharacterSet characterSetWithCharactersInString:@"xyz"];
        int c = ([custom characterIsMember:'y'] && ![custom characterIsMember:'a']) ? 1 : 0;
        printf("M43-CUSTOM-%d\n", c); fflush(stdout);

        NSCharacterSet* notDigit = [digit invertedSet];
        int inv = ([notDigit characterIsMember:'x'] && ![notDigit characterIsMember:'7']) ? 1 : 0;
        printf("M43-INVERTED-%d\n", inv); fflush(stdout);

        printf("M43-DONE\n"); fflush(stdout);
    }
    return 0;
}
