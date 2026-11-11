//! memload: load pixel data into an image that may be a layer.
//! From /sys/src/libmemlayer/load.c.
//!
//! DIFF:
//!   - The data is a slice and `iscompressed` is bool; the goto to Top
//!     is a loop.
//!   - Coordinate arithmetic wraps (`+%`, `-%`), as C's does on its
//!     compilers: rectangles and points come from user programs
//!     through devdraw and an overflow check would panic the kernel.

const draw = @import("../libdraw/draw.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const malloc = @import("../libmemdraw/alloc.zig");
const ldraw = @import("draw.zig");
const lhide = @import("lhide.zig");

const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const loadmemimage = @import("../libmemdraw/load.zig").loadmemimage;
const cloadmemimage = @import("../libmemdraw/cload.zig").cloadmemimage;
const allocmemimage = malloc.allocmemimage;
const freememimage = malloc.freememimage;
const memdraw = ldraw.memdraw;
const memlexpose = lhide.memlexpose;

pub fn memload(dst_: *Memimage, r_: Rectangle, data: []const u8, iscompressed: bool) i32 {
    var dst = dst_;
    var r = r_;
    var n: i32 = undefined;

    var loadfn: *const fn (*Memimage, Rectangle, []const u8) i32 = loadmemimage;
    if (iscompressed)
        loadfn = cloadmemimage;

    while (true) {
        const dl = dst.layer orelse
            return loadfn(dst, r, data);

        //
        // Convert to screen coordinates.
        //
        const lr = r;
        r.min.x +%= dl.delta.x;
        r.min.y +%= dl.delta.y;
        r.max.x +%= dl.delta.x;
        r.max.y +%= dl.delta.y;
        const dx = dl.delta.x & @divTrunc(7, dst.depth);
        if (dl.clear and dx == 0) {
            dst = dl.screen.image;
            continue;
        }

        //
        // dst is an obscured layer or data is unaligned
        //
        if (dl.save != null and dx == 0) {
            n = loadfn(dl.save.?, lr, data);
            if (n > 0)
                memlexpose(dst, r);
            return n;
        }
        const tmp = allocmemimage(lr, dst.chan) orelse
            return -1;
        n = loadfn(tmp, lr, data);
        memdraw(dst, lr, tmp, lr.min, null, lr.min, draw.S);
        freememimage(tmp);
        return n;
    }
}
