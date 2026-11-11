//! Lines on a Memimage: wide lines with square, disc and arrow ends.
//! From /sys/src/libmemdraw/line.c.
//!
//! DIFF:
//!   - Coordinate arithmetic wraps (`+%`, `*%`) as C's does in practice:
//!     the points come from user programs through devdraw and must not
//!     be able to trip an overflow check.
//!   - The ten-point scratch array is indexed, where the C walks it with
//!     a pointer.
//!   - membrush's cached brush is a variable of the file, and freebrush
//!     (not in the C) frees it, for the host tests' leak check.
//!   - `testing` (not in the C) is the support code of the host tests of
//!     this file and of the other shape and layer files; it is an empty
//!     struct in the kernel.
//!   - _memfillpolysc takes a slice and `detail` as bool; the winding
//!     mask ~0 is -1.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("memdraw.zig");
const kernel = @import("kernel.zig");
const mdraw = @import("draw.zig");
const malloc = @import("alloc.zig");
const ellipse = @import("ellipse.zig");
const fillpoly = @import("fillpoly.zig");
const ldraw = @import("../libmemlayer/draw.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const ICOSSCALE = draw.ICOSSCALE;
const Pt = arith.Pt;
const Rect = arith.Rect;
const Rpt = arith.Rpt;
const canonrect = arith.canonrect;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const icossin2 = @import("../libdraw/icossin2.zig").icossin2;
const memdraw = ldraw.memdraw;
const memimagedraw = mdraw.memimagedraw;
const memfillcolor = mdraw.memfillcolor;
const allocmemimage = malloc.allocmemimage;
const freememimage = malloc.freememimage;
const memellipse = ellipse.memellipse;
const _memfillpolysc = fillpoly._memfillpolysc;

const Arrow1 = 8;
const Arrow2 = 10;
const Arrow3 = 3;

/// membrush's static variables
var brush: ?*Memimage = null;
var brushradius: i32 = 0;

fn membrush(radius: i32) ?*Memimage {
    if (brush == null or brushradius != radius) {
        freememimage(brush);
        brush = allocmemimage(Rect(0, 0, 2 *% radius +% 1, 2 *% radius +% 1), memdraw_h.memopaque.chan);
        if (brush) |b| {
            memfillcolor(b, draw.DTransparent); // zeros
            memellipse(b, Pt(radius, radius), radius, radius, -1, memdraw_h.memopaque, Pt(radius, radius), draw.S);
        }
        brushradius = radius;
    }
    return brush;
}

/// Free the cached brush.  Not in the C, where it lives for ever; the
/// host tests call it so their leak check passes.
pub fn freebrush() void {
    freememimage(brush);
    brush = null;
}

fn discend(p: Point, radius: i32, dst: *Memimage, src: *Memimage, dsrc: Point, op: i32) void {
    if (membrush(radius)) |disc| {
        var r: Rectangle = undefined;
        r.min.x = p.x -% radius;
        r.min.y = p.y -% radius;
        r.max.x = p.x +% radius +% 1;
        r.max.y = p.y +% radius +% 1;
        memdraw(dst, r, src, wpt(r.min, dsrc), disc, draw.ZP, op);
    }
}

/// addpt and mulpt that wrap
fn wpt(a: Point, b: Point) Point {
    return .{ .x = a.x +% b.x, .y = a.y +% b.y };
}

fn wmulpt(a: Point, b: i32) Point {
    return .{ .x = a.x *% b, .y = a.y *% b };
}

fn arrowend(tip: Point, pp: *[5]Point, end: i32, sin: i32, cos: i32, radius: i32) void {
    var x1: i32 = undefined;
    var x2: i32 = undefined;
    var x3: i32 = undefined;

    // before rotation
    if (end == draw.Endarrow) {
        x1 = Arrow1;
        x2 = Arrow2;
        x3 = Arrow3;
    } else {
        x1 = (end >> 5) & 0x1FF; // distance along line from end of line to tip
        x2 = (end >> 14) & 0x1FF; // distance along line from barb to tip
        x3 = (end >> 23) & 0x1FF; // distance perpendicular from edge of line to barb
    }

    const w1 = 2 *% radius +% 1;
    const w3 = 2 *% radius +% 2 *% x3 +% 1;

    // comments follow track of right-facing arrowhead
    pp[0].x = tip.x +% (@divTrunc(w1 *% sin, 2) -% x1 *% cos); // upper side of shaft
    pp[0].y = tip.y -% (@divTrunc(w1 *% cos, 2) +% x1 *% sin);
    pp[1].x = tip.x +% (@divTrunc(w3 *% sin, 2) -% x2 *% cos); // upper barb
    pp[1].y = tip.y -% (@divTrunc(w3 *% cos, 2) +% x2 *% sin);
    pp[2].x = tip.x;
    pp[2].y = tip.y;
    pp[3].x = tip.x +% (@divTrunc(-%w3 *% sin, 2) -% x2 *% cos); // lower barb
    pp[3].y = tip.y -% (@divTrunc(-%w3 *% cos, 2) +% x2 *% sin);
    pp[4].x = tip.x +% (@divTrunc(-%w1 *% sin, 2) -% x1 *% cos); // lower side of shaft
    pp[4].y = tip.y +% (@divTrunc(w1 *% cos, 2) -% x1 *% sin);
}

//
// NOTE: Clipping is a little peculiar.  We can't use Sutherland-Cohen
// clipping because lines are wide.  But this is probably just fine:
// we do all math with the original p0 and p1, but clip when deciding
// what pixels to draw.  This means the layer code can call this routine,
// using clipr to define the region being written, and get the same set
// of pixels regardless of the dicing.
//
pub fn _memimageline(dst: *Memimage, p0_: Point, p1_: Point, end0_: i32, end1_: i32, radius: i32, src: *Memimage, sp_: Point, clipr_: Rectangle, op: i32) void {
    var p0 = p0_;
    var p1 = p1_;
    var end0 = end0_;
    var end1 = end1_;
    var sp = sp_;
    var clipr = clipr_;
    var sin: i32 = undefined;
    var cos: i32 = undefined;
    var r: Rectangle = undefined;
    var q: Point = undefined;
    var pts: [10]Point = undefined;

    if (radius < 0)
        return;
    if (!rectclip(&clipr, dst.r))
        return;
    if (!rectclip(&clipr, dst.clipr))
        return;
    const d: Point = .{ .x = sp.x -% p0.x, .y = sp.y -% p0.y };
    if (!rectclip(&clipr, wrectsubpt(src.clipr, d)))
        return;
    if ((src.flags & memdraw_h.Frepl) == 0 and !rectclip(&clipr, wrectsubpt(src.r, d)))
        return;
    const hor = @abs(p1.x -% p0.x) > @abs(p1.y -% p0.y);
    if ((hor and p0.x > p1.x) or (!hor and p0.y > p1.y)) {
        q = p0;
        p0 = p1;
        p1 = q;
        const t = end0;
        end0 = end1;
        end1 = t;
    }

    // handle purely vertical or horizontal lines
    if (p0.x == p1.x or p0.y == p1.y) {
        r.min = p0;
        r.max = wpt(p1, Pt(1, 1));
        if (p0.x == p1.x) {
            r.min.x -%= radius;
            r.max.x +%= radius;
            cos = 0;
            sin = ICOSSCALE;
        } else {
            r.min.y -%= radius;
            r.max.y +%= radius;
            cos = ICOSSCALE;
            sin = 0;
        }
        const oclipr = dst.clipr;
        dst.clipr = clipr;
        switch (end0 & 0x1F) {
            draw.Enddisc => discend(p0, radius, dst, src, d, op),
            draw.Endarrow => {
                q.x = ICOSSCALE *% p0.x +% ICOSSCALE / 2 -% @divTrunc(cos, 2);
                q.y = ICOSSCALE *% p0.y +% ICOSSCALE / 2 -% @divTrunc(sin, 2);
                arrowend(q, pts[0..5], end0, -sin, -cos, radius);
                _memfillpolysc(dst, pts[0..5], -1, src, wpt(pts[0], wmulpt(d, ICOSSCALE)), true, 10, op);
                if (cos != 0)
                    r.min.x = pts[0].x >> 10
                else
                    r.min.y = pts[0].y >> 10;
            },
            else => {},
        }
        switch (end1 & 0x1F) {
            draw.Enddisc => discend(p1, radius, dst, src, d, op),
            draw.Endarrow => {
                q.x = ICOSSCALE *% p1.x +% ICOSSCALE / 2 +% @divTrunc(cos, 2);
                q.y = ICOSSCALE *% p1.y +% ICOSSCALE / 2 +% @divTrunc(sin, 2);
                arrowend(q, pts[0..5], end1, sin, cos, radius);
                _memfillpolysc(dst, pts[0..5], -1, src, wpt(pts[0], wmulpt(d, ICOSSCALE)), true, 10, op);
                if (cos != 0)
                    r.max.x = pts[0].x >> 10
                else
                    r.max.y = pts[0].y >> 10;
            },
            else => {},
        }
        sp = wpt(r.min, d);
        memimagedraw(dst, r, src, sp, memdraw_h.memopaque, sp, op);
        dst.clipr = oclipr;
        return;
    }

    // draw thick line using polygon fill
    icossin2(p1.x -% p0.x, p1.y -% p0.y, &cos, &sin);
    const dx = @divTrunc(sin *% (2 *% radius +% 1), 2);
    const dy = @divTrunc(cos *% (2 *% radius +% 1), 2);
    var pp: usize = 0;
    const oclipr = dst.clipr;
    dst.clipr = clipr;
    q.x = ICOSSCALE *% p0.x +% ICOSSCALE / 2 -% @divTrunc(cos, 2);
    q.y = ICOSSCALE *% p0.y +% ICOSSCALE / 2 -% @divTrunc(sin, 2);
    switch (end0 & 0x1F) {
        draw.Endarrow => {
            arrowend(q, pts[pp..][0..5], end0, -sin, -cos, radius);
            _memfillpolysc(dst, pts[0..5], -1, src, wpt(pts[0], wmulpt(d, ICOSSCALE)), true, 10, op);
            pts[pp + 1] = pts[pp + 4];
            pp += 2;
        },
        else => |e| {
            if (e == draw.Enddisc)
                discend(p0, radius, dst, src, d, op);
            // fall through
            // Endsquare, default:
            pts[pp].x = q.x -% dx;
            pts[pp].y = q.y +% dy;
            pp += 1;
            pts[pp].x = q.x +% dx;
            pts[pp].y = q.y -% dy;
            pp += 1;
        },
    }
    q.x = ICOSSCALE *% p1.x +% ICOSSCALE / 2 +% @divTrunc(cos, 2);
    q.y = ICOSSCALE *% p1.y +% ICOSSCALE / 2 +% @divTrunc(sin, 2);
    switch (end1 & 0x1F) {
        draw.Endarrow => {
            arrowend(q, pts[pp..][0..5], end1, sin, cos, radius);
            _memfillpolysc(dst, pts[pp..][0..5], -1, src, wpt(pts[pp], wmulpt(d, ICOSSCALE)), true, 10, op);
            pts[pp + 1] = pts[pp + 4];
            pp += 2;
        },
        else => |e| {
            if (e == draw.Enddisc)
                discend(p1, radius, dst, src, d, op);
            // fall through
            // Endsquare, default:
            pts[pp].x = q.x +% dx;
            pts[pp].y = q.y -% dy;
            pp += 1;
            pts[pp].x = q.x -% dx;
            pts[pp].y = q.y +% dy;
            pp += 1;
        },
    }
    _memfillpolysc(dst, pts[0..pp], -1, src, wpt(pts[0], wmulpt(d, ICOSSCALE)), false, 10, op);
    dst.clipr = oclipr;
    return;
}

fn wrectsubpt(r: Rectangle, p: Point) Rectangle {
    return .{
        .min = .{ .x = r.min.x -% p.x, .y = r.min.y -% p.y },
        .max = .{ .x = r.max.x -% p.x, .y = r.max.y -% p.y },
    };
}

pub fn memimageline(dst: *Memimage, p0: Point, p1: Point, end0: i32, end1: i32, radius: i32, src: *Memimage, sp: Point, op: i32) void {
    _memimageline(dst, p0, p1, end0, end1, radius, src, sp, dst.clipr, op);
}

//
// Simple-minded conservative code to compute bounding box of line.
// Result is probably a little larger than it needs to be.
//
fn addbbox(r: *Rectangle, p: Point) void {
    if (r.min.x > p.x)
        r.min.x = p.x;
    if (r.min.y > p.y)
        r.min.y = p.y;
    if (r.max.x < p.x +% 1)
        r.max.x = p.x +% 1;
    if (r.max.y < p.y +% 1)
        r.max.y = p.y +% 1;
}

pub fn memlineendsize(end: i32) i32 {
    var x3: i32 = undefined;

    if ((end & 0x3F) != draw.Endarrow)
        return 0;
    if (end == draw.Endarrow)
        x3 = Arrow3
    else
        x3 = (end >> 23) & 0x1FF;
    return x3;
}

fn lmax(a: i32, b: i32) i32 {
    if (a > b)
        return a;
    return b;
}

pub fn memlinebbox(p0: Point, p1: Point, end0: i32, end1: i32, radius: i32) Rectangle {
    var r: Rectangle = undefined;

    r.min.x = 10000000;
    r.min.y = 10000000;
    r.max.x = -10000000;
    r.max.y = -10000000;
    const extra = lmax(memlineendsize(end0), memlineendsize(end1));
    const n = radius +% extra;
    const c = canonrect(Rpt(p0, p1));
    // insetrect(c, -(radius+extra))
    const r1: Rectangle = .{
        .min = .{ .x = c.min.x -% n, .y = c.min.y -% n },
        .max = .{ .x = c.max.x +% n, .y = c.max.y +% n },
    };
    addbbox(&r, r1.min);
    addbbox(&r, r1.max);
    return r;
}

/// Support for the host tests of the shape and layer files.  Each test
/// repeats, call for call, what a C program does with the original
/// libdraw, libmemdraw and libmemlayer (9front's sources built for the
/// host with gcc, long and ulong 32 bits wide as on Plan 9), and
/// compares a hash of the resulting pixels with what that program
/// printed; the `want` text at the end of each file is that program's
/// output.  The hash leaves out the unused byte of x8r8g8b8 pixels:
/// what the C library leaves there depends on uninitialised memory and
/// changes from run to run.
pub const testing = if (kernel.hosted) struct {
    const std = @import("std");
    const memunload = @import("../libmemlayer/unload.zig").memunload;
    const bytesperline = @import("../libdraw/bytesperline.zig").bytesperline;

    pub const Chan = struct { chan: u32, name: []const u8 };

    /// the image formats the shapes are drawn on
    pub const chans = [_]Chan{
        .{ .chan = draw.XRGB32, .name = "x8r8g8b8" },
        .{ .chan = draw.RGB16, .name = "r5g6b5" },
        .{ .chan = draw.GREY8, .name = "k8" },
        .{ .chan = draw.GREY1, .name = "k1" },
        .{ .chan = draw.CMAP8, .name = "m8" },
        .{ .chan = draw.RGBA32, .name = "r8g8b8a8" },
    };

    /// draw.zig keeps scratch buffers and the predefined images between
    /// calls; its own test support (`T.done`) frees them and undoes
    /// memimageinit.  While that is private to draw.zig, the fallback
    /// below frees and remakes the predefined images only: the scratch
    /// buffers then show up as a leak, and each test must be run in a
    /// process of its own (--test-filter).
    const drawdone = @hasDecl(mdraw, "T") and @hasDecl(mdraw.T, "done");

    var inited = false;

    /// memimageinit, for every test: the predefined images are freed
    /// again by deinit so that the test allocator sees no leak.
    pub fn init() void {
        if (drawdone or !inited) {
            mdraw.memimageinit();
            inited = true;
            return;
        }
        const big = Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF);
        const ones = allocmemimage(Rect(0, 0, 1, 1), draw.GREY1).?;
        const zeros = allocmemimage(Rect(0, 0, 1, 1), draw.GREY1).?;
        ones.flags |= memdraw_h.Frepl;
        ones.clipr = big;
        malloc.byteaddr(ones, draw.ZP)[0] = 0xFF;
        zeros.flags |= memdraw_h.Frepl;
        zeros.clipr = big;
        malloc.byteaddr(zeros, draw.ZP)[0] = 0;
        memdraw_h.memwhite = ones;
        memdraw_h.memblack = zeros;
        memdraw_h.memopaque = ones;
        memdraw_h.memtransparent = zeros;
    }

    pub fn deinit() void {
        freebrush();
        @import("../libmemlayer/lalloc.zig").freepaint();
        if (drawdone) {
            mdraw.T.done();
            return;
        }
        freememimage(memdraw_h.memwhite);
        freememimage(memdraw_h.memblack);
    }

    pub fn hash(i: *Memimage) u64 {
        const n: usize = @intCast(bytesperline(i.r, i.depth) * draw.Dy(i.r));
        const buf = std.testing.allocator.alloc(u8, n) catch @panic("hash");
        defer std.testing.allocator.free(buf);
        const k = memunload(i, i.r, buf);
        if (k != n)
            std.debug.print("hash: unload {d} != {d}\n", .{ k, n });
        var h: u64 = 0xcbf29ce484222325;
        for (buf, 0..) |*c, j| {
            if (i.chan == draw.XRGB32 and j & 3 == 3) c.* = 0;
            h ^= c.*;
            h *%= 0x100000001b3;
        }
        return h;
    }

    pub fn mk(r: Rectangle, chan: u32, color: u32) *Memimage {
        const i = allocmemimage(r, chan).?;
        memfillcolor(i, color);
        return i;
    }

    pub fn col(color: u32) *Memimage {
        const i = mk(Rect(0, 0, 1, 1), draw.RGBA32, color);
        i.flags |= memdraw_h.Frepl;
        i.clipr = Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF);
        return i;
    }

    /// a deterministic texture
    pub fn tex(r: Rectangle, chan: u32) *Memimage {
        const i = mk(r, chan, draw.DBlack);
        var y = r.min.y;
        while (y < r.max.y) : (y += 1) {
            var x = r.min.x;
            while (x < r.max.x) : (x += 1) {
                const ux: u32 = @bitCast(x);
                const uy: u32 = @bitCast(y);
                const c = col(((ux *% 37 +% uy *% 11) & 0xFF) << 24 | ((ux *% 5 +% uy *% 23) & 0xFF) << 16 | ((ux *% ux +% uy) & 0xFF) << 8 | 0xFF);
                memimagedraw(i, Rect(x, y, x + 1, y + 1), c, draw.ZP, null, draw.ZP, draw.S);
                freememimage(c);
            }
        }
        return i;
    }

    /// The C program's output, compared a line at a time.
    pub const Ref = struct {
        it: std.mem.SplitIterator(u8, .scalar),
        bad: usize = 0,
        n: usize = 0,

        pub fn init(text: []const u8) Ref {
            return .{ .it = std.mem.splitScalar(u8, text, '\n') };
        }

        /// "<chan>.<name> <hash of i>"
        pub fn out(ref: *Ref, cn: []const u8, name: []const u8, i: *Memimage) void {
            ref.line("{s}.{s} {x:0>16}", .{ cn, name, hash(i) });
        }

        pub fn line(ref: *Ref, comptime format: []const u8, args: anytype) void {
            var buf: [200]u8 = undefined;
            const got = std.fmt.bufPrint(&buf, format, args) catch @panic("line");
            const exp = ref.it.next() orelse "(nothing)";
            ref.n += 1;
            if (!std.mem.eql(u8, got, exp)) {
                ref.bad += 1;
                std.debug.print("got  {s}\nwant {s}\n", .{ got, exp });
            }
        }

        pub fn done(ref: *Ref) !void {
            if (ref.it.next()) |more| {
                std.debug.print("not reached: {s}\n", .{more});
                return error.TestUnexpectedResult;
            }
            if (ref.bad != 0) {
                std.debug.print("{d} of {d} differ\n", .{ ref.bad, ref.n });
                return error.TestUnexpectedResult;
            }
        }
    };
} else struct {};

