//! A fuzz test of the draw libraries as devdraw drives them.  Not from
//! a C file.
//!
//! Everything a program writes to /dev/draw/n/data ends in a call of
//! libmemdraw or libmemlayer with numbers the program chose, and the
//! kernel is built with overflow, cast and bounds checks that panic.
//! This test plays the part of devdraw's drawmesg: it keeps a set of
//! images, screens, windows and fonts the way a client could have made
//! them, and calls the libraries the way each draw message does, making
//! only the checks drawmesg makes, with coordinates and sizes drawn
//! from small values, values at the edges of the images involved, and
//! the extremes of 32 bits.  It also calls the entry points that only
//! the kernel uses (memimagedraw, memfillcolor, memimagestring, the
//! load and unload functions, memaffinewarp, drawrepl, rectclip).
//!
//! It passes when nothing panics, nothing writes outside its memory
//! (kernel.zig's host allocator surrounds every block with guard
//! bytes, checked after every call), no image changes other than the
//! ones a call may write (the pixels of every image are hashed after
//! every call), and nothing is leaked.
//!
//! The run is deterministic.  For hunting, the environment sets more:
//!     FUZZ_ITERS=n    calls per seed (default `iterations`)
//!     FUZZ_SEED=n     first seed (default `seed0`)
//!     FUZZ_SEEDS=n    number of seeds, one after another (default 1)
//!     FUZZ_TRACE=1    print every call before making it
//!     FUZZ_SLOW=usec  print the calls that take longer than this
//!     FUZZ_STATS=1    print how many calls of each kind changed pixels
//!     FUZZ_PAGEGUARD=1  (Linux) give every block of the libraries
//!                     its own pages between two inaccessible ones, so
//!                     that reading outside a block faults too
//!     FUZZ_BIG=1      also use radii and thicknesses of thousands of
//!                     pixels, which make the libraries allocate
//!                     scratch images of hundreds of megabytes
//! e.g. (the build system does not run a test again because the
//! environment changed, so run the test itself)
//!     FUZZ_SEEDS=50 FUZZ_PAGEGUARD=1 zig test -OReleaseSafe \
//!         --dep fmt --dep fcall -Mroot=src/kernel/drawtest.zig \
//!         -Mfmt=src/lib/fmt.zig -Mfcall=src/lib/fcall.zig \
//!         --test-filter fuzz:
//!
//! What it leaves out: images larger than a few thousand pixels (the
//! code is the same, the loops longer), hwdraw (the screen's hook), and
//! devdraw's own message parsing, which needs the kernel.

const std = @import("std");
const builtin = @import("builtin");
const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("memdraw.zig");
const memlayer_h = @import("../libmemlayer/memlayer.zig");
const kernel = @import("kernel.zig");
const malloc = @import("alloc.zig");
const mdraw = @import("draw.zig");
const mline = @import("line.zig");
const mwarp = @import("warp.zig");

const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const badrect = @import("../libdraw/badrect.zig").badrect;
const bytesperline = @import("../libdraw/bytesperline.zig").bytesperline;
const drawrepl = @import("../libdraw/drawrepl.zig").drawrepl;
const drawreplxy = @import("../libdraw/drawrepl.zig").drawreplxy;

const allocmemimage = malloc.allocmemimage;
const freememimage = malloc.freememimage;
const memimagedraw = mdraw.memimagedraw;
const memfillcolor = mdraw.memfillcolor;
const memlinebbox = mline.memlinebbox;
const memlineendsize = mline.memlineendsize;
const memimageline = mline.memimageline;
const memarc = @import("arc.zig").memarc;
const memellipse = @import("ellipse.zig").memellipse;
const mempoly = @import("poly.zig").mempoly;
const memfillpoly = @import("fillpoly.zig").memfillpoly;
const memimagestring = @import("string.zig").memimagestring;
const memsubfontwidth = @import("string.zig").memsubfontwidth;
const getmemdefont = @import("defont.zig").getmemdefont;
const freememsubfont = @import("subfont.zig").freememsubfont;
const loadmemimage = @import("load.zig").loadmemimage;
const cloadmemimage = @import("cload.zig").cloadmemimage;
const unloadmemimage = @import("unload.zig").unloadmemimage;
const memaffinewarp = mwarp.memaffinewarp;

const memdraw = @import("../libmemlayer/draw.zig").memdraw;
const memline = @import("../libmemlayer/line.zig").memline;
const memlalloc = @import("../libmemlayer/lalloc.zig").memlalloc;
const memldelete = @import("../libmemlayer/ldelete.zig").memldelete;
const memltofrontn = @import("../libmemlayer/ltofront.zig").memltofrontn;
const memltorearn = @import("../libmemlayer/ltorear.zig").memltorearn;
const memlsetrefresh = @import("../libmemlayer/lsetrefresh.zig").memlsetrefresh;
const memlorigin = @import("../libmemlayer/lorigin.zig").memlorigin;
const memlnorefresh = @import("../libmemlayer/lorigin.zig").memlnorefresh;
const memload = @import("../libmemlayer/load.zig").memload;
const memunload = @import("../libmemlayer/unload.zig").memunload;
const memlaffinewarp = @import("../libmemlayer/warp.zig").memlaffinewarp;

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Warp = draw.Warp;
const Memimage = memdraw_h.Memimage;
const Memsubfont = memdraw_h.Memsubfont;
const Memscreen = memlayer_h.Memscreen;
const Refreshfn = memlayer_h.Refreshfn;
const Frepl = memdraw_h.Frepl;
const Dx = draw.Dx;
const Dy = draw.Dy;
const ZP = draw.ZP;
const Pt = arith.Pt;
const Rect = arith.Rect;
const rectinrect = arith.rectinrect;
const combinerect = arith.combinerect;

/// What `zig build test` runs.
const iterations = 400000;
const seed0 = 0x9f0c_2026;

const minInt = std.math.minInt(i32);
const maxInt = std.math.maxInt(i32);

const CHAN1 = draw.CHAN1;
const CHAN2 = draw.CHAN2;
const CHAN3 = draw.CHAN3;
const CHAN4 = draw.CHAN4;
const CRed = draw.CRed;
const CGreen = draw.CGreen;
const CBlue = draw.CBlue;
const CGrey = draw.CGrey;
const CAlpha = draw.CAlpha;
const CMap = draw.CMap;
const CIgnore = draw.CIgnore;

/// The image formats: the usual ones several times over, then ones a
/// program can ask for although nothing does.
const chans = [_]u32{
    draw.GREY1,                                     draw.GREY1,
    draw.GREY2,                                     draw.GREY4,
    draw.GREY8,                                     draw.CMAP8,
    draw.RGB15,                                     draw.RGB16,
    draw.RGB24,                                     draw.RGBA32,
    draw.ARGB32,                                    draw.XRGB32,
    draw.XRGB32,                                    draw.BGR24,
    draw.XBGR32,                                    draw.RGBA32,
    draw.GREY8,                                     draw.XRGB32,
    CHAN1(CAlpha, 8),                               CHAN1(CAlpha, 1),
    CHAN1(CMap, 4),                                 CHAN1(CRed, 8),
    CHAN1(CIgnore, 8),                              CHAN2(CGrey, 8, CAlpha, 8),
    CHAN2(CAlpha, 4, CGrey, 4),                     CHAN2(CMap, 8, CAlpha, 8),
    CHAN3(CRed, 3, CGreen, 3, CBlue, 2),            CHAN4(CRed, 4, CGreen, 4, CBlue, 4, CAlpha, 4),
    CHAN4(CAlpha, 1, CRed, 5, CGreen, 5, CBlue, 5), CHAN2(CGrey, 1, CAlpha, 1),
    CHAN3(CAlpha, 8, CGrey, 8, CIgnore, 8),         CHAN4(CIgnore, 8, CIgnore, 8, CIgnore, 8, CIgnore, 8),
    CHAN2(CAlpha, 7, CMap, 1),                      CHAN3(CGrey, 2, CAlpha, 2, CIgnore, 4),
    CHAN4(CBlue, 2, CGreen, 2, CRed, 2, CAlpha, 2), CHAN2(CRed, 8, CBlue, 8),
    CHAN3(CMap, 8, CAlpha, 8, CIgnore, 8),          CHAN4(CIgnore, 8, CMap, 8, CAlpha, 8, CRed, 8),
    CHAN2(CMap, 8, CIgnore, 8),                     CHAN3(CGrey, 8, CMap, 8, CAlpha, 8),
};

