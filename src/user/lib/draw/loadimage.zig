//! Load pixels into an image.
//! From /sys/src/libdraw/loadimage.c (9front 11952).
//!
//! DIFF: data is a slice, whose length is the C's ndata; the count of
//! bytes used is returned in an error union.

const libc = @import("libc");
const D = @import("libdraw.zig");
const Image = D.Image;
const Rectangle = D.Rectangle;
const BPLONG = D.BPLONG;

pub fn loadimage(i: *Image, r_: Rectangle, data_: []const u8) D.Error!usize {
    var r = r_;
    var data = data_;
    const chunk: i64 = i.display.bufsize - 64;

    if (!D.rectinrect(r, i.r)) {
        libc.werrstr("loadimage: bad rectangle", .{});
        return error.Plan9;
    }
    const bpl: i64 = D.bytesperline(r, i.depth);
    var n: i64 = bpl * D.Dy(r);
    if (n > data.len) {
        libc.werrstr("loadimage: insufficient data", .{});
        return error.Plan9;
    }
    var ndata: usize = 0;
    while (r.max.y > r.min.y) {
        var dy: i64 = D.Dy(r);
        var dx: i64 = D.Dx(r);
        if (dy * bpl > chunk)
            dy = @divTrunc(chunk, bpl);
        if (dy <= 0) {
            dy = 1;
            dx = @divTrunc(chunk * dx, bpl) & ~@as(i64, 7);
            n = D.bytesperline(D.Rect(r.min.x, r.min.y, r.min.x + @as(i32, @intCast(dx)), r.min.y + 1), i.depth);
            _ = try loadimage(i, D.Rect(r.min.x + @as(i32, @intCast(dx)), r.min.y, r.max.x, r.min.y + 1), data[@intCast(n)..@intCast(bpl)]);
        } else n = dy * bpl;
        const un: usize = @intCast(n);
        const a = D.bufimage(i.display, 21 + un) catch {
            libc.werrstr("loadimage: %r", .{});
            return error.Plan9;
        };
        a[0] = 'y';
        BPLONG(a[1..], @bitCast(i.id));
        BPLONG(a[5..], @bitCast(r.min.x));
        BPLONG(a[9..], @bitCast(r.min.y));
        BPLONG(a[13..], @bitCast(r.min.x + @as(i32, @intCast(dx))));
        BPLONG(a[17..], @bitCast(r.min.y + @as(i32, @intCast(dy))));
        @memcpy(a[21..][0..un], data[0..un]);
        const used: usize = @intCast(dy * bpl);
        ndata += used;
        data = data[used..];
        r.min.y += @intCast(dy);
    }
    return ndata;
}
