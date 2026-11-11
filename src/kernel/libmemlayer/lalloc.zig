//! memlalloc: make a new layer (window) on a screen.
//! From /sys/src/libmemlayer/lalloc.c.
//!
//! DIFF:
//!   - The static `paint` image is a variable of the file, and
//!     freepaint (not in the C) frees it, for the host tests' leak
//!     check.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");
const kernel = @import("../libmemdraw/kernel.zig");
const malloc = @import("../libmemdraw/alloc.zig");
const mdraw = @import("../libmemdraw/draw.zig");
const ldraw = @import("draw.zig");
const ltofront = @import("ltofront.zig");

const Rectangle = draw.Rectangle;
const Memimage = memdraw_h.Memimage;
const Memlayer = memlayer_h.Memlayer;
const Memscreen = memlayer_h.Memscreen;
const Refreshfn = memlayer_h.Refreshfn;
const Rect = arith.Rect;
const allocmemimage = malloc.allocmemimage;
const allocmemimaged = malloc.allocmemimaged;
const freememimage = malloc.freememimage;
const memsetchan = malloc.memsetchan;
const memfillcolor = mdraw.memfillcolor;
const memdraw = ldraw.memdraw;
const _memltofrontfill = ltofront._memltofrontfill;

/// memlalloc's static variable
var paint: ?*Memimage = null;

/// Free the image memlalloc paints new windows with.  Not in the C,
/// where it lives for ever; the host tests call it so their leak check
/// passes.
pub fn freepaint() void {
    freememimage(paint);
    paint = null;
}

pub fn memlalloc(s: *Memscreen, screenr: Rectangle, refreshfn: ?Refreshfn, refreshptr: ?*anyopaque, val: u32) ?*Memimage {
    if (paint == null) {
        const p = allocmemimage(Rect(0, 0, 1, 1), draw.RGBA32) orelse return null;
        paint = p;
        p.flags |= memdraw_h.Frepl;
        p.clipr = Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF);
    }

    const n = allocmemimaged(screenr, s.image.chan, s.image.data) orelse return null;
    const l = kernel.new(Memlayer) orelse {
        kernel.free(n);
        return null;
    };

    l.screen = s;
    if (refreshfn != null)
        l.save = null
    else {
        l.save = allocmemimage(screenr, s.image.chan) orelse {
            kernel.free(l);
            kernel.free(n);
            return null;
        };
        // allocmemimage doesn't initialize memory; this paints save area
        memfillcolor(l.save.?, val);
    }
    l.refreshfn = refreshfn;
    l.refreshptr = null; // don't set it until we're done
    l.screenr = screenr;
    l.delta = draw.ZP;

    n.data.ref += 1;
    n.zero = s.image.zero;
    n.width = s.image.width;
    n.layer = l;

    // start with new window behind all existing ones
    l.front = s.rearmost;
    l.rear = null;
    if (s.rearmost) |rm|
        rm.layer.?.rear = n;
    s.rearmost = n;
    if (s.frontmost == null)
        s.frontmost = n;
    l.clear = false;

    // now pull new window to front
    _memltofrontfill(n, val != draw.DNofill);
    l.refreshptr = refreshptr;

    //
    // paint with requested color; previously exposed areas are already right
    // if this window has backing store, but just painting the whole thing is simplest.
    //
    if (val != draw.DNofill) {
        _ = memsetchan(paint.?, n.chan);
        memfillcolor(paint.?, val);
        memdraw(n, n.r, paint.?, n.r.min, null, n.r.min, draw.S);
    }
    return n;
}

const testrefresh = struct {
    var nrefresh: i32 = 0;
    var refresharea: i32 = 0;
    var refcol: *Memimage = undefined;

    fn refresh(dst: *Memimage, r: Rectangle, v: ?*anyopaque) void {
        nrefresh += 1;
        refresharea += draw.Dx(r) * draw.Dy(r);
        _ = v;
        memdraw(dst, r, refcol, r.min, null, draw.ZP, draw.S);
    }
};

