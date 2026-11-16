//! Locks for processes that share memory (rfork with RFMEM): the spin
//! lock, the queueing lock, the readers' and writers' lock and the
//! rendezvous point; and the atomic operations.
//! from libc/port/lock.c, libc/9sys/qlock.c, and libc/amd64/tas.s,
//! atom.s, atomic.s, atomic64.s
//!
//! A process that waits for a QLock, an RWLock or a Rendez sleeps in
//! the kernel's rendezvous, with the address of its place in the queue
//! (a QLp) as the tag; the one that lets it go meets it there.  So the
//! processes must share their rendezvous group: none of them may have
//! been made with RFREND (libc.fork is; proc.spawn is not).
//!
//! DIFF:
//!   - The words that several processes read and write outside a lock
//!     (a Lock's val, a QLp's inuse, the place in the pool of QLps) are
//!     read and written with the atomic builtins; the C has plain
//!     assignments, which on amd64 are the same instructions.
//!   - abort prints what was wrong and exits "abort"; the C's abort
//!     faults.
//!   - The atomic operations are Zig's builtins under the C's names;
//!     the compare-and-swaps return a bool.  cas, casp, fas and the
//!     other names of atom.s are not here: acasl and the rest do the
//!     same.

const std = @import("std");
const sys = @import("sys.zig");

// from libc/port/lock.c

pub const Lock = extern struct {
    val: u32 = 0,
};

/// from libc/amd64/tas.s
fn tas(p: *u32) u32 {
    return @atomicRmw(u32, p, .Xchg, 0xdeaddead, .seq_cst);
}

pub fn lock(lk: *Lock) void {
    // once fast
    if (tas(&lk.val) == 0)
        return;
    // a thousand times pretty fast
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        if (tas(&lk.val) == 0)
            return;
        _ = sys.sleep(0);
    }
    // now nice and slow
    i = 0;
    while (i < 1000) : (i += 1) {
        if (tas(&lk.val) == 0)
            return;
        _ = sys.sleep(100);
    }
    // take your time
    while (tas(&lk.val) != 0)
        _ = sys.sleep(1000);
}

pub fn canlock(lk: *Lock) bool {
    return tas(&lk.val) == 0;
}

pub fn unlock(lk: *Lock) void {
    @atomicStore(u32, &lk.val, 0, .seq_cst);
}

// from libc/9sys/qlock.c

pub const QLp = extern struct {
    inuse: u32 = 0,
    state: State = .Queuing,
    next: ?*QLp = null,
};

const State = enum(u32) {
    Queuing,
    QueuingR,
    QueuingW,
    Sleeping,
};

pub const QLock = extern struct {
    lock: Lock = .{},
    locked: bool = false,
    head: ?*QLp = null,
    tail: ?*QLp = null,
};

pub const RWLock = extern struct {
    lock: Lock = .{},
    readers: i32 = 0, // number of readers
    writer: i32 = 0, // number of writers
    head: ?*QLp = null, // list of waiting processes
    tail: ?*QLp = null,
};

pub const Rendez = extern struct {
    l: ?*QLock = null,
    head: ?*QLp = null,
    tail: ?*QLp = null,
};

var qlx: [1024]QLp = @splat(.{});
var qlp: *QLp = &qlx[0];

pub const Rendezvousfn = *const fn (tag: usize, val: usize) usize;

var rendezvousp: Rendezvousfn = sys.rendezvous;

/// this gets called by the thread library ONLY to get us to use its rendezvous
pub fn qlockinit(r: Rendezvousfn) void {
    rendezvousp = r;
}

fn abort(comptime what: []const u8) noreturn {
    _ = sys.write(2, "abort: " ++ what ++ "\n");
    sys.exits("abort");
}

const Interrupted = ~@as(usize, 0);

/// Meet the process that waits at (or lets go of) p.
fn meet(p: *QLp, val: usize) void {
    while (rendezvousp(@intFromPtr(p), val) == Interrupted) {}
}

/// find a free shared memory location to queue ourselves in
fn getqlp() *QLp {
    const op = @atomicLoad(*QLp, &qlp, .seq_cst);
    const endp: [*]QLp = @as([*]QLp, &qlx) + qlx.len;
    var p: [*]QLp = @as([*]QLp, @ptrCast(op)) + 1;
    while (true) : (p += 1) {
        if (p == endp)
            p = &qlx;
        if (@as(*QLp, @ptrCast(p)) == op)
            abort("no free place to queue in");
        if (tas(&p[0].inuse) == 0) {
            @atomicStore(*QLp, &qlp, &p[0], .seq_cst);
            break;
        }
    }
    p[0].next = null;
    return &p[0];
}