/// devdraw's FChar.
const FChar = struct {
    minx: i32 = 0,
    maxx: i32 = 0,
    miny: u8 = 0,
    maxy: u8 = 0,
    left: i8 = 0,
    width: u8 = 0,
};

/// devdraw's DScreen with its Memscreen.
const Scr = struct {
    s: Memscreen,
    ref: u32, // one for the client's CScreen, one per window
    held: bool, // the client has not freed it ('F')
    image: *Img,
    fill: *Img,
    nwin: u32 = 0,
};

/// devdraw's DImage.
const Img = struct {
    i: *Memimage,
    scr: ?*Scr = null, // set for a window
    ref: u32 = 1, // one for the client, one per screen using it
    held: bool = true, // the client has not freed it ('f')
    fchar: ?[]FChar = null,
    ascent: i32 = 0,
    sum: u64 = 0,
    fresh: bool = true,
    refreshed: Rectangle = .{}, // what devdraw's drawrefresh keeps
    /// one of the images every client has (display->opaque, a colour):
    /// the fuzz does not free it or change its clipr
    fixed: bool = false,
};

const Nimg = 96;
const Nscr = 6;

const ta = std.testing.allocator;

var prng: std.Random.DefaultPrng = undefined;
var rnd: std.Random = undefined;
var imgs: [Nimg]?*Img = @splat(null);
var scrs: [Nscr]?*Scr = @splat(null);
/// chance in 100 that a coordinate of the current call is an extreme
var wild: u32 = 0;
/// the current call keeps its coordinates inside the images
var tidy = false;
/// the Memdata of the images the current call may write
var touched: [64]?*anyopaque = @splat(null);
var ntouched: usize = 0;
var trace = false;
var big = false;
var stats = false;
var opno: usize = 0;
var defont: *Memsubfont = undefined;
var scratch: [8192]u8 = undefined;

fn tr(comptime name: []const u8, args: anytype) void {
    if (trace)
        std.debug.print("{d}: " ++ name ++ " {any}\n", .{ opno, args });
}

fn chance(pct: u32) bool {
    return rnd.uintLessThan(u32, 100) < pct;
}

fn between(lo: i32, hi: i32) i32 {
    if (lo > hi)
        return rnd.intRangeAtMost(i32, hi, lo);
    return rnd.intRangeAtMost(i32, lo, hi);
}

const extremes = [_]i32{
    minInt,     minInt,      maxInt,        maxInt,
    1 << 30,    -(1 << 30),  (1 << 30) - 1, 1 - (1 << 30),
    1 << 25,    -(1 << 25),  1 << 26,       -(1 << 26),
    1 << 28,    -(1 << 28),  0x3FFFFFF,     -0x3FFFFFF,
    0x3FFFFFFF, -0x3FFFFFFF, 1 << 21,       -(1 << 21),
    1 << 22,    -(1 << 22),  1 << 20,       -(1 << 20),
    46341,      -46341,      65536,         -65536,
    32768,      -32768,      1 << 24,       -(1 << 24),
    1 << 29,    -(1 << 29),  maxInt / 1024, minInt / 1024,
    maxInt / 2, minInt / 2,  1 << 15,       1 << 16,
};

fn extreme() i32 {
    return extremes[rnd.uintLessThan(usize, extremes.len)] +% between(-2, 2);
}

/// A coordinate for something that lies between lo and hi.
fn coord(lo: i32, hi: i32) i32 {
    const k = rnd.uintLessThan(u32, 100);
    if (k < wild)
        return extreme();
    if (lo > hi or hi -% lo < 0)
        return lo +% between(-40, 40);
    if (tidy)
        return between(lo, @max(lo, hi - 1));
    if (k < wild + 25)
        return (if (chance(50)) lo else hi) +% between(-3, 3);
    if (k < wild + 50)
        return between(lo, hi);
    const m = std.math.clamp(hi - lo, 2, 40);
    return between(lo -| m, hi +| m);
}

fn point(r: Rectangle) Point {
    return .{ .x = coord(r.min.x, r.max.x), .y = coord(r.min.y, r.max.y) };
}

/// A rectangle for something that lies in r: usually well formed,
/// sometimes any two points.
fn rect(r: Rectangle) Rectangle {
    if (tidy and r.min.x < r.max.x and r.min.y < r.max.y and chance(60)) {
        const x0 = between(r.min.x, r.max.x - 1);
        const y0 = between(r.min.y, r.max.y - 1);
        return Rect(x0, y0, between(x0 +% 1, r.max.x), between(y0 +% 1, r.max.y));
    }
    if (chance(70)) {
        const p = point(r);
        const w = if (chance(wild)) extreme() else between(0, @max(1, @min(200, Dx(r) +% 5)));
        const h = if (chance(wild)) extreme() else between(0, @max(1, @min(200, Dy(r) +% 5)));
        return .{ .min = p, .max = .{ .x = p.x +% w, .y = p.y +% h } };
    }
    if (chance(15))
        return r;
    return .{ .min = point(r), .max = point(r) };
}

/// A rectangle inside r, as 'r' and 'y' need.
fn subrect(r: Rectangle) Rectangle {
    if (chance(20))
        return r;
    if (chance(8) or r.min.x >= r.max.x or r.min.y >= r.max.y)
        return rect(r);
    const x0 = between(r.min.x, r.max.x - 1);
    const y0 = between(r.min.y, r.max.y - 1);
    return Rect(x0, y0, between(x0, r.max.x), between(y0, r.max.y));
}

/// A clipping rectangle for an image with rectangle r.
fn cliprect(r: Rectangle) Rectangle {
    return switch (rnd.uintLessThan(u32, 14)) {
        0, 1, 2, 3 => r,
        4 => Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF),
        5, 6 => Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF),
        7 => Rect(minInt, minInt, maxInt, maxInt),
        8 => .{ .min = .{ .x = extreme(), .y = extreme() }, .max = .{ .x = extreme(), .y = extreme() } },
        // inside r and empty or inverted: rectclip "clips" to these
        9 => blk: {
            const x = between(r.min.x, r.max.x);
            const y = between(r.min.y, r.max.y);
            break :blk Rect(x, y, x -% between(0, 3), y +% between(-3, 3));
        },
        10 => blk: {
            const x = between(r.min.x, r.max.x);
            const y = between(r.min.y, r.max.y);
            break :blk Rect(x, y, x +% between(-3, 3), y -% between(0, 3));
        },
        else => rect(r),
    };
}

