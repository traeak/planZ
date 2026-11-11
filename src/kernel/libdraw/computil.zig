//! Helpers for the compressed image format.
//! From /sys/src/libdraw/computil.c.
//!
//! DIFF: _twiddlecompressed takes a slice.

const draw = @import("draw.zig");
const Rectangle = draw.Rectangle;
const bytesperline = @import("bytesperline.zig").bytesperline;

//
// compressed data are seuences of byte codes.
// if the first byte b has the 0x80 bit set, the next (b^0x80)+1 bytes
// are data.  otherwise, it's two bytes specifying a previous string to repeat.
//
pub fn _twiddlecompressed(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const c: usize = buf[i];
        i += 1;
        if (c >= 128) {
            const k = c - 128 + 1;
            var j: usize = 0;
            while (j < k and i < buf.len) : ({
                j += 1;
                i += 1;
            })
                buf[i] ^= 0xFF;
        } else if (i < buf.len)
            i += 1;
    }
}

pub fn _compblocksize(r: Rectangle, depth: i32) i32 {
    var bpl = bytesperline(r, depth);
    bpl = 2 * bpl; // add plenty extra for blocking, etc.
    if (bpl < draw.NCBLOCK)
        return draw.NCBLOCK;
    return bpl;
}

test "computil" {
    const std = @import("std");
    var b = [_]u8{ 0x81, 0x00, 0x0F, 0x12, 0x34, 0x80, 0xAA, 0x85, 0x01 };
    _twiddlecompressed(&b);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0xFF, 0xF0, 0x12, 0x34, 0x80, 0x55, 0x85, 0xFE }, &b);
}
