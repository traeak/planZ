//! Channels and alt.
//! from libthread/channel.c
//!
//! This is the C's channel, of elements of a size given when it is
//! made and values passed by address; libthread.zig's Chan(T) is the
//! typed face of it.
//!
//! DIFF:
//!   - The buffer is a slice of its own, not the tail of the Channel.
//!   - An Alt's err, a string that is only ever "channel was closed",
//!     is the bool `closed`.
//!   - The word a waiting alt is met through (the C's Channel *c in
//!     alt, which also takes the value ~0) is a usize holding the
//!     channel's address.
//!   - alt takes a pointer to the first Alt, as the C does: the list
//!     ends at a CHANEND or CHANNOBLK entry.

const std = @import("std");
const libc = @import("libc");
const impl = @import("impl.zig");
const sched = @import("sched.zig");
const note = @import("note.zig");
const rendez = @import("rendez.zig");
const lib = @import("lib.zig");

const lock = impl.lock;
const unlock = impl.unlock;
const get = impl.get;
const set = impl.set;

/// Channel structure.  S is the size of the buffer.  For unbuffered channels
/// s is zero.  v is an array of s values.  If s is zero, v is unused.
/// f and n represent the state of the queue pointed to by v.
pub const Channel = struct {
    s: u32 = 0, // Size of the channel (may be zero)
    f: u32 = 0, // Extraction point (insertion pt: (f+n) % s)
    n: u32 = 0, // Number of values in the channel
    e: u32 = 0, // Element size
    freed: bool = false, // Set when channel is being deleted
    qentry: []?*Alt = &.{}, // Receivers/senders waiting (malloc)
    closed: u32 = 0, // channel is closed
    v: []u8 = &.{}, // Array of s values in the channel
};

/// Channel operations for alt:
pub const ChanOp = enum(u32) {
    CHANEND,
    CHANSND,
    CHANRCV,
    CHANNOP,
    CHANNOBLK,
};

pub const Alt = struct {
    c: ?*Channel = null, // channel
    v: ?*anyopaque = null, // pointer to value
    op: ChanOp = .CHANEND, // operation
    closed: bool = false, // did the op fail?
    // the next variables are used internally to alt
    // they need not be initialized
    tag: *usize = undefined, // pointer to rendez-vous tag
    entryno: i32 = 0, // entry number
};

/// Value to indicate the channel is closed
const Closed: usize = 0xc105ed;
const Intred = rendez.Intred; // interrupted

var chanlock: impl.Lock = .{}; // central channel access lock

fn _chanfree(c: *Channel) void {
    var inuse = false;
    if (c.closed == 1) // chanclose is ongoing
        inuse = true
    else {
        for (c.qentry) |q| { // alt ongoing
            if (q != null)
                inuse = true;
        }
    }
    if (inuse)
        c.freed = true
    else {
        libc.allocator.free(c.qentry);
        libc.allocator.free(c.v);
        libc.allocator.destroy(c);
    }
}

pub fn chanfree(c: *Channel) void {
    lock(&chanlock);
    _chanfree(c);
    unlock(&chanlock);
}

/// A channel of elemcnt buffered elements of elemsize bytes; null if
/// elemsize is 0.
pub fn chancreate(elemsize: usize, elemcnt: usize) ?*Channel {
    if (elemsize == 0)
        return null;
    const c = lib.create(Channel);
    c.v = lib.alloc(u8, elemsize * elemcnt);
    @memset(c.v, 0);
    c.e = @intCast(elemsize);
    c.s = @intCast(elemcnt);
    return c;
}

fn index(alts: [*]Alt, a: *Alt) i32 {
    return @intCast((@intFromPtr(a) - @intFromPtr(alts)) / @sizeOf(Alt));
}

fn isopenfor(c: *Channel, op: ChanOp) bool {
    return c.closed == 0 or (op == .CHANRCV and c.n > 0);
}

