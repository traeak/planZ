//! Strings drawn from a Memsubfont.
//! From /sys/src/libmemdraw/string.c.
//!
//! DIFF: the string is a slice; it ends at the slice's end or at a NUL,
//! whichever comes first.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("memdraw.zig");
const lib = @import("../port/lib.zig");
const ldraw = @import("../libmemlayer/draw.zig");

const Point = draw.Point;
const Memimage = memdraw_h.Memimage;
const Memsubfont = memdraw_h.Memsubfont;
const Pt = arith.Pt;
const Rect = arith.Rect;
const memdraw = ldraw.memdraw;

pub fn memimagestring(b: *Memimage, p_: Point, color: *Memimage, cp_: Point, f: *Memsubfont, cs: []const u8) Point {
    var p = p_;
    var cp = cp_;
    var s: usize = 0;
    var width: i32 = 0;

    while (s < cs.len and cs[s] != 0) : ({
        p.x +%= width;
        cp.x +%= width;
    }) {
        var c: u32 = cs[s];
        width = 0;
        if (c < lib.Runeself)
            s += 1
        else {
            const rn = lib.chartorune(cs[s..]);
            c = rn.r;
            if (rn.n == 0) {
                s += 1;
                continue;
            }
            s += rn.n;
        }
        c -%= f.min;
        if (c >= @as(u32, @bitCast(@as(i32, f.n))))
            continue;
        const i = f.info + c;
        width = i[0].width;
        const left: i32 = i[0].left;
        memdraw(b, Rect(p.x +% left, p.y +% i[0].top, p.x +% left +% (i[1].x - i[0].x), p.y +% i[0].bottom), color, cp, f.bits, Pt(i[0].x, i[0].top), draw.SoverD);
    }
    return p;
}

pub fn memsubfontwidth(f: *Memsubfont, cs: []const u8) Point {
    var p = Pt(0, f.height);
    var s: usize = 0;
    var width: i32 = 0;

    while (s < cs.len and cs[s] != 0) : (p.x +%= width) {
        var c: u32 = cs[s];
        width = 0;
        if (c < lib.Runeself)
            s += 1
        else {
            const rn = lib.chartorune(cs[s..]);
            c = rn.r;
            if (rn.n == 0) {
                s += 1;
                continue;
            }
            s += rn.n;
        }
        c -%= f.min;
        if (c >= @as(u32, @bitCast(@as(i32, f.n))))
            continue;
        const i = f.info + c;
        width = i[0].width;
    }
    return p;
}

test "strings, against the C library" {
    const T = @import("line.zig").testing;
    const freememimage = @import("alloc.zig").freememimage;
    const getmemdefont = @import("defont.zig").getmemdefont;
    const freememsubfont = @import("subfont.zig").freememsubfont;
    T.init();
    defer T.deinit();
    var ref = T.Ref.init(want);

    const chans = [_]T.Chan{
        .{ .chan = draw.XRGB32, .name = "x8r8g8b8" },
        .{ .chan = draw.GREY1, .name = "k1" },
        .{ .chan = draw.RGB16, .name = "r5g6b5" },
    };
    for (chans) |ch| {
        const f = getmemdefont().?;
        defer freememsubfont(f);
        const red = T.col(draw.DRed);
        defer freememimage(red);
        const d = T.mk(Rect(0, 0, 160, 40), ch.chan, draw.DWhite);
        defer freememimage(d);
        var p = memimagestring(d, Pt(3, 5), red, draw.ZP, f, "Hello, Plan 9!");
        const q = memsubfontwidth(f, "Hello, Plan 9!");
        ref.line("{s}.string {d} {d} {d} {d}", .{ ch.name, p.x, p.y, q.x, q.y });
        ref.out(ch.name, "string.d", d);
        p = memimagestring(d, Pt(-4, 22), d, Pt(1, 1), f, "{clip} ~\x7f\x01 end of line, far too long to fit");
        ref.line("{s}.string2 {d} {d}", .{ ch.name, p.x, p.y });
        ref.out(ch.name, "string2.d", d);
    }
    try ref.done();
}

test "memsubfontwidth: runes and NUL" {
    const std = @import("std");
    const getmemdefont = @import("defont.zig").getmemdefont;
    const freememsubfont = @import("subfont.zig").freememsubfont;
    const f = getmemdefont().?;
    defer freememsubfont(f);
    // é is in the font (one glyph for two bytes), ☺ is not (no advance)
    try std.testing.expectEqual(@as(i32, 3 * 8), memsubfontwidth(f, "aé☺b").x);
    // the string ends at a NUL
    try std.testing.expectEqual(@as(i32, 2 * 8), memsubfontwidth(f, "ab\x00cd").x);
}

/// What the C program printed (see `testing` in libmemdraw/line.zig).
const want =
    \\x8r8g8b8.string 115 5 112 16
    \\x8r8g8b8.string.d e5cb2c855723422d
    \\x8r8g8b8.string2 340 22
    \\x8r8g8b8.string2.d 8f3d522ada2c4541
    \\k1.string 115 5 112 16
    \\k1.string.d 9f4a54153d04c6fc
    \\k1.string2 340 22
    \\k1.string2.d 6ebed58d45013de7
    \\r5g6b5.string 115 5 112 16
    \\r5g6b5.string.d cfc2de1594282c39
    \\r5g6b5.string2 340 22
    \\r5g6b5.string2.d e9ddda48425962ad
;
