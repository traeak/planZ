//! The device #m: /dev/mouse, /dev/mousein, /dev/mousectl and
//! /dev/cursor, and the mouse state drivers feed.
//! from 9/port/devmouse.c
//!
//! DIFF:
//!   - Errors are Zig error returns.  The waserror around the control
//!     message in mousewrite, which frees the Cmdbuf, is a defer.  The
//!     `while(waserror());` of mouseproc is a `catch continue` on its
//!     sleep, the only call there that can fail.
//!   - The Mousestate embedded in Mouseinfo is the field `s`
//!     (mouse.s.xy is the C's mouse.xy); the Lock and Ref are the
//!     fields `lock` and `ref`.
//!   - conf.monitor is screen.hasmonitor(): not every architecture's
//!     Conf has the field.
//!   - mouse.redraw and mouse.resize are set and tested with atomic
//!     loads and stores (Portability rule 2); they are written by
//!     interrupt handlers on one processor and read on another.
//!   - mouseread's shared tail for Qmouse and Qmousein (`if(0){ case
//!     Qmousein: ... }` in the C) is the function mousefmt.
//!   - mousewrite takes the text of a write as a slice; a write of no
//!     bytes to mouse or mousein is Eshort (the C parses whatever
//!     follows its terminating NUL on the stack).  setbuttonmap takes
//!     a slice and so checks the length where the C looks for the NUL.
//!   - The statics of lastmousems and of the three serial decoders are
//!     file-level variables.  The serial decoders (m3mouseputc,
//!     m5mouseputc, mouseputc) are ported but have no caller: planZ
//!     has no serial mouse (see arch/amd64/mouse.zig).

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw = @import("../libmemdraw/memdraw.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const tod = @import("tod.zig");
const parse = @import("parse.zig");
const qio = @import("qio.zig");
const netif = @import("netif.zig");
const portclock = @import("portclock.zig");
const devcons = @import("devcons.zig");
const devuart = @import("devuart.zig");
const devmod = @import("dev.zig");
const devdraw = @import("devdraw.zig");
const screen = @import("screen.zig");

const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const incref = portdat.incref;
const decref = portdat.decref;
const wakeup = proc.wakeup;
const seconds = tod.seconds;
const BGLONG = draw.BGLONG;
const BPLONG = draw.BPLONG;
const Pt = arith.Pt;
const cursoron = screen.cursoron;
const cursoroff = screen.cursoroff;
const setcursor = screen.setcursor;
const blankscreen = screen.blankscreen;

const Error = proc.Error;
const Lock = portdat.Lock;
const Ref = portdat.Ref;
const Rendez = portdat.Rendez;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Dir = portdat.Dir;
const Queue = qio.Queue;
const Dirtab = devmod.Dirtab;
const Cmdtab = parse.Cmdtab;
const Point = draw.Point;
const Memimage = memdraw.Memimage;
pub const Cursor = screen.Cursor;

const ScrollUp = 0x08;
const ScrollDown = 0x10;
const ScrollLeft = 0x20;
const ScrollRight = 0x40;

const Mousestate = struct {
    xy: Point = .{}, // mouse.xy
    buttons: i32 = 0, // mouse.buttons
    counter: u32 = 0, // increments every update
    msec: u32 = 0, // time of last event
};

const Mouseinfo = struct {
    lock: Lock = .{},
    s: Mousestate = .{},
    inbuttons: i32 = 0, // buttons from /dev/mousein
    redraw: bool = false, // update cursor on screen
    redrawr: Rendez = .{}, // wait for cursor screen updates
    lastcounter: u32 = 0, // value when /dev/mouse read
    resize: bool = false, // generate resize event
    r: Rendez = .{},
    ref: Ref = .{},
    open: u32 = 0,
    acceleration: i32 = 0,
    maxacc: i32 = 0,
    queue: [16]Mousestate = @splat(.{}), // circular buffer of click events
    ri: u32 = 0, // read index into queue
    wi: u32 = 0, // write index into queue
};

const CMbuttonmap = 0;
const CMscrollswap = 1;
const CMswap = 2;
const CMblank = 3;
const CMblanktime = 4;
const CMtwitch = 5;
const CMwildcard = 6;

const mousectlmsg = [_]Cmdtab{
    .{ .index = CMbuttonmap, .cmd = "buttonmap", .narg = 0 },
    .{ .index = CMscrollswap, .cmd = "scrollswap", .narg = 0 },
    .{ .index = CMswap, .cmd = "swap", .narg = 1 },
    .{ .index = CMblank, .cmd = "blank", .narg = 1 },
    .{ .index = CMblanktime, .cmd = "blanktime", .narg = 2 },
    .{ .index = CMtwitch, .cmd = "twitch", .narg = 1 },
    .{ .index = CMwildcard, .cmd = "*", .narg = 0 },
};

pub var mouse: Mouseinfo = .{};

const Qdir = 0;
const Qcursor = 1;
const Qmouse = 2;
const Qmousein = 3;
const Qmousectl = 4;

const mousedir = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qdir, .vers = 0, .type = fcall.QTDIR }, .length = 0, .perm = fcall.DMDIR | 0o555 },
    .{ .name = "cursor", .qid = .{ .path = Qcursor }, .length = 0, .perm = 0o666 },
    .{ .name = "mouse", .qid = .{ .path = Qmouse }, .length = 0, .perm = 0o666 },
    .{ .name = "mousein", .qid = .{ .path = Qmousein }, .length = 0, .perm = 0o660 },
    .{ .name = "mousectl", .qid = .{ .path = Qmousectl }, .length = 0, .perm = 0o220 },
};

