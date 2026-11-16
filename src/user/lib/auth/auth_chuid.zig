//! from libauth/auth_chuid.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const auth = @import("libauth.zig");

/// become the authenticated user
pub fn auth_chuid(ai_: ?*auth.AuthInfo, ns: ?[]const u8) libc.Error!void {
    const ai = ai_ orelse {
        libc.werrstr("no capability", .{});
        return error.Plan9;
    };
    if (ai.cap.len == 0) {
        libc.werrstr("no capability", .{});
        return error.Plan9;
    }

    // change uid
    var fd = sys.open("/dev/capuse", sys.OCEXEC | sys.OWRITE);
    if (fd < 0) {
        libc.werrstr("opening /dev/capuse: %r", .{});
        return error.Plan9;
    }
    const rv = sys.write(fd, ai.cap);
    _ = sys.close(fd);
    if (rv < 0) {
        libc.werrstr("writing %s to /dev/capuse: %r", .{ai.cap});
        return error.Plan9;
    }

    // get a link to factotum as new user
    fd = sys.open("/srv/factotum", sys.ORDWR);
    if (fd >= 0) {
        if (sys.mount(fd, -1, "/mnt", sys.MREPL, "") < 0)
            _ = sys.close(fd);
    }

    // set up new namespace
    return auth.newns(ai.cuid, ns);
}
