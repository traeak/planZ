//! Filled polygons on a Memimage, by scan conversion.
//! From /sys/src/libmemdraw/fillpoly.c.
//!
//! DIFF:
//!   - The vertices are a slice; `detail` is bool.
//!   - The table of segment pointers is a slice walked with indices
//!     where the C walks it with pointers; its nil terminator is kept.
//!   - qsort is std.sort.heap (in place, no stack to speak of).  Neither
//!     is stable, so segments that compare equal may come out in another
//!     order than the C's; the fill does not depend on it.
//!   - xscan walks only the scan lines of dst.r, and yscan only its
//!     columns.  The C walks every scan line of the polygon that is
//!     inside dst->clipr, and devdraw lets a program set any clipr
//!     (and a replicated image has a huge one), so one 'P' message
//!     with a polygon 2^31 lines tall kept the kernel in this loop,
//!     holding the draw lock, for a minute.  Nothing is drawn outside
//!     dst.r either way.  A segment met at the image's first line is
//!     given the values the C's walk would have reached there (see
//!     `enter`), so the pixels are the C's.  (The C's own limit, clipr
//!     shifted left by fixshift, is kept with its overflow: on an
//!     image whose clipr reaches past 2^21 it draws what the C draws.)  The passes of
//!     both loops are also counted against the image's size, for the
//!     coordinates that wrap: a window moved with 'o' can have any r.
//!   - mod, sdiv and smuldivmod divide in 64 bits so that no pair of
//!     operands can trap, and the other arithmetic wraps, as C's does
//!     in practice: the vertices come from user programs through
//!     devdraw.