var buttonmap: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
var mouseswap: bool = false;
var scrollswap: bool = false;
var mousetime: u32 = 0;
var blanktime: u32 = 0;

pub const arrow: Cursor = .{
    .offset = .{ .x = -1, .y = -1 },
    .clr = .{
        0xFF, 0xFF, 0x80, 0x01, 0x80, 0x02, 0x80, 0x0C,
        0x80, 0x10, 0x80, 0x10, 0x80, 0x08, 0x80, 0x04,
        0x80, 0x02, 0x80, 0x01, 0x80, 0x02, 0x8C, 0x04,
        0x92, 0x08, 0x91, 0x10, 0xA0, 0xA0, 0xC0, 0x40,
    },
    .set = .{
        0x00, 0x00, 0x7F, 0xFE, 0x7F, 0xFC, 0x7F, 0xF0,
        0x7F, 0xE0, 0x7F, 0xE0, 0x7F, 0xF0, 0x7F, 0xF8,
        0x7F, 0xFC, 0x7F, 0xFE, 0x7F, 0xFC, 0x73, 0xF8,
        0x61, 0xF0, 0x60, 0xE0, 0x40, 0x40, 0x00, 0x00,
    },
};
pub var cursor: Cursor = .{};

fn now() u32 {
    return portclock.tk2ms(arch.MACHP(0).ticks);
}

fn mousedevgen(c: *Chan, name: ?[]const u8, tab: []const Dirtab, i: i32, dp: *Dir) i32 {
    const rc = devmod.devgen(c, name, tab, i, dp);
    if (rc != -1)
        dp.atime = mousetime;
    return rc;
}

fn mouseinit() void {
    if (!screen.hasmonitor())
        return;
    mousetime = @truncate(@as(u64, @bitCast(seconds())));
    Cursortocursor(&arrow);
    proc.kproc("mouse", mouseproc, null);
}

fn mouseattach(spec: []const u8) Error!*Chan {
    if (!screen.hasmonitor())
        return error.Egreg;
    return devmod.devattach('m', spec);
}

fn mousewalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    //
    // We use devgen() and not mousedevgen() here
    // see "Ugly problem" in dev.c/devwalk()
    //
    return devmod.devwalk(c, nc, name, &mousedir, devmod.devgen);
}

fn mousestat(c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, &mousedir, mousedevgen);
}

