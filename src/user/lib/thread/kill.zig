//! from libthread/kill.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const impl = @import("impl.zig");
const create = @import("create.zig");
const rendez = @import("rendez.zig");

const Proc = impl.Proc;
const Thread = impl.Thread;
const lock = impl.lock;
const unlock = impl.unlock;

fn threadxxxgrp(grp: i32, dokill: bool) void {
    lock(&create.threadpq.lock);
    var p = create.threadpq.head;
    while (p) |q| : (p = q.next) {
        lock(&q.lock);
        var t = q.threads.head;
        while (t) |x| : (t = x.nextt) {
            if (x.grp == grp) {
                if (dokill)
                    impl.set(&x.moribund, true);
                tinterrupt(q, x);
            }
        }
        unlock(&q.lock);
    }
    unlock(&create.threadpq.lock);
    rendez.threadbreakrendez();
}

fn threadxxx(id: i32, dokill: bool) void {
    lock(&create.threadpq.lock);
    var p = create.threadpq.head;
    while (p) |q| : (p = q.next) {
        lock(&q.lock);
        var t = q.threads.head;
        while (t) |x| : (t = x.nextt) {
            if (x.id == id) {
                if (dokill)
                    impl.set(&x.moribund, true);
                tinterrupt(q, x);
                unlock(&q.lock);
                unlock(&create.threadpq.lock);
                rendez.threadbreakrendez();
                return;
            }
        }
        unlock(&q.lock);
    }
    unlock(&create.threadpq.lock);
}

/// kill threads in group
pub fn threadkillgrp(grp: i32) void {
    threadxxxgrp(grp, true);
}

/// kill thread
pub fn threadkill(id: i32) void {
    threadxxx(id, true);
}

/// interrupt threads in grp
pub fn threadintgrp(grp: i32) void {
    threadxxxgrp(grp, false);
}

/// interrupt thread
pub fn threadint(id: i32) void {
    threadxxx(id, false);
}

fn writeprocctl(pid: i32, ctl: []const u8) bool {
    var buf: [32]u8 = undefined;

    const file = libc.sprint(&buf, "/proc/%ud/ctl", .{@as(u32, @bitCast(pid))});
    const fd = sys.open(file, sys.OWRITE | sys.OCEXEC);
    if (fd < 0)
        return false;
    if (sys.write(fd, ctl) < 0) {
        _ = sys.close(fd);
        return false;
    }
    _ = sys.close(fd);
    return true;
}

fn tinterrupt(p: *Proc, t: *Thread) void {
    switch (impl.get(&t.state)) {
        .Running => {
            if (!writeprocctl(p.pid, "interrupt"))
                libc.postnote(libc.PNPROC, @bitCast(p.pid), "threadint") catch {};
        },
        .Rendezvous => rendez.threadflagrendez(t),
        else => {},
    }
}
