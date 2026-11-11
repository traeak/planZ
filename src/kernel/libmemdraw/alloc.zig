//! Memimage allocation.
//! From /sys/src/libmemdraw/alloc.c.
//!
//! DIFF:
//!   - The image pool.  The C takes pixel memory from the kernel's
//!     `imagmem` pool (poolalloc/poolfree), a pool that may compact
//!     itself and then calls memimagemove for every block it moved.
//!     planZ has one allocator and it never moves a block, so pixel
//!     memory comes from it (kernel.zig's malloc, port/alloc.zig in the
//!     kernel).  The block layout is kept: Memdata.base points at the
//!     allocation, whose first word points back at the Memdata, then a
//!     32-bit word with the allocator's caller, then the pixels at
//!     Memdata.bdata.  memimagemove is ported and nothing calls it.
//!   - Pixel memory comes back zeroed; poolalloc does not clear.
//!   - allocmemimage asks for one word more than the C does.  draw.c's
//!     readbyte and writebyte go through a 4-byte word for pixels of 2
//!     and 3 bytes, so at the last pixel of an image they read, and
//!     write back unchanged, up to 3 bytes past the pixels.  In C that
//!     lands in the pool's slack; here it would land in the next
//!     block's header, where a write-back could undo a concurrent
//!     change.
//!   - werrstr is kernel.zig's (up.errstr in the kernel).
//!   - byteaddr does its arithmetic on addresses: the intermediate
//!     bdata+zero is outside the allocation for most rectangles.  The
//!     products are computed in the width of an address.  The C
//!     computes them as ints.
//!   - allocmemimaged refuses a rectangle for which Memimage.zero, the
//!     offset of pixel (0,0), does not fit its int.  badrect is meant
//!     to guarantee that (see the comment there) but allows for a scan
//!     line of Dx(r) words, and a line of 24-bit pixels that does not
//!     start on a word boundary takes a word more: for
//!     Rect(2^25-3, 2^28-1, 2^25-2, 2^28) and r8g8b8 the C's sum
//!     overflows, zero is off by 2^32, and every address byteaddr
//!     gives for the image is 4GB from its pixels.
//!   - memsetchan clears shift, mask and nbits before it fills them
//!     in.  The C fills in the channels of the new format and leaves
//!     the others as they were, and draw.c chooses how to read an
//!     image by looking at nbits[CMap] alone.  memlalloc keeps one
//!     image, `paint`, that it re-formats with memsetchan for every
//!     window it makes.  Once a window has been made on a screen with
//!     a colour map channel, paint is read as colour map indices on
//!     every other screen whenever it is read a pixel at a time, which
//!     is when the screen's format has alpha and the window's colour
//!     is not opaque (otherwise it is a memset): the wrong colour,
//!     and where the pixel sizes disagree the reader runs off the end
//!     of paint's one pixel.
//!   - memsetchan: the C's `t < 0` test is gone (t is unsigned here),
//!     and so is `i->cmap == nil` (cmap is not optional; an image
//!     always has one, see the comment there).

const std = @import("std");
const draw = @import("../libdraw/draw.zig");
const memdraw = @import("memdraw.zig");
const kernel = @import("kernel.zig");
const chantodepth = @import("../libdraw/chan.zig").chantodepth;
const badrect = @import("../libdraw/badrect.zig").badrect;
const wordsperline = @import("../libdraw/bytesperline.zig").wordsperline;

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw.Memimage;
const Memdata = memdraw.Memdata;
const Dx = draw.Dx;
const Dy = draw.Dy;
const werrstr = kernel.werrstr;

pub fn memimagemove(from: *anyopaque, to: *anyopaque) void {
    const md: *Memdata = @as(**Memdata, @ptrCast(@alignCast(to))).*;
    if (@as(?*anyopaque, @ptrCast(md.base)) != from) {
        @panic("compacted data not right");
    }
    md.base = @ptrCast(@alignCast(to));

    // if allocmemimage changes this must change too
    md.bdata = @as([*]u8, @ptrCast(md.base.?)) + @sizeOf(*Memdata) + @sizeOf(u32);
}

