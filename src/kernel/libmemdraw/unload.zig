//! unloadmemimage: copy an image's pixels out as packed data.
//! From /sys/src/libmemdraw/unload.c.
//!
//! DIFF: the buffer is a slice.

const draw = @import("../libdraw/draw.zig");
const memdraw = @import("memdraw.zig");
const kernel = @import("kernel.zig");
const badrect = @import("../libdraw/badrect.zig").badrect;
const rectinrect = @import("../libdraw/arith.zig").rectinrect;
const bytesperline = @import("../libdraw/bytesperline.zig").bytesperline;
const byteaddr = @import("alloc.zig").byteaddr;

const Rectangle = draw.Rectangle;
const Memimage = memdraw.Memimage;
const Dy = draw.Dy;
const werrstr = kernel.werrstr;

pub fn unloadmemimage(i: *Memimage, r: Rectangle, data_: []u8) i32 {
    var data = data_.ptr;

    if (badrect(r) or !rectinrect(r, i.r)) {
        werrstr("unloadmemimage: bad rectangle", .{});
        return -1;
    }
    const l: usize = @intCast(bytesperline(r, i.depth));
    const dy: usize = @intCast(Dy(r));
    if (data_.len < l * dy) {
        werrstr("unloadmemimage: buffer too small", .{});
        return -1;
    }
    const ndata: i32 = @intCast(l * dy);
    var q = byteaddr(i, r.min);
    var y = r.min.y;
    while (y < r.max.y) : (y += 1) {
        @memmove(data[0..l], q[0..l]);
        q += i.width * @sizeOf(u32);
        data += l;
    }
    return ndata;
}

test "loadmemimage, unloadmemimage" {
    const std = @import("std");
    const t = std.testing;
    const alloc = @import("alloc.zig");
    const loadmemimage = @import("load.zig").loadmemimage;
    const R = struct {
        fn f(a: i32, b: i32, c: i32, d: i32) Rectangle {
            return .{ .min = .{ .x = a, .y = b }, .max = .{ .x = c, .y = d } };
        }
    }.f;
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    const chans = [_]u32{ draw.GREY1, draw.GREY2, draw.GREY4, draw.GREY8, draw.RGB16, draw.RGB24, draw.XRGB32 };
    var in: [1024]u8 = undefined;
    var out: [1024]u8 = undefined;
    var before: [2048]u8 = undefined;
    var after: [2048]u8 = undefined;
    for (chans) |chan| {
        const ir = R(-5, -3, 30, 9);
        const i = alloc.allocmemimage(ir, chan).?;
        defer alloc.freememimage(i);
        var iter: usize = 0;
        while (iter < 200) : (iter += 1) {
            const x0 = rnd.intRangeLessThan(i32, ir.min.x, ir.max.x);
            const y0 = rnd.intRangeLessThan(i32, ir.min.y, ir.max.y);
            const r = R(x0, y0, rnd.intRangeAtMost(i32, x0 + 1, ir.max.x), rnd.intRangeAtMost(i32, y0 + 1, ir.max.y));
            const n: usize = @intCast(bytesperline(r, i.depth) * Dy(r));
            rnd.bytes(in[0..n]);
            // fill the image with noise and remember it
            const all: usize = @intCast(bytesperline(ir, i.depth) * Dy(ir));
            rnd.bytes(before[0..all]);
            try t.expectEqual(@as(i32, @intCast(all)), loadmemimage(i, ir, before[0..all]));

            try t.expectEqual(@as(i32, @intCast(n)), loadmemimage(i, r, in[0..n]));
            try t.expectEqual(@as(i32, -1), loadmemimage(i, r, in[0 .. n - 1]));
            try t.expectEqual(@as(i32, @intCast(n)), unloadmemimage(i, r, out[0..n]));
            try t.expectEqual(@as(i32, @intCast(all)), unloadmemimage(i, ir, after[0..all]));

            // every pixel inside r comes from `in`, every pixel
            // outside is what it was
            const d: usize = @intCast(i.depth);
            const bpl: usize = @intCast(bytesperline(ir, i.depth));
            const rbpl: usize = @intCast(bytesperline(r, i.depth));
            var y = ir.min.y;
            while (y < ir.max.y) : (y += 1) {
                var x = ir.min.x;
                while (x < ir.max.x) : (x += 1) {
                    // bit offset of the pixel in a packed line
                    const got = getpix(after[@as(usize, @intCast(y - ir.min.y)) * bpl ..], ir.min.x, x, d);
                    const inside = x >= r.min.x and x < r.max.x and y >= r.min.y and y < r.max.y;
                    const want = if (inside)
                        getpix(in[@as(usize, @intCast(y - r.min.y)) * rbpl ..], r.min.x, x, d)
                    else
                        getpix(before[@as(usize, @intCast(y - ir.min.y)) * bpl ..], ir.min.x, x, d);
                    try t.expectEqual(want, got);
                    if (inside)
                        try t.expectEqual(want, getpix(out[@as(usize, @intCast(y - r.min.y)) * rbpl ..], r.min.x, x, d));
                }
            }
        }
        try t.expectEqual(@as(i32, -1), loadmemimage(i, R(-6, 0, 3, 3), &in));
        try t.expectEqual(@as(i32, -1), unloadmemimage(i, R(0, 0, 3, 10), &out));
    }
}

/// Pixel x of a packed scan line whose first byte holds pixel
/// (minx rounded down to a byte); test helper.
fn getpix(line: []const u8, minx: i32, x: i32, d: usize) u32 {
    const ppb: i32 = if (d < 8) @intCast(8 / d) else 1;
    const first: i32 = if (d < 8) minx & ~(ppb - 1) else minx;
    const idx: usize = @intCast(x - first);
    if (d < 8) {
        const b = line[idx * d / 8];
        const sh: u3 = @intCast(8 - d - (idx * d) % 8);
        return (b >> sh) & ((@as(u8, 1) << @intCast(d)) - 1);
    }
    var v: u32 = 0;
    var k: usize = 0;
    while (k < d / 8) : (k += 1)
        v |= @as(u32, line[idx * d / 8 + k]) << @intCast(8 * k);
    return v;
}
