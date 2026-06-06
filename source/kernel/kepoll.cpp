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

#include "kepoll.h"
#include "kscheduler.h"
#include "kunixsocket.h"

#include <string.h>

KEPoll::KEPoll() : KObject(KTYPE_EPOLL) {
}

KEPoll::~KEPoll() {
     for( const auto& n : this->data ) {
         delete n.value;
    }
}

void KEPoll::setBlocking(bool blocking) {
    if (blocking)
        kpanic("KEPoll::setBlocking not implemented yet");
}

bool KEPoll::isBlocking() {
    return false;
}

void KEPoll::setAsync(bool isAsync) {
    if (isAsync)
        kpanic("KEPoll::setAsync not implemented yet");
}

bool KEPoll::isAsync() {
    return false;
}

KFileLock* KEPoll::getLock(KFileLock* lock) {
    kdebug("KEPoll::getLock not implemented yet");
    return nullptr;
}

U32 KEPoll::setLock(KFileLock* lock, bool wait) {
    kdebug("KEPoll::setLock not implemented yet");
    return -1;
}

bool KEPoll::isOpen() {
    kdebug("KEPoll::isOpen not implemented yet");
    return false;
}

void KEPoll::waitForEvents(BOXEDWINE_CONDITION& parentCondition, U32 events) {
    kpanic("KEPoll::waitForEvents not implemented yet");
}

bool KEPoll::isReadReady() {
    kpanic("KEPoll::isReadReady not implemented yet");
    return false;
}

bool KEPoll::isWriteReady() {
    kpanic("KEPoll::isWriteReady not implemented yet");
    return false;
}

U32 KEPoll::writeNative(U8* buffer, U32 len) {
    kpanic("KEPoll::writeNative not implemented yet");
    return 0;
}

U32 KEPoll::readNative(U8* buffer, U32 len) {
    kpanic("KEPoll::readNative not implemented yet");
    return 0;
}

U32 KEPoll::stat(KProcess* process, U32 address, bool is64) {
    kpanic("KEPoll::stat not implemented yet");
    return 0;
}

U32 KEPoll::map(KThread* thread, U32 address, U32 len, S32 prot, S32 flags, U64 off) {
    return 0;
}

bool KEPoll::canMap() {
    return false;
}

BString KEPoll::selfFd() {
    return B("anon_inode:[eventpoll]");
}

S64 KEPoll::seek(S64 pos) {
    return -K_ESPIPE; // :TODO: is this right?
}

S64 KEPoll::getPos() {
    return 0;
}

U32 KEPoll::ioctl(KThread* thread, U32 request) {
    return -K_ENOTTY;
}

bool KEPoll::supportsLocks() {
    return false;
}

S64 KEPoll::length() {
    return -1;
}

void KEPoll::close() {
}


#define K_EPOLL_CTL_ADD 1
#define K_EPOLL_CTL_DEL 2
#define K_EPOLL_CTL_MOD 3

// epoll-only event flags (Linux values). EPOLLET requests edge-triggered
// delivery (report a bit only on a rising edge); EPOLLONESHOT disarms the
// registration after one delivery until re-armed via EPOLL_CTL_MOD.
#define K_EPOLLET       0x80000000
#define K_EPOLLONESHOT  0x40000000

U32 KEPoll::ctl(KMemory* memory, U32 op, FD fd, U32 address) {
    KFileDescriptorPtr targetFD = KThread::currentThread()->process->getFileDescriptor(fd);

    if (!targetFD) {
        return -K_EBADF;
    }

    Data* existing = this->data[fd];

    switch (op) {
        case K_EPOLL_CTL_ADD:
            if (existing) {
                return -K_EEXIST;
            }
            existing = new Data();
            existing->fd = fd;
            existing->events = memory->readd(address);
            existing->data = memory->readq(address + 4);
            existing->lastReported = 0;
            existing->armed = true;
            this->data.set(fd, existing);
            break;
        case K_EPOLL_CTL_DEL:
            if (!existing)
                return -K_ENOENT;
            this->data.remove(fd);
            delete existing;
            break;
        case K_EPOLL_CTL_MOD:
            if (!existing)
                return -K_ENOENT;
            existing->events = memory->readd(address);
            existing->data = memory->readq(address + 4);
            // MOD re-arms an EPOLLONESHOT registration and resets the edge state,
            // so a level that is still asserted is reported again after re-arm.
            existing->lastReported = 0;
            existing->armed = true;
            break;
        default:
            return -K_EINVAL;
    }
    return 0;
}