/// A radius or thickness: devdraw refuses negative ones.
fn radius() i32 {
    const k = rnd.uintLessThan(u32, 100);
    if (k < 55)
        return between(0, 6);
    if (k < 75)
        return between(0, 40);
    if (k < 80)
        return between(0, 300);
    if (k < 82 and big)
        return between(300, 46345);
    if (k < 83)
        return between(46335, 46345); // where the squares overflow
    // too big for the libraries' scratch images
    const t = [_]i32{ maxInt, maxInt - 1, 1 << 30, (1 << 30) - 1, 1 << 25, 1 << 26, 1 << 28, 1 << 29, 0x3FFFFFF, 0x3FFFFFFF, (1 << 25) - 1 };
    return t[rnd.uintLessThan(usize, t.len)] +| between(-2, 2);
}

fn endtype() i32 {
    return switch (rnd.uintLessThan(u32, 10)) {
        0, 1, 2 => draw.Endsquare,
        3, 4 => draw.Enddisc,
        5, 6 => draw.Endarrow,
        7, 8 => draw.Endarrow | (between(0, 0x1FF) << 5) | (between(0, 0x1FF) << 14) | (between(0, 0x1FF) << 23),
        else => rnd.int(i32),
    };
}

fn drawop() i32 {
    if (chance(8))
        return between(0, 255); // client.op is a byte
    if (chance(40))
        return draw.SoverD;
    return between(0, draw.Ncomp - 1);
}

fn color() u32 {
    const t = [_]u32{ draw.DWhite, draw.DBlack, draw.DTransparent, draw.DNofill, draw.DRed, 0x80808080, 0x000000FF, 0xFFFFFF00 };
    if (chance(50))
        return t[rnd.uintLessThan(usize, t.len)];
    return rnd.int(u32);
}

// ---------------------------------------------------------------------
// the client's images
// ---------------------------------------------------------------------

fn nheld() usize {
    var n: usize = 0;
    for (imgs) |ip| {
        if (ip) |im| {
            if (im.held) n += 1;
        }
    }
    return n;
}

const Want = enum { any, plain, window, font };

var dopaque: *Img = undefined;
var colour: *Img = undefined;

/// A source: now and then a plain colour.
fn picksrc() ?*Img {
    if (chance(20))
        return colour;
    return pick(.any);
}

/// A mask: often display->opaque, as in real use.
fn pickmask() ?*Img {
    if (chance(45))
        return dopaque;
    return pick(.any);
}

fn pick(want: Want) ?*Img {
    var tries: usize = 0;
    while (tries < 64) : (tries += 1) {
        const im = imgs[rnd.uintLessThan(usize, Nimg)] orelse continue;
        if (!im.held) continue;
        switch (want) {
            .any => {},
            .plain => if (im.i.layer != null) continue,
            .window => if (im.i.layer == null) continue,
            .font => if (im.fchar == null) continue,
        }
        return im;
    }
    return null;
}

fn pickscr() ?*Scr {
    var tries: usize = 0;
    while (tries < 16) : (tries += 1) {
        const s = scrs[rnd.uintLessThan(usize, Nscr)] orelse continue;
        if (s.held) return s;
    }
    return null;
}

fn install(i: *Memimage, scr: ?*Scr) ?*Img {
    for (&imgs) |*slot| {
        if (slot.* == null) {
            const im = ta.create(Img) catch @panic("fuzz: no memory");
            im.* = .{ .i = i, .scr = scr };
            slot.* = im;
            return im;
        }
    }
    return null;
}

/// drawfreedscreen
fn freedscreen(s: *Scr) void {
    s.ref -= 1;
    if (s.ref > 0)
        return;
    for (&scrs) |*slot| {
        if (slot.* == s) slot.* = null;
    }
    freedimage(s.image);
    freedimage(s.fill);
    ta.destroy(s);
}

/// drawfreedimage
fn freedimage(im: *Img) void {
    im.ref -= 1;
    if (im.ref > 0)
        return;
    if (im.scr) |s| {
        touch(im.i);
        im.i.layer.?.refreshptr = null;
        memldelete(im.i);
        s.nwin -= 1;
        freedscreen(s);
    } else {
        freememimage(im.i);
    }
    if (im.fchar) |f| ta.free(f);
    for (&imgs) |*slot| {
        if (slot.* == im) slot.* = null;
    }
    ta.destroy(im);
}

// ---------------------------------------------------------------------
// checking
// ---------------------------------------------------------------------

/// The call may write i: its pixels or, for a window, the screen and
/// the save areas of the screen's windows.  Repainting a screen reads
/// its fill image, and reading a window can bring its save area up to
/// date, so a screen's fill counts too.
fn touch(i: *Memimage) void {
    const d: *anyopaque = i.data;
    var l = i.layer;
    while (l) |x| {
        if (x.screen.fill) |f| {
            if (f.layer != null and !wastouched(f))
                touch(f);
        }
        l = x.screen.image.layer;
    }
    for (touched[0..ntouched]) |t| {
        if (t == d) return;
    }
    if (ntouched == touched.len)
        @panic("fuzz: touched too small");
    touched[ntouched] = d;
    ntouched += 1;
}

fn wastouched(i: *Memimage) bool {
    const d: *anyopaque = i.data;
    for (touched[0..ntouched]) |t| {
        if (t == d) return true;
    }
    return false;
}

/// The pixels an Img owns: an image's own, a window's save area.
fn pixels(im: *Img) []const u8 {
    var i = im.i;
    if (i.layer) |l|
        i = l.save orelse return &.{};
    const n: usize = @as(usize, i.width) * 4 * @as(usize, @intCast(Dy(i.r)));
    return i.data.bdata[0..n];
}

fn fail(comptime what: []const u8, args: anytype) noreturn {
    std.debug.print("fuzz: call {d}: " ++ what ++ "\n", .{opno} ++ args);
    @panic("fuzz failed (run again with FUZZ_TRACE=1)");
}

/// Returns whether any image changed.
fn check() bool {
    var changed = false;
    if (!kernel.checkguards())
        fail("something wrote outside its memory", .{});
    for (imgs, 0..) |ip, k| {
        const im = ip orelse continue;
        const h = std.hash.Wyhash.hash(0, pixels(im));
        if (!im.fresh and h != im.sum and !wastouched(im.i))
            fail("image {d} changed although nothing drew on it", .{k});
        if (h != im.sum)
            changed = true;
        im.sum = h;
        im.fresh = false;
        // what the libraries rely on
        const i = im.i;
        if (i.layer == null and badrect(i.r))
            fail("image {d} has a bad rectangle", .{k});
    }
    ntouched = 0;
    return changed;
}

// ---------------------------------------------------------------------
// the draw messages
// ---------------------------------------------------------------------

const origins = [_]Point{
    .{ .x = 0, .y = 0 },                         .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 0 },                         .{ .x = -5, .y = -3 },
    .{ .x = 3, .y = 7 },                         .{ .x = 100, .y = 50 },
    .{ .x = -40, .y = -30 },                     .{ .x = (1 << 25) - 60, .y = 100 },
    .{ .x = -(1 << 25), .y = -200 },             .{ .x = 7, .y = 1 << 21 },
    .{ .x = -9, .y = -(1 << 22) },               .{ .x = 1 << 20, .y = 1 << 20 },
    .{ .x = -(1 << 21) - 3, .y = 1000 },         .{ .x = 13, .y = (1 << 22) - 20 },
    // where Memimage.zero is about to overflow (one pixel wide)
    .{ .x = (1 << 25) - 3, .y = (1 << 28) - 1 }, .{ .x = -(1 << 25), .y = -(1 << 28) },
    .{ .x = 5, .y = (1 << 28) - 3 },
};

