//! kbdfs - the keyboard and the console: scan codes to characters,
//! lines cooked for /dev/cons, and the state of the keys for /dev/kbd
//! from /sys/src/cmd/aux/kbdfs/kbdfs.c
//!
//! usage: kbdfs [ -qdD ] [ -s sname ] [ -m mntpnt ] [ file ]
//!
//! The layers of scan codes it starts with (the C's ascii[][]) are in
//! kbdfs/ascii.zig and the compose sequences (latin1.h, which 9front
//! makes from /lib/keyboard) in kbdfs/latin1.zig, both made by
//! tools/kbdfstab.py.
//!
//! Fixed from C: a character typed while the line thread was not
//! waiting for one was dropped: the 257th of a long line always (the
//! thread was sending on the 256 it had), and now and then the first
//! after a newline.  ctlproc gave each rune to the line thread with
//! nbsend on a channel with no buffer; it now waits (send).  Stock
//! shows the loss (PLAN.md, "The lost character").
//!
//! DIFF:
//!   - The strings on kbdchan and conschan are slices; kbd's have the
//!     0 that ends each message in them, which the C adds when it
//!     copies one out.
//!   - keyproc takes a key out of the list of those held by moving
//!     what is behind it; the C moves two runes more than there are.
//!   - -D is taken and prints nothing (lib9p's chatty9p).

const std = @import("std");
const libc = @import("libc");
const thread = @import("thread");
const p9 = @import("9p");
const sys = libc.sys;
const fcall = libc.fcall;
const K = libc.keyboard;
const asciitab = @import("kbdfs/ascii.zig");
const latin1 = @import("kbdfs/latin1.zig");

pub const main = thread.main;

const Rune = libc.Rune;
const Req = p9.Req;
const Fid = p9.Fid;
const Chan = thread.Chan;
const respond = p9.respond;

const Nscan = asciitab.Nscan;

const Qroot = 0;
const Qkbd = 1;
const Qkbdin = 2;
const Qkbin = 3;
const Qkbmap = 4;
const Qcons = 5;
const Qconsctl = 6;
const Nqid = 7;

const Lnone = 0;
const Lshift = 1;
const Lesc1 = 2;
const Laltgr = 3;
const Lctl = 4;
const Lctrlesc1 = 5;
const Lshiftesc1 = 6;
const Lshiftaltgr = 7;
const Lmod4 = 8;
const Laltgrmod4 = 9;
const Nlayers = asciitab.Nlayers;

const Rawon = 0;
const Rawoff = 1;

const STACK = 8 * 1024;

const Key = extern struct {
    down: bool = false,
    b: u32 = 0, // button, unshifted key
    r: u32 = 0, // rune, shifted key
};

const Scan = struct {
    esc1: bool = false,
    esc2: u32 = 0,
    caps: bool = false,
    num: bool = false,
    shift: bool = false,
    ctl: bool = false,
    alt: bool = false,
    altgr: bool = false,
    mod4: bool = false,
    leds: u32 = 0,
};

const Qtab = struct {
    name: []const u8,
    mode: u32,
    type: u8,
};

const qtab = [Nqid]Qtab{
    .{ .name = "/", .mode = fcall.DMDIR | 0o500, .type = fcall.QTDIR },
    .{ .name = "kbd", .mode = 0o600, .type = 0 },
    .{ .name = "kbdin", .mode = 0o200, .type = 0 },
    .{ .name = "kbin", .mode = 0o200, .type = 0 },
    .{ .name = "kbmap", .mode = 0o600, .type = 0 },
    .{ .name = "cons", .mode = 0o600, .type = 0 },
    .{ .name = "consctl", .mode = 0o600, .type = 0 },
};

const Ebadarg = "invalid argument";
const Eperm = "permission denied";
const Einuse = "file in use";
const Enonexist = "file does not exist";
const Ebadspec = "bad attach specifier";
const Ewalk = "walk in non directory";
const Ephase = "the front fell off";
const Eintr = "interrupted";

var kbdifd: isize = -1;
var scanfd: isize = -1;
var ledsfd: isize = -1;
var consfd: isize = -1;
var mctlfd: isize = -1;
var msinfd: isize = -1;
var notefd: isize = -1;
var killfd: isize = -1;

var kbdopen: i32 = 0;
var consctlopen: i32 = 0;
var quiet = false;
var sname: ?[]const u8 = null;
var mntpt: []const u8 = "/dev";
var user: []const u8 = "";

var debug = false;

var keychan: Chan(Key) = undefined;
var mctlchan: Chan(Key) = undefined;

var kbdreqchan: Chan(*Req) = undefined;
var consreqchan: Chan(*Req) = undefined;

var ctlchan: Chan(u32) = undefined;

var rawchan: Chan(Rune) = undefined;
var runechan: Chan(Rune) = undefined;

var conschan: Chan([]u8) = undefined;
var kbdchan: Chan([]u8) = undefined;
var intchan: Chan(i32) = undefined;

const layertab = [Nlayers][]const u8{
    "none",
    "shift",
    "esc",
    "altgr",
    "ctl",
    "ctlesc",
    "shiftesc",
    "shiftaltgr",
    "mod4",
    "altgrmod4",
};

