//! Serial ports, #t: /dev/eiaN, /dev/eiaNctl and /dev/eiaNstatus, and
//! the generic half of every UART driver (queues, stage buffers, flow
//! control, the ctl language).
//! from 9/port/devuart.c; Uart and PhysUart are from 9/port/portdat.h
//!
//! DIFF:
//!   - Errors are Zig error returns.  The waserror sites became defer
//!     (uartread, uartwrite), errdefer (uartdrainoutput) and a catch
//!     (uartclose, which ignores an interrupted drain as the C does).
//!   - uartctl returns error.Ebadarg where the C returns -1, and passes
//!     on the error of an interrupted drain.  Callers that ignore the C's
//!     result write `catch {}`.  It takes a mutable slice because, like
//!     the C, it tokenizes in place; uartctls is for constant strings.
//!   - PhysUart.dobreak returns an error union, since it sleeps; ie, on
//!     and the modem flags of Uart are bools where they are only tested.
//!     PhysUart.status takes the buffer as a slice and returns what it
//!     wrote.  The operations the C calls without a nil check (enable ...
//!     fifo) are not optional; pnp, status, power, getc and putc are.
//!   - physuart is a slice the platform sets before chandevreset (on a
//!     PC: uartpc.uartinit), not a nil-terminated array written by mkdevc.
//!   - The stage buffer positions (iw, ir, ie, op, oe) are indices into
//!     istage and ostage, not pointers, so a Uart can be copied or
//!     initialised at compile time.  "Not enabled yet" is ie == 0 where
//!     the C tests iw for nil.
//!   - Kernel print does not go through the console UART.  consuart is
//!     set and uartgetc, uartputc and uartputs are here, but print.zig
//!     keeps writing to its registered (polled) consoles: uartreset does
//!     not replay kmesg into a newly found console, and although uartinit
//!     sets devcons.serialoq as the C does, only consactive and prflush
//!     look at it.  So the output queue carries only what is written to
//!     /dev/eiaN.
//!   - uartpower is not here: Dev has no power entry.  PhysUart.power and
//!     Uart.saveregs are kept so a driver can fill them, but nothing calls
//!     power.
//!   - uart[] holds no nil entries (uartreset fills every one), so the
//!     nil checks on its elements are gone.
//!   - uartmouse releases the Uart's qlock if setting 1200 baud is
//!     interrupted; the C leaves it held.
//!   - uartctl skips an empty field (a quoted '') where the C reads past
//!     its end.
//!   - NETTYPE, NETID, NETQID and the N*qid numbers (9/port/netif.h) and
//!     strtol/atoi (libc) are not ported yet and are private here.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const xalloc = @import("xalloc.zig");
const qio = @import("qio.zig");
const proc = @import("proc.zig");
const parse = @import("parse.zig");
const portclock = @import("portclock.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");
const p9 = @import("print.zig");

const panic = p9.panic;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const mkqid = devmod.mkqid;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Dir = portdat.Dir;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Rendez = portdat.Rendez;
const Timer = portdat.Timer;
const Queue = qio.Queue;
const Dirtab = devmod.Dirtab;
const QTDIR = fcall.QTDIR;
const DMDIR = fcall.DMDIR;
const COPEN = portdat.COPEN;
const KNAMELEN = portdat.KNAMELEN;
const NUMSIZE = portdat.NUMSIZE;
const READSTR = portdat.READSTR;

/// routines to access UART hardware
pub const PhysUart = struct {
    name: []const u8,
    pnp: ?*const fn () ?*Uart = null,
    enable: *const fn (*Uart, ie: bool) void,
    disable: *const fn (*Uart) void,
    kick: *const fn (*Uart) void,
    dobreak: *const fn (*Uart, ms: i32) Error!void,
    baud: *const fn (*Uart, i32) i32,
    bits: *const fn (*Uart, i32) i32,
    stop: *const fn (*Uart, i32) i32,
    parity: *const fn (*Uart, i32) i32,
    modemctl: *const fn (*Uart, on: i32) void,
    rts: *const fn (*Uart, on: i32) void,
    dtr: *const fn (*Uart, on: i32) void,
    /// Writes the text of the status file into buf, returns what it wrote.
    status: ?*const fn (*Uart, buf: []u8) []u8 = null,
    fifo: *const fn (*Uart, level: i32) void,
    power: ?*const fn (*Uart, on: bool) void = null,
    getc: ?*const fn (*Uart) i32 = null, // polling versions, for iprint, rdb
    putc: ?*const fn (*Uart, i32) void = null,
};

