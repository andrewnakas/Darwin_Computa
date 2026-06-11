/*
 *  Copyright (C) 2012-2025  The BoxedWine Team
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 */

#include "boxedwine.h"

#include "shellspawnclient.h"
#include "kunixsocket.h"
#include "ksocketmsg.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

// shellspawn wire protocol (darling src/shellspawn/shellspawn.h)
enum {
    SHELLSPAWN_ADDARG = 1,
    SHELLSPAWN_SETENV,
    SHELLSPAWN_CHDIR,
    SHELLSPAWN_GO,
    SHELLSPAWN_SIGNAL,
    SHELLSPAWN_SETUIDGID,
    SHELLSPAWN_SETEXEC,
};

ShellSpawnClient& ShellSpawnClient::instance() {
    static ShellSpawnClient s;
    return s;
}

bool ShellSpawnClient::isShellspawnSockPath(const char* path) {
    if (!path) {
        return false;
    }
    // The live bound path is .../var/run/shellspawn.sock under the prefix; match
    // the suffix so the prefix (vchroot) doesn't matter.
    static const char suffix[] = "/var/run/shellspawn.sock";
    size_t pl = strlen(path);
    size_t sl = sizeof(suffix) - 1;
    return pl >= sl && strcmp(path + (pl - sl), suffix) == 0;
}

// Build one shellspawn_cmd message: packed { u16 cmd; u16 data_length; data[] }
// little-endian. data_length includes the trailing NUL for string payloads.
static std::vector<U8> buildCmd(U16 cmd, const void* data, U16 dataLen) {
    std::vector<U8> out;
    out.push_back((U8)cmd);
    out.push_back((U8)(cmd >> 8));
    out.push_back((U8)dataLen);
    out.push_back((U8)(dataLen >> 8));
    if (dataLen) {
        const U8* d = (const U8*)data;
        out.insert(out.end(), d, d + dataLen);
    }
    return out;
}

void ShellSpawnClient::onShellspawnBound(const std::shared_ptr<KUnixSocketObject>& listenSock) {
    const char* target = std::getenv("BW64_SHELLSPAWN");
    if (!target || !target[0]) {
        return; // disabled: byte-identical to a normal boot
    }
    if (this->launched.exchange(true)) {
        return; // only drive one session
    }
    std::shared_ptr<KUnixSocketObject> sock = listenSock;
    std::thread([this, sock]() { this->driveSession(sock); }).detach();
}