/// Do one of the operations of alts, waiting until one can be done
/// unless the list ends in CHANNOBLK.  Returns its index (of the
/// CHANNOBLK entry if nothing could be done), or -1 if the wait was
/// interrupted or every channel was already found closed.  An
/// operation that ended because its channel was closed has `closed`
/// set.
pub fn alt(alts: [*]Alt) i32 {
    // The point of going splhi here is that note handlers
    // might reasonably want to use channel operations,
    // but that will hang if the note comes while we hold the
    // chanlock.  Instead, we delay the note until we've dropped
    // the lock.
    const t = impl.getproc().thread.?;
    if (get(&t.moribund) or impl.exitsall() != null)
        sched.yield(); // won't return
    var s = note.procsplhi();
    lock(&chanlock);
    t.alt = alts;
    t.chan = .Chanalt;

    // test whether any channels can proceed
    var n: i32 = 0;
    var a: ?*Alt = null;

    var i: usize = 0;
    while (alts[i].op != .CHANEND and alts[i].op != .CHANNOBLK) : (i += 1) {
        const xa = &alts[i];
        xa.entryno = -1;
        if (xa.op == .CHANNOP)
            continue;

        const c = xa.c orelse {
            unlock(&chanlock);
            note.procsplx(s);
            t.chan = .Channone;
            return -1;
        };

        if (isopenfor(c, xa.op) and canexec(xa)) {
            n += 1;
            if (libc.nrand(n) == 0)
                a = xa;
        }
    }

    if (a == null) {
        // nothing can proceed
        if (alts[i].op == .CHANNOBLK) {
            unlock(&chanlock);
            note.procsplx(s);
            t.chan = .Channone;
            return @intCast(i);
        }

        // enqueue on all channels open for us.
        var c: usize = 0;
        var ca: ?*Alt = null;
        var waiting = false;
        var allreadycl = false;
        i = 0;
        while (alts[i].op != .CHANEND) : (i += 1) {
            const xa = &alts[i];
            if (xa.op == .CHANNOP)
                continue;
            if (isopenfor(xa.c.?, xa.op)) {
                waiting = true;
                enqueue(xa, &c);
            } else if (!xa.closed)
                ca = xa
            else
                allreadycl = true;
        }

        if (!waiting) {
            if (ca) |x| {
                // everything was closed, select last channel
                x.closed = true;
                unlock(&chanlock);
                note.procsplx(s);
                t.chan = .Channone;
                return index(alts, x);
            } else if (allreadycl) {
                // everything was already closed
                unlock(&chanlock);
                note.procsplx(s);
                t.chan = .Channone;
                return -1;
            }
        }
        // wait for successful rendezvous.
        // we can't just give up if the rendezvous
        // is interrupted -- someone else might come
        // along and try to rendezvous with us, so
        // we need to be here.
        // if the channel was closed, the op is done
        // and we flag an error for the entry.
        var r: usize = undefined;
        while (true) {
            unlock(&chanlock);
            note.procsplx(s);
            r = rendez.threadrendezvous(@intFromPtr(&c), 0);
            s = note.procsplhi();
            lock(&chanlock);

            if (r == Intred) { // interrupted
                if (get(&c) != 0) // someone will meet us; go back
                    continue;
                set(&c, ~@as(usize, 0)); // so no one tries to meet us
            }
            break;
        }

        // dequeue from channels, find selected one
        i = 0;
        while (alts[i].op != .CHANEND) : (i += 1) {
            const xa = &alts[i];
            if (xa.op == .CHANNOP)
                continue;
            if (@intFromPtr(xa.c) == get(&c)) {
                a = xa;
                xa.closed = false;
                if (r == Closed)
                    xa.closed = true;
            }
            dequeue(xa);
        }
        unlock(&chanlock);
        note.procsplx(s);
        if (a == null) { // we were interrupted
            std.debug.assert(c == ~@as(usize, 0));
            return -1;
        }
    } else _ = altexec(a.?, s); // unlocks chanlock, does splx
    sched.sched();
    t.chan = .Channone;
    return index(alts, a.?);
}

/// Close c: sends fail from now on, and receives once the buffer is
/// empty.  False if it was closed already.
pub fn chanclose(c: *Channel) bool {
    var s = note.procsplhi(); // note handlers; see alt
    lock(&chanlock);
    if (c.closed != 0) {
        // Already close; we fail but it's ok. don't print
        unlock(&chanlock);
        note.procsplx(s);
        return false;
    }
    c.closed = 1; // Being closed
    // Locate entries that will fail due to close
    // (send, and receive if nothing buffered) and wake them up.
    // the situation cannot change because all queries
    // should be committed by now and new ones will find the channel
    // closed.  We still need to take the lock during the iteration
    // because we can wake threads on qentrys we have not seen yet
    // as in alt and there would be a race in the access to *a.
    var i: usize = 0;
    while (i < c.qentry.len) : (i += 1) {
        const a = c.qentry[i] orelse continue;
        if (a.tag.* != 0)
            continue;

        if (a.op != .CHANSND and (a.op != .CHANRCV or c.n != 0))
            continue;
        a.tag.* = @intFromPtr(c);
        const tag = a.tag;
        unlock(&chanlock);
        note.procsplx(s);
        while (rendez.threadrendezvous(@intFromPtr(tag), Closed) == Intred) {}
        s = note.procsplhi();
        lock(&chanlock);
    }

    c.closed = 2; // Fully closed
    if (c.freed)
        _chanfree(c);
    unlock(&chanlock);
    note.procsplx(s);
    return true;
}

