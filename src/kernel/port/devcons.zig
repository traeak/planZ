//! The console device, #c: cons, consctl, kmesg, kprint, time, bintime,
//! user, hostowner, sysname, sysstat, drivers, null, zero and friends.
//! from 9/port/devcons.c
//!
//! DIFF:
//!   - The output half of the C file (kmesgputs, putstrn0, putstrn,
//!     print, iprint, panic) is in print.zig, which writes straight to
//!     the consoles registered with addconsole.  It has no serialoq and
//!     no kprintoq.  What is left of them here:
//!       * serialoq is declared so that consactive, prflush and
//!         cpushutdown read as in C, but nothing writes to it.
//!       * kprintoq is fed by a console function that consinit
//!         registers.  Output therefore reaches /dev/kprint in addition
//!         to the screen and the serial port, where the C sends it to
//!         kprint instead of the screen.
//!       * a write to /dev/cons calls p9.putstrn, which does not wait
//!         for flow control as putstrn0(.., usewrite=1) does.
//!   - sysfatal and _assert are not ported: nothing in Zig calls them.
//!   - Errors are Zig error returns; the two waserror sites that only
//!     free a buffer became defer.
//!   - readnum and readstr take the destination as a slice; n is its
//!     length.  todget returns a struct, so readbintime's fall-through
//!     switch is a chain of ifs.
//!   - sysstat: counters a Mach does not have (tlbfault and tlbpurge on
//!     amd64) read as 0, and the loop stops if more processors are
//!     active than conf.nmach, where the C overruns its buffer.
//!   - reboot: "panic" panics without first writing to address 0;
//!     "rdb" calls consdebug only if one is set, there is no rdb.
//!   - iseve, hostdomain, userwrite, hostownerwrite and hostdomainwrite
//!     are in auth.c in 9front; they are here until auth.c is ported
//!     (M7).  hostownerwrite has no shrrenameuser: devshr is not ported.
//!
//! As in 9front there is no console input in the kernel: a read of
//! /dev/cons and a write of /dev/consctl fail with Egreg.  Keyboard and
//! serial input reach user space through their own devices, and kbdfs
//! serves the /dev/cons that programs read.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const tod = @import("tod.zig");
const portclock = @import("portclock.zig");
const qio = @import("qio.zig");
const chan = @import("chan.zig");
const pgrp = @import("pgrp.zig");
const parse = @import("parse.zig");
const devmod = @import("dev.zig");
const devsrv = @import("devsrv.zig");
const p9 = @import("print.zig");

const print = p9.print;
const iprint = p9.iprint;
const panic = p9.panic;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Proc = portdat.Proc;
const Queue = qio.Queue;
const Dirtab = devmod.Dirtab;
const Cmdtab = parse.Cmdtab;
const Mach = arch.Mach;

const HZ = arch.mem.HZ;
const MAXMACH = arch.mem.MAXMACH;
const NUMSIZE = portdat.NUMSIZE;
const READSTR = portdat.READSTR;
const KNAMELEN = portdat.KNAMELEN;
const DOMLEN = 48; // authentication domain name length, from authsrv.h

pub var consdebug: ?*const fn () void = null;

pub var serialoq: ?*Queue = null; // serial console output
pub var kprintoq: ?*Queue = null; // console output, for /dev/kprint
var kprintinuse: u32 = 0; // test and set whether /dev/kprint is open

/// DIFF: the empty string where the C has nil.
pub var sysname: []u8 = portdat.nostr;

// M7: auth.c
pub var hostdomain: [DOMLEN]u8 = @splat(0);

const CMreboot = 0;
const CMpanic = 1;
const CMrdb = 2;

const rebootmsg = [_]Cmdtab{
    .{ .index = CMreboot, .cmd = "reboot", .narg = 0 },
    .{ .index = CMpanic, .cmd = "panic", .narg = 0 },
    .{ .index = CMrdb, .cmd = "rdb", .narg = 0 },
};

const CMchdev = 0;

const drivermsg = [_]Cmdtab{
    .{ .index = CMchdev, .cmd = "chdev", .narg = 0 },
};