fn putqlp(p: *QLp) void {
    @atomicStore(u32, &p.inuse, 0, .seq_cst);
}

pub fn qlock(q: *QLock) void {
    lock(&q.lock);
    if (!q.locked) {
        q.locked = true;
        unlock(&q.lock);
        return;
    }

    // chain into waiting list
    const mp = getqlp();
    if (q.tail) |p|
        p.next = mp
    else
        q.head = mp;
    q.tail = mp;
    mp.state = .Queuing;
    unlock(&q.lock);

    // wait
    meet(mp, 1);
    putqlp(mp);
}

pub fn qunlock(q: *QLock) void {
    lock(&q.lock);
    if (!q.locked)
        abort("qunlock of a lock not held");
    if (q.head) |p| {
        // wakeup head waiting process
        q.head = p.next;
        if (q.head == null)
            q.tail = null;
        unlock(&q.lock);
        meet(p, 0x12345);
        return;
    }
    q.locked = false;
    unlock(&q.lock);
}

pub fn canqlock(q: *QLock) bool {
    if (!canlock(&q.lock))
        return false;
    if (!q.locked) {
        q.locked = true;
        unlock(&q.lock);
        return true;
    }
    unlock(&q.lock);
    return false;
}

pub fn rlock(q: *RWLock) void {
    lock(&q.lock);
    if (q.writer == 0 and q.head == null) {
        // no writer, go for it
        q.readers += 1;
        unlock(&q.lock);
        return;
    }

    const mp = getqlp();
    if (q.tail) |p|
        p.next = mp
    else
        q.head = mp;
    q.tail = mp;
    mp.state = .QueuingR;
    unlock(&q.lock);

    // wait in kernel
    meet(mp, 1);
    putqlp(mp);
}

pub fn canrlock(q: *RWLock) bool {
    lock(&q.lock);
    if (q.writer == 0 and q.head == null) {
        // no writer; go for it
        q.readers += 1;
        unlock(&q.lock);
        return true;
    }
    unlock(&q.lock);
    return false;
}

pub fn runlock(q: *RWLock) void {
    lock(&q.lock);
    if (q.readers <= 0)
        abort("runlock of a lock not held");
    q.readers -= 1;
    const p = q.head;
    if (q.readers > 0 or p == null) {
        unlock(&q.lock);
        return;
    }

    // start waiting writer
    if (p.?.state != .QueuingW)
        abort("runlock: a reader waits behind readers");
    q.head = p.?.next;
    if (q.head == null)
        q.tail = null;
    q.writer = 1;
    unlock(&q.lock);

    // wakeup waiter
    meet(p.?, 0);
}

pub fn wlock(q: *RWLock) void {
    lock(&q.lock);
    if (q.readers == 0 and q.writer == 0) {
        // noone waiting, go for it
        q.writer = 1;
        unlock(&q.lock);
        return;
    }

    // wait
    const mp = getqlp();
    if (q.tail) |p|
        p.next = mp
    else
        q.head = mp;
    q.tail = mp;
    mp.state = .QueuingW;
    unlock(&q.lock);

    // wait in kernel
    meet(mp, 1);
    putqlp(mp);
}

pub fn canwlock(q: *RWLock) bool {
    lock(&q.lock);
    if (q.readers == 0 and q.writer == 0) {
        // no one waiting; go for it
        q.writer = 1;
        unlock(&q.lock);
        return true;
    }
    unlock(&q.lock);
    return false;
}

pub fn wunlock(q: *RWLock) void {
    lock(&q.lock);
    if (q.writer == 0)
        abort("wunlock of a lock not held");
    var p = q.head orelse {
        q.writer = 0;
        unlock(&q.lock);
        return;
    };
    if (p.state == .QueuingW) {
        // start waiting writer
        q.head = p.next;
        if (q.head == null)
            q.tail = null;
        unlock(&q.lock);
        meet(p, 0);
        return;
    }
    if (p.state != .QueuingR)
        abort("wunlock: a sleeper in the lock's queue");

    // collect waiting readers
    q.readers = 1;
    var x = p.next;
    while (x != null and x.?.state == .QueuingR) : (x = x.?.next) {
        q.readers += 1;
        p = x.?;
    }
    p.next = null;
    var w = q.head;

    // queue remaining writers
    q.head = x;
    if (x == null)
        q.tail = null;
    q.writer = 0;
    unlock(&q.lock);

    // wakeup waiting readers
    while (w) |r| {
        w = r.next;
        meet(r, 0);
    }
}

