//! drawtest - draw the same scenes with planZ's libdraw as tools/drawtest.c
//! does with 9front's, off the screen, and print what each call returned
//! and a hash of the pixels.  See tools/drawtest.c, whose output this
//! must match line for line.
//!
//! usage: drawtest [tmpdir]
//!
//! Not part of 9front.

const std = @import("std");
const libc = @import("libc");
const D = @import("draw");
const Image = D.Image;
const Rectangle = D.Rectangle;
const Font = D.Font;
const Rect = D.Rect;
const Pt = D.Pt;
const ZP = D.ZP;

var d: *D.Display = undefined;
var tmp: []const u8 = "/tmp";

/// FNV-1a
fn hash(p: []const u8) u32 {
    var h: u32 = 2166136261;
    for (p) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

fn b2i(b: bool) i32 {
    return @intFromBool(b);
}

/// the image's rectangle, channels and pixels, a hash every 16 rows
fn dump(label: []const u8, i: *Image) void {
    var cbuf: [20]u8 = undefined;
    const bpl: usize = @intCast(D.bytesperline(i.r, i.depth));
    const n = bpl * @as(usize, @intCast(D.Dy(i.r)));
    const buf = libc.allocator.alloc(u8, n) catch libc.sysfatal("malloc: %r", .{});
    defer libc.allocator.free(buf);
    const got = D.unloadimage(i, i.r, buf) catch 0;
    if (got != n)
        libc.print("%s: unloadimage: %r\n", .{label});
    libc.print("%s %R %s %d repl %d clipr %R:", .{ label, i.r, D.chantostr(&cbuf, i.chan).?, i.depth, b2i(i.repl), i.clipr });
    var y: usize = 0;
    const dyr: usize = @intCast(D.Dy(i.r));
    while (y < dyr) : (y += 16) {
        const dy = @min(dyr - y, 16);
        libc.print(" %08ux", .{hash(buf[y * bpl ..][0 .. dy * bpl])});
    }
    libc.print("\n", .{});
}

fn col(c: u32) *Image {
    return D.allocimage(d, Rect(0, 0, 1, 1), D.RGB24, true, c) catch libc.sysfatal("allocimage: %r", .{});
}

fn alloc(r: Rectangle, chan: u32, repl: bool, c: u32) *Image {
    return D.allocimage(d, r, chan, repl, c) catch libc.sysfatal("allocimage %R: %r", .{r});
}

fn free(i: ?*Image) void {
    D.freeimage(i) catch {};
}

/// loadimage's count, or -1 as the C's
fn loaded(r: D.Error!usize) i64 {
    return if (r) |n| @intCast(n) else |_| -1;
}

// allocimage, draw, the ops, masks, replicated and clipped sources
fn drawing() void {
    var ramp: [64 * 16]u8 = undefined;

    libc.print("display image %d white %d black %d opaque %d transparent %d new %d\n", .{
        b2i(d.image != null), d.white.id,                     d.black.id,
        b2i(d.@"opaque" == d.white), b2i(d.transparent == d.black), b2i(d._isnewdisplay),
    });
    const c = alloc(Rect(0, 0, 240, 160), D.RGB24, false, D.DWhite);
    libc.print("canvas id %d depth %d\n", .{ c.id, c.depth });
    const red = col(D.DRed);
    const blue = col(D.DBlue);
    const grn = col(0x22AA44FF);
    D.draw(c, Rect(10, 10, 100, 60), red, null, ZP);
    D.drawop(c, Rect(50, 30, 150, 90), blue, null, ZP, D.SxorD);
    D.drawop(c, Rect(120, 20, 200, 120), grn, null, ZP, D.DoverS);

    // a GREY8 ramp as an alpha mask, and a GREY1 checkerboard
    const m8 = alloc(Rect(0, 0, 64, 16), D.GREY8, false, D.DBlack);
    for (0..16) |y|
        for (0..64) |x| {
            ramp[y * 64 + x] = @truncate(x * 4 + y);
        };
    libc.print("loadimage %d\n", .{loaded(D.loadimage(m8, m8.r, &ramp))});
    D.draw(c, Rect(20, 100, 84, 116), blue, m8, ZP);
    D.gendraw(c, Rect(90, 100, 154, 116), red, ZP, m8, Pt(8, 2));
    const m1 = alloc(Rect(0, 0, 8, 8), D.GREY1, true, D.DBlack);
    for (0..8) |y|
        ramp[y] = if (y & 1 != 0) 0xAA else 0x55;
    libc.print("loadimage %d\n", .{loaded(D.loadimage(m1, Rect(0, 0, 8, 8), ramp[0..8]))});
    D.draw(c, Rect(160, 100, 230, 150), grn, m1, ZP);
    D.gendrawop(c, Rect(5, 130, 75, 155), red, ZP, m1, Pt(3, 1), D.S);

    // a tile replicated through a clip rectangle
    const tile = alloc(Rect(0, 0, 4, 4), D.RGB24, true, D.DYellow);
    D.draw(tile, Rect(0, 0, 2, 2), blue, null, ZP);
    D.replclipr(tile, true, Rect(-100, -100, 100, 100));
    libc.print("tile repl %d clipr %R\n", .{ b2i(tile.repl), tile.clipr });
    D.replclipr(c, false, Rect(100, 120, 140, 160));
    D.draw(c, c.r, tile, null, ZP);
    D.replclipr(c, false, c.r);

    // errors: devdraw's, and libdraw's own
    if (D.allocimage(d, Rect(10, 10, 0, 0), D.RGB24, false, D.DWhite)) |_| {} else |_|
        libc.print("bad rect: %r\n", .{});
    if (D.allocimage(d, Rect(0, 0, 1, 1), 0, false, D.DWhite)) |_| {} else |_|
        libc.print("bad chan: %r\n", .{});
    if (D.allocimage(d, Rect(0, 0, 1, 1), D.CHAN1(D.CRed, 3), false, D.DWhite)) |_| {} else |_|
        libc.print("bad depth: %r\n", .{});

    D.flushimage(d, false) catch {};
    dump("drawing", c);
    dump("ramp", m8);
    dump("check", m1);
    free(m8);
    free(m1);
    free(tile);
    free(c);
    free(red);
    free(blue);
    free(grn);
}

// loadimage and unloadimage longer than the buffer, and rows wider
fn loading() void {
    const a = libc.allocator;
    libc.print("bufsize %d\n", .{d.bufsize});
    // a row longer than the buffer: loaded and read in pieces
    var w = alloc(Rect(0, 0, 22001, 2), D.RGB24, false, D.DBlack);
    var n: usize = @intCast(D.bytesperline(w.r, w.depth) * D.Dy(w.r));
    var b = a.alloc(u8, n) catch unreachable;
    const u = a.alloc(u8, n) catch unreachable;
    for (b, 0..) |*p, i|
        p.* = @truncate(i *% 7 +% (i >> 8));
    libc.print("wide load %d\n", .{loaded(D.loadimage(w, w.r, b))});
    libc.print("wide unload %d\n", .{loaded(D.unloadimage(w, w.r, u))});
    libc.print("same %d\n", .{b2i(std.mem.eql(u8, b, u))});
    libc.print("short load %d", .{loaded(D.loadimage(w, w.r, b[0 .. n - 1]))});
    libc.print(" %r\n", .{});
    libc.print("outside %d", .{loaded(D.loadimage(w, Rect(0, 0, 22002, 1), b))});
    libc.print(" %r\n", .{});
    dump("wide", w);
    free(w);
    a.free(b);
    a.free(u);

    w = alloc(Rect(-5, 7, 395, 107), D.XRGB32, false, D.DBlack);
    n = @intCast(D.bytesperline(w.r, w.depth) * D.Dy(w.r));
    b = a.alloc(u8, n) catch unreachable;
    for (b, 0..) |*p, i|
        p.* = @truncate(i ^ (i >> 9));
    libc.print("tall load %d\n", .{loaded(D.loadimage(w, w.r, b))});
    dump("tall", w);
    free(w);
    a.free(b);
}

fn readback(label: []const u8, path: []const u8) void {
    const fd = libc.open(path, libc.OREAD) catch -1;
    const r = D.readimage(d, fd);
    libc.close(fd) catch {};
    if (r) |i| {
        dump(label, i);
        free(i);
    } else |_| libc.print("readimage %s: %r\n", .{label});
}

// image files: as written by hand here, in both formats, read back
fn files() void {
    var pbuf: [128]u8 = undefined;
    var cbuf: [20]u8 = undefined;
    const a = libc.allocator;

    const i = alloc(Rect(3, 4, 43, 24), D.CMAP8, false, D.DWhite);
    const bpl: usize = @intCast(D.bytesperline(i.r, i.depth));
    const n = bpl * @as(usize, @intCast(D.Dy(i.r)));
    const b = a.alloc(u8, n) catch unreachable;
    defer a.free(b);
    for (b, 0..) |*p, k|
        p.* = @truncate(k *% 13);
    _ = D.loadimage(i, i.r, b) catch {};

    var path = libc.sprint(&pbuf, "%s/drawtest.new", .{tmp});
    var fd = libc.create(path, libc.OWRITE, 0o666) catch libc.sysfatal("create %s: %r", .{path});
    libc.fprint(fd, "%11s %11d %11d %11d %11d ", .{ D.chantostr(&cbuf, i.chan).?, i.r.min.x, i.r.min.y, i.r.max.x, i.r.max.y });
    _ = libc.write(fd, b) catch {};
    libc.close(fd) catch {};
    readback("new", path);

    // the old format: ldepth 3, the bits inverted
    path = libc.sprint(&pbuf, "%s/drawtest.old", .{tmp});
    fd = libc.create(path, libc.OWRITE, 0o666) catch -1;
    libc.fprint(fd, "%11d %11d %11d %11d %11d ", .{ 3, i.r.min.x, i.r.min.y, i.r.max.x, i.r.max.y });
    for (b) |*p|
        p.* ^= 0xFF;
    _ = libc.write(fd, b) catch {};
    libc.close(fd) catch {};
    readback("old", path);
    libc.remove(path) catch {};
    path = libc.sprint(&pbuf, "%s/drawtest.new", .{tmp});
    libc.remove(path) catch {};

    // a bad header
    path = libc.sprint(&pbuf, "%s/drawtest.bad", .{tmp});
    fd = libc.create(path, libc.ORDWR, 0o666) catch -1;
    libc.fprint(fd, "%11s %11d %11d %11d %11d ", .{ "q9", 0, 0, 1, 1 });
    _ = libc.seek(fd, 0, 0) catch {};
    if (D.readimage(d, fd)) |_| {} else |_|
        libc.print("readimage bad: %r\n", .{});
    libc.close(fd) catch {};
    libc.remove(path) catch {};
    free(i);
}

// a screen on an image of its own, windows on it
fn windows() void {
    var w: [4]*Image = undefined;
    const cols = [4]u32{ D.DRed, D.DGreen, D.DBlue, D.DPaleyellow };

    const base = alloc(Rect(0, 0, 200, 150), D.RGB24, false, D.DBlack);
    const fill = col(D.DPalebluegreen);
    d.screenimage = base;
    const s = D.allocscreen(base, fill, false) catch libc.sysfatal("allocscreen: %r", .{});
    libc.print("screen image %d fill %d\n", .{ b2i(s.image == base), b2i(s.fill == fill) });
    for (0..4) |k| {
        const i: i32 = @intCast(k);
        w[k] = D.allocwindow(s, Rect(10 + 30 * i, 10 + 20 * i, 110 + 30 * i, 90 + 20 * i), D.Refbackup, cols[k]) catch
            libc.sysfatal("allocwindow: %r", .{});
        libc.print("window %d %R screen %d\n", .{ w[k].id, w[k].r, b2i(w[k].screen == s) });
    }
    libc.print("windows list %d %d %d %d %d\n", .{
        b2i(d.windows == w[3]), b2i(w[3].next == w[2]),
        b2i(w[2].next == w[1]), b2i(w[1].next == w[0]), b2i(w[0].next == null),
    });
    const c = col(D.DWhite);
    D.draw(w[1], Rect(20, 40, 200, 60), c, null, ZP);
    libc.print("flush visible %d\n", .{@as(i32, if (D.flushimage(d, true)) |_| 1 else |_| -1)});
    dump("stacked", base);
    D.topwindow(w[0]);
    D.bottomwindow(w[3]);
    dump("top0bottom3", base);
    D.topnwindows(w[1..3]);
    dump("topn", base);
    D.bottomnwindows(w[0..2]);
    dump("bottomn", base);
    libc.print("origin %d", .{b2i(if (D.originwindow(w[2], Pt(0, 0), Pt(5, 60))) |_| true else |_| false)});
    libc.print(" %R %R\n", .{ w[2].r, w[2].clipr });
    D.draw(w[2], Rect(0, 0, 30, 30), c, null, ZP);
    dump("origin", base);
    free(w[1]);
    libc.print("windows list %d %d %d\n", .{ b2i(d.windows == w[3]), b2i(w[3].next == w[2]), b2i(w[2].next == w[0]) });
    dump("freed", base);
    for (0..4) |k|
        if (k != 1)
            free(w[k]);
    dump("empty", base);
    libc.print("freescreen %d\n", .{@as(i32, if (D.freescreen(s)) |_| 1 else |_| -1)});
    d.screenimage = null;
    free(c);
    free(fill);
    free(base);
}

// naming an image and looking it up by name
fn names() void {
    var nbuf: [64]u8 = undefined;

    const i = alloc(Rect(1, 2, 31, 22), D.GREY8, false, 0x808080FF);
    D.replclipr(i, false, Rect(5, 5, 25, 15));
    const name = libc.sprint(&nbuf, "drawtest.%d", .{libc.getpid()});
    libc.print("nameimage %d\n", .{b2i(if (D.nameimage(i, name, true)) |_| true else |_| false)});
    if (D.namedimage(d, name)) |n| {
        libc.print("named %R %R %d %d\n", .{ n.r, n.clipr, n.depth, b2i(n.repl) });
        dump("named", n);
        free(n);
    } else |_| libc.print("namedimage: %r\n", .{});
    libc.print("unname %d\n", .{b2i(if (D.nameimage(i, name, false)) |_| true else |_| false)});
    if (D.namedimage(d, name)) |_| {} else |_|
        libc.print("gone: %r\n", .{});
    if (D.namedimage(d, "")) |_| {} else |_|
        libc.print("empty: %r\n", .{});
    free(i);
}

fn text(c: *Image, f: *Font, label: []const u8) void {
    const r = [_]D.Rune{ 'R', 'u', 'n', 'e', 's', ' ', 0x3B1, 0x3B2, 0x263A };
    var long1: [299]u8 = undefined;

    const ink = col(D.DBlack);
    const bg = col(D.DPaleyellow);
    libc.print("%s height %d ascent %d\n", .{ label, f.height, f.ascent });
    var p = D.string(c, Pt(2, 2), ink, ZP, f, "Hello, world");
    libc.print("string %P\n", .{p});
    p = D.stringn(c, Pt(2, 2 + f.height), ink, ZP, f, "stringn cut here", 7);
    libc.print("stringn %P\n", .{p});
    p = D.runestring(c, Pt(2, 2 + 2 * @as(i32, f.height)), ink, ZP, f, &r);
    libc.print("runestring %P\n", .{p});
    p = D.stringbg(c, Pt(2, 2 + 3 * @as(i32, f.height)), ink, ZP, f, "on a background", bg, ZP);
    libc.print("stringbg %P\n", .{p});
    p = D.stringop(c, Pt(2, 2 + 4 * @as(i32, f.height)), ink, ZP, f, "with S", D.S);
    libc.print("stringop %P\n", .{p});
    p = D.string(c, Pt(2, 2 + 5 * @as(i32, f.height)), ink, ZP, f, "Ünïcödé — αβγ кот ─┼─ ☺ ");
    libc.print("unicode %P\n", .{p});
    libc.print("widths %d %d %d %d\n", .{
        D.stringwidth(f, "Hello, world"), D.stringnwidth(f, "Hello", 3),
        D.runestringwidth(f, &r),         D.runestringnwidth(f, &r, 7),
    });
    p = D.stringsize(f, "size");
    libc.print("stringsize %P\n", .{p});
    // more than the cache holds, and longer than one message
    for (&long1, 0..) |*ch, i|
        ch.* = @intCast(33 + (i * 7) % 94);
    p = D.string(c, Pt(2, 2 + 6 * @as(i32, f.height)), ink, ZP, f, &long1);
    libc.print("long %P width %d\n", .{ p, D.stringwidth(f, &long1) });
    libc.print("cache %d subf %d width %d\n", .{ f.cache.len, f.subf.len, f.width });
    free(ink);
    free(bg);
}

// the built-in font, as initdraw makes it
fn deffont() void {
    var buf: [128]u8 = undefined;

    const df = D.getdefont(d) catch libc.sysfatal("getdefont: %r", .{});
    d.defaultsubfont = df;
    libc.print("defont n %d height %d ascent %d bits %R\n", .{ df.n, df.height, df.ascent, df.bits.r });
    const s = libc.sprint(&buf, "%d %d\n0 %d\t%s\n", .{ df.height, df.ascent, df.n - 1, "*default*" });
    const f = D.buildfont(d, s, "*default*") catch libc.sysfatal("buildfont: %r", .{});
    d.defaultfont = f;
    const c = alloc(Rect(0, 0, 400, 140), D.GREY8, false, D.DWhite);
    text(c, f, "default");
    dump("deftext", c);
    free(c);
}

// a font from files: several subfonts, compressed images
fn filefont() void {
    var r: [300]D.Rune = undefined;

    var f = D.openfont(d, "/lib/font/bit/vga/unicode.font") catch libc.sysfatal("openfont: %r", .{});
    libc.print("vga nsub %d\n", .{f.sub.len});
    const c = alloc(Rect(0, 0, 600, 160), D.RGB24, false, D.DWhite);
    text(c, f, "vga");

    // runes from many subfonts in turn: the subfont list grows
    var n: usize = 0;
    for (0..60) |k| {
        const i: D.Rune = @intCast(k);
        r[n] = 0x41 + i % 26;
        r[n + 1] = 0x3B1 + i % 20;
        r[n + 2] = 0x430 + i % 30;
        r[n + 3] = 0x2500 + i % 40;
        r[n + 4] = 0x2190 + i % 8;
        n += 5;
    }
    libc.print("mixed width %d\n", .{D.runestringwidth(f, r[0..n])});
    _ = D.runestring(c, Pt(0, 130), d.black, ZP, f, r[0..n]);
    libc.print("cache %d subf %d width %d\n", .{ f.cache.len, f.subf.len, f.width });
    dump("vgatext", c);

    // the ages renormalised at 65536: old subfonts are freed
    for (0..70000) |_|
        _ = D.stringwidth(f, "A");
    libc.print("aged %ud cache %d subf %d\n", .{ f.age, f.cache.len, f.subf.len });
    n = 0;
    for (0..20) |k| {
        const i: D.Rune = @intCast(k);
        r[n] = 0x5D0 + i % 27;
        r[n + 1] = 0x391 + i % 17;
        r[n + 2] = 0x2200 + i % 30;
        n += 3;
    }
    D.draw(c, c.r, d.white, null, ZP);
    const p = D.runestring(c, Pt(0, 0), d.black, ZP, f, r[0..n]);
    libc.print("after age %P %ud cache %d subf %d\n", .{ p, f.age, f.cache.len, f.subf.len });
    for (f.subf) |sf|
        libc.print(" %ud", .{sf.age});
    libc.print("\n", .{});
    dump("agedtext", c);
    free(c);
    D.freefont(f);

    // a subfont taller above the baseline than its font
    f = D.buildfont(d, "16 10\n0 0x7f /lib/font/bit/vga/vga.0000-007F\n", "asc") catch libc.sysfatal("buildfont: %r", .{});
    const c2 = alloc(Rect(0, 0, 200, 20), D.GREY8, false, D.DWhite);
    const p2 = D.string(c2, Pt(1, 1), d.black, ZP, f, "Ascent gjpqy|");
    libc.print("ascent %P %d %d\n", .{ p2, f.height, f.ascent });
    dump("asctext", c2);
    free(c2);
    D.freefont(f);

    if (D.openfont(d, "/nonexistent.font")) |_| {} else |_|
        libc.print("openfont: %r\n", .{});
    if (D.buildfont(d, "x y\n", "bad")) |_| {} else |_|
        libc.print("buildfont: %r\n", .{});
    if (D.buildfont(d, "10 8\n5 3 a\n", "bad")) |_| {} else |_|
        libc.print("buildfont: %r\n", .{});
    f = D.buildfont(d, "10 8\n0x20 0x7e 0 sub\n0x100 0x17f 0x20 other\n", "/x/y.font") catch {
        libc.print("buildfont: %r\n", .{});
        return;
    };
    libc.print("built %d %d nsub %d", .{ f.height, f.ascent, f.sub.len });
    for (f.sub) |s|
        libc.print(" [%ud %ud %d %s]", .{ s.min, s.max, s.offset, s.name });
    libc.print("\n", .{});
    D.freefont(f);
}

pub fn main() void {
    if (libc.argv.len > 1)
        tmp = libc.argv[1];
    d = D.initdisplay(null, null, null) catch libc.sysfatal("initdisplay: %r", .{});
    drawing();
    loading();
    files();
    windows();
    names();
    deffont();
    filefont();
    libc.print("done\n", .{});
    libc.exits(null);
}

// Every function of the library is compiled, used here or not.
comptime {
    _ = &D.geninitdraw;
    _ = &D.initdraw;
    _ = &D.gengetwindow;
    _ = &D.getwindow;
    _ = &D.initdisplay;
    _ = &D.closedisplay;
    _ = &D.drawerror;
    _ = &D.flushimage;
    _ = &D.bufimage;
    _ = &D._bufimageop;
    _ = &D.allocimage;
    _ = &D._allocimage;
    _ = &D.namedimage;
    _ = &D.nameimage;
    _ = &D._freeimage1;
    _ = &D.freeimage;
    _ = &D.draw;
    _ = &D.drawop;
    _ = &D.gendraw;
    _ = &D.gendrawop;
    _ = &D.replclipr;
    _ = &D.loadimage;
    _ = &D.unloadimage;
    _ = &D.readimage;
    _ = &D.creadimage;
    _ = &D.allocscreen;
    _ = &D.publicscreen;
    _ = &D.freescreen;
    _ = &D.allocwindow;
    _ = &D._allocwindow;
    _ = &D.bottomwindow;
    _ = &D.topwindow;
    _ = &D.bottomnwindows;
    _ = &D.topnwindows;
    _ = &D.originwindow;
    _ = &D.cachechars;
    _ = &D.agefont;
    _ = &D.loadchar;
    _ = &D.buildfont;
    _ = &D.freefont;
    _ = &D.openfont;
    _ = &D.getdefont;
    _ = &D.allocsubfont;
    _ = &D.lookupsubfont;
    _ = &D.installsubfont;
    _ = &D.uninstallsubfont;
    _ = &D.subfontname;
    _ = &D._getsubfont;
    _ = &D.freesubfont;
    _ = &D.readsubfonti;
    _ = &D.readsubfont;
    _ = &D.string;
    _ = &D.stringop;
    _ = &D.stringn;
    _ = &D.stringnop;
    _ = &D.runestring;
    _ = &D.runestringop;
    _ = &D.runestringn;
    _ = &D.runestringnop;
    _ = &D._string;
    _ = &D.stringbg;
    _ = &D.stringbgop;
    _ = &D.stringnbg;
    _ = &D.stringnbgop;
    _ = &D.runestringbg;
    _ = &D.runestringbgop;
    _ = &D.runestringnbg;
    _ = &D.runestringnbgop;
    _ = &D._stringnwidth;
    _ = &D.stringnwidth;
    _ = &D.stringwidth;
    _ = &D.stringsize;
    _ = &D.runestringnwidth;
    _ = &D.runestringwidth;
    _ = &D.runestringsize;
}
