/*
 * xmlcli.m — M8: event-driven XML parsing via NSXMLParser (a distinct Foundation
 * data format from JSON, the SAX delegate path, on the proven Foundation runtime).
 *
 * Parses an XML document with a delegate that (a) counts <note> elements, (b)
 * captures an element ATTRIBUTE, and (c) accumulates the TEXT content of a
 * specific element — then verifies the parsed structure. This exercises the full
 * SAX callback chain (didStartElement / foundCharacters / didEndElement), not just
 * a one-shot call.
 *
 * Real Objective-C (compiler objc_msgSend). Headless, deterministic (no network).
 *
 *   M8-PARSE-OK            parse returned YES (well-formed doc consumed)
 *   M8-ELEMENTS-3          3 <note> elements seen via didStartElement
 *   M8-ATTR-42             the <answer value="42"/> attribute was read
 *   M8-TEXT-DARWIN         the <name> element's text content -> "darwin" (uppercased)
 *   M8-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

@interface XMLCollector : NSObject <NSXMLParserDelegate>
@property(nonatomic) int noteCount;
@property(nonatomic) int attrValue;
@property(nonatomic, copy) NSString* currentElement;
@property(nonatomic, strong) NSMutableString* nameText;
@end

@implementation XMLCollector
- (instancetype)init {
    if ((self = [super init])) { _nameText = [NSMutableString string]; _attrValue = -1; }
    return self;
}
- (void)parser:(NSXMLParser*)parser didStartElement:(NSString*)elementName
  namespaceURI:(NSString*)namespaceURI qualifiedName:(NSString*)qName
    attributes:(NSDictionary*)attrs {
    self.currentElement = elementName;
    if ([elementName isEqualToString:@"note"]) {
        self.noteCount++;
    } else if ([elementName isEqualToString:@"answer"]) {
        NSString* v = attrs[@"value"];
        if (v) self.attrValue = [v intValue];
    }
}
- (void)parser:(NSXMLParser*)parser foundCharacters:(NSString*)string {
    if ([self.currentElement isEqualToString:@"name"]) {
        [self.nameText appendString:string];
    }
}
- (void)parser:(NSXMLParser*)parser didEndElement:(NSString*)elementName
  namespaceURI:(NSString*)namespaceURI qualifiedName:(NSString*)qName {
    self.currentElement = nil;
}
@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        const char* xml =
            "<?xml version=\"1.0\"?>"
            "<doc>"
            "  <name>darwin</name>"
            "  <answer value=\"42\"/>"
            "  <notes><note>a</note><note>b</note><note>c</note></notes>"
            "</doc>";
        NSData* data = [NSData dataWithBytes:xml length:strlen(xml)];

        NSXMLParser* parser = [[NSXMLParser alloc] initWithData:data];
        XMLCollector* col = [[XMLCollector alloc] init];
        [parser setDelegate:col];

        BOOL ok = [parser parse];
        printf("M8-PARSE-%s\n", ok ? "OK" : "FAIL"); fflush(stdout);
        if (!ok) { printf("M8-DONE\n"); return 0; }

        printf("M8-ELEMENTS-%d\n", col.noteCount); fflush(stdout);
        printf("M8-ATTR-%d\n", col.attrValue); fflush(stdout);

        // <name>darwin</name> has no surrounding whitespace, so uppercase directly
        // (avoids NSCharacterSet, which isn't resolvable in the by-path Foundation
        // link here).
        NSString* name = [col.nameText uppercaseString];
        printf("M8-TEXT-%s\n", [name length] ? [name UTF8String] : "EMPTY"); fflush(stdout);

        printf("M8-DONE\n"); fflush(stdout);
    }
    return 0;
}