/// Something a client can reasonably allocate.
fn sanerect() Rectangle {
    const o = origins[rnd.uintLessThan(usize, origins.len)];
    var w = between(1, 48);
    var h = between(1, 32);
    if (chance(20)) {
        w = 1;
        h = 1;
    } else if (chance(8)) {
        w = 1;
    } else if (chance(8)) {
        h = 1;
    }
    return Rect(o.x, o.y, o.x + w, o.y + h);
}

/// The fuzz keeps away from rectangles that are acceptable and big.
fn toobig(r: Rectangle) bool {
    if (badrect(r))
        return false;
    return @as(i64, Dx(r)) * Dy(r) > 6000;
}

/// 'b' without a screen
fn opalloc() void {
    if (nheld() >= 40)
        return opfree();
    const chan = chans[rnd.uintLessThan(usize, chans.len)];
    const r = if (chance(88)) sanerect() else rect(sanerect());
    const repl = chance(30);
    var clipr = if (chance(60)) (if (repl) Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF) else r) else cliprect(r);
    const value = color();
    tr("b", .{ chan, repl, r, clipr, value });
    if (toobig(r))
        return;
    const i = allocmemimage(r, chan) orelse return;
    if (repl)
        i.flags |= Frepl;
    i.clipr = clipr;
    if (!repl) {
        clipr = i.clipr;
        _ = rectclip(&i.clipr, r);
    }
    const im = install(i, null) orelse {
        freememimage(i);
        return;
    };
    _ = im;
    memfillcolor(i, value);
    if (chance(50)) {
        // noise, as a 'y' would put there
        const n: usize = @intCast(bytesperline(r, i.depth) * Dy(r));
        if (n <= scratch.len) {
            rnd.bytes(scratch[0..n]);
            _ = loadmemimage(i, r, scratch[0..n]);
        }
    }
}

/// what devdraw's drawrefresh does with the rectangle
fn refreshfn(_: *Memimage, r: Rectangle, v: ?*anyopaque) void {
    const im: *Img = @ptrCast(@alignCast(v orelse return));
    combinerect(&im.refreshed, r);
}

/// 'b' on a screen
fn opwindow() void {
    const s = pickscr() orelse return opscreen();
    if (s.nwin >= 6)
        return opfree();
    const sr = s.s.image.r;
    var r: Rectangle = undefined;
    if (chance(85)) {
        const x = between(sr.min.x -| 30, sr.max.x +| 20);
        const y = between(sr.min.y -| 20, sr.max.y +| 15);
        r = Rect(x, y, x +| between(1, 50), y +| between(1, 36));
    } else r = rect(sr);
    const refresh = rnd.uintLessThan(u32, 3);
    const clipr = if (chance(60)) r else cliprect(r);
    const value = color();
    tr("b window", .{ sr, r, refresh, clipr, value });
    if (toobig(r))
        return;
    const reffn: ?Refreshfn = switch (refresh) {
        draw.Refbackup => null,
        draw.Refnone => &memlnorefresh,
        else => &refreshfn,
    };
    touch(s.s.image);
    const l = memlalloc(&s.s, r, reffn, null, value) orelse return;
    l.clipr = clipr;
    _ = rectclip(&l.clipr, r);
    const im = install(l, s) orelse {
        memldelete(l);
        return;
    };
    s.ref += 1;
    s.nwin += 1;
    if (reffn) |f|
        _ = memlsetrefresh(l, f, if (refresh == draw.Refmesg) im else null);
}

/// 'A'
fn opscreen() void {
    const image = pick(if (chance(70)) .plain else .any) orelse return;
    const fill = pick(if (chance(70)) .plain else .any) orelse return;
    tr("A", .{ image.i.r, image.i.layer != null, fill.i.r, fill.i.layer != null });
    for (&scrs) |*slot| {
        if (slot.* == null) {
            const s = ta.create(Scr) catch @panic("fuzz: no memory");
            s.* = .{
                .s = .{ .frontmost = null, .rearmost = null, .image = image.i, .fill = fill.i },
                .ref = 1,
                .held = true,
                .image = image,
                .fill = fill,
            };
            image.ref += 1;
            fill.ref += 1;
            slot.* = s;
            return;
        }
    }
    // no room: 'F' one instead
    const s = pickscr() orelse return;
    tr("F", .{});
    s.held = false;
    freedscreen(s);
}

/// 'f'
fn opfree() void {
    const im = pick(.any) orelse return;
    if (im.fixed)
        return;
    tr("f", .{ im.i.r, im.i.layer != null });
    im.held = false;
    freedimage(im);
}

/// 'c'
fn opclip() void {
    const im = pick(.any) orelse return;
    if (im.fixed)
        return;
    const dst = im.i;
    const repl = chance(25);
    const bigclip: Rectangle = Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF);
    const clipr = if (chance(70)) (if (dst.flags & Frepl != 0 and chance(70)) bigclip else dst.r) else cliprect(dst.r);
    tr("c", .{ dst.r, repl, clipr });
    if (repl)
        dst.flags |= Frepl;
    dst.clipr = clipr;
}

/// 'd'
fn opdraw() void {
    const dst = (pick(.any) orelse return).i;
    const src = (picksrc() orelse return).i;
    const mask = (pickmask() orelse return).i;
    const r = rect(dst.r);
    const p = point(src.r);
    const q = if (chance(30)) p else point(mask.r);
    const op = drawop();
    tr("d", .{ dst.r, dst.clipr, dst.flags, src.r, src.clipr, src.flags, mask.r, mask.clipr, mask.flags, r, p, q, op });
    touch(dst);
    touch(src); // a window's save area takes what the screen shows
    if (dst.layer == null and src.layer == null and mask.layer == null and chance(30))
        memimagedraw(dst, r, src, p, if (chance(20)) null else mask, q, op)
    else
        memdraw(dst, r, src, p, mask, q, op);
}

/// 'e', 'E'
fn opellipse() void {
    const dst = (pick(.any) orelse return).i;
    const src = (picksrc() orelse return).i;
    const p = point(dst.r);
    const e0 = radius();
    const e1 = radius();
    const j = radius();
    const sp = point(src.r);
    var ox: i32 = if (chance(50)) rnd.int(i32) | minInt else between(0, maxInt);
    const oy: i32 = if (chance(60)) between(-400, 400) else rnd.int(i32);
    const c: i32 = if (chance(30)) -1 else j;
    const op = drawop();
    tr("e", .{ dst.r, dst.clipr, src.r, src.clipr, src.flags, p, e0, e1, j, c, sp, ox, oy, op });
    touch(dst);
    touch(src);
    if (ox < 0) {
        if (ox & (1 << 30) == 0)
            ox &= 0x7FFFFFFF;
        memarc(dst, p, e0, e1, c, src, sp, ox, oy, op);
    } else {
        memellipse(dst, p, e0, e1, c, src, sp, op);
    }
}

/// 'L'
fn opline() void {
    const dst = (pick(.any) orelse return).i;
    const src = (picksrc() orelse return).i;
    const p = point(dst.r);
    const q = if (chance(15)) Pt(p.x, coord(dst.r.min.y, dst.r.max.y)) else if (chance(15)) Pt(coord(dst.r.min.x, dst.r.max.x), p.y) else point(dst.r);
    const e0 = endtype();
    const e1 = endtype();
    const j = radius();
    const sp = point(src.r);
    const op = drawop();
    tr("L", .{ dst.r, dst.clipr, src.r, src.clipr, src.flags, p, q, e0, e1, j, sp, op });
    touch(dst);
    touch(src);
    if (dst.layer == null and src.layer == null and chance(20))
        memimageline(dst, p, q, e0, e1, j, src, sp, op)
    else
        memline(dst, p, q, e0, e1, j, src, sp, op);
    _ = memlinebbox(p, q, e0, e1, j);
    _ = memlineendsize(e0);
}