fn up() *Proc {
    return arch.up().?;
}

/// (ulong)offset in the C: file offsets of the small files here are
/// cut to 32 bits.
fn ul(off: i64) usize {
    return @as(u32, @truncate(@as(u64, @bitCast(off))));
}

/// strtoul(s, 0, 0): optional white space and sign, then a number in
/// base 16 after 0x, 8 after 0, 10 otherwise, up to the first character
/// that is not a digit.  Overflow wraps where the C saturates.
fn strtoul(s: []const u8) u32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or (s[i] >= '\t' and s[i] <= '\r'))) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var base: u32 = 10;
    if (i < s.len and s[i] == '0') {
        base = 8;
        if (i + 2 < s.len and (s[i + 1] == 'x' or s[i + 1] == 'X') and std.ascii.isHex(s[i + 2])) {
            base = 16;
            i += 2;
        }
    }
    var n: u32 = 0;
    while (i < s.len) : (i += 1) {
        const d = std.fmt.charToDigit(s[i], 16) catch break;
        if (d >= base) break;
        n = n *% base +% d;
    }
    return if (neg) 0 -% n else n;
}

pub fn printinit() void {}

pub fn consactive() bool {
    if (serialoq) |q|
        return qio.qlen(q) > 0;
    return false;
}

pub fn prflush() void {
    const now = arch.m().ticks;
    while (consactive()) {
        if (arch.m().ticks -% now >= HZ)
            break;
    }
}

// kmesgputs, putstrn0, putstrn, print, iprint and panic are in print.zig.

/// The console that carries kernel output to /dev/kprint; in the C this
/// is the kprintoq branch of putstrn0.
fn kprintputs(s: []const u8) void {
    const q = kprintoq orelse return;
    if (p9.panicking) // don't try to write to /dev/kprint
        return;
    if (!qio.qisclosed(q))
        _ = qio.qiwrite(q, s);
}

/// Print on the standard error of the current process, for messages
/// about what the process did.
pub fn pprint(comptime format: []const u8, args: anytype) usize {
    var buf: [2 * portdat.PRINTSIZE]u8 = undefined;

    const u = arch.up() orelse return 0;
    const fgrp = u.fgrp orelse return 0;

    if (fgrp.fd.len <= 2)
        return 0;
    const c = fgrp.fd[2] orelse return 0;
    if (c.flag & portdat.CMSG != 0 or (c.mode != lib.OWRITE and c.mode != lib.ORDWR))
        return 0;
    var n = fmt.snprint(&buf, "%s %lud: ", .{ u.text, u.pid }).len;
    n += fmt.snprint(buf[n..], format, args).len;

    _ = devmod.devtab[c.type].write(c, buf[0..n], c.offset) catch return 0;

    taslock.lock(&c.lock);
    c.offset += @intCast(n);
    taslock.unlock(&c.lock);

    return n;
}

const Qdir = 0;
const Qbintime = 1;
const Qcons = 2;
const Qconsctl = 3;
const Qcputime = 4;
const Qdrivers = 5;
const Qkmesg = 6;
const Qkprint = 7;
const Qhostdomain = 8;
const Qhostowner = 9;
const Qnull = 10;
const Qosversion = 11;
const Qpid = 12;
const Qppid = 13;
const Qrandom = 14;
const Qreboot = 15;
const Qsysname = 16;
const Qsysstat = 17;
const Qtime = 18;
const Quser = 19;
const Qzero = 20;
const Qmordor = 21;
const Qconfig = 22;

const VLNUMSIZE = 22;