U32 KEPoll::wait(KThread* thread, U32 events, U32 maxevents, U32 timeout) {
    S32 result = 0;
    U32 pollCount=0;
    KMemory* memory = thread->memory;

    // Build the poll set from the armed registrations. A registration disarmed by
    // EPOLLONESHOT is skipped entirely until EPOLL_CTL_MOD re-arms it. For an
    // edge-triggered (EPOLLET) registration we suppress the bits we already
    // delivered (lastReported) so that a level that stays asserted (e.g. a dgram
    // socket that is always POLLOUT-ready) does not, by itself, force epoll_wait
    // to return — exactly the busy-spin darlingserver's EPOLLET listener hit.
    thread->pollData.clear();
    std::vector<Data*> owners;
    for( const auto& n : this->data ) {
        Data* next = n.value;
        if (!next->armed) {
            continue;
        }
        KPollData pollData;

        pollData.events = next->events;
        pollData.fd = next->fd;
        pollData.data = next->data;
        pollData.suppress = (next->events & K_EPOLLET) ? next->lastReported : 0;
        thread->pollData.push_back(pollData);
        owners.push_back(next);
        pollCount++;
    }
    result = internal_poll(thread, thread->pollData.data(), pollCount, timeout);
    if (result >= 0) {
        result = 0;
        for (size_t idx = 0; idx < thread->pollData.size(); idx++) {
            KPollData& data = thread->pollData[idx];
            Data* owner = owners[idx];
            bool edge = (owner->events & K_EPOLLET) != 0;

            // For edge-triggered fds report only the rising-edge bits (those not
            // already delivered); for level-triggered fds report the full revents.
            U32 toReport = edge ? (data.revents & ~owner->lastReported) : data.revents;

            // Track delivered bits for ET so a falling-then-rising edge re-fires;
            // bits no longer asserted are dropped from lastReported.
            if (edge) {
                owner->lastReported = data.revents;
            }

            if (toReport != 0) {
                if (getenv("BW64_EPDUMP")) {
                    KFileDescriptorPtr fd = thread->process->getFileDescriptor((FD)data.fd);
                    const char* kind = "?";
                    int inC = -1, outC = -1; long used = -1;
                    if (fd && fd->kobject) {
                        switch (fd->kobject->type) {
                            case KTYPE_FILE: kind = "file"; break;
                            case KTYPE_UNIX_SOCKET: {
                                kind = "unixsock";
                                std::shared_ptr<KUnixSocketObject> us = std::dynamic_pointer_cast<KUnixSocketObject>(fd->kobject);
                                if (us) { inC = us->inClosed; outC = us->outClosed; used = (long)us->debugRecvUsed(); }
                                break;
                            }
                            case KTYPE_NATIVE_SOCKET: kind = "natsock"; break;
                            case KTYPE_EVENT: kind = "event"; break;
                            case KTYPE_TIMER: kind = "timer"; break;
                            case KTYPE_SIGNAL: kind = "signal"; break;
                            default: kind = "other"; break;
                        }
                    }
                    klog_fmt("EPDUMP wait: fd=%d data=0x%llx revents=0x%x kind=%s inClosed=%d outClosed=%d recvUsed=%ld",
                             (int)data.fd, (unsigned long long)data.data,
                             (unsigned)toReport, kind, inC, outC, used);
                }
                memory->writed(events + result * 12, toReport);
                memory->writeq(events + result * 12 + 4, data.data);
                result++;
                // EPOLLONESHOT: disarm until the application re-arms with MOD.
                if (owner->events & K_EPOLLONESHOT) {
                    owner->armed = false;
                }
                if (result>=(S32)maxevents) {
                    kwarn("possible starvation in epoll, more events are ready than can be received.");
                    break;
                }
            }
        }
    }
    return result;
}