/// 'p', 'P'
fn oppoly() void {
    const dst = (pick(.any) orelse return).i;
    const src = (picksrc() orelse return).i;
    var pp: [300]Point = undefined;
    const n: usize = if (chance(3)) rnd.intRangeAtMost(usize, 1, pp.len) else rnd.intRangeAtMost(usize, 1, 9);
    for (pp[0..n], 0..) |*v, k| {
        // drawcoord: a small step from the last point, or anything
        if (k > 0 and chance(40))
            v.* = .{ .x = pp[k - 1].x +% between(-64, 63), .y = pp[k - 1].y +% between(-64, 63) }
        else
            v.* = point(dst.r);
    }
    const e0 = if (chance(50)) endtype() else if (chance(50)) @as(i32, -1) else @as(i32, 1);
    const e1 = endtype();
    const j = radius();
    const sp = point(src.r);
    const op = drawop();
    const filled = chance(50);
    tr("p", .{ filled, dst.r, dst.clipr, src.r, src.clipr, src.flags, pp[0..n], e0, e1, j, sp, op });
    touch(dst);
    touch(src);
    if (filled)
        memfillpoly(dst, pp[0..n], e0, src, sp, op)
    else
        mempoly(dst, pp[0..n], e0, e1, j, src, sp, op);
}

/// 'o'
fn oporigin() void {
    const im = pick(.window) orelse return;
    const dst = im.i;
    const l = dst.layer.?;
    const p = if (chance(30)) dst.r.min else point(dst.r);
    const q = if (chance(30)) l.screenr.min else point(l.screen.image.r);
    tr("o", .{ dst.r, l.screenr, l.screen.image.r, p, q });
    touch(dst);
    _ = memlorigin(dst, p, q);
}

/// 't'
fn optop() void {
    const s = pickscr() orelse return;
    var lp: [8]*Memimage = undefined;
    var n: usize = 0;
    for (imgs) |ip| {
        const im = ip orelse continue;
        if (im.held and im.scr == s and n < lp.len and chance(60)) {
            lp[n] = im.i;
            n += 1;
        }
    }
    if (n == 0)
        return;
    // nothing stops a client naming a window twice
    while (n < lp.len and chance(15)) {
        lp[n] = lp[rnd.uintLessThan(usize, n)];
        n += 1;
    }
    rnd.shuffle(*Memimage, lp[0..n]);
    const top = chance(50);
    tr("t", .{ top, n });
    touch(lp[0]);
    if (top)
        memltofrontn(lp[0..n])
    else
        memltorearn(lp[0..n]);
}

/// 'i'
fn opfont() void {
    // a font's image usually starts at the origin
    var im = pick(.plain) orelse return;
    for (0..8) |_| {
        if (im.i.r.min.y >= 0 and im.i.r.max.y < 256 and Dx(im.i.r) > 4)
            break;
        im = pick(.plain) orelse return;
    }
    const ni = between(1, 12);
    tr("i", .{ im.i.r, ni });
    if (im.fchar) |f| ta.free(f);
    im.fchar = ta.alloc(FChar, @intCast(ni)) catch @panic("fuzz: no memory");
    @memset(im.fchar.?, .{});
    im.ascent = if (chance(70)) between(0, 12) else between(0, 255);
}

/// 'l'
fn oploadchar() void {
    const font = pick(.font) orelse return opfont();
    const src = (pick(.any) orelse return).i;
    const ci = rnd.uintLessThan(usize, font.fchar.?.len);
    const r = rect(font.i.r);
    const p = point(src.r);
    tr("l", .{ font.i.r, src.r, ci, r, p });
    touch(font.i);
    touch(src);
    memdraw(font.i, r, src, p, memdraw_h.memopaque, p, draw.S);
    const fc = &font.fchar.?[ci];
    fc.minx = r.min.x;
    fc.maxx = r.max.x;
    fc.miny = @truncate(@as(u32, @bitCast(r.min.y)));
    fc.maxy = @truncate(@as(u32, @bitCast(r.max.y)));
    fc.left = rnd.int(i8);
    fc.width = rnd.int(u8);
}

/// devdraw's drawchar, without the hardware branch
fn drawchar(dst: *Memimage, p_: Point, src: *Memimage, sp: *Point, font: *Img, index: usize, op: i32) Point {
    var p = p_;
    const fc = &font.fchar.?[index];
    var r: Rectangle = undefined;
    r.min.x = p.x +% fc.left;
    r.min.y = p.y -% (font.ascent -% fc.miny);
    r.max.x = r.min.x +% (fc.maxx -% fc.minx);
    r.max.y = r.min.y +% (@as(i32, fc.maxy) - fc.miny);
    const sp1: Point = .{ .x = sp.x +% fc.left, .y = sp.y +% fc.miny };
    memdraw(dst, r, src, sp1, font.i, Pt(fc.minx, fc.miny), op);
    p.x +%= fc.width;
    sp.x +%= fc.width;
    return p;
}

/// 's', 'x'
fn opstring() void {
    const font = pick(.font) orelse return opfont();
    const dst = (pick(.any) orelse return).i;
    const src = (picksrc() orelse return).i;
    const bg = (pick(.any) orelse return).i;
    const p = point(dst.r);
    var r = if (chance(60)) dst.clipr else cliprect(dst.r);
    var sp = point(src.r);
    var q = point(bg.r);
    const nchars = rnd.intRangeAtMost(usize, 1, 6);
    const withbg = chance(40);
    const op = drawop();
    tr("s", .{ dst.r, dst.clipr, src.r, bg.r, font.i.r, p, r, sp, q, nchars, withbg, op });
    touch(dst);
    touch(src);
    touch(bg);
    touch(font.i);
    const clipr = dst.clipr;
    dst.clipr = r;
    defer dst.clipr = clipr;
    var index: [6]usize = undefined;
    for (index[0..nchars]) |*x|
        x.* = rnd.uintLessThan(usize, font.fchar.?.len);
    if (withbg) {
        r.min.x = p.x;
        r.min.y = p.y -% font.ascent;
        r.max.x = p.x;
        r.max.y = r.min.y +% Dy(font.i.r);
        for (index[0..nchars]) |x|
            r.max.x +%= font.fchar.?[x].width;
        memdraw(dst, r, bg, q, memdraw_h.memopaque, ZP, op);
    }
    q = p;
    for (index[0..nchars]) |x|
        q = drawchar(dst, q, src, &sp, font, x, op);
}

/// 'r'
fn opread() void {
    const i = (pick(.any) orelse return).i;
    const r = subrect(i.r);
    tr("r", .{ i.r, i.layer != null, r });
    if (!rectinrect(r, i.r))
        return;
    var c = bytesperline(r, i.depth);
    c *%= Dy(r);
    // devdraw refuses a bad rectangle; now and then see what the
    // library makes of one
    if (badrect(r)) {
        if (chance(50))
            return;
        c = between(0, 64);
    }
    if (c < 0 or c > 1 << 20)
        return;
    const data = ta.alloc(u8, @intCast(c)) catch @panic("fuzz: no memory");
    defer ta.free(data);
    touch(i);
    const n = memunload(i, r, data);
    if (n > c)
        fail("memunload returned {d} for a buffer of {d}", .{ n, c });
}

