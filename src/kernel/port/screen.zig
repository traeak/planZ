//! The screen: a linear framebuffer left by the boot loader, drawn on
//! with memdraw, with the kernel's console in a window on it and a
//! software cursor.  The interface of 9/pc/screen.h that devdraw,
//! devmouse and swcursor use.
//! from 9/pc/screen.c (the screen with a soft copy: bootscreeninit,
//! setscreensize0, attachscreen, flushmemscreen, getcolor, setcolor,
//! cursoron, cursoroff, setcursor, hwdraw, blankscreen), 9/pc/vga.c
//! (the console: vgaimageinit, vgascroll, vgascreenputc, vgascreenputs,
//! mkcolor, vgascreenwin), 9/pc/vgasoft.c (the software cursor's glue),
//! 9/bcm/screen.c (mousectl; the shape of a screen file without
//! devvga) and /sys/include/cursor.h (Cursor)
//!
//! DIFF:
//!   - There is no devvga, no VGAdev, VGAcur or VGAscr and no mode
//!     setting: one screen, in the mode the firmware chose, described
//!     by the loader's BootInfo instead of *bootscreen=.  What is left
//!     of VGAscr is the variable `scr`.  Gone with them: tilt,
//!     setscreensize, setactualsize, actualscreensize, screenaperture,
//!     vgalinearaddr and vgalinearpci, bootmapfb (the architecture maps
//!     the framebuffer and passes its address), rgbmask2chan (the
//!     loader reports one of two pixel formats, which main turns into
//!     a channel descriptor), bootscreenconf (no kernel-to-kernel
//!     reboot), setpalette, vgablank, addvgaseg, the paged-window and
//!     driver-flush halves of flushmemscreen, and the hardware
//!     acceleration half of hwdraw.
//!   - screeninit is bootscreeninit with those removed.  It runs
//!     earlier than the C's, from main before interrupts are on, and
//!     takes the screen image's memory from xalloc with a static
//!     Memdata (as the C's own non-soft case does) instead of
//!     allocmemimage: the size-class allocator would round 4MB up to
//!     8MB.  The image is still a soft screen: it is in RAM, drawing
//!     never reads the framebuffer, and flushmemscreen copies what
//!     changed (softscreen and useflush are both always true).
//!   - flushmemscreen: the framebuffer's line length may differ from
//!     the image's (the firmware's stride can exceed the width), so
//!     the two pointers advance by different amounts.
//!   - getcolor gives zeros and setcolor does nothing: the C's do the
//!     same for a screen deeper than 8 bits, bar a colormap array
//!     that then only ever holds zeros.  drawcmap is not called for
//!     the same reason.
//!   - blankscreen does nothing, as the C's with hwblank 0.
//!   - hwdraw is installed in libmemdraw's hwdraw.hook (see
//!     libmemdraw/hwdraw.zig); the C replaces the symbol at link time.
//!   - conf.monitor is also kept here (hasmonitor), since not every
//!     architecture's Conf has the field.
//!   - mousectl: the PC's is in 9/pc/mouse.c, which is architecture
//!     code here (arch/amd64/mouse.zig) and cannot be imported; the
//!     architecture sets archmousectl.  Without one, mousectl is
//!     9/bcm/screen.c's (accelerated, linear).
//!   - The console's functions have the names of 9/bcm/screen.c
//!     (screenputs, screenputc, scroll, screenwin) for vga.c's
//!     vgascreenputs, vgascreenputc, vgascroll, vgascreenwin.
//!   - screenputs is registered with print.zig's addconsole, which has
//!     no screenputs pointer.  print.zig calls it with interrupts off
//!     and its own lock held, so of the C's two ways of taking
//!     vgascreenlock only the try is ever used; the other is kept.
//!     While the kernel is panicking print.zig holds no lock and the
//!     lock here may belong to a processor that has stopped or to the
//!     one that is panicking: then the text is drawn without the lock
//!     rather than dropped, as the C would.
//!   - The partial rune kept between calls is bounded before use, for
//!     the panic case above where two processors may be in here.
//!   - fullrune is a private copy of libc's.

