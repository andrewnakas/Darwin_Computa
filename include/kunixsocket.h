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

#ifndef __KUNIXSOCKET_H__
#define __KUNIXSOCKET_H__

#include "ksocketmsg.h"
#include "ksocketobject.h"
#include "../source/util/ring_buffer.h"

class KUnixSocketObject : public KSocketObject {
public:
    KUnixSocketObject(U32 domain, U32 type, U32 protocol);
    virtual ~KUnixSocketObject();    

    // from KObject
    U32 ioctl(KThread* thread, U32 request) override;
    S64 seek(S64 pos) override;
    S64 length() override;
    S64 getPos() override;
    void setBlocking(bool blocking) override;
    bool isBlocking() override;
    void setAsync(bool isAsync) override;
    bool isAsync() override;
    KFileLock* getLock(KFileLock* lock) override;
    U32 setLock(KFileLock* lock, bool wait) override;
    bool supportsLocks() override;
    bool isOpen() override;
    bool isReadReady() override;
    U64 readReadySeq() override { return this->readSeq; }
    bool isWriteReady() override;
    void waitForEvents(BOXEDWINE_CONDITION& parentCondition, U32 events) override;
    U32 write(KThread* thread, U32 buffer, U32 len) override;
    U32 writeNative(U8* buffer, U32 len) override;
    U32 writev(KThread* thread, U32 iov, S32 iovcnt) override;
    U32 read(KThread* thread, U32 buffer, U32 len) override;
    U32 read(KThread* thread, U32 buffer, U32 len, U32 flags);
    U32 readNative(U8* buffer, U32 len) override;
    U32 stat(KProcess* process, U32 address, bool is64) override;
    U32 map(KThread* thread, U32 address, U32 len, S32 prot, S32 flags, U64 off) override;
    bool canMap() override;
    BString selfFd() override;

    // from KSocketObject
    U32 accept(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 len, U32 flags) override;
    U32 bind(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 len) override;
    U32 connect(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 len) override;
    U32 getpeername(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 plen) override;
    U32 getsockname(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 plen) override;
    U32 getsockopt(KThread* thread, const KFileDescriptorPtr& fd, U32 level, U32 name, U32 value, U32 len_address) override;
    U32 listen(KThread* thread, const KFileDescriptorPtr& fd, U32 backlog) override;
    U32 recvfrom(KThread* thread, const KFileDescriptorPtr& fd, U32 buffer, U32 length, U32 flags, U32 address, U32 address_len) override;
    U32 recvmsg(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 flags) override;
    U32 sendmsg(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 flags) override;
    U32 sendto(KThread* thread, const KFileDescriptorPtr& fd, U32 message, U32 length, U32 flags, U32 dest_addr, U32 dest_len) override;
    U32 setsockopt(KThread* thread, const KFileDescriptorPtr& fd, U32 level, U32 name, U32 value, U32 len) override;
    U32 shutdown(KThread* thread, const KFileDescriptorPtr& fd, U32 how) override;

    std::shared_ptr<FsNode> node;
    std::weak_ptr<KUnixSocketObject> connection;

    static U32 unixsocket_write_native_nowait(const std::shared_ptr<KObject>& obj, U8* value, int len);

    // --- AF_UNIX SOCK_DGRAM (connectionless) support ---------------------------
    // Datagram unix sockets aren't connected: a sender names the destination per
    // message (sendto/sendmsg msg_name) and the receiver pulls from its own msgs
    // queue, learning the sender's address from the dequeued KSocketMsg. Pathname
    // dgram sockets ALSO register a VFS node (like stream); autobind dgram sockets
    // (bind with len==sizeof(family)) get a generated abstract name and ONLY live
    // in this registry. Needed for darlingserver: mldr autobinds its rpc socket so
    // the server can reply, and the server binds a pathname socket at the prefix.
    BString boundPath;              // this dgram socket's own bound address (registry key)
    bool soPassCred = false;        // SO_PASSCRED: synthesize SCM_CREDENTIALS on recv
    static std::shared_ptr<KUnixSocketObject> findBoundDgram(const BString& path);
    static void registerBoundDgram(const BString& path, const std::shared_ptr<KUnixSocketObject>& sock);
    static void unregisterBoundDgram(const BString& path);
    U32 dgramSend(KThread* thread, U32 destAddr, U32 destLen, std::shared_ptr<KSocketMsg> msg, bool nameFromHdr);
    U32 ensureAutobind();           // assign an abstract autobind name if not yet bound

    void signalReadReady();

    // Called on the *receiving* peer after another socket appends bytes to this
    // object's recvBuffer (the three put sites in internal_write/writeNative/
    // unixsocket_write_native_nowait). Base is a no-op; the in-process X11 wire
    // server (XWireServerSocket) overrides it to parse requests synchronously on
    // the writer's thread and write replies/events straight back to the client.
    virtual void onPeerWrote() {}

    // True only for the in-process X11 wire server peer. Used to keep the
    // wineserver-stream read diagnostics (BW64_WSREAD) off the X11 byte-stream.
    virtual bool isXWire() { return false; }

    // Debug-only: bytes currently sitting in the recv buffer (for epoll spin
    // diagnostics — BW64_EPDUMP).
    size_t debugRecvUsed() { return recvBuffer.size_used(); }
    size_t debugMsgsSize() { return msgs.size(); }
    bool debugInClosed() { return inClosed; }
    // pendingConnections total vs the subset whose weak_ptr is still live. If
    // total>0 but live==0, the listen socket is spuriously read-ready forever
    // (expired entries never get accept()'d away) — the epoll busy-spin.
    size_t debugPendingTotal() { return pendingConnections.size(); }
    size_t debugPendingLive() { size_t n=0; for (auto& w : pendingConnections) if (!w.expired()) n++; return n; }

protected:
    std::list< std::weak_ptr<KUnixSocketObject> > pendingConnections; // weak, if object is destroyed it should remove itself from this list
    std::weak_ptr<KUnixSocketObject> connecting;

    BOXEDWINE_CONDITION lockCond;

    Soft_Ring_Buffer recvBuffer;
    std::queue<std::shared_ptr<KSocketMsg> > msgs;
    U32 pid = 0;
    // Bumped on every fresh delivery into recvBuffer or msgs (the analogue of
    // Linux's per-skb sk_data_ready). epoll EPOLLET POLLIN re-fires whenever this
    // advances while the socket is still readable, so a datagram listener whose
    // queue never drains to empty between arrivals (the darlingserver shared dserver
    // socket, fd=3) keeps generating edges instead of latching after the first.
    U64 readSeq = 0;

    U32 internal_write(KThread* thread, const std::shared_ptr<KUnixSocketObject>& con, BOXEDWINE_CONDITION& cond, U32 buffer, U32 len);
    U32 writePipeClosed(KThread* thread, bool noSignal);
    // Flatten any fd-less STREAM frames queued in msgs (deposited by a peer's
    // sendmsg(), each iovec length-prefixed) into the byte recvBuffer so a plain
    // read()/recvfrom can consume them as a stream. Caller must hold lockCond.
    // Frames carrying SCM_RIGHTS objects are left for recvmsg(). See read().
    void drainStreamMsgsToRecvBuffer();
};

#endif
