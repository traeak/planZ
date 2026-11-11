//! memunload: read pixel data out of an image that may be a layer.
//! From /sys/src/libmemlayer/unload.c.
//!
//! DIFF:
//!   - The buffer is a slice; the goto to Top is a loop.
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
const unloadmemimage = @import("../libmemdraw/unload.zig").unloadmemimage;
const allocmemimage = malloc.allocmemimage;
const freememimage = malloc.freememimage;
const memdraw = ldraw.memdraw;
const memlhide = lhide.memlhide;

pub fn memunload(src_: *Memimage, r_: Rectangle, data: []u8) i32 {
    var src = src_;
    var r = r_;
    var n: i32 = undefined;

    while (true) {
        const dl = src.layer orelse
            return unloadmemimage(src, r, data);

        //
        // Convert to screen coordinates.
        //
        const lr = r;
        r.min.x +%= dl.delta.x;
        r.min.y +%= dl.delta.y;
        r.max.x +%= dl.delta.x;
        r.max.y +%= dl.delta.y;
        const dx = dl.delta.x & @divTrunc(7, src.depth);
        if (dl.clear and dx == 0) {
            src = dl.screen.image;
            continue;
        }

        //
        // src is an obscured layer or data is unaligned
        //
        if (dl.save != null and dx == 0) {
            if (dl.refreshfn != null)
                return -1; // can't unload window if it's not Refbackup
            if (data.len > 0)
                memlhide(src, r);
            n = unloadmemimage(dl.save.?, lr, data);
            return n;
        }
        const tmp = allocmemimage(lr, src.chan) orelse
            return -1;
        memdraw(tmp, lr, src, lr.min, null, lr.min, draw.S);
        n = unloadmemimage(tmp, lr, data);
        freememimage(tmp);
        return n;
    }
}