/// How many values are still to be received from a closed channel;
/// -1 if c is not closed.
pub fn chanclosing(c: *Channel) i32 {
    const s = note.procsplhi(); // note handlers; see alt
    lock(&chanlock);
    const n: i32 = if (c.closed == 0) -1 else @intCast(c.n);
    unlock(&chanlock);
    note.procsplx(s);
    return n;
}

fn runop(op: ChanOp, c: *Channel, v: ?*anyopaque, nb: bool) i32 {
    // we could do this without calling alt,
    // but the only reason would be performance,
    // and i'm not convinced it matters.
    var a: [2]Alt = .{
        .{ .op = op, .c = c, .v = v, .closed = false },
        .{ .op = if (nb) .CHANNOBLK else .CHANEND },
    };
    const r = alt(&a);
    switch (r) {
        -1 => return -1, // interrupted
        1 => { // nonblocking, didn't accomplish anything
            std.debug.assert(nb);
            return 0;
        },
        0 => {
            // Okay, but return -1 if the op is done because of a close.
            if (a[0].closed)
                return -1;
            return 1;
        },
        else => {
            libc.fprint(2, "ERROR: channel alt returned %d\n", .{r});
            libc.sys.exits("abort");
        },
    }
}

/// 1 if a value was received into v (which may be null), -1 if the
/// wait was interrupted or the channel is closed.
pub fn recv(c: *Channel, v: ?*anyopaque) i32 {
    return runop(.CHANRCV, c, v, false);
}

/// As recv, and 0 if there was nothing to receive.
pub fn nbrecv(c: *Channel, v: ?*anyopaque) i32 {
    return runop(.CHANRCV, c, v, true);
}

/// 1 if the value at v (zeros for null) was sent, -1 if the wait was
/// interrupted or the channel is closed.
pub fn send(c: *Channel, v: ?*const anyopaque) i32 {
    return runop(.CHANSND, c, @constCast(v), false);
}

/// As send, and 0 if it could not be sent at once.
pub fn nbsend(c: *Channel, v: ?*const anyopaque) i32 {
    return runop(.CHANSND, c, @constCast(v), true);
}

fn channelsize(c: *Channel, sz: usize) void {
    std.debug.assert(c.e == sz);
}

pub fn sendul(c: *Channel, v: u32) i32 {
    channelsize(c, @sizeOf(u32));
    return send(c, @ptrCast(&v));
}

pub fn recvul(c: *Channel) u32 {
    var v: u32 = undefined;
    channelsize(c, @sizeOf(u32));
    if (recv(c, @ptrCast(&v)) < 0)
        return ~@as(u32, 0);
    return v;
}

pub fn sendp(c: *Channel, v: ?*anyopaque) i32 {
    channelsize(c, @sizeOf(?*anyopaque));
    return send(c, @ptrCast(&v));
}

pub fn recvp(c: *Channel) ?*anyopaque {
    var v: ?*anyopaque = undefined;
    channelsize(c, @sizeOf(?*anyopaque));
    if (recv(c, @ptrCast(&v)) < 0)
        return null;
    return v;
}

pub fn nbsendul(c: *Channel, v: u32) i32 {
    channelsize(c, @sizeOf(u32));
    return nbsend(c, @ptrCast(&v));
}

pub fn nbrecvul(c: *Channel) u32 {
    var v: u32 = undefined;
    channelsize(c, @sizeOf(u32));
    if (nbrecv(c, @ptrCast(&v)) == 0)
        return 0;
    return v;
}

pub fn nbsendp(c: *Channel, v: ?*anyopaque) i32 {
    channelsize(c, @sizeOf(?*anyopaque));
    return nbsend(c, @ptrCast(&v));
}