fn mouseopen(c: *Chan, omode: u32) Error!*Chan {
    const mode = try devmod.openmode(omode);
    sw: switch (c.qid.path) {
        Qdir => {
            if (omode != lib.OREAD)
                return error.Eperm;
        },
        Qmousein => {
            if (!devcons.iseve())
                return error.Eperm;
            const m = alloc.new(Mousestate) orelse return error.Enomem;
            m.* = .{};
            c.aux = m;
        },
        Qmouse => {
            if (arch.tas(&mouse.open) != 0)
                return error.Einuse;
            mouse.lastcounter = mouse.s.counter;
            @atomicStore(bool, &mouse.resize, false, .release);
            mousetime = @truncate(@as(u64, @bitCast(seconds())));
            // wet floor
            continue :sw Qcursor;
        },
        Qcursor => {
            _ = incref(&mouse.ref);
        },
        else => {},
    }
    c.mode = @intCast(mode);
    c.flag |= portdat.COPEN;
    c.offset = 0;
    return c;
}

fn mouseclose(c: *Chan) Error!void {
    if ((c.qid.type & fcall.QTDIR) != 0 or (c.flag & portdat.COPEN) == 0)
        return;
    sw: switch (c.qid.path) {
        Qmousein => {
            const m: *Mousestate = @ptrCast(@alignCast(c.aux.?));
            ilock(&mouse.lock);
            mouse.inbuttons &= ~m.buttons;
            iunlock(&mouse.lock);
            alloc.free(m); // Mousestate
            c.aux = null;
            return;
        },
        Qmouse => {
            @atomicStore(u32, &mouse.open, 0, .release);
            mouseblankscreen(false);
            // wet floor
            continue :sw Qcursor;
        },
        Qcursor => {
            if (decref(&mouse.ref) != 0)
                return;
            Cursortocursor(&arrow);
        },
        else => {},
    }
}

/// The text of a mouse event, the end of the C's mouseread for mouse
/// and mousein (see DIFF).
fn mousefmt(va: []u8, t: u8, m: *const Mousestate) usize {
    var buf: [1 + 4 * 12 + 1]u8 = undefined;

    var b: i32 = buttonmap[@intCast(m.buttons & 7)];
    // put buttons 4 and 5 back in
    b |= m.buttons & (3 << 3);

    if (scrollswap) {
        if (b == 8)
            b = 16
        else if (b == 16)
            b = 8;
    }

    _ = fmt.snprint(&buf, "%c%11d %11d %11d %11d ", .{ t, m.xy.x, m.xy.y, b, @as(i32, @bitCast(m.msec)) });
    var n = va.len;
    if (n > 1 + 4 * 12)
        n = 1 + 4 * 12;
    @memcpy(va[0..n], buf[0..n]);
    return n;
}

fn mouseread(c: *Chan, va: []u8, off: i64) Error!usize {
    const offset: u32 = @truncate(@as(u64, @bitCast(off)));
    var m: Mousestate = undefined;

    switch (c.qid.path) {
        Qdir => return devmod.devdirread(c, va, &mousedir, mousedevgen),

        Qcursor => {
            if (offset != 0)
                return 0;
            if (va.len < 2 * 4 + 2 * 2 * 16)
                return error.Eshort;

            qlock(&devdraw.drawlock);
            const curs = cursor;
            qunlock(&devdraw.drawlock);

            const n = 2 * 4 + 2 * 2 * 16;
            BPLONG(va[0..], @as(u32, @bitCast(curs.offset.x)));
            BPLONG(va[4..], @as(u32, @bitCast(curs.offset.y)));
            @memcpy(va[8..][0 .. 2 * 16], &curs.clr);
            @memcpy(va[40..][0 .. 2 * 16], &curs.set);
            return n;
        },

        Qmouse => {
            while (!mousechanged(null)) {
                try proc.tsleep(&mouse.r, mousechanged, null, 30 * 1000);
                if (blanktime != 0 and !mousechanged(null) and
                    (@as(u32, @truncate(@as(u64, @bitCast(seconds())))) -% mousetime) >= blanktime *% 60)
                    mouseblankscreen(true);
            }
            mousetime = @truncate(@as(u64, @bitCast(seconds())));
            mouseblankscreen(false);

            ilock(&mouse.lock);
            if (mouse.ri != mouse.wi) {
                m = mouse.queue[mouse.ri % mouse.queue.len];
                mouse.ri +%= 1;
            } else m = mouse.s;
            iunlock(&mouse.lock);

            // Qmouse
            var t: u8 = 'm';
            mouse.lastcounter = m.counter;
            if (@atomicLoad(bool, &mouse.resize, .acquire)) {
                @atomicStore(bool, &mouse.resize, false, .release);
                t = 'r';
            }
            return mousefmt(va, t, &m);
        },

        Qmousein => {
            if (offset != 0)
                return 0;

            ilock(&mouse.lock);
            m = mouse.s;
            iunlock(&mouse.lock);

            return mousefmt(va, 'm', &m);
        },
        else => {},
    }
    return 0;
}

