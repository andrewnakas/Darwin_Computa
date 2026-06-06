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

#include "kunixsocket.h"
#include "ksocket.h"
#include "kstat.h"
#include "ksignal.h"

#include <string>
#include <unordered_map>
#include "../x11wire/xwireserver.h"
#include "../x11wire/xwireconnection.h"

KUnixSocketObject::KUnixSocketObject(U32 domain, U32 type, U32 protocol) : KSocketObject(KTYPE_UNIX_SOCKET, domain, type, protocol), 
    lockCond(std::make_shared<BoxedWineCondition>(B("KUnixSocketObject::lockCond"))), recvBuffer(128)
{
}

KUnixSocketObject::~KUnixSocketObject() {
    if (this->boundPath.length()) {
        KUnixSocketObject::unregisterBoundDgram(this->boundPath);
    }
    if (this->node) {
        std::shared_ptr<FsNode> parent = this->node->getParent().lock();
        if (parent) {
            parent->removeChildByName(this->node->name);
        }
    }

    std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
    if (con) {
        // BW64_SOCKDTOR: witness a connected stream socket being destroyed.
        if (std::getenv("BW64_SOCKDTOR") && this->type == K_SOCK_STREAM && this->connected) {
            KThread* dt = KThread::currentThread();
            klog_fmt("SOCKDTOR: destroying connected stream sock this=%p pid=%u "
                     "peer=%p peerPid=%u byThreadPid=%d byTid=%d",
                     (void*)this, (unsigned)this->pid, (void*)con.get(),
                     (unsigned)con->pid,
                     (int)(dt && dt->process ? dt->process->id : -1),
                     (int)(dt ? dt->id : -1));
        }
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(con->lockCond);
        con = this->connection.lock();
        if (con) {
            if (getenv("BW64_WSREAD")) {
                klog_fmt("WSDISC: peer EOF set — pid=%u recvUsed=%u msgs=%u (this pid=%u)",
                         (unsigned)con->pid, (unsigned)con->recvBuffer.size_used(),
                         (unsigned)con->msgs.size(), (unsigned)this->pid);
            }
            con->connection.reset();
            con->inClosed = true;
            con->outClosed = true;
            BOXEDWINE_CONDITION_SIGNAL_ALL(con->lockCond);
        }
    }

    std::shared_ptr<KUnixSocketObject> c = this->connecting.lock();
    if (c) {
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(c->lockCond);
        auto it = c->pendingConnections.begin();
        while (it != c->pendingConnections.end()) {
            std::shared_ptr<KUnixSocketObject> p = (*it).lock();
            if (p == shared_from_this()) {
                it = c->pendingConnections.erase(it);
            } else {
                it++;
            }
        }
        this->connecting.reset();
    }
    {
		std::vector< std::shared_ptr<KUnixSocketObject> > pendingConnections;

        {
            BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
            for (auto& weakSocket : this->pendingConnections) {
                std::shared_ptr<KUnixSocketObject> s = weakSocket.lock();
                if (s) {
                    s->connecting.reset();
                    pendingConnections.push_back(s);
                }
            }
        }
        for (auto& s : pendingConnections) {
            BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(s->lockCond);
            BOXEDWINE_CONDITION_SIGNAL_ALL(s->lockCond);
        }
        while (!msgs.empty()) {
            this->msgs.pop();
        }
        BOXEDWINE_CONDITION_SIGNAL_ALL(this->lockCond);
    }
}

// --- AF_UNIX SOCK_DGRAM bound-socket registry --------------------------------
// Connectionless dgram delivery needs to resolve a destination address to its
// receiving socket object. Pathname dgram sockets also create a VFS node (so they
// could be found that way) but autobind sockets do not, so a single flat registry
// keyed by the bound address string covers both uniformly. Guarded by its own
// mutex; the stored weak_ptrs self-clean on socket destruction (the dtor calls
// unregisterBoundDgram).
static std::mutex g_dgramRegistryMutex;
static std::unordered_map<std::string, std::weak_ptr<KUnixSocketObject>> g_dgramRegistry;

std::shared_ptr<KUnixSocketObject> KUnixSocketObject::findBoundDgram(const BString& path) {
    std::lock_guard<std::mutex> lock(g_dgramRegistryMutex);
    auto it = g_dgramRegistry.find(std::string(path.c_str()));
    if (it == g_dgramRegistry.end()) {
        return nullptr;
    }
    std::shared_ptr<KUnixSocketObject> s = it->second.lock();
    if (!s) {
        g_dgramRegistry.erase(it);
    }
    return s;
}

void KUnixSocketObject::registerBoundDgram(const BString& path, const std::shared_ptr<KUnixSocketObject>& sock) {
    std::lock_guard<std::mutex> lock(g_dgramRegistryMutex);
    g_dgramRegistry[std::string(path.c_str())] = sock;
}

void KUnixSocketObject::unregisterBoundDgram(const BString& path) {
    std::lock_guard<std::mutex> lock(g_dgramRegistryMutex);
    g_dgramRegistry.erase(std::string(path.c_str()));
}

// Give an unbound dgram socket an abstract autobind name so the peer it sends to
// can reply (Linux assigns "\0<5 hex digits>" on autobind / on first send from an
// unbound socket). We model the leading NUL as a literal "@" prefix in our string
// keys (abstract namespace), which never collides with a real pathname.
U32 KUnixSocketObject::ensureAutobind() {
    if (this->boundPath.length()) {
        return 0;
    }
    static std::atomic<U32> counter{1};
    U32 n = counter.fetch_add(1);
    BString name;
    name.sprintf("@dgram-autobind-%05x", (unsigned)(n & 0xfffff));
    this->boundPath = name;
    KUnixSocketObject::registerBoundDgram(this->boundPath, std::dynamic_pointer_cast<KUnixSocketObject>(shared_from_this()));
    return 0;
}

void KUnixSocketObject::setBlocking(bool blocking) {
    BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
    this->blocking = blocking;
}

bool KUnixSocketObject::isBlocking() {
    return this->blocking;
}

void  KUnixSocketObject::setAsync(bool isAsync) {
    if (isAsync)
        kpanic(" UnixSocketObject::setAsync not implemented yet");
}

bool  KUnixSocketObject::isAsync() {
    return false;
}

KFileLock*  KUnixSocketObject::getLock(KFileLock* lock) {
    kdebug("UnixSocketObject::getLock not implemented yet");
    return nullptr;
}

U32  KUnixSocketObject::setLock(KFileLock* lock, bool wait) {
    kdebug(" UnixSocketObject::setLock not implemented yet");
    return -1;
}

bool KUnixSocketObject::isOpen() {
    if (this->listening) {
        return true;
    }
    return connected && (!outClosed || !inClosed);
}

bool KUnixSocketObject::isReadReady() {
    //BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
    return this->inClosed || this->recvBuffer.size_used() || this->pendingConnections.size() || this->msgs.size();
}

bool KUnixSocketObject::isWriteReady() {
    // A connectionless datagram socket is always ready to send (each sendmsg is
    // routed to the destination's queue, there is no peer flow-control). Reporting
    // it as NOT writable made darlingserver's outbox spin: it epoll-waits for the
    // listener socket to become writable to flush replies, and with no connection
    // (dgram) connection.expired() was always true -> never writable -> a busy
    // eventfd re-arm loop that starved the rest of the boot.
    if (this->type == K_SOCK_DGRAM) {
        return true;
    }
    return !connection.expired();
}