pub fn allocmemimaged(r: Rectangle, chan: u32, md: *Memdata) ?*Memimage {
    const d = chantodepth(chan);
    if (d == 0) {
        werrstr("bad channel descriptor %.8lux", .{chan});
        return null;
    }
    if (badrect(r)) {
        werrstr("bad rectangle %R", .{r});
        return null;
    }

    // DIFF: the offset of pixel (0,0) must fit, see the header
    const width = wordsperline(r, d);
    const zero: i64 = @as(i64, r.min.y) * (@sizeOf(u32) * @as(i64, width)) + ((@as(i64, r.min.x) * d) >> 3);
    if (width <= 0 or zero <= std.math.minInt(i32) or zero > std.math.maxInt(i32)) {
        werrstr("bad rectangle %R, depth %d", .{ r, d });
        return null;
    }

    const i = kernel.new(Memimage) orelse return null;

    i.data = md;
    i.width = @intCast(width);
    i.zero = @intCast(-zero);

    i.r = r;
    i.clipr = r;
    i.flags = if (Dx(r) == 1 and Dy(r) == 1) memdraw.Fsimple else 0;
    i.layer = null;
    i.cmap = memdraw.memdefcmap;
    if (memsetchan(i, chan) < 0) {
        kernel.free(i);
        return null;
    }
    return i;
}

pub fn allocmemimage(r: Rectangle, chan: u32) ?*Memimage {
    const d = chantodepth(chan);
    if (d == 0) {
        werrstr("bad channel descriptor %.8lux", .{chan});
        return null;
    }
    if (badrect(r)) {
        werrstr("bad rectangle %R", .{r});
        return null;
    }
    const nw: u64 = @as(u64, @intCast(wordsperline(r, d))) * @as(u64, @intCast(Dy(r)));
    if (nw >= ((1 << 31) - @sizeOf(*Memdata) - @sizeOf(u32)) / @sizeOf(u32)) {
        werrstr("bad rectangle %R, depth %d", .{ r, d });
        return null;
    }

    const md = kernel.new(Memdata) orelse return null;

    md.ref = 1;
    // DIFF: one more word than the C asks for, see the header.
    const base = kernel.malloc(@sizeOf(*Memdata) + (1 + @as(usize, @intCast(nw)) + 1) * @sizeOf(u32)) orelse {
        kernel.free(md);
        return null;
    };
    md.base = @ptrCast(@alignCast(base));

    var p: [*]u8 = base;
    @as(**Memdata, @ptrCast(@alignCast(p))).* = md;
    p += @sizeOf(*Memdata);

    @as(*u32, @ptrCast(@alignCast(p))).* = @truncate(@returnAddress());
    p += @sizeOf(u32);

    // if this changes, memimagemove must change too
    md.bdata = p;
    md.allocd = true;

    const i = allocmemimaged(r, chan, md) orelse {
        kernel.free(md.base);
        kernel.free(md);
        return null;
    };
    md.imref = i;
    return i;
}

pub fn freememimage(i_: ?*Memimage) void {
    const i = i_ orelse return;
    i.data.ref -= 1;
    if (i.data.ref == 0 and i.data.allocd) {
        if (i.data.base) |b|
            kernel.free(b);
        kernel.free(i.data);
    }
    kernel.free(i);
}

//
// Wordaddr is deprecated.
//
pub fn wordaddr(i: *Memimage, p: Point) [*]u32 {
    return @ptrFromInt(@intFromPtr(byteaddr(i, p)) & ~@as(usize, @sizeOf(u32) - 1));
}

pub fn byteaddr(i: *Memimage, p: Point) [*]u8 {
    const off: isize = @as(isize, i.zero) +
        @as(isize, p.y) * @as(isize, @intCast(@sizeOf(u32) * i.width)) + ((@as(isize, p.x) * i.depth) >> 3);
    return @ptrFromInt(@intFromPtr(i.data.bdata) +% @as(usize, @bitCast(off)));
}

