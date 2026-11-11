//! _memlayerop: apply a function to the pieces of a layer, each piece
//! either visible on the screen or hidden in the save area.
//! From /sys/src/libmemlayer/layerop.c.
//!
//! DIFF:
//!   - The callback takes ?*Memimage for the image to work on: the C
//!     passes l->save, which is nil for a layer with a refresh function,
//!     and its callbacks check `insave` before touching it.  `insave`
//!     is bool.
//!   - _layerop does not recurse.  The C calls itself once for every
//!     window in front of the piece being cut, so a client with a few
//!     hundred overlapping windows could run a kernel stack (8K) out.
//!     Here the pieces still to do wait on an explicit stack, pushed so
//!     that `fn` is called on the same pieces in the same order as the
//!     C's depth-first recursion (a source may be the screen the pieces
//!     are drawn to, so the order is kept rather than argued away).
//!     The stack needs at most 4n+1 entries for n windows in front of
//!     the layer; up to `Nsmall` live on the kernel stack and more are
//!     allocated.  If that allocation fails, nothing is drawn, as when
//!     the C's draw routines cannot allocate.  The RECUR macro is gone.
//!   - The arguments that do not change (fn, i, clipr, etc) travel
//!     behind one pointer.

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("memlayer.zig");
const kernel = @import("../libmemdraw/kernel.zig");

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

/// A piece still to do: cut `r` by the windows from `front` back to
/// the layer, or, when `front` is null, put `r` in the save area.
const Piece = struct {
    r: Rectangle,
    front: ?*Memimage,
};

/// Pieces kept on the kernel stack before _memlayerop allocates.
const Nsmall = 8;

