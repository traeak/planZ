//! from libthread/exit.c
//!
//! DIFF:
//!   - threadwaitchan's channel carries *libc.Waitmsg from the
//!     allocator, which the receiver destroys.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const impl = @import("impl.zig");
const create = @import("create.zig");
const sched = @import("sched.zig");
const channel = @import("channel.zig");

pub var waitchan: ?*channel.Channel = null;

pub fn threadexits(exitstr: ?[]const u8) noreturn {
    const p = impl.getproc();
    const t = p.thread.?;
    impl.set(&t.moribund, true);
    p.setexitmsg(exitstr orelse "");
    sched.sched();
    unreachable;
}

pub fn threadexitsall(exitstr_: ?[]const u8) noreturn {
    var pid: [64]i32 = undefined;

    const exitstr = exitstr_ orelse "";
    impl.setexitsall(exitstr);
    const mypid: i32 = @intCast(libc.getpid());

    // signal others.
    // copying all the pids first avoids other threads
    // teardown procedures getting in the way.
    //
    // avoid mallocs since malloc can post a note which can
    // call threadexitsall...
    while (true) {
        impl.lock(&create.threadpq.lock);
        var npid: usize = 0;
        var p = create.threadpq.head;
        while (p) |q| : (p = q.next) {
            if (npid >= pid.len)
                break;
            if (!q.threadint and q.pid != mypid and q.pid != -1) {
                pid[npid] = q.pid;
                npid += 1;
                q.threadint = true;
            }
        }
        impl.unlock(&create.threadpq.lock);
        if (npid == 0)
            break;
        for (pid[0..npid]) |id|
            libc.postnote(libc.PNPROC, @intCast(id), "threadint") catch {};
    }

    // leave
    libc.exits(if (exitstr.len == 0) null else exitstr);
}

pub fn threadwaitchan() *channel.Channel {
    if (waitchan == null)
        waitchan = channel.chancreate(@sizeOf(*libc.Waitmsg), 16);
    return waitchan.?;
}
