//! from libauth/procsetuser.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;

/// Make this process user's (the host owner may; anyone may become
/// none).
pub fn procsetuser(user: []const u8) libc.Error!void {
    var name: [32]u8 = undefined;

    var dir = libc.nulldir();
    dir.uid = user;
    libc.dirwstat(libc.sprint(&name, "/proc/%ud/ctl", .{libc.getpid()}), &dir) catch {
        // this is backwards compatibility code as
        // devproc initially didnt allow changing
        // the user to none.
        if (!std.mem.eql(u8, user, "none"))
            return error.Plan9;
        const fd = sys.open("#c/user", sys.OWRITE | sys.OCEXEC);
        if (fd < 0)
            return error.Plan9;
        defer _ = sys.close(fd);
        if (sys.write(fd, "none") != 4)
            return error.Plan9;
    };
}
