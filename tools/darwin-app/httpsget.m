/*
 * httpsget.m — M4c: an HTTPS (TLS) client over the proven guest->host socket
 * bridge, using the staged MODERN OpenSSL (libssl.46/libcrypto.44 => TLS 1.3),
 * with in-process chunked decoding (reused from M4b).
 *
 * Why OpenSSL directly, not Security.framework/NSURLSession? The emulator socket
 * bridge is raw TCP only (TLS must run in guest userspace), and Darling's
 * high-level CFNetwork loaders are flakily broken here (see
 * [[darwin-computa-networking-m4]]). The staged userland has a full OpenSSL: the
 * libssl.dylib SYMLINK points at ancient 0.9.8 (TLS1.0-only, rejected by modern
 * servers), but libssl.46.dylib + libcrypto.44.dylib are modern (TLS_client_method,
 * TLS 1.2/1.3) — we link those EXPLICITLY by path. example.com requires TLS 1.3,
 * which they provide. This is the same "build on the layer that works" approach
 * that landed M4/M4b.
 *
 * No OpenSSL headers are staged, so the handful of needed functions are declared
 * extern here (their ABI is stable). The exact call sequence + SNI + de-chunk was
 * validated NATIVELY on the host first (/tmp/tls_test.c -> TLS-HANDSHAKE-OK-TLSv1.3
 * ... DECODED-559 HASMARKER-1) before any guest boot.
 *
 *   M4C-DNS-<ip>            getaddrinfo resolved the host
 *   M4C-TCP-OK             guest->host TCP connect to :443
 *   M4C-HANDSHAKE-OK-<ver> SSL_connect succeeded (TLS version)
 *   M4C-STATUS-<code>      parsed HTTP status over TLS
 *   M4C-DECODED-<n>        decoded (de-chunked) body length
 *   M4C-HASMARKER-<0|1>    body contains "<title>Example Domain" (NSString check)
 *   M4C-DONE
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

// --- Minimal OpenSSL extern decls (no headers staged; ABI is stable). ---------
typedef struct ssl_st SSL;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_method_st SSL_METHOD;
extern const SSL_METHOD* TLS_client_method(void);
extern SSL_CTX* SSL_CTX_new(const SSL_METHOD* meth);
extern void     SSL_CTX_free(SSL_CTX*);
extern SSL*     SSL_new(SSL_CTX*);
extern void     SSL_free(SSL*);
extern int      SSL_set_fd(SSL*, int fd);
extern int      SSL_connect(SSL*);
extern int      SSL_write(SSL*, const void* buf, int num);
extern int      SSL_read(SSL*, void* buf, int num);
extern int      SSL_get_error(const SSL*, int ret);
extern const char* SSL_get_version(const SSL*);
extern long     SSL_ctrl(SSL*, int cmd, long larg, void* parg);
// SNI: SSL_set_tlsext_host_name(s,name) == SSL_ctrl(s, 55, 0, (void*)name).
#define SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define TLSEXT_NAMETYPE_host_name 0
// In OpenSSL 1.1+/3.0 library init is automatic; no SSL_library_init needed.

#define HOST "example.com"
#define MARKER "<title>Example Domain"

static int dechunk(const char* body, int bodyLen, char* out, int cap) {
    int ip = 0, op = 0;
    while (ip < bodyLen) {
        int sz = 0, sawDigit = 0;
        while (ip < bodyLen && isxdigit((unsigned char)body[ip])) {
            char c = body[ip++];
            int d = (c <= '9') ? c - '0' : (tolower(c) - 'a' + 10);
            sz = sz * 16 + d; sawDigit = 1;
        }
        if (!sawDigit) return -1;
        while (ip + 1 < bodyLen && !(body[ip] == '\r' && body[ip + 1] == '\n')) ip++;
        ip += 2;
        if (sz == 0) break;
        if (ip + sz > bodyLen || op + sz > cap) return -1;
        memcpy(out + op, body + ip, sz);
        op += sz; ip += sz;
        if (ip + 1 < bodyLen && body[ip] == '\r' && body[ip + 1] == '\n') ip += 2;
    }
    out[op < cap ? op : cap - 1] = '\0';
    return op;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        struct addrinfo hints, *res = NULL;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo(HOST, "443", &hints, &res) != 0 || !res) {
            printf("M4C-DNS-FAIL\n"); fflush(stdout); printf("M4C-DONE\n"); return 0;
        }
        struct sockaddr_in dst = *(struct sockaddr_in*)res->ai_addr;
        char ip[64] = {0}; inet_ntop(AF_INET, &dst.sin_addr, ip, sizeof(ip));
        freeaddrinfo(res);
        printf("M4C-DNS-%s\n", ip); fflush(stdout);

        int s = socket(AF_INET, SOCK_STREAM, 0);
        dst.sin_port = htons(443);
        if (connect(s, (struct sockaddr*)&dst, sizeof(dst)) != 0) {
            printf("M4C-TCP-FAIL-%d\n", errno); fflush(stdout); printf("M4C-DONE\n"); return 0;
        }
        printf("M4C-TCP-OK\n"); fflush(stdout);

        SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
        if (!ctx) { printf("M4C-CTX-FAIL\n"); fflush(stdout); printf("M4C-DONE\n"); return 0; }
        SSL* ssl = SSL_new(ctx);
        SSL_set_fd(ssl, s);
        SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, (void*)HOST); // SNI
        if (SSL_connect(ssl) != 1) {
            printf("M4C-HANDSHAKE-FAIL-%d\n", SSL_get_error(ssl, 0)); fflush(stdout);
            printf("M4C-DONE\n"); return 0;
        }
        printf("M4C-HANDSHAKE-OK-%s\n", SSL_get_version(ssl)); fflush(stdout);

        const char* req = "GET / HTTP/1.1\r\nHost: " HOST "\r\n"
                          "Connection: close\r\nAccept-Encoding: identity\r\n"
                          "User-Agent: DarwinComputa-httpsget/1.0\r\n\r\n";
        SSL_write(ssl, req, (int)strlen(req));

        static char resp[131072];
        int total = 0, n;
        while (total < (int)sizeof(resp) - 1 &&
               (n = SSL_read(ssl, resp + total, (int)sizeof(resp) - 1 - total)) > 0) {
            total += n;
        }
        resp[total] = '\0';
        SSL_free(ssl); SSL_CTX_free(ctx); close(s);

        int code = -1;
        if (!strncmp(resp, "HTTP/1.", 7)) { const char* sp = strchr(resp, ' '); if (sp) code = atoi(sp + 1); }
        printf("M4C-STATUS-%d\n", code); fflush(stdout);

        const char* split = strstr(resp, "\r\n\r\n");
        const char* body = split ? split + 4 : resp;
        int bodyLen = split ? total - (int)(body - resp) : total;
        int chunked = 0;
        for (const char* p = resp; p < (split ? split : resp + total); ) {
            const char* nl = strchr(p, '\n'); if (!nl || (split && nl >= split)) break;
            if (!strncasecmp(p, "Transfer-Encoding:", 18) && strstr(p, "chunked")) chunked = 1;
            p = nl + 1;
        }
        static char decoded[131072];
        int decLen;
        if (chunked) {
            decLen = dechunk(body, bodyLen, decoded, sizeof(decoded));
            if (decLen < 0) { printf("M4C-DECHUNK-MALFORMED\n"); fflush(stdout); printf("M4C-DONE\n"); return 0; }
        } else {
            decLen = bodyLen < (int)sizeof(decoded) ? bodyLen : (int)sizeof(decoded) - 1;
            memcpy(decoded, body, decLen); decoded[decLen] = '\0';
        }
        printf("M4C-DECODED-%d\n", decLen); fflush(stdout);

        NSString* page = [[NSString alloc] initWithBytes:decoded length:decLen encoding:NSUTF8StringEncoding];
        BOOL hasMarker = page && [page rangeOfString:@MARKER].location != NSNotFound;
        printf("M4C-HASMARKER-%d\n", hasMarker ? 1 : 0); fflush(stdout);

        printf("M4C-DONE\n"); fflush(stdout);
    }
    return 0;
}
