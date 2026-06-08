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

KEPoll::KEPoll() : KObject(KTYPE_EPOLL),
    changeCond(std::make_shared<BoxedWineCondition>(B("KEPoll::changeCond"))) {
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
    // An epoll fd is always "open" (it has no peer to hang up on). Reporting it
    // open lets it participate in another poll/select set (poll-on-epoll) without
    // being treated as a hung-up fd.
    return true;
}

// Poll-on-epoll. Darwin's libkqueue implements kqueue() as a Linux epoll fd and
// then BLOCKS waiting for kevents via select()/poll() on that epoll fd — e.g.
// launchd's kqueue_demand_loop does select(mainkq+1, &rfds, ...) where mainkq is
// the epoll fd. So an epoll fd must answer isReadReady()/waitForEvents() by
// delegating to the fds it is monitoring: it is "readable" (a kevent is pending)
// exactly when one of its armed registrations currently has a requested event
// ready on the underlying object, and a waiter on the epoll fd must be woken
// whenever any of those underlying objects becomes ready.

void KEPoll::waitForEvents(BOXEDWINE_CONDITION& parentCondition, U32 events) {
    KThread* thread = KThread::currentThread();
    if (!thread || !thread->process) {
        return;
    }
    // events==0 is the unregister pass: detach parentCondition from every
    // underlying fd's condition (mirror of how internal_poll tears down its
    // parent links). We can't selectively remove per-fd here without tracking
    // which we added, so we attempt removal on each armed registration's object
    // (REMOVE_PARENT is a no-op when the link isn't present).

    // Also (un)link the membership-change condition. A poll-on-epoll waiter takes
    // its parent links over the fd-set as it exists right now; if another thread
    // later epoll_ctl(ADD)s a new fd and that fd becomes ready, the waiter would
    // never wake because it was never linked to it. changeCond is signalled by
    // ctl() on every ADD/MOD/DEL, so the waiter wakes, re-evaluates isReadReady,
    // and re-links over the new set on its next waitForEvents pass. (launchd's
    // kqueue_demand_loop blocks in select() on its epoll fd before libkqueue adds
    // the proc-exit kqchan socket — without this the NOTE_EXIT never wakes it.)
    if (events) {
        BOXEDWINE_CONDITION_ADD_PARENT(this->changeCond, parentCondition);
    } else {
        BOXEDWINE_CONDITION_REMOVE_PARENT(this->changeCond, parentCondition);
    }

    for (const auto& n : this->data) {
        Data* reg = n.value;
        if (!reg->armed) {
            continue;
        }
        KFileDescriptor* pFD = thread->process->getFileDescriptor_nolock(reg->fd);
        if (!pFD || !pFD->kobject) {
            continue;
        }
        // Ask the underlying object to (un)register the parent condition for the
        // events this registration cares about. The epoll fd is readable when any
        // monitored event fires, so wake the poll-on-epoll waiter on POLLIN-side
        // readiness of the registration's requested events.
        pFD->kobject->waitForEvents(parentCondition, events ? reg->events : 0);
    }
}

bool KEPoll::isReadReady() {
    // Readable == at least one kevent is pending == some armed registration has a
    // requested event ready on its underlying object right now.
    KThread* thread = KThread::currentThread();
    if (!thread || !thread->process) {
        return false;
    }
    for (const auto& n : this->data) {
        Data* reg = n.value;
        if (!reg->armed) {
            continue;
        }
        KFileDescriptor* pFD = thread->process->getFileDescriptor_nolock(reg->fd);
        if (!pFD || !pFD->kobject) {
            continue;
        }
        KObject* k = pFD->kobject.get();
        if ((reg->events & K_POLLIN) && k->isReadReady()) {
            return true;
        }
        if ((reg->events & K_POLLOUT) && k->isWriteReady()) {
            return true;
        }
        if ((reg->events & K_POLLPRI) && k->isPriorityReadReady()) {
            return true;
        }
        // A hung-up monitored fd is also an epoll event (EPOLLHUP/EPOLLERR are
        // implicit) — surface it as readable so the poll-on-epoll waiter wakes
        // and the application drains it via epoll_wait/kevent.
        if (!k->isOpen()) {
            return true;
        }
    }
    return false;
}