void KUnixSocketObject::waitForEvents(BOXEDWINE_CONDITION& parentCondition, U32 events) {
    bool addedLock = false;

    if (events & K_POLLIN) {
        BOXEDWINE_CONDITION_ADD_PARENT(this->lockCond, parentCondition);
        addedLock = true;
    }
    if (events & K_POLLOUT) {
        std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
        if (con) {
            BOXEDWINE_CONDITION_ADD_PARENT(con->lockCond, parentCondition);
        } else {
            if (!addedLock) {
                BOXEDWINE_CONDITION_ADD_PARENT(this->lockCond, parentCondition);
                addedLock = true;
            }
        }
    }
    if (events && ((events & ~(K_POLLIN | K_POLLOUT)) || this->listening)) {
        if (!addedLock) {
            BOXEDWINE_CONDITION_ADD_PARENT(this->lockCond, parentCondition);
        }
    }
    if (events == 0) {
        BOXEDWINE_CONDITION_REMOVE_PARENT(this->lockCond, parentCondition);
    }
}

U32 KUnixSocketObject::internal_write(KThread* thread, const std::shared_ptr<KUnixSocketObject>& con, BOXEDWINE_CONDITION& cond, U32 buffer, U32 len) {
    KMemory* memory = thread->memory;

    if (!memory->canRead(buffer, len)) {
        return -K_EFAULT;
    }
    if (this->type == K_SOCK_DGRAM) {
        if (!strcmp(this->destAddress.data, "/dev/log")) {
            BString s = memory->readString(buffer);
            printf("%s\n", s.c_str());
        }
        return len;
    }
    if (this->outClosed || !con) {
        // 64-bit threads must not take the SIGPIPE/-K_CONTINUE path (mis-delivered
        // on the 32-bit cpu, sentinel leaks as a short write -> wine "partial
        // write"); return a clean -EPIPE like Linux. See writeNative for the full
        // rationale.
        if (thread->cpu64) {
            return -K_EPIPE;
        }
        return writePipeClosed(thread, false);
    }
    //printf("internal_write: %0.8X size=%d capacity=%d writeLen=%d", (int)&this->connection->recvBuffer, (int)this->connection->recvBuffer.size(), (int)this->connection->recvBuffer.capacity(), len);

    memory->performOnMemory(buffer, len, true, [con](U8* ram, U32 len) {
        con->recvBuffer.put(ram, len);
        return true;
        });
    return len;
}

U32 KUnixSocketObject::writev(KThread* thread, U32 iov, S32 iovcnt) {
    S32 len=0;
    std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
    KMemory* memory = thread->memory;
    bool wrote = false;

    {
        BOXEDWINE_CONDITION& cond = (con?con->lockCond:this->lockCond);
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(cond);

        for (S32 i=0;i<iovcnt;i++) {
            U32 buf = memory->readd(iov + i * 8);
            U32 toWrite = memory->readd(iov + i * 8 + 4);
            S32 result;

            if (toWrite) {
                result = this->internal_write(thread, con, cond, buf, toWrite);
                if (result < 0) {
                    if (i == 0) len = result; // first segment failed: report errno
                    break;
                }
                len += result;
            }
        }
        if (con) {
            BOXEDWINE_CONDITION_SIGNAL_ALL(cond);
        }
        wrote = (len > 0);
    }
    // Notify a server peer (X11 wire server) outside the lock — see write().
    if (con && wrote) con->onPeerWrote();
    return (U32)len;
}

U32 KUnixSocketObject::write(KThread* thread, U32 buffer, U32 len) {
    this->pid = thread->process->id; // kind of a hack to do this here
    std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
    U32 result;
    {
        BOXEDWINE_CONDITION& cond = (con?con->lockCond:this->lockCond);
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(cond);
        result = this->internal_write(thread, con, cond, buffer, len);
        if (con) {
            BOXEDWINE_CONDITION_SIGNAL_ALL(con->lockCond);
        }
    }
    // Notify a server peer (e.g. the X11 wire server) outside the lock so its
    // synchronous request parsing can re-read this same recvBuffer.
    if (con) con->onPeerWrote();
    return result;
}

U32 KUnixSocketObject::writeNative(U8* buffer, U32 len) {
    if (this->type == K_SOCK_DGRAM) {
        if (!strcmp(this->destAddress.data, "/dev/log")) {
            klog_fmt("%s", buffer);
        }
        return len;
    }
    std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
    if (this->outClosed || !con) {
		KThread* thread = KThread::currentThread();
        // BW64_WRITECLOSED: the wineserver request-socket write hits this branch
        // mid-boot and returns -K_CONTINUE (from writePipeClosed's SIGPIPE path),
        // which leaks to wine as a bogus byte count -> "partial write". Log WHY:
        // is the peer genuinely outClosed, or did the connection weak_ptr fail to
        // lock (a transient under MT, peer object still alive elsewhere)?
        if (std::getenv("BW64_WRITECLOSED")) {
            klog_fmt("WRITECLOSED: this=%p pid=%d tid=%d len=%u outClosed=%d con=%s inClosed=%d type=%d connected=%d",
                     (void*)this,
                     (int)(thread && thread->process ? thread->process->id : -1),
                     (int)(thread ? thread->id : -1),
                     (unsigned)len, (int)this->outClosed,
                     con ? "alive" : "NULL", (int)this->inClosed, (int)this->type,
                     (int)this->connected);
        }
        // A connected stream socket whose peer weak_ptr momentarily fails to lock
        // (peer object transiently unreferenced under fd-table churn at boot)
        // is NOT a broken pipe: returning the SIGPIPE/-K_CONTINUE sentinel leaks
        // out of sys_write64 as a bogus byte count and wine reports "partial
        // write" -> fatal client error. Treat "connected, not explicitly closed,
        // peer not lockable" as a transient -EWOULDBLOCK so a blocking writer
        // retries (the wineserver request socket is blocking) instead of dying.
        if (!this->outClosed && this->connected && !con) {
            return -K_EWOULDBLOCK;
        }
        // Broken pipe: the peer endpoint is gone. writePipeClosed() raises SIGPIPE
        // via the 32-bit KThread::runSignal, which (a) builds the signal frame on
        // the UNUSED 32-bit this->cpu for a 64-bit thread (mis-delivery) and (b)
        // returns -K_CONTINUE, a sentinel the 64-bit dispatcher leaves in RAX as a
        // garbage "bytes written" count -> wine reads a short write on its
        // wineserver request socket -> "partial write" -> fatal client error +
        // wineserver heap corruption as it reaps the broken client. Real Linux
        // write-to-broken-pipe with SIGPIPE ignored (wine always SIG_IGNs it)
        // simply returns -EPIPE. So for a 64-bit thread, return a clean -EPIPE and
        // never leak the -K_CONTINUE sentinel; the 32-bit path keeps its existing
        // SIGPIPE behaviour. (See [[project_boxedwine64_bug2_teardown]] for the
        // same 32-bit-runSignal-on-a-64-bit-thread mis-delivery class.)
        if (thread && thread->cpu64) {
            return -K_EPIPE;
        }
        if (thread) {
            return writePipeClosed(thread, false);
        }
        return -K_EPIPE;
    }

    {
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(con->lockCond);
        con->recvBuffer.put(buffer, len);
        BOXEDWINE_CONDITION_SIGNAL_ALL(con->lockCond);
    }
    con->onPeerWrote();
    return len;
}

