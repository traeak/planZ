//! from lib9p/uid.c

const std = @import("std");
const p9 = @import("lib9p.zig");

/// simplistic permission checking.  assume that
/// each user is the leader of her own group.
pub fn hasperm(f: *p9.File, uid: []const u8, p: u32) bool {
    var m = f.d.mode & 7; // other
    if ((p & m) == p)
        return true;

    if (std.mem.eql(u8, f.d.uid, uid)) {
        m |= (f.d.mode >> 6) & 7;
        if ((p & m) == p)
            return true;
    }

    if (std.mem.eql(u8, f.d.gid, uid)) {
        m |= (f.d.mode >> 3) & 7;
        if ((p & m) == p)
            return true;
    }

    return false;
}
