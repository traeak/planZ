//! getmemdefont: the built-in font as a Memsubfont.
//! From /sys/src/libmemdraw/defont.c.
//!
//! DIFF:
//!   - libdraw/defont.zig aligns the data, so the C's memmove to
//!     word-align it is gone.
//!   - When allocating the Fontchars fails the C frees the image but
//!     leaks nothing else; the same here.

const draw = @import("../libdraw/draw.zig");
const memdraw = @import("memdraw.zig");
const kernel = @import("kernel.zig");
const ldefont = @import("../libdraw/defont.zig");
const drawld2chan = @import("../libdraw/arith.zig").drawld2chan;
const alloc = @import("alloc.zig");
const subfont = @import("subfont.zig");

const Fontchar = draw.Fontchar;
const Rectangle = draw.Rectangle;
const Memdata = memdraw.Memdata;
const Memsubfont = memdraw.Memsubfont;
const Dy = draw.Dy;

/// atoi of one 12-byte header field.
fn atoi(p: [*]const u8) i32 {
    var i: usize = 0;
    while (p[i] == ' ' or p[i] == '\t') i += 1;
    var neg = false;
    if (p[i] == '-' or p[i] == '+') {
        neg = p[i] == '-';
        i += 1;
    }
    var n: i32 = 0;
    while (p[i] >= '0' and p[i] <= '9') : (i += 1)
        n = n * 10 + (p[i] - '0');
    return if (neg) -n else n;
}

pub fn getmemdefont() ?*Memsubfont {
    var r: Rectangle = undefined;

    //
    // make sure data is word-aligned.  this is true with Plan 9 compilers
    // but not in general.  the byte order is right because the data is
    // declared as char*, not ulong*.
    //
    var p: [*]u8 = &ldefont.defontdata;
    const ld: usize = @intCast(atoi(p + 0 * 12));
    r.min.x = atoi(p + 1 * 12);
    r.min.y = atoi(p + 2 * 12);
    r.max.x = atoi(p + 3 * 12);
    r.max.y = atoi(p + 4 * 12);

    const md = kernel.new(Memdata) orelse return null;

    p += 5 * 12;

    md.base = null; // so freememimage doesn't free p
    md.bdata = p; // ick
    md.ref = 1;
    md.allocd = true; // so freememimage does free md

    const i = alloc.allocmemimaged(r, drawld2chan[ld], md) orelse {
        kernel.free(md);
        return null;
    };

    const hdr = p + @as(usize, @intCast(Dy(r))) * i.width * @sizeOf(u32);
    const n = atoi(hdr);
    p = hdr + 3 * 12;
    const fc = kernel.newslice(Fontchar, @intCast(n + 1)) orelse {
        alloc.freememimage(i);
        return null;
    };
    ldefont._unpackinfo(fc, p, n);
    const f = subfont.allocmemsubfont("*default*", n, atoi(hdr + 12), atoi(hdr + 24), fc.ptr, i) orelse {
        alloc.freememimage(i);
        kernel.free(fc);
        return null;
    };
    return f;
}

test "getmemdefont" {
    const std = @import("std");
    const t = std.testing;
    const f = getmemdefont().?;
    defer subfont.freememsubfont(f);
    try t.expectEqualStrings("*default*", f.name.?);
    try t.expectEqual(@as(i16, 256), f.n);
    try t.expectEqual(@as(u8, 16), f.height);
    try t.expectEqual(@as(i32, 1), f.bits.depth);
    try t.expectEqual(@as(i32, 16), draw.Dy(f.bits.r));
    // fixed width: every character is 8 wide and they sit side by side
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        try t.expectEqual(@as(u8, 8), f.info[c].width);
        try t.expectEqual(@as(i32, @intCast(8 * c)), f.info[c].x);
    }
    try t.expectEqual(@as(i32, 2048), f.info[256].x);
    // 'I' has ink, ' ' has none
    const pixelbits = @import("draw.zig").pixelbits;
    var ink: u32 = 0;
    var blank: u32 = 0;
    var y: i32 = 0;
    while (y < 16) : (y += 1) {
        var x: i32 = 0;
        while (x < 8) : (x += 1) {
            ink += pixelbits(f.bits, .{ .x = 'I' * 8 + x, .y = y }) & 1;
            blank += pixelbits(f.bits, .{ .x = ' ' * 8 + x, .y = y }) & 1;
        }
    }
    try t.expect(ink > 0 and blank == 0);
}