void KUnixSocketObject::signalReadReady() {
    BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(lockCond);
    BOXEDWINE_CONDITION_SIGNAL_ALL(lockCond);
}

U32 KUnixSocketObject::unixsocket_write_native_nowait(const std::shared_ptr<KObject>& obj, U8* value, int len) {
    if (obj->type!=KTYPE_UNIX_SOCKET)
        return 0;
    std::shared_ptr<KUnixSocketObject> s = std::dynamic_pointer_cast<KUnixSocketObject>(obj);

    if (s->type == K_SOCK_DGRAM) {
        return 0;
    }
    std::shared_ptr<KUnixSocketObject> con = s->connection.lock();
    if (s->outClosed || !con)
        return -K_EPIPE;

    {
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(con->lockCond);
        //printf("SOCKET write len=%d bufferSize=%d pos=%d\n", len, s->connection->recvBufferLen, s->connection->recvBufferWritePos);
        con->recvBuffer.put(value, len);
        BOXEDWINE_CONDITION_SIGNAL_ALL(con->lockCond);
    }
    con->onPeerWrote();
    return len;
}

U32 KUnixSocketObject::readNative(U8* buffer, U32 len) {
    std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
    if (!this->inClosed && !con)
        return -K_EPIPE;
    con = nullptr; // don't hold a strong reference to this, if we are blocking then it would prevent the con object from being destroyed when its process is closed
    BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
    while (this->recvBuffer.size_used()==0) {
        if (this->inClosed) {
            return 0;
        }
        if (!this->blocking) {
            return -K_EWOULDBLOCK;
        }
        BOXEDWINE_CONDITION_WAIT(this->lockCond);
#ifdef BOXEDWINE_MULTI_THREADED
        KThread* thread = KThread::currentThread();
        // audio thread will call this function without a thread
        if (thread) {
            if (thread->terminating) {
                return -K_EINTR;
            }
            if (thread->startSignal) {
                thread->startSignal = false;
                return -K_CONTINUE;
            }
        }
#endif
    }
    //printf("readNative: %0.8X size=%d capacity=%d writeLen=%d", (int)&this->recvBuffer, (int)this->recvBuffer.size(), (int)this->recvBuffer.capacity(), len);
    if (len > this->recvBuffer.size_used()) {
        len = (U32)this->recvBuffer.size_used();
    }
    this->recvBuffer.get(buffer, len);
    BOXEDWINE_CONDITION_SIGNAL_ALL(this->lockCond);
    //printf("    readNative: %0.8X size=%d capacity=%d writeLen=%d", (int)&this->recvBuffer, (int)this->recvBuffer.size(), (int)this->recvBuffer.capacity(), len);
    return len;
}

U32 KUnixSocketObject::read(KThread* thread, U32 buffer, U32 len) {
    return read(thread, buffer, len, 0);
}

U32 KUnixSocketObject::read(KThread* thread, U32 buffer, U32 len, U32 flags) {
    bool peek = false;
    if (flags & K_MSG_PEEK) {
        peek = true;
        flags &= ~K_MSG_PEEK;
    }
    if (flags) {
        kwarn_fmt("KUnixSocketObject::recvfrom unhandled flags=%x", flags);
    }

    U32 count = 0;
    this->pid = thread->process->id; // kind of a hack to do this here
    std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
    KMemory* memory = thread->memory;

    if (!memory->canWrite(buffer, len)) {
        return -K_EFAULT;
    }
    if (!this->inClosed && !con)
        return -K_EPIPE;
    con = nullptr; // don't hold a strong reference to this, if we are blocking then it would prevent the con object from being destroyed when its process is closed
    BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
    while (this->recvBuffer.size_used()==0) {
        if (this->inClosed) {
            return 0;
        }
        if (!this->blocking) {
            return -K_EWOULDBLOCK;
        }
        BOXEDWINE_CONDITION_WAIT(this->lockCond);
#ifdef BOXEDWINE_MULTI_THREADED
		if (thread->terminating) {
			return -K_EINTR;
		}
        if (thread->startSignal) {
            thread->startSignal = false;
            return -K_CONTINUE;
        }
#endif
    }
    count = std::min(len, (U32)this->recvBuffer.size_used());
    if (peek) {
        U32 availableOnPage = K_PAGE_SIZE - (buffer & K_PAGE_MASK);
        if (count <= availableOnPage) {
            memory->performOnMemory(buffer, count, false, [this](U8* ram, U32 len) {
                this->recvBuffer.peek(ram, len);
                return true;
                });
        } else {
            U8* tmp = new U8[count];
            this->recvBuffer.peek(tmp, count);
            U8* p = tmp;
            memory->performOnMemory(buffer, count, false, [&p](U8* ram, U32 len) {
                memcpy(ram, p, len);
                p += len;
                return true;
                });
            delete[] tmp;
        }
    }
    else {
        memory->performOnMemory(buffer, count, false, [this](U8* ram, U32 len) {
            this->recvBuffer.get(ram, len);
            return true;
            });
    }
    con = this->connection.lock();
    if (con) {
        BOXEDWINE_CONDITION_SIGNAL_ALL(this->lockCond);
    }

    return count;
}

U32 KUnixSocketObject::stat(KProcess* process, U32 address, bool is64) {
    KSystem::writeStat(process, B(""), address, is64, true, (this->node?this->node->id:0), K_S_IFSOCK|K__S_IWRITE|K__S_IREAD, (this->node?this->node->rdev:0), 0, 4096, 0, this->lastModifiedTime, 1);
    return 0;
}

U32 KUnixSocketObject::map(KThread* thread, U32 address, U32 len, S32 prot, S32 flags, U64 off) {
    return 0;
}

bool KUnixSocketObject::canMap() {
    return false;
}

BString KUnixSocketObject::selfFd() {
    return B("anon_inode:[pipe]");
}

S64 KUnixSocketObject::seek(S64 pos) {
    return -K_ESPIPE;
}

S64 KUnixSocketObject::getPos() {
    return 0;
}

U32 KUnixSocketObject::ioctl(KThread* thread, U32 request) {
    return -K_ENOTTY;
}

bool KUnixSocketObject::supportsLocks() {
    return false;
}

S64 KUnixSocketObject::length() {
    return -1;
}

class UnixSocketNode : public FsNode {
public:
    UnixSocketNode(U32 id, U32 rdev, BString path, std::shared_ptr<FsNode> parent) : FsNode(Type::Socket, id, rdev, path, B(""), B(""), false, parent) {}
    U32 rename(BString path) override {return -K_EIO;}
    bool remove() override {if (!this->parent.lock()) return false; this->removeNodeFromParent(); return true;}
    U64 lastModified() override {return 0;}
    U64 length() override {return 0;}
    FsOpenNode* open(U32 flags) override {kwarn("unixsocket_open was called, this shouldn't happen.  syscall_open should detect we have a kobject already"); return nullptr;}
    U32 getType(bool checkForLink) override {return 12;} // DT_SOCK
    U32 getMode() override {return K__S_IREAD | K__S_IWRITE | K_S_IFSOCK;}
    U32 removeDir() override {kpanic("UnixSocket::removeDir not implemented"); return 0;}
    U32 setTimes(U64 lastAccessTime, U32 lastAccessTimeNano, U64 lastModifiedTime, U32 lastModifiedTimeNano) override {klog("UnixSocket::setTimes not implemented"); return 0;}
};

