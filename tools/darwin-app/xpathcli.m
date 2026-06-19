/*
 * xpathcli.m — M18: direct libxml2 with XPath queries + DOM tree navigation.
 *
 * This is a DEEPER, NEW capability over M8 (which used NSXMLParser's event/SAX
 * wrapper). Here we drive libxml2's real engine directly: build an in-memory DOM,
 * navigate the element tree, read attributes/text, and — the genuinely new part —
 * run XPath EXPRESSIONS that select node-sets, count them, and pull values.
 * XPath/DOM is something the SAX-only NSXMLParser path cannot do.
 *
 * libxml2 is a clean, self-contained staged C lib (deps: libSystem/libz/libiconv/
 * libc++ — no Cocotron glue), so we link it BY PATH like libsqlite3/libz and
 * declare its C API extern (no libxml/*.h staged; the ABI is stable). Foundation is
 * linked only for an NSString cross-check of an extracted value.
 *
 *   M18-XMLVER-<v>         xmlParserVersion (the lib loaded + runs)
 *   M18-PARSE-OK           xmlReadMemory built a DOM from the in-memory doc
 *   M18-ROOT-<name>        root element name == "catalog"
 *   M18-FIRSTCHILD-<name>  first element child == "book"
 *   M18-ATTR-<v>           xmlGetProp: the first book's id attribute == "b1"
 *   M18-TEXT-<v>           text content of the first book's <title>
 *   M18-XPATH-COUNT-<n>    XPath //book selected n nodes (== 3)
 *   M18-XPATH-PRICE-<v>    XPath string of //book[2]/price/text() == "31.50"
 *   M18-NSSTRING-OK        the XPath-extracted price equals "31.50" via NSString
 *   M18-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

/* ---- libxml2 C API (extern; no libxml headers staged) --------------------- */
typedef unsigned char xmlChar;
typedef struct _xmlDoc  xmlDoc;     typedef xmlDoc*  xmlDocPtr;
typedef struct _xmlNode xmlNode;    typedef xmlNode* xmlNodePtr;
typedef struct _xmlXPathContext xmlXPathContext; typedef xmlXPathContext* xmlXPathContextPtr;

/* xmlNode: we only touch ->name and ->children, both near the struct head. The
 * real layout starts: void* _private; xmlElementType type; const xmlChar* name;
 * struct _xmlNode* children; ... We mirror the prefix to read name/children. */
struct _xmlNode {
    void* _private;
    int   type;
    const xmlChar* name;
    xmlNodePtr children;
    xmlNodePtr last;
    xmlNodePtr parent;
    xmlNodePtr next;
    xmlNodePtr prev;
    xmlDocPtr  doc;
};

/* xmlXPathObject prefix: enum type; then a nodeset pointer. We need ->type and
 * ->nodesetval (xmlNodeSet*: int nodeNr; int nodeMax; xmlNodePtr* nodeTab) plus
 * ->stringval for string() results. */
typedef struct _xmlNodeSet { int nodeNr; int nodeMax; xmlNodePtr* nodeTab; } xmlNodeSet;
typedef struct _xmlXPathObject {
    int type;                 /* XPATH_NODESET=1, XPATH_STRING=4 */
    xmlNodeSet* nodesetval;
    int boolval;
    double floatval;
    xmlChar* stringval;
} xmlXPathObject;
typedef xmlXPathObject* xmlXPathObjectPtr;

