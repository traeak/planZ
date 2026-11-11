//! _memlayerop: apply a function to the pieces of a layer, each piece
//! either visible on the screen or hidden in the save area.
//! From /sys/src/libmemlayer/layerop.c.
//!
//! DIFF:
//!   - The callback takes ?*Memimage for the image to work on: the C
//!     passes l->save, which is nil for a layer with a refresh function,
//!     and its callbacks check `insave` before touching it.  `insave`
//!     is bool.
//!   - _layerop recurses once per window in front of the piece being
//!     cut, and kernel stacks are 8K, so the arguments that do not
//!     change on the way down (fn, i, clipr, etc) travel behind one
//!     pointer.  The RECUR macro is a function.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const Rect = arith.Rect;
const rectXrect = arith.rectXrect;
const rectinrect = arith.rectinrect;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;

pub const Layerfn = *const fn (?*Memimage, Rectangle, Rectangle, ?*anyopaque, bool) void;

/// _layerop's unchanging arguments
const Op = struct {
    @"fn": Layerfn,
    i: *Memimage,
    clipr: Rectangle,
    etc: ?*anyopaque,
};

fn RECUR(op: *const Op, a: Point, b: Point, c: Point, d: Point, front: *Memimage) void {
    _layerop(op, Rect(a.x, b.y, c.x, d.y), front.layer.?.rear.?);
}

fn _layerop(op: *const Op, r_: Rectangle, front_: *Memimage) void {
    var r = r_;
    var front = front_;
    const i = op.i;

    while (true) {
        if (front == i) {
            // no one is in front of this part of window; use the screen
            op.@"fn"(i.layer.?.screen.image, r, op.clipr, op.etc, false);
            return;
        }
        const fr = &front.layer.?.screenr;
        if (!rectXrect(r, fr.*)) {
            // r doesn't touch this window; continue on next rearmost
            // assert(front && front->layer && front->layer->screen && front->layer->rear);
            front = front.layer.?.rear.?;
            continue;
        }
        if (r.min.y < fr.min.y) {
            // above front layer
            RECUR(op, r.min, r.min, r.max, fr.min, front);
            r.min.y = fr.min.y;
        }
        if (r.max.y > fr.max.y) {
            // below front layer
            RECUR(op, r.min, fr.max, r.max, r.max, front);
            r.max.y = fr.max.y;
        }
        if (r.min.x < fr.min.x) {
            // left of front layer
            RECUR(op, r.min, r.min, fr.min, r.max, front);
            r.min.x = fr.min.x;
        }
        if (r.max.x > fr.max.x) {
            // right of front layer
            RECUR(op, fr.max, r.min, r.max, r.max, front);
            r.max.x = fr.max.x;
        }
        // r is covered by front, so put in save area
        op.@"fn"(i.layer.?.save, r, op.clipr, op.etc, true);
        return;
    }
}

//
// Assumes incoming rectangle has already been clipped to i's logical r and clipr
//
pub fn _memlayerop(
    @"fn": Layerfn,
    i: *Memimage,
    screenr_: Rectangle, // clipped to window boundaries
    clipr: Rectangle, // clipped also to clipping rectangles of hierarchy
    etc: ?*anyopaque,
) void {
    var screenr = screenr_;

    const l = i.layer.?;
    if (!rectclip(&screenr, l.screenr))
        return;
    if (l.clear) {
        @"fn"(l.screen.image, screenr, clipr, etc, false);
        return;
    }
    var r = screenr;
    const scr = l.screen.image.clipr;

    //
    // Do the piece on the screen
    //
    if (rectclip(&screenr, scr)) {
        const op: Op = .{ .@"fn" = @"fn", .i = i, .clipr = clipr, .etc = etc };
        _layerop(&op, screenr, l.screen.frontmost.?);
    }
    if (rectinrect(r, scr))
        return;

    //
    // Do the piece off the screen
    //
    if (!rectXrect(r, scr)) {
        // completely offscreen; easy
        @"fn"(l.save, r, clipr, etc, true);
        return;
    }
    if (r.min.y < scr.min.y) {
        // above screen
        @"fn"(l.save, Rect(r.min.x, r.min.y, r.max.x, scr.min.y), clipr, etc, true);
        r.min.y = scr.min.y;
    }
    if (r.max.y > scr.max.y) {
        // below screen
        @"fn"(l.save, Rect(r.min.x, scr.max.y, r.max.x, r.max.y), clipr, etc, true);
        r.max.y = scr.max.y;
    }
    if (r.min.x < scr.min.x) {
        // left of screen
        @"fn"(l.save, Rect(r.min.x, r.min.y, scr.min.x, r.max.y), clipr, etc, true);
        r.min.x = scr.min.x;
    }
    if (r.max.x > scr.max.x) {
        // right of screen
        @"fn"(l.save, Rect(scr.max.x, r.min.y, r.max.x, r.max.y), clipr, etc, true);
    }
}