const std = @import("std");
const draw = @import("../libdraw/draw.zig");
const memdraw_h = @import("memdraw.zig");
const kernel = @import("kernel.zig");
const ldraw = @import("../libmemlayer/draw.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const memdraw = ldraw.memdraw;

/// Host tests: whether a complaint of the scan converter is a failure.
/// The fuzz test turns it off; coordinates that overflow the fixed
/// point arithmetic earn the complaints honestly.
pub var loud = true;

fn print(comptime format: []const u8, args: anytype) void {
    if (kernel.hosted) {
        // host tests: these messages mean a bug; make them fail loudly
        if (loud)
            @panic(format);
    } else {
        @import("../port/print.zig").print(format, args);
    }
}

const Seg = struct {
    p0: Point,
    p1: Point,
    num: i32,
    den: i32,
    dz: i32,
    dzrem: i32,
    z: i32,
    zerr: i32,
    d: i32,
};

fn fillline(dst: *Memimage, left: i32, right: i32, y: i32, src: *Memimage, p_: Point, op: i32) void {
    var p = p_;
    var r: Rectangle = undefined;

    r.min.x = left;
    r.min.y = y;
    r.max.x = right;
    r.max.y = y +% 1;
    p.x +%= left;
    p.y +%= y;
    memdraw(dst, r, src, p, memdraw_h.memopaque, p, op);
}

fn fillpoint(dst: *Memimage, x: i32, y: i32, src: *Memimage, p_: Point, op: i32) void {
    var p = p_;
    var r: Rectangle = undefined;

    r.min.x = x;
    r.min.y = y;
    r.max.x = x +% 1;
    r.max.y = y +% 1;
    p.x +%= x;
    p.y +%= y;
    memdraw(dst, r, src, p, memdraw_h.memopaque, p, op);
}

pub fn memfillpoly(dst: *Memimage, vert: []const Point, w: i32, src: *Memimage, sp: Point, op: i32) void {
    _memfillpolysc(dst, vert, w, src, sp, false, 0, op);
}

pub fn _memfillpolysc(dst: *Memimage, vert: []const Point, w: i32, src: *Memimage, sp_: Point, detail: bool, fixshift_: i32, op: i32) void {
    var sp = sp_;
    var fixshift = fixshift_;
    const nvert = vert.len;

    if (nvert <= 0)
        return;

    const seg = kernel.newslice(?*Seg, nvert + 2) orelse return;
    defer kernel.free(seg);
    const segtab = kernel.newslice(Seg, nvert + 1) orelse return;
    defer kernel.free(segtab);

    sp.x = (sp.x -% vert[0].x) >> @intCast(fixshift);
    sp.y = (sp.y -% vert[0].y) >> @intCast(fixshift);
    var p0 = vert[nvert - 1];
    if (fixshift == 0) {
        p0.x <<= 1;
        p0.y <<= 1;
    }
    for (0..nvert) |i| {
        segtab[i].p0 = p0;
        p0 = vert[i];
        if (fixshift == 0) {
            p0.x <<= 1;
            p0.y <<= 1;
        }
        segtab[i].p1 = p0;
        segtab[i].d = 1;
    }
    if (fixshift == 0)
        fixshift = 1;

    xscan(dst, seg, segtab, nvert, w, src, sp, detail, fixshift, op);
    if (detail)
        yscan(dst, seg, segtab, nvert, w, src, sp, fixshift, op);
}

fn mod(x: i32, y: i32) i32 {
    const z: i32 = @truncate(@rem(@as(i64, x), @as(i64, y)));
    if ((z ^ y) > 0 or z == 0)
        return z;
    return z +% y;
}

fn sdiv(x: i32, y: i32) i32 {
    if ((x ^ y) >= 0 or x == 0)
        return @truncate(@divTrunc(@as(i64, x), @as(i64, y)));

    return @truncate(@divTrunc(@as(i64, x +% ((y >> 30) | 1)), @as(i64, y)) - 1);
}

fn smuldivmod(x: i32, y: i32, z: i32, modp: *i32) i32 {
    if (x == 0 or y == 0) {
        modp.* = 0;
        return 0;
    }
    var vx: i64 = x;
    vx *= y;
    modp.* = @truncate(@rem(vx, @as(i64, z)));
    if (modp.* < 0)
        modp.* +%= z; // z is always >0
    if ((vx < 0) == (z < 0))
        return @truncate(@divTrunc(vx, @as(i64, z)));
    return @truncate(-@divTrunc(-vx, @as(i64, z)));
}

/// v << shift, held at the ends of 32 bits instead of wrapping.
fn satshl(v: i32, shift: u5) i32 {
    const x = @as(i64, v) << shift;
    return @intCast(std.math.clamp(x, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// Start following segment s at scan line y (xscan; a column for
/// yscan): set s.z and s.zerr, the cross coordinate there and its
/// remainder.  z0 and t0 are the cross and the scan coordinate of the
/// segment's first point, c0 is the scan line at which the C begins its
/// walk.
///
/// The C computes z where it first meets the segment, at the first
/// scan line past t0 or at c0, with smuldivmod, and from there adds dz
/// and dzrem a line at a time.  smuldivmod rounds a negative quotient
/// towards zero while keeping a positive remainder, so what it gives
/// is one more than the steps would have given, unless the division
/// is exact: the pixels depend on where a segment is first met.  When
/// xscan begins at the image's first line instead (see the header),
/// this gives the segment the values the C's walk would have brought
/// to line y: the C's first value, and the steps from there in one go.
fn enter(s: *Seg, z0: i32, t0: i32, c0: i32, y: i32, fixshift: u5, onehalf: i32) void {
    var first = ((((t0 -% onehalf) >> fixshift) +% 1) << fixshift) +% onehalf;
    if (first < c0)
        first = c0;
    if (first > y)
        first = y;
    s.z = z0;
    s.z +%= smuldivmod(first -% t0, s.num, s.den, &s.zerr);
    const k: i64 = (@as(i64, y) - first) >> fixshift;
    if (k <= 0 or s.den <= 0)
        return;
    const e: i64 = s.zerr +% k *% s.dzrem;
    s.z +%= @truncate(k *% s.dz +% @divFloor(e, s.den));
    s.zerr = @truncate(@mod(e, s.den));
}

fn xscan(dst: *Memimage, seg: []?*Seg, segtab: []Seg, nseg: usize, wind: i32, src: *Memimage, sp: Point, detail: bool, fixshift_: i32, op: i32) void {
    const fixshift: u5 = @intCast(fixshift_);
    var p: usize = 0;

    for (segtab[0..nseg]) |*s| {
        seg[p] = s;
        if (s.p0.y == s.p1.y)
            continue;
        if (s.p0.y > s.p1.y) {
            const pt = s.p0;
            s.p0 = s.p1;
            s.p1 = pt;
            s.d = -s.d;
        }
        s.num = s.p1.x -% s.p0.x;
        s.den = s.p1.y -% s.p0.y;
        s.dz = sdiv(s.num, s.den) << fixshift;
        s.dzrem = mod(s.num, s.den) << fixshift;
        s.dz +%= sdiv(s.dzrem, s.den);
        s.dzrem = mod(s.dzrem, s.den);
        p += 1;
    }
    const n = p;
    if (n == 0)
        return;
    seg[p] = null;
    std.sort.heap(?*Seg, seg[0..n], {}, ycompare);

    var onehalf: i32 = 0;
    if (fixshift != 0)
        onehalf = @as(i32, 1) << (fixshift - 1);

    const minx = dst.clipr.min.x;
    const maxx = dst.clipr.max.x;

    var y = seg[0].?.p0.y;
    if (y < (dst.clipr.min.y << fixshift))
        y = dst.clipr.min.y << fixshift;
    var iy = (y +% onehalf) >> fixshift;
    y = (iy << fixshift) +% onehalf;
    var maxy = dst.clipr.max.y << fixshift;
    // DIFF: only the scan lines of the image, see the header.  y0 is
    // where the C starts.
    const y0 = y;
    if (@as(i64, y0) < (@as(i64, dst.r.min.y) << fixshift) + onehalf) {
        if (dst.r.min.y != satshl(dst.r.min.y, fixshift) >> fixshift)
            return;
        iy = dst.r.min.y;
        y = (iy << fixshift) +% onehalf;
    }
    if (maxy > satshl(dst.r.max.y, fixshift))
        maxy = satshl(dst.r.max.y, fixshift);

    var ep: usize = 0;
    var next: usize = 0;

    // DIFF: at most a pass for each scan line of the image and one
    // for each segment skipped to, whatever the arithmetic wrapped to
    var passes: i64 = @as(i64, dst.r.max.y) - dst.r.min.y + @as(i64, @intCast(nseg)) + 2;
    while (y < maxy) {
        passes -= 1;
        if (passes < 0)
            break;
        var q: usize = 0;
        p = 0;
        while (p < ep) : (p += 1) {
            const s = seg[p].?;
            if (s.p1.y < y)
                continue;
            s.z +%= s.dz;
            s.zerr +%= s.dzrem;
            if (s.zerr >= s.den) {
                s.z +%= 1;
                s.zerr -%= s.den;
                if (s.zerr < 0 or s.zerr >= s.den)
                    print("bad ratzerr1: %d den %d dzrem %d\n", .{ s.zerr, s.den, s.dzrem });
            }
            seg[q] = s;
            q += 1;
        }

        p = next;
        while (seg[p]) |s| : (p += 1) {
            if (s.p0.y >= y)
                break;
            if (s.p1.y < y)
                continue;
            enter(s, s.p0.x, s.p0.y, y0, y, fixshift, onehalf);
            if (s.zerr < 0 or s.zerr >= s.den)
                print("bad ratzerr2: %d den %d ratdzrem %d\n", .{ s.zerr, s.den, s.dzrem });
            seg[q] = s;
            q += 1;
        }
        ep = q;
        next = p;

        if (ep == 0) {
            const nx = seg[next] orelse break;
            iy = (nx.p0.y +% onehalf) >> fixshift;
            y = (iy << fixshift) +% onehalf;
            continue;
        }

        zsort(seg[0..ep]);

        p = 0;
        while (p < ep) : (p += 1) {
            var cnt: i32 = 0;
            var x = seg[p].?.z;
            const xerr = seg[p].?.zerr;
            const xden = seg[p].?.den;
            var ix = (x +% onehalf) >> fixshift;
            if (ix >= maxx)
                break;
            if (ix < minx)
                ix = minx;
            cnt +%= seg[p].?.d;
            p += 1;
            while (true) {
                if (p == ep) {
                    print("xscan: fill to infinity", .{});
                    return;
                }
                cnt +%= seg[p].?.d;
                if ((cnt & wind) == 0)
                    break;
                p += 1;
            }
            const s = seg[p].?;
            const x2 = s.z;
            var ix2 = (x2 +% onehalf) >> fixshift;
            if (ix2 <= minx)
                continue;
            if (ix2 > maxx)
                ix2 = maxx;
            if (ix == ix2 and detail) {
                if (xerr *% s.den +% s.zerr *% xden > s.den *% xden)
                    x +%= 1;
                ix = (x +% x2) >> (fixshift + 1);
                ix2 = ix +% 1;
            }
            fillline(dst, ix, ix2, iy, src, sp, op);
        }
        y +%= @as(i32, 1) << fixshift;
        iy +%= 1;
    }
}

fn yscan(dst: *Memimage, seg: []?*Seg, segtab: []Seg, nseg: usize, wind: i32, src: *Memimage, sp: Point, fixshift_: i32, op: i32) void {
    const fixshift: u5 = @intCast(fixshift_);
    var p: usize = 0;

    for (segtab[0..nseg]) |*s| {
        seg[p] = s;
        if (s.p0.x == s.p1.x)
            continue;
        if (s.p0.x > s.p1.x) {
            const pt = s.p0;
            s.p0 = s.p1;
            s.p1 = pt;
            s.d = -s.d;
        }
        s.num = s.p1.y -% s.p0.y;
        s.den = s.p1.x -% s.p0.x;
        s.dz = sdiv(s.num, s.den) << fixshift;
        s.dzrem = mod(s.num, s.den) << fixshift;
        s.dz +%= sdiv(s.dzrem, s.den);
        s.dzrem = mod(s.dzrem, s.den);
        p += 1;
    }
    const n = p;
    if (n == 0)
        return;
    seg[p] = null;
    std.sort.heap(?*Seg, seg[0..n], {}, xcompare);

    var onehalf: i32 = 0;
    if (fixshift != 0)
        onehalf = @as(i32, 1) << (fixshift - 1);

    const miny = dst.clipr.min.y;
    const maxy = dst.clipr.max.y;

    var x = seg[0].?.p0.x;
    if (x < (dst.clipr.min.x << fixshift))
        x = dst.clipr.min.x << fixshift;
    var ix = (x +% onehalf) >> fixshift;
    x = (ix << fixshift) +% onehalf;
    var maxx = dst.clipr.max.x << fixshift;
    // DIFF: only the columns of the image, as in xscan
    const x0 = x;
    if (@as(i64, x0) < (@as(i64, dst.r.min.x) << fixshift) + onehalf) {
        if (dst.r.min.x != satshl(dst.r.min.x, fixshift) >> fixshift)
            return;
        ix = dst.r.min.x;
        x = (ix << fixshift) +% onehalf;
    }
    if (maxx > satshl(dst.r.max.x, fixshift))
        maxx = satshl(dst.r.max.x, fixshift);

    var ep: usize = 0;
    var next: usize = 0;

    // DIFF: as in xscan
    var passes: i64 = @as(i64, dst.r.max.x) - dst.r.min.x + @as(i64, @intCast(nseg)) + 2;
    while (x < maxx) {
        passes -= 1;
        if (passes < 0)
            break;
        var q: usize = 0;
        p = 0;
        while (p < ep) : (p += 1) {
            const s = seg[p].?;
            if (s.p1.x < x)
                continue;
            s.z +%= s.dz;
            s.zerr +%= s.dzrem;
            if (s.zerr >= s.den) {
                s.z +%= 1;
                s.zerr -%= s.den;
                if (s.zerr < 0 or s.zerr >= s.den)
                    print("bad ratzerr1: %d den %d ratdzrem %d\n", .{ s.zerr, s.den, s.dzrem });
            }
            seg[q] = s;
            q += 1;
        }

        p = next;
        while (seg[p]) |s| : (p += 1) {
            if (s.p0.x >= x)
                break;
            if (s.p1.x < x)
                continue;
            enter(s, s.p0.y, s.p0.x, x0, x, fixshift, onehalf);
            if (s.zerr < 0 or s.zerr >= s.den)
                print("bad ratzerr2: %d den %d ratdzrem %d\n", .{ s.zerr, s.den, s.dzrem });
            seg[q] = s;
            q += 1;
        }
        ep = q;
        next = p;

        if (ep == 0) {
            const nx = seg[next] orelse break;
            ix = (nx.p0.x +% onehalf) >> fixshift;
            x = (ix << fixshift) +% onehalf;
            continue;
        }

        zsort(seg[0..ep]);

        p = 0;
        while (p < ep) : (p += 1) {
            var cnt: i32 = 0;
            var y = seg[p].?.z;
            const yerr = seg[p].?.zerr;
            const yden = seg[p].?.den;
            var iy = (y +% onehalf) >> fixshift;
            if (iy >= maxy)
                break;
            if (iy < miny)
                iy = miny;
            cnt +%= seg[p].?.d;
            p += 1;
            while (true) {
                if (p == ep) {
                    print("yscan: fill to infinity", .{});
                    return;
                }
                cnt +%= seg[p].?.d;
                if ((cnt & wind) == 0)
                    break;
                p += 1;
            }
            const s = seg[p].?;
            const y2 = s.z;
            var iy2 = (y2 +% onehalf) >> fixshift;
            if (iy2 <= miny)
                continue;
            if (iy2 > maxy)
                iy2 = maxy;
            if (iy == iy2) {
                if (yerr *% s.den +% s.zerr *% yden > s.den *% yden)
                    y +%= 1;
                iy = (y +% y2) >> (fixshift + 1);
                fillpoint(dst, ix, iy, src, sp, op);
            }
        }
        x +%= @as(i32, 1) << fixshift;
        ix +%= 1;
    }
}

fn zsort(seg: []?*Seg) void {
    if (seg.len < 20) {
        // bubble sort by z - they should be almost sorted already
        var q = seg.len;
        while (true) {
            var done = true;
            q -= 1;
            var p: usize = 0;
            while (p < q) : (p += 1) {
                if (seg[p].?.z > seg[p + 1].?.z) {
                    const s = seg[p];
                    seg[p] = seg[p + 1];
                    seg[p + 1] = s;
                    done = false;
                }
            }
            if (done)
                break;
        }
    } else {
        const q = seg.len - 1;
        var p: usize = 0;
        while (p < q) : (p += 1) {
            if (seg[p].?.z > seg[p + 1].?.z) {
                std.sort.heap(?*Seg, seg, {}, zcompare);
                break;
            }
        }
    }
}

fn ycompare(_: void, s0: ?*Seg, s1: ?*Seg) bool {
    return s0.?.p0.y < s1.?.p0.y;
}

fn xcompare(_: void, s0: ?*Seg, s1: ?*Seg) bool {
    return s0.?.p0.x < s1.?.p0.x;
}

fn zcompare(_: void, s0: ?*Seg, s1: ?*Seg) bool {
    return s0.?.z < s1.?.z;
}

test "filled polygons, against the C library" {
    const T = @import("line.zig").testing;
    const arith = @import("../libdraw/arith.zig");
    const freememimage = @import("alloc.zig").freememimage;
    const Pt = arith.Pt;
    T.init();
    defer T.deinit();
    var ref = T.Ref.init(want);

    for (T.chans) |ch| {
        const red = T.col(draw.DRed);
        defer freememimage(red);
        const green = T.col(0x00FF0080);
        defer freememimage(green);
        const blue = T.col(draw.DBlue);
        defer freememimage(blue);
        const t = T.tex(arith.Rect(-8, -8, 72, 56), draw.RGB24);
        defer freememimage(t);

        const d = T.mk(arith.Rect(0, 0, 64, 48), ch.chan, draw.DWhite);
        defer freememimage(d);
        memfillpoly(d, &.{ Pt(5, 5), Pt(55, 10), Pt(20, 40) }, -1, red, draw.ZP, draw.SoverD);
        ref.out(ch.name, "poly_tri", d);
        const star = [_]Point{ Pt(32, 2), Pt(44, 44), Pt(4, 16), Pt(60, 16), Pt(20, 44) };
        memfillpoly(d, &star, 1, blue, draw.ZP, draw.SoverD);
        ref.out(ch.name, "poly_star_odd", d);
        memfillpoly(d, &star, -1, green, draw.ZP, draw.SoverD);
        ref.out(ch.name, "poly_star_nz", d);
        memfillpoly(d, &.{ Pt(-10, 20), Pt(30, -10), Pt(80, 30), Pt(30, 60) }, -1, t, Pt(7, 9), draw.SoverD);
        ref.out(ch.name, "poly_tex_clip", d);
    }
    try ref.done();
}

test "mod, sdiv, smuldivmod" {
    const eq = std.testing.expectEqual;
    try eq(@as(i32, 1), mod(7, 3));
    try eq(@as(i32, 2), mod(-7, 3));
    try eq(@as(i32, 0), mod(-6, 3));
    try eq(@as(i32, 2), sdiv(7, 3));
    try eq(@as(i32, -3), sdiv(-7, 3));
    try eq(@as(i32, -2), sdiv(-6, 3));
    var m: i32 = undefined;
    try eq(@as(i32, 4), smuldivmod(7, 2, 3, &m));
    try eq(@as(i32, 2), m);
    try eq(@as(i32, -4), smuldivmod(-7, 2, 3, &m));
    try eq(@as(i32, 1), m);
    // operands the C divides at its peril
    _ = mod(std.math.minInt(i32), -1);
    _ = sdiv(std.math.minInt(i32), -1);
}

/// What the C program printed (see `testing` in libmemdraw/line.zig).
const want =
    \\x8r8g8b8.poly_tri 56e4512194702671
    \\x8r8g8b8.poly_star_odd 93709c5a719c4437
    \\x8r8g8b8.poly_star_nz a508cd852e4ef2e3
    \\x8r8g8b8.poly_tex_clip 7d5ba0df45981ad1
    \\r5g6b5.poly_tri 607db3f50516bd79
    \\r5g6b5.poly_star_odd 23a30ef42d94473b
    \\r5g6b5.poly_star_nz cd0e621335ad1bc7
    \\r5g6b5.poly_tex_clip c01abe909560e30f
    \\k8.poly_tri 06cb18088f09bef1
    \\k8.poly_star_odd d8313b308ccd0232
    \\k8.poly_star_nz cb3354afa2530f2e
    \\k8.poly_tex_clip 7183e99ad16b04f2
    \\k1.poly_tri 2191e21942a08813
    \\k1.poly_star_odd 2e2b1cf846111a65
    \\k1.poly_star_nz c69e421a78d268ab
    \\k1.poly_tex_clip 2c7d7818b8eea195
    \\m8.poly_tri 125b00f6dec9deb9
    \\m8.poly_star_odd d18231178082ec16
    \\m8.poly_star_nz 6619c9466668b1da
    \\m8.poly_tex_clip 8ad8b688696b85ab
    \\r8g8b8a8.poly_tri 3ffffee3efcef2c9
    \\r8g8b8a8.poly_star_odd 1e9606bd90bd959f
    \\r8g8b8a8.poly_star_nz beb3d64c38b820f7
    \\r8g8b8a8.poly_tex_clip 18be98763d7bc92d
;
