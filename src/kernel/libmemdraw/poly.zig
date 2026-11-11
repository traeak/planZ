//! Open polygons (connected lines) on a Memimage.
//! From /sys/src/libmemdraw/poly.c.
//!
//! DIFF: the vertices are a slice.

const draw = @import("../libdraw/draw.zig");
const memdraw_h = @import("memdraw.zig");
const lline = @import("../libmemlayer/line.zig");

const Point = draw.Point;
const Memimage = memdraw_h.Memimage;
const memline = lline.memline;

pub fn mempoly(dst: *Memimage, vert: []const Point, end0: i32, end1: i32, radius: i32, src: *Memimage, sp: Point, op: i32) void {
    const nvert = vert.len;
    if (nvert < 2)
        return;
    const d: Point = .{ .x = sp.x -% vert[0].x, .y = sp.y -% vert[0].y };
    var i: usize = 1;
    while (i < nvert) : (i += 1) {
        var e0: i32 = draw.Enddisc;
        var e1: i32 = draw.Enddisc;
        if (i == 1)
            e0 = end0;
        if (i == nvert - 1)
            e1 = end1;
        memline(dst, vert[i - 1], vert[i], e0, e1, radius, src, .{ .x = d.x +% vert[i - 1].x, .y = d.y +% vert[i - 1].y }, op);
    }
}

test "polygons, against the C library" {
    const T = @import("line.zig").testing;
    const arith = @import("../libdraw/arith.zig");
    const freememimage = @import("alloc.zig").freememimage;
    const Pt = arith.Pt;
    T.init();
    defer T.deinit();
    var ref = T.Ref.init(want);

    for (T.chans) |ch| {
        const red = T.col(draw.DRed);
        defer freememimage(red);
        const t = T.tex(arith.Rect(-8, -8, 72, 56), draw.RGB24);
        defer freememimage(t);

        const d = T.mk(arith.Rect(0, 0, 64, 48), ch.chan, draw.DBlack);
        defer freememimage(d);
        const pts = [_]Point{ Pt(5, 40), Pt(15, 8), Pt(40, 35), Pt(58, 6) };
        mempoly(d, &pts, draw.Enddisc, draw.Endarrow, 2, red, draw.ZP, draw.SoverD);
        ref.out(ch.name, "mempoly", d);
        mempoly(d, &pts, draw.Endsquare, draw.Endsquare, 0, t, pts[0], draw.SoverD);
        ref.out(ch.name, "mempoly_thin", d);
    }
    try ref.done();
}

/// What the C program printed (see `testing` in libmemdraw/line.zig).
const want =
    \\x8r8g8b8.mempoly 9266b22ac0324852
    \\x8r8g8b8.mempoly_thin fbe62ce24f2178f9
    \\r5g6b5.mempoly ebbe36dbb84befed
    \\r5g6b5.mempoly_thin 88cf339f8a6880d7
    \\k8.mempoly d030bb900d77ed21
    \\k8.mempoly_thin 5520470c59b1adb5
    \\k1.mempoly c86ec345c0ee8125
    \\k1.mempoly_thin b121557683cae16e
    \\m8.mempoly 6f95e0bed400ca15
    \\m8.mempoly_thin 13814912f4f669c3
    \\r8g8b8a8.mempoly 5f749df004a79a00
    \\r8g8b8a8.mempoly_thin a199be8f0d76fa85
;
