//! loadmemimage: copy packed pixel data into an image.
//! From /sys/src/libmemdraw/load.c.
//!
//! DIFF: the data is a slice.

const draw = @import("../libdraw/draw.zig");
const memdraw = @import("memdraw.zig");
const kernel = @import("kernel.zig");
const badrect = @import("../libdraw/badrect.zig").badrect;
const rectinrect = @import("../libdraw/arith.zig").rectinrect;
const bytesperline = @import("../libdraw/bytesperline.zig").bytesperline;
const byteaddr = @import("alloc.zig").byteaddr;
const hwdraw = @import("hwdraw.zig").hwdraw;

const Rectangle = draw.Rectangle;
const Memimage = memdraw.Memimage;
const Memdrawparam = memdraw.Memdrawparam;
const Dy = draw.Dy;
const werrstr = kernel.werrstr;

var par: Memdrawparam = undefined;

pub fn loadmemimage(i: *Memimage, r: Rectangle, data_: []const u8) i32 {
    var data = data_.ptr;

    if (badrect(r) or !rectinrect(r, i.r)) {
        werrstr("loadmemimage: bad rectangle", .{});
        return -1;
    }
    const l: usize = @intCast(bytesperline(r, i.depth));
    const dy: usize = @intCast(Dy(r));
    if (data_.len < l * dy) {
        werrstr("loadmemimage: insufficient data", .{});
        return -1;
    }
    const ndata: i32 = @intCast(l * dy);

    // avoid sw cursor
    par.dst = i;
    par.src = null;
    par.mask = null;
    par.r = r;
    _ = hwdraw(&par);

    var q = byteaddr(i, r.min);
    const stride: usize = i.width * @sizeOf(u32);
    const mx: i32 = @divTrunc(7, i.depth);
    const lpart: u4 = @intCast((r.min.x & mx) * i.depth);
    const rpart: u4 = @intCast((r.max.x & mx) * i.depth);
    var m: u8 = @as(u8, 0xFF) >> @intCast(lpart);
    var y: i32 = undefined;
    // may need to do bit insertion on edges
    if (l == 1) { // all in one byte
        if (rpart != 0)
            m ^= @as(u8, 0xFF) >> @intCast(rpart);
        y = r.min.y;
        while (y < r.max.y) : (y += 1) {
            q[0] ^= (data[0] ^ q[0]) & m;
            q += stride;
            data += 1;
        }
        return ndata;
    }
    if (lpart == 0 and rpart == 0) { // easy case
        y = r.min.y;
        while (y < r.max.y) : (y += 1) {
            @memmove(q[0..l], data[0..l]);
            q += stride;
            data += l;
        }
        return ndata;
    }
    const mr: u8 = 0xFF ^ (@as(u8, 0xFF) >> @intCast(rpart));
    if (lpart != 0 and rpart == 0) {
        y = r.min.y;
        while (y < r.max.y) : (y += 1) {
            q[0] ^= (data[0] ^ q[0]) & m;
            if (l > 1)
                @memmove(q[1..l], data[1..l]);
            q += stride;
            data += l;
        }
        return ndata;
    }
    if (lpart == 0 and rpart != 0) {
        y = r.min.y;
        while (y < r.max.y) : (y += 1) {
            if (l > 1)
                @memmove(q[0 .. l - 1], data[0 .. l - 1]);
            q[l - 1] ^= (data[l - 1] ^ q[l - 1]) & mr;
            q += stride;
            data += l;
        }
        return ndata;
    }
    y = r.min.y;
    while (y < r.max.y) : (y += 1) {
        q[0] ^= (data[0] ^ q[0]) & m;
        if (l > 2)
            @memmove(q[1 .. l - 1], data[1 .. l - 1]);
        q[l - 1] ^= (data[l - 1] ^ q[l - 1]) & mr;
        q += stride;
        data += l;
    }
    return ndata;
}