fn setbuttonmap(map: []const u8) Error!void {
    var one: u8 = 0;
    var two: u8 = 0;
    var three: u8 = 0;
    for (0..3) |i| {
        if (i >= map.len)
            return error.Ebadarg;
        const bit = @as(u8, 1) << @intCast(i);
        if (map[i] == '1') {
            if (one != 0)
                return error.Ebadarg;
            one = bit;
        } else if (map[i] == '2') {
            if (two != 0)
                return error.Ebadarg;
            two = bit;
        } else if (map[i] == '3') {
            if (three != 0)
                return error.Ebadarg;
            three = bit;
        } else return error.Ebadarg;
    }
    if (map.len > 3)
        return error.Ebadarg;

    @memset(&buttonmap, 0);
    for (0..8) |i| {
        var x: u8 = 0;
        if (i & 1 != 0)
            x |= one;
        if (i & 2 != 0)
            x |= two;
        if (i & 4 != 0)
            x |= three;
        buttonmap[x] = @intCast(i);
    }
}

/// libc's strtol(p, &p, 0) on what is left of a write: the number,
/// and p advanced past it (unchanged if there is no number).
fn strtol(p: *[]const u8) i32 {
    const r = devuart.strtol(p.*, 0);
    p.* = p.*[r.end..];
    return @truncate(r.n);
}