var kbtabs: [Nlayers][Nscan]Rune = undefined;

fn dev(buf: []u8, file: []const u8) []const u8 {
    return libc.sprint(buf, "%s/%s", .{ mntpt, file });
}

fn eopen(name: []const u8, mode: u32) isize {
    const fd = sys.open(name, mode);
    if (fd < 0 and !quiet)
        libc.fprint(2, "%s: warning: can't open %s: %r\n", .{ libc.argv0, name });
    return fd;
}

fn reboot() void {
    var buf: [256]u8 = undefined;

    if (debug)
        return;

    const fd = eopen(dev(&buf, "reboot"), sys.OWRITE);
    if (fd < 0)
        return;
    _ = sys.write(fd, "reboot\n");
    _ = sys.close(fd);
}

fn shutdown() noreturn {
    if (notefd >= 0)
        _ = sys.write(notefd, "hangup");
    if (killfd >= 0)
        _ = sys.write(killfd, "hangup");
    thread.threadexitsall(null);
}

fn shiftup() void {
    keychan.send(.{ .down = false, .r = K.Kshift, .b = K.Kshift }) catch {};
}

/// The strings a reader is given are the allocator's.
fn dup(s: []const u8) []u8 {
    return p9.estrdup9p(s);
}

/// Give s to a channel of strings if it has room; it is freed if not.
fn give(c: Chan([]u8), s: []u8) void {
    if (!(c.nbsend(s) catch false))
        libc.allocator.free(s);
}

// Scan code processing

fn kbdputsc(scan: *Scan, c_: u8) void {
    var key: Key = .{};
    var c: usize = c_;

    //  e0's is the first of a 2 character sequence, e1 and e2 the first
    //  of a 3 character sequence (on the safari)
    if (scan.esc2 != 0) {
        scan.esc2 -= 1;
        return;
    } else if (c == 0xe1 or c == 0xe2) {
        scan.esc2 = 2;
        return;
    } else if (c == 0xe0) {
        scan.esc1 = true;
        return;
    }

    key.down = (c & 0x80) == 0;
    c &= 0x7f;

    if (c >= Nscan)
        return;

    // qemu workarround: emulate e0 for numpad
    if (c != 0 and std.mem.indexOfScalar(u8, "GHIKMOPQRS", @intCast(c)) != null) {
        if (!scan.num)
            scan.esc1 = true;
    }

    if (scan.esc1 and scan.ctl and kbtabs[Lctrlesc1][c] != 0)
        key.r = kbtabs[Lctrlesc1][c]
    else if (scan.esc1 and scan.shift and kbtabs[Lshiftesc1][c] != 0)
        key.r = kbtabs[Lshiftesc1][c]
    else if (scan.esc1)
        key.r = kbtabs[Lesc1][c]
    else if (scan.altgr and scan.mod4 and kbtabs[Laltgrmod4][c] != 0)
        key.r = kbtabs[Laltgrmod4][c]
    else if (scan.mod4 and kbtabs[Lmod4][c] != 0)
        key.r = kbtabs[Lmod4][c]
    else if (scan.shift and scan.altgr and kbtabs[Lshiftaltgr][c] != 0)
        key.r = kbtabs[Lshiftaltgr][c]
    else if (scan.shift)
        key.r = kbtabs[Lshift][c]
    else if (scan.altgr)
        key.r = kbtabs[Laltgr][c]
    else if (scan.ctl)
        key.r = kbtabs[Lctl][c]
    else
        key.r = kbtabs[Lnone][c];

    if (scan.esc1 or kbtabs[Lnone][c] == 0)
        key.b = key.r
    else
        key.b = kbtabs[Lnone][c];

    if (scan.caps and key.r <= 'z' and key.r >= 'a')
        key.r = key.r + 'A' - 'a';

    if (scan.ctl and scan.alt and key.r == K.Kdel) {
        if (scan.shift)
            shiftup()
        else
            reboot();
    }

    if (key.b != 0)
        keychan.send(key) catch {};

    switch (key.r) {
        K.Kshift => scan.shift = key.down,
        K.Kctl => scan.ctl = key.down,
        K.Kaltgr => scan.altgr = key.down,
        K.Kmod4 => scan.mod4 = key.down,
        K.Kalt => scan.alt = key.down,
        K.Knum => {
            if (key.down)
                scan.num = !scan.num;
        },
        K.Kcaps => {
            if (key.down)
                scan.caps = !scan.caps;
        },
        else => {},
    }
    scan.esc1 = false;
}