fn _layerop(op: *const Op, r0: Rectangle, front0: *Memimage, stack: []Piece) void {
    const i = op.i;
    stack[0] = .{ .r = r0, .front = front0 };
    var n: usize = 1;

    while (n > 0) {
        n -= 1;
        var r = stack[n].r;
        var front = stack[n].front orelse {
            // r is covered by a window in front, so put in save area
            op.@"fn"(i.layer.?.save, r, op.clipr, op.etc, true);
            continue;
        };
        // r doesn't touch this window; continue on next rearmost
        while (front != i and !rectXrect(r, front.layer.?.screenr))
            front = front.layer.?.rear.?;
        if (front == i) {
            // no one is in front of this part of window; use the screen
            op.@"fn"(i.layer.?.screen.image, r, op.clipr, op.etc, false);
            continue;
        }
        const fr = front.layer.?.screenr;
        const rear = front.layer.?.rear.?;
        var cut: [4]Rectangle = undefined;
        var ncut: usize = 0;
        if (r.min.y < fr.min.y) {
            // above front layer
            cut[ncut] = Rect(r.min.x, r.min.y, r.max.x, fr.min.y);
            ncut += 1;
            r.min.y = fr.min.y;
        }
        if (r.max.y > fr.max.y) {
            // below front layer
            cut[ncut] = Rect(r.min.x, fr.max.y, r.max.x, r.max.y);
            ncut += 1;
            r.max.y = fr.max.y;
        }
        if (r.min.x < fr.min.x) {
            // left of front layer
            cut[ncut] = Rect(r.min.x, r.min.y, fr.min.x, r.max.y);
            ncut += 1;
            r.min.x = fr.min.x;
        }
        if (r.max.x > fr.max.x) {
            // right of front layer
            cut[ncut] = Rect(fr.max.x, r.min.y, r.max.x, r.max.y);
            ncut += 1;
            r.max.x = fr.max.x;
        }
        // The C finishes each cut piece, in this order, before the
        // next one and before r goes in the save area: push in reverse.
        stack[n] = .{ .r = r, .front = null };
        n += 1;
        while (ncut > 0) {
            ncut -= 1;
            stack[n] = .{ .r = cut[ncut], .front = rear };
            n += 1;
        }
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
        // Each window in front can leave four pieces and a save-area
        // call waiting, of which the next one done is taken off again.
        var nfront: usize = 0;
        var f = l.screen.frontmost.?;
        while (f != i) : (f = f.layer.?.rear.?)
            nfront += 1;
        const need = 4 * nfront + 1;
        var small: [Nsmall]Piece = undefined;
        if (need <= small.len) {
            _layerop(&op, screenr, l.screen.frontmost.?, &small);
        } else {
            const big = kernel.newslice(Piece, need) orelse return;
            defer kernel.free(big);
            _layerop(&op, screenr, l.screen.frontmost.?, big);
        }
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

// Tests: the loop must hand `fn` the same pieces, in the same order,
// as the C's recursion, which is kept here as the reference.

const Call = struct { img: ?*Memimage, r: Rectangle, insave: bool };

const Rec = struct {
    calls: []Call,
    n: usize = 0,
    over: bool = false,

    fn init() !Rec {
        return .{ .calls = try @import("std").testing.allocator.alloc(Call, 1 << 16) };
    }

    fn deinit(rec: *Rec) void {
        @import("std").testing.allocator.free(rec.calls);
    }

    fn record(img: ?*Memimage, r: Rectangle, _: Rectangle, etc: ?*anyopaque, insave: bool) void {
        const rec: *Rec = @ptrCast(@alignCast(etc.?));
        if (rec.n == rec.calls.len) {
            rec.over = true;
            return;
        }
        rec.calls[rec.n] = .{ .img = img, .r = r, .insave = insave };
        rec.n += 1;
    }
};

/// The C's _layerop, recursion and all.
fn refLayerop(op: *const Op, r_: Rectangle, front_: *Memimage) void {
    var r = r_;
    var front = front_;
    const i = op.i;
    while (true) {
        if (front == i) {
            op.@"fn"(i.layer.?.screen.image, r, op.clipr, op.etc, false);
            return;
        }
        const fr = front.layer.?.screenr;
        if (!rectXrect(r, fr)) {
            front = front.layer.?.rear.?;
            continue;
        }
        const rear = front.layer.?.rear.?;
        if (r.min.y < fr.min.y) {
            refLayerop(op, Rect(r.min.x, r.min.y, r.max.x, fr.min.y), rear);
            r.min.y = fr.min.y;
        }
        if (r.max.y > fr.max.y) {
            refLayerop(op, Rect(r.min.x, fr.max.y, r.max.x, r.max.y), rear);
            r.max.y = fr.max.y;
        }
        if (r.min.x < fr.min.x) {
            refLayerop(op, Rect(r.min.x, r.min.y, fr.min.x, r.max.y), rear);
            r.min.x = fr.min.x;
        }
        if (r.max.x > fr.max.x) {
            refLayerop(op, Rect(fr.max.x, r.min.y, r.max.x, r.max.y), rear);
            r.max.x = fr.max.x;
        }
        op.@"fn"(i.layer.?.save, r, op.clipr, op.etc, true);
        return;
    }
}

/// The C's _memlayerop, on refLayerop.
fn refMemlayerop(f: Layerfn, i: *Memimage, screenr_: Rectangle, clipr: Rectangle, etc: ?*anyopaque) void {
    var screenr = screenr_;
    const l = i.layer.?;
    if (!rectclip(&screenr, l.screenr))
        return;
    if (l.clear) {
        f(l.screen.image, screenr, clipr, etc, false);
        return;
    }
    var r = screenr;
    const scr = l.screen.image.clipr;
    if (rectclip(&screenr, scr)) {
        const op: Op = .{ .@"fn" = f, .i = i, .clipr = clipr, .etc = etc };
        refLayerop(&op, screenr, l.screen.frontmost.?);
    }
    if (rectinrect(r, scr))
        return;
    if (!rectXrect(r, scr)) {
        f(l.save, r, clipr, etc, true);
        return;
    }
    if (r.min.y < scr.min.y) {
        f(l.save, Rect(r.min.x, r.min.y, r.max.x, scr.min.y), clipr, etc, true);
        r.min.y = scr.min.y;
    }
    if (r.max.y > scr.max.y) {
        f(l.save, Rect(r.min.x, scr.max.y, r.max.x, r.max.y), clipr, etc, true);
        r.max.y = scr.max.y;
    }
    if (r.min.x < scr.min.x) {
        f(l.save, Rect(r.min.x, r.min.y, scr.min.x, r.max.y), clipr, etc, true);
        r.min.x = scr.min.x;
    }
    if (r.max.x > scr.max.x)
        f(l.save, Rect(scr.max.x, r.min.y, r.max.x, r.max.y), clipr, etc, true);
}

/// Run both on `r` of layer `i` and require the same calls of `fn`.
fn compare(i: *Memimage, r: Rectangle) !usize {
    const std = @import("std");
    var got: Rec = try .init();
    defer got.deinit();
    var want: Rec = try .init();
    defer want.deinit();
    _memlayerop(Rec.record, i, r, r, &got);
    refMemlayerop(Rec.record, i, r, r, &want);
    try std.testing.expect(!got.over and !want.over);
    try std.testing.expectEqual(want.n, got.n);
    for (want.calls[0..want.n], got.calls[0..got.n]) |w, g| {
        try std.testing.expectEqual(w.img, g.img);
        try std.testing.expectEqual(w.insave, g.insave);
        try std.testing.expectEqual(w.r, g.r);
    }
    return want.n;
}

test "_memlayerop cuts as the C's recursion does" {
    const std = @import("std");
    const T = @import("../libmemdraw/line.zig").testing;
    const memlalloc = @import("lalloc.zig").memlalloc;
    const memldelete = @import("ldelete.zig").memldelete;
    const freememimage = @import("../libmemdraw/alloc.zig").freememimage;

    T.init();
    defer T.deinit();
    const fill = T.col(0x777777FF);
    defer freememimage(fill);
    const si = T.mk(Rect(0, 0, 200, 150), draw.GREY8, 0x777777FF);
    defer freememimage(si);

    var prng = std.Random.DefaultPrng.init(0x1a7e5);
    const rnd = prng.random();
    var pieces: usize = 0;
    var round: usize = 0;
    while (round < 1000) : (round += 1) {
        var scr: memlayer_h.Memscreen = .{ .frontmost = null, .rearmost = null, .image = si, .fill = fill };
        var w: [12]*Memimage = undefined;
        const nw = rnd.intRangeAtMost(usize, 1, w.len);
        for (w[0..nw]) |*p| {
            // Some windows hang off the screen.
            const x = rnd.intRangeAtMost(i32, -20, 190);
            const y = rnd.intRangeAtMost(i32, -20, 140);
            p.* = memlalloc(&scr, Rect(x, y, x + rnd.intRangeAtMost(i32, 2, 90), y + rnd.intRangeAtMost(i32, 2, 70)), null, null, draw.DWhite).?;
        }
        var k: usize = 0;
        while (k < 10) : (k += 1) {
            const i = w[rnd.uintLessThan(usize, nw)];
            const sr = i.layer.?.screenr;
            const x = rnd.intRangeAtMost(i32, sr.min.x - 5, sr.max.x);
            const y = rnd.intRangeAtMost(i32, sr.min.y - 5, sr.max.y);
            pieces += try compare(i, Rect(x, y, x + rnd.intRangeAtMost(i32, 1, 100), y + rnd.intRangeAtMost(i32, 1, 80)));
        }
        for (w[0..nw]) |p|
            memldelete(p);
    }
    // The layouts must have made the code cut, not just pass through.
    try std.testing.expect(pieces > 10000);
}

test "_memlayerop with hundreds of windows in front" {
    const std = @import("std");
    const T = @import("../libmemdraw/line.zig").testing;
    const memlalloc = @import("lalloc.zig").memlalloc;
    const memldelete = @import("ldelete.zig").memldelete;
    const freememimage = @import("../libmemdraw/alloc.zig").freememimage;

    T.init();
    defer T.deinit();
    const fill = T.col(0x777777FF);
    defer freememimage(fill);
    const si = T.mk(Rect(0, 0, 1300, 100), draw.GREY8, 0x777777FF);
    defer freememimage(si);
    var scr: memlayer_h.Memscreen = .{ .frontmost = null, .rearmost = null, .image = si, .fill = fill };

    // A wide window at the back, then 600 thin ones in front of it,
    // each a little lower than the last, so that a draw across the
    // back one is cut by every one of them: in the C, 600 levels of
    // recursion on an 8K kernel stack.
    const back = memlalloc(&scr, Rect(0, 0, 1300, 100), null, null, draw.DWhite).?;
    var front: [600]*Memimage = undefined;
    for (&front, 0..) |*p, k| {
        const x: i32 = @intCast(2 * k + 1);
        p.* = memlalloc(&scr, Rect(x, @intCast(k / 10), x + 1, 90), null, null, draw.DBlack).?;
    }
    const n = try compare(back, Rect(0, 0, 1300, 100));
    try std.testing.expect(n > 30000);
    for (front) |p|
        memldelete(p);
    memldelete(back);
}
