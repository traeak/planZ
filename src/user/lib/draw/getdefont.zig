//! The built-in font, as a Subfont on the display.
//! From /sys/src/libdraw/getdefont.c (9front 11952).
//!
//! DIFF: the data (the kernel's defont.zig) is aligned to 4, so the
//! C's moving it to a word boundary is left out.

const libc = @import("libc");
const D = @import("libdraw.zig");
const k = @import("drawlib");

pub fn getdefont(d: *D.Display) D.Error!*D.Subfont {
    const data: []const u8 = &k.defont.defontdata;
    var p = data;
    const ld: usize = @intCast(libc.atoi(p[0 * 12 ..]));
    var r: D.Rectangle = undefined;
    r.min.x = @truncate(libc.atoi(p[1 * 12 ..]));
    r.min.y = @truncate(libc.atoi(p[2 * 12 ..]));
    r.max.x = @truncate(libc.atoi(p[3 * 12 ..]));
    r.max.y = @truncate(libc.atoi(p[4 * 12 ..]));

    const i = try D.allocimage(d, r, D.drawld2chan[ld], false, 0);
    errdefer D.freeimage(i) catch {};

    p = p[5 * 12 ..];
    const used = try D.loadimage(i, r, p);

    const hdr = p[used..];
    const n: usize = @intCast(libc.atoi(hdr[0..12]));
    p = hdr[3 * 12 ..];
    const fc = libc.allocator.alloc(D.Fontchar, n + 1) catch return D.nomem();
    errdefer libc.allocator.free(fc);
    D._unpackinfo(fc, p.ptr, @intCast(n));
    return D.allocsubfont("*default*", @intCast(n), @truncate(libc.atoi(hdr[12..24])), @truncate(libc.atoi(hdr[24..36])), fc, i);
}
