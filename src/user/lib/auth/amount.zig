//! from libauth/amount.c (amount_getkey.c's variable is in libauth.zig)

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const auth = @import("libauth.zig");

/// Mount the 9P connection fd on mntpt, authenticating first if the
/// server asks for it (p9any, as the client, with factotum's keys).
pub fn amount(fd: i32, mntpt: []const u8, flags: u32, aname: []const u8) libc.Error!void {
    const afd = sys.fauth(fd, aname);
    if (afd >= 0) {
        if (auth.auth_proxy(@intCast(afd), auth.amount_getkey, "proto=p9any role=client", .{})) |ai|
            auth.auth_freeAI(ai)
        else |_| {}
    }
    const rv = sys.mount(fd, afd, mntpt, flags, aname);
    if (afd >= 0)
        _ = sys.close(afd);
    if (rv < 0)
        return error.Plan9;
}