fn kbdin(a: *Scan, data: []const u8) void {
    var k: Key = .{};
    var p = data;

    if (p.len > 0 and p[p.len - 1] != 0) {
        // old format as used by bitsy keyboard:
        // just a string of characters, no keyup
        // information.
        const s = std.mem.sliceTo(p, 0);
        var i: usize = 0;
        while (i < s.len) {
            const cr = libc.chartorune(s[i..]);
            i += cr.n;
            if (cr.r != 0)
                rawchan.send(cr.r) catch {};
        }
        return;
    }
    while (p.len >= 2) {
        const msg = std.mem.sliceTo(p, 0);
        switch (p[0]) {
            'R', 'r' => blk: {
                // rune up/down
                if (msg.len < 2)
                    break :blk;
                k.r = libc.chartorune(msg[1..]).r;
                if (k.r == 0)
                    break :blk;
                k.b = 0;
                k.down = p[0] == 'r';
                for (0..Nscan) |i| {
                    if (kbtabs[Lnone][i] == k.r or kbtabs[Lshift][i] == k.r or (i >= 16 and kbtabs[Lctl][i] == k.r)) {
                        // assign button from kbtab
                        k.b = kbtabs[Lnone][i];

                        // handle ^X forms
                        if (k.r == kbtabs[Lnone][i] and kbtabs[Lctl][i] != 0 and !a.shift and !a.altgr and a.ctl)
                            k.r = kbtabs[Lctl][i];
                        break;
                    } else if (kbtabs[Lesc1][i] == k.r or kbtabs[Lshiftesc1][i] == k.r) {
                        // check escaped scancodes too
                        k.b = kbtabs[Lesc1][i];
                        break;
                    }
                }
                // button unknown to kbtab, use rune if no modifier keys are active
                if (k.b == 0 and !a.shift and !a.altgr and !a.ctl)
                    k.b = k.r;
                if (k.r == K.Kshift)
                    a.shift = k.down
                else if (k.r == K.Kaltgr)
                    a.altgr = k.down
                else if (k.r == K.Kmod4)
                    a.mod4 = k.down
                else if (k.r == K.Kctl)
                    a.ctl = k.down;
                keychan.send(k) catch {};
            },
            'c' => {
                const r: Rune = if (msg.len < 2) 0 else libc.chartorune(msg[1..]).r;
                _ = runechan.nbsend(r) catch false;
            },
            else => {
                if (kbdopen != 0)
                    give(kbdchan, dup(p[0 .. msg.len + 1]));
            },
        }
        p = p[msg.len + 1 ..];
    }
}

fn setleds(scan: *Scan, leds_: u32) void {
    var buf: [8]u8 = undefined;

    if (ledsfd < 0 or scan.leds == leds_)
        return;
    const leds = leds_ & 7;
    _ = sys.pwrite(ledsfd, libc.sprint(&buf, "%d", .{leds}), 0);
    scan.leds = leds;
}

/// Read scan codes from scanfd
fn scanproc(_: void) void {
    var buf: [64]u8 = undefined;
    var scan: Scan = .{};

    thread.threadsetname("scanproc");

    while (true) {
        const n = sys.read(scanfd, &buf);
        if (n <= 0)
            break;
        for (buf[0..@intCast(n)]) |c|
            kbdputsc(&scan, c);
        setleds(&scan, (@as(u32, @intFromBool(scan.num)) << 1) | (@as(u32, @intFromBool(scan.caps)) << 2));
    }

    shutdown();
}

fn kbdiproc(_: void) void {
    var buf: [1024]u8 = undefined;
    var a: Scan = .{};

    thread.threadsetname("kbdiproc");

    while (true) {
        const n = sys.read(kbdifd, &buf);
        if (n <= 0)
            break;
        kbdin(&a, buf[0..@intCast(n)]);
    }

    shutdown();
}

/// The runes as UTF, from the allocator; with a 0 after them if zero.
fn utfconv(r: []const Rune, zero: bool) []u8 {
    var l: usize = @intFromBool(zero);
    for (r) |x|
        l += libc.runelen(x);
    const s = p9.emalloc9p(l);
    var p: usize = 0;
    for (r) |x|
        p += libc.runetochar(s[p..], x);
    return s;
}

/// Read key events from keychan and produce characters to
/// rawchan and keystate in kbdchan.
fn keyproc(_: void) void {
    var rb: [Nscan + 1]Rune = undefined;

    thread.threadsetname("keyproc");

    var nb: usize = 0;
    while (keychan.recv()) |key| {
        if (key.r >= K.Kmouse + 1 and key.r <= K.Kmouse + 5) {
            if (msinfd >= 0)
                mctlchan.send(key) catch {};
            continue;
        }
        rb[0] = 0;
        if (key.b != 0) {
            var i: usize = 0;
            while (i < nb and rb[i + 1] != key.b)
                i += 1;
            if (!key.down) {
                while (i < nb and rb[i + 1] == key.b) {
                    std.mem.copyForwards(Rune, rb[i + 1 .. nb], rb[i + 2 .. nb + 1]);
                    nb -= 1;
                    rb[0] = 'K';
                }
            } else if (i == nb and nb < rb.len - 1) {
                nb += 1;
                rb[nb] = @intCast(key.b);
                rb[0] = 'k';
            }
        }
        if (rb[0] != 0) {
            if (kbdopen != 0)
                give(kbdchan, utfconv(rb[0 .. nb + 1], true));
            if (mctlfd >= 0)
                mctlchan.send(key) catch {};
        }
        if (key.down and key.r != 0)
            rawchan.send(@intCast(key.r)) catch {};
    } else |_| {}
}

