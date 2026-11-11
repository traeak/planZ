//! memltofront: pull layers to the front of their screen.
//! From /sys/src/libmemlayer/ltofront.c.
//!
//! DIFF:
//!   - memltofrontn takes a slice; `fill` is bool.
//!   - _memltofront stops when it runs out of windows in front of i
//!     without having met `front`.  The C dereferences the nil: a 't'
//!     message that names the same window twice makes memltofrontn ask
//!     for a window to be put behind itself (or behind one that is now
//!     behind it), and the kernel faults.  Here the window stays where
//!     it is, in front.

const memdraw_h = @import("../libmemdraw/memdraw.zig");
const lhide = @import("lhide.zig");
const ldelete = @import("ldelete.zig");

const Memimage = memdraw_h.Memimage;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const memlhide = lhide.memlhide;
const memlexpose = lhide.memlexpose;
const _memlsetclear = ldelete._memlsetclear;

//
// Pull i towards top of screen, just behind front
//
fn _memltofront(i: *Memimage, front: ?*Memimage, fill: bool) void {
    const l = i.layer.?;
    const s = l.screen;
    while (l.front != front) {
        // DIFF: see the header
        const f = l.front orelse break;
        var x = l.screenr;
        const overlap = rectclip(&x, f.layer.?.screenr);
        if (overlap) {
            memlhide(f, x);
            f.layer.?.clear = false;
        }
        // swap l and f in screen's list
        const ff = f.layer.?.front;
        const rr = l.rear;
        if (ff) |p|
            p.layer.?.rear = i
        else
            s.frontmost = i;
        if (rr) |p|
            p.layer.?.front = f
        else
            s.rearmost = f;
        l.front = ff;
        l.rear = f;
        f.layer.?.front = i;
        f.layer.?.rear = rr;
        if (overlap and fill)
            memlexpose(i, x);
    }
}

pub fn _memltofrontfill(i: *Memimage, fill: bool) void {
    _memltofront(i, null, fill);
    _memlsetclear(i.layer.?.screen);
}

pub fn memltofront(i: *Memimage) void {
    _memltofront(i, null, true);
    _memlsetclear(i.layer.?.screen);
}

pub fn memltofrontn(ip: []const *Memimage) void {
    if (ip.len == 0)
        return;
    var front: ?*Memimage = null;
    for (ip) |i| {
        _memltofront(i, front, true);
        front = i;
    }
    const s = front.?.layer.?.screen;
    _memlsetclear(s);
}
