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

#ifndef __KEPOLL_H__
#define __KEPOLL_H__

class KEPoll : public KObject {
public:
    KEPoll();
    virtual ~KEPoll();
    virtual void close();

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
    U32  setLock(KFileLock* lock, bool wait) override;
    bool supportsLocks() override;
    bool isOpen() override;
    bool isReadReady() override;
    bool isWriteReady() override;
    U64 readReadySeq() override;
    void waitForEvents(BOXEDWINE_CONDITION& parentCondition, U32 events) override;
    U32  writeNative(U8* buffer, U32 len) override;
    U32  readNative(U8* buffer, U32 len) override;
    U32  stat(KProcess* process, U32 address, bool is64) override;
    U32  map(KThread* thread, U32 address, U32 len, S32 prot, S32 flags, U64 off) override;
    bool canMap() override;
    BString selfFd() override;

    U32 ctl(KMemory* memory, U32 op, FD fd, U32 address);
    U32 wait(KThread* thread, U32 events, U32 maxevents, U32 timeout);
private:
    class Data {
    public:
        U32 fd;
        U64 data;
        U32 events;
        // Edge-triggered (EPOLLET) bookkeeping: the set of ready bits we last
        // reported to the application for this fd. An ET event for a given bit is
        // only delivered on a rising edge (currently-ready bit that was NOT in
        // lastReported). EPOLLONESHOT disarms the registration (armed=false) after
        // any delivery until EPOLL_CTL_MOD re-arms it.
        U32 lastReported = 0;
        // The readReadySeq() value at which we last delivered an ET POLLIN. When the
        // fd's seq advances past this while POLLIN is still asserted, a new datagram
        // (or stream chunk) arrived since our last delivery -> a fresh ET edge, even
        // though the POLLIN level never dropped to 0. Pure level-edge tracking
        // (lastReported) misses this when the queue never fully drains between
        // arrivals — the darlingserver shared-dgram-socket multi-client wall.
        U64 lastReadSeq = 0;
        bool armed = true;
    };
    BHashTable<U32, Data*> data;

    // Signalled whenever the monitored fd-set changes (epoll_ctl ADD/MOD/DEL). A
    // poll-on-epoll waiter (select/poll blocked on this epoll fd) parent-links
    // this in waitForEvents so a membership change wakes it — otherwise an fd
    // added AFTER the waiter blocked could never wake it (its parent links were
    // taken over the fd-set as it was at block-entry). See kepoll.cpp.
    BOXEDWINE_CONDITION changeCond;

    // Monotonic membership-change counter, bumped on every epoll_ctl ADD/MOD/DEL.
    // Folded into readReadySeq() so that a NESTED epoll (this fd registered with
    // EPOLLET inside an OUTER epoll — exactly libkqueue's layout: launchd watches
    // its main kqueue epfd inside a demand-loop epfd) presents a rising readReadySeq
    // edge when a new member fd is added/armed. Without an advancing seq, KObject's
    // default readReadySeq()==0 leaves hasReadSeq false, so the outer EPOLLET
    // registration can never re-fire POLLIN once it has latched it (lastReported) —
    // a freshly-added-and-ready member (e.g. launchd's accepted job-submit socket)
    // becomes readable on the inner epoll but the outer ET waiter never sees the
    // edge. Same edge-membership family as the connect()/listen-fd readSeq bump (S23)
    // and the S18 changeCond wake. See KEPoll::readReadySeq.
    U64 changeSeq = 0;
};

#endif