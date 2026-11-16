//! from lib9p/mount.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const auth = @import("auth");
const p9 = @import("lib9p.zig");

/// postsrv, and mount the service on mtpt if one is given.  A failure
/// ends the program.
pub fn postmountsrv(s: *p9.Srv, name: ?[]const u8, mtpt: ?[]const u8, flag: u32) void {
    const sfd = p9.postsrv(s, name) catch libc.sysfatal("postsrv: %r", .{});
    if (mtpt) |m| {
        auth.amount(sfd, m, flag, "") catch
            libc.sysfatal("mount %s: %r", .{m});
        // mount closed sfd
    } else _ = sys.close(sfd);
}