pub const Stagesize = 2048;

/// software UART
pub const Uart = struct {
    regs: ?*anyopaque = null, // hardware stuff
    saveregs: ?*anyopaque = null, // place to put registers on power down
    name: []const u8 = "", // internal name
    freq: u32 = 0, // clock frequency
    bits: i32 = 0, // bits per character
    stop: i32 = 0, // stop bits
    parity: i32 = 0, // even, odd or no parity
    baud: i32 = 0, // baud rate
    phys: *const PhysUart,
    console: bool = false, // used as a serial console
    special: bool = false, // internal kernel device
    next: ?*Uart = null, // list of allocated uarts

    qlock: QLock = .{},
    type: i32 = 0, // ??
    dev: i32 = 0,
    opens: i32 = 0,

    enabled: bool = false,
    elist: ?*Uart = null, // next enabled interface

    perr: i32 = 0, // parity errors
    ferr: i32 = 0, // framing errors
    oerr: i32 = 0, // rcvr overruns
    berr: i32 = 0, // no input buffers
    serr: i32 = 0, // input queue overflow

    // buffers
    putc: ?*const fn (?*Queue, i32) i32 = null,
    iq: ?*Queue = null,
    oq: ?*Queue = null,

    rlock: Lock = .{},
    istage: [Stagesize]u8 = @splat(0),
    iw: usize = 0, // indices into istage (see DIFF)
    ir: usize = 0,
    ie: usize = 0,

    tlock: Lock = .{}, // transmit
    ostage: [Stagesize]u8 = @splat(0),
    op: usize = 0, // indices into ostage
    oe: usize = 0,
    drain: bool = false,

    modem: bool = false, // hardware flow control on
    xonoff: bool = false, // software flow control on
    blocked: bool = false,
    cts: bool = false, // keep track of modem status
    dsr: bool = false,
    dcd: bool = false,
    ctsbackoff: i32 = 0,
    hup_dsr: i32 = 0, // send hangup upstream?
    hup_dcd: i32 = 0,
    dohup: bool = false,

    r: Rendez = .{},
};

// soft flow control chars
const CTLS = 0o23;
const CTLQ = 0o21;

// from 9/port/netif.h, which is not ported yet.
const Ndataqid = 5;
const Nctlqid = 6;
const Nstatqid = 7;

fn NETTYPE(x: u64) u32 {
    return @as(u32, @truncate(x)) & 0x1f;
}

fn NETID(x: u64) u32 {
    return @as(u32, @truncate(x)) >> 5;
}

fn NETQID(i: u32, t: u32) u64 {
    return (i << 5) | t;
}

/// The drivers to ask for UARTs (see DIFF); set before chandevreset.
pub var physuart: []const *const PhysUart = &.{};

var uartlist: ?*Uart = null;
var uart: []*Uart = &.{};
var uartnuart: usize = 0;
var uartdir: []Dirtab = &.{};
var uartndir: usize = 0;
var uarttimer: ?*Timer = null;

var uartalloc: struct {
    lock: Lock = .{},
    elist: ?*Uart = null, // list of enabled interfaces
} = .{};

/// strtol(s, &end, base) from libc: optional white space and sign, then
/// a number in the base (0: 16 after 0x, 8 after 0, 10 otherwise).  end
/// is the index of the first character not used, 0 if there is no number.
/// Overflow wraps where the C saturates.
pub fn strtol(s: []const u8, base_: u32) struct { n: i64, end: usize } {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or (s[i] >= '\t' and s[i] <= '\r'))) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var base = base_;
    if (base == 0) {
        base = 10;
        if (i < s.len and s[i] == '0') {
            base = 8;
            if (i + 2 < s.len and (s[i + 1] == 'x' or s[i + 1] == 'X') and std.ascii.isHex(s[i + 2])) {
                base = 16;
                i += 2;
            }
        }
    }
    var n: i64 = 0;
    var ndig: usize = 0;
    while (i < s.len) : (i += 1) {
        const d = std.fmt.charToDigit(s[i], 16) catch break;
        if (d >= base) break;
        n = n *% base +% d;
        ndig += 1;
    }
    if (ndig == 0)
        return .{ .n = 0, .end = 0 };
    return .{ .n = if (neg) 0 -% n else n, .end = i };
}

