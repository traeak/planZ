//! memldelete, memlfree and _memlsetclear.
//! From /sys/src/libmemlayer/ldelete.c.
//!
//! DIFF: none.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");
const kernel = @import("../libmemdraw/kernel.zig");
const malloc = @import("../libmemdraw/alloc.zig");
const ldraw = @import("draw.zig");
const ltorear = @import("ltorear.zig");

const Memimage = memdraw_h.Memimage;
const Memscreen = memlayer_h.Memscreen;
const rectinrect = arith.rectinrect;
const rectXrect = arith.rectXrect;
const freememimage = malloc.freememimage;
const memdraw = ldraw.memdraw;
const memltorear = ltorear.memltorear;

pub fn memldelete(i: *Memimage) void {
    const l = i.layer.?;
    // free backing store and disconnect refresh, to make pushback fast
    freememimage(l.save);
    l.save = null;
    l.refreshptr = null;
    memltorear(i);

    // window is now the rearmost;  clean up screen structures and deallocate
    const s = i.layer.?.screen;
    if (s.fill) |fill| {
        i.clipr = i.r;
        memdraw(i, i.r, fill, i.r.min, null, i.r.min, draw.S);
    }
    if (l.front) |front| {
        front.layer.?.rear = null;
        s.rearmost = front;
    } else {
        s.frontmost = null;
        s.rearmost = null;
    }
    kernel.free(l);
    freememimage(i);
}

//
// Just free the data structures, don't do graphics
//
pub fn memlfree(i: *Memimage) void {
    const l = i.layer.?;
    freememimage(l.save);
    kernel.free(l);
    freememimage(i);
}

pub fn _memlsetclear(s: *Memscreen) void {
    var ip = s.rearmost;
    while (ip) |i| : (ip = i.layer.?.front) {
        const l = i.layer.?;
        l.clear = rectinrect(l.screenr, l.screen.image.clipr);
        if (l.clear) {
            var jp = l.front;
            while (jp) |j| : (jp = j.layer.?.front) {
                if (rectXrect(l.screenr, j.layer.?.screenr)) {
                    l.clear = false;
                    break;
                }
            }
        }
    }
}
