//! memlaffinewarp: affine warps on images that may be layers.
//! From /sys/src/libmemlayer/warp.c.
//!
//! DIFF:
//!   - The gotos to Top and Clearlayer are two labelled loops.
//!   - Coordinate arithmetic wraps (`+%`, `-%`), as C's does on its
//!     compilers: rectangles and points come from user programs
//!     through devdraw and an overflow check would panic the kernel.
//!   - `smooth` is bool; the mask is optional (nothing looks at it).

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");
const mwarp = @import("../libmemdraw/warp.zig");
const layerop = @import("layerop.zig");
const lhide = @import("lhide.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Warp = draw.Warp;
const Memimage = memdraw_h.Memimage;
const Memlayer = memlayer_h.Memlayer;
const subpt = arith.subpt;
const rectsubpt = arith.rectsubpt;
const rectinrect = arith.rectinrect;
const rectXrect = arith.rectXrect;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const badrect = @import("../libdraw/badrect.zig").badrect;
const memaffinewarp = mwarp.memaffinewarp;
const _memlayerop = layerop._memlayerop;
const memlhide = lhide.memlhide;
const memlexpose = lhide.memlexpose;

const Draw = struct {
    dstlayer: *Memlayer,
    dp: Point,
    src: *Memimage,
    sp: Point,
    msk: ?*Memimage,
    mp: Point,
    warp: *const Warp,
    smooth: bool,
    op: i32,
};

fn ldrawop(dst: ?*Memimage, screenr: Rectangle, clipr_: Rectangle, etc: ?*anyopaque, insave: bool) void {
    var clipr = clipr_;
    var r: Rectangle = undefined;
    var dp: Point = undefined;

    const d: *Draw = @ptrCast(@alignCast(etc.?));
    if (insave and d.dstlayer.save == null)
        return;

    if (insave) {
        dp = subpt(d.dp, d.dstlayer.delta);
        r = rectsubpt(screenr, d.dstlayer.delta);
        clipr = rectsubpt(clipr, d.dstlayer.delta);
    } else {
        dp = d.dp;
        r = screenr;
    }

    // now in logical coordinates

    // clipr may have narrowed what we should draw on, so clip if necessary
    if (!rectinrect(r, clipr) and !rectclip(&r, clipr))
        return;
    memlaffinewarp(dst.?, dp, r, d.src, d.sp, d.msk, d.mp, d.warp, d.smooth, d.op);
}

pub fn memlaffinewarp(dst_: *Memimage, dp0_: Point, r_: Rectangle, src_: *Memimage, p0_: Point, msk: ?*Memimage, p1: Point, w: *const Warp, smooth: bool, op: i32) void {
    var dst = dst_;
    var dp0 = dp0_;
    var r = r_;
    var src = src_;
    var p0 = p0_;
    var d: Draw = undefined;
    var tr: Rectangle = undefined;
    var dl: *Memlayer = undefined;

    Top: while (true) {
        if (dst.layer == null and src.layer == null) {
            memaffinewarp(dst, dp0, r, src, p0, msk, p1, w, smooth, op);
            return;
        }

        if (badrect(r))
            return;
        if (!rectclip(&r, dst.r) or !rectclip(&r, dst.clipr))
            return;

        var srcr = src.clipr;

        //
        // Convert to screen coordinates.
        //
        const dlp = dst.layer;
        if (dlp) |l| {
            dp0.x +%= l.delta.x;
            dp0.y +%= l.delta.y;
            r.min.x +%= l.delta.x;
            r.min.y +%= l.delta.y;
            r.max.x +%= l.delta.x;
            r.max.y +%= l.delta.y;
        }
        Clearlayer: while (true) {
            // the C's label is inside `if(dl != nil)`; a jump to it
            // always has a layer
            if (dlp != null and dlp.?.clear) {
                const l = dlp.?;
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
            // dst and src are images or obscured layers.
            //

            //
            // if dst and src are the same layer, just draw in save area and expose.
            //
            if (dlp != null and dst == src) {
                const l = dlp.?;
                const save = l.save orelse
                    return; // refresh function makes this case unworkable
                if (rectXrect(r, srcr)) {
                    tr = r;
                    if (srcr.min.x < tr.min.x)
                        tr.min.x = srcr.min.x;
                    if (srcr.min.y < tr.min.y)
                        tr.min.y = srcr.min.y;
                    if (srcr.max.x > tr.max.x)
                        tr.max.x = srcr.max.x;
                    if (srcr.max.y > tr.max.y)
                        tr.max.y = srcr.max.y;
                    memlhide(dst, tr);
                } else {
                    memlhide(dst, r);
                    memlhide(dst, srcr);
                }
                memlaffinewarp(save, subpt(dp0, l.delta), rectsubpt(r, l.delta), save, subpt(p0, sl.?.delta), msk, p1, w, smooth, op);
                memlexpose(dst, r);
                return;
            }

            if (sl) |l| {
                if (l.clear) {
                    src = l.screen.image;
                    if (dlp) |dll| {
                        dp0.x -%= dll.delta.x;
                        dp0.y -%= dll.delta.y;
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
            dl = dst.layer.?;
            break :Top;
        }
    }

    //
    // dst is an obscured layer
    //
    d.dstlayer = dl;
    d.dp = dp0;
    d.src = src;
    d.sp = p0;
    d.msk = msk;
    d.mp = p1;
    d.warp = w;
    d.smooth = smooth;
    d.op = op;
    _memlayerop(ldrawop, dst, r, r, &d);
}

test "warps on layers, against the C library" {
    const T = @import("../libmemdraw/line.zig").testing;
    const Pt = arith.Pt;
    const Rect = arith.Rect;
    const freememimage = @import("../libmemdraw/alloc.zig").freememimage;
    const memlalloc = @import("lalloc.zig").memlalloc;
    const memldelete = @import("ldelete.zig").memldelete;
    T.init();
    defer T.deinit();
    var ref = T.Ref.init(want);

    const s = T.tex(Rect(0, 0, 16, 12), draw.RGBA32);
    defer freememimage(s);
    const si = T.mk(Rect(0, 0, 80, 60), draw.XRGB32, 0x777777FF);
    defer freememimage(si);
    var scr: memlayer_h.Memscreen = .{ .frontmost = null, .rearmost = null, .image = si, .fill = null };
    const a = memlalloc(&scr, Rect(10, 10, 50, 40), null, null, draw.DWhite).?;
    const b = memlalloc(&scr, Rect(30, 20, 70, 55), null, null, draw.DPaleyellow).?;
    const w: Warp = .{ .m = .{ .{ 3000, -500, 0 }, .{ 400, 2500, 0 }, .{ 0, 0, 8192 } }, .flags = 0 };
    memlaffinewarp(a, Pt(12, 12), Rect(12, 12, 48, 38), s, draw.ZP, null, draw.ZP, &w, true, draw.S);
    ref.out("lwarp", "scr", si);
    ref.out("lwarp", "a", a);
    memlaffinewarp(b, Pt(30, 20), b.r, a, Pt(10, 10), null, draw.ZP, &w, false, draw.S);
    ref.out("lwarp2", "scr", si);
    memldelete(a);
    memldelete(b);
    try ref.done();
}

/// What the C program printed (see `testing` in libmemdraw/line.zig).
const want =
    \\lwarp.scr 7a6d44f66719cbbd
    \\lwarp.a 9e34e3f8b6f0fd69
    \\lwarp2.scr 7e10ba1e619f8121
;
