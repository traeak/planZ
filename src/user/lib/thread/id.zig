//! from libthread/id.c
//!
//! DIFF:
//!   - threadsetname takes the name as a slice (the C formats it), and
//!     writes it to /proc/n/args without the C's 0 after it.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const impl = @import("impl.zig");
const create = @import("create.zig");

const lock = impl.lock;
const unlock = impl.unlock;

pub fn threadid() i32 {
    return impl.getproc().thread.?.id;
}

/// The pid of the proc that thread id is in; of this proc for 0; -1
/// if there is no such thread.
pub fn threadpid(id: i32) i32 {
    if (id < 0)
        return -1;
    if (id == 0)
        return impl.getproc().pid;
    lock(&create.threadpq.lock);
    var p = create.threadpq.head;
    while (p) |q| : (p = q.next) {
        lock(&q.lock);
        var t = q.threads.head;
        while (t) |x| : (t = x.nextt) {
            if (x.id == id) {
                const pid = q.pid;
                unlock(&q.lock);
                unlock(&create.threadpq.lock);
                return pid;
            }
        }
        unlock(&q.lock);
    }
    unlock(&create.threadpq.lock);
    return -1;
}

/// set thread group, return old
pub fn threadsetgrp(ng: i32) i32 {
    const t = impl.getproc().thread.?;
    const og = t.grp;
    t.grp = ng;
    return og;
}

/// return thread group of current thread
pub fn threadgetgrp() i32 {
    return impl.getproc().thread.?.grp;
}

pub fn threadsetname(name: []const u8) void {
    var buf: [32]u8 = undefined;

    const p = impl.getproc();
    const t = p.thread.?;
    if (t.cmdname) |n|
        libc.allocator.free(n);
    t.cmdname = libc.allocator.dupe(u8, name) catch null;
    if (t.cmdname != null and p.nthreads == 1) {
        const file = libc.sprint(&buf, "/proc/%ud/args", .{libc.getpid()});
        const fd = sys.open(file, sys.OWRITE | sys.OCEXEC);
        if (fd >= 0) {
            _ = sys.write(fd, name);
            _ = sys.close(fd);
        }
    }
}

pub fn threadgetname() ?[]const u8 {
    return impl.getproc().thread.?.cmdname;
}

/// A word of the running thread's own.
pub fn threaddata() *usize {
    return &impl.getproc().thread.?.udata;
}

/// A word of the running proc's own.
pub fn procdata() *usize {
    return &impl.getproc().udata;
}
