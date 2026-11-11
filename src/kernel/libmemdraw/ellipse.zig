//! Ellipses on a Memimage.
//! From /sys/src/libmemdraw/ellipse.c.
//!
//! DIFF:
//!   - bellipse frees the disc it allocates.  The C never does, leaking
//!     an image for every thick skinny ellipse drawn.
//!   - memellipse draws nothing when a semiaxis plus the thickness is
//!     more than Maxaxis, 46340.  From there on the C's a*a and b*b
//!     overflow int, so what it draws is not an ellipse, and it takes
//!     one pass of its loop, with up to four draws, for each of up to
//!     2^31 scan lines whether or not they are in the image: a program
//!     could hold the draw lock for minutes with one message.  memarc
//!     uses the same limit (arc.zig).
//!   - Arithmetic wraps as C's does in practice: the axes and thickness
//!     come from user programs through devdraw and must not be able to
//!     trip an overflow check.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("memdraw.zig");
const mdraw = @import("draw.zig");
const malloc = @import("alloc.zig");
const ldraw = @import("../libmemlayer/draw.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const ZP = draw.ZP;
const Rect = arith.Rect;
const memdraw = ldraw.memdraw;
const memfillcolor = mdraw.memfillcolor;
const allocmemimage = malloc.allocmemimage;
const freememimage = malloc.freememimage;

//
// ellipse(dst, c, a, b, t, src, sp)
//   draws an ellipse centered at c with semiaxes a,b>=0
//   and semithickness t>=0, or filled if t<0.  point sp
//   in src maps to c in dst
//
//   very thick skinny ellipses are brushed with circles (slow)
//   others are approximated by filling between 2 ellipses
//   criterion for very thick when b<a: t/b > 0.5*x/(1-x)
//   where x = b/a
//

/// the largest semiaxis plus thickness: floor(sqrt(2^31))
pub const Maxaxis = 46340;

const Param = struct {
    dst: *Memimage,
    src: *Memimage,
    c: Point,
    t: i32,
    sp: Point,
    disc: ?*Memimage,
    op: i32,
};

//
// denote residual error by e(x,y) = b^2*x^2 + a^2*y^2 - a^2*b^2
// e(x,y) = 0 on ellipse, e(x,y) < 0 inside, e(x,y) > 0 outside
//

const State = struct {
    a: i32,
    x: i32,
    a2: i64, // a^2
    b2: i64, // b^2
    b2x: i64, // b^2 * x
    a2y: i64, // a^2 * y
    c1: i64,
    c2: i64, // test criteria
    ee: i64, // ee = e(x+1/2,y-1/2) - (a^2+b^2)/4
    dxe: i64,
    dye: i64,
    d2xe: i64,
    d2ye: i64,
};

fn newstate(s: *State, a: i32, b: i32) *State {
    s.x = 0;
    s.a = a;
    s.a2 = a *% a;
    s.b2 = b *% b;
    s.b2x = 0;
    s.a2y = s.a2 *% b;
    s.c1 = -%((s.a2 >> 2) +% (a & 1) +% s.b2);
    s.c2 = -%((s.b2 >> 2) +% (b & 1));
    s.ee = -%s.a2y;
    s.dxe = 0;
    s.dye = s.ee << 1;
    s.d2xe = s.b2 << 1;
    s.d2ye = s.a2 << 1;
    return s;
}

//
// return x coord of rightmost pixel on next scan line
//
fn step(s: *State) i32 {
    while (s.x < s.a) {
        if (s.ee +% s.b2x <= s.c1 or // e(x+1,y-1/2) <= 0
            s.ee +% s.a2y <= s.c2) // e(x+1/2,y) <= 0 (rare)
        {
            s.dxe +%= s.d2xe;
            s.ee +%= s.dxe;
            s.b2x +%= s.b2;
            s.x += 1;
            continue;
        }
        s.dye +%= s.d2ye;
        s.ee +%= s.dye;
        s.a2y -%= s.a2;
        if (s.ee -% s.a2y <= s.c2) { // e(x+1/2,y-1) <= 0
            s.dxe +%= s.d2xe;
            s.ee +%= s.dxe;
            s.b2x +%= s.b2;
            const x = s.x;
            s.x += 1;
            return x;
        }
        break;
    }
    return s.x;
}

pub fn memellipse(dst: *Memimage, c: Point, a_: i32, b_: i32, t: i32, src: *Memimage, sp: Point, op: i32) void {
    var a = a_;
    var b = b_;
    var in: State = undefined;
    var out: State = undefined;
    var y: i32 = undefined;
    var inb: i32 = undefined;
    var p: Param = undefined;

    if (a < 0)
        a = -%a;
    if (b < 0)
        b = -%b;
    // DIFF: see the header
    const w = if (t < 0) 0 else t;
    if (a < 0 or b < 0 or w > Maxaxis or a > Maxaxis - w or b > Maxaxis - w)
        return;
    p.dst = dst;
    p.src = src;
    p.c = c;
    p.t = t;
    p.sp = .{ .x = sp.x -% c.x, .y = sp.y -% c.y };
    p.disc = null;
    p.op = op;

    const u = (t << 1) *% (a -% b);
    if ((b < a and u > b *% b) or (a < b and -%u > a *% a)) {
        // if(b<a&&(t<<1)>b*b/a || a<b&&(t<<1)>a*a/b)   # very thick
        bellipse(b, newstate(&in, a, b), &p);
        return;
    }

    if (t < 0) {
        inb = -1;
        y = b;
        _ = newstate(&out, a, y);
    } else {
        inb = b -% t;
        y = b +% t;
        _ = newstate(&out, a +% t, y);
    }
    if (t > 0)
        _ = newstate(&in, a -% t, inb);
    var inx: i32 = 0;
    while (y >= 0) : (y -= 1) {
        const outx = step(&out);
        if (y > inb) {
            erect(-outx, y, outx, y, &p);
            if (y != 0)
                erect(-outx, -y, outx, -y, &p);
            continue;
        }
        if (t > 0) {
            inx = step(&in);
            if (y == inb)
                inx = 0;
        } else if (inx > outx)
            inx = outx;
        erect(inx, y, outx, y, &p);
        if (y != 0)
            erect(inx, -y, outx, -y, &p);
        erect(-outx, y, -inx, y, &p);
        if (y != 0)
            erect(-outx, -y, -inx, -y, &p);
        inx = outx +% 1;
    }
}

//
// a brushed ellipse
//
fn bellipse(y_: i32, s: *State, p: *Param) void {
    var y = y_;

    const t = p.t;
    const disc = allocmemimage(Rect(-%t, -%t, t +% 1, t +% 1), draw.GREY1) orelse return;
    p.disc = disc;
    defer {
        // DIFF: not freed in the C
        p.disc = null;
        freememimage(disc);
    }
    memfillcolor(disc, draw.DTransparent);
    memellipse(disc, ZP, t, t, -1, memdraw_h.memopaque, ZP, p.op);
    var oy = y;
    var ox: i32 = 0;
    var x = step(s);
    var nx = x;
    while (true) {
        // while(nx==x && y-->0)
        while (nx == x) {
            const more = y > 0;
            y -= 1;
            if (!more)
                break;
            nx = step(s);
        }
        y += 1;
        eline(-x, -oy, -ox, -y, p);
        eline(ox, -oy, x, -y, p);
        eline(-x, y, -ox, oy, p);
        eline(ox, y, x, oy, p);
        ox = x +% 1;
        x = nx;
        y -= 1;
        oy = y;
        if (!(oy > 0))
            break;
    }
}

//
// a rectangle with closed (not half-open) coordinates expressed
// relative to the center of the ellipse
//
fn erect(x0: i32, y0: i32, x1: i32, y1: i32, p: *Param) void {
    // print("R %d,%d %d,%d\n", x0, y0, x1, y1);
    const r = Rect(p.c.x +% x0, p.c.y +% y0, p.c.x +% x1 +% 1, p.c.y +% y1 +% 1);
    memdraw(p.dst, r, p.src, wpt(p.sp, r.min), memdraw_h.memopaque, ZP, p.op);
}

/// addpt that wraps
fn wpt(a: Point, b: Point) Point {
    return .{ .x = a.x +% b.x, .y = a.y +% b.y };
}

//
// a brushed point similarly specified
//
fn epoint(x: i32, y: i32, p: *Param) void {
    // print("P%d %d,%d\n", p->t, x, y);
    const disc = p.disc.?;
    const p0: Point = .{ .x = p.c.x +% x, .y = p.c.y +% y };
    const r: Rectangle = .{ .min = wpt(p0, disc.r.min), .max = wpt(p0, disc.r.max) };
    memdraw(p.dst, r, p.src, wpt(p.sp, r.min), disc, disc.r.min, p.op);
}

//
// a brushed horizontal or vertical line similarly specified
//
fn eline(x0: i32, y0: i32, x1: i32, y1: i32, p: *Param) void {
    // print("L%d %d,%d %d,%d\n", p->t, x0, y0, x1, y1);
    if (x1 > x0 +% 1)
        erect(x0 +% 1, y0 -% p.t, x1 -% 1, y1 +% p.t, p)
    else if (y1 > y0 +% 1)
        erect(x0 -% p.t, y0 +% 1, x1 +% p.t, y1 -% 1, p);
    epoint(x0, y0, p);
    if (x1 -% x0 != 0 or y1 -% y0 != 0)
        epoint(x1, y1, p);
}

test "ellipses, against the C library" {
    const T = @import("line.zig").testing;
    const Pt = arith.Pt;
    T.init();
    defer T.deinit();
    var ref = T.Ref.init(want);

    for (T.chans) |ch| {
        const r = Rect(0, 0, 64, 48);
        const red = T.col(draw.DRed);
        defer freememimage(red);
        const green = T.col(0x00FF0080);
        defer freememimage(green);
        const blue = T.col(draw.DBlue);
        defer freememimage(blue);
        const t = T.tex(Rect(-8, -8, 72, 56), draw.RGB24);
        defer freememimage(t);

        var d = T.mk(r, ch.chan, draw.DWhite);
        memellipse(d, Pt(32, 24), 20, 12, 0, red, ZP, draw.SoverD);
        ref.out(ch.name, "ellipse_thin", d);
        memellipse(d, Pt(32, 24), 26, 18, 3, t, Pt(1, 2), draw.SoverD);
        ref.out(ch.name, "ellipse_thick", d);
        memellipse(d, Pt(20, 20), 9, 13, -1, green, ZP, draw.SoverD);
        ref.out(ch.name, "ellipse_fill", d);
        memellipse(d, Pt(40, 30), 10, 10, 1, blue, ZP, draw.SoverD);
        ref.out(ch.name, "circle", d);
        freememimage(d);

        d = T.mk(r, ch.chan, draw.DWhite);
        memellipse(d, Pt(32, 24), 25, 3, 6, blue, ZP, draw.SoverD);
        ref.out(ch.name, "ellipse_brush", d);
        memellipse(d, Pt(32, 24), 2, 18, 5, red, ZP, draw.SoverD);
        ref.out(ch.name, "ellipse_brush2", d);
        memellipse(d, Pt(60, 44), 14, 9, 2, green, ZP, draw.SoverD);
        ref.out(ch.name, "ellipse_edge", d);
        freememimage(d);
    }
    try ref.done();
}

/// What the C program printed (see `testing` in libmemdraw/line.zig).
const want =
    \\x8r8g8b8.ellipse_thin 88a247d9d067cadd
    \\x8r8g8b8.ellipse_thick e6a64354fe2ffffd
    \\x8r8g8b8.ellipse_fill e3b15d765eafb27e
    \\x8r8g8b8.circle 86e6212db70fc5fa
    \\x8r8g8b8.ellipse_brush 6d204858bd673e4b
    \\x8r8g8b8.ellipse_brush2 e4eef0fa5dec9583
    \\x8r8g8b8.ellipse_edge f09d54c3bfc9fb38
    \\r5g6b5.ellipse_thin 8125aeca543c809d
    \\r5g6b5.ellipse_thick 963141820416f140
    \\r5g6b5.ellipse_fill 34d068828d56d19c
    \\r5g6b5.circle e059729b69ac4c3b
    \\r5g6b5.ellipse_brush 214797370bccb9d4
    \\r5g6b5.ellipse_brush2 557f48ccae1a5cb3
    \\r5g6b5.ellipse_edge 6637d1f7a45d5be1
    \\k8.ellipse_thin d1f4cfdcf39d86b5
    \\k8.ellipse_thick cd1b1210e7b6afc1
    \\k8.ellipse_fill 2d5d3c9c715d40c2
    \\k8.circle 85c30ed4cb61afc7
    \\k8.ellipse_brush eb6451facf2a4dd3
    \\k8.ellipse_brush2 c1c6bb9e6f0d5706
    \\k8.ellipse_edge 72c26cfea5d72658
    \\k1.ellipse_thin 4655f7d2a6a1e605
    \\k1.ellipse_thick f551fd546324f17f
    \\k1.ellipse_fill cdbd4c5fdbfb4875
    \\k1.circle 27d5fa60112bfd72
    \\k1.ellipse_brush 63f560a14bdf6dfe
    \\k1.ellipse_brush2 cca774af52d053c2
    \\k1.ellipse_edge 6d5611b6f74aaa0d
    \\m8.ellipse_thin a4f8b7e8e169a68d
    \\m8.ellipse_thick f81e56d17df92ea7
    \\m8.ellipse_fill af2f4cb763f31d9f
    \\m8.circle db77a125f1237d47
    \\m8.ellipse_brush 49937a89134ab610
    \\m8.ellipse_brush2 a22e4217c461fed2
    \\m8.ellipse_edge 89bbcd83a5d0d1d6
    \\r8g8b8a8.ellipse_thin 805b65ee06b9f65d
    \\r8g8b8a8.ellipse_thick cc0935ad95dcc775
    \\r8g8b8a8.ellipse_fill ea0ad9a2e4991133
    \\r8g8b8a8.circle afe98fa30869490f
    \\r8g8b8a8.ellipse_brush 76be5850c462198b
    \\r8g8b8a8.ellipse_brush2 15f5f49ce80b21d3
    \\r8g8b8a8.ellipse_edge 28c2c51894286660
;
