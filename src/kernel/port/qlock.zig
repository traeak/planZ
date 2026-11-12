//! Queueing locks: a process that cannot have the lock sleeps until it
//! is handed over, in arrival order.
//! from 9/port/qlock.c
//!
//! DIFF: eqlock returns error.Eintr where the C calls error(Eintr).
//! The qlock statistics (rwstats) are not kept.

const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const proc = @import("proc.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const lock = taslock.lock;
const unlock = taslock.unlock;

pub const QLock = portdat.QLock;
pub const RWLock = portdat.RWLock;
const Proc = portdat.Proc;

fn checklocks(name: []const u8, pc: usize) void {
    // DIFF: with interrupts off, so that m() is this processor's; see
    // proc.sched.
    const s = arch.splhi();
    const depth = arch.m().ilockdepth;
    arch.splx(s);
    if (depth != 0)
        print("%s: %#p: ilockdepth %d\n", .{ name, pc, depth });
    if (arch.up()) |up| {
        if (up.nlocks != 0)
            print("%s: %#p: nlocks %d\n", .{ name, pc, up.nlocks });
    }
}

/// Put the current process at the end of the queue.
fn enqueue(head: *?*Proc, tail: *?*Proc, up: *Proc) void {
    if (tail.*) |p| p.qnext = up else head.* = up;
    tail.* = up;
    up.qnext = null;
}

/// qlock that a note can interrupt.
pub fn eqlock(q: *QLock) proc.Error!void {
    const pc = @returnAddress();
    checklocks("eqlock", pc);

    lock(&q.use);
    if (!q.locked) {
        q.pc = pc;
        q.locked = true;
        unlock(&q.use);
        return;
    }
    const up = arch.up() orelse panic("eqlock", .{});
    if (up.notepending) {
        up.notepending = false;
        unlock(&q.use);
        return proc.interrupted();
    }
    enqueue(&q.head, &q.tail, up);
    up.eql = q;
    up.qpc = pc;
    up.state = .Queueing;
    unlock(&q.use);
    proc.sched();
    if (up.eql == null) {
        up.notepending = false;
        return proc.interrupted();
    }
    up.eql = null;
}

pub fn qlock(q: *QLock) void {
    const pc = @returnAddress();
    checklocks("qlock", pc);

    lock(&q.use);
    if (!q.locked) {
        q.pc = pc;
        q.locked = true;
        unlock(&q.use);
        return;
    }
    const up = arch.up() orelse panic("qlock", .{});
    enqueue(&q.head, &q.tail, up);
    up.eql = null;
    up.qpc = pc;
    up.state = .Queueing;
    unlock(&q.use);
    proc.sched();
}

pub fn canqlock(q: *QLock) bool {
    if (!taslock.canlock(&q.use))
        return false;
    if (q.locked) {
        unlock(&q.use);
        return false;
    }
    q.locked = true;
    q.pc = @returnAddress();
    unlock(&q.use);
    return true;
}

pub fn qunlock(q: *QLock) void {
    lock(&q.use);
    if (!q.locked) {
        unlock(&q.use);
        print("qunlock called with qlock not held, from %#p\n", .{@returnAddress()});
        return;
    }
    if (q.head) |p| {
        if (p.state != .Queueing)
            panic("qunlock", .{});
        q.pc = p.qpc;
        q.head = p.qnext;
        if (q.head == null)
            q.tail = null;
        unlock(&q.use);
        proc.ready(p);
        return;
    }
    q.locked = false;
    unlock(&q.use);
}

pub fn rlock(q: *RWLock) void {
    checklocks("rlock", @returnAddress());

    lock(&q.use);
    if (q.writer == 0 and q.head == null) {
        // no writer, go for it
        q.readers += 1;
        unlock(&q.use);
        return;
    }

    const up = arch.up() orelse panic("rlock", .{});
    enqueue(&q.head, &q.tail, up);
    up.state = .QueueingR;
    unlock(&q.use);
    proc.sched();
}

pub fn runlock(q: *RWLock) void {
    lock(&q.use);
    q.readers -= 1;
    const p = q.head;
    if (q.readers > 0 or p == null) {
        unlock(&q.use);
        return;
    }

    // start waiting writer
    const w = p.?;
    if (w.state != .QueueingW)
        panic("runlock", .{});
    q.head = w.qnext;
    if (q.head == null)
        q.tail = null;
    q.wpc = w.qpc;
    q.writer = 1;
    unlock(&q.use);
    proc.ready(w);
}

pub fn wlock(q: *RWLock) void {
    const pc = @returnAddress();
    checklocks("wlock", pc);

    lock(&q.use);
    if (q.readers == 0 and q.writer == 0) {
        // noone waiting, go for it
        q.wpc = pc;
        q.writer = 1;
        unlock(&q.use);
        return;
    }

    // wait
    const up = arch.up() orelse panic("wlock", .{});
    enqueue(&q.head, &q.tail, up);
    up.qpc = pc;
    up.state = .QueueingW;
    unlock(&q.use);
    proc.sched();
}

pub fn wunlock(q: *RWLock) void {
    lock(&q.use);
    const p = q.head orelse {
        q.writer = 0;
        unlock(&q.use);
        return;
    };
    if (p.state == .QueueingW) {
        // start waiting writer
        q.wpc = p.qpc;
        q.head = p.qnext;
        if (q.head == null)
            q.tail = null;
        unlock(&q.use);
        proc.ready(p);
        return;
    }

    if (p.state != .QueueingR)
        panic("wunlock", .{});

    // waken waiting readers
    while (q.head) |r| {
        if (r.state != .QueueingR) break;
        q.head = r.qnext;
        q.readers += 1;
        proc.ready(r);
    }
    if (q.head == null)
        q.tail = null;
    q.writer = 0;
    unlock(&q.use);
}

/// same as rlock but punts if there are any writers waiting
pub fn canrlock(q: *RWLock) bool {
    lock(&q.use);
    if (q.writer == 0 and q.head == null) {
        // no writer, go for it
        q.readers += 1;
        unlock(&q.use);
        return true;
    }
    unlock(&q.use);
    return false;
}
