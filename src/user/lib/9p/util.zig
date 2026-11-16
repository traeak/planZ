//! from lib9p/util.c

const std = @import("std");
const p9 = @import("lib9p.zig");

/// Answer a read with the part of s that the offset and count ask for.
pub fn readbuf(r: *p9.Req, s: []const u8) void {
    r.ofcall.count = r.ifcall.count;
    if (r.ifcall.offset >= s.len) {
        r.ofcall.count = 0;
        return;
    }
    const off: usize = @intCast(r.ifcall.offset);
    if (off + r.ofcall.count > s.len)
        r.ofcall.count = @intCast(s.len - off);
    @memcpy(r.rbuf[0..r.ofcall.count], s[off..][0..r.ofcall.count]);
}

pub fn readstr(r: *p9.Req, s: []const u8) void {
    readbuf(r, s);
}