fn atoi(s: []const u8) i32 {
    return @truncate(strtol(s, 10).n);
}

/// uartctl with a constant string, result ignored.
pub fn uartctls(p: *Uart, comptime cmd: []const u8) void {
    var buf: [cmd.len]u8 = cmd[0..cmd.len].*;
    uartctl(p, &buf) catch {};
}

/// enable/disable uart and add/remove to list of enabled uarts
fn uartenable(p: *Uart) ?*Uart {
    if (p.enabled)
        return p;
    if (p.iq) |q|
        qio.qreopen(q)
    else
        p.iq = qio.qopen(8 * 1024, qio.Qcoalesce, uartflow, p) orelse return null;
    if (p.oq) |q|
        qio.qreopen(q)
    else
        p.oq = qio.qopen(8 * 1024, 0, uartkick, p) orelse {
            qio.qfree(p.iq);
            p.iq = null;
            return null;
        };

    p.ir = 0;
    p.iw = 0;
    p.ie = Stagesize;
    p.op = 0;
    p.oe = 0;

    p.hup_dsr = 0;
    p.hup_dcd = 0;
    p.dsr = false;
    p.dcd = false;

    // assume we can send
    p.cts = true;
    p.blocked = false;
    p.ctsbackoff = 0;

    if (p.bits == 0)
        uartctls(p, "l8");
    if (p.stop == 0)
        uartctls(p, "s1");
    if (p.parity == 0)
        uartctls(p, "pn");
    if (p.baud == 0)
        uartctls(p, "b9600");
    p.phys.enable(p, true);

    // use ilock because uartclock can otherwise interrupt here
    // and would hang on an attempt to lock uartalloc.
    ilock(&uartalloc.lock);
    var l: *?*Uart = &uartalloc.elist;
    while (l.*) |u| : (l = &u.elist) {
        if (u == p)
            break;
    }
    if (l.* == null) {
        p.elist = uartalloc.elist;
        uartalloc.elist = p;
    }
    p.enabled = true;
    iunlock(&uartalloc.lock);

    return p;
}

fn uartdisable(p: *Uart) void {
    if (!p.enabled)
        return;
    p.phys.disable(p);

    ilock(&uartalloc.lock);
    var l: *?*Uart = &uartalloc.elist;
    while (l.*) |u| : (l = &u.elist) {
        if (u == p) {
            l.* = p.elist;
            break;
        }
    }
    p.enabled = false;
    iunlock(&uartalloc.lock);
}

fn uartport(which: []const u8) Error!*Uart {
    const r = strtol(which, 0);
    if (r.end == 0)
        return error.Ebadarg;
    if (r.n < 0 or r.n >= uartnuart)
        return error.Enodev;
    return uart[@intCast(r.n)];
}

pub fn uartmouse(which: []const u8, putc: *const fn (?*Queue, i32) i32, setb1200: bool) Error!void {
    const p = try uartport(which);
    qlock(&p.qlock);
    defer qunlock(&p.qlock);
    if (p.opens == 0 and uartenable(p) == null)
        return error.Enodev;
    p.opens += 1;
    if (setb1200) {
        var cmd = "b1200".*;
        try uartctl(p, &cmd);
    }
    p.putc = putc;
    p.special = true;
}

pub fn uartsetmouseputc(which: []const u8, putc: *const fn (?*Queue, i32) i32) Error!void {
    const p = try uartport(which);
    qlock(&p.qlock);
    defer qunlock(&p.qlock);
    if (p.opens == 0 or !p.special)
        return error.Enodev;
    p.putc = putc;
}

