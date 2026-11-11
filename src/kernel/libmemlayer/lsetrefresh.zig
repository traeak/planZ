//! memlsetrefresh: change how a layer's hidden parts are restored.
//! From /sys/src/libmemlayer/lsetrefresh.c.
//!
//! DIFF: returns bool (the C returns 1, or 0 when the backing image
//! cannot be allocated).

const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");
const malloc = @import("../libmemdraw/alloc.zig");

const Memimage = memdraw_h.Memimage;
const Refreshfn = memlayer_h.Refreshfn;
const allocmemimage = malloc.allocmemimage;
const freememimage = malloc.freememimage;

pub fn memlsetrefresh(i: *Memimage, @"fn": ?Refreshfn, ptr: ?*anyopaque) bool {
    const l = i.layer.?;
    if (l.refreshfn != null and @"fn" != null) { // just change functions
        l.refreshfn = @"fn";
        l.refreshptr = ptr;
        return true;
    }

    if (l.refreshfn == null) { // is using backup image; just free it
        freememimage(l.save);
        l.save = null;
        l.refreshfn = @"fn";
        l.refreshptr = ptr;
        return true;
    }

    l.save = allocmemimage(i.r, i.chan) orelse
        return false;
    // easiest way is just to update the entire save area
    l.refreshfn.?(i, i.r, l.refreshptr);
    l.refreshfn = null;
    l.refreshptr = null;
    return true;
}
