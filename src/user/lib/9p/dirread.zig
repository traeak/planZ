//! from lib9p/dirread.c
//!
//! DIFF:
//!   - gen returns a bool: false where the C's returns -1.

const std = @import("std");
const libc = @import("libc");
const p9 = @import("lib9p.zig");
const fcall = libc.fcall;

pub const Dirgen = *const fn (i: i32, d: *p9.Dir, aux: ?*anyopaque) bool;

fn freestr(s: []const u8) void {
    if (s.len != 0)
        libc.allocator.free(s);
}

/// Answer a read of a directory whose entries gen makes.
pub fn dirread9p(r: *p9.Req, gen: Dirgen, aux: ?*anyopaque) void {
    const fid = r.fid.?;
    var start: i32 = if (r.ifcall.offset == 0) 0 else fid.dirindex;

    var p: usize = 0;
    const ep: usize = r.ifcall.count;

    while (p < ep) {
        var d: p9.Dir = .{};
        if (!gen(start, &d, aux))
            break;
        const rv = fcall.convD2M(&d, r.rbuf[p..ep]);
        freestr(d.name);
        freestr(d.muid);
        freestr(d.uid);
        freestr(d.gid);
        if (rv <= fcall.BIT16SZ)
            break;
        p += rv;
        start += 1;
    }
    fid.dirindex = start;
    r.ofcall.count = @intCast(p);
}