test "lines, against the C library" {
    const T = testing;
    T.init();
    defer T.deinit();
    var ref = T.Ref.init(want);

    for (T.chans) |ch| {
        const r = Rect(0, 0, 64, 48);
        const red = T.col(draw.DRed);
        defer freememimage(red);
        const green = T.col(0x00FF0080); // premultiplied half green
        defer freememimage(green);
        const blue = T.col(draw.DBlue);
        defer freememimage(blue);
        const t = T.tex(Rect(-8, -8, 72, 56), draw.RGB24);
        defer freememimage(t);

        var d = T.mk(r, ch.chan, draw.DWhite);
        memimageline(d, Pt(5, 10), Pt(40, 10), draw.Endsquare, draw.Endsquare, 0, red, draw.ZP, draw.SoverD);
        ref.out(ch.name, "line_h", d);
        memimageline(d, Pt(20, 5), Pt(20, 40), draw.Enddisc, draw.Endsquare, 3, blue, draw.ZP, draw.SoverD);
        ref.out(ch.name, "line_v_thick", d);
        memimageline(d, Pt(5, 5), Pt(50, 40), draw.Endsquare, draw.Endsquare, 0, green, draw.ZP, draw.SoverD);
        ref.out(ch.name, "line_diag", d);
        memimageline(d, Pt(50, 5), Pt(8, 30), draw.Enddisc, draw.Enddisc, 4, t, Pt(3, 4), draw.SoverD);
        ref.out(ch.name, "line_diag_disc", d);
        freememimage(d);

        d = T.mk(r, ch.chan, draw.DBlack);
        memimageline(d, Pt(10, 40), Pt(55, 12), draw.Endsquare, draw.Endarrow, 1, red, draw.ZP, draw.SoverD);
        ref.out(ch.name, "line_arrow", d);
        memimageline(d, Pt(10, 20), Pt(50, 20), draw.Endarrow, draw.ARROW(12, 14, 5), 2, blue, draw.ZP, draw.SoverD);
        ref.out(ch.name, "line_arrow_h", d);
        memimageline(d, Pt(30, 2), Pt(30, 45), draw.ARROW(9, 9, 4), draw.Endarrow, 0, green, draw.ZP, draw.SoverD);
        ref.out(ch.name, "line_arrow_v", d);
        d.clipr = Rect(10, 10, 30, 30);
        memimageline(d, Pt(0, 0), Pt(60, 45), draw.Enddisc, draw.Enddisc, 2, t, draw.ZP, draw.S);
        memimageline(d, Pt(-20, 25), Pt(90, 26), draw.Endsquare, draw.Endsquare, 1, red, draw.ZP, draw.S);
        d.clipr = d.r;
        ref.out(ch.name, "line_clip", d);
        freememimage(d);
    }
    try ref.done();
}