U32 KUnixSocketObject::bind(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 len) {
    KMemory* memory = thread->memory;

    U32 family = memory->readw(address);
    if (family==K_AF_UNIX) {
        BString name = socketAddressName(memory, address, len);

        if (name.length() == 0) {
            // No path in the address. For a DGRAM socket this is AUTOBIND
            // (bind(fd, &family, sizeof(family))): Linux assigns an abstract name
            // so peers can reply. darlingserver's mldr rpc socket relies on this.
            if (this->type == K_SOCK_DGRAM) {
                return this->ensureAutobind();
            }
            return 0; // :TODO: why does XOrg need this
        }
        std::shared_ptr<FsNode> node = Fs::getNodeFromLocalPath(thread->process->currentDirectory, name, true);
        if (node) {
            return -K_EADDRINUSE;
        }
        BString fullpath = Fs::getFullPath(thread->process->currentDirectory, name);
        this->destAddress.family = family;
        strncpy(this->destAddress.data, fullpath.c_str(), sizeof(this->destAddress.data));
		this->destAddress.data[sizeof(this->destAddress.data) - 1] = 0;
        std::shared_ptr<FsNode> parentNode = Fs::getNodeFromLocalPath(B(""), Fs::getParentPath(fullpath), true);
        std::shared_ptr<UnixSocketNode> socketNode = std::make_shared<UnixSocketNode>(0, 2, fullpath, parentNode);
        parentNode->addChild(socketNode);
        std::shared_ptr<KUnixSocketObject> s = std::dynamic_pointer_cast<KUnixSocketObject>(fd->kobject);
        socketNode->kobject = fd->kobject;
        s->node = socketNode;
        // DGRAM delivery resolves a destination by address via the registry (a
        // pathname dgram socket has a VFS node too, but autobind ones don't, so a
        // uniform registry covers both). Record the bound path for reply routing.
        if (this->type == K_SOCK_DGRAM) {
            this->boundPath = fullpath;
            KUnixSocketObject::registerBoundDgram(fullpath, s);
        }
        return 0;
    }
    return -K_EAFNOSUPPORT;
}

U32 KUnixSocketObject::connect(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 len) {
    KMemory* memory = thread->memory;

    if (len < 2) {
        return -K_EINVAL;
	}
    this->pid = thread->process->id;
    if (len>sizeof(this->destAddress.data)+2) {
        kpanic("Socket address is too big");
    }
    this->destAddress.family = memory->readw(address);
    memory->memcpy(this->destAddress.data, address + 2, len - 2);
    if (this->type==K_SOCK_DGRAM) {
        this->connected = true;
        return -K_EISCONN;
    } else if (this->type==K_SOCK_STREAM) {
        if (this->destAddress.data[0]==0) {
            // :TODO: why
            memory->memcpy(this->destAddress.data, address + 3, len - 3);
        }
        if (this->destAddress.data[0] == 0) {
            return -K_ENOENT;
        }
        if (this->domain==K_AF_UNIX) {
            if (getenv("BW64_SCDUMP")) {
                klog_fmt("KUnixSocket::connect AF_UNIX path='%s' isX=%d",
                         this->destAddress.data,
                         (int)XWireServer::isXDisplayPath(this->destAddress.data));
            }
            // In-process X11 wire server: a guest connect to /tmp/.X11-unix/X<n>
            // is wine's real libX11 reaching for an X server. There is no real
            // X server in the rootfs, so hand the connection to our SDL-backed
            // wire server instead of returning ECONNREFUSED (which makes libX11
            // fall back to a TCP :6000 probe and then run headless/spinning).
            if (XWireServer::isXDisplayPath(this->destAddress.data)) {
                std::shared_ptr<KUnixSocketObject> self = std::dynamic_pointer_cast<KUnixSocketObject>(shared_from_this());
                if (XWireServer::instance().acceptConnection(self)) {
                    this->connected = true;
                    return 0;
                }
                this->destAddress.family = 0;
                return -K_ECONNREFUSED;
            }
            std::shared_ptr<FsNode> node = Fs::getNodeFromLocalPath(thread->process->currentDirectory, BString::copy(this->destAddress.data), true);
            std::shared_ptr<KObject> kobject;
            if (node) {
                kobject = node->kobject.lock();
            }
            if (!node || !kobject || kobject->type!=KTYPE_UNIX_SOCKET) {
                this->destAddress.family = 0;
                return -K_ECONNREFUSED;
            }     
            std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
            if (con) {
                this->connected = true;
                return 0;
            }     
            con = nullptr; // don't hold a strong reference to this, if we are blocking then it would prevent the con object from being destroyed when its process is closed
            if (!this->connecting.expired()) {
                if (this->blocking) {
                    BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
                    while (!this->connecting.expired()) {
                        BOXEDWINE_CONDITION_WAIT(this->lockCond);
#ifdef BOXEDWINE_MULTI_THREADED
						if (thread->terminating) {
							return -K_EINTR;
						}
                        if (thread->startSignal) {
                            thread->startSignal = false;
                            return -K_CONTINUE;
                        }
#endif
                    }
                    if (this->connection.expired()) {
                        return -K_ECONNREFUSED;
                    }
                    this->connected = true;
                    return 0;
                } else {
                    return -K_EINPROGRESS;
                }
            } else {
                std::shared_ptr<KUnixSocketObject> destination = std::dynamic_pointer_cast<KUnixSocketObject>(node->kobject.lock());

                this->connecting = destination;
                {
                    BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(destination->lockCond);
                    std::shared_ptr< KUnixSocketObject> t = std::dynamic_pointer_cast<KUnixSocketObject>(shared_from_this());
                    destination->pendingConnections.push_back(t);
                    BOXEDWINE_CONDITION_SIGNAL_ALL(destination->lockCond);
                }

                if (!this->blocking) {
                    return -K_EINPROGRESS;
                }
                // :TODO: what about a time out
                
                BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
                if (!this->connecting.expired()) {
                    BOXEDWINE_CONDITION_WAIT(this->lockCond);
#ifdef BOXEDWINE_MULTI_THREADED
					if (thread->terminating) {
						return -K_EINTR;
					}
                    if (thread->startSignal) {
                        thread->startSignal = false;
                        return -K_CONTINUE;
                    }
#endif
                }
                if (this->connection.expired()) {
                    return -K_ECONNREFUSED;
                }
                this->connected = true;
                return 0;
            }
        } else {
            kpanic_fmt("connect not implemented for domain %d", this->domain);
        }
    } else {
        kwarn_fmt("connect not implemented for type %d", this->type);
        return -K_ECONNREFUSED;
    }
    // should never get here
    return 0;
}

U32 KUnixSocketObject::listen(KThread* thread, const KFileDescriptorPtr& fd, U32 backlog) {
    if (!this->node) {
        return -K_EDESTADDRREQ;
    }
    if (!this->connection.expired() || !this->connecting.expired()) {
        return -K_EINVAL;
    }
    this->listening = true;
    return 0;
}

