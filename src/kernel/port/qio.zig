//! IO queues: lists of Blocks with flow control, read by one side and
//! written by the other, at process or interrupt level.
//! from 9/port/qio.c; the queue state bits from 9/port/portdat.h
//!
//! DIFF:
//!   - Errors are Zig error returns.  qbread, qread, qbwrite and qwrite
//!     return error.Eintr when a note interrupts their eqlock or sleep,
//!     and the queue's error when it is closed: error.Ehungup if that
//!     is what q.err says, otherwise q.err is copied to up.errstr and
//!     error.Str returned (see qerror).  The waserror sites became
//!     defer, or explicit cleanup before the return.
//!   - Buffers are slices: qread, qwrite, qiwrite, qproduce, qconsume
//!     and readblist take the buffer and its length as one argument.
//!   - Lengths the C asserts to be non-negative are usize, so the
//!     asserts are gone.  Functions that return -1 return i32.
//!     Queue.state is unsigned.
//!   - qread and qwrite copy to and from the caller's buffer without a
//!     waserror around the copy; how a fault on a user address unwinds
//!     is decided in M4 and those two sites are marked.
//!   - concatblock returns a non-optional pointer: pullupblock cannot
//!     run short when asked for exactly blocklen bytes.
//!   - A block with wp below rp (the "negative length packet" of
//!     pullupblock) is tested for by comparing the pointers.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const proc = @import("proc.zig");
const alloc = @import("alloc.zig");
const ab = @import("allocb.zig");
const errmod = @import("error.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const eqlock = ql.eqlock;
const qunlock = ql.qunlock;
const sleep = proc.sleep;
const wakeup = proc.wakeup;
const kstrcpy = proc.kstrcpy;

pub const Error = errmod.Error;
pub const Block = ab.Block;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Rendez = portdat.Rendez;
const ERRMAX = portdat.ERRMAX;

const BLEN = ab.BLEN;
const BALLOC = ab.BALLOC;
const allocb = ab.allocb;
const iallocb = ab.iallocb;
const iallocbp = ab.iallocbp;
const freeb = ab.freeb;
const checkb = ab.checkb;

const QDEBUG = false;

const Ehungup = errmod.errstr(error.Ehungup);

// queue state bits,  Qmsg, Qcoalesce, and Qkick can be set in qopen
pub const Qstarve: u32 = 1 << 0; // consumer starved
pub const Qmsg: u32 = 1 << 1; // message stream
pub const Qclosed: u32 = 1 << 2; // queue has been closed/hungup
pub const Qflow: u32 = 1 << 3; // producer flow controlled
pub const Qcoalesce: u32 = 1 << 4; // coallesce packets on read
pub const Qkick: u32 = 1 << 5; // always call the kick routine after qwrite

pub const Kick = *const fn (?*anyopaque) void;
pub const Bypass = *const fn (?*anyopaque, *Block) void;

/// IO queues
pub const Queue = struct {
    lock: Lock = .{},

    state: u32 = 0,
    dlen: i32 = 0, // data length in bytes
    rp: u32 = 0, // read/write position (counting BALLOC() bytes)
    wp: u32 = 0,
    limit: i32 = 0, // max BALLOC() bytes in queue
    inilim: i32 = 0, // initial limit
    noblock: bool = false, // true if writes return immediately when q full
    eof: u8 = 0, // number of eofs read by user

    bfirst: ?*Block = null, // buffer
    blast: ?*Block = null,

    arg: ?*anyopaque = null, // argument to kick and bypass
    kick: ?Kick = null, // restart output
    bypass: ?Bypass = null, // bypass queue altogether

    rlock: QLock = .{}, // mutex for reading processes
    rr: Rendez = .{}, // process waiting to read

    wlock: QLock = .{}, // mutex for writing processes
    wr: Rendez = .{}, // process waiting to write

    err: [ERRMAX]u8 = @splat(0),
};

const Maxatomic = 64 * 1024;

pub var qiomaxatomic: u32 = Maxatomic;

fn assert(ok: bool) void {
    if (!ok) panic("qio: assert failed, pc %#p", .{@returnAddress()});
}

/// A byte count as the C's int.
fn int(n: usize) i32 {
    return @intCast(n);
}

/// Queue occupancy in BALLOC bytes behind position `wp`; the C's
/// (int)(wp - q->rp), which relies on the positions wrapping.
fn qdist(wp: u32, rp: u32) i32 {
    return @bitCast(wp -% rp);
}

/// The queue's error string.
fn qerrstr(q: *Queue) []const u8 {
    return std.mem.sliceTo(&q.err, 0);
}

/// What the C does with error(q->err).
fn qerror(q: *Queue) Error {
    const s = qerrstr(q);
    if (std.mem.eql(u8, s, Ehungup))
        return error.Ehungup;
    return proc.errorf("%s", .{s});
}

/// free a list of blocks
pub fn freeblist(b_: ?*Block) void {
    var b = b_;
    while (b) |x| {
        const next = x.next;
        x.next = null;
        freeb(x);
        b = next;
    }
}

/// return count of bytes in a string of blocks
pub fn blocklen(bp_: ?*Block) usize {
    var len: usize = 0;
    var bp = bp_;
    while (bp) |b| {
        len += BLEN(b);
        bp = b.next;
    }
    return len;
}

/// copy the contents of a string of blocks into
/// memory from an offset. blocklist kept unchanged.
/// return number of copied bytes.
pub fn readblist(b_: ?*Block, p_: []u8, o_: usize) usize {
    var b = b_;
    var p = p_;
    var o = o_;

    var r: usize = 0;
    while (p.len > 0) {
        const x = b orelse break;
        var m = BLEN(x);
        if (o >= m) {
            o -= m;
        } else {
            m -= o;
            if (p.len < m)
                m = p.len;
            @memcpy(p[0..m], (x.rp + o)[0..m]);
            p = p[m..];
            r += m;
            o = 0;
        }
        b = x.next;
    }
    return r;
}

/// copy the string of blocks into
/// a single block and free the string
pub fn concatblock(bp: *Block) *Block {
    if (bp.next == null)
        return bp;
    const len = blocklen(bp);
    return pullupblock(bp, len) orelse panic("concatblock", .{});
}

/// make sure the first block has at least n bytes
pub fn pullupblock(bp_: *Block, n_: usize) ?*Block {
    var bp = bp_;
    var n = n_;

    // this should almost always be true, it's
    // just to avoid every caller checking.
    if (BLEN(bp) >= n)
        return bp;

    // if not enough room in the first block,
    // add another to the front of the list.
    if (@intFromPtr(bp.lim) - @intFromPtr(bp.rp) < n) {
        const nbp = allocb(n);
        nbp.next = bp;
        bp = nbp;
    }

    // copy bytes from the trailing blocks into the first
    n -= BLEN(bp);
    while (bp.next) |nbp| {
        var i: usize = undefined;
        // shouldn't happen but why crash if it does
        if (@intFromPtr(nbp.wp) < @intFromPtr(nbp.rp)) {
            print("pullup negative length packet, called from %#p\n", .{@returnAddress()});
            i = 0;
        } else i = BLEN(nbp);
        if (i > n) {
            @memcpy(bp.wp[0..n], nbp.rp[0..n]);
            bp.wp += n;
            nbp.rp += n;
            if (QDEBUG) checkb(bp, "pullupblock 1");
            return bp;
        } else {
            @memcpy(bp.wp[0..i], nbp.rp[0..i]);
            bp.wp += i;
            bp.next = nbp.next;
            nbp.next = null;
            freeb(nbp);
            n -= i;
            if (n == 0) {
                if (QDEBUG) checkb(bp, "pullupblock 2");
                return bp;
            }
        }
    }
    freeb(bp);
    return null;
}

/// make sure the first block has at least n bytes
pub fn pullupqueue(q: *Queue, n: usize) ?*Block {
    if (BLEN(q.bfirst.?) >= n)
        return q.bfirst;
    q.bfirst = pullupblock(q.bfirst.?, n);
    var b = q.bfirst;
    while (b) |x| : (b = x.next) {
        if (x.next == null) break;
    }
    q.blast = b;
    return q.bfirst;
}

/// trim to len bytes starting at offset
pub fn trimblock(bp_: *Block, offset_: i32, len_: i32) ?*Block {
    var bp = bp_;

    if (offset_ < 0 or len_ < 0) {
        freeblist(bp);
        return null;
    }
    var offset: usize = @intCast(offset_);
    var len: usize = @intCast(len_);

    if (QDEBUG) checkb(bp, "trimblock 1");
    var l = blocklen(bp);
    if (offset == 0 and len == l)
        return bp;
    if (l < offset + len) {
        freeblist(bp);
        return null;
    }

    while (true) {
        l = BLEN(bp);
        if (!(l < offset)) break;
        offset -= l;
        const nb = bp.next;
        bp.next = null;
        freeb(bp);
        bp = nb.?;
    }

    const startb = bp;
    bp.rp += offset;

    while (true) {
        l = BLEN(bp);
        if (!(l < len)) break;
        len -= l;
        bp = bp.next.?;
    }

    bp.wp -= (BLEN(bp) - len);

    if (bp.next != null) {
        freeblist(bp.next);
        bp.next = null;
    }

    return startb;
}

/// pad a block to the front (or the back if size is negative)
pub fn padblock(bp: *Block, size_: i32) *Block {
    var nbp: *Block = undefined;

    if (QDEBUG) checkb(bp, "padblock 0");
    if (size_ >= 0) {
        const size: usize = @intCast(size_);
        if (@intFromPtr(bp.rp) - @intFromPtr(bp.base) >= size) {
            bp.rp -= size;
            return bp;
        }
        const n = BLEN(bp);
        nbp = allocb(size + n);
        nbp.rp += size;
        nbp.wp = nbp.rp;
        @memcpy(nbp.wp[0..n], bp.rp[0..n]);
        nbp.wp += n;
        nbp.rp -= size;
    } else {
        const size: usize = @intCast(-size_);
        if (@intFromPtr(bp.lim) - @intFromPtr(bp.wp) >= size)
            return bp;
        const n = BLEN(bp);
        nbp = allocb(n + size);
        @memcpy(nbp.wp[0..n], bp.rp[0..n]);
        nbp.wp += n;
    }
    nbp.next = bp.next;
    freeb(bp);
    if (QDEBUG) checkb(nbp, "padblock 1");
    return nbp;
}

/// copy 'count' bytes into a new block
pub fn copyblock(bp_: *Block, count_: usize) *Block {
    var count = count_;

    if (QDEBUG) checkb(bp_, "copyblock 0");
    const nbp = blk: {
        if (bp_.pool) |pool| {
            if (count <= pool.size) {
                if (iallocbp(pool)) |x| break :blk x;
            }
        }
        break :blk allocb(count);
    };
    nbp.flag |= bp_.flag & ~(ab.BINTR | ab.BFREE);

    var bp: ?*Block = bp_;
    while (count > 0) {
        const x = bp orelse break;
        var l = BLEN(x);
        if (l > count)
            l = count;
        @memcpy(nbp.wp[0..l], x.rp[0..l]);
        nbp.wp += l;
        count -= l;
        bp = x.next;
    }
    if (count > 0) {
        @memset(nbp.wp[0..count], 0);
        nbp.wp += count;
    }
    if (QDEBUG) checkb(nbp, "copyblock 1");

    return nbp;
}

pub fn adjustblock(bp: *Block, len_: i32) ?*Block {
    if (len_ < 0) {
        freeb(bp);
        return null;
    }
    const len: usize = @intCast(len_);

    if (@intFromPtr(bp.rp) + len > @intFromPtr(bp.lim)) {
        const nbp = copyblock(bp, len);
        freeblist(bp);
        if (QDEBUG) checkb(nbp, "adjustblock 1");

        return nbp;
    }

    const n = BLEN(bp);
    if (len > n)
        @memset(bp.wp[0 .. len - n], 0);
    bp.wp = bp.rp + len;
    if (QDEBUG) checkb(bp, "adjustblock 2");

    return bp;
}

/// if the allocated space is way out of line with the used
/// space, reallocate to a smaller block
pub fn packblock(bp_: ?*Block) ?*Block {
    var bp = bp_;

    var l: *?*Block = &bp;
    while (l.*) |nbp| : (l = &l.*.?.next) {
        const n = BLEN(nbp);
        if ((n << 2) < BALLOC(nbp)) {
            const b = allocb(n);
            l.* = b;
            @memcpy(b.wp[0..n], nbp.rp[0..n]);
            b.wp += n;
            b.next = nbp.next;
            freeb(nbp);
        }
    }

    return bp;
}

/// throw away up to count bytes from a
/// list of blocks.  Return count of bytes
/// thrown away.
pub fn pullblock(bph_: ?*?*Block, count_: usize) usize {
    var count = count_;

    var bytes: usize = 0;
    const bph = bph_ orelse return 0;

    while (count > 0) {
        const bp = bph.* orelse break;
        if (QDEBUG) checkb(bp, "pullblock ");
        var n = BLEN(bp);
        if (count < n)
            n = count;
        bytes += n;
        count -= n;
        bp.rp += n;
        if (BLEN(bp) == 0) {
            bph.* = bp.next;
            bp.next = null;
            freeb(bp);
        }
    }
    return bytes;
}

/// remove a block from the front of the queue
pub fn qremove(q: *Queue) ?*Block {
    const b = q.bfirst orelse return null;
    if (QDEBUG) checkb(b, "qremove");
    q.bfirst = b.next;
    b.next = null;
    q.dlen -= int(BLEN(b));
    q.rp +%= @truncate(BALLOC(b));
    return b;
}

/// put a block back to the front of the queue
pub fn qputback(q: *Queue, b: *Block) void {
    if (QDEBUG) checkb(b, "qputback");
    b.next = q.bfirst;
    if (q.bfirst == null)
        q.blast = b;
    q.bfirst = b;
    q.dlen += int(BLEN(b));
    q.rp -%= @truncate(BALLOC(b));
}

/// after removing data from the queue,
/// unlock queue and wakeup blocked writer.
/// called at interrupt level.
fn iunlock_consumer(q: *Queue) u32 {
    const s = q.state;

    // stop flow control when back at or below the limit
    if (qdist(q.wp, q.rp) <= q.limit)
        q.state = s & ~Qflow;

    iunlock(&q.lock);

    if (s & Qflow != 0) {
        // wakeup flow controlled writers.
        // note that this is done even when q.state
        // still has Qflow set, as the unblocking
        // condition depends on the writers local queuing
        // position, not on the global queue length.
        _ = wakeup(&q.wr);
    }
    return s;
}

/// after removing data from the queue,
/// unlock queue and wakeup blocked writer.
/// get output going again when it was blocked.
/// called at process level.
fn iunlock_reader(q: *Queue) u32 {
    const s = iunlock_consumer(q);

    if (q.kick) |kick| {
        if (s & Qflow != 0)
            kick(q.arg);
    }

    return s;
}

/// after inserting into queue,
/// unlock queue and wakeup starved reader.
/// called at interrupt level.
fn iunlock_producer(q: *Queue) u32 {
    var s = q.state;

    // start flow control when above the limit
    if (qdist(q.wp, q.rp) > q.limit)
        s |= Qflow;

    q.state = s & ~Qstarve;
    iunlock(&q.lock);

    if (s & Qstarve != 0) {
        const p = wakeup(&q.rr);

        // if we just wokeup a higher priority process, let it run
        if (p) |x| {
            if (arch.up()) |up| {
                if (x.priority > up.priority and arch.islo())
                    proc.sched();
            }
        }
    }
    return s;
}

/// unlock queue and wakeup starved reader.
/// get output going again when it was starved.
/// called at process level.
fn iunlock_writer(q: *Queue) u32 {
    const s = iunlock_producer(q);

    if (q.kick) |kick| {
        if (s & (Qstarve | Qkick) != 0)
            kick(q.arg);
    }

    return s;
}

/// get next block from a queue, return null if nothing there
/// called at interrupt level.
pub fn qget(q: *Queue) ?*Block {
    ilock(&q.lock);
    const b = qremove(q) orelse {
        q.state |= Qstarve;
        iunlock(&q.lock);
        return null;
    };
    _ = iunlock_consumer(q);

    return b;
}

/// Interrupt level copy out of a queue, return # bytes copied.
pub fn qconsume(q: *Queue, vp: []u8) i32 {
    var tofree: ?*Block = null;
    var len: usize = vp.len;
    var ret: i32 = undefined;

    ilock(&q.lock);
    out: {
        var b: *Block = undefined;
        var n: usize = undefined;
        while (true) {
            b = q.bfirst orelse {
                q.state |= Qstarve;
                ret = -1;
                break :out;
            };
            if (QDEBUG) checkb(b, "qconsume 1");

            n = BLEN(b);
            if (n > 0)
                break;

            // get rid of zero-length blocks
            q.bfirst = b.next;
            q.rp +%= @truncate(BALLOC(b));

            // remember to free this
            b.next = tofree;
            tofree = b;
        }

        if (n < len)
            len = n;
        @memcpy(vp[0..len], b.rp[0..len]);
        b.rp += len;
        q.dlen -= int(len);

        // discard the block if we're done with it
        if ((q.state & Qmsg) != 0 or len == n) {
            q.bfirst = b.next;
            q.rp +%= @truncate(BALLOC(b));
            q.dlen -= int(BLEN(b));

            // remember to free this
            b.next = tofree;
            tofree = b;
        }
        ret = int(len);
    }
    _ = iunlock_consumer(q);

    freeblist(tofree);

    return ret;
}

/// add a block list to a queue, return bytes added
pub fn qaddlist(q: *Queue, b_: *Block) usize {
    var b = b_;

    if (QDEBUG) checkb(b, "qaddlist 1");

    // queue the block
    if (q.bfirst != null)
        q.blast.?.next = b
    else
        q.bfirst = b;

    var len = BLEN(b);
    q.wp +%= @truncate(BALLOC(b));
    while (b.next) |next| {
        b = next;
        if (QDEBUG) checkb(b, "qaddlist 2");
        len += BLEN(b);
        q.wp +%= @truncate(BALLOC(b));
    }
    q.dlen += int(len);
    q.blast = b;
    return len;
}

pub fn qpass(q: *Queue, b: *Block) i32 {
    ilock(&q.lock);
    if (q.state & Qclosed != 0) {
        iunlock(&q.lock);
        freeblist(b);
        return 0;
    }
    if (q.state & Qflow != 0) {
        iunlock(&q.lock);
        freeblist(b);
        return -1;
    }
    const len = qaddlist(q, b);
    _ = iunlock_producer(q);

    return int(len);
}

pub fn qpassnolim(q: *Queue, b: *Block) usize {
    ilock(&q.lock);
    if (q.state & Qclosed != 0) {
        iunlock(&q.lock);
        freeblist(b);
        return 0;
    }
    const len = qaddlist(q, b);
    _ = iunlock_producer(q);

    return len;
}

pub fn qproduce(q: *Queue, vp: []const u8) i32 {
    const len = vp.len;

    const b = iallocb(len) orelse
        return 0;

    // save in buffer
    @memcpy(b.wp[0..len], vp);
    b.wp += len;

    return qpass(q, b);
}

/// copy from offset in the queue
pub fn qcopy(q: *Queue, len: usize, offset: usize) *Block {
    const b = allocb(len);
    ilock(&q.lock);
    b.wp += readblist(q.bfirst, b.wp[0..len], offset);
    iunlock(&q.lock);
    return b;
}

/// called by non-interrupt code
pub fn qopen(limit: i32, msg: u32, kick: ?Kick, arg: ?*anyopaque) ?*Queue {
    assert(limit >= 0);

    const q: *Queue = @ptrCast(@alignCast(alloc.malloc(@sizeOf(Queue)) orelse
        return null));
    q.* = .{};

    q.dlen = 0;
    q.wp = 0;
    q.rp = 0;
    q.limit = limit;
    q.inilim = limit;
    q.kick = kick;
    q.arg = arg;
    q.state = msg | Qstarve;
    q.eof = 0;
    q.noblock = false;

    return q;
}

/// open a queue to be bypassed
pub fn qbypass(bypass: ?Bypass, arg: ?*anyopaque) ?*Queue {
    const q: *Queue = @ptrCast(@alignCast(alloc.malloc(@sizeOf(Queue)) orelse
        return null));
    q.* = .{};

    q.dlen = 0;
    q.wp = 0;
    q.rp = 0;
    q.limit = 0;
    q.arg = arg;
    q.bypass = bypass;
    q.state = 0;
    q.eof = 0;
    q.noblock = false;

    return q;
}

pub fn qsetbypass(q: *Queue, bypass: ?Bypass) void {
    ilock(&q.lock);
    if (bypass) |f| {
        while (qremove(q)) |b| {
            iunlock(&q.lock);
            f(q.arg, b);
            ilock(&q.lock);
        }
        q.state |= Qstarve;
    }
    q.bypass = bypass;
    _ = iunlock_consumer(q);
}

fn notempty(a: ?*anyopaque) bool {
    const q: *Queue = @ptrCast(@alignCast(a.?));

    return q.bfirst != null or (q.state & Qclosed) != 0;
}

/// wait for the queue to be non-empty or closed.
/// called with q ilocked.
///
/// Returns 1 when there is data, 0 at end of file and -1 when the
/// caller should fail with the queue's error; q is ilocked then.  When
/// the sleep is interrupted the error is returned with q NOT locked.
fn qwait(q: *Queue) Error!i32 {
    // wait for data
    while (true) {
        if (q.bfirst != null)
            break;

        if (q.state & Qclosed != 0) {
            if (q.eof >= 3 or (q.err[0] != 0 and !std.mem.eql(u8, qerrstr(q), Ehungup)))
                return -1;
            q.eof += 1;
            return 0;
        }

        q.state |= Qstarve; // flag requesting producer to wake me
        iunlock(&q.lock);
        try sleep(&q.rr, notempty, q);
        ilock(&q.lock);
    }
    return 1;
}

/// cut off n bytes from the end of *h. return a new
/// block with the tail and change *h to refer to the
/// head.
fn splitblock(h: **Block, n: usize) *Block {
    const a = h.*;
    const m = BLEN(a) - n;
    if (m < n) {
        const b = allocb(m);
        @memcpy(b.wp[0..m], a.rp[0..m]);
        b.wp += m;
        a.rp += m;
        h.* = b;
        return a;
    } else {
        const b = allocb(n);
        a.wp -= n;
        @memcpy(b.wp[0..n], a.wp[0..n]);
        b.wp += n;
        return b;
    }
}

/// get next block from a queue (up to a limit)
pub fn qbread(q: *Queue, len: usize) Error!?*Block {
    try eqlock(&q.rlock);
    defer qunlock(&q.rlock);

    ilock(&q.lock);
    switch (try qwait(q)) {
        0 => {
            // queue closed
            iunlock(&q.lock);
            return null;
        },
        -1 => {
            // multiple reads on a closed queue
            iunlock(&q.lock);
            return qerror(q);
        },
        else => {},
    }

    // if we get here, there's at least one block in the queue
    var b = qremove(q).?;
    var n = BLEN(b);

    // split block if it's too big and this is not a message queue
    if (n > len) {
        n -= len;
        if ((q.state & Qmsg) == 0)
            qputback(q, splitblock(&b, n))
        else
            b.wp -= n;
    }
    _ = iunlock_reader(q);

    return b;
}

/// read a queue.  if no data is queued, post a Block
/// and wait on its Rendez.
pub fn qread(q: *Queue, vp: []u8) Error!usize {
    const len = vp.len;
    var first: ?*Block = null;

    {
        try eqlock(&q.rlock);
        defer qunlock(&q.rlock);

        ilock(&q.lock);
        var last: *?*Block = undefined;
        var n: usize = undefined;
        again: while (true) {
            switch (try qwait(q)) {
                0 => {
                    // queue closed
                    iunlock(&q.lock);
                    return 0;
                },
                -1 => {
                    // multiple reads on a closed queue
                    iunlock(&q.lock);
                    return qerror(q);
                },
                else => {},
            }

            // if we get here, there's at least one block in the queue
            last = &first;
            if (q.state & Qcoalesce != 0) {
                // when coalescing, 0 length blocks just go away
                var b = q.bfirst.?;
                var m = BLEN(b);
                if (m == 0) {
                    freeb(qremove(q));
                    continue :again;
                }
                // grab the first block plus as many
                // following blocks as will partially
                // fit in the read.
                n = 0;
                while (true) {
                    last.* = qremove(q);
                    n += m;
                    if (n >= len or q.bfirst == null)
                        break;
                    last = &b.next;
                    b = q.bfirst.?;
                    m = BLEN(b);
                }
            } else {
                first = qremove(q);
                n = BLEN(first.?);
            }
            break;
        }

        // split last block if it's too big and this is not a message queue
        if (n > len and (q.state & Qmsg) == 0) {
            var h = last.*.?;
            const tail = splitblock(&h, n - len);
            last.* = h;
            qputback(q, tail);
        }

        _ = iunlock_reader(q);
    }

    // M4: the C frees `first` in a waserror if the copy to vp faults.
    const n = readblist(first, vp, 0);
    freeblist(first);

    return n;
}

/// a Flow represens a flow controlled
/// writer on queue q with position p.
const Flow = struct {
    q: *Queue,
    p: u32,
};

fn unblocked(a: ?*anyopaque) bool {
    const f: *Flow = @ptrCast(@alignCast(a.?));
    const q = f.q;

    return q.noblock or qdist(f.p, q.rp) <= q.limit or (q.state & Qclosed) != 0;
}

/// flow control, wait for queue to drain back to the limit
fn qflow(f: *Flow) Error!void {
    const q = f.q;

    while (!unblocked(f)) {
        try eqlock(&q.wlock);
        defer qunlock(&q.wlock);
        try sleep(&q.wr, unblocked, f);
    }
}

/// add a block to a queue obeying flow control
pub fn qbwrite(q: *Queue, b: *Block) Error!usize {
    if (q.bypass) |bypass| {
        const len = blocklen(b);
        bypass(q.arg, b);
        return len;
    }

    ilock(&q.lock);

    // give up if the queue is closed
    if (q.state & Qclosed != 0) {
        iunlock(&q.lock);
        freeblist(b);
        return qerror(q);
    }
    // if the queue is full,
    // silently discard when non-blocking
    if (q.state & Qflow != 0 and q.noblock) {
        iunlock(&q.lock);
        const len = blocklen(b);
        freeblist(b);
        return len;
    }
    const len = qaddlist(q, b);

    // save our current position in queue
    // for flow control below.
    var flow: Flow = .{ .q = q, .p = q.wp };
    if (iunlock_writer(q) & Qflow != 0) {
        // flow control, before allowing the process to continue and
        // queue more. We do this here so that postnote can only
        // interrupt us after the data has been queued.  This means that
        // things like 9p flushes and ssl messages will not be disrupted
        // by software interrupts.
        try qflow(&flow);
    }

    return len;
}

/// block here uninterruptable until queue drains.
fn qbloated(q: *Queue) Error!void {
    var flow: Flow = .{ .q = q, .p = q.wp };
    while (true) {
        qflow(&flow) catch {
            const up = arch.up().?;
            if (up.procctl == portdat.Proc_exitme or up.procctl == portdat.Proc_exitbig)
                return error.Egreg;
            continue;
        };
        break;
    }
}

/// write to a queue.  only Maxatomic bytes at a time is atomic.
pub fn qwrite(q: *Queue, vp: []const u8) Error!usize {
    const len = vp.len;

    if (QDEBUG) {
        if (!arch.islo())
            print("qwrite hi %#p\n", .{@returnAddress()});
    }

    // when the queue length grew over twice the limit,
    // block here before allocating more blocks.
    // this can happen when qflow() is getting
    // interrupted by notes, preventing effective
    // flow control.
    if (q.state & Qflow != 0 and @divTrunc(qdist(q.wp, q.rp), 2) > q.limit)
        try qbloated(q);

    var sofar: usize = 0;
    while (true) {
        var n = len - sofar;
        if (n > Maxatomic)
            n = Maxatomic;

        const b = allocb(n);
        // M4: the C frees b in a waserror if the copy from vp faults.
        @memcpy(b.wp[0..n], vp[sofar..][0..n]);
        b.wp += n;

        sofar += try qbwrite(q, b);
        if (!(sofar < len and (q.state & Qmsg) == 0)) break;
    }

    return len;
}

/// used by print() to write to a queue.  Since we may be splhi or not in
/// a process, don't qlock.
pub fn qiwrite(q: *Queue, vp: []const u8) usize {
    const len = vp.len;

    var sofar: usize = 0;
    loop: while (true) {
        body: {
            var n = len - sofar;
            if (n > Maxatomic)
                n = Maxatomic;

            const b = iallocb(n) orelse
                break :loop;
            @memcpy(b.wp[0..n], vp[sofar..][0..n]);
            b.wp += n;

            if (q.bypass) |bypass| {
                sofar += n;
                bypass(q.arg, b);
                break :body;
            }

            ilock(&q.lock);
            if (q.state & (Qflow | Qclosed) != 0) {
                iunlock(&q.lock);
                freeb(b);
                break :loop;
            }
            sofar += qaddlist(q, b);
            _ = iunlock_writer(q);
        }
        if (!(sofar < len and (q.state & Qmsg) == 0)) break;
    }

    return sofar;
}

/// throw away the next 'len' bytes in the queue
pub fn qdiscard(q: *Queue, len: usize) usize {
    var tofree: ?*Block = null;

    ilock(&q.lock);
    var sofar: usize = 0;
    while (sofar < len) {
        const b = q.bfirst orelse
            break;
        if (QDEBUG) checkb(b, "qdiscard");
        var n = BLEN(b);
        if (n <= len - sofar) {
            q.bfirst = b.next;
            q.rp +%= @truncate(BALLOC(b));

            // remember to free this
            b.next = tofree;
            tofree = b;
        } else {
            n = len - sofar;
            b.rp += n;
        }
        q.dlen -= int(n);
        sofar += n;
    }
    _ = iunlock_consumer(q);

    freeblist(tofree);

    return sofar;
}

/// flush the output queue
pub fn qflush(q: *Queue) void {
    ilock(&q.lock);
    const tofree = q.bfirst;
    q.bfirst = null;
    q.rp = q.wp;
    q.dlen = 0;
    _ = iunlock_consumer(q);

    freeblist(tofree);
}

/// Mark a queue as closed.  No further IO is permitted.
/// All blocks are released.
pub fn qclose(q_: ?*Queue) void {
    const q = q_ orelse return;

    ilock(&q.lock);
    q.state |= Qclosed;
    q.state &= ~(Qflow | Qstarve);
    kstrcpy(&q.err, Ehungup);
    const tofree = q.bfirst;
    q.bfirst = null;
    q.rp = q.wp;
    q.dlen = 0;
    q.noblock = false;
    iunlock(&q.lock);

    // wake up readers/writers
    _ = wakeup(&q.rr);
    _ = wakeup(&q.wr);

    // free queued blocks
    freeblist(tofree);
}

/// be extremely careful when calling this,
/// as there is no reference accounting
pub fn qfree(q: ?*Queue) void {
    qclose(q);
    alloc.free(q);
}

/// Mark a queue as closed.  Wakeup any readers.  Don't remove queued
/// blocks.
pub fn qhangup(q: *Queue, msg_: ?[]const u8) void {
    ilock(&q.lock);
    q.state |= Qclosed;
    var msg = msg_ orelse Ehungup;
    if (msg.len == 0)
        msg = Ehungup;
    kstrcpy(&q.err, msg);
    iunlock(&q.lock);

    // wake up readers/writers
    _ = wakeup(&q.rr);
    _ = wakeup(&q.wr);
}

/// return true if the q is hungup
pub fn qisclosed(q: *Queue) bool {
    return q.state & Qclosed != 0;
}

/// mark a queue as no longer hung up
pub fn qreopen(q: *Queue) void {
    ilock(&q.lock);
    q.state &= ~Qclosed;
    q.state |= Qstarve;
    q.eof = 0;
    q.limit = q.inilim;
    iunlock(&q.lock);
}

/// return bytes queued
pub fn qlen(q: *Queue) i32 {
    return q.dlen;
}

/// return true if we can read without blocking
pub fn qcanread(q: *Queue) bool {
    return q.bfirst != null;
}

/// return true when the queue is full
pub fn qfull(q: *Queue) bool {
    return q.state & Qflow != 0;
}

/// change queue limit
pub fn qsetlimit(q: *Queue, limit: i32) void {
    assert(limit >= 0);

    ilock(&q.lock);
    q.limit = limit;
    _ = iunlock_consumer(q);
}

/// set blocking/nonblocking
pub fn qnoblock(q: *Queue, onoff: bool) void {
    ilock(&q.lock);
    q.noblock = onoff;
    _ = iunlock_consumer(q);
}