pub fn nbrecvp(c: *Channel) ?*anyopaque {
    var v: ?*anyopaque = undefined;
    channelsize(c, @sizeOf(?*anyopaque));
    if (nbrecv(c, @ptrCast(&v)) == 0)
        return null;
    return v;
}

fn emptyentry(c: *Channel) usize {
    for (c.qentry, 0..) |q, i| {
        if (q == null)
            return i;
    }

    const extra = 16;
    const i = c.qentry.len;
    c.qentry = libc.allocator.realloc(c.qentry, i + extra) catch
        libc.sysfatal("realloc channel entries: %r", .{});
    @memset(c.qentry[i..], null);
    return i;
}

fn enqueue(a: *Alt, c: *usize) void {
    a.tag = c;
    const ch = a.c.?;
    const i = emptyentry(ch);
    ch.qentry[i] = a;
}

fn dequeue(a: *Alt) void {
    const c = a.c.?;
    for (c.qentry) |*q| {
        if (q.* == a) {
            q.* = null;
            // release if freed and not closing
            if (c.freed and c.closed != 1)
                _chanfree(c);
            return;
        }
    }
}

fn otherop(op: ChanOp) ChanOp {
    return if (op == .CHANSND) .CHANRCV else .CHANSND;
}

fn canexec(a: *Alt) bool {
    const c = a.c.?;
    // are there senders or receivers blocked?
    const other = otherop(a.op);
    for (c.qentry) |q| {
        if (q) |b| {
            if (b.op == other and b.tag.* == 0)
                return true;
        }
    }

    // is there room in the channel?
    if ((a.op == .CHANSND and c.n < c.s) or (a.op == .CHANRCV and c.n > 0))
        return true;

    return false;
}

fn altexecbuffered(a: *Alt, willreplace: bool) [*]u8 {
    const c = a.c.?;
    // use buffered channel queue
    if (a.op == .CHANRCV and c.n > 0) {
        const v = c.v.ptr + c.e * (c.f % c.s);
        if (!willreplace)
            c.n -= 1;
        c.f +%= 1;
        return v;
    }
    if (a.op == .CHANSND and c.n < c.s) {
        const v = c.v.ptr + c.e * ((c.f +% c.n) % c.s);
        if (!willreplace)
            c.n += 1;
        return v;
    }
    libc.sys.exits("abort");
}

fn altcopy(dst: ?*anyopaque, src: ?*const anyopaque, sz: usize) void {
    const d: [*]u8 = @ptrCast(dst orelse return);
    if (src) |sp|
        std.mem.copyForwards(u8, d[0..sz], @as([*]const u8, @ptrCast(sp))[0..sz])
    else
        @memset(d[0..sz], 0);
}

fn altexec(a: *Alt, spl: bool) bool {
    const c = a.c.?;

    // rendezvous with others
    const other = otherop(a.op);
    var n: i32 = 0;
    var b: ?*Alt = null;
    const me = a.v;
    for (c.qentry) |q| {
        if (q) |x| {
            if (x.op == other and x.tag.* == 0) {
                n += 1;
                if (libc.nrand(n) == 0)
                    b = x;
            }
        }
    }
    if (b) |w| {
        const waiter = w.v;
        if (c.s != 0 and c.n != 0) {
            // if buffer is full and there are waiters
            // and we're meeting a waiter,
            // we must be receiving.
            //
            // we use the value in the channel buffer,
            // copy the waiter's value into the channel buffer
            // on behalf of the waiter, and then wake the waiter.
            if (a.op != .CHANRCV)
                libc.sys.exits("abort");
            const buf = altexecbuffered(a, true);
            altcopy(me, buf, c.e);
            altcopy(buf, waiter, c.e);
        } else {
            if (a.op == .CHANRCV)
                altcopy(me, waiter, c.e)
            else
                altcopy(waiter, me, c.e);
        }
        const tag = w.tag;
        tag.* = @intFromPtr(c); // commits us to rendezvous
        unlock(&chanlock);
        note.procsplx(spl);
        while (rendez.threadrendezvous(@intFromPtr(tag), 0) == Intred) {}
        return true;
    }

    const buf = altexecbuffered(a, false);
    if (a.op == .CHANRCV)
        altcopy(me, buf, c.e)
    else
        altcopy(buf, me, c.e);

    unlock(&chanlock);
    note.procsplx(spl);
    return true;
}