U32 KUnixSocketObject::accept(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 len, U32 flags) {
    std::shared_ptr<KUnixSocketObject> pendingConnection;
    {
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
        while (!this->pendingConnections.size()) {
            if (!this->blocking) {
                return -K_EWOULDBLOCK;
            }
            BOXEDWINE_CONDITION_WAIT(this->lockCond);
    #ifdef BOXEDWINE_MULTI_THREADED
            if (thread->terminating) {
                return -K_EINTR;
            }
            if (thread->startSignal) {
                thread->startSignal = false;
                return -K_CONTINUE;
            }
    #endif
        }

        pendingConnection = this->pendingConnections.front().lock();
        this->pendingConnections.pop_front();
    }
    if (pendingConnection == nullptr) {
        return -K_ECONNABORTED;
	}

    BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(pendingConnection->lockCond);
    std::shared_ptr<KUnixSocketObject> resultSocket = std::make_shared<KUnixSocketObject>(domain, type, protocol);
    KFileDescriptorPtr result = thread->process->allocFileDescriptor(resultSocket, K_O_RDWR, 0, -1, 0);

    if (flags & FD_CLOEXEC) {
        result->descriptorFlags|=FD_CLOEXEC;
    }
    if (flags & K_O_NONBLOCK) {
        result->kobject->setBlocking(false);
    }

    pendingConnection->connection = resultSocket;
    //pendingConnection->connected = true; this will be handled when the connecting thread is unblocked    

    resultSocket->connected = true;
    resultSocket->connection = pendingConnection; // weak reference
    
    BOXEDWINE_CONDITION_SIGNAL_ALL(pendingConnection->lockCond);

    return result->handle;
}

U32 KUnixSocketObject::getsockname(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 plen) {
    KMemory* memory = thread->memory;

    U32 len = memory->readd( plen);
    if (this->domain == K_AF_UNIX) {
        memory->writew(address, this->destAddress.family);
        len-=2;
        if (len>sizeof(this->destAddress.data))
            len = sizeof(this->destAddress.data);
        memory->memcpy(address + 2, this->destAddress.data, len);
        memory->writed(plen, 2 + (U32)strlen(this->destAddress.data) + 1);
        return 0;
    }
    kwarn_fmt("KUnixSocketObject::getsockname not implemented for domain %d", this->domain);
    return 0;
}

U32 KUnixSocketObject::getpeername(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 plen) {
    KMemory* memory = thread->memory;

    if (this->connection.expired())
        return -K_ENOTCONN;
    U32 len = memory->readd( plen);
    memory->writew(address, this->destAddress.family);
    len-=2;
    if (len>sizeof(this->destAddress.data))
        len = sizeof(this->destAddress.data);
    memory->memcpy(address + 2, this->destAddress.data, len);
    memory->writed(plen, 2 + (U32)strlen(this->destAddress.data) + 1);
    return 0;
}

U32 KUnixSocketObject::shutdown(KThread* thread, const KFileDescriptorPtr& fd, U32 how) {
    if (this->type == K_SOCK_DGRAM) {
        kwarn("shutdown on SOCK_DGRAM not implemented");
        return -1;
    }
    std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
    if (!con) {
        return -K_ENOTCONN;
    }
    if (how == K_SHUT_RD) {
        {
            BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
            this->inClosed = true;
            BOXEDWINE_CONDITION_SIGNAL_ALL(this->lockCond);
        }
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(con->lockCond);
        con->outClosed = true;
        BOXEDWINE_CONDITION_SIGNAL_ALL(con->lockCond);
    } else if (how == K_SHUT_WR) {
        {
            BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
            this->outClosed = true;
            BOXEDWINE_CONDITION_SIGNAL_ALL(this->lockCond);
        }
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(con->lockCond);
        con->inClosed = true;
        BOXEDWINE_CONDITION_SIGNAL_ALL(con->lockCond);
    } else if (how == K_SHUT_RDWR) {
        {
            BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
            this->outClosed = true;
            this->inClosed = true;
            BOXEDWINE_CONDITION_SIGNAL_ALL(this->lockCond);
        }
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(con->lockCond);
        con->outClosed = true;
        con->inClosed = true;
        BOXEDWINE_CONDITION_SIGNAL_ALL(con->lockCond);
    }
    return 0;
}

U32 KUnixSocketObject::setsockopt(KThread* thread, const KFileDescriptorPtr& fd, U32 level, U32 name, U32 value, U32 len) {
    KMemory* memory = thread->memory;

    if (level == K_SOL_SOCKET) {
        switch (name) {
            case K_SO_RCVBUFFORCE:
            case K_SO_RCVBUF:
                if (len!=4)
                    kpanic("KUnixSocketObject::setsockopt SO_RCVBUF expecting len of 4");
                this->recvLen = memory->readd(value);
                break;
            case K_SO_SNDBUFFORCE:
            case K_SO_SNDBUF:
                if (len != 4)
                    kpanic("KUnixSocketObject::setsockopt SO_SNDBUF expecting len of 4");
                this->sendLen = memory->readd(value);
                break;
            case K_SO_PASSCRED:
                // Enable SCM_CREDENTIALS delivery on recv. darlingserver sets this
                // and reads the sender pid from each datagram's creds to identify
                // the process; without honoring it the server can't attribute the
                // checkin to mldr's pid.
                this->soPassCred = (len >= 4) ? (memory->readd(value) != 0) : true;
                break;
            case K_SO_ATTACH_FILTER:
                break;
            default:
                kwarn_fmt("KUnixSocketObject::setsockopt name %d not implemented", name);
        }
    } else {
        kwarn_fmt("KUnixSocketObject::setsockopt level %d not implemented", level);
    }
    return 0;
}

U32 KUnixSocketObject::getsockopt(KThread* thread, const KFileDescriptorPtr& fd, U32 level, U32 name, U32 value, U32 len_address) {
    KMemory* memory = thread->memory;

    U32 len = memory->readd(len_address);
    if (level == K_SOL_SOCKET) {
        if (name == K_SO_RCVBUF) {
            if (len!=4)
                kpanic("KUnixSocketObject::getsockopt SO_RCVBUF expecting len of 4");
            memory->writed(value, this->recvLen);
        } else if (name == K_SO_SNDBUF) {
            if (len != 4)
                kpanic("KUnixSocketObject::getsockopt SO_SNDBUF expecting len of 4");
            memory->writed(value, this->sendLen);
        } else if (name == K_SO_ERROR) {
            if (len != 4)
                kpanic("KUnixSocketObject::getsockopt SO_ERROR expecting len of 4");
            memory->writed(value, this->error);
        } else if (name == K_SO_TYPE) { 
            if (len != 4)
                kpanic("KUnixSocketObject::getsockopt K_SO_TYPE expecting len of 4");
            memory->writed(value, this->type);
        } else if (name == K_SO_PEERCRED) {
            if (this->domain!=K_AF_UNIX) {
                return -K_EINVAL; // :TODO: is this right
            }
            std::shared_ptr<KUnixSocketObject> con = this->connection.lock();
            if (!con) {
                return -K_EINVAL; // :TODO: is this right
            }
            if (len != 12)
                kpanic("KUnixSocketObject::getsockopt SO_PEERCRED expecting len of 12");
            memory->writed(value, con->pid);
            memory->writed(value + 4, thread->process->userId);
            memory->writed(value + 8, thread->process->groupId);
        } else {
            kwarn_fmt("KUnixSocketObject::getsockopt name %d not implemented", name);
            return -K_EINVAL;
        }
    } else {
        kwarn_fmt("KUnixSocketObject::getsockopt level %d not implemented", level);
        return -K_EINVAL;
    }
    return 0;
}