fn mousewrite(c: *Chan, va: []const u8, _: i64) Error!usize {
    var buf: [64]u8 = undefined;
    var n = va.len;

    switch (c.qid.path) {
        Qdir => return error.Eisdir,

        Qcursor => {
            if (n < 2 * 4 + 2 * 2 * 16) {
                Cursortocursor(&arrow);
                return n;
            }
            n = 2 * 4 + 2 * 2 * 16;
            var curs: Cursor = undefined;
            curs.offset.x = @bitCast(BGLONG(va[0..]));
            curs.offset.y = @bitCast(BGLONG(va[4..]));
            @memcpy(&curs.clr, va[8..][0 .. 2 * 16]);
            @memcpy(&curs.set, va[40..][0 .. 2 * 16]);
            Cursortocursor(&curs);
            return n;
        },

        Qmousectl => {
            const cb = try parse.parsecmd(va);
            defer alloc.free(cb);

            const ct = try parse.lookupcmd(cb, &mousectlmsg);

            sw: switch (ct.index) {
                CMswap => {
                    if (mouseswap)
                        try setbuttonmap("123")
                    else
                        try setbuttonmap("321");
                    mouseswap = !mouseswap;
                },

                CMscrollswap => scrollswap = !scrollswap,

                CMbuttonmap => {
                    if (cb.nf == 1)
                        try setbuttonmap("123")
                    else
                        try setbuttonmap(cb.f[1]);
                },

                CMblank => mouseblankscreen(true),

                CMblanktime => {
                    blanktime = netif.strtoul(cb.f[1], 0).v;
                    // wet floor
                    continue :sw CMtwitch;
                },
                CMtwitch => {
                    mousetime = @truncate(@as(u64, @bitCast(seconds())));
                    mouseblankscreen(false);
                },

                CMwildcard => try screen.mousectl(cb),
                else => {},
            }

            return n;
        },

        Qmousein => {
            if (n > buf.len - 1)
                n = buf.len - 1;
            @memcpy(buf[0..n], va[0..n]);
            // the text ends at a NUL, as the C's string does
            const str: []const u8 = std.mem.sliceTo(buf[0..n], 0);
            if (str.len == 0)
                return error.Eshort; // DIFF: see the header

            var p = str[1..];
            var pt: Point = .{};
            pt.x = strtol(&p);
            if (p.len == 0)
                return error.Eshort;
            pt.y = strtol(&p);
            if (p.len == 0)
                return error.Eshort;
            var b = strtol(&p);
            var msec: u32 = @truncate(@as(u64, @bitCast(devuart.strtol(p, 0).n)));
            if (msec == 0)
                msec = now();

            // exclude wheel
            const z = b & (8 | 16);
            b ^= z;

            const m: *Mousestate = @ptrCast(@alignCast(c.aux.?));
            m.xy = pt;
            m.msec = msec;
            b ^= m.buttons;
            m.buttons ^= b;

            ilock(&mouse.lock);
            mouse.inbuttons = (m.buttons & b) | (mouse.inbuttons & ~b);
            b = mouse.s.buttons & ~b;
            iunlock(&mouse.lock);

            // include wheel
            b &= ~@as(i32, 8 | 16);
            b ^= z;

            if (str[0] == 'A')
                absmousetrack(pt.x, pt.y, b, msec)
            else if (str[0] == 'a')
                scmousetrack(pt.x, pt.y, b, msec)
            else
                mousetrack(pt.x, pt.y, b, msec);
            return n;
        },

        Qmouse => {
            if (n > buf.len - 1)
                n = buf.len - 1;
            @memcpy(buf[0..n], va[0..n]);
            const str: []const u8 = std.mem.sliceTo(buf[0..n], 0);
            if (str.len == 0)
                return error.Eshort; // DIFF: see the header

            var p = str[1..];
            var pt: Point = .{};
            pt.x = strtol(&p);
            if (p.len == 0)
                return error.Eshort;
            pt.y = strtol(&p);
            absmousetrack(pt.x, pt.y, mouse.s.buttons, now());
            return n;
        },
        else => {},
    }

    return error.Egreg;
}

pub const mousedevtab: devmod.Dev = .{
    .dc = 'm',
    .name = "mouse",

    .init = mouseinit,
    .attach = mouseattach,
    .walk = mousewalk,
    .stat = mousestat,
    .open = mouseopen,
    .close = mouseclose,
    .read = mouseread,
    .write = mousewrite,
};

fn Cursortocursor(c: *const Cursor) void {
    qlock(&devdraw.drawlock);
    cursoroff();
    cursor = c.*;
    setcursor(c);
    cursoron();
    qunlock(&devdraw.drawlock);
}

var blanked: bool = false;

pub fn mouseblankscreen(blank: bool) void {
    if (blank == blanked)
        return;
    qlock(&devdraw.drawlock);
    if (blanked != blank) {
        blankscreen(blank);
        blanked = blank;
    }
    qunlock(&devdraw.drawlock);
}

fn shouldredraw(_: ?*anyopaque) bool {
    return @atomicLoad(bool, &mouse.redraw, .acquire);
}

/// process that redraws the cursor
fn mouseproc(_: ?*anyopaque) void {
    while (true) {
        proc.sleep(&mouse.redrawr, shouldredraw, null) catch continue;
        @atomicStore(bool, &mouse.redraw, false, .release);

        qlock(&devdraw.drawlock);
        cursoroff();
        cursoron();
        qunlock(&devdraw.drawlock);
    }
}

fn scale(x_: i32) i32 {
    var x = x_;
    var sign: i32 = 1;

    if (x < 0) {
        sign = -1;
        x = -%x;
    }
    switch (x) {
        0, 1, 2, 3 => {},
        4 => x = 6 + (mouse.acceleration >> 2),
        5 => x = 9 + (mouse.acceleration >> 1),
        else => x *%= mouse.maxacc,
    }
    return sign *% x;
}

