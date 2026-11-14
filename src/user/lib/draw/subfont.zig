//! Make a Subfont of an image and its character descriptors.
//! From /sys/src/libdraw/subfont.c (9front 11952).
//!
//! DIFF: info is a slice of n+1 entries, which the Subfont owns.

const std = @import("std");
const libc = @import("libc");
const D = @import("libdraw.zig");
const Subfont = D.Subfont;

pub fn allocsubfont(name: ?[]const u8, n: i32, height: i32, ascent: i32, info: []D.Fontchar, i: *D.Image) D.Error!*Subfont {
    std.debug.assert(height != 0); // allocsubfont

    const f = libc.allocator.create(Subfont) catch return D.nomem();
    f.* = .{
        .name = null,
        .n = @truncate(n),
        .height = @truncate(@as(u32, @bitCast(height))),
        .ascent = @truncate(ascent),
        .info = info,
        .bits = i,
        .ref = 1,
    };
    if (name) |nm| {
        f.name = libc.allocator.dupe(u8, nm) catch {
            libc.allocator.destroy(f);
            return D.nomem();
        };
        D.installsubfont(nm, f);
    }
    return f;
}