U32 KUnixSocketObject::writePipeClosed(KThread* thread, bool noSignal) {
    if (noSignal || thread->process->sigActions[K_SIGPIPE].handlerAndSigAction == K_SIG_IGN || !thread->readyForSignal(K_SIGPIPE)) {
        return -K_EPIPE;
    }
    thread->runSignal(K_SIGPIPE, 0, 0);
    return -K_CONTINUE;
}

// Build a single atomic datagram (no per-iovec framing — a dgram is one message)
// from the msghdr's iovecs, plus any SCM_RIGHTS fds, then route it to the
// destination dgram socket named by destAddr (sendto) or msg_name (sendmsg) or
// the connected destAddress. Returns the payload byte count on success.
U32 KUnixSocketObject::dgramSend(KThread* thread, U32 destAddr, U32 destLen, std::shared_ptr<KSocketMsg> msg, bool /*nameFromHdr*/) {
    // Resolve destination path: explicit address wins, else the connected peer.
    BString destPath;
    if (destAddr) {
        destPath = socketAddressName(thread->memory, destAddr, destLen);
    }
    if (destPath.length() == 0) {
        if (this->connected && this->destAddress.data[0]) {
            destPath = BString::copy(this->destAddress.data);
        } else {
            return -K_ENOTCONN;
        }
    }
    // Absolute-ify a relative dest path the same way bind/connect do, so the
    // registry key matches the bound full path.
    if (destPath.length() && destPath.c_str()[0] != '/' && destPath.c_str()[0] != '@') {
        destPath = Fs::getFullPath(thread->process->currentDirectory, destPath);
    }
    std::shared_ptr<KUnixSocketObject> dest = KUnixSocketObject::findBoundDgram(destPath);
    if (getenv("BW64_DGRAM")) {
        klog_fmt("DGRAM send pid=%d destAddr=0x%x destLen=%d destPath='%s' found=%d",
                 (int)thread->process->id, destAddr, destLen, destPath.c_str(), dest ? 1 : 0);
    }
    if (!dest) {
        return -K_ECONNREFUSED;
    }
    // Stamp the sender's return address + credentials onto the datagram. Autobind
    // ourselves first if unbound so a reply can come back.
    this->ensureAutobind();
    msg->hasSender = true;
    msg->senderPath = this->boundPath;
    msg->senderPid = thread->process->id;
    msg->senderUid = thread->process->userId;
    msg->senderGid = thread->process->groupId;
    U32 payload = (U32)msg->data.size();
    {
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(dest->lockCond);
        dest->msgs.push(msg);
        BOXEDWINE_CONDITION_SIGNAL_ALL(dest->lockCond);
    }
    return payload;
}

U32 KUnixSocketObject::sendmsg(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 flags) {
    MsgHdr hdr = {};
    KMemory* memory = thread->memory;
    U32 result = 0;

    // SOCK_DGRAM: connectionless. Build one atomic datagram and deliver it to the
    // socket bound at the destination address (msg_name or the connected peer).
    // This is the path darlingserver's mldr rpc checkin uses.
    if (this->type == K_SOCK_DGRAM) {
        flags &= ~K_MSG_NOSIGNAL;
        readMsgHdr(thread, address, &hdr);
        std::shared_ptr<KSocketMsg> msg = std::make_shared<KSocketMsg>();
        // SCM_RIGHTS fds. The 64-bit shim (sys_sendmsg64) has already flattened the
        // guest's cmsg into the object's compact form: one 16-byte record per fd,
        // {len=16, level, type, fd@+12}, with msg_controllen = nfds*16. Iterate
        // those records (same convention as the stream path). Any SCM_CREDENTIALS
        // the guest sent is dropped here; we synthesize creds on the receive side.
        if (hdr.msg_control) {
            for (U32 i = 0; i < hdr.msg_controllen / 16; i++) {
                CMsgHdr cmsg;
                readCMsgHdr(thread, hdr.msg_control + 16 * i, &cmsg);
                if (cmsg.cmsg_level != K_SOL_SOCKET || cmsg.cmsg_type != K_SCM_RIGHTS) {
                    continue;
                }
                KFileDescriptorPtr f = thread->process->getFileDescriptor(memory->readd(hdr.msg_control + 16 * i + 12));
                if (f) {
                    KSocketMsgObject d;
                    d.object = f->kobject;
                    d.accessFlags = f->accessFlags;
                    msg->objects.push_back(d);
                }
            }
        }
        // Concatenate all iovecs into one contiguous datagram payload.
        for (U32 i = 0; i < hdr.msg_iovlen; i++) {
            U32 p = memory->readd(hdr.msg_iov + 8 * i);
            U32 len = memory->readd(hdr.msg_iov + 8 * i + 4);
            while (len) {
                msg->data.push_back(memory->readb(p++));
                len--;
            }
        }
        return this->dgramSend(thread, hdr.msg_name, hdr.msg_namelen, msg, true);
    }

    std::shared_ptr<KUnixSocketObject> con = this->connection.lock();

    if (!con) {
        if (this->type == K_SOCK_STREAM) {
            return -K_ENOTCONN;
        }
        kpanic_fmt("KUnixSocketObject::sendmsg not implemented for type: %d", this->type);
        return 0;
    }
    bool noSignal = (flags & K_MSG_NOSIGNAL) != 0;
    flags &= ~K_MSG_NOSIGNAL;
    if (flags) {
        kwarn_fmt("KUnixSocketObject::sendmsg unhandled flag=%x", flags);
    }
    BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(con->lockCond);
    if (this->outClosed) {
        return writePipeClosed(thread, noSignal);
    }
    readMsgHdr(thread, address, &hdr);

    std::shared_ptr<KSocketMsg> msg = std::make_shared<KSocketMsg>();

    if (hdr.msg_control) {
        CMsgHdr cmsg;			

        readCMsgHdr(thread, hdr.msg_control, &cmsg);
        if (cmsg.cmsg_level != K_SOL_SOCKET) {
            kpanic_fmt("KUnixSocketObject::sendmsg control level %d not implemented", cmsg.cmsg_level);
        } else if (cmsg.cmsg_type != K_SCM_RIGHTS) {
            kpanic_fmt("KUnixSocketObject::sendmsg control type %d not implemented", cmsg.cmsg_type);
        } else if ((cmsg.cmsg_len & 3) != 0) {
            kpanic_fmt("KUnixSocketObject::sendmsg control len %d not implemented", cmsg.cmsg_len);
        }

        for (U32 i=0;i<hdr.msg_controllen/16;i++) {
            KFileDescriptorPtr f = thread->process->getFileDescriptor(memory->readd(hdr.msg_control + 16 * i + 12));
            if (!f) {
                return -K_EBADF;
            } else {
                KSocketMsgObject d;
                d.object = f->kobject;
                d.accessFlags = f->accessFlags;
                // BW64_SOCKDTOR: witness the SENDER passing a fd via SCM_RIGHTS —
                // which pid sends which kobject. Pairs with the recvmsg install +
                // SOCKCLOSE pointer trace to see how a socket ends up shared across
                // processes (the dup-vs-share question).
                if (std::getenv("BW64_SOCKDTOR")) {
                    klog_fmt("SCMSEND: pid=%d tid=%d sends kobj=%p type=%d (use_count=%ld)",
                             (int)thread->process->id, (int)thread->id,
                             (void*)f->kobject.get(), (int)f->kobject->type,
                             f->kobject.use_count());
                }
                msg->objects.push_back(d);
            }
        }				
    }
    // The X11 wire server is a raw byte-stream endpoint, not a datagram/SCM
    // peer: winex11's libxcb writes core X requests through sendmsg(), but the
    // wire parser (XWireServerSocket::readNativeNonBlocking) reads from
    // recvBuffer and is driven by onPeerWrote() — exactly like write()/writev().
    // Routing these bytes into the length-prefixed msgs queue (which never
    // calls onPeerWrote) left the request bytes unparsed, so notepad blocked
    // forever after connecting. Feed XWire peers as a contiguous stream and
    // trigger the parser, the same wakeup path write() uses.
    bool isXWirePeer = std::dynamic_pointer_cast<XWireServerSocket>(con) != nullptr;
    if (isXWirePeer) {
        for (U32 i = 0; i < hdr.msg_iovlen; i++) {
            U32 p = memory->readd(hdr.msg_iov + 8 * i);
            U32 len = memory->readd(hdr.msg_iov + 8 * i + 4);
            while (len) {
                U8 byte = memory->readb(p++);
                con->recvBuffer.put(&byte, 1);
                len--;
                result++;
            }
        }
        BOXEDWINE_CONDITION_SIGNAL_ALL(con->lockCond);
        if (getenv("BW64_XWIRE")) {
            klog_fmt("KUnixSocket::sendmsg datalen=%d to XWire peer via recvBuffer", (int)result);
        }
        // onPeerWrote() runs the parser, which reacquires con->lockCond inside
        // readNativeNonBlocking. con->lockCond->m is a plain std::mutex, so we
        // must drop our lock first or self-deadlock. boxedWineCriticalSection is
        // the unique_lock created by BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION —
        // which only exists in the multi-threaded build; single-threaded has no
        // lock to drop (and no reentrancy to deadlock against), so skip it.
#ifdef BOXEDWINE_MULTI_THREADED
        boxedWineCriticalSection.unlock();
#endif
        con->onPeerWrote();
        return result;
    }
    for (U32 i=0;i<hdr.msg_iovlen;i++) {
        U32 p = memory->readd(hdr.msg_iov + 8 * i);
        U32 len = memory->readd(hdr.msg_iov + 8 * i + 4);

        msg->data.push_back((U8)len);
        msg->data.push_back((U8)(len >> 8));
        msg->data.push_back((U8)(len >> 16));
        msg->data.push_back((U8)(len >> 24));
        while (len) {
            msg->data.push_back(memory->readb(p++));
            len--;
            result++;
        }
    }
    con->msgs.push(msg);
    BOXEDWINE_CONDITION_SIGNAL_ALL(con->lockCond);

    if (getenv("BW64_XWIRE")) {
        klog_fmt("KUnixSocket::sendmsg datalen=%d to peer (isXWire=%d) via msgs queue",
                 (int)result, (int)(std::dynamic_pointer_cast<XWireServerSocket>(con) != nullptr));
    }
    return result;
}

