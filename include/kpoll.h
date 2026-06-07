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

#ifndef __KPOLL_H__
#define __KPOLL_H__

class KFileDescriptor;

class KPollData {
public:
    U32 address;
    FD fd;
    U32 events;
    U32 revents;
    U64 data;
    // Edge-triggered support (epoll EPOLLET): bits already delivered to the app
    // that must NOT, on their own, count as "ready" for the purpose of deciding
    // whether internal_poll returns vs. blocks. Defaults to 0 (level-triggered),
    // so poll()/select() are unaffected; only KEPoll::wait sets this. The raw
    // revents are still computed in full so the caller can detect rising edges.
    U32 suppress = 0;
    // EPOLLET edge bookkeeping (KEPoll only): points at the owning registration's
    // persistent lastReported mask. internal_poll ages it EVERY poll cycle —
    // including the cycle right before it blocks — clearing any delivered bit that
    // is no longer asserted, so the next rising edge is detected. Without this the
    // mask froze at last delivery and, after a same-level drain+refill (e.g. a
    // dgram queue going empty then a new datagram arriving), suppressed the fresh
    // POLLIN forever -> the parked epoll_wait never woke (the darlingserver wall).
    // nullptr for poll()/select(), so their level-triggered semantics are intact.
    U32* suppressWriteback = nullptr;
    // EPOLLET POLLIN re-arming by arrival count (KEPoll only). When the polled fd
    // exposes a readReadySeq() (unix sockets bump it per datagram/chunk), internal_poll
    // records the current value here. KEPoll::wait compares it against the seq it last
    // delivered POLLIN at (Data::lastReadSeq): if it advanced while POLLIN is still
    // asserted, that is a fresh edge even though the level never fell to 0 — the case
    // a pure level-edge mask misses when a queue never fully drains between arrivals.
    U64 readSeq = 0;
    bool hasReadSeq = false;
    // For ET fds, the seq we last delivered POLLIN at (copied from Data::lastReadSeq).
    // POLLIN counts as freshly ready when readSeq != lastReadSeq.
    U64 lastReadSeq = 0;
};

S32 internal_poll(KThread* thread, KPollData* data, U32 count, U32 timeout);

U32 kpoll(KThread* thread, U32 pfds, U32 nfds, U32 timeout);
U32 kselect(KThread* thread, U32 nfds, U32 readfds, U32 writefds, U32 errorfds, U32 timeout, bool timeoutIsTimeVal, U32 sigmask = 0, bool time64 = false);

#define K_POLLIN       0x001
#define K_POLLPRI      0x002
#define K_POLLOUT      0x004

#define K_POLLRDNORM   0x040
#define K_POLLRDBAND   0x080
#define K_POLLWRNORM   0x100
#define K_POLLWRBAND   0x200

#define K_POLLERR      0x0008
#define K_POLLHUP      0x0010
#define K_POLLNVAL     0x0020

#endif