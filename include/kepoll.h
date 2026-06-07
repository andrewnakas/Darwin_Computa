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
};

#endif