/// 'y', 'Y'
fn opwrite() void {
    const dst = (pick(.any) orelse return).i;
    const r = subrect(dst.r);
    const compressed = chance(35);
    var n: usize = undefined;
    if (rectinrect(r, dst.r) and !badrect(r) and chance(70)) {
        // about what the rectangle needs
        const need: i64 = @as(i64, bytesperline(r, dst.depth)) * Dy(r);
        n = @intCast(std.math.clamp(need + between(-3, 3), 0, scratch.len));
    } else n = rnd.uintLessThan(usize, 400);
    const a = scratch[0..n];
    rnd.bytes(a);
    if (compressed and chance(60)) {
        // mostly literal runs, so that more than the first line loads
        var k: usize = 0;
        while (k < n) {
            const lit = rnd.intRangeAtMost(usize, 1, 16);
            a[k] = @intCast(0x80 + lit - 1);
            k += lit + 1;
            if (chance(15) and k + 2 <= n) {
                a[k] = rnd.int(u8) & 0x7F;
                k += 2;
            }
        }
    }
    tr("y", .{ dst.r, dst.layer != null, r, compressed, n });
    if (!rectinrect(r, dst.r))
        return;
    touch(dst);
    const y = memload(dst, r, a, compressed);
    if (y > 0 and @as(usize, @intCast(y)) > n)
        fail("memload used {d} bytes of {d}", .{ y, n });
}

fn matrix() Warp {
    var w: Warp = undefined;
    const kind = rnd.uintLessThan(u32, 10);
    for (&w.m, 0..) |*row, a| {
        for (row, 0..) |*v, b| {
            v.* = switch (kind) {
                // about the identity, in the fixed point mkwarp uses
                0, 1, 2, 3 => (if (a == b) @as(i32, 1 << 16) else 0) +% between(-(1 << 15), 1 << 15),
                4 => if (a == b) between(1, 8) << 16 else 0,
                5 => between(-3, 3),
                6 => 0,
                7 => extreme(),
                else => if (chance(wild + 10)) extreme() else rnd.int(i32) >> @intCast(between(0, 31)),
            };
        }
    }
    w.flags = 0;
    return w;
}

/// 'w'
fn opwarp() void {
    const dst = (pick(.any) orelse return).i;
    const src = (pick(.any) orelse return).i;
    const mask = (pickmask() orelse return).i;
    const p = point(dst.r);
    const r = rect(dst.r);
    const sp = point(src.r);
    const q = point(mask.r);
    var w = matrix();
    const value: u32 = rnd.int(u8);
    w.flags = @bitCast(value >> 1);
    const op = drawop();
    tr("w", .{ dst.r, dst.clipr, dst.flags, dst.chan, src.r, src.clipr, src.flags, src.chan, p, r, sp, q, w.m[0], w.m[1], w.m[2], value, op });
    touch(dst);
    touch(src);
    if (dst.layer == null and src.layer == null and chance(30))
        memaffinewarp(dst, p, r, src, sp, mask, q, &w, value & 1 != 0, op)
    else
        memlaffinewarp(dst, p, r, src, sp, mask, q, &w, value & 1 != 0, op);
}

// ---------------------------------------------------------------------
// what only the kernel calls
// ---------------------------------------------------------------------

fn opfill() void {
    const i = (pick(.plain) orelse return).i;
    const v = color();
    tr("memfillcolor", .{ i.r, i.clipr, i.flags, v });
    touch(i);
    memfillcolor(i, v);
}

fn optext() void {
    const b = (pick(.any) orelse return).i;
    const col = (picksrc() orelse return).i;
    const p = point(b.r);
    const cp = point(col.r);
    var s: [12]u8 = undefined;
    const n = rnd.uintLessThan(usize, s.len);
    for (s[0..n]) |*c|
        c.* = if (chance(80)) rnd.intRangeAtMost(u8, ' ', '~') else rnd.int(u8);
    tr("memimagestring", .{ b.r, b.clipr, col.r, p, cp, s[0..n] });
    touch(b);
    touch(col);
    _ = memimagestring(b, p, col, cp, defont, s[0..n]);
    _ = memsubfontwidth(defont, s[0..n]);
}

/// loadmemimage, cloadmemimage and unloadmemimage with any rectangle
fn oprawload() void {
    const i = (pick(.plain) orelse return).i;
    const r = if (chance(50)) subrect(i.r) else rect(i.r);
    const n = rnd.uintLessThan(usize, 600);
    const a = scratch[0..n];
    rnd.bytes(a);
    const which = rnd.uintLessThan(u32, 3);
    tr("load", .{ i.r, r, n, which });
    touch(i);
    const k = switch (which) {
        0 => loadmemimage(i, r, a),
        1 => cloadmemimage(i, r, a),
        else => unloadmemimage(i, r, a),
    };
    if (k > 0 and @as(usize, @intCast(k)) > n)
        fail("load or unload used {d} bytes of {d}", .{ k, n });
}

fn ophelpers() void {
    const i = (pick(.any) orelse return).i;
    const p: Point = .{ .x = if (chance(50)) extreme() else rnd.int(i32), .y = coord(i.r.min.y, i.r.max.y) };
    tr("drawrepl", .{ i.r, p });
    const q = drawrepl(i.r, p);
    if (!badrect(i.r) and !arith.ptinrect(q, i.r))
        fail("drawrepl({any}, {any}) = {any}", .{ i.r, p, q });
    _ = drawreplxy(rnd.int(i32), rnd.int(i32), rnd.int(i32));
    _ = drawreplxy(extreme(), extreme(), extreme());
    var a = rect(i.r);
    const b = cliprect(i.r);
    const before = a;
    if (rectclip(&a, b)) {
        if (!rectinrect(a, b) or !rectinrect(a, before))
            fail("rectclip({any}, {any}) = {any}", .{ before, b, a });
    }
    _ = badrect(before);
    _ = badrect(b);
    _ = arith.rectaddpt(b, p);
    _ = arith.rectsubpt(b, p);
    _ = arith.insetrect(b, p.x);
    _ = arith.addpt(p, q);
    _ = arith.subpt(q, p);
    _ = arith.mulpt(p, p.y);
    _ = arith.canonrect(b);
    _ = arith.rectXrect(a, b);
    _ = Dx(b) +% Dy(b);
}

const Op = struct { f: *const fn () void, weight: u32, name: []const u8 = "" };

const ops = [_]Op{
    .{ .f = opalloc, .weight = 5, .name = "alloc" },
    .{ .f = opwindow, .weight = 4, .name = "window" },
    .{ .f = opscreen, .weight = 1, .name = "screen" },
    .{ .f = opfree, .weight = 4, .name = "free" },
    .{ .f = opclip, .weight = 2, .name = "clip" },
    .{ .f = opdraw, .weight = 24, .name = "draw" },
    .{ .f = opellipse, .weight = 7, .name = "ellipse" },
    .{ .f = opline, .weight = 10, .name = "line" },
    .{ .f = oppoly, .weight = 6, .name = "poly" },
    .{ .f = oporigin, .weight = 5, .name = "origin" },
    .{ .f = optop, .weight = 4, .name = "top" },
    .{ .f = opfont, .weight = 1, .name = "font" },
    .{ .f = oploadchar, .weight = 2, .name = "loadchar" },
    .{ .f = opstring, .weight = 4, .name = "string" },
    .{ .f = opread, .weight = 4, .name = "read" },
    .{ .f = opwrite, .weight = 5, .name = "write" },
    .{ .f = opwarp, .weight = 6, .name = "warp" },
    .{ .f = opfill, .weight = 1, .name = "fill" },
    .{ .f = optext, .weight = 2, .name = "text" },
    .{ .f = oprawload, .weight = 2, .name = "rawload" },
    .{ .f = ophelpers, .weight = 1, .name = "helpers" },
};

