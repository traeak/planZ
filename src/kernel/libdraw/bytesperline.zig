//! wordsperline, bytesperline: storage for one scan line of an image.
//! From /sys/src/libdraw/bytesperline.c.
//!
//! DIFF:
//!   - Where the C calls abort() for a depth outside 1..32, this
//!     panics.
//!   - The arithmetic wraps, as C's does on its compilers.  devdraw's
//!     'r' asks for the size of a rectangle it has only checked with
//!     rectinrect, which an inverted rectangle with any max passes.

const draw = @import("draw.zig");
const Rectangle = draw.Rectangle;

fn unitsperline(r: Rectangle, d: i32, bitsperunit: i32) i32 {
    if (d <= 0 or d > 32) // being called wrong.  d is image depth.
        @panic("unitsperline: bad depth");
    return @divTrunc(r.max.x *% d -% ((r.min.x *% d) & -bitsperunit) +% bitsperunit -% 1, bitsperunit);
}

pub fn wordsperline(r: Rectangle, d: i32) i32 {
    return unitsperline(r, d, 8 * @sizeOf(u32));
}

pub fn bytesperline(r: Rectangle, d: i32) i32 {
    return unitsperline(r, d, 8);
}

test "bytesperline" {
    const std = @import("std");
    const t = std.testing;
    const R = struct {
        fn f(a: i32, c: i32) Rectangle {
            return .{ .min = .{ .x = a, .y = 0 }, .max = .{ .x = c, .y = 1 } };
        }
    }.f;
    try t.expectEqual(@as(i32, 1), bytesperline(R(0, 8), 1));
    try t.expectEqual(@as(i32, 2), bytesperline(R(0, 9), 1));
    try t.expectEqual(@as(i32, 2), bytesperline(R(7, 9), 1));
    try t.expectEqual(@as(i32, 1), bytesperline(R(8, 9), 1));
    try t.expectEqual(@as(i32, 4), bytesperline(R(-9, 9), 1));
    try t.expectEqual(@as(i32, 40), bytesperline(R(0, 10), 32));
    try t.expectEqual(@as(i32, 1), wordsperline(R(0, 32), 1));
    try t.expectEqual(@as(i32, 2), wordsperline(R(31, 33), 1));
    try t.expectEqual(@as(i32, 2), wordsperline(R(-1, 1), 8));
    try t.expectEqual(@as(i32, 3), wordsperline(R(1, 4), 24));
}