test "memlinebbox, memlineendsize" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 0), memlineendsize(draw.Endsquare));
    try std.testing.expectEqual(@as(i32, 0), memlineendsize(draw.Enddisc));
    try std.testing.expectEqual(@as(i32, Arrow3), memlineendsize(draw.Endarrow));
    try std.testing.expectEqual(@as(i32, 7), memlineendsize(draw.ARROW(2, 2, 7)));
    // an odd first parameter sets a bit of the mask the C tests with
    try std.testing.expectEqual(@as(i32, 0), memlineendsize(draw.ARROW(1, 2, 7)));
    const r = memlinebbox(Pt(10, 30), Pt(5, 40), draw.Endsquare, draw.ARROW(2, 2, 7), 2);
    try std.testing.expect(arith.eqrect(r, Rect(5 - 9, 30 - 9, 10 + 9 + 1, 40 + 9 + 1)));
}

/// What the C program printed (see `testing` in libmemdraw/line.zig).
const want =
    \\x8r8g8b8.line_h 2ffe71f31f55e3e5
    \\x8r8g8b8.line_v_thick 946f1ca2553e9135
    \\x8r8g8b8.line_diag 828dffd093522af5
    \\x8r8g8b8.line_diag_disc 549414c4608d53d5
    \\x8r8g8b8.line_arrow c84c88d56bdb1eb5
    \\x8r8g8b8.line_arrow_h 5b0ff3c40e9b1f9a
    \\x8r8g8b8.line_arrow_v 8eaf37d73a9e0c4a
    \\x8r8g8b8.line_clip 5c9d11f8d1689cfe
    \\r5g6b5.line_h 5396f307977e464d
    \\r5g6b5.line_v_thick 7f4896180f4c038e
    \\r5g6b5.line_diag 6f8a89c5a031413a
    \\r5g6b5.line_diag_disc b45e7086a6829418
    \\r5g6b5.line_arrow 2879b0aecd6b8655
    \\r5g6b5.line_arrow_h b4b1d12395e9be1a
    \\r5g6b5.line_arrow_v 37d067c4a3af5f72
    \\r5g6b5.line_clip 3603e6ccf8a2b2a2
    \\k8.line_h 02749b689a557879
    \\k8.line_v_thick f483223349b3b6a0
    \\k8.line_diag a803b6335f194996
    \\k8.line_diag_disc be71b17421f61b24
    \\k8.line_arrow aa5cba1671e0bedd
    \\k8.line_arrow_h be587fee1389552c
    \\k8.line_arrow_v 1304af88e300cc33
    \\k8.line_clip 8dd9c1b54b818b0c
    \\k1.line_h a62583a0089685d6
    \\k1.line_v_thick 98b55aa1595d07b8
    \\k1.line_diag 909a6571466c7750
    \\k1.line_diag_disc 0505a96d061124fd
    \\k1.line_arrow c86ec345c0ee8125
    \\k1.line_arrow_h c86ec345c0ee8125
    \\k1.line_arrow_v b6eb90e1a64b1405
    \\k1.line_clip 585c069b5fbd90ad
    \\m8.line_h 74b8552c59fc85f9
    \\m8.line_v_thick fb9c6275aab3d277
    \\m8.line_diag bc541e0cc60f8acb
    \\m8.line_diag_disc 4c5bae4a4e104f0d
    \\m8.line_arrow cd49c95862374865
    \\m8.line_arrow_h 13bc79de062819c3
    \\m8.line_arrow_v 2ff6a601e6e724fe
    \\m8.line_clip 0da81903a4a2004e
    \\r8g8b8a8.line_h f06118c40d7737ad
    \\r8g8b8a8.line_v_thick 520b9a68b06b8b0d
    \\r8g8b8a8.line_diag 6f93470ffd8b7b55
    \\r8g8b8a8.line_diag_disc 4226d3849e943c09
    \\r8g8b8a8.line_arrow 4e25e8d3d00e0a09
    \\r8g8b8a8.line_arrow_h 7bda9ba0d2126f30
    \\r8g8b8a8.line_arrow_v 060b9fc37c5af670
    \\r8g8b8a8.line_clip 38a9bfe212794a9c
;