/// Read characters from consfd (serial console)
fn consproc(_: void) void {
    var buf: [64]u8 = undefined;

    thread.threadsetname("consproc");

    var cr = false;
    var have: usize = 0; // bytes of a rune not yet whole, at the start of buf
    while (true) {
        const n = sys.read(consfd, buf[have..]);
        if (n <= 0)
            break;
        const x = have + @as(usize, @intCast(n));
        var p: usize = 0;
        have = 0;
        while (p < x) {
            if (!libc.fullrune(buf[p..x])) {
                have = x - p;
                std.mem.copyForwards(u8, buf[0..have], buf[p..x]);
                break;
            }
            const c = libc.chartorune(buf[p..x]);
            p += c.n;
            var r = c.r;
            if (r == 0o21 or r == 0o23) // XON/XOFF
                continue;
            if (r == 0 or r == libc.Runeerror) {
                cr = false;
                continue;
            }
            if (r == '\n' and cr) {
                cr = false;
                continue;
            }
            cr = r == '\r';
            if (cr)
                r = '\n';
            runechan.send(r) catch {};
        }
    }

    shutdown();
}

/// The next rune that is not a modifier: 0 with r set to it, 1 with r
/// set to Kctl or Kalt (composing escapes), -1 when the channel is
/// done.
fn nextrune(ch: Chan(Rune), r: *Rune) i32 {
    while (ch.recv()) |x| {
        r.* = x;
        switch (x) {
            // ignore modifiers
            0, K.Kcaps, K.Knum, K.Kshift, K.Kaltgr, K.Kmod4 => continue,
            // composing escapes
            K.Kctl, K.Kalt => return 1,
            else => return 0,
        }
    } else |_| {}
    return -1;
}

/// Read runes from rawchan, possibly compose special characters
/// and output the new runes to runechan
fn runeproc(_: void) void {
    const tab = latin1.tab;
    var r: Rune = 0;

    thread.threadsetname("runeproc");

    var ctl = false;
    while (true) {
        var i = nextrune(rawchan, &r);
        if (i < 0)
            break;
        if (i == 0) {
            ctl = false;
            runechan.send(r) catch {};
            continue;
        }

        if (r == K.Kctl) {
            ctl = true;
            continue;
        }

        // emulators like qemu and vmware use Ctrl+Alt to lock
        // keyboard input so dont confuse them for a compose
        // sequence.
        if (r != K.Kalt or ctl)
            continue;

        if (nextrune(rawchan, &r) != 0)
            continue;

        var rr: Rune = 0;
        if (r == 'x' or r == 'X') {
            i = if (r == 'X') 4 else 6;
            const j = i;
            var v: u32 = 0;
            var nothex = false;
            while (true) {
                if (nextrune(rawchan, &rr) != 0)
                    break;
                if (rr >= '0' and rr <= '9')
                    v = (v << 4) | (rr - '0')
                else if (rr >= 'a' and rr <= 'f')
                    v = (v << 4) | (10 + (rr - 'a'))
                else if (rr >= 'A' and rr <= 'F')
                    v = (v << 4) | (10 + (rr - 'A'))
                else {
                    if (i == j and rr != ';')
                        nothex = true;
                    break;
                }
                i -= 1;
                if (i <= 0)
                    break;
            }
            if (!nothex) {
                if ((i == 0 or rr == ';') and v != 0 and v <= libc.Runemax)
                    runechan.send(@intCast(v)) catch {};
                continue;
            }
            r = if (j == 6) 'x' else 'X';
        } else {
            if (nextrune(rawchan, &rr) != 0)
                continue;
        }
        // Nothex:
        var e: ?usize = null;
        for (tab, 0..) |t, k| {
            if (t.ld[0] != r)
                continue;
            if (t.ld.len == 1) {
                e = k;
                break;
            }
            if (t.ld[1] == rr) {
                _ = nextrune(rawchan, &rr);
                e = k;
                break;
            }
        }
        const t = tab[e orelse continue];
        if (rr == 0)
            continue;
        for (t.si, 0..) |c, k| {
            if (c == rr) {
                runechan.send(t.so[k]) catch {};
                break;
            }
        }
    }
}

/// Need to do this in a separate proc because if process we're interrupting
/// is dying and trying to print tombstone, kernel is blocked holding p->debug lock.
fn intrproc(_: void) void {
    thread.threadsetname("intrproc");

    while (intchan.recv()) |_| {
        _ = sys.write(notefd, "interrupt");
    } else |_| {}
}

/// Process Kmouse keys and mouse button swap on shift,
/// unblank screen by twiching.
fn mctlproc(_: void) void {
    var buf: [64]u8 = undefined;
    var mouseb: u32 = 0;

    thread.threadsetname("mctlproc");

    while (true) {
        const key = (mctlchan.nbrecv() catch null) orelse blk: {
            if (mctlfd >= 0)
                _ = sys.write(mctlfd, "twitch");
            break :blk mctlchan.recv() catch break;
        };

        if (mctlfd >= 0 and key.r == K.Kshift) {
            if (key.down) {
                _ = sys.write(mctlfd, "buttonmap 132");
            } else {
                _ = sys.write(mctlfd, "swap");
                _ = sys.write(mctlfd, "swap");
            }
            continue;
        }

        if (msinfd >= 0 and key.r >= K.Kmouse + 1 and key.r <= K.Kmouse + 5) {
            const i = @as(u32, 1) << @intCast(key.r - (K.Kmouse + 1));
            if (key.down)
                mouseb |= i
            else
                mouseb &= ~i;
            _ = sys.write(msinfd, libc.sprint(&buf, "m%11d %11d %11d", .{ 0, 0, mouseb }));
            continue;
        }
    }
}