fn setlength(i: i32) void {
    if (i > 0) {
        const p = uart[@intCast(i)];
        if (p.opens != 0) {
            if (p.iq) |q|
                uartdir[1 + 3 * @as(usize, @intCast(i))].length = qio.qlen(q);
        }
    } else for (uart, 0..) |p, j| {
        if (p.opens != 0) {
            if (p.iq) |q|
                uartdir[1 + 3 * j].length = qio.qlen(q);
        }
    }
}

/// set up the '#t' directory
fn uartreset() void {
    var tail: ?*Uart = null;
    for (physuart) |phys| {
        const pnp = phys.pnp orelse continue;
        const p = pnp() orelse continue;
        if (uartlist != null)
            tail.?.next = p
        else
            uartlist = p;
        tail = p;
        while (tail.?.next) |n| : (tail = n)
            uartnuart += 1;
        uartnuart += 1;
    }

    if (uartnuart != 0) {
        const a = xalloc.xalloc(uartnuart * @sizeOf(*Uart)) orelse panic("uartreset: no memory", .{});
        uart = @as([*]*Uart, @ptrFromInt(a))[0..uartnuart];
    }

    uartndir = 1 + 3 * uartnuart;
    const da = xalloc.xalloc(uartndir * @sizeOf(Dirtab)) orelse panic("uartreset: no memory", .{});
    uartdir = @as([*]Dirtab, @ptrFromInt(da))[0..uartndir];
    // DIFF: a Dirtab's name is a slice; the C's is an array in the entry.
    const na = xalloc.xalloc(uartndir * KNAMELEN) orelse panic("uartreset: no memory", .{});
    const names = @as([*]u8, @ptrFromInt(na))[0 .. uartndir * KNAMELEN];

    var dp: usize = 0;
    uartdir[dp] = .{ .name = ".", .qid = mkqid(0, 0, QTDIR), .length = 0, .perm = DMDIR | 0o555 };
    dp += 1;
    var p = uartlist;
    for (0..uartnuart) |i| {
        const u = p.?;
        const id: u32 = @intCast(i);
        // 3 directory entries per port
        uartdir[dp] = .{
            .name = fmt.snprint(names[dp * KNAMELEN ..][0..KNAMELEN], "eia%d", .{id}),
            .qid = .{ .path = NETQID(id, Ndataqid) },
            .perm = 0o660,
        };
        dp += 1;
        uartdir[dp] = .{
            .name = fmt.snprint(names[dp * KNAMELEN ..][0..KNAMELEN], "eia%dctl", .{id}),
            .qid = .{ .path = NETQID(id, Nctlqid) },
            .perm = 0o660,
        };
        dp += 1;
        uartdir[dp] = .{
            .name = fmt.snprint(names[dp * KNAMELEN ..][0..KNAMELEN], "eia%dstatus", .{id}),
            .qid = .{ .path = NETQID(id, Nstatqid) },
            .perm = 0o444,
        };
        dp += 1;

        uart[i] = u;
        u.dev = @intCast(i);

        // enable serial console for uarts detected
        // late during boot (like pci card).
        if (consuart == null) {
            if (arch.getconf("console")) |s| {
                const r = strtol(s, 0);
                if (r.end > 0 and r.n == i) {
                    u.console = true;
                    if (r.end < s.len) {
                        var buf: [64]u8 = undefined;
                        const options = s[r.end..];
                        const n = @min(options.len, buf.len);
                        @memcpy(buf[0..n], options[0..n]);
                        uartctl(u, buf[0..n]) catch {};
                    }
                }
            }
        }

        if (u.console or u.special) {
            if (uartenable(u) != null) {
                if (u.console) {
                    if (consuart == null) {
                        consuart = u;
                        // DIFF: no uartputs(kmesg.buf, kmesg.n): print
                        // has already written it to the polled console.
                    }
                }
                u.opens += 1;
            }
        }
        p = u.next;
    }

    if (uartnuart != 0) {
        // at 115200 baud, the 1024 char buffer takes 56 ms to process,
        // processing it every 22 ms should be fine.
        uarttimer = portclock.addclock0link(uartclock, 22);
    }
}

fn uartinit() void {
    // now that the timers are ticking, enable buffered uart
    // DIFF: print does not use serialoq; see the header.
    if (devcons.serialoq == null) {
        if (consuart) |cu| {
            if (cu.enabled)
                devcons.serialoq = cu.oq;
        }
    }
}