test "layers, against the C library" {
    const T = @import("../libmemdraw/line.zig").testing;
    const Pt = arith.Pt;
    const ZP = draw.ZP;
    const SoverD = draw.SoverD;
    const S = draw.S;
    const memline = @import("line.zig").memline;
    const memellipse = @import("../libmemdraw/ellipse.zig").memellipse;
    const memarc = @import("../libmemdraw/arc.zig").memarc;
    const memfillpoly = @import("../libmemdraw/fillpoly.zig").memfillpoly;
    const memload = @import("load.zig").memload;
    const memunload = @import("unload.zig").memunload;
    const memltofront = ltofront.memltofront;
    const memltofrontn = ltofront.memltofrontn;
    const memltorear = @import("ltorear.zig").memltorear;
    const memltorearn = @import("ltorear.zig").memltorearn;
    const memlorigin = @import("lorigin.zig").memlorigin;
    const memlnorefresh = @import("lorigin.zig").memlnorefresh;
    const memlsetrefresh = @import("lsetrefresh.zig").memlsetrefresh;
    const memldelete = @import("ldelete.zig").memldelete;
    const memlfree = @import("ldelete.zig").memlfree;
    const R = testrefresh;
    const b2i = struct {
        fn f(v: bool) i32 {
            return @intFromBool(v);
        }
    }.f;

    T.init();
    defer T.deinit();
    var ref = T.Ref.init(want);

    const chans = [_]T.Chan{
        .{ .chan = draw.XRGB32, .name = "x8r8g8b8" },
        .{ .chan = draw.RGB16, .name = "r5g6b5" },
        .{ .chan = draw.GREY2, .name = "k2" },
    };
    for (chans) |ch| {
        const cn = ch.name;
        var buf: [4096]u8 = undefined;
        var n: i32 = undefined;

        const red = T.col(draw.DRed);
        defer freememimage(red);
        const green = T.col(0x00FF0080);
        defer freememimage(green);
        const blue = T.col(draw.DBlue);
        defer freememimage(blue);
        R.refcol = T.col(draw.DYellow);
        defer freememimage(R.refcol);
        const t = T.tex(Rect(0, 0, 80, 60), draw.RGB24);
        defer freememimage(t);
        const fill = T.col(0x777777FF);
        defer freememimage(fill);
        const si = T.mk(Rect(0, 0, 80, 60), ch.chan, 0x777777FF);
        defer freememimage(si);
        var scr: Memscreen = .{ .frontmost = null, .rearmost = null, .image = si, .fill = fill };
        R.nrefresh = 0;
        R.refresharea = 0;

        const a = memlalloc(&scr, Rect(10, 10, 50, 40), null, null, draw.DWhite).?;
        ref.out(cn, "alloc_a", si);
        const b = memlalloc(&scr, Rect(30, 20, 70, 55), R.refresh, null, draw.DPaleyellow).?;
        ref.out(cn, "alloc_b", si);
        ref.line("{s}.clear {d} {d} {d} {d}", .{ cn, b2i(a.layer.?.clear), b2i(b.layer.?.clear), R.nrefresh, R.refresharea });

        // draw in a, which is partly hidden by b
        memdraw(a, Rect(12, 12, 48, 38), t, Pt(3, 3), null, ZP, SoverD);
        memline(a, Pt(10, 10), Pt(49, 39), draw.Enddisc, draw.Endarrow, 2, red, ZP, SoverD);
        memellipse(a, Pt(40, 30), 12, 8, 2, blue, ZP, SoverD);
        ref.out(cn, "draw_a.scr", si);
        ref.out(cn, "draw_a.a", a);
        // a line across both, and a poly in b
        memline(b, Pt(25, 25), Pt(69, 50), draw.Endsquare, draw.Endsquare, 1, green, ZP, SoverD);
        memfillpoly(b, &.{ Pt(35, 22), Pt(68, 30), Pt(40, 52) }, -1, blue, ZP, SoverD);
        ref.out(cn, "draw_b.scr", si);

        memltofront(a);
        ref.out(cn, "tofront_a.scr", si);
        ref.out(cn, "tofront_a.a", a);
        ref.line("{s}.clear {d} {d} {d} {d}", .{ cn, b2i(a.layer.?.clear), b2i(b.layer.?.clear), R.nrefresh, R.refresharea });
        memarc(b, Pt(50, 38), 15, 12, 3, red, ZP, 10, 250, SoverD);
        ref.out(cn, "arc_b.scr", si);
        memltorear(a);
        ref.out(cn, "torear_a.scr", si);
        ref.line("{s}.clear {d} {d} {d} {d}", .{ cn, b2i(a.layer.?.clear), b2i(b.layer.?.clear), R.nrefresh, R.refresharea });

        // a third window hanging off the screen
        const c = memlalloc(&scr, Rect(60, 35, 100, 80), null, null, draw.DGreen).?;
        ref.out(cn, "alloc_c.scr", si);
        ref.out(cn, "alloc_c.c", c);
        memellipse(c, Pt(80, 58), 18, 20, -1, red, ZP, SoverD);
        memline(c, Pt(60, 35), Pt(99, 79), draw.Enddisc, draw.Enddisc, 3, blue, ZP, SoverD);
        ref.out(cn, "draw_c.scr", si);
        ref.out(cn, "draw_c.c", c);
        ref.line("{s}.clear {d} {d} {d} {d} {d}", .{ cn, b2i(a.layer.?.clear), b2i(b.layer.?.clear), b2i(c.layer.?.clear), R.nrefresh, R.refresharea });

        // scroll within a (same layer, obscured)
        memdraw(a, Rect(10, 10, 45, 35), a, Pt(15, 14), null, ZP, S);
        ref.out(cn, "scroll_a.scr", si);
        ref.out(cn, "scroll_a.a", a);
        // obscured layer as source
        memdraw(c, Rect(62, 37, 98, 70), a, Pt(12, 12), null, ZP, SoverD);
        ref.out(cn, "a_to_c.scr", si);
        ref.out(cn, "a_to_c.c", c);
        // copy within c, partly off screen
        memdraw(c, Rect(70, 50, 100, 80), c, Pt(60, 35), null, ZP, S);
        ref.out(cn, "scroll_c.c", c);

        // load and unload
        for (&buf, 0..) |*p, i|
            p.* = @truncate(i * 7 + (i >> 5));
        n = memload(a, Rect(20, 15, 45, 30), &buf, false);
        ref.line("{s}.memload {d}", .{ cn, n });
        ref.out(cn, "load_a.scr", si);
        ref.out(cn, "load_a.a", a);
        n = memload(c, Rect(65, 40, 95, 75), &buf, false);
        ref.line("{s}.memload_c {d}", .{ cn, n });
        ref.out(cn, "load_c.c", c);
        n = memunload(b, Rect(30, 20, 70, 55), &buf);
        ref.line("{s}.memunload_b {d}", .{ cn, n });

        // shuffles
        memltofrontn(&.{ a, c });
        ref.out(cn, "tofrontn.scr", si);
        ref.line("{s}.clear {d} {d} {d} {d} {d}", .{ cn, b2i(a.layer.?.clear), b2i(b.layer.?.clear), b2i(c.layer.?.clear), R.nrefresh, R.refresharea });
        memltorearn(&.{ c, a, b });
        ref.out(cn, "torearn.scr", si);
        ref.line("{s}.clear {d} {d} {d} {d} {d}", .{ cn, b2i(a.layer.?.clear), b2i(b.layer.?.clear), b2i(c.layer.?.clear), R.nrefresh, R.refresharea });
        ref.line("{s}.order {d} {d} {d}", .{ cn, b2i(scr.frontmost == a), b2i(scr.rearmost == c), b2i(a.layer.?.rear == b) });

        // origin: move a, then change its coordinates, then both
        n = memlorigin(a, a.r.min, Pt(5, 25));
        ref.line("{s}.origin1 {d}", .{ cn, n });
        ref.out(cn, "origin1.scr", si);
        ref.out(cn, "origin1.a", a);
        n = memlorigin(a, Pt(-100, -200), Pt(5, 25));
        ref.line("{s}.origin2 {d} {d} {d}", .{ cn, n, a.r.min.x, a.layer.?.delta.y });
        ref.out(cn, "origin2.scr", si);
        ref.out(cn, "origin2.a", a);
        memline(a, Pt(-100, -200), Pt(-61, -171), draw.Endsquare, draw.Endsquare, 0, red, ZP, SoverD);
        n = memlorigin(c, Pt(0, 0), Pt(-10, -10));
        ref.line("{s}.origin3 {d}", .{ cn, n });
        ref.out(cn, "origin3.scr", si);
        ref.out(cn, "origin3.c", c);
        n = memlorigin(b, Pt(3, 3), Pt(45, -5));
        ref.line("{s}.origin4 {d}", .{ cn, n });
        ref.out(cn, "origin4.scr", si);
        n = memlorigin(b, Pt(3, 3), Pt(45, -5));
        ref.line("{s}.origin5 {d}", .{ cn, n });
        ref.line("{s}.clear {d} {d} {d} {d} {d}", .{ cn, b2i(a.layer.?.clear), b2i(b.layer.?.clear), b2i(c.layer.?.clear), R.nrefresh, R.refresharea });

        // refresh method changes
        var ok = memlsetrefresh(b, null, null); // refresh fn -> backup
        ref.line("{s}.setrefresh1 {d} {d} {d}", .{ cn, b2i(ok), b2i(b.layer.?.save != null), R.nrefresh });
        memltofront(a);
        memltofront(b);
        ref.out(cn, "setrefresh1.scr", si);
        ok = memlsetrefresh(a, R.refresh, null); // backup -> refresh fn
        ref.line("{s}.setrefresh2 {d} {d}", .{ cn, b2i(ok), b2i(a.layer.?.save != null) });
        ok = memlsetrefresh(a, memlnorefresh, null);
        ref.line("{s}.setrefresh3 {d}", .{ cn, b2i(ok) });
        memltofront(a);
        ref.out(cn, "setrefresh3.scr", si);

        memldelete(b);
        ref.out(cn, "delete_b.scr", si);
        memldelete(a);
        ref.out(cn, "delete_a.scr", si);
        ref.line("{s}.order {d} {d}", .{ cn, b2i(scr.frontmost == c), b2i(scr.rearmost == c) });
        memlfree(c);
        ref.out(cn, "free_c.scr", si);
    }
    try ref.done();
}

