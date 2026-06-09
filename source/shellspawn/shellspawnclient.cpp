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
    // Child's stdin: hand it the read end; we never write, so it sees EOF once the
    // write end is shut. Mark the write end's peer closed so reads return 0.
    // (We simply never write to stdinWrite; sw_vers/uname don't read stdin.)

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
    // 3) GO with the 3 stdio fds via SCM_RIGHTS {stdin, stdout, stderr}.
    {
        std::vector<U8> m = buildCmd(SHELLSPAWN_GO, nullptr, 0);
        std::vector<KSocketMsgObject> objects;
        KSocketMsgObject o0; o0.object = stdinRead;  o0.accessFlags = K_O_RDWR; objects.push_back(o0);
        KSocketMsgObject o1; o1.object = outWrite;   o1.accessFlags = K_O_RDWR; objects.push_back(o1);
        KSocketMsgObject o2; o2.object = errWrite;   o2.accessFlags = K_O_RDWR; objects.push_back(o2);
        client->hostSendMsgWithObjects(m.data(), (U32)m.size(), objects);
    }

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
    klog_fmt("ShellSpawn: session complete");
}