// Per-arrival readiness counter for a poll-on-epoll (or nested-epoll) waiter. The
// outer EPOLLET registration only re-fires POLLIN on a rising readReadySeq edge
// (kpoll.cpp internal_poll / kepoll.cpp wait). For a plain socket that seq is the
// per-datagram/chunk counter; for an epoll fd "a fresh edge" means EITHER a member
// produced fresh data (its own readReadySeq advanced) OR the membership changed (a
// new fd added/armed, e.g. launchd's accepted job-submit socket joining the inner
// kqueue epoll). Fold both: sum the armed members' readReadySeq plus changeSeq.
// Monotonic enough — members' seqs only grow and changeSeq only grows — so the
// outer ET waiter sees an edge exactly when something it cares about changed. A
// non-zero return also flips hasReadSeq true so the rescue path engages at all.
U64 KEPoll::readReadySeq() {
    KThread* thread = KThread::currentThread();
    if (!thread || !thread->process) {
        return this->changeSeq;
    }
    U64 seq = this->changeSeq;
    for (const auto& n : this->data) {
        Data* reg = n.value;
        if (!reg->armed) {
            continue;
        }
        KFileDescriptor* pFD = thread->process->getFileDescriptor_nolock(reg->fd);
        if (!pFD || !pFD->kobject) {
            continue;
        }
        seq += pFD->kobject->readReadySeq();
    }
    // Never return 0 when we have any change history, so hasReadSeq latches true
    // and the ET re-fire rescue can run (seq==0 is the "no per-arrival counter"
    // sentinel in kpoll.cpp). +1 keeps it strictly positive once anything happened.
    return seq ? seq + 1 : 0;
}

bool KEPoll::isWriteReady() {
    // You cannot write to an epoll fd; it is never selectable for write.
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
    // The monitored fd-set changed — wake any thread blocked in a poll-on-epoll
    // select/poll on this epoll fd so it re-links over the new set (see
    // waitForEvents). Without this a fd added after a waiter blocked is invisible
    // to that waiter forever.
    {
        BOXEDWINE_CRITICAL_SECTION_WITH_CONDITION(this->changeCond);
        // Advance the membership-change seq so a nested-epoll EPOLLET registration
        // in an outer epoll sees a rising readReadySeq edge (see readReadySeq).
        this->changeSeq++;
        BOXEDWINE_CONDITION_SIGNAL_ALL(this->changeCond);
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
        bool edge = (next->events & K_EPOLLET) != 0;
        pollData.suppress = edge ? next->lastReported : 0;
        // For ET fds let internal_poll age lastReported in place every cycle (it
        // points straight at the registration's mask). next lives in this->data
        // for the whole call, so the pointer stays valid across the poll/block.
        pollData.suppressWriteback = edge ? &next->lastReported : nullptr;
        // Seed the per-arrival edge baseline so internal_poll can tell whether a
        // new datagram/chunk arrived since our last POLLIN delivery (ET only).
        pollData.lastReadSeq = edge ? next->lastReadSeq : 0;
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

            // ET POLLIN also re-fires when a NEW arrival bumped the fd's readReadySeq
            // past the value we last delivered POLLIN at, even if POLLIN never fell to
            // 0 (a datagram queue that never fully drains between arrivals). Without
            // this, the level-edge mask latches POLLIN after the first delivery and
            // never reports the fd again -> piled-up datagrams go unserviced (the
            // darlingserver shared dserver socket, multiple guest threads).
            if (edge && (data.revents & K_POLLIN) && data.hasReadSeq &&
                data.readSeq != owner->lastReadSeq) {
                toReport |= K_POLLIN;
            }

            // Track delivered bits for ET so a falling-then-rising edge re-fires;
            // bits no longer asserted are dropped from lastReported. Advance the
            // per-arrival baseline only when we actually deliver POLLIN, so a fresh
            // arrival that we could not deliver this cycle (e.g. maxevents starvation)
            // is still reported next time.
            if (edge) {
                owner->lastReported = data.revents;
                if ((toReport & K_POLLIN) && data.hasReadSeq) {
                    owner->lastReadSeq = data.readSeq;
                }
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