fn echo(r: Rune) void {
    var b: [libc.UTFmax]u8 = undefined;
    _ = sys.write(1, b[0..libc.runetochar(&b, r)]);
}

/// Cook lines for cons
fn lineproc(cookc: *thread.Channel) void {
    const cook: Chan(Rune) = .{ .c = cookc };
    var rb: [256]Rune = undefined;

    thread.threadsetname("lineproc");

    while (true) {
        var nr: usize = 0;
        var done = false;
        while (!done and nr < rb.len) {
            const r = cook.recv() catch 0;
            switch (r) {
                K.Kdel, 0 => {
                    if (r == K.Kdel) {
                        if (!(intchan.nbsend(@intCast(notefd)) catch false))
                            continue;
                    }
                    // flush
                    nr = 0;
                },
                // ^H: erase character, ^U: erase line, ^W: erase word
                K.Kbs, K.Knack, K.Ketb => {
                    while (nr > 0) {
                        nr -= 1;
                        _ = sys.write(1, "\x08");
                        if (r == K.Kbs)
                            break;
                        if (r == K.Ketb and (rb[nr] == ' ' or rb[nr] == '\t'))
                            break;
                    }
                },
                K.Keof => done = true, // ^D: eof
                else => {
                    if (r == '\n')
                        done = true;
                    rb[nr] = r;
                    nr += 1;
                    echo(r);
                },
            }
        }
        give(conschan, utfconv(rb[0..nr], false));
    }
}

/// The channels of one reqproc: requests, and the strings to answer
/// them with.
const Reqchans = struct {
    req: Chan(*Req),
    str: Chan([]u8),
};

/// Reads Tread and Tflush requests from reqchan and responds
/// to them with data received on the string channel.
fn reqproc(ac: *const Reqchans) void {
    const AREQ = 0;
    const ASTR = 1;
    var r: *Req = undefined;
    var str: []u8 = &.{};

    thread.threadsetname("reqproc");

    var s: ?[]u8 = null; // the string being given out
    var p: usize = 0; // how much of it has gone

    // the reads that wait, the oldest first, linked through aux
    var q: ?*Req = null;
    var last: ?*Req = null;

    var a = [_]thread.Alt{ ac.req.rcv(&r), ac.str.rcv(&str), thread.altend };

    while (true) {
        a[ASTR].op = if (s != null) .CHANNOP else .CHANRCV;

        switch (thread.alt(&a)) {
            AREQ => {
                if (r.ifcall.type == fcall.Tflush) {
                    var prev: ?*Req = null;
                    var x = q;
                    while (x) |cur| {
                        const next: ?*Req = @ptrCast(@alignCast(cur.aux));
                        if (cur == r.oldreq) {
                            if (prev) |pv| pv.aux = next else q = next;
                            if (next == null)
                                last = prev;
                            respond(cur, Eintr);
                            break;
                        }
                        prev = cur;
                        x = next;
                    }
                    respond(r, null);
                    continue;
                } else if (r.ifcall.type != fcall.Tread) {
                    respond(r, Ephase);
                    continue;
                }
                r.aux = null;
                if (last) |l| l.aux = r else q = r;
                last = r;
            },
            ASTR => {
                s = str;
                p = 0;
            },
            else => continue,
        }

        while (s != null and q != null) {
            const cur = q.?;
            q = @ptrCast(@alignCast(cur.aux));
            if (q == null)
                last = null;
            cur.ofcall.count = 0;
            while (true) {
                const text = s.?;
                var n = text.len - p;
                const m = cur.ifcall.count - cur.ofcall.count;
                if (n > m) {
                    if (cur.ofcall.count > 0)
                        break;
                    n = m;
                }
                @memcpy(cur.rbuf[cur.ofcall.count..][0..n], text[p..][0..n]);
                cur.ofcall.count += @intCast(n);
                p += n;
                if (p >= text.len) {
                    libc.allocator.free(text);
                    s = ac.str.nbrecv() catch null;
                    if (s != null) {
                        p = 0;
                        continue;
                    }
                }
                break;
            }
            respond(cur, null);
        }
    }
}

var aconsr: Reqchans = undefined;
var akbdr: Reqchans = undefined;

