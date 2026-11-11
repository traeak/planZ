//! Software cursor.
//! from 9/port/swcursor.c
//!
//! DIFF:
//!   - gscreen, flushmemscreen and mouseredraw are imported from
//!     screen.zig and devmouse.zig; the C declares them extern.
//!   - The cursor's offset comes from a write to /dev/cursor and can
//!     be any number; adding it to the mouse position relies on addpt
//!     and rectaddpt wrapping (libdraw/arith.zig) and on memimagedraw
//!     and flushmemscreen clipping what comes out.
//!   - swcursorinit forgets the old images before it frees them, so
//!     that a failed allocation cannot leave a freed image behind for
//!     the other functions to draw with (the C keeps the stale
//!     pointers until they are overwritten).

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw = @import("../libmemdraw/memdraw.zig");
const memalloc = @import("../libmemdraw/alloc.zig");
const mdraw = @import("../libmemdraw/draw.zig");
const screen = @import("screen.zig");
const devmouse = @import("devmouse.zig");
const p9 = @import("print.zig");

const print = p9.print;
const Rect = arith.Rect;
const addpt = arith.addpt;
const rectaddpt = arith.rectaddpt;
const rectXrect = arith.rectXrect;
const combinerect = arith.combinerect;
const allocmemimage = memalloc.allocmemimage;
const freememimage = memalloc.freememimage;
const byteaddr = memalloc.byteaddr;
const memimagedraw = mdraw.memimagedraw;
const memfillcolor = mdraw.memfillcolor;
const flushmemscreen = screen.flushmemscreen;
const mouseredraw = devmouse.mouseredraw;

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw.Memimage;
const Cursor = screen.Cursor;
const ZP = draw.ZP;
const ZR = draw.ZR;

var swback: ?*Memimage = null; // screen under cursor
var swimg: ?*Memimage = null; // cursor image
var swmask: ?*Memimage = null; // cursor mask
var swimg1: ?*Memimage = null;
var swmask1: ?*Memimage = null;

var swoffset: Point = .{};
var swrect: Rectangle = .{}; // screen rectangle in swback
var swvispt: Point = .{}; // actual cursor location
var swvisible: bool = false; // is the cursor visible?

/// called with drawlock locked for us, most of the time.
/// kernel prints at inopportune times might mean we don't
/// hold the lock, but memimagedraw is now reentrant so
/// that should be okay: worst case we get cursor droppings.
pub fn swcursorhide(doflush: bool) void {
    if (!swvisible)
        return;
    swvisible = false;
    const back = swback orelse return;
    const gscreen = screen.gscreen orelse return;
    memimagedraw(gscreen, swrect, back, ZP, memdraw.memopaque, ZP, draw.S);
    if (doflush) {
        flushmemscreen(swrect);
        swrect = ZR;
    }
}

pub fn swcursoravoid(r: Rectangle) void {
    if (swvisible and rectXrect(r, swrect)) {
        swcursorhide(false);
        mouseredraw(); // schedule cursor redraw after we release drawlock
    }
}

pub fn swcursordraw(p: Point) void {
    if (swvisible)
        return;
    const back = swback orelse return;
    const img1 = swimg1 orelse return;
    const mask1 = swmask1 orelse return;
    const gscreen = screen.gscreen orelse return;
    swvispt = addpt(swoffset, p);
    var flushr = swrect;
    swrect = rectaddpt(img1.r, swvispt);
    combinerect(&flushr, swrect);
    memimagedraw(back, back.r, gscreen, swvispt, memdraw.memopaque, ZP, draw.S);
    memimagedraw(gscreen, swrect, img1, ZP, mask1, ZP, draw.SoverD);
    flushmemscreen(flushr);
    swvisible = true;
}

pub fn swcursorload(curs: *const Cursor) void {
    const img = swimg orelse return;
    const mask = swmask orelse return;
    const img1 = swimg1 orelse return;
    const mask1 = swmask1 orelse return;
    //
    // Build cursor image and mask.
    // Image is just the usual cursor image
    // but mask is a transparent alpha mask.
    //
    // The 16x16x8 memimages do not have
    // padding at the end of their scan lines.
    //
    var ip = byteaddr(img, ZP);
    var mp = byteaddr(mask, ZP);
    for (0..32) |i| {
        const set = curs.set[i];
        const clr = curs.clr[i];
        var j: u8 = 0x80;
        while (j != 0) : (j >>= 1) {
            ip[0] = if (set & j != 0) 0x00 else 0xFF;
            ip += 1;
            mp[0] = if ((clr | set) & j != 0) 0xFF else 0x00;
            mp += 1;
        }
    }
    swoffset = curs.offset;
    memimagedraw(img1, img1.r, img, ZP, memdraw.memopaque, ZP, draw.S);
    memimagedraw(mask1, mask1.r, mask, ZP, memdraw.memopaque, ZP, draw.S);
}

pub fn swcursorinit() void {
    swvisible = false;
    const gscreen = screen.gscreen orelse return;

    if (swback != null) {
        const old = .{ swback, swmask, swmask1, swimg, swimg1 };
        swback = null; // DIFF: see the header
        swmask = null;
        swmask1 = null;
        swimg = null;
        swimg1 = null;
        inline for (old) |i| freememimage(i);
    }
    swback = allocmemimage(Rect(0, 0, 16, 16), gscreen.chan);
    swmask = allocmemimage(Rect(0, 0, 16, 16), draw.GREY8);
    swmask1 = allocmemimage(Rect(0, 0, 16, 16), draw.GREY1);
    swimg = allocmemimage(Rect(0, 0, 16, 16), draw.GREY8);
    swimg1 = allocmemimage(Rect(0, 0, 16, 16), draw.GREY1);
    if (swback == null or swmask == null or swmask1 == null or swimg == null or swimg1 == null) {
        print("software cursor: allocmemimage fails\n", .{});
        return;
    }
    memfillcolor(swback.?, draw.DTransparent);
    memfillcolor(swmask.?, draw.DOpaque);
    memfillcolor(swmask1.?, draw.DOpaque);
    memfillcolor(swimg.?, draw.DBlack);
    memfillcolor(swimg1.?, draw.DBlack);
}