///  called at interrupt level to update the structure and
///  awaken any waiting procs.
pub fn mousetrack(dx_: i32, dy_: i32, b: i32, msec: u32) void {
    var dx = dx_;
    var dy = dy_;
    if (mouse.acceleration != 0) {
        dx = scale(dx);
        dy = scale(dy);
    }
    absmousetrack(mouse.s.xy.x +% dx, mouse.s.xy.y +% dy, b, msec);
}

pub fn absmousetrack(x_: i32, y_: i32, b_: i32, msec: u32) void {
    var x = x_;
    var y = y_;
    var b = b_;

    const i = screen.gscreen orelse return;

    if (x < i.clipr.min.x)
        x = i.clipr.min.x;
    if (x >= i.clipr.max.x)
        x = i.clipr.max.x - 1;
    if (y < i.clipr.min.y)
        y = i.clipr.min.y;
    if (y >= i.clipr.max.y)
        y = i.clipr.max.y - 1;

    ilock(&mouse.lock);
    mouse.s.xy = Pt(x, y);
    const lastb = mouse.s.buttons;
    b |= mouse.inbuttons;
    mouse.s.buttons = b;
    mouse.s.msec = msec;
    mouse.s.counter +%= 1;

    //
    // if the queue fills, don't queue any more events until a
    // reader polls the mouse.
    //
    if (b != lastb and (mouse.wi -% mouse.ri) < mouse.queue.len) {
        mouse.queue[mouse.wi % mouse.queue.len] = mouse.s;
        mouse.wi +%= 1;
    }
    iunlock(&mouse.lock);

    _ = wakeup(&mouse.r);

    mouseredraw();
}

pub fn scmousetrack(x_: i32, y_: i32, b: i32, msec: u32) void {
    const i = screen.gscreen orelse return;

    const vx: i64 = @as(i64, @as(u32, @bitCast(x_))) * (i.clipr.max.x - i.clipr.min.x);
    const x: i32 = @as(i32, @truncate((vx + (1 << 30) - ((~vx >> 31) & 1)) >> 31)) +% i.clipr.min.x;
    const vy: i64 = @as(i64, @as(u32, @bitCast(y_))) * (i.clipr.max.y - i.clipr.min.y);
    const y: i32 = @as(i32, @truncate((vy + (1 << 30) - ((~vy >> 31) & 1)) >> 31)) +% i.clipr.min.y;

    absmousetrack(x, y, b, msec);
}

var lasttick: u32 = 0;

pub fn lastmousems() u32 {
    const t = arch.MACHP(0).ticks;
    const d = t -% lasttick;
    lasttick = t;
    // TK2MS, the macro: no overflow check
    return d *% (1000 / arch.mem.HZ);
}

var m3: struct {
    msg: [3]u8 = @splat(0),
    nb: usize = 0,
    middle: i32 = 0,
} = .{};

///  microsoft 3 button, 7 bit bytes
///
///     byte 0 -        1  L  R Y7 Y6 X7 X6
///     byte 1 -        0 X5 X4 X3 X2 X1 X0
///     byte 2 -        0 Y5 Y4 Y3 Y2 Y1 Y0
///     byte 3 -        0  M  x  x  x  x  x     (optional)
///
///  shift & right button is the same as middle button (for 2 button mice)
pub fn m3mouseputc(_: ?*Queue, c: i32) i32 {
    const b = [_]u8{ 0, 4, 1, 5, 0, 2, 1, 3 };
    const msg = &m3.msg;

    if (lastmousems() > 500)
        m3.nb = 0;
    if (m3.nb == 3) {
        m3.nb = 0;
        //
        // an extra byte comes for middle button motion.
        // only two possible values for the extra byte.
        //
        if (c == 0x00 or c == 0x20) {
            // an extra byte gets sent for the middle button
            m3.middle = if (c & 0x20 != 0) 2 else 0;
            const newbuttons = (mouse.s.buttons & ~@as(i32, 2)) | m3.middle;
            mousetrack(0, 0, newbuttons, now());
            return 0;
        }
    }
    msg[m3.nb] = @truncate(@as(u32, @bitCast(c)));
    m3.nb += 1;
    if (m3.nb == 3) {
        const newbuttons = m3.middle | b[(msg[0] >> 4) & 3];
        var x: i16 = @bitCast(@as(u16, msg[0] & 0x3) << 14);
        const dx = @as(i32, x >> 8) | msg[1];
        x = @bitCast(@as(u16, msg[0] & 0xc) << 12);
        const dy = @as(i32, x >> 8) | msg[2];
        mousetrack(dx, dy, newbuttons, now());
    }
    return 0;
}