/// Keep track of rawing state and distribute the runes from
/// runechan to the right channels depending on the state.
fn ctlproc(_: void) void {
    const ACTL = 0;
    const ARUNE = 1;
    var r: Rune = 0;
    var c: u32 = 0;

    thread.threadsetname("ctlproc");

    if (kbdifd >= 0)
        _ = thread.proccreate(kbdiproc, {}, STACK); // kbdifd -> kbdin()
    if (mctlfd >= 0 or msinfd >= 0)
        _ = thread.proccreate(mctlproc, {}, STACK); // mctlchan -> mctlfd, msinfd
    if (scanfd >= 0)
        _ = thread.proccreate(scanproc, {}, STACK); // scanfd -> keychan
    if (consfd >= 0)
        _ = thread.proccreate(consproc, {}, STACK); // consfd -> runechan
    if (notefd >= 0)
        _ = thread.proccreate(intrproc, {}, STACK); // intchan -> notefd

    _ = thread.threadcreate(keyproc, {}, STACK); // keychan -> mctlchan, rawchan, kbdchan
    _ = thread.threadcreate(runeproc, {}, STACK); // rawchan -> runechan

    aconsr = .{ .req = consreqchan, .str = conschan };
    _ = thread.threadcreate(reqproc, &aconsr, STACK); // consreqchan,conschan -> respond

    akbdr = .{ .req = kbdreqchan, .str = kbdchan };
    _ = thread.threadcreate(reqproc, &akbdr, STACK); // kbdreqchan,kbdchan -> respond

    const cook = Chan(Rune).create(0);
    _ = thread.threadcreate(lineproc, cook.c, STACK); // cook -> conschan

    var raw = false;

    var a = [_]thread.Alt{ ctlchan.rcv(&c), runechan.rcv(&r), thread.altend };

    while (true) {
        switch (thread.alt(&a)) {
            ACTL => switch (c) {
                Rawoff, Rawon => {
                    raw = c == Rawon;
                    if (raw)
                        _ = cook.nbsend(0) catch false;
                },
                else => {},
            },
            ARUNE => {
                if (kbdopen != 0) {
                    const s = p9.emalloc9p(1 + libc.runelen(r) + 1);
                    s[0] = 'c';
                    _ = libc.runetochar(s[1..], r);
                    give(kbdchan, s);
                    continue;
                }
                if (raw) {
                    give(conschan, utfconv(&.{r}, false));
                    continue;
                }
                // Fixed from C: nbsend, which drops the rune when the
                // line thread is not waiting for one
                cook.send(r) catch {};
            },
            else => {},
        }
    }
}

// Keyboard layout maps

fn kbmapent(t: usize, sc: usize) ?*Rune {
    if (t < Nlayers and sc < Nscan)
        return &kbtabs[t][sc];
    return null;
}

fn kbmapread(req: *Req) void {
    var tmp: [3 * 12 + 1]u8 = undefined;
    const size = tmp.len - 1;

    const off: usize = @intCast(@divTrunc(req.ifcall.offset, size));
    const soff: usize = @intCast(@rem(req.ifcall.offset, size));
    const t = off / Nscan;
    const sc = off % Nscan;
    if (kbmapent(t, sc)) |rp| {
        const line = libc.sprint(&tmp, "%11s %11d %11d\n", .{ layertab[t], sc, rp.* });
        var n = line.len -| soff;
        if (req.ifcall.count < n)
            n = req.ifcall.count;
        req.ofcall.count = @intCast(n);
        @memcpy(req.rbuf[0..n], line[soff..][0..n]);
    } else req.ofcall.count = 0;
    respond(req, null);
}

fn kbcompat(r: u32) u32 {
    const o = K.Spec | 0x60;
    const tab = [_]u32{
        K.Kshift, K.Kbreak, K.Kctl,    K.Kalt,
        K.Kcaps,  K.Knum,   K.Kmiddle, K.Kaltgr,
        K.Kmod4,
    };
    if (r >= o and r < o + tab.len)
        return tab[r - o];
    return r;
}

/// One line of a kbmap, without its newline: false if it is wrong.
fn kbmapline(line: []const u8) bool {
    if (line.len == 0)
        return false;
    var lp: usize = 0;
    while (lp < line.len and (line[lp] == ' ' or line[lp] == '\t'))
        lp += 1;
    var e = lp;
    while (e < line.len and line[e] != ' ' and line[e] != '\t')
        e += 1;
    if (e == lp or e == line.len)
        return false;
    const word = line[lp..e];
    var t: usize = Nlayers;
    for (layertab, 0..) |name, i| {
        if (std.mem.eql(u8, word, name)) {
            t = i;
            break;
        }
    }
    if (t == Nlayers) {
        const v = libc.strtoul(word, 0);
        if (v.n == 0)
            return false;
        t = @truncate(v.v);
    }
    e += 1;
    const scv = libc.strtoul(line[e..], 0);
    if (scv.n == 0)
        return false;
    lp = e + scv.n;
    while (lp < line.len and (line[lp] == ' ' or line[lp] == '\t'))
        lp += 1;
    const rp = kbmapent(t, @truncate(scv.v)) orelse return false;
    const rest = line[lp..];
    var r: u32 = 0;
    if (rest.len >= 2 and rest[0] == '\'')
        r = libc.chartorune(rest[1..]).r
    else if (rest.len >= 2 and rest[0] == '^') {
        r = libc.chartorune(rest[1..]).r;
        if (0x40 <= r and r < 0x60)
            r -= 0x40
        else
            return false;
    } else if (rest.len >= 2 and rest[0] == 'M' and '1' <= rest[1] and rest[1] <= '5')
        r = K.Kmouse + @as(u32, rest[1]) - '0'
    else if (rest.len >= 1 and rest[0] >= '0' and rest[0] <= '9') // includes 0x...
        r = @truncate(libc.strtoul(rest, 0).v)
    else
        return false;
    rp.* = @truncate(kbcompat(r));
    return true;
}