fn env(name: []const u8, default: u64) u64 {
    const v = std.testing.environ.getPosix(name) orelse return default;
    return std.fmt.parseInt(u64, v, 0) catch default;
}

fn now() u64 {
    if (builtin.os.tag != .linux)
        return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

fn run(seed: u64, n: usize, slow: u64) void {
    const T = mline.testing;
    T.init();
    defer T.deinit();
    defont = getmemdefont().?;
    defer freememsubfont(defont);
    const fillpoly = @import("fillpoly.zig");
    fillpoly.loud = false;
    defer fillpoly.loud = true;

    prng = std.Random.DefaultPrng.init(seed);
    rnd = prng.random();
    var total: u32 = 0;
    for (ops) |o| total += o.weight;

    // a client starts with something to draw on
    wild = 0;
    tidy = true;
    opno = 0;
    {
        const bigclip: Rectangle = Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF);
        const o = allocmemimage(Rect(0, 0, 1, 1), draw.GREY1).?;
        o.flags |= Frepl;
        o.clipr = bigclip;
        memfillcolor(o, draw.DWhite);
        dopaque = install(o, null).?;
        dopaque.fixed = true;
        const c = allocmemimage(Rect(0, 0, 1, 1), draw.RGBA32).?;
        c.flags |= Frepl;
        c.clipr = bigclip;
        memfillcolor(c, 0x3060C0FF);
        colour = install(c, null).?;
        colour.fixed = true;
    }
    for (0..12) |_| opalloc();
    opscreen();
    for (0..3) |_| opwindow();
    _ = check();
    var calls: [ops.len]u32 = @splat(0);
    var effects: [ops.len]u32 = @splat(0);

    opno = 1;
    while (opno <= n) : (opno += 1) {
        wild = switch (rnd.uintLessThan(u32, 10)) {
            0, 1, 2, 3, 4 => 0,
            5, 6, 7 => 8,
            8 => 30,
            else => 70,
        };
        tidy = wild == 0 and chance(70);
        var k = rnd.uintLessThan(u32, total);
        var f: *const fn () void = undefined;
        var which: usize = 0;
        for (ops, 0..) |o, x| {
            if (k < o.weight) {
                f = o.f;
                which = x;
                break;
            }
            k -= o.weight;
        }
        const t0 = if (slow != 0) now() else 0;
        f();
        if (slow != 0) {
            const dt = now() - t0;
            if (dt > slow)
                std.debug.print("fuzz: seed {d} call {d} took {d} usec\n", .{ seed, opno, dt });
        }
        calls[which] += 1;
        if (check())
            effects[which] += 1;
    }
    if (stats) {
        var np: u32 = 0;
        var nw: u32 = 0;
        var nf: u32 = 0;
        var ns: u32 = 0;
        for (imgs) |ip| {
            const im = ip orelse continue;
            if (im.i.layer != null) nw += 1 else np += 1;
            if (im.fchar != null) nf += 1;
        }
        for (scrs) |sp| {
            if (sp != null) ns += 1;
        }
        std.debug.print("fuzz: at the end {d} images, {d} windows, {d} fonts, {d} screens\n", .{ np, nw, nf, ns });
        for (ops, 0..) |o, x|
            std.debug.print("fuzz: {s}: {d} calls, {d} changed pixels\n", .{ o.name, calls[x], effects[x] });
    }

    // drawclose: the screens, then the images
    for (scrs) |sp| {
        const s = sp orelse continue;
        if (s.held) {
            s.held = false;
            freedscreen(s);
        }
    }
    for (0..Nimg) |k| {
        const im = imgs[k] orelse continue;
        if (im.held) {
            im.held = false;
            freedimage(im);
        }
    }
    for (imgs) |ip| {
        if (ip != null) @panic("fuzz: an image outlived its client");
    }
    for (scrs) |sp| {
        if (sp != null) @panic("fuzz: a screen outlived its client");
    }
    if (!kernel.checkguards())
        @panic("fuzz: something wrote outside its memory");
}

test "fuzz: what a draw client can make the libraries do" {
    const n: usize = @intCast(env("FUZZ_ITERS", iterations));
    const first = env("FUZZ_SEED", seed0);
    const seeds = env("FUZZ_SEEDS", 1);
    const slow = env("FUZZ_SLOW", 0);
    trace = env("FUZZ_TRACE", 0) != 0;
    big = env("FUZZ_BIG", 0) != 0;
    stats = env("FUZZ_STATS", 0) != 0;
    if (env("FUZZ_PAGEGUARD", 0) != 0)
        kernel.setpageguard(true);
    defer kernel.setpageguard(false);
    var s: u64 = 0;
    while (s < seeds) : (s += 1) {
        if (seeds > 1)
            std.debug.print("fuzz: seed {d}\n", .{first + s});
        run(first + s, n, slow);
        try std.testing.expectEqual(@as(usize, 0), kernel.livecount());
    }
}

