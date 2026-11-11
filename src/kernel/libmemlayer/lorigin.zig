//! memlorigin: move a layer on the screen and change its coordinates.
//! From /sys/src/libmemlayer/lorigin.c.
//!
//! DIFF:
//!   - memlorigin fails (-1) when the new screen rectangle or the new
//!     logical rectangle would not be acceptable to allocmemimage
//!     (badrect).  The C checks only the logical one, and only when
//!     the window has a save area to reallocate; otherwise it lets
//!     the sums wrap, and devdraw's 'o' message can leave a window
//!     with an inverted rectangle on the screen's list for the rest of
//!     libmemlayer to trip over.
//!   - Coordinate arithmetic wraps (`+%`, `-%`), as C's does on its
//!     compilers: rectangles and points come from user programs
//!     through devdraw and an overflow check would panic the kernel.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");
const malloc = @import("../libmemdraw/alloc.zig");
const mdraw = @import("../libmemdraw/draw.zig");
const ldraw = @import("draw.zig");
const lalloc = @import("lalloc.zig");
const ldelete = @import("ldelete.zig");
const lhide = @import("lhide.zig");
const ltofront = @import("ltofront.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const Dx = draw.Dx;
const Dy = draw.Dy;
const ZP = draw.ZP;
const Rect = arith.Rect;
const eqpt = arith.eqpt;
const subpt = arith.subpt;
const rectaddpt = arith.rectaddpt;
const rectinrect = arith.rectinrect;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const badrect = @import("../libdraw/badrect.zig").badrect;
const allocmemimage = malloc.allocmemimage;
const freememimage = malloc.freememimage;
const memimagedraw = mdraw.memimagedraw;
const memdraw = ldraw.memdraw;
const memlalloc = lalloc.memlalloc;
const memldelete = ldelete.memldelete;
const memlhide = lhide.memlhide;
const memlexpose = lhide.memlexpose;
const memltofront = ltofront.memltofront;

//
// Place i so i->r.min = log, i->layer->screenr.min == scr.
//
pub fn memlorigin(i: *Memimage, log: Point, scr: Point) i32 {
    const l = i.layer.?;
    const s = l.screen;
    const oldr = l.screenr;
    const newr = Rect(scr.x, scr.y, scr.x +% Dx(oldr), scr.y +% Dy(oldr));
    const eqscr = eqpt(scr, oldr.min);
    const eqlog = eqpt(log, i.r.min);
    if (eqscr and eqlog)
        return 0;
    // DIFF: see the header
    if (badrect(newr) or badrect(Rect(log.x, log.y, log.x +% Dx(oldr), log.y +% Dy(oldr))))
        return -1;
    var nsave: ?*Memimage = null;
    if (!eqlog and l.save != null) {
        nsave = allocmemimage(Rect(log.x, log.y, log.x +% Dx(oldr), log.y +% Dy(oldr)), i.chan) orelse
            return -1;
    }

    //
    // Bring it to front and move logical coordinate system.
    //
    memltofront(i);
    const wasclear = l.clear;
    if (nsave) |ns| {
        if (!wasclear)
            memimagedraw(ns, ns.r, l.save.?, l.save.?.r.min, null, ZP, draw.S);
        freememimage(l.save);
        l.save = ns;
    }
    const delta = subpt(log, i.r.min);
    i.r = rectaddpt(i.r, delta);
    i.clipr = rectaddpt(i.clipr, delta);
    l.delta = subpt(l.screenr.min, i.r.min);
    if (eqscr)
        return 0;

    //
    // To clean up old position, make a shadow window there, don't paint it,
    // push it behind this one, and (later) delete it.  Because the refresh function
    // for this fake window is a no-op, this will cause no graphics action except
    // to restore the background and expose the windows previously hidden.
    //
    const shad = memlalloc(s, oldr, memlnorefresh, null, draw.DNofill) orelse
        return -1;
    s.frontmost = i;
    if (s.rearmost == i)
        s.rearmost = shad
    else
        l.rear.?.layer.?.front = shad;
    shad.layer.?.front = i;
    shad.layer.?.rear = l.rear;
    l.rear = shad;
    l.front = null;
    shad.layer.?.clear = false;

    //
    // Shadow is now holding down the fort at the old position.
    // Move the window and hide things obscured by new position.
    //
    var tp = l.rear.?.layer.?.rear;
    while (tp) |t| : (tp = t.layer.?.rear) {
        var x = newr;
        const overlap = rectclip(&x, t.layer.?.screenr);
        if (overlap) {
            memlhide(t, x);
            t.layer.?.clear = false;
        }
    }
    l.screenr = newr;
    l.delta = subpt(scr, i.r.min);
    l.clear = rectinrect(newr, l.screen.image.clipr);

    //
    // Everything's covered.  Copy to new position and delete shadow window.
    //
    if (wasclear)
        memdraw(s.image, newr, s.image, oldr.min, null, ZP, draw.S)
    else
        memlexpose(i, newr);
    memldelete(shad);

    return 1;
}

pub fn memlnorefresh(l: *Memimage, r: Rectangle, v: ?*anyopaque) void {
    _ = l;
    _ = r;
    _ = v;
}
