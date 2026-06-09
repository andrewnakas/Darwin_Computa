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

#ifndef __SHELLSPAWNCLIENT_H__
#define __SHELLSPAWNCLIENT_H__

#include <atomic>
#include <memory>

class KUnixSocketObject;

// In-emulator client for Darling's `org.darlinghq.shellspawn` daemon (the guest
// /usr/libexec/shellspawn, Darling's host->guest command gateway). shellspawn
// runs under launchd and binds a LISTENING AF_UNIX SOCK_STREAM socket at the
// guest path /var/run/shellspawn.sock. That socket lives only in the emulator's
// in-memory KUnixSocket table, so the macOS host cannot connect() to it; the
// client must run inside the emulator and go through the AF_UNIX layer.
//
// This is the INVERSE of source/x11wire/ (an in-process emulator SERVER for a
// guest X11 client): here the emulator is the CLIENT against a guest server. The
// protocol is from darling src/shellspawn/shellspawn.h:
//   struct __attribute__((packed)) shellspawn_cmd { u16 cmd; u16 data_length; char data[]; };
//   opcodes: ADDARG=1 SETENV=2 CHDIR=3 GO=4 SIGNAL=5 SETUIDGID=6 SETEXEC=7
// The server reads each 4-byte header via recvmsg() then the payload via read();
// GO carries the child's {stdin,stdout,stderr} fds via SCM_RIGHTS (exactly 3) and
// the server writes back one int (WEXITSTATUS) on the connection after the child
// exits.
//
// Gated entirely behind the BW64_SHELLSPAWN env var (the guest macho to run, e.g.
// /usr/bin/sw_vers); unset => onShellspawnBound is a no-op and every boot/selftest
// is byte-identical to before.
class ShellSpawnClient {
public:
    static ShellSpawnClient& instance();

    // True if a just-bound AF_UNIX path is shellspawn's listening socket.
    static bool isShellspawnSockPath(const char* path);

    // Called from KUnixSocketObject::bind when a STREAM socket binds shellspawn's
    // path. Fires the client once (atomic guard); spawns a detached host worker so
    // the binding guest thread is never blocked. No-op unless BW64_SHELLSPAWN set.
    void onShellspawnBound(const std::shared_ptr<KUnixSocketObject>& listenSock);

private:
    ShellSpawnClient() = default;
    void driveSession(std::shared_ptr<KUnixSocketObject> listenSock);

    std::atomic<bool> launched{false};
};

#endif