fn uartattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('t', spec);
}

fn uartwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, uartdir, devmod.devgen);
}

fn uartstat(c: *Chan, dp: []u8) Error!usize {
    if (NETTYPE(c.qid.path) == Ndataqid)
        setlength(@intCast(NETID(c.qid.path)));
    return devmod.devstat(c, dp, uartdir, devmod.devgen);
}

fn uartopen(c: *Chan, omode: u32) Error!*Chan {
    _ = try devmod.devopen(c, omode, uartdir, devmod.devgen);

    switch (NETTYPE(c.qid.path)) {
        Nctlqid, Ndataqid => {
            const p = uart[NETID(c.qid.path)];
            qlock(&p.qlock);
            if (p.opens == 0 and uartenable(p) == null) {
                qunlock(&p.qlock);
                c.flag &= ~@as(u16, COPEN);
                return error.Enodev;
            }
            p.opens += 1;
            qunlock(&p.qlock);
        },
        else => {},
    }

    c.iounit = qio.qiomaxatomic;
    return c;
}

fn uartdrained(arg: ?*anyopaque) bool {
    const p: *Uart = @ptrCast(@alignCast(arg.?));
    return qio.qlen(p.oq.?) == 0 and p.op == p.oe;
}

fn uartdrainoutput(p: *Uart) Error!void {
    if (!p.enabled or arch.up() == null or !arch.islo())
        return;
    p.drain = true;
    errdefer p.drain = false;
    try proc.sleep(&p.r, uartdrained, p);
}

fn uartclose(c: *Chan) Error!void {
    if (c.qid.type & QTDIR != 0)
        return;
    if (c.flag & COPEN == 0)
        return;
    switch (NETTYPE(c.qid.path)) {
        Ndataqid, Nctlqid => {
            const p = uart[NETID(c.qid.path)];
            qlock(&p.qlock);
            p.opens -= 1;
            if (p.opens == 0) {
                qio.qclose(p.iq);
                ilock(&p.rlock);
                p.ir = 0;
                p.iw = 0;
                iunlock(&p.rlock);

                qio.qhangup(p.oq.?, null);
                uartdrainoutput(p) catch {};
                qio.qclose(p.oq);
                uartdisable(p);
                p.dcd = false;
                p.dsr = false;
                p.dohup = false;
            }
            qunlock(&p.qlock);
        },
        else => {},
    }
}

fn uartread(c: *Chan, buf: []u8, off: i64) Error!usize {
    const offset: usize = @as(u32, @truncate(@as(u64, @bitCast(off))));

    if (c.qid.type & QTDIR != 0) {
        setlength(-1);
        return devmod.devdirread(c, buf, uartdir, devmod.devgen);
    }

    const p = uart[NETID(c.qid.path)];
    switch (NETTYPE(c.qid.path)) {
        Ndataqid => return qio.qread(p.iq.?, buf),
        Nctlqid => return devcons.readnum(offset, buf, NETID(c.qid.path), NUMSIZE),
        Nstatqid => {
            if (off >= READSTR)
                return 0;
            const s = alloc.smalloc(READSTR)[0..READSTR];
            defer alloc.free(s.ptr);
            const text = if (p.phys.status) |status|
                status(p, s)
            else
                fmt.snprint(s, "b%d\n" ++
                    "dev(%d) type(%d) framing(%d) overruns(%d) " ++
                    "berr(%d) serr(%d)\n", .{
                    p.baud,
                    p.dev,
                    p.type,
                    p.ferr,
                    p.oerr,
                    p.berr,
                    p.serr,
                });
            return devcons.readstr(offset, buf, text);
        },
        else => {},
    }

    return 0;
}

