//! The default font's data and the subfont header unpacker.
//! From /sys/src/libdraw/defont.c.
//!
//! DIFF:
//!   - The bytes of the C's initialiser (vga/vga00, in uncompressed
//!     form) are in port/defont.bin, extracted from defont.c, and are
//!     embedded from there.  The array is aligned to 4 so that
//!     getmemdefont never has to shift it, and is a variable because
//!     a Memimage points into it.
//!   - _unpackinfo takes the info as a slice of n+1 entries.

const draw = @import("draw.zig");
const Fontchar = draw.Fontchar;

const data = @embedFile("../port/defont.bin");

pub var defontdata: [data.len]u8 align(4) = data.*;

pub const sizeofdefont: i32 = data.len;

pub fn _unpackinfo(fc: []Fontchar, p_: [*]const u8, n: i32) void {
    var p = p_;
    var j: usize = 0;
    while (j <= n) : (j += 1) {
        fc[j].x = @as(i32, p[0]) | (@as(i32, p[1]) << 8);
        fc[j].top = p[2];
        fc[j].bottom = p[3];
        fc[j].left = @bitCast(p[4]);
        fc[j].width = p[5];
        p += 6;
    }
}