const consdir = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qdir, .type = fcall.QTDIR }, .length = 0, .perm = fcall.DMDIR | 0o555 },
    .{ .name = "bintime", .qid = .{ .path = Qbintime }, .length = 24, .perm = 0o664 },
    .{ .name = "cons", .qid = .{ .path = Qcons }, .length = 0, .perm = 0o660 },
    .{ .name = "consctl", .qid = .{ .path = Qconsctl }, .length = 0, .perm = 0o220 },
    .{ .name = "cputime", .qid = .{ .path = Qcputime }, .length = 6 * NUMSIZE, .perm = 0o444 },
    .{ .name = "drivers", .qid = .{ .path = Qdrivers }, .length = 0, .perm = 0o666 },
    .{ .name = "hostdomain", .qid = .{ .path = Qhostdomain }, .length = DOMLEN, .perm = 0o664 },
    .{ .name = "hostowner", .qid = .{ .path = Qhostowner }, .length = 0, .perm = 0o664 },
    .{ .name = "kmesg", .qid = .{ .path = Qkmesg }, .length = 0, .perm = 0o440 },
    .{ .name = "kprint", .qid = .{ .path = Qkprint, .type = fcall.QTEXCL }, .length = 0, .perm = fcall.DMEXCL | 0o440 },
    .{ .name = "null", .qid = .{ .path = Qnull }, .length = 0, .perm = 0o666 },
    .{ .name = "osversion", .qid = .{ .path = Qosversion }, .length = 0, .perm = 0o444 },
    .{ .name = "pid", .qid = .{ .path = Qpid }, .length = NUMSIZE, .perm = 0o444 },
    .{ .name = "ppid", .qid = .{ .path = Qppid }, .length = NUMSIZE, .perm = 0o444 },
    .{ .name = "random", .qid = .{ .path = Qrandom }, .length = 0, .perm = 0o444 },
    .{ .name = "reboot", .qid = .{ .path = Qreboot }, .length = 0, .perm = 0o220 },
    .{ .name = "sysname", .qid = .{ .path = Qsysname }, .length = 0, .perm = 0o664 },
    .{ .name = "sysstat", .qid = .{ .path = Qsysstat }, .length = 0, .perm = 0o664 },
    .{ .name = "time", .qid = .{ .path = Qtime }, .length = NUMSIZE + 3 * VLNUMSIZE, .perm = 0o664 },
    .{ .name = "user", .qid = .{ .path = Quser }, .length = 0, .perm = 0o666 },
    .{ .name = "zero", .qid = .{ .path = Qzero }, .length = 0, .perm = 0o444 },
    .{ .name = "config", .qid = .{ .path = Qconfig }, .length = 0, .perm = 0o444 },
    .{ .name = "mordor", .qid = .{ .path = Qmordor }, .length = 0, .perm = 0o666 },
};

/// Copy to buf the part from offset off of val formatted as a decimal
/// number right-justified in size-1 columns and followed by a blank.
pub fn readnum(off: usize, buf: []u8, val: u32, size: usize) usize {
    var tmp: [64]u8 = @splat(' ');

    _ = fmt.snprint(&tmp, "%*lud", .{ size - 1, val });
    tmp[size - 1] = ' ';
    if (off >= size)
        return 0;
    var n = buf.len;
    if (off + n > size)
        n = size - off;
    @memcpy(buf[0..n], tmp[off..][0..n]);
    return n;
}

/// Copy to buf the part of str from offset off.
pub fn readstr(off: usize, buf: []u8, str: []const u8) usize {
    const size = str.len;
    if (off >= size)
        return 0;
    var n = buf.len;
    if (off + n > size)
        n = size - off;
    @memcpy(buf[0..n], str[off..][0..n]);
    return n;
}

fn consinit() void {
    tod.todinit();
    // M5: randominit()
    p9.addconsole(kprintputs); // DIFF: see kprintputs
}

fn consattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('c', spec);
}

fn conswalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &consdir, devmod.devgen);
}

fn consstat(c: *Chan, dp: []u8) Error!usize {
    return devmod.devstat(c, dp, &consdir, devmod.devgen);
}