fn kbmapwrite(req: *Req) void {
    var line: [100]u8 = undefined;
    var lp: usize = 0;

    const f = req.fid.?;
    if (f.aux) |aux| {
        const old: *[]u8 = @ptrCast(@alignCast(aux));
        @memcpy(line[0..old.len], old.*);
        lp = old.len;
        libc.allocator.free(old.*);
        libc.allocator.destroy(old);
        f.aux = null;
    }
    for (req.ifcall.data[0..req.ifcall.count]) |c| {
        line[lp] = c;
        lp += 1;
        if (c == '\n' or lp == line.len - 1) {
            const l = line[0..lp];
            lp = 0;
            if (l[0] == '\n' or l[0] == '#')
                continue;
            // as the C sees the line: up to a 0, the newline in it
            if (!kbmapline(std.mem.sliceTo(l, 0))) {
                respond(req, Ebadarg);
                return;
            }
        }
    }
    if (lp != 0) {
        const keep = libc.allocator.create([]u8) catch libc.sysfatal("out of memory", .{});
        keep.* = dup(line[0..lp]);
        f.aux = @ptrCast(keep);
    }
    req.ofcall.count = req.ifcall.count;
    respond(req, null);
}

// Filesystem

fn now() u32 {
    return @truncate(@as(u64, @bitCast(libc.time())));
}

fn fillstat(qid: usize, d: *p9.Dir) void {
    const t = &qtab[qid];
    d.* = .{};
    d.uid = user;
    d.gid = user;
    d.muid = "";
    d.qid = .{ .path = qid, .vers = 0, .type = t.type };
    d.atime = now();
    d.name = t.name;
    d.mode = t.mode;
}

fn fsattach(r: *Req) void {
    if (r.ifcall.aname.len != 0) {
        respond(r, Ebadspec);
        return;
    }
    r.fid.?.qid = .{ .path = Qroot, .vers = 0, .type = fcall.QTDIR };
    r.ofcall.qid = r.fid.?.qid;
    respond(r, null);
}

fn fsstat(r: *Req) void {
    fillstat(@intCast(r.fid.?.qid.path), &r.d);
    r.d.name = p9.estrdup9p(r.d.name);
    r.d.uid = p9.estrdup9p(r.d.uid);
    r.d.gid = p9.estrdup9p(r.d.gid);
    r.d.muid = p9.estrdup9p(r.d.muid);
    respond(r, null);
}

fn fswalk1(fid: *Fid, name: []const u8, qid: *p9.Qid) ?[]const u8 {
    switch (fid.qid.path) {
        Qroot => {
            if (std.mem.eql(u8, name, "..")) {
                qid.* = .{ .path = Qroot, .vers = 0, .type = fcall.QTDIR };
                fid.qid = qid.*;
                return null;
            }
            for (qtab, 0..) |t, i| {
                if (!std.mem.eql(u8, name, t.name))
                    continue;
                qid.* = .{ .path = i, .vers = 0, .type = 0 };
                fid.qid = qid.*;
                return null;
            }
            return Enonexist;
        },
        else => return Ewalk,
    }
}

fn fsopen(r: *Req) void {
    const need = [4]u32{ 4, 2, 6, 1 };

    const f = r.fid.?;
    const t = &qtab[@intCast(f.qid.path)];
    const n = need[r.ifcall.mode & 3] << 6;
    if ((n & t.mode) != n)
        respond(r, Eperm)
    else {
        f.aux = null;
        switch (f.qid.path) {
            Qkbmap => {
                if (r.ifcall.mode & sys.OTRUNC != 0)
                    kbtabs = asciitab.ascii;
            },
            Qkbd => {
                if (kbdopen != 0) {
                    respond(r, Einuse);
                    return;
                }
                kbdopen += 1;
            },
            Qconsctl => consctlopen += 1,
            else => {},
        }
        respond(r, null);
    }
}

fn readtopdir(buf: []u8, off: i64, cnt_: usize) usize {
    var d: p9.Dir = .{};
    var cnt = cnt_;

    var n: usize = 0;
    var pos: i64 = 0;
    for (1..Nqid) |i| {
        fillstat(i, &d);
        const m = fcall.convD2M(&d, buf[n..]);
        if (off <= pos) {
            if (m <= fcall.BIT16SZ or m > cnt)
                break;
            n += m;
            cnt -= m;
        }
        pos += @intCast(m);
    }
    return n;
}

fn fsread(r: *Req) void {
    switch (r.fid.?.qid.path) {
        Qroot => r.ofcall.count = @intCast(readtopdir(r.rbuf, r.ifcall.offset, r.ifcall.count)),
        Qkbd => {
            kbdreqchan.send(r) catch {};
            return;
        },
        Qcons => {
            consreqchan.send(r) catch {};
            return;
        },
        Qkbmap => {
            kbmapread(r);
            return;
        },
        else => {
            respond(r, Ephase);
            return;
        },
    }
    respond(r, null);
}