U32 KUnixSocketObject::recvmsg(KThread* thread, const KFileDescriptorPtr& fd, U32 address, U32 flags) {
    MsgHdr hdr = {};
    U32 result = 0;
    KMemory* memory = thread->memory;

    // SOCK_DGRAM: pull one atomic datagram from our msgs queue. Unlike the stream
    // path, the payload is unframed; we also fill msg_name with the sender's
    // address (for replies) and synthesize SCM_CREDENTIALS when SO_PASSCRED is on
    // (darlingserver identifies the sender process by the pid in those creds).
    if (this->type == K_SOCK_DGRAM) {
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
        if (getenv("BW64_DGRAM")) {
            klog_fmt("DGRAM recvmsg pid=%d this=%p boundPath='%s' msgs=%d blocking=%d flags=0x%x",
                     (int)thread->process->id, (void*)this, this->boundPath.c_str(),
                     (int)this->msgs.size(), (int)this->blocking, flags);
        }
        while (!this->msgs.size()) {
            if (this->inClosed) {
                return 0;
            }
            if (!this->blocking) {
                return -K_EWOULDBLOCK;
            }
            BOXEDWINE_CONDITION_WAIT(this->lockCond);
#ifdef BOXEDWINE_MULTI_THREADED
            if (thread->terminating) {
                return -K_EINTR;
            }
            if (thread->startSignal) {
                thread->startSignal = false;
                return -K_CONTINUE;
            }
#endif
        }
        bool peek = (flags & K_MSG_PEEK) != 0;
        readMsgHdr(thread, address, &hdr);
        std::shared_ptr<KSocketMsg> msg = this->msgs.front();
        if (!peek) {
            this->msgs.pop();
        }

        // Sender address -> msg_name (sockaddr_un: family + NUL-terminated path).
        if (hdr.msg_name && hdr.msg_namelen >= 2) {
            memory->writew(hdr.msg_name, K_AF_UNIX);
            U32 cap = hdr.msg_namelen > 2 ? hdr.msg_namelen - 2 : 0;
            const char* sp = msg->senderPath.c_str();
            U32 slen = (U32)msg->senderPath.length();
            if (slen + 1 < cap) cap = slen + 1;
            for (U32 i = 0; i < cap; i++) {
                memory->writeb(hdr.msg_name + 2 + i, (i < slen) ? (U8)sp[i] : 0);
            }
            memory->writed(address + 4, 2 + slen + 1); // msg_namelen actual
        } else if (hdr.msg_name) {
            memory->writed(address + 4, 0);
        }

        // Control: SCM_CREDENTIALS (if requested via SO_PASSCRED) followed by
        // SCM_RIGHTS for any passed fds. Linux cmsg layout: each header is
        // {len(4), level(4), type(4)} then data, aligned to 8. ucred = {pid,uid,gid}.
        U32 controlWritten = 0;
        if (hdr.msg_control && hdr.msg_controllen) {
            U32 c = hdr.msg_control;
            U32 end = hdr.msg_control + hdr.msg_controllen;
            if (this->soPassCred && c + 12 + 12 <= end) {
                memory->writed(c + 0, 12 + 12);       // cmsg_len = hdr(12)+ucred(12)
                memory->writed(c + 4, K_SOL_SOCKET);
                memory->writed(c + 8, K_SCM_CREDENTIALS);
                memory->writed(c + 12, msg->senderPid);
                memory->writed(c + 16, msg->senderUid);
                memory->writed(c + 20, msg->senderGid);
                U32 adv = (12 + 12 + 7) & ~7u;        // align to 8
                c += adv;
                controlWritten += adv;
            }
            if (!msg->objects.empty() && c + 16 <= end) {
                U32 maxFds = (end - c >= 16) ? (end - c - 12) / 4 : 0;
                U32 nfds = (U32)msg->objects.size();
                if (nfds > maxFds) nfds = maxFds;
                memory->writed(c + 0, 12 + nfds * 4);
                memory->writed(c + 4, K_SOL_SOCKET);
                memory->writed(c + 8, K_SCM_RIGHTS);
                for (U32 i = 0; i < nfds; i++) {
                    KFileDescriptorPtr recvFd = thread->process->allocFileDescriptor(msg->objects[i].object, msg->objects[i].accessFlags, 0, -1, 0);
                    memory->writed(c + 12 + i * 4, recvFd->handle);
                }
                U32 adv = (12 + nfds * 4 + 7) & ~7u;
                c += adv;
                controlWritten += adv;
            }
        }
        if (hdr.msg_control || hdr.msg_controllen) {
            memory->writed(address + 20, controlWritten); // msg_controllen actual
        }

        // Payload into the iovecs (truncate to fit; set MSG_TRUNC if it overflows).
        U32 pos = 0;
        U32 total = (U32)msg->data.size();
        for (U32 i = 0; i < hdr.msg_iovlen && pos < total; i++) {
            U32 p = memory->readd(hdr.msg_iov + 8 * i);
            U32 len = memory->readd(hdr.msg_iov + 8 * i + 4);
            U32 count = std::min(len, total - pos);
            memory->memcpy(p, msg->data.data() + pos, count);
            pos += count;
            result += count;
        }
        // msg_flags: report MSG_TRUNC if the datagram didn't fit.
        if (hdr.msg_name || hdr.msg_iovlen) {
            memory->writed(address + 24, (pos < total) ? K_MSG_TRUNC : 0);
        }
        return result;
    }

    BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
    while (!this->msgs.size()) {
        if (this->recvBuffer.size_used()) {
            readMsgHdr(thread, address, &hdr);        
            for (U32 i = 0; i < hdr.msg_iovlen; i++) {
                U32 p = memory->readd(hdr.msg_iov + 8 * i);
                U32 len = memory->readd(hdr.msg_iov + 8 * i + 4);

                U32 count = std::min(len, (U32)this->recvBuffer.size_used());
                memory->performOnMemory(p, count, false, [this](U8* ram, U32 len) {
                    this->recvBuffer.get(ram, len);
                    return true;
                    });
                result += count;
            }
            if (this->type==K_SOCK_STREAM)
                memory->writed(address + 4, 0); // msg_namelen, set to 0 for connected sockets
            memory->writed(address + 20, 0); // msg_controllen
            return result;
        }
        if (this->inClosed) {
            return 0;
        }
        if (!this->blocking) {
            return -K_EWOULDBLOCK;
        }
        // :TODO: what about a time out
        BOXEDWINE_CONDITION_WAIT(this->lockCond);
#ifdef BOXEDWINE_MULTI_THREADED
		if (thread->terminating) {
			return -K_EINTR;
		}
        if (thread->startSignal) {
            thread->startSignal = false;
            return -K_CONTINUE;
        }
#endif
    }

    readMsgHdr(thread, address, &hdr);
    std::shared_ptr<KSocketMsg> msg = this->msgs.front();
    this->msgs.pop();

    if (hdr.msg_control) {
        U32 i=0;

        for (;i<hdr.msg_controllen/16 && i<msg->objects.size();i++) {
            KFileDescriptorPtr recvFd = thread->process->allocFileDescriptor(msg->objects[i].object, msg->objects[i].accessFlags, 0, -1, 0);
            // BW64_SOCKDTOR: witness the RECEIVER installing a passed fd. The
            // object is SHARED (same shared_ptr) with the sender's fd — this is
            // the share-vs-dup site. Log the kobj + the receiver's new fd + the
            // post-install use_count (how many fd tables now reference it).
            if (std::getenv("BW64_SOCKDTOR")) {
                klog_fmt("SCMRECV: pid=%d tid=%d installs kobj=%p as fd=%d type=%d (use_count=%ld)",
                         (int)thread->process->id, (int)thread->id,
                         (void*)msg->objects[i].object.get(), (int)recvFd->handle,
                         (int)msg->objects[i].object->type,
                         msg->objects[i].object.use_count());
            }
            writeCMsgHdr(thread, hdr.msg_control + i * 16, 16, K_SOL_SOCKET, K_SCM_RIGHTS);
            memory->writed(hdr.msg_control + i * 16 + 12, recvFd->handle);
        }
		memory->writed(address + 20, i * 16); // msg_controllen
    }
    U32 pos = 0;
    for (U32 i=0;i<hdr.msg_iovlen;i++) {
        U32 p = memory->readd(hdr.msg_iov + 8 * i);
        U32 len = memory->readd(hdr.msg_iov + 8 * i + 4);
        U32 dataLen = msg->data[pos] | (((U32)msg->data[pos + 1]) << 8) | (((U32)msg->data[pos + 2]) << 16) | (((U32)msg->data[pos + 3]) << 24);
        pos+=4;
        if (len<dataLen) {
            kpanic("unhandled socket msg logic");
        }
        memory->memcpy(p, msg->data.data() + pos, dataLen);
        pos+=dataLen;
        result+=dataLen;
    }  
    if (!this->connection.expired()) {
        BOXEDWINE_CONDITION_SIGNAL_ALL(this->lockCond);
    }
    return result;
}