pub fn memsetchan(i: *Memimage, chan: u32) i32 {
    const d = chantodepth(chan);
    if (d == 0) {
        werrstr("bad channel descriptor", .{});
        return -1;
    }

    i.depth = d;
    i.chan = chan;
    i.flags &= ~(memdraw.Fgrey | memdraw.Falpha | memdraw.Fcmap | memdraw.Fbytes);
    // DIFF: forget the channels of the format the image had, see the header
    i.shift = @splat(0);
    i.mask = @splat(0);
    i.nbits = @splat(0);
    var bytes = true;
    var usedt: u32 = 0;
    var cc = chan;
    var j: i32 = 0;
    var k: i32 = 0;
    while (cc != 0) : ({
        j += @intCast(draw.NBITS(cc));
        cc >>= 8;
        k += 1;
    }) {
        const t = draw.TYPE(cc);
        if (t >= draw.NChan or (t != draw.CIgnore and usedt & (@as(u32, 1) << @intCast(t)) != 0)) {
            werrstr("bad channel string", .{});
            return -1;
        }
        if (t == draw.CGrey)
            i.flags |= memdraw.Fgrey;
        if (t == draw.CAlpha)
            i.flags |= memdraw.Falpha;
        // DIFF: the C sets Fcmap (and the default cmap) only when
        // i->cmap is nil, which it never is after allocmemimaged, so
        // Fcmap is never set there either.

        i.shift[t] = j;
        i.mask[t] = (@as(u32, 1) << @intCast(draw.NBITS(cc))) - 1;
        i.nbits[t] = @intCast(draw.NBITS(cc));
        usedt |= @as(u32, 1) << @intCast(t);
        if (draw.NBITS(cc) != 8)
            bytes = false;
    }
    i.nchan = k;
    if (bytes)
        i.flags |= memdraw.Fbytes;
    return 0;
}

test "allocmemimage" {
    const t = std.testing;
    const r: Rectangle = .{ .min = .{ .x = 3, .y = 5 }, .max = .{ .x = 20, .y = 9 } };

    const i = allocmemimage(r, draw.RGB16).?;
    defer freememimage(i);
    try t.expectEqual(@as(i32, 16), i.depth);
    try t.expectEqual(@as(i32, 3), i.nchan);
    try t.expectEqual(@as(u32, 9), i.width); // words: bits 48..320
    try t.expectEqual(@as(u32, 0), i.flags);
    try t.expectEqual(@as(i32, 11), i.shift[draw.CRed]);
    try t.expectEqual(@as(i32, 5), i.shift[draw.CGreen]);
    try t.expectEqual(@as(u32, 0x3F), i.mask[draw.CGreen]);
    try t.expectEqual(@as(i32, 5), i.nbits[draw.CBlue]);
    // the first word of the allocation points back at the Memdata
    try t.expect(@as(**Memdata, @ptrCast(@alignCast(i.data.base.?))).* == i.data);
    try t.expect(i.data.bdata == @as([*]u8, @ptrCast(i.data.base.?)) + 12);
    // r.min is the first pixel of the data
    try t.expect(byteaddr(i, .{ .x = 3, .y = 5 }) == i.data.bdata);
    try t.expect(@intFromPtr(wordaddr(i, .{ .x = 4, .y = 5 })) == @intFromPtr(i.data.bdata));
    try t.expect(byteaddr(i, .{ .x = 4, .y = 6 }) == i.data.bdata + 36 + 2);

    // a window onto the same data
    const w = allocmemimaged(r, draw.RGB16, i.data).?;
    i.data.ref += 1;
    freememimage(w);
    try t.expectEqual(@as(i32, 1), i.data.ref);

    const g = allocmemimage(.{ .min = .{}, .max = .{ .x = 1, .y = 1 } }, draw.GREY8).?;
    defer freememimage(g);
    try t.expectEqual(memdraw.Fsimple | memdraw.Fgrey | memdraw.Fbytes, g.flags);
    const a = allocmemimage(r, draw.RGBA32).?;
    defer freememimage(a);
    try t.expectEqual(memdraw.Falpha | memdraw.Fbytes, a.flags);

    try t.expect(allocmemimage(r, 0x1234) == null);
    try t.expect(allocmemimage(.{}, draw.GREY1) == null);
}
