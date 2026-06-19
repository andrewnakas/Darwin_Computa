/*
 * x2jcli.m — M32: CLI SYNTHESIS #2, a CROSS-TIER pipeline. Composes capabilities
 * from the C-library tier and the Foundation tier end to end in one process,
 * proving they interoperate across the boundary (a different mix than M31's
 * all-Foundation-plus-crypto flow):
 *
 *   libxml2 XPath (M18)  ->  NSJSONSerialization (M7)  ->  AES-256-CBC enc/dec (M21)
 *
 * Flow: parse an XML <catalog> with libxml2, run XPath //book to pull each book's
 * title + price into a Foundation NSArray of NSDictionary, serialize that to JSON
 * bytes via NSJSONSerialization, AES-256-CBC encrypt the JSON (fixed key+IV),
 * decrypt it back, JSON-parse the recovered bytes, and confirm the round-tripped
 * objects equal the originals.
 *
 * Links the union BY PATH: Foundation + CoreFoundation (M17) + libxml2.2 (M18) +
 * libcrypto.44 (M21). C APIs declared extern (no headers staged); the few libxml2
 * structs are mirrored by head-prefix (ABI-validated header-free on host).
 *
 *   M32-XML-OK             libxml2 parsed the catalog
 *   M32-XPATH-<n>          XPath //book node count  (== 3)
 *   M32-JSON-<n>           JSON serialized byte length (> 0)
 *   M32-ENC-LEN-<n>        AES ciphertext length (> JSON length, block-padded)
 *   M32-DEC-OK             decrypt(encrypt(json)) == json bytes
 *   M32-REPARSE-<n>        JSON re-parsed from decrypted bytes -> array count (== 3)
 *   M32-TITLE2-<s>         second book's title after the full round trip (== "Computa")
 *   M32-PRICE2-<s>         second book's price after the full round trip (== "31.50")
 *   M32-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ---- libxml2 (extern; head-prefix structs, per M18) ----------------------- */
typedef unsigned char xmlChar;
typedef struct _xmlDoc xmlDoc;   typedef xmlDoc*  xmlDocPtr;
typedef struct _xmlNode xmlNode; typedef xmlNode* xmlNodePtr;
typedef struct _xmlXPathContext xmlXPathContext; typedef xmlXPathContext* xmlXPathContextPtr;
struct _xmlNode { void* _private; int type; const xmlChar* name; xmlNodePtr children;
                  xmlNodePtr last; xmlNodePtr parent; xmlNodePtr next; xmlNodePtr prev; xmlDocPtr doc; };
typedef struct _xmlNodeSet { int nodeNr; int nodeMax; xmlNodePtr* nodeTab; } xmlNodeSet;
typedef struct _xmlXPathObject { int type; xmlNodeSet* nodesetval; int boolval;
                                 double floatval; xmlChar* stringval; } xmlXPathObject;
typedef xmlXPathObject* xmlXPathObjectPtr;
extern xmlDocPtr  xmlReadMemory(const char*, int, const char*, const char*, int);
extern xmlXPathContextPtr xmlXPathNewContext(xmlDocPtr);
extern xmlXPathObjectPtr  xmlXPathEvalExpression(const xmlChar*, xmlXPathContextPtr);
extern xmlChar*   xmlNodeGetContent(xmlNodePtr);
extern xmlNodePtr xmlFirstElementChild(xmlNodePtr);
extern xmlNodePtr xmlNextElementSibling(xmlNodePtr);
extern void xmlXPathFreeObject(xmlXPathObjectPtr);
extern void xmlXPathFreeContext(xmlXPathContextPtr);
extern void xmlFreeDoc(xmlDocPtr);
extern void xmlCleanupParser(void);

/* ---- libcrypto EVP cipher (extern, per M21) ------------------------------- */
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
typedef struct evp_cipher_st     EVP_CIPHER;
typedef struct engine_st         ENGINE;
extern EVP_CIPHER_CTX* EVP_CIPHER_CTX_new(void);
extern void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX*);
extern const EVP_CIPHER* EVP_aes_256_cbc(void);
extern int EVP_EncryptInit_ex(EVP_CIPHER_CTX*, const EVP_CIPHER*, ENGINE*, const unsigned char*, const unsigned char*);
extern int EVP_EncryptUpdate(EVP_CIPHER_CTX*, unsigned char*, int*, const unsigned char*, int);
extern int EVP_EncryptFinal_ex(EVP_CIPHER_CTX*, unsigned char*, int*);
extern int EVP_DecryptInit_ex(EVP_CIPHER_CTX*, const EVP_CIPHER*, ENGINE*, const unsigned char*, const unsigned char*);
extern int EVP_DecryptUpdate(EVP_CIPHER_CTX*, unsigned char*, int*, const unsigned char*, int);
extern int EVP_DecryptFinal_ex(EVP_CIPHER_CTX*, unsigned char*, int*);

