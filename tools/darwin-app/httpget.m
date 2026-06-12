/*
 * httpget.m — M4b: a COMPLETE, reliable HTTP client over the proven guest->host
 * socket bridge, including chunked transfer-encoding decoding done in-process.
 *
 * Why not CFNetwork's high-level loaders? On this substrate they are flakily
 * broken (verified live, see [[darwin-computa-networking-m4]]): NSURLSession
 * throws on +[__NSCFURLSessionConfiguration defaultSessionConfiguration];
 * NSURLConnection returns NSURLErrorCannotDecodeContentData (-1015) on a chunked
 * body via its broken chunked decoder, and intermittently NSURLErrorTimedOut
 * (-1001) with no response at all (non-deterministic connection setup). The raw
 * AF_INET bridge (KNativeSocketObject), by contrast, works on EVERY run. So the
 * production-grade path is to build the HTTP layer on the reliable transport and
 * decode chunked ourselves — exactly what a robust HTTP client does.
 *
 * Uses Foundation for DNS (NSHost is unreliable here, so getaddrinfo) + string
 * work, real Objective-C objc_msgSend. Targets example.com (proven reachable,
 * Cloudflare => chunked => exercises the decoder, which is the whole point).
 *
 *   M4B-DNS-<ip>             getaddrinfo resolved the host
 *   M4B-CONNECT-OK           guest->host TCP connect
 *   M4B-STATUS-<code>        parsed HTTP status line
 *   M4B-ENCODING-<chunked|length|eof>   how the body is framed
 *   M4B-DECODED-<n>          decoded body byte count (after de-chunking)
 *   M4B-HASMARKER-<0|1>      body contains the expected "<title>Example Domain"
 *   M4B-DONE
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

#define HOST "example.com"
#define MARKER "<title>Example Domain"

// Read the entire response (server sends Connection: close => read to EOF).
static int readAll(int s, char* buf, int cap) {
    int total = 0, n;
    while (total < cap - 1 && (n = (int)read(s, buf + total, cap - 1 - total)) > 0) {
        total += n;
    }
    buf[total] = '\0';
    return total;
}

// Decode chunked transfer-encoding from `body` (length bodyLen) into out (cap).
// Returns decoded length, or -1 on malformed framing. Chunk = hex-size CRLF data
// CRLF, terminated by a 0-size chunk.
static int dechunk(const char* body, int bodyLen, char* out, int cap) {
    int ip = 0, op = 0;
    while (ip < bodyLen) {
        // Parse the hex chunk size up to CRLF.
        int sz = 0, sawDigit = 0;
        while (ip < bodyLen && isxdigit((unsigned char)body[ip])) {
            char c = body[ip++];
            int d = (c <= '9') ? c - '0' : (tolower(c) - 'a' + 10);
            sz = sz * 16 + d; sawDigit = 1;
        }
        if (!sawDigit) return -1;
        // Skip any chunk extensions to the CRLF.
        while (ip + 1 < bodyLen && !(body[ip] == '\r' && body[ip + 1] == '\n')) ip++;
        ip += 2; // past CRLF
        if (sz == 0) break; // last chunk
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
        // 1) DNS via getaddrinfo (resolv.conf -> 8.8.8.8 -> the host socket bridge).
        struct addrinfo hints, *res = NULL;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo(HOST, "80", &hints, &res) != 0 || !res) {
            printf("M4B-DNS-FAIL\n"); fflush(stdout); printf("M4B-DONE\n"); return 0;
        }
        struct sockaddr_in dst = *(struct sockaddr_in*)res->ai_addr;
        char ip[64] = {0};
        inet_ntop(AF_INET, &dst.sin_addr, ip, sizeof(ip));
        freeaddrinfo(res);
        printf("M4B-DNS-%s\n", ip); fflush(stdout);

        // 2) Connect + send an HTTP/1.1 GET with Connection: close.
        int s = socket(AF_INET, SOCK_STREAM, 0);
        dst.sin_port = htons(80);
        if (connect(s, (struct sockaddr*)&dst, sizeof(dst)) != 0) {
            printf("M4B-CONNECT-FAIL-%d\n", errno); fflush(stdout); printf("M4B-DONE\n"); return 0;
        }
        printf("M4B-CONNECT-OK\n"); fflush(stdout);
        const char* req = "GET / HTTP/1.1\r\nHost: " HOST "\r\n"
                          "Connection: close\r\nAccept-Encoding: identity\r\n"
                          "User-Agent: DarwinComputa-httpget/1.0\r\n\r\n";
        write(s, req, strlen(req));

        // 3) Read the whole response.
        static char resp[131072];
        int total = readAll(s, resp, sizeof(resp));
        close(s);

        // 4) Parse status line.
        int code = -1;
        if (!strncmp(resp, "HTTP/1.", 7)) { const char* sp = strchr(resp, ' '); if (sp) code = atoi(sp + 1); }
        printf("M4B-STATUS-%d\n", code); fflush(stdout);

        // 5) Split headers/body; detect framing (case-insensitive header scan).
        const char* split = strstr(resp, "\r\n\r\n");
        const char* body = split ? split + 4 : resp;
        int bodyLen = split ? total - (int)(body - resp) : total;
        int chunked = 0, contentLen = -1;
        for (const char* p = resp; p < (split ? split : resp + total); ) {
            const char* nl = strchr(p, '\n'); if (!nl || (split && nl >= split)) break;
            if (!strncasecmp(p, "Transfer-Encoding:", 18) && strstr(p, "chunked")) chunked = 1;
            if (!strncasecmp(p, "Content-Length:", 15)) contentLen = atoi(p + 15);
            p = nl + 1;
        }
        printf("M4B-ENCODING-%s\n", chunked ? "chunked" : (contentLen >= 0 ? "length" : "eof"));
        fflush(stdout);

        // 6) Decode the body. The whole point: handle chunked ourselves so a
        //    real decoded HTTP body is produced where CFNetwork's decoder failed.
        static char decoded[131072];
        int decLen;
        if (chunked) {
            decLen = dechunk(body, bodyLen, decoded, sizeof(decoded));
            if (decLen < 0) { printf("M4B-DECHUNK-MALFORMED\n"); fflush(stdout); printf("M4B-DONE\n"); return 0; }
        } else {
            decLen = bodyLen < (int)sizeof(decoded) ? bodyLen : (int)sizeof(decoded) - 1;
            memcpy(decoded, body, decLen); decoded[decLen] = '\0';
        }
        printf("M4B-DECODED-%d\n", decLen); fflush(stdout);

        // 7) Verify the decoded body is the real page (an NSString contains: check
        //    through Foundation, so the proof also exercises objc_msgSend on the data).
        NSString* page = [[NSString alloc] initWithBytes:decoded length:decLen encoding:NSUTF8StringEncoding];
        BOOL hasMarker = page && [page rangeOfString:@MARKER].location != NSNotFound;
        printf("M4B-HASMARKER-%d\n", hasMarker ? 1 : 0); fflush(stdout);

        printf("M4B-DONE\n"); fflush(stdout);
    }
    return 0;
}
