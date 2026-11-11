//! drawrepl: map a point into a replicated rectangle.
//! From /sys/src/libdraw/drawrepl.c.
//!
//! DIFF: the arithmetic wraps, as C's does on its compilers: the point
//! comes from user programs through devdraw.  An empty rectangle (the C
//! divides by zero) or one whose size wrapped to -1 (-2^31 % -1 traps on
//! amd64) gives `min`; no image has such a rectangle.

const draw = @import("draw.zig");
const Point = draw.Point;
const Rectangle = draw.Rectangle;

pub fn drawreplxy(min: i32, max: i32, x: i32) i32 {
    const d = max -% min;
    if (d == 0 or d == -1) // DIFF: the C divides (see the header)
        return min;
    var sx: i32 = @rem(x -% min, d);
    if (sx < 0)
        sx +%= d;
    return sx +% min;
}

pub fn drawrepl(r: Rectangle, p_: Point) Point {
    var p = p_;
    p.x = drawreplxy(r.min.x, r.max.x, p.x);
    p.y = drawreplxy(r.min.y, r.max.y, p.y);
    return p;
}

test "drawrepl" {
    const std = @import("std");
    const t = std.testing;
    try t.expectEqual(@as(i32, 3), drawreplxy(3, 7, 7));
    try t.expectEqual(@as(i32, 6), drawreplxy(3, 7, 2));
    try t.expectEqual(@as(i32, 6), drawreplxy(3, 7, -2));
    try t.expectEqual(@as(i32, 5), drawreplxy(3, 7, 5));
    const r: Rectangle = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 4, .y = 2 } };
    try t.expectEqual(Point{ .x = 3, .y = 1 }, drawrepl(r, .{ .x = -1, .y = -1 }));
}