// The cases the fuzz found, one call each, so that they stay found.
// Most of them are bugs of the C libraries; the files named say more
// in their DIFF paragraphs.
test "fuzz: the cases it found" {
    const T = mline.testing;
    const t = std.testing;
    const pixelbits = mdraw.pixelbits;
    const huge = Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF);
    T.init();
    defer T.deinit();

    const white = T.col(draw.DWhite);
    defer freememimage(white);
    const d = T.mk(Rect(0, 0, 40, 30), draw.XRGB32, draw.DBlack);
    defer freememimage(d);
    const s = T.tex(Rect(0, 0, 16, 12), draw.RGB24);
    defer freememimage(s);
    const before = T.hash(d);
    const ident: Warp = .{ .m = .{ .{ 1 << 13, 0, 0 }, .{ 0, 1 << 13, 0 }, .{ 0, 0, 1 << 13 } }, .flags = 0 };
    const zero: Warp = .{ .m = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } }, .flags = draw.WFintupscale };

    // warp.zig: a clipr that misses the image; an inverted rectangle
    // with integer upscaling; an empty source
    d.clipr = Rect(100, 100, 140, 130);
    memaffinewarp(d, ZP, Rect(90, 90, 150, 150), s, ZP, null, ZP, &ident, false, draw.S);
    d.clipr = d.r;
    memaffinewarp(d, ZP, Rect(6, 0, 5, 30), s, ZP, null, ZP, &zero, false, draw.S);
    s.flags |= Frepl;
    s.clipr = Rect(3, 3, 3, 9);
    memaffinewarp(d, ZP, d.r, s, ZP, null, ZP, &ident, false, draw.S);
    s.clipr = Rect(5, 3, 3, 9);
    memaffinewarp(d, ZP, d.r, s, ZP, null, ZP, &ident, true, draw.S);
    s.flags &= ~Frepl;
    s.clipr = s.r;
    try t.expect(kernel.checkguards());
    try t.expectEqual(before, T.hash(d));

    // draw.zig: an inverted clipr inside the rectangle, on the mask,
    // the source and the destination
    const m = T.mk(Rect(0, 0, 1, 1), draw.GREY8, draw.DWhite);
    defer freememimage(m);
    m.flags |= Frepl;
    m.clipr = Rect(6, 7, 5, 8);
    memimagedraw(d, d.r, s, ZP, m, Pt(1, 1), draw.SoverD);
    m.clipr = Rect(6, 7, 6, 9);
    memimagedraw(d, d.r, s, ZP, m, Pt(1, 1), draw.SoverD);
    m.clipr = huge;
    s.clipr = Rect(8, 2, 4, 9);
    memimagedraw(d, d.r, s, ZP, m, ZP, draw.S);
    s.clipr = s.r;
    d.clipr = Rect(20, 20, 10, 10);
    memimagedraw(d, d.r, white, ZP, m, ZP, draw.S);
    memline(d, Pt(0, 0), Pt(39, 29), draw.Enddisc, draw.Endarrow, 2, white, ZP, draw.SoverD);
    d.clipr = d.r;
    try t.expect(kernel.checkguards());
    try t.expectEqual(before, T.hash(d));

    // extreme points that are fine: the sums wrap
    white.clipr = Rect(minInt, minInt, maxInt, maxInt);
    m.clipr = white.clipr;
    memimagedraw(d, Rect(-5, -5, 3, 3), white, Pt(maxInt, maxInt), m, Pt(minInt, maxInt), draw.S);
    m.clipr = huge;
    try t.expectEqual(@as(u32, 0xFFFFFF), pixelbits(d, Pt(2, 2)) & 0xFFFFFF);
    try t.expectEqual(@as(u32, 0), pixelbits(d, Pt(3, 3)) & 0xFFFFFF);
    memfillcolor(d, draw.DBlack);
    _ = bytesperline(Rect(0, 0, minInt, minInt), 32);
    try t.expectEqual(@as(i32, 7), drawreplxy(7, 7, 100));
    _ = drawreplxy(0, -1, minInt);
    _ = drawrepl(Rect(maxInt, 0, minInt, 5), Pt(3, minInt));
    _ = arith.rectaddpt(huge, Pt(maxInt, minInt));
    _ = Dx(Rect(maxInt, 0, minInt, 0));

    // ellipse.zig, arc.zig, fillpoly.zig: loops as long as the numbers
    memellipse(d, Pt(20, 15), (1 << 30) - 1, 6, 0, white, ZP, draw.SoverD);
    memellipse(d, Pt(20, 15), 3, 46000, 400, white, ZP, draw.SoverD);
    memarc(d, Pt(20, 15), 1 << 23, 60, 2, white, ZP, 10, 100, draw.SoverD);
    try t.expectEqual(before, T.hash(d));
    // (the scan converter may complain about the overflowing ones)
    @import("fillpoly.zig").loud = false;
    defer @import("fillpoly.zig").loud = true;
    d.clipr = Rect(minInt, minInt, maxInt, maxInt);
    memfillpoly(d, &.{ Pt(5, minInt + 5), Pt(1 << 30, 100), Pt(-(1 << 30), (1 << 30) - 1) }, -1, white, ZP, draw.S);
    d.clipr = huge;
    memfillpoly(d, &.{ Pt(5, -(1 << 29)), Pt(1 << 29, 100), Pt(-(1 << 29), 1 << 29) }, 1, white, ZP, draw.S);
    d.clipr = d.r;
    memfillcolor(d, draw.DBlack);

    // alloc.zig: Memimage.zero would not fit
    try t.expect(allocmemimage(Rect((1 << 25) - 3, (1 << 28) - 2, (1 << 25) - 2, (1 << 28) - 1), draw.RGB24) == null);
    const far = allocmemimage(Rect((1 << 25) - 3, (1 << 28) - 2, (1 << 25) - 2, (1 << 28) - 1), draw.GREY8).?;
    memfillcolor(far, draw.DWhite);
    memimagedraw(far, far.r, s, ZP, null, ZP, draw.S);
    freememimage(far);

    // draw.zig: a colour-mapped format with 3 bytes to the pixel,
    // replicated (with FUZZ_PAGEGUARD-style pages this read ran off
    // the image)
    const odd = T.mk(Rect(0, 0, 3, 1), CHAN3(CMap, 8, CAlpha, 8, CIgnore, 8), draw.DRed);
    defer freememimage(odd);
    odd.flags |= Frepl;
    odd.clipr = huge;
    memimagedraw(d, d.r, odd, ZP, null, ZP, draw.SoverD);
    try t.expectEqual(pixelbits(d, Pt(0, 0)), pixelbits(d, Pt(39, 29)));
    try t.expect(pixelbits(d, Pt(0, 0)) & 0xFFFFFF != 0);

    // alloc.zig's memsetchan and lalloc.zig's paint: after a window on
    // a colour-mapped screen, the colour of a window on another
    const fill = T.col(0x777777FF);
    defer freememimage(fill);
    const cm = T.mk(Rect(0, 0, 20, 20), draw.CMAP8, draw.DBlack);
    defer freememimage(cm);
    var cscr: Memscreen = .{ .frontmost = null, .rearmost = null, .image = cm, .fill = fill };
    const cw = memlalloc(&cscr, Rect(2, 2, 10, 10), null, null, draw.DGreen).?;
    var scr: Memscreen = .{ .frontmost = null, .rearmost = null, .image = d, .fill = fill };
    // (a screen and a colour with alpha, so that paint is read a pixel
    // at a time and not just memset)
    const da = T.mk(Rect(0, 0, 20, 20), draw.RGBA32, draw.DBlack);
    defer freememimage(da);
    var ascr: Memscreen = .{ .frontmost = null, .rearmost = null, .image = da, .fill = fill };
    const aw = memlalloc(&ascr, Rect(2, 2, 10, 10), null, null, 0x80402080).?;
    try t.expectEqual(@as(u32, 0x80402080), pixelbits(da, Pt(3, 3)));
    memldelete(aw);
    const a = memlalloc(&scr, Rect(5, 5, 25, 20), null, null, draw.DRed).?;
    try t.expectEqual(@as(u32, 0xFF0000), pixelbits(d, Pt(6, 6)) & 0xFFFFFF);
    const b = memlalloc(&scr, Rect(15, 10, 35, 28), &memlnorefresh, null, draw.DBlue).?;
    const c = memlalloc(&scr, Rect(0, 0, 12, 12), null, null, draw.DWhite).?;
    try t.expectEqual(@as(u32, 0x0000FF), pixelbits(d, Pt(20, 15)) & 0xFFFFFF);

    // ltofront.zig, ltorear.zig: the same window twice
    memltofrontn(&.{ a, a });
    memltofrontn(&.{ a, b, a, c, b });
    memltorearn(&.{ b, b });
    memltorearn(&.{ c, a, c, b, a });
    var n: usize = 0;
    var w = scr.frontmost;
    while (w) |x| : (w = x.layer.?.rear) {
        try t.expect(x.layer.?.rear != null or scr.rearmost == x);
        n += 1;
    }
    try t.expectEqual(@as(usize, 3), n);

    // lorigin.zig: origins that would wrap, with and without a save
    // area
    try t.expectEqual(@as(i32, -1), memlorigin(b, b.r.min, Pt(maxInt - 3, 5)));
    try t.expectEqual(@as(i32, -1), memlorigin(b, Pt(maxInt - 3, minInt), b.layer.?.screenr.min));
    try t.expectEqual(@as(i32, -1), memlorigin(a, Pt(1 << 30, 0), Pt(0, 0)));
    try t.expectEqual(@as(i32, 1), memlorigin(b, Pt(-1000, 1 << 20), Pt(30, 20)));
    memline(b, Pt(-1000, 1 << 20), Pt(-990, (1 << 20) + 9), draw.Endsquare, draw.Endsquare, 1, white, ZP, draw.SoverD);

    // unload through a window with a rectangle only rectinrect likes
    var buf: [64]u8 = undefined;
    try t.expectEqual(@as(i32, -1), memunload(a, Rect(6, 6, minInt, minInt), &buf));
    try t.expectEqual(@as(i32, -1), memload(a, Rect(6, 6, 5, 9), &buf, false));

    memldelete(a);
    memldelete(b);
    memldelete(c);
    memldelete(cw);
    try t.expect(kernel.checkguards());
}
