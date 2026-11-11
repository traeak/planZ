//! memltorear: push layers to the back of their screen.
//! From /sys/src/libmemlayer/ltorear.c.
//!
//! DIFF:
//!   - memltorearn takes a slice.
//!   - _memltorear stops when it runs out of windows behind i without
//!     having met `rear`, where the C dereferences the nil; see
//!     ltofront.zig.

const memdraw_h = @import("../libmemdraw/memdraw.zig");
const lhide = @import("lhide.zig");
const ldelete = @import("ldelete.zig");

const Memimage = memdraw_h.Memimage;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const memlhide = lhide.memlhide;
const memlexpose = lhide.memlexpose;
const _memlsetclear = ldelete._memlsetclear;

pub fn _memltorear(i: *Memimage, rear: ?*Memimage) void {
    const l = i.layer.?;
    const s = l.screen;
    while (l.rear != rear) {
        // DIFF: see the header
        const r = l.rear orelse break;
        var x = l.screenr;
        const overlap = rectclip(&x, r.layer.?.screenr);
        if (overlap) {
            memlhide(i, x);
            l.clear = false;
        }
        // swap l and r in screen's list
        const rr = r.layer.?.rear;
        const f = l.front;
        if (rr) |p|
            p.layer.?.front = i
        else
            s.rearmost = i;
        if (f) |p|
            p.layer.?.rear = r
        else
            s.frontmost = r;
        l.rear = rr;
        l.front = r;
        r.layer.?.rear = i;
        r.layer.?.front = f;
        if (overlap)
            memlexpose(r, x);
    }
}

pub fn memltorear(i: *Memimage) void {
    _memltorear(i, null);
    _memlsetclear(i.layer.?.screen);
}

pub fn memltorearn(ip: []const *Memimage) void {
    if (ip.len == 0)
        return;
    var rear: ?*Memimage = null;
    for (ip) |i| {
        _memltorear(i, rear);
        rear = i;
    }
    const s = rear.?.layer.?.screen;
    _memlsetclear(s);
}