/// Unlocks r.l, sleeps until a wakeup, and has r.l locked again when it
/// returns.  r.l must be set and held.
pub fn rsleep(r: *Rendez) void {
    const l = r.l orelse abort("rsleep: no lock");
    lock(&l.lock);
    // we should hold the qlock
    if (!l.locked)
        abort("rsleep: lock not held");

    // add ourselves to the wait list
    const me = getqlp();
    me.state = .Sleeping;
    if (r.head == null)
        r.head = me
    else
        r.tail.?.next = me;
    r.tail = me;

    // pass the qlock to the next guy
    if (l.head) |t| {
        l.head = t.next;
        if (l.head == null)
            l.tail = null;
        unlock(&l.lock);
        meet(t, 0x12345);
    } else {
        l.locked = false;
        unlock(&l.lock);
    }

    // wait for a wakeup
    meet(me, 1);
    putqlp(me);
}

/// Wake one sleeper, if there is one: it runs when the caller lets go
/// of r.l, before those that wait for the lock.  r.l must be held.
pub fn rwakeup(r: *Rendez) bool {
    // take off wait and put on front of queue
    // put on front so guys that have been waiting will not get starved
    const l = r.l orelse abort("rwakeup: no lock");
    lock(&l.lock);
    if (!l.locked)
        abort("rwakeup: lock not held");

    const t = r.head orelse {
        unlock(&l.lock);
        return false;
    };

    r.head = t.next;
    if (r.head == null)
        r.tail = null;

    t.next = l.head;
    l.head = t;
    if (l.tail == null)
        l.tail = t;

    t.state = .Queuing;
    unlock(&l.lock);
    return true;
}

/// Wake all the sleepers; returns how many.
pub fn rwakeupall(r: *Rendez) usize {
    var i: usize = 0;
    while (rwakeup(r))
        i += 1;
    return i;
}

// from libc/amd64/atom.s

/// Add one; returns the new value.
pub fn ainc(p: *i32) i32 {
    return @atomicRmw(i32, p, .Add, 1, .seq_cst) +% 1;
}

/// Take one off; returns the new value.
pub fn adec(p: *i32) i32 {
    return @atomicRmw(i32, p, .Sub, 1, .seq_cst) -% 1;
}

// from libc/amd64/atomic.s and atomic64.s

pub const Along = extern struct { v: i32 = 0 };
pub const Avlong = extern struct { v: i64 = 0 };
pub const Aptr = extern struct { v: ?*anyopaque = null };

pub fn agetl(p: *Along) i32 {
    return @atomicLoad(i32, &p.v, .seq_cst);
}

pub fn agetv(p: *Avlong) i64 {
    return @atomicLoad(i64, &p.v, .seq_cst);
}

pub fn agetp(p: *Aptr) ?*anyopaque {
    return @atomicLoad(?*anyopaque, &p.v, .seq_cst);
}

/// Set; returns the old value.
pub fn aswapl(p: *Along, v: i32) i32 {
    return @atomicRmw(i32, &p.v, .Xchg, v, .seq_cst);
}

pub fn aswapv(p: *Avlong, v: i64) i64 {
    return @atomicRmw(i64, &p.v, .Xchg, v, .seq_cst);
}

pub fn aswapp(p: *Aptr, v: ?*anyopaque) ?*anyopaque {
    return @atomicRmw(?*anyopaque, &p.v, .Xchg, v, .seq_cst);
}

/// Add v; returns the new value.
pub fn aincl(p: *Along, v: i32) i32 {
    return @atomicRmw(i32, &p.v, .Add, v, .seq_cst) +% v;
}

pub fn aincv(p: *Avlong, v: i64) i64 {
    return @atomicRmw(i64, &p.v, .Add, v, .seq_cst) +% v;
}

/// If the value is c, set it to v; returns whether it did.
pub fn acasl(p: *Along, c: i32, v: i32) bool {
    return @cmpxchgStrong(i32, &p.v, c, v, .seq_cst, .seq_cst) == null;
}

pub fn acasv(p: *Avlong, c: i64, v: i64) bool {
    return @cmpxchgStrong(i64, &p.v, c, v, .seq_cst, .seq_cst) == null;
}

pub fn acasp(p: *Aptr, c: ?*anyopaque, v: ?*anyopaque) bool {
    return @cmpxchgStrong(?*anyopaque, &p.v, c, v, .seq_cst, .seq_cst) == null;
}

/// A barrier: what was written before it is seen by the other
/// processors after it.
pub fn coherence() void {
    asm volatile ("mfence");
}
