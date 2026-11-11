//! Elliptical arcs on a Memimage.
//! From /sys/src/libmemdraw/arc.c.
//!
//! DIFF:
//!   - The `goto Return` clean-up is a defer.
//!   - memfillpoly takes a slice; its winding mask ~0 is -1.
//!   - Nothing is drawn when a semiaxis plus the thickness is more
//!     than ellipse.zig's Maxaxis, the limit of memellipse (see
//!     there), before the three masks of that size are allocated.
//!   - Arithmetic on the caller's numbers wraps, as C's does in
//!     practice: they come from user programs through devdraw.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("memdraw.zig");
const mdraw = @import("draw.zig");
const malloc = @import("alloc.zig");
const ellipse = @import("ellipse.zig");
const fillpoly = @import("fillpoly.zig");
const ldraw = @import("../libmemlayer/draw.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const ICOSSCALE = draw.ICOSSCALE;
const ZP = draw.ZP;
const Pt = arith.Pt;
const Rect = arith.Rect;
const icossin = @import("../libdraw/icossin.zig").icossin;
const memdraw = ldraw.memdraw;
const memimagedraw = mdraw.memimagedraw;
const memfillcolor = mdraw.memfillcolor;
const allocmemimage = malloc.allocmemimage;
const freememimage = malloc.freememimage;
const memellipse = ellipse.memellipse;
const memfillpoly = fillpoly.memfillpoly;

//
// elarc(dst,c,a,b,t,src,sp,alpha,phi)
//   draws the part of an ellipse between rays at angles alpha and alpha+phi
//   measured counterclockwise from the positive x axis. other
//   arguments are as for ellipse(dst,c,a,b,t,src,sp)
//

// right, top, left, bottom
const R = 0;
const T = 1;
const L = 2;
const B = 3;

const corners = [_]Point{
    .{ .x = 1, .y = 1 },
    .{ .x = -1, .y = 1 },
    .{ .x = -1, .y = -1 },
    .{ .x = 1, .y = -1 },
};

/// mulpt that wraps
fn wmulpt(a: Point, b: i32) Point {
    return .{ .x = a.x *% b, .y = a.y *% b };
}

//
// make a "wedge" mask covering the desired angle and contained in
// a surrounding square; draw a full ellipse; intersect that with the
// wedge to make a mask through which to copy src to dst.
//
pub fn memarc(dst: *Memimage, c_: Point, a_: i32, b_: i32, t: i32, src: *Memimage, sp: Point, alpha_: i32, phi_: i32, op: i32) void {
    var c = c_;
    var a = a_;
    var b = b_;
    var alpha = alpha_;
    var phi = phi_;
    var p: Point = undefined;
    var bnd: [8]Point = undefined;

    if (phi == 0)
        return;
    if (phi <= -360 or phi >= 360) {
        memellipse(dst, c, a, b, t, src, sp, op);
        return;
    }
    alpha = @rem(alpha, 360);
    alpha = -alpha; // compensate for upside-down coords
    phi = -phi;
    var beta = alpha + phi;
    if (phi < 0) {
        const tmp = alpha;
        alpha = beta;
        beta = tmp;
        phi = -phi;
    }
    while (alpha < 0)
        alpha += 360;
    while (beta < 0)
        beta += 360;
    var c1: usize = @intCast(@divTrunc(alpha, 90) & 3); // number of nearest corner
    const c2: usize = @intCast(@divTrunc(beta, 90) & 3);
    //
    // icossin returns point at radius ICOSSCALE.
    // multiplying by m1 moves it outside the ellipse
    //

    if (a < 0)
        a = -%a;
    if (b < 0)
        b = -%b;
    var w = t;
    if (w < 0)
        w = 0;
    // DIFF: memellipse would draw nothing; do not allocate the masks
    if (a < 0 or b < 0 or w > ellipse.Maxaxis or a > ellipse.Maxaxis - w or b > ellipse.Maxaxis - w)
        return;

    const rect = Rect(-%a -% w, -%b -% w, a +% w +% 1, b +% w +% 1);
    var m = rect.max.x; // inradius of bounding square
    if (m < rect.max.y)
        m = rect.max.y;
    const m1 = (m +% ICOSSCALE -% 1) >> 10;
    m = m1 << 10; // assure m1*cossin is inside
    var i: usize = 0;
    bnd[i] = Pt(0, 0);
    i += 1;
    icossin(alpha, &p.x, &p.y);
    bnd[i] = wmulpt(p, m1);
    i += 1;
    while (true) {
        bnd[i] = wmulpt(corners[c1], m);
        i += 1;
        if (c1 == c2 and phi < 180)
            break;
        c1 = (c1 + 1) & 3;
        phi -= 90;
    }
    icossin(beta, &p.x, &p.y);
    bnd[i] = wmulpt(p, m1);
    i += 1;

    var figure: ?*Memimage = null;
    var mask: ?*Memimage = null;
    var wedge: ?*Memimage = null;
    defer {
        freememimage(wedge);
        freememimage(figure);
        freememimage(mask);
    }
    wedge = allocmemimage(rect, draw.GREY1) orelse return;
    memfillcolor(wedge.?, draw.DTransparent);
    memfillpoly(wedge.?, bnd[0..i], -1, memdraw_h.memopaque, ZP, draw.S);
    figure = allocmemimage(rect, draw.GREY1) orelse return;
    memfillcolor(figure.?, draw.DTransparent);
    memellipse(figure.?, ZP, a, b, t, memdraw_h.memopaque, ZP, draw.S);
    mask = allocmemimage(rect, draw.GREY1) orelse return;
    memfillcolor(mask.?, draw.DTransparent);
    memimagedraw(mask.?, rect, figure.?, rect.min, wedge.?, rect.min, draw.S);
    c = .{ .x = c.x -% dst.r.min.x, .y = c.y -% dst.r.min.y };
    memdraw(dst, dst.r, src, .{ .x = sp.x -% c.x, .y = sp.y -% c.y }, mask.?, .{ .x = -%c.x, .y = -%c.y }, op);
}

test "arcs, against the C library" {
    const tl = @import("line.zig").testing;
    tl.init();
    defer tl.deinit();
    var ref = tl.Ref.init(want);

    for (tl.chans) |ch| {
        const red = tl.col(draw.DRed);
        defer freememimage(red);
        const green = tl.col(0x00FF0080);
        defer freememimage(green);
        const blue = tl.col(draw.DBlue);
        defer freememimage(blue);
        const t = tl.tex(Rect(-8, -8, 72, 56), draw.RGB24);
        defer freememimage(t);

        const d = tl.mk(Rect(0, 0, 64, 48), ch.chan, draw.DBlack);
        defer freememimage(d);
        memarc(d, Pt(32, 24), 20, 15, 2, red, ZP, 30, 100, draw.SoverD);
        ref.out(ch.name, "arc", d);
        memarc(d, Pt(32, 24), 12, 10, -1, t, ZP, 200, -250, draw.SoverD);
        ref.out(ch.name, "arc_fill", d);
        memarc(d, Pt(32, 24), 28, 22, 0, blue, ZP, -45, 350, draw.SoverD);
        ref.out(ch.name, "arc_big", d);
        memarc(d, Pt(10, 10), 8, 8, 1, green, ZP, 0, 360, draw.SoverD);
        ref.out(ch.name, "arc_full", d);
    }
    try ref.done();
}

/// What the C program printed (see `testing` in libmemdraw/line.zig).
const want =
    \\x8r8g8b8.arc 3dc5d4bcb34f3b75
    \\x8r8g8b8.arc_fill 8a56ba3854593ee6
    \\x8r8g8b8.arc_big 77952b54b74fe9c6
    \\x8r8g8b8.arc_full 7c53ef30362780aa
    \\r5g6b5.arc c5aaf8f0e4041615
    \\r5g6b5.arc_fill c4e5b1bc08e1ada8
    \\r5g6b5.arc_big c00e5682e1bb07d8
    \\r5g6b5.arc_full c16b7a7dfec406ac
    \\k8.arc 9232c6b3f06d7bbd
    \\k8.arc_fill b73a63530f64d8f0
    \\k8.arc_big ae05c64d5291936c
    \\k8.arc_full aec1a6da3207ea6d
    \\k1.arc c86ec345c0ee8125
    \\k1.arc_fill 713acbebe46a56e2
    \\k1.arc_big 713acbebe46a56e2
    \\k1.arc_full be18bf67d41de942
    \\m8.arc ff2ce5a769651425
    \\m8.arc_fill 1b8f3dce9804f0c0
    \\m8.arc_big 88bf7924ff4dfd84
    \\m8.arc_full 67604dc463d0cef3
    \\r8g8b8a8.arc 359ca788fd698c41
    \\r8g8b8a8.arc_fill 12b8c54ae9111a84
    \\r8g8b8a8.arc_big 188280927d056b94
    \\r8g8b8a8.arc_full 4b5b3393ca523e6c
;