fn consopen(c_: *Chan, omode: u32) Error!*Chan {
    c_.aux = null;
    const c = try devmod.devopen(c_, omode, &consdir, devmod.devgen);
    switch (c.qid.path) {
        Qkprint => {
            if (arch.tas(&kprintinuse) != 0) {
                c.flag &= ~@as(u16, portdat.COPEN);
                return error.Einuse;
            }
            if (kprintoq) |q| {
                qio.qreopen(q);
            } else {
                const q = qio.qopen(8 * 1024, qio.Qcoalesce, null, null) orelse {
                    c.flag &= ~@as(u16, portdat.COPEN);
                    return error.Enomem;
                };
                qio.qnoblock(q, true);
                kprintoq = q;
            }
            c.iounit = qio.qiomaxatomic;
        },
        else => {},
    }
    return c;
}

fn consclose(c: *Chan) Error!void {
    switch (c.qid.path) {
        // close of kprint allows other opens
        Qkprint => {
            if (c.flag & portdat.COPEN != 0) {
                kprintinuse = 0;
                qio.qhangup(kprintoq.?, null);
            }
        },
        else => {},
    }
}

/// A counter of a Mach as /dev/sysstat prints it; 0 if this
/// architecture does not keep it.
fn machstat(mp: *const Mach, comptime field: []const u8) u32 {
    if (!@hasField(Mach, field))
        return 0;
    return @truncate(@as(u64, @bitCast(@as(i64, @field(mp, field)))));
}

fn machclear(mp: *Mach, comptime field: []const u8) void {
    if (@hasField(Mach, field))
        @field(mp, field) = 0;
}

fn consread(c: *Chan, buf: []u8, off: i64) Error!usize {
    var tmp: [256]u8 = undefined;
    var n = buf.len;
    const offset = off;

    if (n == 0)
        return n;

    switch (c.qid.path) {
        Qdir => return devmod.devdirread(c, buf, &consdir, devmod.devgen),

        Qcons => return error.Egreg,

        Qcputime => {
            const k = ul(offset);
            if (k >= 6 * NUMSIZE)
                return 0;
            if (k + n > 6 * NUMSIZE)
                n = 6 * NUMSIZE - k;
            // easiest to format in a separate buffer and copy out
            var i: usize = 0;
            while (i < 6 and NUMSIZE * i < k + n) : (i += 1) {
                var l = up().time[i];
                if (i == portdat.TReal)
                    l = arch.MACHP(0).ticks -% l;
                _ = readnum(0, tmp[NUMSIZE * i ..][0..NUMSIZE], portclock.tk2ms(l), NUMSIZE);
            }
            @memcpy(buf[0..n], tmp[k..][0..n]);
            return n;
        },

        Qkmesg => {
            // This is unlocked to avoid tying up a process
            // that's writing to the buffer.  kmesg.n never
            // gets smaller, so worst case the reader will
            // see a slurred buffer.
            const kn = p9.kmesg.n;
            const o: u64 = @bitCast(off);
            if (o >= kn) {
                n = 0;
            } else {
                if (o + n > kn)
                    n = kn - @as(usize, @intCast(o));
                @memcpy(buf[0..n], p9.kmesg.buf[@intCast(o)..][0..n]);
            }
            return n;
        },

        Qkprint => return qio.qread(kprintoq.?, buf),

        Qpid => return readnum(ul(offset), buf, up().pid, NUMSIZE),

        Qppid => return readnum(ul(offset), buf, up().parentpid, NUMSIZE),

        Qtime => return readtime(ul(offset), buf),

        Qbintime => return readbintime(buf),

        Qhostowner => return readstr(ul(offset), buf, proc.eve),

        Qhostdomain => return readstr(ul(offset), buf, std.mem.sliceTo(&hostdomain, 0)),

        Quser => return readstr(ul(offset), buf, up().user),

        Qnull => return 0,

        // M5: configfile, the text of the kernel configuration, which
        // mkdevc generates in 9front; empty until conf/ provides one.
        Qconfig => return readstr(ul(offset), buf, ""),

        Qsysstat => {
            const b = alloc.snewslice(u8, arch.conf.nmach * (NUMSIZE * 11 + 1) + 1); // +1 for NUL
            defer alloc.free(b.ptr);
            var bp: usize = 0;
            for (0..MAXMACH) |id| {
                if (!arch.active.machs[id])
                    continue;
                if (bp + NUMSIZE * 10 + 1 > b.len)
                    break;
                const mp = arch.MACHP(id);
                const stats = [8]u32{
                    @intCast(id),
                    machstat(mp, "cs"),
                    machstat(mp, "intr"),
                    machstat(mp, "syscall"),
                    machstat(mp, "pfault"),
                    machstat(mp, "tlbfault"),
                    machstat(mp, "tlbpurge"),
                    machstat(mp, "load"),
                };
                for (stats) |v| {
                    _ = readnum(0, b[bp..][0..NUMSIZE], v, NUMSIZE);
                    bp += NUMSIZE;
                }
                var l: u32 = mp.perf.period;
                if (l == 0)
                    l = 1;
                _ = readnum(0, b[bp..][0..NUMSIZE], (mp.perf.avg_inidle *% 100) / l, NUMSIZE);
                bp += NUMSIZE;
                _ = readnum(0, b[bp..][0..NUMSIZE], (mp.perf.avg_inintr *% 100) / l, NUMSIZE);
                bp += NUMSIZE;
                b[bp] = '\n';
                bp += 1;
            }
            return readstr(ul(offset), buf, b[0..bp]);
        },

        Qsysname => return readstr(ul(offset), buf, sysname),

        // M5: randomread(buf, n), from 9/port/random.c
        Qrandom => return proc.errorf("random numbers not ported yet", .{}),

        Qdrivers => {
            const b = alloc.snewslice(u8, READSTR);
            defer alloc.free(b.ptr);
            var k: usize = 0;
            for (devmod.devtab, 0..) |d, i| {
                if (pgrp.devmasked(up().pgrp.?, @intCast(i)))
                    continue;
                k += fmt.snprint(b[k..], "#%C %s\n", .{ d.dc, d.name }).len;
            }
            return readstr(ul(offset), buf, b[0..k]);
        },

        Qzero => {
            @memset(buf, 0);
            return n;
        },

        Qmordor => return proc.errorf("one does not simply read from mordor", .{}),

        Qosversion => return readstr(ul(offset), buf, "2000"),

        else => {
            print("consread %#llux\n", .{c.qid.path});
            return error.Egreg;
        },
    }
}

