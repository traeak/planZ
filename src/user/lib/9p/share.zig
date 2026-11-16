//! from lib9p/share.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const p9 = @import("lib9p.zig");
const fcall = libc.fcall;

/// postsrv, and put the service in the share mtpt (#σ) under the name
/// desc, if both are given.
pub fn postsharesrv(s: *p9.Srv, name: ?[]const u8, mtpt: ?[]const u8, desc: ?[]const u8) void {
    var buf: [80]u8 = undefined;
    var nb: [16]u8 = undefined;
    var cfd: isize = -1;
    var path: []const u8 = "";

    if (mtpt != null and desc != null) {
        cfd = sys.create(libc.sprint(&buf, "#σc/%s", .{mtpt.?}), sys.OREAD, fcall.DMDIR | 0o700);
        if (cfd >= 0)
            _ = sys.close(cfd);

        path = libc.sprint(&buf, "#σc/%s/%s", .{ mtpt.?, desc.? });
        cfd = sys.create(path, sys.OWRITE | sys.ORCLOSE | sys.OCEXEC, 0o600);
        if (cfd < 0)
            libc.sysfatal("create %s: %r", .{path});
    }

    const sfd = p9.postsrv(s, name) catch libc.sysfatal("postsrv: %r", .{});
    if (cfd >= 0) {
        if (sys.write(cfd, libc.sprint(&nb, "%d\n", .{sfd})) < 0)
            libc.sysfatal("write %s: %r", .{path});
        _ = sys.close(cfd);
    }
    _ = sys.close(sfd);
}