static const char* kXML =
    "<?xml version=\"1.0\"?><catalog>"
    "<book><title>Darwin</title><price>19.99</price></book>"
    "<book><title>Computa</title><price>31.50</price></book>"
    "<book><title>Substrate</title><price>42.00</price></book>"
    "</catalog>";

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        /* ---- libxml2 parse + XPath -> Foundation array -------------------- */
        xmlDocPtr doc = xmlReadMemory(kXML, (int)strlen(kXML), "c.xml", NULL, 0);
        printf("M32-XML-%s\n", doc ? "OK" : "FAIL"); fflush(stdout);
        if (!doc) { printf("M32-DONE\n"); return 0; }

        xmlXPathContextPtr xc = xmlXPathNewContext(doc);
        xmlXPathObjectPtr books = xmlXPathEvalExpression((const xmlChar*)"//book", xc);
        int n = (books && books->nodesetval) ? books->nodesetval->nodeNr : 0;
        printf("M32-XPATH-%d\n", n); fflush(stdout);

        NSMutableArray* recs = [NSMutableArray array];
        for (int i = 0; i < n; i++) {
            xmlNodePtr book = books->nodesetval->nodeTab[i];
            xmlNodePtr title = xmlFirstElementChild(book);          /* <title> */
            xmlNodePtr price = title ? xmlNextElementSibling(title) : NULL; /* <price> */
            xmlChar* t = title ? xmlNodeGetContent(title) : NULL;
            xmlChar* p = price ? xmlNodeGetContent(price) : NULL;
            [recs addObject:@{ @"title": t ? [NSString stringWithUTF8String:(const char*)t] : @"",
                               @"price": p ? [NSString stringWithUTF8String:(const char*)p] : @"" }];
        }
        if (books) xmlXPathFreeObject(books);
        if (xc) xmlXPathFreeContext(xc);
        xmlFreeDoc(doc); xmlCleanupParser();

        /* ---- Foundation array -> JSON bytes ------------------------------- */
        NSData* json = [NSJSONSerialization dataWithJSONObject:recs options:0 error:NULL];
        printf("M32-JSON-%lu\n", (unsigned long)[json length]); fflush(stdout);

        /* ---- AES-256-CBC encrypt the JSON --------------------------------- */
        unsigned char key[32], iv[16];
        for (int i = 0; i < 32; i++) key[i] = (unsigned char)i;
        for (int i = 0; i < 16; i++) iv[i]  = (unsigned char)i;
        int jl = (int)[json length];
        unsigned char* ct = (unsigned char*)malloc(jl + 32);
        int clen = 0, tmp = 0;
        EVP_CIPHER_CTX* ec = EVP_CIPHER_CTX_new();
        EVP_EncryptInit_ex(ec, EVP_aes_256_cbc(), NULL, key, iv);
        EVP_EncryptUpdate(ec, ct, &clen, (const unsigned char*)[json bytes], jl);
        EVP_EncryptFinal_ex(ec, ct + clen, &tmp); clen += tmp;
        EVP_CIPHER_CTX_free(ec);
        printf("M32-ENC-LEN-%d\n", clen); fflush(stdout);

        /* ---- decrypt back ------------------------------------------------- */
        unsigned char* pt = (unsigned char*)malloc(clen + 32);
        int plen = 0, tmp2 = 0;
        EVP_CIPHER_CTX* dc = EVP_CIPHER_CTX_new();
        EVP_DecryptInit_ex(dc, EVP_aes_256_cbc(), NULL, key, iv);
        EVP_DecryptUpdate(dc, pt, &plen, ct, clen);
        EVP_DecryptFinal_ex(dc, pt + plen, &tmp2); plen += tmp2;
        EVP_CIPHER_CTX_free(dc);
        NSData* recovered = [NSData dataWithBytes:pt length:plen];
        printf("M32-DEC-%s\n", [recovered isEqualToData:json] ? "OK" : "FAIL"); fflush(stdout);

        /* ---- JSON re-parse the decrypted bytes ---------------------------- */
        NSArray* back = [NSJSONSerialization JSONObjectWithData:recovered options:0 error:NULL];
        printf("M32-REPARSE-%lu\n", (unsigned long)[back count]); fflush(stdout);
        NSDictionary* b2 = ([back count] >= 2) ? [back objectAtIndex:1] : nil;
        printf("M32-TITLE2-%s\n", b2 ? [[b2 objectForKey:@"title"] UTF8String] : "(nil)"); fflush(stdout);
        printf("M32-PRICE2-%s\n", b2 ? [[b2 objectForKey:@"price"] UTF8String] : "(nil)"); fflush(stdout);

        free(ct); free(pt);
        printf("M32-DONE\n"); fflush(stdout);
    }
    return 0;
}
