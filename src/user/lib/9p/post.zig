//! from lib9p/post.c
//!
//! DIFF:
//!   - postsrv returns an error where the C returns -1.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const p9 = @import("lib9p.zig");

const Srv = p9.Srv;

fn postproc(s: *Srv) void {
    _ = sys.close(@bitCast(sys.rendezvous(@intFromPtr(s), 0)));
    p9.srv(s);
}

/// Serve s on one end of a pipe, in a new process (in its own name
/// space and note group), and return the other end; with a name, the
/// other end is also posted as /srv/name, which goes away when the
/// server exits.
pub fn postsrv(s: *Srv, name: ?[]const u8) libc.Error!i32 {
    var fd: [2]i32 = undefined;
    var cfd: isize = -1;

    if (sys.pipe(&fd) < 0)
        return error.Plan9;
    if (name) |n| {
        var buf: [160]u8 = undefined;
        var nb: [16]u8 = undefined;

        cfd = sys.create(libc.sprint(&buf, "/srv/%s", .{n}), sys.OWRITE | sys.ORCLOSE | sys.OCEXEC, 0o600);
        if (cfd < 0 or sys.write(cfd, libc.sprint(&nb, "%d", .{fd[0]})) < 0) {
            _ = sys.close(fd[0]);
            if (cfd >= 0)
                _ = sys.close(cfd);
            _ = sys.close(fd[1]);
            return error.Plan9;
        }
    }

    // now we are commited
    s.infd = fd[1];
    s.outfd = fd[1];
    if (s.forker == null)
        s.forker = p9.srvforker;
    s.forker.?(postproc, s, sys.RFNAMEG | sys.RFNOTEG);

    _ = sys.rfork(sys.RFFDG);
    _ = sys.rendezvous(@intFromPtr(s), @intCast(fd[0]));
    if (cfd >= 0)
        _ = sys.close(cfd);
    _ = sys.close(fd[1]);
    return fd[0];
}
