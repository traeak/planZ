//! memlhide and memlexpose: move a layer's pixels between the screen
//! and its save area.
//! From /sys/src/libmemlayer/lhide.c.
//!
//! DIFF: none beyond the callback signature (see layerop.zig).

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");
const ldraw = @import("draw.zig");
const layerop = @import("layerop.zig");

const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const Memlayer = memlayer_h.Memlayer;
const rectsubpt = arith.rectsubpt;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const memdraw = ldraw.memdraw;
const _memlayerop = layerop._memlayerop;

//
// Hide puts that portion of screenr now on the screen into the window's save area.
// Expose puts that portion of screenr now in the save area onto the screen.
//
// Hide and Expose both require that the layer structures in the screen
// match the geometry they are being asked to update, that is, they update the
// save area (hide) or screen (expose) based on what those structures tell them.
// This means they must be called at the correct time during window shuffles.
//

fn lhideop(src: ?*Memimage, screenr: Rectangle, clipr: Rectangle, etc: ?*anyopaque, insave: bool) void {
    _ = clipr;
    _ = insave;
    const l: *Memlayer = @ptrCast(@alignCast(etc.?));
    if (src != l.save) { // do nothing if src is already in save area
        const r = rectsubpt(screenr, l.delta);
        memdraw(l.save.?, r, src.?, screenr.min, null, screenr.min, draw.S);
    }
}

pub fn memlhide(i: *Memimage, screenr_: Rectangle) void {
    var screenr = screenr_;
    if (i.layer.?.save == null)
        return;
    if (!rectclip(&screenr, i.layer.?.screen.image.r))
        return;
    _memlayerop(lhideop, i, screenr, screenr, i.layer);
}

fn lexposeop(dst: ?*Memimage, screenr: Rectangle, clipr: Rectangle, etc: ?*anyopaque, insave: bool) void {
    _ = clipr;
    if (insave) // if dst is save area, don't bother
        return;
    const l: *Memlayer = @ptrCast(@alignCast(etc.?));
    const r = rectsubpt(screenr, l.delta);
    if (l.save) |save|
        memdraw(dst.?, screenr, save, r.min, null, r.min, draw.S)
    else
        l.refreshfn.?(dst.?, r, l.refreshptr);
}

pub fn memlexpose(i: *Memimage, screenr_: Rectangle) void {
    var screenr = screenr_;
    if (!rectclip(&screenr, i.layer.?.screen.image.r))
        return;
    _memlayerop(lexposeop, i, screenr, screenr, i.layer);
}
