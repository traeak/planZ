//! from libauth/auth_getkey.c

const std = @import("std");
const libc = @import("libc");

/// Have factotum ask the user for the key that params describes
/// (factotum -g, on the console).  False if there is no factotum to
/// run or it failed.
pub fn auth_getkey(params: []const u8) bool {
    // start /factotum to query for a key
    var name: []const u8 = "/factotum";
    if (!exists(name)) {
        name = "/boot/factotum";
        if (!exists(name)) {
            libc.werrstr("auth_getkey: no /factotum or /boot/factotum: didn't get key %s", .{params});
            return false;
        }
    }
    const pid = libc.fork() catch {
        libc.werrstr("can't fork for %s: %r", .{name});
        return false;
    };
    if (pid == 0) {
        _ = libc.exec(name, &.{ "getkey", "-g", params }) catch {};
        libc.exits(null);
    }
    while (true) {
        const w = libc.wait() catch break;
        if (w.pid == pid)
            return w.msg().len == 0;
    }
    return true;
}

fn exists(name: []const u8) bool {
    var st = libc.dirstat(libc.allocator, name) catch return false;
    st.deinit(libc.allocator);
    return true;
}