pub fn uartctl(p: *Uart, cmd: []u8) Error!void {
    var f: [16][]u8 = undefined;

    const nf = parse.tokenize(cmd, &f);
    for (f[0..nf]) |fi| {
        if (fi.len == 0)
            continue;
        if (std.mem.startsWith(u8, fi, "break")) {
            try p.phys.dobreak(p, 0);
            continue;
        }

        const n = atoi(fi[1..]);
        switch (fi[0]) {
            'B', 'b' => {
                try uartdrainoutput(p);
                if (p.phys.baud(p, n) < 0)
                    return error.Ebadarg;
            },
            'C', 'c' => p.hup_dcd = n,
            'D', 'd' => {
                try uartdrainoutput(p);
                p.phys.dtr(p, n);
            },
            'E', 'e' => p.hup_dsr = n,
            'f', 'F' => {
                if (p.oq) |q|
                    qio.qflush(q);
            },
            'H', 'h' => {
                if (p.iq) |q|
                    qio.qhangup(q, null);
                if (p.oq) |q|
                    qio.qhangup(q, null);
            },
            'i', 'I' => {
                try uartdrainoutput(p);
                p.phys.fifo(p, n);
            },
            'K', 'k' => {
                try uartdrainoutput(p);
                try p.phys.dobreak(p, n);
            },
            'L', 'l' => {
                try uartdrainoutput(p);
                if (p.phys.bits(p, n) < 0)
                    return error.Ebadarg;
            },
            'm', 'M' => {
                try uartdrainoutput(p);
                p.phys.modemctl(p, n);
            },
            'n', 'N' => {
                if (p.oq) |q|
                    qio.qnoblock(q, n != 0);
            },
            'P', 'p' => {
                try uartdrainoutput(p);
                if (p.phys.parity(p, if (fi.len > 1) fi[1] else 0) < 0)
                    return error.Ebadarg;
            },
            'Q', 'q' => {
                if (n < 0 or n > 1024 * 1024)
                    return error.Ebadarg;
                if (p.iq) |q|
                    qio.qsetlimit(q, n);
                if (p.oq) |q|
                    qio.qsetlimit(q, n);
            },
            'R', 'r' => {
                try uartdrainoutput(p);
                p.phys.rts(p, n);
            },
            'S', 's' => {
                try uartdrainoutput(p);
                if (p.phys.stop(p, n) < 0)
                    return error.Ebadarg;
            },
            'W', 'w' => {
                const t = uarttimer orelse return error.Ebadarg;
                if (n < 1)
                    return error.Ebadarg;
                t.tns = @as(i64, n) * 100000;
            },
            'X', 'x' => {
                ilock(&p.tlock);
                p.xonoff = n != 0;
                p.blocked = false;
                iunlock(&p.tlock);
            },
            else => {},
        }
    }
}

fn uartwrite(c: *Chan, buf: []const u8, _: i64) Error!usize {
    if (c.qid.type & QTDIR != 0)
        return error.Eperm;

    const p = uart[NETID(c.qid.path)];
    var n = buf.len;

    switch (NETTYPE(c.qid.path)) {
        Ndataqid => {
            qlock(&p.qlock);
            defer qunlock(&p.qlock);

            n = try qio.qwrite(p.oq.?, buf);
        },
        Nctlqid => {
            const cmd = alloc.smalloc(n + 1)[0..n];
            defer alloc.free(cmd.ptr);
            @memcpy(cmd, buf);
            // DIFF: the C's string ends at the first NUL written.
            const len = std.mem.findScalar(u8, cmd, 0) orelse n;
            qlock(&p.qlock);
            defer qunlock(&p.qlock);

            // let output drain
            try uartctl(p, cmd[0..len]);
        },
        else => {},
    }

    return n;
}

fn uartwstat(c: *Chan, dp: []const u8) Error!usize {
    var d: Dir = .{};

    if (!devcons.iseve())
        return error.Eperm;
    if (QTDIR & c.qid.type != 0)
        return error.Eperm;
    if (NETTYPE(c.qid.path) == Nstatqid)
        return error.Eperm;

    const dt = uartdir[1 + 3 * NETID(c.qid.path) ..];
    const n = fcall.convM2D(dp, &d, null);
    if (n == 0)
        return error.Eshortstat;
    if (d.mode != ~@as(u32, 0)) {
        dt[0].perm = d.mode;
        dt[1].perm = d.mode;
    }
    return n;
}

pub const uartdevtab: devmod.Dev = .{
    .dc = 't',
    .name = "uart",

    .reset = uartreset,
    .init = uartinit,
    .attach = uartattach,
    .walk = uartwalk,
    .stat = uartstat,
    .open = uartopen,
    .close = uartclose,
    .read = uartread,
    .write = uartwrite,
    .wstat = uartwstat,
};