U32 KUnixSocketObject::sendto(KThread* thread, const KFileDescriptorPtr& fd, U32 message, U32 length, U32 flags, U32 dest_addr, U32 dest_len) {
    if (this->type == K_SOCK_DGRAM) {
        KMemory* memory = thread->memory;
        if (!memory->canRead(message, length)) {
            return -K_EFAULT;
        }
        std::shared_ptr<KSocketMsg> msg = std::make_shared<KSocketMsg>();
        msg->data.resize(length);
        for (U32 i = 0; i < length; i++) {
            msg->data[i] = memory->readb(message + i);
        }
        return this->dgramSend(thread, dest_addr, dest_len, msg, false);
    }
    // Stream sendto ignores the address; fall back to a plain write.
    return this->write(thread, message, length);
}

U32 KUnixSocketObject::recvfrom(KThread* thread, const KFileDescriptorPtr& fd, U32 buffer, U32 length, U32 flags, U32 address, U32 address_len) {
    if (this->type == K_SOCK_DGRAM) {
        KMemory* memory = thread->memory;
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->lockCond);
        while (!this->msgs.size()) {
            if (this->inClosed) {
                return 0;
            }
            if (!this->blocking) {
                return -K_EWOULDBLOCK;
            }
            BOXEDWINE_CONDITION_WAIT(this->lockCond);
#ifdef BOXEDWINE_MULTI_THREADED
            if (thread->terminating) {
                return -K_EINTR;
            }
            if (thread->startSignal) {
                thread->startSignal = false;
                return -K_CONTINUE;
            }
#endif
        }
        bool peek = (flags & K_MSG_PEEK) != 0;
        std::shared_ptr<KSocketMsg> msg = this->msgs.front();
        if (!peek) {
            this->msgs.pop();
        }
        U32 count = std::min(length, (U32)msg->data.size());
        if (count) {
            memory->memcpy(buffer, msg->data.data(), count);
        }
        // Fill the sender address if the caller wants it.
        if (address && address_len) {
            U32 cap = memory->readd(address_len);
            if (cap >= 2) {
                memory->writew(address, K_AF_UNIX);
                const char* sp = msg->senderPath.c_str();
                U32 slen = (U32)msg->senderPath.length();
                U32 room = cap - 2;
                if (slen + 1 < room) room = slen + 1;
                for (U32 i = 0; i < room; i++) {
                    memory->writeb(address + 2 + i, (i < slen) ? (U8)sp[i] : 0);
                }
            }
            memory->writed(address_len, 2 + (U32)msg->senderPath.length() + 1);
        }
        return count;
    }
    if (address == 0) {
        return read(thread, buffer, length, flags);
    }
    return read(thread, buffer, length, flags);
}
