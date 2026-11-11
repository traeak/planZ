//! badrect: is a rectangle empty, inverted or too big for an image?
//! From /sys/src/libdraw/badrect.c.
//!
//! DIFF: returns bool.  The multiplications wrap as the C's do on its
//! compilers (they are checked by dividing back).

const draw = @import("draw.zig");
const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Dx = draw.Dx;
const Dy = draw.Dy;

//
// XOVFL protects the unitsperline() calculation, and its
// limit is based on:
//      -2^31 <= r.max.x*32 + r.min.x*32 < 2^31
//      -2^26 <= r.max.x + r.min.x       < 2^26
//      -2^25 <= r.min.x, r.max.x        < 2^25
// for the worst case scenario where the depth is 32 and one of
// the values is negative.
//
// YOVFL is meant to protect against overflow when
// calculating the Memimage.zero and byteaddr(2) offsets.  Its
// limit is derived from:
//      -2^31 <= p.y*4*wpl + p.x*depth/8 < 2^31
//      -2^30 <= p.y*4*wpl               < 2^30
//      -2^28 <= p.y*wpl                 < 2^28
// for the worst case scenario where both coordinates have the
// same sign and wpl = Dx(r).
//
fn XOVFL(p: Point) bool {
    return p.x < -(1 << 25) or p.x >= (1 << 25);
}
fn YOVFL(y: i32) bool {
    return y < -(1 << 28) or y >= (1 << 28);
}

//
// check for zero, negative size or insanely huge rectangle.
//
pub fn badrect(r: Rectangle) bool {
    const x: i32 = r.max.x -% r.min.x;
    const y: i32 = r.max.y -% r.min.y;
    if (x > 0 and y > 0) {
        if (XOVFL(r.min) or XOVFL(r.max))
            return true;
        const z: u32 = @bitCast(x *% y);
        const zy0: i32 = x *% r.min.y;
        const zy1: i32 = x *% r.max.y;
        if (z / @as(u32, @intCast(x)) == @as(u32, @intCast(y)) and
            @divTrunc(zy0, x) == r.min.y and !YOVFL(zy0) and
            @divTrunc(zy1, x) == r.max.y and !YOVFL(zy1))
            return false;
    }
    return true;
}

test "badrect" {
    const std = @import("std");
    const t = std.testing;
    const R = struct {
        fn f(a: i32, b: i32, c: i32, d: i32) Rectangle {
            return .{ .min = .{ .x = a, .y = b }, .max = .{ .x = c, .y = d } };
        }
    }.f;
    try t.expect(!badrect(R(0, 0, 1, 1)));
    try t.expect(!badrect(R(-100, -100, 1280, 800)));
    try t.expect(badrect(R(0, 0, 0, 10)));
    try t.expect(badrect(R(5, 5, 4, 10)));
    try t.expect(badrect(R(0, 0, 1 << 25, 1)));
    try t.expect(badrect(R(-(1 << 25) - 1, 0, 0, 1)));
    try t.expect(badrect(R(0, 0, 1 << 20, 1 << 20)));
    try t.expect(badrect(R(0, 0, 1 << 16, 1 << 16)));
    try t.expect(badrect(R(0, std.math.minInt(i32), 10, std.math.maxInt(i32))));
    try t.expect(!badrect(R(0, 0, 1 << 14, 1 << 14 - 1)));
}
