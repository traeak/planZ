//! memline: lines on images that may be layers.
//! From /sys/src/libmemlayer/line.c.
//!
//! DIFF:
//!   - The goto to Top is a loop.
//!   - The layer's delta is added with wrapping arithmetic, since the
//!     end points come from user programs through devdraw.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");
const mline = @import("../libmemdraw/line.zig");
const layerop = @import("layerop.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const Memlayer = memlayer_h.Memlayer;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const _memimageline = mline._memimageline;
const memlinebbox = mline.memlinebbox;
const _memlayerop = layerop._memlayerop;

const Lline = struct {
    p0: Point,
    p1: Point,
    delta: Point,
    end0: i32,
    end1: i32,
    radius: i32,
    sp: Point,
    dstlayer: *Memlayer,
    src: *Memimage,
    op: i32,
};

/// subpt and rectsubpt that wrap
fn wsubpt(a: Point, b: Point) Point {
    return .{ .x = a.x -% b.x, .y = a.y -% b.y };
}

fn wrectsubpt(r: Rectangle, p: Point) Rectangle {
    return .{ .min = wsubpt(r.min, p), .max = wsubpt(r.max, p) };
}

fn _memline(dst_: *Memimage, p0_: Point, p1_: Point, end0: i32, end1: i32, radius: i32, src: *Memimage, sp: Point, clipr_: Rectangle, op: i32) void {
    var dst = dst_;
    var p0 = p0_;
    var p1 = p1_;
    var clipr = clipr_;
    var ll: Lline = undefined;

    if (radius < 0)
        return;
    if (src.layer != null) // can't draw line with layered source
        return;
    var srcclipped = false;

    while (true) {
        const dl = dst.layer orelse {
            _memimageline(dst, p0, p1, end0, end1, radius, src, sp, clipr, op);
            return;
        };
        if (!srcclipped) {
            const d = wsubpt(sp, p0);
            if (!rectclip(&clipr, wrectsubpt(src.clipr, d)))
                return;
            if ((src.flags & memdraw_h.Frepl) == 0 and !rectclip(&clipr, wrectsubpt(src.r, d)))
                return;
            srcclipped = true;
        }

        // dst is known to be a layer
        p0.x +%= dl.delta.x;
        p0.y +%= dl.delta.y;
        p1.x +%= dl.delta.x;
        p1.y +%= dl.delta.y;
        clipr.min.x +%= dl.delta.x;
        clipr.min.y +%= dl.delta.y;
        clipr.max.x +%= dl.delta.x;
        clipr.max.y +%= dl.delta.y;
        if (dl.clear) {
            dst = dl.screen.image;
            continue;
        }

        // can't use sutherland-cohen clipping because lines are wide
        var r = memlinebbox(p0, p1, end0, end1, radius);
        //
        // r is now a bounding box for the line;
        // use it as a clipping rectangle for subdivision
        //
        if (!rectclip(&r, clipr))
            return;
        ll.p0 = p0;
        ll.p1 = p1;
        ll.end0 = end0;
        ll.end1 = end1;
        ll.sp = sp;
        ll.dstlayer = dl;
        ll.src = src;
        ll.radius = radius;
        ll.delta = dl.delta;
        ll.op = op;
        _memlayerop(llineop, dst, r, r, &ll);
        return;
    }
}

fn llineop(dst: ?*Memimage, screenr: Rectangle, clipr_: Rectangle, etc: ?*anyopaque, insave: bool) void {
    var clipr = clipr_;
    var p0: Point = undefined;
    var p1: Point = undefined;

    const ll: *Lline = @ptrCast(@alignCast(etc.?));
    if (insave and ll.dstlayer.save == null)
        return;
    if (!rectclip(&clipr, screenr))
        return;
    if (insave) {
        p0 = wsubpt(ll.p0, ll.delta);
        p1 = wsubpt(ll.p1, ll.delta);
        clipr = wrectsubpt(clipr, ll.delta);
    } else {
        p0 = ll.p0;
        p1 = ll.p1;
    }
    _memline(dst.?, p0, p1, ll.end0, ll.end1, ll.radius, ll.src, ll.sp, clipr, ll.op);
}

pub fn memline(dst: *Memimage, p0: Point, p1: Point, end0: i32, end1: i32, radius: i32, src: *Memimage, sp: Point, op: i32) void {
    _memline(dst, p0, p1, end0, end1, radius, src, sp, dst.clipr, op);
}
