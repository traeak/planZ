//! The file of a font's subfont, for the depth wanted.
//! From /sys/src/libdraw/subfontname.c (9front 11952).
//!
//! Default version: convert to file name
//!
//! DIFF: the name returned is allocated, as in C, and the caller owns
//! it.

const std = @import("std");
const libc = @import("libc");
const D = @import("libdraw.zig");

pub fn subfontname(cfname: []const u8, fname: []const u8, maxdepth_: i32) ?[]u8 {
    const a = libc.allocator;
    var maxdepth = maxdepth_;

    var t = a.dupe(u8, cfname) catch return null; // t is the return string
    if (std.mem.eql(u8, cfname, "*default*"))
        return t;
    if (t.len == 0 or t[0] != '/') {
        const dir = if (std.mem.lastIndexOfScalar(u8, fname, '/')) |u| fname[0..u] else ".";
        const tmp1 = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, t }) catch {
            a.free(t);
            return null;
        };
        a.free(t);
        t = tmp1;
    }

    if (maxdepth > 8)
        maxdepth = 8;

    var i: i32 = 3;
    while (i >= 0) : (i -= 1) {
        if ((@as(i32, 1) << @intCast(i)) > maxdepth)
            continue;
        // try i-bit grey
        const tmp2 = std.fmt.allocPrint(a, "{s}.{d}", .{ t, i }) catch continue;
        if (libc.access(tmp2, libc.AREAD)) {
            a.free(t);
            return tmp2;
        }
        a.free(tmp2);
    }

    // try default
    if (libc.access(t, libc.AREAD))
        return t;

    a.free(t);
    return null;
}
