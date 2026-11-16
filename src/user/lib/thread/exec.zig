//! from libthread/exec.c
//!
//! DIFF:
//!   - args is a slice of slices, the program's name first; there is
//!     no procexecl, which is procexec with the arguments in a tuple
//!     literal.
//!   - pidc is a channel of u32 (the C's ulong), which gets the pid, or
//!     ~0 on failure.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const impl = @import("impl.zig");
const sched = @import("sched.zig");
const main = @import("main.zig");
const channel = @import("channel.zig");

/// Replace the calling proc, which must have only this thread, with
/// prog, as exec does.  Returns only on failure, with the error
/// string set.
pub fn procexec(pidc: ?*channel.Channel, prog: []const u8, args: []const []const u8) void {
    // must be only thread in proc
    const p = impl.getproc();
    const t = p.thread.?;
    bad: {
        if (p.threads.head != t or p.threads.head.?.nextt != null) {
            libc.werrstr("not only thread in proc", .{});
            break :bad;
        }

        // We want procexec to behave like exec; if exec succeeds,
        // never return, and if it fails, return with errstr set.
        // Unfortunately, the exec happens in another proc since
        // we have to wait for the exec'ed process to finish.
        // To provide the semantics, we open a pipe with the
        // write end close-on-exec and hand it to the proc that
        // is doing the exec.  If the exec succeeds, the pipe will
        // close so that our read below fails.  If the exec fails,
        // then the proc doing the exec sends the errstr down the
        // pipe to us.
        if (sys.pipe(&p.exec.fd) < 0)
            break :bad;
        var nb: [32]u8 = undefined;
        const n = sys.open(libc.sprint(&nb, "/fd/%d", .{p.exec.fd[1]}), sys.OWRITE | sys.OCEXEC);
        if (n < 0) {
            _ = sys.close(p.exec.fd[0]);
            _ = sys.close(p.exec.fd[1]);
            break :bad;
        }
        _ = sys.close(p.exec.fd[1]);
        p.exec.fd[1] = @intCast(n);

        while (p.needexec or p.newproc != null)
            sched.sched();

        // exec in parallel via the scheduler
        p.exec.prog = prog;
        p.exec.args = args;
        p.needexec = true;
        sched.sched();

        _ = sys.close(p.exec.fd[1]);
        const r = sys.read(p.exec.fd[0], p.exitstr[0 .. impl.ERRMAX - 1]);
        if (r > 0) { // exec failed
            p.exitstr[@intCast(r)] = 0;
            libc.werrstr("%s", .{p.exitmsg()});
            _ = sys.close(p.exec.fd[0]);
            break :bad;
        }
        _ = sys.close(p.exec.fd[0]);

        if (t.ret == -1)
            break :bad;
        if (pidc) |c|
            _ = channel.sendul(c, @bitCast(t.ret));

        // wait for exec'ed program, then exit
        main.schedexecwait();
    }
    if (pidc) |c|
        _ = channel.sendul(c, ~@as(u32, 0));
}
