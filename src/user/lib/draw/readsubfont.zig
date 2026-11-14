//! Read a subfont: its image, then its character descriptors.
//! From /sys/src/libdraw/readsubfont.c (9front 11952).
//!
//! DIFF: the last argument (dolock) is left out.

const libc = @import("libc");
const D = @import("libdraw.zig");
const Subfont = D.Subfont;

pub fn readsubfonti(d: *D.Display, name: []const u8, fd: i32, ai: ?*D.Image) D.Error!*Subfont {
    var hdr: [3 * 12 + 4 + 1]u8 = undefined;
    const a = libc.allocator;

    const i = ai orelse try D.readimage(d, fd);
    errdefer if (ai == null) D.freeimage(i) catch {};
    if ((libc.readn(fd, hdr[0 .. 3 * 12]) catch 0) != 3 * 12) {
        libc.werrstr("readsubfont: header read error: %r", .{});
        return error.Plan9;
    }
    const n: i64 = libc.atoi(hdr[0 .. 3 * 12]);
    if (n <= 0 or n > 0x7fff) {
        libc.werrstr("readsubfont: bad fontchar count %d", .{n});
        return error.Plan9;
    }
    const un: usize = @intCast(n);
    const p = a.alloc(u8, 6 * (un + 1)) catch return D.nomem();
    defer a.free(p);
    if ((libc.readn(fd, p) catch 0) != p.len) {
        libc.werrstr("readsubfont: fontchar read error: %r", .{});
        return error.Plan9;
    }
    const fc = a.alloc(D.Fontchar, un + 1) catch return D.nomem();
    errdefer a.free(fc);
    D._unpackinfo(fc, p.ptr, @intCast(n));
    return D.allocsubfont(name, @intCast(n), @truncate(libc.atoi(hdr[12 .. 3 * 12])), @truncate(libc.atoi(hdr[24 .. 3 * 12])), fc, i);
}

pub fn readsubfont(d: *D.Display, name: []const u8, fd: i32) D.Error!*Subfont {
    return readsubfonti(d, name, fd, null);
}