/// restart input if it's off
fn uartflow(v: ?*anyopaque) void {
    const p: *Uart = @ptrCast(@alignCast(v.?));
    if (p.modem)
        p.phys.rts(p, 1);
}

/// put some bytes into the local queue to avoid calling
/// qconsume for every character
pub fn uartstageoutput(p: *Uart) i32 {
    if (!p.enabled or p.blocked)
        return 0;

    const n = qio.qconsume(p.oq.?, &p.ostage);
    if (n <= 0)
        return 0;
    p.op = 0;
    p.oe = @intCast(n);
    return n;
}

/// restart output
pub fn uartkick(v: ?*anyopaque) void {
    const p: *Uart = @ptrCast(@alignCast(v.?));

    if (!p.enabled or p.blocked)
        return;

    ilock(&p.tlock);
    p.phys.kick(p);
    iunlock(&p.tlock);

    if (p.drain and uartdrained(p)) {
        p.drain = false;
        _ = proc.wakeup(&p.r);
    }
}

/// Move data from the interrupt staging area to
/// the input Queue.
fn uartstageinput(p: *Uart) void {
    while (p.ir != p.iw) {
        const ir = p.ir;
        var iw: usize = undefined;
        if (p.ir > p.iw) {
            iw = p.ie;
            p.ir = 0;
        } else {
            iw = p.iw;
            p.ir = p.iw;
        }
        const n = qio.qproduce(p.iq.?, p.istage[ir..iw]);
        if (n < 0) {
            if (p.modem)
                p.phys.rts(p, 0);
            p.serr +%= 1;
        } else if (n == 0)
            p.berr +%= 1;
    }
}

/// receive a character at interrupt time
pub fn uartrecv(p: *Uart, ch: u8) void {
    // software flow control
    if (p.xonoff) {
        if (ch == CTLS) {
            p.blocked = true;
        } else if (ch == CTLQ) {
            p.blocked = false;
            p.ctsbackoff = 2; // clock gets output going again
        }
    }

    // receive the character
    if (p.putc) |putc| {
        _ = putc(p.iq, ch);
    } else if (p.ie != 0) { // maybe the line isn't enabled yet
        ilock(&p.rlock);
        var next = p.iw + 1;
        if (next == p.ie)
            next = 0;
        if (next == p.ir)
            uartstageinput(p);
        if (next != p.ir) {
            p.istage[p.iw] = ch;
            p.iw = next;
        }
        iunlock(&p.rlock);
    }
}

/// we save up input characters till clock time to reduce
/// per character interrupt overhead.
fn uartclock() void {
    ilock(&uartalloc.lock);
    var l = uartalloc.elist;
    while (l) |p| : (l = p.elist) {

        // this hopefully amortizes cost of qproduce to many chars
        if (p.iw != p.ir) {
            ilock(&p.rlock);
            uartstageinput(p);
            iunlock(&p.rlock);
        }

        // hang up if requested
        if (p.dohup) {
            qio.qhangup(p.iq.?, null);
            qio.qhangup(p.oq.?, null);
            p.dohup = false;
        }

        // this adds hysteresis to hardware/software flow control
        if (p.ctsbackoff != 0) {
            ilock(&p.tlock);
            if (p.ctsbackoff != 0) {
                p.ctsbackoff -= 1;
                if (p.ctsbackoff == 0 and !p.blocked)
                    p.phys.kick(p);
            }
            iunlock(&p.tlock);
        }
    }
    iunlock(&uartalloc.lock);
}

// polling console input, output

pub var consuart: ?*Uart = null;

pub fn uartgetc() i32 {
    const cu = consuart orelse return -1;
    const getc = cu.phys.getc orelse return -1;
    return getc(cu);
}

pub fn uartputc(c: i32) void {
    const cu = consuart orelse return;
    const putc = cu.phys.putc orelse return;
    putc(cu, c);
}

pub fn uartputs(s: []const u8) void {
    const cu = consuart orelse return;
    const putc = cu.phys.putc orelse return;

    for (s) |c| {
        if (c == '\n')
            putc(cu, '\r');
        putc(cu, c);
    }
}