fn fswrite(r: *Req) void {
    const f = r.fid.?;
    const p = r.ifcall.data[0..r.ifcall.count];
    switch (f.qid.path) {
        Qcons => {
            if (sys.write(1, p) != p.len) {
                p9.responderror(r);
                return;
            }
        },
        Qconsctl => {
            if (std.mem.startsWith(u8, p, "rawon"))
                ctlchan.send(Rawon) catch {}
            else if (std.mem.startsWith(u8, p, "rawoff"))
                ctlchan.send(Rawoff) catch {}
            else {
                respond(r, Ebadarg);
                return;
            }
        },
        Qkbdin, Qkbin => {
            if (f.aux == null)
                f.aux = p9.create9p(Scan);
            const scan: *Scan = @ptrCast(@alignCast(f.aux.?));
            if (f.qid.path == Qkbin) {
                for (p) |c|
                    kbdputsc(scan, c);
            } else {
                kbdin(scan, p);
            }
        },
        Qkbmap => {
            kbmapwrite(r);
            return;
        },
        else => {
            respond(r, Ephase);
            return;
        },
    }
    r.ofcall.count = r.ifcall.count;
    respond(r, null);
}

fn fsflush(r: *Req) void {
    switch (r.oldreq.?.fid.?.qid.path) {
        Qkbd => {
            kbdreqchan.send(r) catch {};
            return;
        },
        Qcons => {
            consreqchan.send(r) catch {};
            return;
        },
        else => {},
    }
    respond(r, null);
}

fn fsdestroyfid(f: *Fid) void {
    if (f.omode != -1) {
        switch (f.qid.path) {
            Qkbdin, Qkbin => {
                if (f.aux) |p| {
                    f.aux = null;
                    libc.allocator.destroy(@as(*Scan, @ptrCast(@alignCast(p))));
                }
            },
            Qkbmap => {
                if (f.aux) |p| {
                    f.aux = null;
                    const old: *[]u8 = @ptrCast(@alignCast(p));
                    libc.allocator.free(old.*);
                    libc.allocator.destroy(old);
                }
            },
            Qkbd => kbdopen -= 1,
            Qconsctl => {
                consctlopen -= 1;
                if (consctlopen == 0)
                    ctlchan.send(Rawoff) catch {};
            },
            else => {},
        }
    }
}

fn procopen(pid: u32, name: []const u8, mode: u32) isize {
    var buf: [128]u8 = undefined;
    return eopen(libc.sprint(&buf, "/proc/%d/%s", .{ pid, name }), mode);
}

fn elevate() void {
    if (debug)
        return;

    const fd = procopen(libc.getpid(), "ctl", sys.OWRITE);
    if (fd < 0)
        return;

    // get higher than normal priority
    _ = sys.write(fd, "pri 16\n");

    // always present in physical memory
    _ = sys.write(fd, "noswap\n");

    // dont let anybody kill us
    if (libc.dirfstat(libc.allocator, @intCast(fd))) |st_| {
        var st = st_;
        var nd = libc.nulldir();
        nd.mode = st.dir.mode & ~@as(u32, 0o222);
        libc.dirfwstat(@intCast(fd), &nd) catch {};
        st.deinit(libc.allocator);
    } else |_| {}

    _ = sys.close(fd);
}

fn fsstart(_: *p9.Srv) void {
    killfd = procopen(libc.getpid(), "notepg", sys.OWRITE);
    elevate();
    kbtabs = asciitab.ascii;
    _ = thread.proccreate(ctlproc, {}, STACK);
}

fn fsend(_: *p9.Srv) void {
    shutdown();
}

var fs: p9.Srv = .{
    .start = fsstart,
    .attach = fsattach,
    .walk1 = fswalk1,
    .open = fsopen,
    .read = fsread,
    .write = fswrite,
    .stat = fsstat,
    .flush = fsflush,
    .destroyfid = fsdestroyfid,
    .end = fsend,
};

fn usage() noreturn {
    libc.fprint(2, "usage: %s [ -qdD ] [ -s sname ] [ -m mntpnt ] [ file ]\n", .{libc.argv0});
    libc.exits("usage");
}

pub fn threadmain(argv_: []const []const u8) void {
    var buf: [256]u8 = undefined;

    var args = libc.Args.init(argv_);
    while (args.next()) |c| switch (c) {
        'd' => debug = true,
        'D' => p9.chatty9p += 1,
        's' => sname = args.value() orelse usage(),
        'm' => mntpt = args.value() orelse usage(),
        'q' => quiet = true,
        else => usage(),
    };
    const argv = args.rest();

    if (argv.len > 0)
        consfd = eopen(argv[0], sys.OREAD);

    kbdifd = sys.open(dev(&buf, "kbd"), sys.OREAD);
    if (kbdifd < 0) {
        scanfd = eopen(dev(&buf, "scancode"), sys.OREAD);
        ledsfd = eopen(dev(&buf, "leds"), sys.OWRITE);
    }
    mctlfd = eopen(dev(&buf, "mousectl"), sys.OWRITE);
    msinfd = eopen(dev(&buf, "mousein"), sys.OWRITE);

    notefd = procopen(libc.getpid(), "notepg", sys.OWRITE);

    consreqchan = .create(0);
    kbdreqchan = .create(0);

    keychan = .create(64);
    mctlchan = .create(64);
    ctlchan = .create(0);
    rawchan = .create(0);
    runechan = .create(256);
    conschan = .create(128);
    kbdchan = .create(128);
    intchan = .create(0);

    user = p9.estrdup9p(libc.getuser());
    p9.threadpostmountsrv(&fs, sname, mntpt, sys.MBEFORE);
    thread.threadexits(null);
}