fn conswrite(c: *Chan, va: []const u8, off: i64) Error!usize {
    var buf: [256]u8 = undefined;
    const n = va.len;
    var a = va;
    const offset = ul(off);

    switch (c.qid.path) {
        Qcons => {
            // Can't page fault in putstrn, so copy the data locally.
            while (a.len > 0) {
                const bp = @min(a.len, buf.len);
                @memcpy(buf[0..bp], a[0..bp]);
                p9.putstrn(buf[0..bp]);
                a = a[bp..];
            }
        },

        Qconsctl => return error.Egreg,

        Qtime => {
            if (!iseve())
                return error.Eperm;
            return writetime(a);
        },

        Qbintime => {
            if (!iseve())
                return error.Eperm;
            return writebintime(a);
        },

        Qhostowner => return hostownerwrite(a),

        Qhostdomain => return hostdomainwrite(a),

        Quser => return userwrite(a),

        Qnull => {},

        Qconfig => return error.Eperm,

        Qdrivers => {
            const cb = try parse.parsecmd(a);
            defer alloc.free(cb);

            const ct = try parse.lookupcmd(cb, &drivermsg);
            if (ct.index != CMchdev)
                return error.Ebadarg;
            if (cb.nf == 1)
                return error.Ebadarg;
            switch (if (cb.f[1].len > 0) cb.f[1][0] else 0) {
                '&' => {
                    if (cb.nf != 3)
                        return error.Ebadarg;
                    pgrp.devmask(up().pgrp.?, !(cb.f[1].len > 1 and cb.f[1][1] == '~'), cb.f[2]);
                },
                '~' => {
                    if (cb.nf != 2)
                        return error.Ebadarg;
                    pgrp.devmask(up().pgrp.?, true, "");
                },
                else => return error.Ebadarg,
            }
        },

        Qreboot => {
            if (!iseve())
                return error.Eperm;
            const cb = try parse.parsecmd(a);
            defer alloc.free(cb);

            const ct = try parse.lookupcmd(cb, &rebootmsg);
            switch (ct.index) {
                CMreboot => {
                    // M5: rebootcmd(cb.nf-1, cb.f+1), from 9/port/rebootcmd.c
                    return proc.errorf("reboot not ported yet", .{});
                },
                CMpanic => panic("/dev/reboot", .{}),
                CMrdb => {
                    // DIFF: there is no rdb to fall back on
                    if (consdebug) |f| f();
                },
                else => {},
            }
        },

        Qsysstat => {
            for (0..MAXMACH) |id| {
                if (arch.active.machs[id]) {
                    const mp = arch.MACHP(id);
                    machclear(mp, "cs");
                    machclear(mp, "intr");
                    machclear(mp, "syscall");
                    machclear(mp, "pfault");
                    machclear(mp, "tlbflush");
                    machclear(mp, "tlbfault");
                    machclear(mp, "tlbpurge");
                }
            }
        },

        Qsysname => {
            if (offset != 0)
                return error.Ebadarg;
            if (n == 0 or n >= buf.len)
                return error.Ebadarg;
            @memcpy(buf[0..n], a);
            buf[n] = 0;
            if (buf[n - 1] == '\n')
                buf[n - 1] = 0;
            proc.kstrdup(&sysname, std.mem.sliceTo(buf[0..n], 0));
        },

        Qmordor => return proc.errorf("one does not simply write into mordor", .{}),

        else => {
            print("conswrite: %#llux\n", .{c.qid.path});
            return error.Egreg;
        },
    }
    return n;
}