const std = @import("std");
const arch = @import("../arch.zig");
const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const chanmod = @import("../libdraw/chan.zig");
const memdraw = @import("../libmemdraw/memdraw.zig");
const memalloc = @import("../libmemdraw/alloc.zig");
const mdraw = @import("../libmemdraw/draw.zig");
const mstring = @import("../libmemdraw/string.zig");
const memhwdraw = @import("../libmemdraw/hwdraw.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const xalloc = @import("xalloc.zig");
const proc = @import("proc.zig");
const parse = @import("parse.zig");
const netif = @import("netif.zig");
const devdraw = @import("devdraw.zig");
const devmouse = @import("devmouse.zig");
const swcursor = @import("swcursor.zig");
const p9 = @import("print.zig");
const alloc = @import("alloc.zig");
const devcons = @import("devcons.zig");
const qio = @import("qio.zig");
const allocmemsubfont = @import("../libmemdraw/subfont.zig").allocmemsubfont;

const print = p9.print;
const Pt = arith.Pt;
const Rect = arith.Rect;
const Rpt = arith.Rpt;
const addpt = arith.addpt;
const insetrect = arith.insetrect;
const combinerect = arith.combinerect;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const wordsperline = @import("../libdraw/bytesperline.zig").wordsperline;
const getmemdefont = @import("../libmemdraw/defont.zig").getmemdefont;
const allocmemimage = memalloc.allocmemimage;
const allocmemimaged = memalloc.allocmemimaged;
const freememimage = memalloc.freememimage;
const byteaddr = memalloc.byteaddr;
const memimageinit = mdraw.memimageinit;
const memimagedraw = mdraw.memimagedraw;
const memfillcolor = mdraw.memfillcolor;
const memimagestring = mstring.memimagestring;
const memsubfontwidth = mstring.memsubfontwidth;
const swcursorhide = swcursor.swcursorhide;
const swcursoravoid = swcursor.swcursoravoid;
const swcursordraw = swcursor.swcursordraw;
const swcursorload = swcursor.swcursorload;
const swcursorinit = swcursor.swcursorinit;
const mousexy = devmouse.mousexy;
const mouseaccelerate = devmouse.mouseaccelerate;

const Error = proc.Error;
const Lock = portdat.Lock;
const Cmdbuf = parse.Cmdbuf;
const Cmdtab = parse.Cmdtab;
const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw.Memimage;
const Memdata = memdraw.Memdata;
const Memsubfont = memdraw.Memsubfont;
const Memdrawparam = memdraw.Memdrawparam;
const ZP = draw.ZP;
const Dy = draw.Dy;
const Dx = draw.Dx;
const S = draw.S;
const UTFmax = lib.UTFmax;

/// cursor.h
pub const Cursor = struct {
    offset: Point = .{},
    clr: [2 * 16]u8 = @splat(0),
    set: [2 * 16]u8 = @splat(0),
};

pub var gscreen: ?*Memimage = null;

/// What is left of the C's VGAscr (see DIFF).
var scr: struct {
    useflush: bool = false,

    vaddr: [*]u8 = undefined, // frame buffer
    pitch: usize = 0, // bytes in one of its lines

    width: i32 = 0,
    height: i32 = 0,

    gscreen: ?*Memimage = null,
    gscreendata: ?*Memdata = null,
    memdefont: *Memsubfont = undefined,

    softscreen: bool = false,
} = .{};

/// conf.monitor (see DIFF).
var monitor: bool = false;

pub fn hasmonitor() bool {
    return monitor;
}

/// The machine's mousectl, if it has one (see DIFF).
pub var archmousectl: ?*const fn (cb: *Cmdbuf) Error!void = null;

var xgdata: Memdata = .{};

fn setscreensize0(width: i32, height: i32, chan: u32) ?[]const u8 {
    scr.gscreendata = null;
    scr.gscreen = null;
    gscreen = null;

    const depth = chanmod.chantodepth(chan);
    if (depth == 0)
        return "bad channel descriptor";

    // DIFF: see the header; the C calls allocmemimage here.
    const r = Rpt(ZP, Pt(width, height));
    const size = @as(usize, @intCast(wordsperline(r, depth))) * @sizeOf(u32) * @as(usize, @intCast(height));
    const mem = xalloc.xalloc(size) orelse return "no memory for vga memimage";
    xgdata.ref = 1;
    xgdata.bdata = @ptrFromInt(mem);
    const i = allocmemimaged(r, chan, &xgdata) orelse return "no memory for vga memimage";
    scr.softscreen = true;
    scr.useflush = true;

    scr.width = width;
    scr.height = height;

    scr.memdefont = getmemdefont() orelse return "no default font";
    // DIFF: on a screen of 1440 lines or more the console's font is
    // doubled, or its text is too small to read.
    if (height >= 1440)
        scr.memdefont = bigfont(scr.memdefont) orelse scr.memdefont;
    gscreen = i;
    scr.gscreen = i;
    scr.gscreendata = i.data;

    return null;
}

pub fn attachscreen(r: *Rectangle, chan: *u32, d: *i32, width: *i32, softscreen: *bool) ?*Memdata {
    const g = scr.gscreen orelse return null;
    const data = scr.gscreendata orelse return null;

    r.* = g.clipr;
    chan.* = g.chan;
    d.* = g.depth;
    width.* = @intCast(g.width);
    softscreen.* = data.allocd or scr.useflush;

    data.ref += 1;
    return data;
}

pub fn flushmemscreen(r_: Rectangle) void {
    var r = r_;
    const g = scr.gscreen orelse return;
    if (!scr.useflush)
        return;
    if (!rectclip(&r, g.clipr))
        return;

    //
    // Linear framebuffer with softscreen.
    //
    const depth: usize = @intCast(g.depth);
    const off = (@as(usize, @intCast(r.min.x)) * depth) / 8;
    const len = (@as(usize, @intCast(r.max.x)) * depth + 7) / 8 - off;
    const incs = @as(usize, g.width) * @sizeOf(u32);
    var sp = byteaddr(g, Pt(0, r.min.y)) + off;
    var sdisp = scr.vaddr + @as(usize, @intCast(r.min.y)) * scr.pitch + off;
    var y = r.min.y;
    while (y < r.max.y) : (y += 1) {
        @memcpy(sdisp[0..len], sp[0..len]);
        sp += incs;
        sdisp += scr.pitch; // DIFF: not incs
    }
}

pub fn getcolor(_: u32, pr: *u32, pg: *u32, pb: *u32) void {
    // DIFF: see the header
    pr.* = 0;
    pg.* = 0;
    pb.* = 0;
}

pub fn setcolor(_: u32, _: u32, _: u32, _: u32) i32 {
    // DIFF: see the header
    return 0;
}

pub fn cursoron() void {
    // vgasoft.c's swmove
    swcursorhide(false);
    swcursordraw(mousexy());
}

pub fn cursoroff() void {}

pub fn setcursor(curs: *const Cursor) void {
    // vgasoft.c's swload
    swcursorload(curs);
}

/// Is this image the screen?  The ishwimage macro of screen.h.
pub fn ishwimage(i: *const Memimage) bool {
    const scrd = scr.gscreendata orelse return false;
    return i.data.bdata == scrd.bdata;
}

pub fn hwdraw(par: *Memdrawparam) i32 {
    const scrd = scr.gscreendata orelse return 0;
    if (scr.gscreen == null)
        return 0;
    // loadmemimage and cloadmemimage come here with only dst and r
    // set, as in the C: src and mask are nil then, whatever the types
    // in Memdrawparam say, so they are read as the optionals they are.
    const dst = par.dst;
    const src = par.src;
    const mask = par.mask;
    if (dst.data.bdata == scrd.bdata)
        swcursoravoid(par.r);
    if (src) |i| {
        if (i.data.bdata == scrd.bdata)
            swcursoravoid(par.sr);
    }
    if (mask) |i| {
        if (i.data.bdata == scrd.bdata)
            swcursoravoid(par.mr);
    }

    // DIFF: nothing accelerates
    return 0;
}

pub fn blankscreen(_: bool) void {
    // DIFF: see the header
}

/// called early on boot to attach to framebuffer
/// setup by bootloader/firmware or plan9.
///
/// `fb` is where the framebuffer is mapped, `stride` its line length
/// in pixels, `chan` the channel descriptor of its pixels.
pub fn screeninit(fb: usize, width: usize, height: usize, stride: usize, chan: u32) void {
    scr.softscreen = true;

    if (width == 0 or height == 0 or stride < width or
        width > std.math.maxInt(i16) or height > std.math.maxInt(i16))
    {
        print("screeninit: bad framebuffer %ludx%lud\n", .{ width, height });
        return;
    }
    const depth: usize = @intCast(chanmod.chantodepth(chan));
    scr.vaddr = @ptrFromInt(fb);
    scr.pitch = stride * ((depth + 7) / 8);

    memimageinit();
    if (setscreensize0(@intCast(width), @intCast(height), chan)) |err| {
        print("setscreensize0: %s\n", .{err});
        return;
    }
    memhwdraw.hook = &hwdraw;

    vgaimageinit(chan);
    screenwin();

    // vgasoft.c's swenable
    swcursorinit();
    swcursorload(&devmouse.cursor);

    monitor = true;
    if (@hasField(arch.Conf, "monitor"))
        arch.conf.monitor = 1;
}

// called from devmouse

const CMaccelerated = 0;
const CMlinear = 1;

const mousectlmsg = [_]Cmdtab{
    .{ .index = CMaccelerated, .cmd = "accelerated", .narg = 0 },
    .{ .index = CMlinear, .cmd = "linear", .narg = 1 },
};

pub fn mousectl(cb: *Cmdbuf) Error!void {
    if (archmousectl) |f|
        return f(cb);

    const ct = try parse.lookupcmd(cb, &mousectlmsg);
    switch (ct.index) {
        CMaccelerated => mouseaccelerate(if (cb.nf == 1) 1 else netif.atoi(cb.f[1])),
        CMlinear => mouseaccelerate(0),
        else => {},
    }
}

// The console, from 9/pc/vga.c.

var conscol: *Memimage = undefined;
var back: *Memimage = undefined;

var curpos: Point = .{};
var window: Rectangle = .{};
var xp: usize = 0; // index into xbuf, where the C has a pointer
var xbuf: [256]i32 = @splat(0);
var vgascreenlock: Lock = .{};

fn vgaimageinit(_: u32) void {
    conscol = memdraw.memblack;
    back = memdraw.memwhite;
}

fn scroll() void {
    const g = scr.gscreen.?;
    const h: i32 = scr.memdefont.height;
    const o = 8 * h;
    var r = Rpt(window.min, Pt(window.max.x, window.max.y - o));
    const p = Pt(window.min.x, window.min.y + o);
    memimagedraw(g, r, g, p, null, p, S);
    r = Rpt(Pt(window.min.x, window.max.y - o), window.max);
    memimagedraw(g, r, back, ZP, null, ZP, S);

    curpos.y -= o;
}

fn screenputc(buf: []const u8, flushr: *Rectangle) void {
    const g = scr.gscreen.?;

    if (xp >= xbuf.len)
        xp = 0;

    const h: i32 = scr.memdefont.height;
    switch (buf[0]) {
        '\n' => {
            if (curpos.y + h >= window.max.y) {
                scroll();
                flushr.* = window;
            }
            curpos.y += h;
            screenputc("\r", flushr);
        },

        '\r' => {
            xp = 0;
            curpos.x = window.min.x;
        },

        '\t' => {
            const w = memsubfontwidth(scr.memdefont, " ").x;
            if (curpos.x >= window.max.x - 4 * w)
                screenputc("\n", flushr);

            var pos = @divTrunc(curpos.x - window.min.x, w);
            pos = 4 - @rem(pos, 4);
            xbuf[xp] = curpos.x;
            xp += 1;
            const r = Rect(curpos.x, curpos.y, curpos.x + pos * w, curpos.y + h);
            memimagedraw(g, r, back, ZP, null, ZP, S);
            curpos.x += pos * w;
        },

        0x08 => {
            if (xp == 0)
                return;
            xp -= 1;
            const r = Rect(xbuf[xp], curpos.y, curpos.x, curpos.y + h);
            memimagedraw(g, r, back, r.min, null, ZP, S);
            combinerect(flushr, r);
            curpos.x = xbuf[xp];
        },

        0 => {},

        else => {
            const w = memsubfontwidth(scr.memdefont, buf).x;

            if (curpos.x >= window.max.x - w)
                screenputc("\n", flushr);

            xbuf[xp] = curpos.x;
            xp += 1;
            const r = Rect(curpos.x, curpos.y, curpos.x + w, curpos.y + h);
            memimagedraw(g, r, back, r.min, null, ZP, S);
            _ = memimagestring(g, curpos, conscol, ZP, scr.memdefont, buf);
            combinerect(flushr, r);
            curpos.x += w;
        },
    }
}

/// libc's fullrune.
fn fullrune(s: []const u8) bool {
    if (s.len == 0)
        return false;
    const c = s[0];
    if (c < 0x80)
        return true;
    if (c < 0xE0)
        return s.len >= 2;
    if (c < 0xF0)
        return s.len >= 3;
    return s.len >= 4;
}

var rb: [UTFmax + 1]u8 = @splat(0);
var nrb: usize = 0;

/// The font `f` with every pixel doubled each way.  Not in the C.
fn bigfont(f: *Memsubfont) ?*Memsubfont {
    const b = f.bits;
    if (b.depth != 1)
        return null;
    const n: usize = @intCast(f.n);
    const i = allocmemimage(Rect(b.r.min.x * 2, b.r.min.y * 2, b.r.max.x * 2, b.r.max.y * 2), b.chan) orelse return null;
    const info = alloc.newslice(draw.Fontchar, n + 1) orelse {
        freememimage(i);
        return null;
    };
    var y = b.r.min.y;
    while (y < b.r.max.y) : (y += 1) {
        var x = b.r.min.x;
        while (x < b.r.max.x) : (x += 1) {
            const bit = byteaddr(b, Pt(x, y))[0] & (@as(u8, 0x80) >> @intCast(x & 7));
            var k: i32 = 0;
            while (k < 4) : (k += 1) {
                const px = x * 2 + (k & 1);
                const d = &byteaddr(i, Pt(px, y * 2 + (k >> 1)))[0];
                const m = @as(u8, 0x80) >> @intCast(px & 7);
                if (bit != 0) d.* |= m else d.* &= ~m;
            }
        }
    }
    for (info, 0..) |*c, j| {
        const o = f.info[j];
        c.* = .{ .x = o.x * 2, .top = o.top *| 2, .bottom = o.bottom *| 2, .left = o.left *| 2, .width = o.width *| 2 };
    }
    return allocmemsubfont("*default2*", f.n, @as(i32, f.height) * 2, @as(i32, f.ascent) * 2, info.ptr, i) orelse {
        alloc.free(info.ptr);
        freememimage(i);
        return null;
    };
}

pub fn screenputs(s: []const u8) void {
    // As putstrn0 in the C: while a program has /dev/kprint open,
    // kernel messages go there and not over what is on the screen.
    if (devcons.kprintoq) |q| {
        if (!qio.qisclosed(q) and !p9.panicking)
            return;
    }

    var locked = true;

    if (!arch.islo()) {
        //
        // Don't deadlock trying to
        // print in an interrupt.
        //
        if (!taslock.canlock(&vgascreenlock)) {
            // DIFF: a panic is drawn regardless; see the header.
            if (!p9.panicking)
                return;
            locked = false;
        }
    } else {
        while (!taslock.canlock(&vgascreenlock)) {}
    }

    //
    // Be nice to hold this, but not going to deadlock
    // waiting for it.  Just try and see.
    //
    const gotdraw = ql.canqlock(&devdraw.drawlock);

    var flushr = Rect(10000, 10000, -10000, -10000);

    for (s) |c| {
        if (nrb >= UTFmax) // DIFF: see the header
            nrb = 0;
        rb[nrb] = c;
        nrb += 1;
        if (nrb >= UTFmax or fullrune(rb[0..nrb])) {
            const n = nrb;
            nrb = 0;
            screenputc(rb[0..n], &flushr);
        }
    }
    flushmemscreen(flushr);

    if (gotdraw)
        ql.qunlock(&devdraw.drawlock);
    if (locked)
        taslock.unlock(&vgascreenlock);
}

fn mkcolor(screen: *Memimage, color: u32) ?*Memimage {
    const i = allocmemimage(Rect(0, 0, 1, 1), screen.chan) orelse return null;
    i.flags |= memdraw.Frepl;
    i.clipr = screen.r;
    memfillcolor(i, color);
    return i;
}

fn screenwin() void {
    const g = scr.gscreen.?;

    const h: i32 = scr.memdefont.height;
    var r = g.r;

    if (mkcolor(g, 0x0D686BFF)) |i| {
        memimagedraw(g, r, i, ZP, null, ZP, S);
        freememimage(i);
    }

    r = g.clipr;
    window = insetrect(r, 20);
    memimagedraw(g, window, conscol, ZP, memdraw.memopaque, ZP, S);
    window = insetrect(window, 4);
    memimagedraw(g, window, back, ZP, memdraw.memopaque, ZP, S);

    if (mkcolor(g, 0xAAAAAAFF)) |i| {
        memimagedraw(g, Rect(window.min.x, window.min.y, window.max.x, window.min.y + h + 5 + 6), i, ZP, null, ZP, S);
        freememimage(i);

        window = insetrect(window, 5);
        const p = addpt(window.min, Pt(10, 0));
        _ = memimagestring(g, p, memdraw.memblack, ZP, scr.memdefont, " Plan 9 Console ");
        window.min.y += h + 6;
    } else window = insetrect(window, 5);

    window.max.y = window.min.y + @divTrunc(Dy(window), h) * h;
    curpos = window.min;

    flushmemscreen(r);

    // DIFF: a screen too small to hold a line of text gets no console
    // (the C would draw outside its window).
    if (Dy(window) < h or Dx(window) < 8 * memsubfontwidth(scr.memdefont, " ").x)
        return;
    screenputs(p9.kmesg.buf[0..p9.kmesg.n]);
    p9.addconsole(screenputs);
}
