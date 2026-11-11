//! memdraw: draw on images that may be layers (windows).
//! From /sys/src/libmemlayer/draw.c.
//!
//! DIFF:
//!   - The gotos to Top and Clearlayer are two labelled loops.
//!   - The _memlayerop callback takes ?*Memimage, because _memlayerop
//!     hands it a layer's save image, which may be nil; `insave` is
//!     bool.
//!   - Coordinate arithmetic wraps (`+%`, `-%`), as C's does on its
//!     compilers: rectangles and points come from user programs
//!     through devdraw and an overflow check would panic the kernel.
//!   - A nil mask means memopaque, as in C; the parameter is optional.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");
const mdraw = @import("../libmemdraw/draw.zig");
const layerop = @import("layerop.zig");
const lhide = @import("lhide.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const Memlayer = memlayer_h.Memlayer;
const addpt = arith.addpt;
const subpt = arith.subpt;
const rectsubpt = arith.rectsubpt;
const rectinrect = arith.rectinrect;
const rectXrect = arith.rectXrect;
const memimagedraw = mdraw.memimagedraw;
const drawclipnorepl = mdraw.drawclipnorepl;
const _drawclipnorepl = mdraw._drawclipnorepl;
const _memlayerop = layerop._memlayerop;
const memlhide = lhide.memlhide;
const memlexpose = lhide.memlexpose;

const Draw = struct {
    deltas: Point,
    deltam: Point,
    dstlayer: *Memlayer,
    src: *Memimage,
    mask: *Memimage,
    op: i32,
};

fn ldrawop(dst_: ?*Memimage, screenr: Rectangle, clipr_: Rectangle, etc: ?*anyopaque, insave: bool) void {
    var clipr = clipr_;
    var r: Rectangle = undefined;
    var srcr: Rectangle = undefined;
    var mr: Rectangle = undefined;

    const d: *Draw = @ptrCast(@alignCast(etc.?));
    if (insave and d.dstlayer.save == null)
        return;
    const dst = dst_.?;

    var p0 = addpt(screenr.min, d.deltas);
    var p1 = addpt(screenr.min, d.deltam);

    if (insave) {
        r = rectsubpt(screenr, d.dstlayer.delta);
        clipr = rectsubpt(clipr, d.dstlayer.delta);
    } else r = screenr;

    // now in logical coordinates

    // clipr may have narrowed what we should draw on, so clip if necessary
    if (!rectinrect(r, clipr) and
        !_drawclipnorepl(&dst.r, &clipr, &r, d.src, &p0, d.mask, &p1, &srcr, &mr))
        return;
    memdraw(dst, r, d.src, p0, d.mask, p1, d.op);
}

pub fn memdraw(dst_: *Memimage, r_: Rectangle, src_: *Memimage, p0_: Point, mask_: ?*Memimage, p1_: Point, op: i32) void {
    var dst = dst_;
    var r = r_;
    var src = src_;
    var p0 = p0_;
    var p1 = p1_;
    var d: Draw = undefined;
    var srcr: Rectangle = undefined;
    var mr: Rectangle = undefined;
    var tr: Rectangle = undefined;
    var dl: ?*Memlayer = undefined;

    const mask = mask_ orelse memdraw_h.memopaque;

    if (mask.layer != null)
        return; // too hard, at least for now

    Top: while (true) {
        if (dst.layer == null and src.layer == null) {
            memimagedraw(dst, r, src, p0, mask, p1, op);
            return;
        }

        if (!drawclipnorepl(dst, &r, src, &p0, mask, &p1, &srcr, &mr))
            return;

        //
        // Convert to screen coordinates.
        //
        dl = dst.layer;
        if (dl) |l| {
            r.min.x +%= l.delta.x;
            r.min.y +%= l.delta.y;
            r.max.x +%= l.delta.x;
            r.max.y +%= l.delta.y;
        }
        Clearlayer: while (true) {
            if (dl != null and dl.?.clear) {
                const l = dl.?;
                if (src == dst) {
                    p0.x +%= l.delta.x;
                    p0.y +%= l.delta.y;
                    src = l.screen.image;
                }
                dst = l.screen.image;
                continue :Top;
            }

            const sl = src.layer;
            if (sl) |l| {
                p0.x +%= l.delta.x;
                p0.y +%= l.delta.y;
                srcr.min.x +%= l.delta.x;
                srcr.min.y +%= l.delta.y;
                srcr.max.x +%= l.delta.x;
                srcr.max.y +%= l.delta.y;
            }

            //
            // Now everything is in screen coordinates.
            // mask is an image.  dst and src are images or obscured layers.
            //

            //
            // if dst and src are the same layer, just draw in save area and expose.
            //
            if (dl != null and dst == src) {
                const l = dl.?;
                const save = l.save orelse
                    return; // refresh function makes this case unworkable
                if (rectXrect(r, srcr)) {
                    tr = r;
                    if (srcr.min.x < tr.min.x) {
                        p1.x +%= tr.min.x -% srcr.min.x;
                        tr.min.x = srcr.min.x;
                    }
                    if (srcr.min.y < tr.min.y) {
                        p1.y +%= tr.min.y -% srcr.min.y;
                        tr.min.y = srcr.min.y;
                    }
                    if (srcr.max.x > tr.max.x)
                        tr.max.x = srcr.max.x;
                    if (srcr.max.y > tr.max.y)
                        tr.max.y = srcr.max.y;
                    memlhide(dst, tr);
                } else {
                    memlhide(dst, r);
                    memlhide(dst, srcr);
                }
                memdraw(save, rectsubpt(r, l.delta), save, subpt(srcr.min, src.layer.?.delta), mask, p1, op);
                memlexpose(dst, r);
                return;
            }

            if (sl) |l| {
                if (l.clear) {
                    src = l.screen.image;
                    if (dl) |dll| {
                        r.min.x -%= dll.delta.x;
                        r.min.y -%= dll.delta.y;
                        r.max.x -%= dll.delta.x;
                        r.max.y -%= dll.delta.y;
                    }
                    continue :Top;
                }
                // relatively rare case; use save area
                const save = l.save orelse
                    return; // refresh function makes this case unworkable
                memlhide(src, srcr);
                // convert back to logical coordinates
                p0.x -%= l.delta.x;
                p0.y -%= l.delta.y;
                srcr.min.x -%= l.delta.x;
                srcr.min.y -%= l.delta.y;
                srcr.max.x -%= l.delta.x;
                srcr.max.y -%= l.delta.y;
                src = save;
            }

            //
            // src is now an image.  dst may be an image or a clear layer
            //
            if (dst.layer == null)
                continue :Top;
            if (dst.layer.?.clear)
                continue :Clearlayer;
            break :Top;
        }
    }

    //
    // dst is an obscured layer
    //
    d.deltas = subpt(p0, r.min);
    d.deltam = subpt(p1, r.min);
    d.dstlayer = dl.?;
    d.src = src;
    d.op = op;
    d.mask = mask;
    _memlayerop(ldrawop, dst, r, r, &d);
}
