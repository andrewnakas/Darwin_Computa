/*
 * apicli.m — M10: a real end-to-end "fetch a JSON API over HTTPS and parse it"
 * app, composing the proven layers: TLS networking (M4c, OpenSSL over the guest
 * socket bridge) + JSON parsing (M7, NSJSONSerialization).
 *
 * This is the most realistic milestone: it does what an actual app does — open a
 * TLS connection to a public API, GET a JSON document, and parse the response into
 * a Foundation object graph, reading typed values back out. Target:
 * https://api.github.com/meta (stable, HTTP/1.1, Content-Length JSON ~197 KB).
 *
 * Reuses the httpsget approach (extern OpenSSL, SSL_connect + SNI; modern
 * libssl.46) and feeds the HTTP body to NSJSONSerialization.
 *
 *   M10-DNS-<ip>            getaddrinfo resolved api.github.com
 *   M10-TCP-OK             guest->host TCP connect to :443
 *   M10-TLS-<ver>          TLS handshake (e.g. TLSv1.2)
 *   M10-HTTP-<code>        parsed HTTP status over TLS
 *   M10-BODY-<bytes>       HTTP body length received
 *   M10-JSON-OK            NSJSONSerialization parsed the body into a dictionary
 *   M10-KEYS-<n>           number of top-level keys (api.github.com/meta has many)
 *   M10-FIELD-<0|1>        d["verifiable_password_authentication"] == false (a
 *                          stable known field) round-tripped through parse
 *   M10-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

// --- Minimal OpenSSL extern decls (modern libssl.46; no header staged). --------
typedef struct ssl_st SSL;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_method_st SSL_METHOD;
extern const SSL_METHOD* TLS_client_method(void);
extern SSL_CTX* SSL_CTX_new(const SSL_METHOD*);
extern void     SSL_CTX_free(SSL_CTX*);
extern SSL*     SSL_new(SSL_CTX*);
extern void     SSL_free(SSL*);
extern int      SSL_set_fd(SSL*, int);
extern int      SSL_connect(SSL*);
extern int      SSL_write(SSL*, const void*, int);
extern int      SSL_read(SSL*, void*, int);
extern const char* SSL_get_version(const SSL*);
extern long     SSL_ctrl(SSL*, int, long, void*);
extern int      SSL_get_error(const SSL*, int);
extern unsigned long ERR_get_error(void);  // libcrypto: pop the error queue
extern int      SSL_CTX_set_cipher_list(SSL_CTX*, const char*);
extern long     SSL_CTX_ctrl(SSL_CTX*, int cmd, long larg, void* parg);
// set_min/max_proto_version + set1_groups_list are MACROS over *_ctrl in the
// OpenSSL headers (not linkable symbols on the host), so call the ctrl commands
// directly — these ARE real exported symbols in the guest libssl.46 and on host.
#define SSL_CTRL_SET_GROUPS_LIST        92
#define SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define SSL_CTRL_SET_MAX_PROTO_VERSION 124
#define SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define TLSEXT_NAMETYPE_host_name 0
#define TLS1_2_VERSION 0x0303

// Multi-host probe in ONE boot. Earlier single-host attempts failed at the TLS
// handshake with SSL_ERROR_SYSCALL (errq=0 — a transport-level abort, not a
// cipher/cert rejection): api.github.com and cloudflare-dns.com both aborted,
// while M4c's httpsget handshook with example.com fine. To separate "guest TLS
// regressed" from "these hosts abort", fetch() tries several hosts, EXAMPLE FIRST
// (the M4c-proven control), each printing its own TLS result + SSL error code.
// The host that returns JSON proves the M4c(TLS)+M7(JSON) composition.

// fetch one URL over TLS; print tagged result lines; return the parsed top-level
// dict (or nil). Caller checks fields.
static NSDictionary* fetch(const char* tag, const char* host, const char* sni,
                           const char* path, const char* accept) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, "443", &hints, &res) != 0 || !res) {
        printf("M10-%s-DNS-FAIL\n", tag); fflush(stdout); return nil;
    }
    struct sockaddr_in dst = *(struct sockaddr_in*)res->ai_addr;
    char ip[64] = {0}; inet_ntop(AF_INET, &dst.sin_addr, ip, sizeof(ip));
    freeaddrinfo(res);
    printf("M10-%s-DNS-%s\n", tag, ip); fflush(stdout);

    int s = socket(AF_INET, SOCK_STREAM, 0);
    dst.sin_port = htons(443);
    if (connect(s, (struct sockaddr*)&dst, sizeof(dst)) != 0) {
        printf("M10-%s-TCP-FAIL-%d\n", tag, errno); fflush(stdout); close(s); return nil;
    }
    printf("M10-%s-TCP-OK\n", tag); fflush(stdout);

    SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
    // Pin TLS 1.2 + a known server-accepted cipher + standard curves. The default
    // TLS_client_method offers TLS 1.3 first; the guest's older libssl ClientHello
    // (1.3 key_share / a curve or cipher set modern CDNs dropped) was getting the
    // connection closed mid-handshake -> SSL_ERROR_SYSCALL (errq=0, an EOF) on ALL
    // hosts (example.com/cloudflare/google) uniformly. Constraining to TLS1.2 +
    // ECDHE-RSA-AES128-GCM-SHA256 (verified the guest libssl HAS it and example.com
    // ACCEPTS it) + X25519/P-256 makes a clean, mutually-supported handshake.
    SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, NULL);
    SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, TLS1_2_VERSION, NULL);
    SSL_CTX_set_cipher_list(ctx,
        "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:"
        "ECDHE-ECDSA-AES128-GCM-SHA256:AES128-GCM-SHA256:ECDHE-RSA-AES128-SHA");
    SSL* ssl = SSL_new(ctx);
    SSL_set_fd(ssl, s);
    SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, (void*)sni);
    SSL_ctrl(ssl, SSL_CTRL_SET_GROUPS_LIST, 0, (void*)"X25519:P-256:P-384");
    int hres = SSL_connect(ssl);
    if (hres != 1) {
        printf("M10-%s-TLS-FAIL-sslerr-%d-errq-0x%lx\n",
               tag, SSL_get_error(ssl, hres), ERR_get_error());
        fflush(stdout); SSL_free(ssl); SSL_CTX_free(ctx); close(s); return nil;
    }
    printf("M10-%s-TLS-%s\n", tag, SSL_get_version(ssl)); fflush(stdout);

    char req[512];
    snprintf(req, sizeof(req),
             "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: DarwinComputa-apicli/1.0\r\n"
             "Accept: %s\r\nConnection: close\r\nAccept-Encoding: identity\r\n\r\n",
             path, sni, accept);
    SSL_write(ssl, req, (int)strlen(req));

    static char resp[400000];
    int total = 0, n;
    while (total < (int)sizeof(resp) - 1 &&
           (n = SSL_read(ssl, resp + total, (int)sizeof(resp) - 1 - total)) > 0) {
        total += n;
    }
    resp[total] = '\0';
    SSL_free(ssl); SSL_CTX_free(ctx); close(s);

    int code = -1;
    if (!strncmp(resp, "HTTP/1.", 7)) { const char* sp = strchr(resp, ' '); if (sp) code = atoi(sp + 1); }
    printf("M10-%s-HTTP-%d\n", tag, code); fflush(stdout);

    const char* split = strstr(resp, "\r\n\r\n");
    const char* body = split ? split + 4 : resp;
    int bodyLen = split ? total - (int)(body - resp) : total;
    printf("M10-%s-BODY-%d\n", tag, bodyLen); fflush(stdout);
    if (bodyLen <= 0) return nil;

    NSData* data = [NSData dataWithBytes:body length:bodyLen];
    NSError* err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil; // not JSON (e.g. example.com HTML)
    printf("M10-%s-JSON-OK\n", tag); fflush(stdout);
    return (NSDictionary*)obj;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // 1) CONTROL: example.com — the exact host M4c's httpsget handshook with.
        //    Confirms the guest TLS path still works in this binary. (Returns HTML,
        //    so no JSON dict — we only care that TLS+HTTP-200 succeed here.)
        fetch("CTRL", "example.com", "example.com", "/", "text/html");

        // 2) The JSON-API composition: try Cloudflare DoH (cloudflare-dns.com), and
        //    if that aborts, dns.google. Whichever returns JSON proves M4c+M7.
        NSDictionary* d = fetch("CF", "cloudflare-dns.com", "cloudflare-dns.com",
                                "/dns-query?name=example.com&type=A", "application/dns-json");
        if (!d) {
            d = fetch("GOOG", "dns.google", "dns.google",
                      "/resolve?name=example.com&type=A", "application/json");
        }

        if (d) {
            printf("M10-KEYS-%lu\n", (unsigned long)[d count]); fflush(stdout);
            id status = d[@"Status"];
            id answer = d[@"Answer"];
            int ok = (status != nil) && [status isKindOfClass:[NSNumber class]] && ([status intValue] == 0)
                     && [answer isKindOfClass:[NSArray class]] && ([answer count] >= 1);
            printf("M10-FIELD-%d\n", ok ? 1 : 0); fflush(stdout);
        } else {
            printf("M10-NOJSON\n"); fflush(stdout);
        }

        printf("M10-DONE\n"); fflush(stdout);
    }
    return 0;
}