/// What the C program printed (see `testing` in libmemdraw/line.zig).
const want =
    \\x8r8g8b8.alloc_a 49c7895de52c3425
    \\x8r8g8b8.alloc_b 7834a0030c612b05
    \\x8r8g8b8.clear 0 1 1 400
    \\x8r8g8b8.draw_a.scr 7674507ad0c887ac
    \\x8r8g8b8.draw_a.a 171663f30fb0dec4
    \\x8r8g8b8.draw_b.scr 6edbaee6fd74ac4f
    \\x8r8g8b8.tofront_a.scr 6061dd88b079bf9c
    \\x8r8g8b8.tofront_a.a 171663f30fb0dec4
    \\x8r8g8b8.clear 1 0 1 400
    \\x8r8g8b8.arc_b.scr c7e515abd319f334
    \\x8r8g8b8.torear_a.scr af0ec5310c4fd928
    \\x8r8g8b8.clear 0 1 2 800
    \\x8r8g8b8.alloc_c.scr 1dcfa68f5559edff
    \\x8r8g8b8.alloc_c.c ce4a832071307665
    \\x8r8g8b8.draw_c.scr 4ef953bf75fd4eef
    \\x8r8g8b8.draw_c.c dd0ca699026aa935
    \\x8r8g8b8.clear 0 0 0 2 800
    \\x8r8g8b8.scroll_a.scr bbcf098039824444
    \\x8r8g8b8.scroll_a.a 17113dcca6ec9f3f
    \\x8r8g8b8.a_to_c.scr 685284eb0089a0d2
    \\x8r8g8b8.a_to_c.c 76c51af1fd2349ce
    \\x8r8g8b8.scroll_c.c 62e532ffe97cb0a2
    \\x8r8g8b8.memload 1500
    \\x8r8g8b8.load_a.scr 065b7e30351be85e
    \\x8r8g8b8.load_a.a 0c4c758573d1a81c
    \\x8r8g8b8.memload_c -1
    \\x8r8g8b8.load_c.c 62e532ffe97cb0a2
    \\x8r8g8b8.memunload_b -1
    \\x8r8g8b8.tofrontn.scr 58422c75caa39593
    \\x8r8g8b8.clear 1 0 0 2 800
    \\x8r8g8b8.torearn.scr 88fbc179c3a5e77b
    \\x8r8g8b8.clear 0 1 0 4 1400
    \\x8r8g8b8.order 0 1 0
    \\x8r8g8b8.origin1 1
    \\x8r8g8b8.origin1.scr 2f9362d002cb2f1f
    \\x8r8g8b8.origin1.a 0c4c758573d1a81c
    \\x8r8g8b8.origin2 0 -100 225
    \\x8r8g8b8.origin2.scr 2f9362d002cb2f1f
    \\x8r8g8b8.origin2.a 0c4c758573d1a81c
    \\x8r8g8b8.origin3 1
    \\x8r8g8b8.origin3.scr de45216df16bfe1b
    \\x8r8g8b8.origin3.c 62e532ffe97cb0a2
    \\x8r8g8b8.origin4 1
    \\x8r8g8b8.origin4.scr bce20e26983c56a8
    \\x8r8g8b8.origin5 0
    \\x8r8g8b8.clear 0 0 0 8 2225
    \\x8r8g8b8.setrefresh1 1 1 9
    \\x8r8g8b8.setrefresh1.scr 302c64c98fe59671
    \\x8r8g8b8.setrefresh2 1 0
    \\x8r8g8b8.setrefresh3 1
    \\x8r8g8b8.setrefresh3.scr 302c64c98fe59671
    \\x8r8g8b8.delete_b.scr b171c9084c1be799
    \\x8r8g8b8.delete_a.scr d1a92a9bc3501463
    \\x8r8g8b8.order 1 1
    \\x8r8g8b8.free_c.scr d1a92a9bc3501463
    \\r5g6b5.alloc_a b403faf0fcb8b725
    \\r5g6b5.alloc_b 0d05e7db4f0cca55
    \\r5g6b5.clear 0 1 1 400
    \\r5g6b5.draw_a.scr fe11046523223477
    \\r5g6b5.draw_a.a 40ee61d4c4f377a5
    \\r5g6b5.draw_b.scr ad4334766f274c74
    \\r5g6b5.tofront_a.scr 404a95c3e302930a
    \\r5g6b5.tofront_a.a 40ee61d4c4f377a5
    \\r5g6b5.clear 1 0 1 400
    \\r5g6b5.arc_b.scr 3e33b6d22f5aeaca
    \\r5g6b5.torear_a.scr 2afa3917d948f2c4
    \\r5g6b5.clear 0 1 2 800
    \\r5g6b5.alloc_c.scr 7d3304825a5812b0
    \\r5g6b5.alloc_c.c ccc7c74c6f573a05
    \\r5g6b5.draw_c.scr dcddcd1e753e39bb
    \\r5g6b5.draw_c.c 85337d5bbfb4df3d
    \\r5g6b5.clear 0 0 0 2 800
    \\r5g6b5.scroll_a.scr 3683063acac535d5
    \\r5g6b5.scroll_a.a 3b46fc9f672fc238
    \\r5g6b5.a_to_c.scr 3bf67f9c0edef84a
    \\r5g6b5.a_to_c.c 2744ff1e4c22c46e
    \\r5g6b5.scroll_c.c bb6bb8e82a4befc6
    \\r5g6b5.memload 750
    \\r5g6b5.load_a.scr f16483ed6762353c
    \\r5g6b5.load_a.a 805b9d3501a94e4e
    \\r5g6b5.memload_c 2100
    \\r5g6b5.load_c.c c3cf3beed08de94d
    \\r5g6b5.memunload_b 2800
    \\r5g6b5.tofrontn.scr f857d29fb0d95267
    \\r5g6b5.clear 1 0 0 2 800
    \\r5g6b5.torearn.scr 2d367581e2b7bf38
    \\r5g6b5.clear 0 1 0 4 1400
    \\r5g6b5.order 0 1 0
    \\r5g6b5.origin1 1
    \\r5g6b5.origin1.scr e0779bc1dac5488d
    \\r5g6b5.origin1.a 805b9d3501a94e4e
    \\r5g6b5.origin2 0 -100 225
    \\r5g6b5.origin2.scr e0779bc1dac5488d
    \\r5g6b5.origin2.a 805b9d3501a94e4e
    \\r5g6b5.origin3 1
    \\r5g6b5.origin3.scr d9e08aa845cf028a
    \\r5g6b5.origin3.c c3cf3beed08de94d
    \\r5g6b5.origin4 1
    \\r5g6b5.origin4.scr 51751aa9b2a59d15
    \\r5g6b5.origin5 0
    \\r5g6b5.clear 0 0 0 8 2225
    \\r5g6b5.setrefresh1 1 1 9
    \\r5g6b5.setrefresh1.scr 30f2408d897c0315
    \\r5g6b5.setrefresh2 1 0
    \\r5g6b5.setrefresh3 1
    \\r5g6b5.setrefresh3.scr 30f2408d897c0315
    \\r5g6b5.delete_b.scr d04978ec0143913d
    \\r5g6b5.delete_a.scr c3f97ac475b3a524
    \\r5g6b5.order 1 1
    \\r5g6b5.free_c.scr c3f97ac475b3a524
    \\k2.alloc_a f46b3e4d3953fb4d
    \\k2.alloc_b c3adebe2a58399f5
    \\k2.clear 0 1 1 400
    \\k2.draw_a.scr e3891f358b61e21d
    \\k2.draw_a.a 493a7d0703818159
    \\k2.draw_b.scr ec0829155253fa1b
    \\k2.tofront_a.scr 2f9d7849b2662a96
    \\k2.tofront_a.a 85da4dcc162017cb
    \\k2.clear 1 0 1 400
    \\k2.arc_b.scr 8bab419eb7fa1274
    \\k2.torear_a.scr aa28a72f3ad9ecb2
    \\k2.clear 0 1 2 800
    \\k2.alloc_c.scr be438d38e27fd1b2
    \\k2.alloc_c.c bc57523c8579d6d5
    \\k2.draw_c.scr 81d389d65c12a25f
    \\k2.draw_c.c ee3098e9cf836f72
    \\k2.clear 0 0 0 2 800
    \\k2.scroll_a.scr d641e2d0fa3c366d
    \\k2.scroll_a.a e1324275508e24ec
    \\k2.a_to_c.scr 974d2441daa4a8f8
    \\k2.a_to_c.c 8f2ba0c8522a61ea
    \\k2.scroll_c.c ad0549b5e9d4a955
    \\k2.memload 105
    \\k2.load_a.scr 02e43546190494c8
    \\k2.load_a.a 014d2e16b97823d8
    \\k2.memload_c 280
    \\k2.load_c.c 26dc7f3b3398d2f0
    \\k2.memunload_b 385
    \\k2.tofrontn.scr 30bb647814587393
    \\k2.clear 1 0 0 2 800
    \\k2.torearn.scr f6578a1e25577675
    \\k2.clear 0 1 0 4 1400
    \\k2.order 0 1 0
    \\k2.origin1 1
    \\k2.origin1.scr 131ca6e03ca4de71
    \\k2.origin1.a cc9b82747ab663e6
    \\k2.origin2 0 -100 225
    \\k2.origin2.scr 131ca6e03ca4de71
    \\k2.origin2.a 8ce2dc5cd2a5ad1a
    \\k2.origin3 1
    \\k2.origin3.scr b4a7a7187fac4294
    \\k2.origin3.c 26dc7f3b3398d2f0
    \\k2.origin4 1
    \\k2.origin4.scr 922fa374447e3132
    \\k2.origin5 0
    \\k2.clear 0 0 0 8 2225
    \\k2.setrefresh1 1 1 9
    \\k2.setrefresh1.scr 299cabb3cf52a1cc
    \\k2.setrefresh2 1 0
    \\k2.setrefresh3 1
    \\k2.setrefresh3.scr 299cabb3cf52a1cc
    \\k2.delete_b.scr 51acb4d60763e854
    \\k2.delete_a.scr 1fb2e208714906cf
    \\k2.order 1 1
    \\k2.free_c.scr 1fb2e208714906cf
;