void ShellSpawnClient::driveSession(std::shared_ptr<KUnixSocketObject> listenSock) {
    const char* target = std::getenv("BW64_SHELLSPAWN");
    if (!target || !target[0]) {
        return;
    }
    std::string exec = target;
    // argv[0] = basename of the target by convention.
    std::string arg0 = exec;
    size_t slash = arg0.find_last_of('/');
    if (slash != std::string::npos) {
        arg0 = arg0.substr(slash + 1);
    }

    klog_fmt("ShellSpawn: connecting to shellspawn to run '%s'", exec.c_str());

    std::shared_ptr<KUnixSocketObject> client = listenSock->hostConnectStream();
    if (!client) {
        klog_fmt("ShellSpawn: FAILED to connect to shellspawn (listen/accept timed out)");
        return;
    }
    klog_fmt("ShellSpawn: connected; sending SETEXEC/ADDARG/GO");

    // stdio for the child, all built host-side. The writeEnds/readEnds are handed
    // to the guest via SCM_RIGHTS; the host worker drains the stdout/stderr read
    // ends. Keep strong refs for the whole session so the peers don't close early.
    std::shared_ptr<KUnixSocketObject> stdinRead, stdinWrite;   // child stdin (EOF)
    std::shared_ptr<KUnixSocketObject> outRead, outWrite;       // child stdout
    std::shared_ptr<KUnixSocketObject> errRead, errWrite;       // child stderr
    KUnixSocketObject::makeHostPipe(stdinRead, stdinWrite);
    KUnixSocketObject::makeHostPipe(outRead, outWrite);
    KUnixSocketObject::makeHostPipe(errRead, errWrite);
    // Child's stdin: hand it the read end. By default we never write, so it sees
    // EOF once stdin drains (sw_vers/uname/GUI apps don't read stdin). But if
    // BW64_STDIN_SCRIPT is set (M2 — interactive shell), a feeder thread writes
    // scripted input lines INTO the child's stdin via stdinWrite->writeNative
    // (whose peer is stdinRead, so the bytes land in stdinRead->recvBuffer for the
    // child's read()), paced so an interactive shell prints its prompt/output
    // between lines, then closes stdin (EOF) so the shell's read loop ends.

    // 1) SETEXEC "<exec>\0"  (must precede ADDARG)
    {
        std::vector<U8> m = buildCmd(SHELLSPAWN_SETEXEC, exec.c_str(), (U16)(exec.size() + 1));
        client->hostSendBytes(m.data(), (U32)m.size());
    }
    // 2) ADDARG "<arg0>\0"
    {
        std::vector<U8> m = buildCmd(SHELLSPAWN_ADDARG, arg0.c_str(), (U16)(arg0.size() + 1));
        client->hostSendBytes(m.data(), (U32)m.size());
    }
    // 2b) Optional SETENV "<KEY=VALUE>\0" pairs, from host BW64_SPAWN_ENV
    //     (';'-separated, e.g. "OBJC_PRINT_INITIALIZE_METHODS=YES;FOO=bar").
    //     Lets us inject diagnostics (objc class-init tracing) or any env into the
    //     spawned Darwin app without rebuilding it. Default unset = no-op.
    if (const char* spawnEnv = std::getenv("BW64_SPAWN_ENV")) {
        std::string all(spawnEnv);
        size_t start = 0;
        while (start <= all.size()) {
            size_t sep = all.find(';', start);
            std::string pair = all.substr(start, sep == std::string::npos ? std::string::npos : sep - start);
            if (!pair.empty()) {
                std::vector<U8> m = buildCmd(SHELLSPAWN_SETENV, pair.c_str(), (U16)(pair.size() + 1));
                client->hostSendBytes(m.data(), (U32)m.size());
                klog_fmt("ShellSpawn: SETENV '%s'", pair.c_str());
            }
            if (sep == std::string::npos) break;
            start = sep + 1;
        }
    }
    // 2c) CHDIR to a valid working directory (M2). The shellspawn child otherwise
    //     inherits launchd's cwd, which is an inaccessible inode here — so the
    //     child's getcwd() returns EINVAL and bash aborts init with "shell-init:
    //     error retrieving current directory" (exit 70) before running anything.
    //     /var/root exists in the rootfs and is a safe default; override with
    //     BW64_SPAWN_CWD. The server applies CHDIR in the child before exec.
    {
        const char* cwdEnv = std::getenv("BW64_SPAWN_CWD");
        std::string cwd = (cwdEnv && cwdEnv[0]) ? cwdEnv : "/var/root";
        std::vector<U8> m = buildCmd(SHELLSPAWN_CHDIR, cwd.c_str(), (U16)(cwd.size() + 1));
        client->hostSendBytes(m.data(), (U32)m.size());
        klog_fmt("ShellSpawn: CHDIR '%s'", cwd.c_str());
    }
    // 3) GO with the 3 stdio fds via SCM_RIGHTS {stdin, stdout, stderr}.
    {
        std::vector<U8> m = buildCmd(SHELLSPAWN_GO, nullptr, 0);
        std::vector<KSocketMsgObject> objects;
        KSocketMsgObject o0; o0.object = stdinRead;  o0.accessFlags = K_O_RDWR; objects.push_back(o0);
        KSocketMsgObject o1; o1.object = outWrite;   o1.accessFlags = K_O_RDWR; objects.push_back(o1);
        KSocketMsgObject o2; o2.object = errWrite;   o2.accessFlags = K_O_RDWR; objects.push_back(o2);
        client->hostSendMsgWithObjects(m.data(), (U32)m.size(), objects);
    }

    // 3b) Optional interactive stdin feeder (M2). BW64_STDIN_SCRIPT holds the
    //     input to type at the running child, with literal "\n" decoded to real
    //     newlines so a multi-line session fits in one env var (e.g.
    //     "echo hi\nVAR=42\necho $VAR\nexit"). We write line-by-line with a short
    //     pause between lines so an interactive shell reads, executes, and prints
    //     each one (proving a live read loop, not a one-shot exec), then close
    //     stdin so the shell's read() returns EOF and it exits cleanly. Default
    //     unset = no feeder = the old immediate-EOF stdin (M1 bundle launches keep
    //     working byte-for-byte). The write end (stdinWrite) and the child's read
    //     end (stdinRead) are both held alive by this function's locals.
    std::thread tIn;
    bool haveStdinScript = false;
    if (const char* scriptEnv = std::getenv("BW64_STDIN_SCRIPT")) {
        if (scriptEnv[0]) {
            haveStdinScript = true;
            std::string raw(scriptEnv);
            // Decode the two-char escape "\n" -> newline (and "\\" -> backslash).
            std::string script;
            script.reserve(raw.size());
            for (size_t i = 0; i < raw.size(); i++) {
                if (raw[i] == '\\' && i + 1 < raw.size()) {
                    char nxt = raw[i + 1];
                    if (nxt == 'n') { script.push_back('\n'); i++; continue; }
                    if (nxt == 't') { script.push_back('\t'); i++; continue; }
                    if (nxt == '\\') { script.push_back('\\'); i++; continue; }
                }
                script.push_back(raw[i]);
            }
            tIn = std::thread([stdinWrite, stdinRead, script]() {
                // Give the shell a moment to come up and print its first prompt
                // before we start typing, so the transcript reads naturally.
                std::this_thread::sleep_for(std::chrono::milliseconds(1500));
                size_t start = 0;
                while (start <= script.size()) {
                    size_t nl = script.find('\n', start);
                    size_t end = (nl == std::string::npos) ? script.size() : nl + 1;
                    std::string line = script.substr(start, end - start);
                    if (!line.empty()) {
                        klog_fmt("ShellSpawn[in]: %.*s",
                                 (int)(line.size() - (line.back() == '\n' ? 1 : 0)),
                                 line.c_str());
                        stdinWrite->writeNative((U8*)line.data(), (U32)line.size());
                        // Pace: let the shell parse+run this line and emit output
                        // before the next arrives. Interactive shells need the
                        // gap; a batch shell would not, so this also demonstrates
                        // the input is consumed incrementally.
                        std::this_thread::sleep_for(std::chrono::milliseconds(600));
                    }
                    if (nl == std::string::npos) break;
                    start = end;
                }
                // EOF: stop the shell's read loop so it exits even without a
                // trailing `exit` in the script.
                stdinRead->hostCloseForEof();
            });
        }
    }
    (void)haveStdinScript;

    // Drain child stdout + stderr to the host console on background threads. The
    // child closing stdout/stderr (on exit) makes readNative return 0 (EOF).
    auto drain = [](std::shared_ptr<KUnixSocketObject> r, const char* tag) {
        U8 buf[1024];
        std::string line;
        for (;;) {
            U32 n = r->readNative(buf, sizeof(buf));
            if (n == 0 || (S32)n < 0) {
                break;
            }
            for (U32 i = 0; i < n; i++) {
                char c = (char)buf[i];
                if (c == '\n') {
                    klog_fmt("ShellSpawn[%s]: %s", tag, line.c_str());
                    line.clear();
                } else {
                    line.push_back(c);
                }
            }
        }
        if (!line.empty()) {
            klog_fmt("ShellSpawn[%s]: %s", tag, line.c_str());
        }
    };
    std::thread tOut([&]() { drain(outRead, "out"); });
    std::thread tErr([&]() { drain(errRead, "err"); });

    // 4) Read the child's exit status (one int) back on the connection. The
    // server writes it only after the child exits, by which point the child's
    // stdout/stderr writes have already been delivered into our capture buffers.
    int exitCode = -1;
    U32 got = client->readNative((U8*)&exitCode, sizeof(exitCode));
    if (got == sizeof(exitCode)) {
        klog_fmt("ShellSpawn: '%s' exited with code %d", exec.c_str(), exitCode);
    } else {
        klog_fmt("ShellSpawn: connection closed without an exit code (got=%d)", (int)got);
    }

    // The child is gone — force EOF on the capture read ends so the drain threads
    // flush their last buffered bytes and exit (we hold the write ends alive, so
    // they won't see EOF on their own).
    outRead->hostCloseForEof();
    errRead->hostCloseForEof();
    if (tOut.joinable()) tOut.join();
    if (tErr.joinable()) tErr.join();
    if (tIn.joinable()) tIn.join();
    klog_fmt("ShellSpawn: session complete");
}
