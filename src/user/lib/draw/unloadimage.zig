//! Read pixels back from an image.
//! From /sys/src/libdraw/unloadimage.c (9front 11952).
//!
//! DIFF: data is a slice, whose length is the C's ndata; the count of
//! bytes read is returned in an error union.

const libc = @import("libc");
const D = @import("libdraw.zig");
const Image = D.Image;
const Rectangle = D.Rectangle;
const BPLONG = D.BPLONG;

pub fn unloadimage(i: *Image, r_: Rectangle, data_: []u8) D.Error!usize {
    var r = r_;
    var data = data_;

    if (!D.rectinrect(r, i.r)) {
        libc.werrstr("unloadimage: bad rectangle", .{});
        return error.Plan9;
    }
    const bpl: i32 = D.bytesperline(r, i.depth);
    if (data.len < @as(i64, bpl) * D.Dy(r)) {
        libc.werrstr("unloadimage: buffer too small", .{});
        return error.Plan9;
    }
    var nread: usize = 0;
    const d = i.display;
    const chunk = d.bufsize;
    D.flushimage(d, false) catch {}; // make sure subsequent flush is for us only
    while (r.min.y < r.max.y) {
        var dx = D.Dx(r);
        var dy = @divTrunc(chunk, bpl);
        var n: i32 = undefined;
        if (dy <= 0) {
            dy = 1;
            dx = @divTrunc(chunk *% dx, bpl) & ~@as(i32, 7);
            n = D.bytesperline(D.Rect(r.min.x, r.min.y, r.min.x + dx, r.min.y + dy), i.depth);
            _ = try unloadimage(i, D.Rect(r.min.x + dx, r.min.y, r.max.x, r.min.y + dy), data[@intCast(n)..@intCast(bpl)]);
        } else {
            if (dy > D.Dy(r))
                dy = D.Dy(r);
            n = bpl * dy;
        }
        const a = D.bufimage(d, 1 + 4 + 4 * 4) catch {
            libc.werrstr("unloadimage: %r", .{});
            return error.Plan9;
        };
        a[0] = 'r';
        BPLONG(a[1..], @bitCast(i.id));
        BPLONG(a[5..], @bitCast(r.min.x));
        BPLONG(a[9..], @bitCast(r.min.y));
        BPLONG(a[13..], @bitCast(r.min.x + dx));
        BPLONG(a[17..], @bitCast(r.min.y + dy));
        try D.flushimage(d, false);
        _ = try libc.read(d.fd, data[0..@intCast(n)]);
        const used: usize = @intCast(bpl * dy);
        nread += used;
        data = data[used..];
        r.min.y += dy;
    }
    return nread;
}
