//! A queue of requests and a proc that does them one at a time, for a
//! server whose work on a file may wait: the request being done can
//! be flushed, which interrupts the proc.
//! from lib9p/queue.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const thread = @import("thread");
const p9 = @import("lib9p.zig");
const mem = @import("mem.zig");

const Req = p9.Req;
const Queueelem = p9.Queueelem;

pub const Reqqueue = struct {
    ql: libc.QLock = .{},
    rz: libc.Rendez = .{},
    qe: Queueelem = .{},
    pid: i32 = 0,
    flush: i32 = 0,
    cur: ?*Req = null,
};

fn _reqqueueproc(q: *Reqqueue) void {
    var buf: [32]u8 = undefined;
    var r: *Req = undefined;

    _ = sys.rfork(sys.RFNOTEG);

    const fd = sys.open(libc.sprint(&buf, "/proc/%ud/ctl", .{libc.getpid()}), sys.OWRITE | sys.OCEXEC);

    while (true) {
        libc.qlock(&q.ql);
        q.flush = 0;
        if (fd >= 0)
            _ = sys.write(fd, "nointerrupt");
        q.cur = null;
        while (q.qe.next == &q.qe)
            libc.rsleep(&q.rz);
        r = @fieldParentPtr("qu", q.qe.next.?);
        r.qu.next.?.prev = r.qu.prev;
        r.qu.prev.?.next = r.qu.next;
        const f = r.qu.f;
        r.qu = .{};
        q.cur = r;
        libc.qunlock(&q.ql);
        if (f) |func|
            func(r)
        else
            break;
    }

    if (fd >= 0)
        _ = sys.close(fd);
    libc.allocator.destroy(r);
    libc.allocator.destroy(q);
    thread.threadexits(null);
}

pub fn reqqueuecreate() *Reqqueue {
    const q = mem.create9p(Reqqueue);
    q.rz.l = &q.ql;
    q.qe.next = &q.qe;
    q.qe.prev = &q.qe;
    q.pid = thread.proccreate(_reqqueueproc, q, thread.mainstacksize);
    return q;
}

/// Have the queue's proc call f(r) when its turn comes.
pub fn reqqueuepush(q: *Reqqueue, r: *Req, f: ?*const fn (*Req) void) void {
    libc.qlock(&q.ql);
    r.qu.f = f;
    r.qu.next = &q.qe;
    r.qu.prev = q.qe.prev;
    q.qe.prev.?.next = &r.qu;
    q.qe.prev = &r.qu;
    _ = libc.rwakeup(&q.rz);
    libc.qunlock(&q.ql);
}

/// For the server's flush: r, a request given to the queue, is
/// interrupted if it is the one being done, and otherwise taken out
/// and answered "interrupted".
pub fn reqqueueflush(q: *Reqqueue, r: *Req) void {
    libc.qlock(&q.ql);
    if (q.cur == r) {
        thread.threadint(q.pid);
        q.flush += 1;
        libc.qunlock(&q.ql);
    } else {
        if (r.qu.next) |n| {
            n.prev = r.qu.prev;
            r.qu.prev.?.next = r.qu.next;
        }
        r.qu = .{};
        libc.qunlock(&q.ql);
        p9.respond(r, "interrupted");
    }
}

/// End the queue's proc when it has done what it was given.
pub fn reqqueuefree(q_: ?*Reqqueue) void {
    const q = q_ orelse return;
    const r = mem.create9p(Req);
    reqqueuepush(q, r, null);
}
