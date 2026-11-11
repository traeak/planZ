//! rectclip: clip one rectangle to another.
//! From /sys/src/libdraw/rectclip.c.
//!
//! DIFF: returns bool.

const draw = @import("draw.zig");
const Rectangle = draw.Rectangle;

pub fn rectclip(rp: *Rectangle, b: Rectangle) bool { // first by reference, second by value
    const bp = &b;
    //
    // Expand rectXrect() in line for speed
    //
    if (!(rp.min.x < bp.max.x and bp.min.x < rp.max.x and
        rp.min.y < bp.max.y and bp.min.y < rp.max.y))
        return false;
    // They must overlap
    if (rp.min.x < bp.min.x)
        rp.min.x = bp.min.x;
    if (rp.min.y < bp.min.y)
        rp.min.y = bp.min.y;
    if (rp.max.x > bp.max.x)
        rp.max.x = bp.max.x;
    if (rp.max.y > bp.max.y)
        rp.max.y = bp.max.y;
    return true;
}

test "rectclip" {
    const std = @import("std");
    const t = std.testing;
    const R = struct {
        fn f(a: i32, b: i32, c: i32, d: i32) Rectangle {
            return .{ .min = .{ .x = a, .y = b }, .max = .{ .x = c, .y = d } };
        }
    }.f;
    var r = R(0, 0, 10, 10);
    try t.expect(rectclip(&r, R(5, -5, 20, 7)));
    try t.expectEqual(R(5, 0, 10, 7), r);
    r = R(0, 0, 10, 10);
    try t.expect(!rectclip(&r, R(10, 0, 20, 10)));
    try t.expectEqual(R(0, 0, 10, 10), r);
    try t.expect(rectclip(&r, R(-100, -100, 100, 100)));
    try t.expectEqual(R(0, 0, 10, 10), r);
}
