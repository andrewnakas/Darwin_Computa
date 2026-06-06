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

#include "kpidfd.h"
#include "kprocess.h"
#include "ksystem.h"

KPidFd::KPidFd(U32 targetPid) : KObject(KTYPE_PIDFD), targetPid(targetPid) {
}

// Latch and return whether the target process is dead/gone. A dead process never
// comes back, so once latched we stay ready.
bool KPidFd::refreshDead() {
    if (targetDead) {
        return true;
    }
    KProcessPtr p = KSystem::getProcess(targetPid);
    if (!p || p->terminated) {
        targetDead = true;
    }
    return targetDead;
}

bool KPidFd::isReadReady() {
    return refreshDead();
}

bool KPidFd::isWriteReady() {
    // A pidfd is never writable.
    return false;
}

void KPidFd::waitForEvents(BOXEDWINE_CONDITION& parentCondition, U32 events) {
    // Wake the waiter when the target process exits. The process signals its
    // exitOrExecCond on exit (KProcess::exitThread / clearOtherThreadsAndCleanup),
    // so add that as a parent. If the process is already gone, there's no
    // condition to attach to — but isReadReady() already returns true so poll
    // will report it immediately without blocking.
    if (events & K_POLLIN) {
        KProcessPtr p = KSystem::getProcess(targetPid);
        if (p) {
            BOXEDWINE_CONDITION_ADD_PARENT(p->exitOrExecCond, parentCondition);
        }
    }
}

U32 KPidFd::readNative(U8* buffer, U32 len) {
    // pidfds are not byte-stream readable; reading returns EINVAL on Linux.
    return -K_EINVAL;
}

U32 KPidFd::writeNative(U8* buffer, U32 len) {
    return -K_EINVAL;
}

bool KPidFd::isOpen() {
    return true;
}

void KPidFd::setBlocking(bool b) {
    this->blocking = b;
}

bool KPidFd::isBlocking() {
    return this->blocking;
}

void KPidFd::setAsync(bool isAsync) {
}

bool KPidFd::isAsync() {
    return false;
}

KFileLock* KPidFd::getLock(KFileLock* lock) {
    return nullptr;
}

U32 KPidFd::setLock(KFileLock* lock, bool wait) {
    return -K_ENOLCK;
}

bool KPidFd::supportsLocks() {
    return false;
}

U32 KPidFd::stat(KProcess* process, U32 address, bool is64) {
    return -K_ENOSYS;
}

U32 KPidFd::map(KThread* thread, U32 address, U32 len, S32 prot, S32 flags, U64 off) {
    return -K_ENODEV;
}

bool KPidFd::canMap() {
    return false;
}

BString KPidFd::selfFd() {
    return B("anon_inode:[pidfd]");
}

S64 KPidFd::seek(S64 pos) {
    return -K_ESPIPE;
}

S64 KPidFd::getPos() {
    return 0;
}

S64 KPidFd::length() {
    return -1;
}

U32 KPidFd::ioctl(KThread* thread, U32 request) {
    return -K_ENOTTY;
}

U32 syscall_pidfd_open(KThread* thread, U32 pid, U32 flags) {
    // pidfd_open(pid, flags). flags 0 or PIDFD_NONBLOCK(0x800). The target must be
    // an existing process. darlingserver opens one per tracked macOS process to
    // learn of its death via epoll.
    KProcessPtr target = KSystem::getProcess(pid);
    if (!target) {
        return -K_ESRCH;
    }
    std::shared_ptr<KPidFd> o = std::make_shared<KPidFd>(pid);
    if (flags & 0x800) { // PIDFD_NONBLOCK
        o->setBlocking(false);
    }
    U32 fdFlags = K_O_CLOEXEC; // pidfds are close-on-exec by default
    KFileDescriptorPtr fd = thread->process->allocFileDescriptor(o, K_O_RDONLY, fdFlags, -1, 0);
    if (!fd) {
        return -K_EMFILE;
    }
    return fd->handle;
}
