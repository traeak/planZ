//! Point and Rectangle arithmetic.
//! From /sys/src/libdraw/arith.c.
//!
//! DIFF:
//!   - The predicates return bool.
//!   - ZP and ZR are in draw.zig.
//!   - The arithmetic on coordinates wraps (`+%`, `-%`, `*%`), as C's
//!     does on its compilers: points and rectangles reach these
//!     functions from user programs through devdraw, and an overflow
//!     check would panic the kernel.

const draw = @import("draw.zig");
const Point = draw.Point;
const Rectangle = draw.Rectangle;

pub fn Pt(x: i32, y: i32) Point {
    return .{ .x = x, .y = y };
}

pub fn Rect(x: i32, y: i32, bx: i32, by: i32) Rectangle {
    const p0: Point = .{ .x = x, .y = y };
    const p1: Point = .{ .x = bx, .y = by };
    return .{ .min = p0, .max = p1 };
}

pub fn Rpt(min: Point, max: Point) Rectangle {
    return .{ .min = min, .max = max };
}

pub fn addpt(a_: Point, b: Point) Point {
    var a = a_;
    a.x +%= b.x;
    a.y +%= b.y;
    return a;
}

pub fn subpt(a_: Point, b: Point) Point {
    var a = a_;
    a.x -%= b.x;
    a.y -%= b.y;
    return a;
}

pub fn insetrect(r_: Rectangle, n: i32) Rectangle {
    var r = r_;
    r.min.x +%= n;
    r.min.y +%= n;
    r.max.x -%= n;
    r.max.y -%= n;
    return r;
}

pub fn divpt(a_: Point, b: i32) Point {
    var a = a_;
    a.x = wdiv(a.x, b);
    a.y = wdiv(a.y, b);
    return a;
}

/// C's `/` as the compilers do it: -2^31 / -1 wraps.  Dividing by
/// zero traps there as it does here.
fn wdiv(a: i32, b: i32) i32 {
    if (b == -1)
        return -%a;
    return @divTrunc(a, b);
}

pub fn mulpt(a_: Point, b: i32) Point {
    var a = a_;
    a.x *%= b;
    a.y *%= b;
    return a;
}

pub fn rectsubpt(r_: Rectangle, p: Point) Rectangle {
    var r = r_;
    r.min.x -%= p.x;
    r.min.y -%= p.y;
    r.max.x -%= p.x;
    r.max.y -%= p.y;
    return r;
}

pub fn rectaddpt(r_: Rectangle, p: Point) Rectangle {
    var r = r_;
    r.min.x +%= p.x;
    r.min.y +%= p.y;
    r.max.x +%= p.x;
    r.max.y +%= p.y;
    return r;
}

pub fn eqpt(p: Point, q: Point) bool {
    return p.x == q.x and p.y == q.y;
}

pub fn eqrect(r: Rectangle, s: Rectangle) bool {
    return r.min.x == s.min.x and r.max.x == s.max.x and
        r.min.y == s.min.y and r.max.y == s.max.y;
}

pub fn rectXrect(r: Rectangle, s: Rectangle) bool {
    return r.min.x < s.max.x and s.min.x < r.max.x and
        r.min.y < s.max.y and s.min.y < r.max.y;
}

pub fn rectinrect(r: Rectangle, s: Rectangle) bool {
    return s.min.x <= r.min.x and r.max.x <= s.max.x and s.min.y <= r.min.y and r.max.y <= s.max.y;
}

pub fn ptinrect(p: Point, r: Rectangle) bool {
    return p.x >= r.min.x and p.x < r.max.x and
        p.y >= r.min.y and p.y < r.max.y;
}

pub fn canonrect(r_: Rectangle) Rectangle {
    var r = r_;
    var t: i32 = undefined;
    if (r.max.x < r.min.x) {
        t = r.min.x;
        r.min.x = r.max.x;
        r.max.x = t;
    }
    if (r.max.y < r.min.y) {
        t = r.min.y;
        r.min.y = r.max.y;
        r.max.y = t;
    }
    return r;
}

pub fn combinerect(r1: *Rectangle, r2: Rectangle) void {
    if (r1.min.x > r2.min.x)
        r1.min.x = r2.min.x;
    if (r1.min.y > r2.min.y)
        r1.min.y = r2.min.y;
    if (r1.max.x < r2.max.x)
        r1.max.x = r2.max.x;
    if (r1.max.y < r2.max.y)
        r1.max.y = r2.max.y;
}

pub const drawld2chan = [4]u32{
    draw.GREY1,
    draw.GREY2,
    draw.GREY4,
    draw.CMAP8,
};

pub fn setalpha(color: u32, alpha: u8) u32 {
    var red: u32 = (color >> 3 * 8) & 0xFF;
    var green: u32 = (color >> 2 * 8) & 0xFF;
    var blue: u32 = (color >> 1 * 8) & 0xFF;
    // ignore incoming alpha
    red = (red * alpha) / 255;
    green = (green * alpha) / 255;
    blue = (blue * alpha) / 255;
    return (red << 3 * 8) | (green << 2 * 8) | (blue << 1 * 8) | (@as(u32, alpha) << 0 * 8);
}

test "arith" {
    const std = @import("std");
    const t = std.testing;
    const r = Rect(1, 2, 10, 20);
    try t.expect(eqrect(rectsubpt(rectaddpt(r, Pt(3, 4)), Pt(3, 4)), r));
    try t.expect(eqrect(canonrect(Rect(10, 20, 1, 2)), r));
    try t.expect(ptinrect(Pt(1, 2), r) and !ptinrect(Pt(10, 2), r));
    try t.expect(rectinrect(insetrect(r, 1), r) and !rectinrect(r, insetrect(r, 1)));
    try t.expect(rectXrect(r, Rect(9, 19, 30, 30)) and !rectXrect(r, Rect(10, 2, 30, 30)));
    var c = r;
    combinerect(&c, Rect(0, 5, 5, 25));
    try t.expect(eqrect(c, Rect(0, 2, 10, 25)));
    try t.expectEqual(@as(u32, 0x7F00007F), setalpha(draw.DRed, 0x7F));
    try t.expect(eqpt(divpt(mulpt(Pt(-3, 5), 4), 4), Pt(-3, 5)));
}
