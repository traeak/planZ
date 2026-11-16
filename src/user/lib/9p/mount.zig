//! from lib9p/mount.c, and libauth/amount.c for the mount
//!
//! DIFF:
//!   - amount is here until libauth is ported (step 5), and without
//!     its auth_proxy: a server that answers Tauth (none of this
//!     library's can yet: auth.c is not ported) is mounted with the
//!     authentication file as it is, and refuses the attach.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const p9 = @import("lib9p.zig");

fn amount(fd: i32, mntpt: []const u8, flags: u32, aname: []const u8) isize {
    const afd = sys.fauth(fd, aname);
    const rv = sys.mount(fd, afd, mntpt, flags, aname);
    if (afd >= 0)
        _ = sys.close(afd);
    return rv;
}

/// postsrv, and mount the service on mtpt if one is given.  A failure
/// ends the program.
pub fn postmountsrv(s: *p9.Srv, name: ?[]const u8, mtpt: ?[]const u8, flag: u32) void {
    const sfd = p9.postsrv(s, name) catch libc.sysfatal("postsrv: %r", .{});
    if (mtpt) |m| {
        if (amount(sfd, m, flag, "") < 0)
            libc.sysfatal("mount %s: %r", .{m});
        // mount closed sfd
    } else _ = sys.close(sfd);
}