var m5: struct {
    msg: [4]u8 = @splat(0),
    nb: usize = 0,
} = .{};

/// microsoft intellimouse 3 buttons + scroll
///     byte 0 -        1  L  R Y7 Y6 X7 X6
///     byte 1 -        0 X5 X4 X3 X2 X1 X0
///     byte 2 -        0 Y5 Y4 Y3 Y2 Y1 Y0
///     byte 3 -        0  0  M  %  %  %  %
///
///     %: 0xf => U , 0x1 => D
///
///     L: left
///     R: right
///     U: up
///     D: down
pub fn m5mouseputc(_: ?*Queue, c: i32) i32 {
    const msg = &m5.msg;

    if (lastmousems() > 500)
        m5.nb = 0;
    msg[m5.nb] = @intCast(c & 0x7f);
    m5.nb += 1;
    if (m5.nb == 4) {
        m5.nb = 0;
        const dx: i8 = @bitCast(msg[1] | (msg[0] & 0x3) << 6);
        const dy: i8 = @bitCast(msg[2] | (msg[0] & 0xc) << 4);
        const newbuttons: i32 =
            (msg[0] & 0x10) >> 2 |
            (msg[0] & 0x20) >> 5 |
            @as(i32, if (msg[3] == 0x10) 0x02 else if (msg[3] == 0x0f) ScrollUp else if (msg[3] == 0x01) ScrollDown else 0);
        mousetrack(dx, dy, newbuttons, now());
    }
    return 0;
}

var m0: struct {
    msg: [5]i16 = @splat(0),
    nb: usize = 0,
} = .{};

///  Logitech 5 byte packed binary mouse format, 8 bit bytes
///
///  shift & right button is the same as middle button (for 2 button mice)
pub fn mouseputc(_: ?*Queue, c: i32) i32 {
    const b = [_]u8{ 0, 4, 2, 6, 1, 5, 3, 7, 0, 2, 2, 6, 1, 3, 3, 7 };
    const msg = &m0.msg;

    if (lastmousems() > 500 or (c & 0xF0) == 0x80)
        m0.nb = 0;
    msg[m0.nb] = @truncate(c);
    if (c & 0x80 != 0)
        msg[m0.nb] = @bitCast(@as(u16, @bitCast(msg[m0.nb])) | 0xFF00); // sign extend
    m0.nb += 1;
    if (m0.nb == 5) {
        m0.nb = 0;
        const newbuttons: i32 = b[@intCast((msg[0] & 7) ^ 7)];
        const dx = @as(i32, msg[1]) + msg[3];
        const dy = -(@as(i32, msg[2]) + msg[4]);
        mousetrack(dx, dy, newbuttons, now());
    }
    return 0;
}

pub fn mousechanged(_: ?*anyopaque) bool {
    return mouse.lastcounter != mouse.s.counter or @atomicLoad(bool, &mouse.resize, .acquire);
}

pub fn mousexy() Point {
    return mouse.s.xy;
}

pub fn mouseaccelerate(x: i32) void {
    mouse.acceleration = x;
    if (mouse.acceleration < 3)
        mouse.maxacc = 2
    else
        mouse.maxacc = mouse.acceleration;
}

/// notify reader that screen has been resized
pub fn mouseresize() void {
    @atomicStore(bool, &mouse.resize, true, .release);
    _ = wakeup(&mouse.r);
}

pub fn mouseredraw() void {
    @atomicStore(bool, &mouse.redraw, true, .release);
    _ = wakeup(&mouse.redrawr);
}