pub const consdevtab: devmod.Dev = .{
    .dc = 'c',
    .name = "cons",

    .init = consinit,
    .attach = consattach,
    .walk = conswalk,
    .stat = consstat,
    .open = consopen,
    .close = consclose,
    .read = consread,
    .write = conswrite,
};

fn gb32(p: []const u8) i32 {
    return @bitCast(std.mem.readInt(u32, p[0..4], .big));
}

fn gb64(p: []const u8) i64 {
    return @bitCast(std.mem.readInt(u64, p[0..8], .big));
}

fn pb64(p: []u8, v: i64) void {
    std.mem.writeInt(u64, p[0..8], @bitCast(v), .big);
}

const Ebadtimectl = "bad time control";

/// like the old #c/time but with added info.  Return
///
///     seconds nanoseconds fticks ftickshz uptime
fn readtime(off: usize, buf: []u8) usize {
    var str: [9 * NUMSIZE]u8 = undefined;

    const t = tod.todget();
    const s = fmt.snprint(&str, "%*lud %*llud %*llud %*llud %*llud ", .{
        NUMSIZE - 1,   @as(u32, @truncate(@as(u64, @bitCast(@divTrunc(t.nsec, 1000000000))))),
        VLNUMSIZE - 1, @as(u64, @bitCast(t.nsec)),
        VLNUMSIZE - 1, t.ticks,
        VLNUMSIZE - 1, t.hz,
        VLNUMSIZE - 1, @as(u64, @bitCast(t.uptime)),
    });
    return readstr(off, buf, s);
}

/// set the time in seconds
fn writetime(buf: []const u8) Error!usize {
    const n = buf.len;
    if (n >= 13)
        return proc.errorf(Ebadtimectl, .{});
    const i: i32 = @bitCast(strtoul(std.mem.sliceTo(buf, 0)));
    if (i <= 0)
        return proc.errorf(Ebadtimectl, .{});
    const now = @as(i64, i) * 1000000000;
    tod.todset(now, 0, 0);
    return n;
}

/// read binary time info.
fn readbintime(buf: []u8) usize {
    // DIFF: the C falls through the cases of a switch from the most
    // values asked for to the fewest
    const n: usize = @min(buf.len / 8, 4);
    if (n == 0)
        return 0;
    const t = tod.todget();
    if (n >= 4)
        pb64(buf[3 * 8 ..], t.uptime);
    if (n >= 3)
        pb64(buf[2 * 8 ..], @bitCast(t.hz));
    if (n >= 2)
        pb64(buf[1 * 8 ..], @bitCast(t.ticks));
    pb64(buf[0 * 8 ..], t.nsec);
    return n * 8;
}