extern const char* xmlParserVersion;  /* a const char* global, not a function */
extern xmlDocPtr   xmlReadMemory(const char* buf, int size, const char* url, const char* enc, int opts);
extern xmlNodePtr  xmlDocGetRootElement(xmlDocPtr doc);
extern xmlNodePtr  xmlFirstElementChild(xmlNodePtr parent);
extern xmlChar*    xmlGetProp(xmlNodePtr node, const xmlChar* name);
extern xmlChar*    xmlNodeGetContent(xmlNodePtr node);
extern void        xmlFree(void*);                 /* via the xmlFree global indirection */
extern xmlXPathContextPtr xmlXPathNewContext(xmlDocPtr doc);
extern xmlXPathObjectPtr  xmlXPathEvalExpression(const xmlChar* expr, xmlXPathContextPtr ctx);
extern void        xmlXPathFreeObject(xmlXPathObjectPtr obj);
extern void        xmlXPathFreeContext(xmlXPathContextPtr ctx);
extern void        xmlFreeDoc(xmlDocPtr doc);
extern void        xmlCleanupParser(void);

static const char* kDoc =
    "<?xml version=\"1.0\"?>"
    "<catalog>"
    "  <book id=\"b1\"><title>Darwin</title><price>19.99</price></book>"
    "  <book id=\"b2\"><title>Computa</title><price>31.50</price></book>"
    "  <book id=\"b3\"><title>Substrate</title><price>42.00</price></book>"
    "</catalog>";

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        printf("M18-XMLVER-%s\n", xmlParserVersion ? xmlParserVersion : "(nil)"); fflush(stdout);

        xmlDocPtr doc = xmlReadMemory(kDoc, (int)strlen(kDoc), "noname.xml", NULL, 0);
        printf("M18-PARSE-%s\n", doc ? "OK" : "FAIL"); fflush(stdout);
        if (!doc) { printf("M18-DONE\n"); return 0; }

        xmlNodePtr root = xmlDocGetRootElement(doc);
        printf("M18-ROOT-%s\n", root && root->name ? (const char*)root->name : "(nil)"); fflush(stdout);

        xmlNodePtr book1 = root ? xmlFirstElementChild(root) : NULL;
        printf("M18-FIRSTCHILD-%s\n", book1 && book1->name ? (const char*)book1->name : "(nil)"); fflush(stdout);

        xmlChar* idv = book1 ? xmlGetProp(book1, (const xmlChar*)"id") : NULL;
        printf("M18-ATTR-%s\n", idv ? (const char*)idv : "(nil)"); fflush(stdout);

        /* text of the first book's <title> (first element child of book1). */
        xmlNodePtr title1 = book1 ? xmlFirstElementChild(book1) : NULL;
        xmlChar* titleTxt = title1 ? xmlNodeGetContent(title1) : NULL;
        printf("M18-TEXT-%s\n", titleTxt ? (const char*)titleTxt : "(nil)"); fflush(stdout);

        /* ---- the new capability: XPath ------------------------------------ */
        xmlXPathContextPtr xc = xmlXPathNewContext(doc);
        xmlXPathObjectPtr nodes = xc ? xmlXPathEvalExpression((const xmlChar*)"//book", xc) : NULL;
        int count = (nodes && nodes->nodesetval) ? nodes->nodesetval->nodeNr : -1;
        printf("M18-XPATH-COUNT-%d\n", count); fflush(stdout);

        /* string(//book[2]/price) — XPath's string() coerces the node to its text. */
        xmlXPathObjectPtr price = xc ?
            xmlXPathEvalExpression((const xmlChar*)"string(//book[2]/price)", xc) : NULL;
        const char* priceStr = (price && price->stringval) ? (const char*)price->stringval : "(nil)";
        printf("M18-XPATH-PRICE-%s\n", priceStr); fflush(stdout);

        NSString* ns = [NSString stringWithUTF8String:priceStr];
        printf("M18-NSSTRING-%s\n", [ns isEqualToString:@"31.50"] ? "OK" : "FAIL"); fflush(stdout);

        if (price) xmlXPathFreeObject(price);
        if (nodes) xmlXPathFreeObject(nodes);
        if (xc) xmlXPathFreeContext(xc);
        xmlFreeDoc(doc);
        xmlCleanupParser();
        printf("M18-DONE\n"); fflush(stdout);
    }
    return 0;
}