/// set any of the following
///  - time in nanoseconds
///  - nsec trim applied over some seconds
///  - clock frequency
fn writebintime(buf: []const u8) Error!usize {
    const n = buf.len;
    if (n < 1)
        return proc.errorf(Ebadtimectl, .{});

    switch (buf[0]) {
        'n' => {
            if (n < 1 + 8)
                return proc.errorf(Ebadtimectl, .{});
            const delta = gb64(buf[1..]);
            tod.todset(delta, 0, 0);
        },
        'd' => {
            if (n < 1 + 8 + 4)
                return proc.errorf(Ebadtimectl, .{});
            const delta = gb64(buf[1..]);
            const period = gb32(buf[1 + 8 ..]);
            tod.todset(-1, delta, period);
        },
        'f' => {
            if (n < 1 + 8)
                return proc.errorf(Ebadtimectl, .{});
            const hz = gb64(buf[1..]);
            if (hz <= 0)
                return proc.errorf(Ebadtimectl, .{});
            tod.todsetfreq(@intCast(hz));
        },
        else => return proc.errorf(Ebadtimectl, .{}),
    }
    return n;
}

pub fn cpushutdown() void {
    const machno: usize = @intCast(arch.m().machno);
    const once = arch.active.machs[machno];
    arch.active.machs[machno] = false;
    arch.active.exiting = true;

    if (once)
        iprint("cpu%d: exiting\n", .{machno});

    // wait for any other processors to shutdown
    _ = arch.spllo();
    const tick = 2 * 1000 / HZ; // TK2MS(2)
    var ms: i32 = 5 * 1000;
    while (ms > 0) : (ms -= tick) {
        arch.delay(tick);
        if (std.mem.findScalar(bool, &arch.active.machs, true) == null and !consactive())
            break;
    }
}

// M7: auth.c.  The rest of this file is the part of 9/port/auth.c that
// the console files need.

/// return true if current user is eve
pub fn iseve() bool {
    return std.mem.eql(u8, proc.eve, up().user);
}

/// What kstrdup(&eve, ...) allocated, to free at the next change;
/// proc.eve starts out as a constant.
var evebuf: ?[*]u8 = null;

/// writing "none" to /dev/user makes the process none; nothing else
/// is allowed.
fn userwrite(a: []const u8) Error!usize {
    if (!std.mem.eql(u8, a, "none"))
        return error.Eperm;
    proc.procsetuser("none");
    return a.len;
}

/// called by devcons() for host owner/domain
fn hostownerwrite(a: []const u8) Error!usize {
    const n = a.len;

    if (!iseve())
        return error.Eperm;
    if (n == 0)
        return error.Ebadarg;
    if (n >= KNAMELEN)
        return error.Etoolong;
    const name = std.mem.sliceTo(a, 0);

    const new = alloc.smalloc(name.len + 1);
    @memcpy(new[0..name.len], name);

    proc.renameuser(proc.eve, new[0..name.len]);
    devsrv.srvrenameuser(proc.eve, new[0..name.len]);
    // DIFF: no shrrenameuser, devshr is not ported
    const old = evebuf;
    proc.eve = new[0..name.len];
    evebuf = new;
    alloc.free(old);
    proc.procsetuser(proc.eve);
    return n;
}

fn hostdomainwrite(a: []const u8) Error!usize {
    var buf: [DOMLEN]u8 = @splat(0);
    const n = a.len;

    if (!iseve())
        return error.Eperm;
    if (n == 0 or n >= DOMLEN)
        return error.Ebadarg;
    const s = std.mem.sliceTo(a, 0);
    @memcpy(buf[0..s.len], s);
    if (buf[0] == 0)
        return error.Ebadarg;
    hostdomain = buf;
    return n;
}
