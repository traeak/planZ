//! The device #r: /dev/rtc and /dev/nvram.
//! real time clock and non-volatile ram
//! from 9/pc/devrtc.c
//!
//! DIFF:
//!   - rtcinit is gone: it only reserved the two ports with ioalloc,
//!     and planZ keeps no table of I/O port ranges.
//!   - rtctime returns the seconds unsigned (the C returns long and its
//!     one caller casts to ulong).
//!   - rtc2sec stops at December when the clock's month register holds
//!     garbage; the C reads past the end of its table.
//!   - strtoul is a private copy of the base-0 conversion (decimal, 0x
//!     hexadecimal, leading-0 octal, saturating), started at a digit as
//!     the C's caller arranges.
//!   - Rtc's fields and the day tables are i32 where the C has int; the
//!     32-bit wrap-around of the C's ulong and long arithmetic is kept.

const std = @import("std");
const fcall = @import("fcall");
const l = @import("l.zig");
const portdat = @import("../../port/portdat.zig");
const lib = @import("../../port/lib.zig");
const taslock = @import("../../port/taslock.zig");
const proc = @import("../../port/proc.zig");
const devcons = @import("../../port/devcons.zig");
const devmod = @import("../../port/dev.zig");
const p9 = @import("../../port/print.zig");

const print = p9.print;
const inb = l.inb;
const outb = l.outb;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const readnum = devcons.readnum;

const Error = proc.Error;
const Lock = portdat.Lock;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Dirtab = devmod.Dirtab;

const Paddr = 0x70; // address port
const Pdata = 0x71; // data port

const Seconds = 0x00;
const Minutes = 0x02;
const Hours = 0x04;
const Mday = 0x07;
const Month = 0x08;
const Year = 0x09;
const Status = 0x0A;

const Nvoff = 128; // where usable nvram lives
const Nvsize = 256;

const Nbcd = 6;

const Rtc = struct {
    sec: i32 = 0,
    min: i32 = 0,
    hour: i32 = 0,
    mday: i32 = 0,
    mon: i32 = 0,
    year: i32 = 0,
};

const Qdir = 0;
const Qrtc = 1;
const Qnvram = 2;

const rtcdir = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qdir, .type = fcall.QTDIR }, .length = 0, .perm = 0o555 },
    .{ .name = "nvram", .qid = .{ .path = Qnvram }, .length = Nvsize, .perm = 0o664 },
    .{ .name = "rtc", .qid = .{ .path = Qrtc }, .length = 0, .perm = 0o664 },
};

fn rtcattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('r', spec);
}

fn rtcwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &rtcdir, devmod.devgen);
}

fn rtcstat(c: *Chan, dp: []u8) Error!usize {
    return devmod.devstat(c, dp, &rtcdir, devmod.devgen);
}

fn rtcopen(c: *Chan, omode_: u32) Error!*Chan {
    const omode = try devmod.openmode(omode_);
    switch (c.qid.path) {
        Qrtc => {
            if (!devcons.iseve() and omode != lib.OREAD)
                return error.Eperm;
        },
        Qnvram => {
            if (!devcons.iseve())
                return error.Eperm;
        },
        else => {},
    }
    return devmod.devopen(c, omode, &rtcdir, devmod.devgen);
}

fn rtcclose(_: *Chan) Error!void {}

fn GETBCD(bcdclock: *const [Nbcd]u8, o: usize) i32 {
    return @as(i32, bcdclock[o] & 0xf) + 10 * @as(i32, bcdclock[o] >> 4);
}

fn _rtctime() u32 {
    var bcdclock: [Nbcd]u8 = @splat(0);
    var rtc: Rtc = .{};

    // don't do the read until the clock is no longer busy
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        outb(Paddr, Status);
        if (inb(Pdata) & 0x80 != 0)
            continue;

        // read clock values
        outb(Paddr, Seconds);
        bcdclock[0] = inb(Pdata);
        outb(Paddr, Minutes);
        bcdclock[1] = inb(Pdata);
        outb(Paddr, Hours);
        bcdclock[2] = inb(Pdata);
        outb(Paddr, Mday);
        bcdclock[3] = inb(Pdata);
        outb(Paddr, Month);
        bcdclock[4] = inb(Pdata);
        outb(Paddr, Year);
        bcdclock[5] = inb(Pdata);

        outb(Paddr, Status);
        if (inb(Pdata) & 0x80 == 0)
            break;
    }

    //
    //  convert from BCD
    //
    rtc.sec = GETBCD(&bcdclock, 0);
    rtc.min = GETBCD(&bcdclock, 1);
    rtc.hour = GETBCD(&bcdclock, 2);
    rtc.mday = GETBCD(&bcdclock, 3);
    rtc.mon = GETBCD(&bcdclock, 4);
    rtc.year = GETBCD(&bcdclock, 5);

    //
    //  the world starts jan 1 1970
    //
    if (rtc.year < 70)
        rtc.year += 2000
    else
        rtc.year += 1900;
    return rtc2sec(&rtc);
}

var nvrtlock: Lock = .{};

pub fn rtctime() u32 {
    ilock(&nvrtlock);

    // loop till we get two reads in a row the same
    var t = _rtctime();
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const ot = t;
        t = _rtctime();
        if (ot == t)
            break;
    }
    if (i == 100) print("we are boofheads\n", .{});

    iunlock(&nvrtlock);

    return t;
}

fn rtcread(c: *Chan, buf: []u8, off: i64) Error!usize {
    var offset: u32 = @truncate(@as(u64, @bitCast(off)));

    if (c.qid.type & fcall.QTDIR != 0)
        return devmod.devdirread(c, buf, &rtcdir, devmod.devgen);

    switch (c.qid.path) {
        Qrtc => return readnum(offset, buf, rtctime(), 12),
        Qnvram => {
            if (offset >= Nvsize)
                return 0;
            var n = buf.len;
            if (offset + n > Nvsize)
                n = Nvsize - offset;
            offset += Nvoff;
            for (buf[0..n]) |*a| {
                a.* = nvramread(offset);
                offset += 1;
            }
            return n;
        },
        else => {},
    }
    return error.Ebadarg;
}

fn PUTBCD(bcdclock: *[Nbcd]u8, n: i32, o: usize) void {
    bcdclock[o] = @intCast(@rem(n, 10) | (@rem(@divTrunc(n, 10), 10) << 4));
}

/// strtoul(s, 0, 0) of a string that starts with a digit.
fn strtoul(s: []const u8) u32 {
    var i: usize = 0;
    var base: u64 = 10;
    if (s.len > 0 and s[0] == '0') {
        base = 8;
        if (s.len > 2 and (s[1] == 'x' or s[1] == 'X') and std.ascii.isHex(s[2])) {
            base = 16;
            i = 2;
        }
    }
    var n: u64 = 0;
    while (i < s.len) : (i += 1) {
        const d = std.fmt.charToDigit(s[i], @intCast(base)) catch break;
        n = n * base + d;
        if (n > std.math.maxInt(u32))
            n = std.math.maxInt(u32);
    }
    return @intCast(n);
}

fn rtcwrite(c: *Chan, buf: []const u8, off: i64) Error!usize {
    var rtc: Rtc = .{};
    var bcdclock: [Nbcd]u8 = @splat(0);
    var offset: u32 = @truncate(@as(u64, @bitCast(off)));

    if (offset != 0)
        return error.Ebadarg;

    switch (c.qid.path) {
        Qrtc => {
            //
            //  read the time
            //
            if (buf.len >= 32)
                return error.Ebadarg;
            // strncpy into sbuf in the C: the string ends at a NUL
            var cp: []const u8 = std.mem.sliceTo(buf, 0);
            while (cp.len > 0) : (cp = cp[1..]) {
                if (cp[0] >= '0' and cp[0] <= '9')
                    break;
            }
            const secs = strtoul(cp);

            //
            //  convert to bcd
            //
            sec2rtc(secs, &rtc);
            PUTBCD(&bcdclock, rtc.sec, 0);
            PUTBCD(&bcdclock, rtc.min, 1);
            PUTBCD(&bcdclock, rtc.hour, 2);
            PUTBCD(&bcdclock, rtc.mday, 3);
            PUTBCD(&bcdclock, rtc.mon, 4);
            PUTBCD(&bcdclock, rtc.year, 5);

            //
            //  write the clock
            //
            ilock(&nvrtlock);
            outb(Paddr, Seconds);
            outb(Pdata, bcdclock[0]);
            outb(Paddr, Minutes);
            outb(Pdata, bcdclock[1]);
            outb(Paddr, Hours);
            outb(Pdata, bcdclock[2]);
            outb(Paddr, Mday);
            outb(Pdata, bcdclock[3]);
            outb(Paddr, Month);
            outb(Pdata, bcdclock[4]);
            outb(Paddr, Year);
            outb(Pdata, bcdclock[5]);
            iunlock(&nvrtlock);
            return buf.len;
        },
        Qnvram => {
            if (offset >= Nvsize)
                return 0;
            var n = buf.len;
            if (offset + n > Nvsize)
                n = Nvsize - offset;
            offset += Nvoff;
            for (buf[0..n]) |a| {
                nvramwrite(offset, a);
                offset += 1;
            }
            return n;
        },
        else => {},
    }
    return error.Ebadarg;
}

pub const rtcdevtab: devmod.Dev = .{
    .dc = 'r',
    .name = "rtc",

    .attach = rtcattach,
    .walk = rtcwalk,
    .stat = rtcstat,
    .open = rtcopen,
    .close = rtcclose,
    .read = rtcread,
    .write = rtcwrite,
};

const SEC2MIN = 60;
const SEC2HOUR = 60 * SEC2MIN;
const SEC2DAY = 24 * SEC2HOUR;

//
//  days per month plus days/year
//
const dmsize = [_]i32{
    365, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
};
const ldmsize = [_]i32{
    366, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
};

//
//  return the days/month for the given year
//
fn yrsize(y: i32) *const [13]i32 {
    if (@rem(y, 4) == 0 and (@rem(y, 100) != 0 or @rem(y, 400) == 0))
        return &ldmsize
    else
        return &dmsize;
}

/// n * unit added to a ulong, as the C's 32-bit arithmetic does it.
fn addsecs(secs: u32, n: i32, unit: i32) u32 {
    return secs +% @as(u32, @bitCast(n *% unit));
}

//
//  compute seconds since Jan 1 1970
//
fn rtc2sec(rtc: *const Rtc) u32 {
    var secs: u32 = 0;

    //
    //  seconds per year
    //
    var i: i32 = 1970;
    while (i < rtc.year) : (i += 1) {
        const d2m = yrsize(i);
        secs = addsecs(secs, d2m[0], SEC2DAY);
    }

    //
    //  seconds per month
    //
    const d2m = yrsize(rtc.year);
    i = 1;
    while (i < rtc.mon and i < d2m.len) : (i += 1) // DIFF: the bound
        secs = addsecs(secs, d2m[@intCast(i)], SEC2DAY);

    secs = addsecs(secs, rtc.mday - 1, SEC2DAY);
    secs = addsecs(secs, rtc.hour, SEC2HOUR);
    secs = addsecs(secs, rtc.min, SEC2MIN);
    secs = addsecs(secs, rtc.sec, 1);

    return secs;
}

//
//  compute rtc from seconds since Jan 1 1970
//
fn sec2rtc(secs: u32, rtc: *Rtc) void {
    //
    // break initial number into days
    //
    var hms: i32 = @bitCast(secs % SEC2DAY);
    var day: i32 = @bitCast(secs / SEC2DAY);
    if (hms < 0) {
        hms += SEC2DAY;
        day -= 1;
    }

    //
    // generate hours:minutes:seconds
    //
    rtc.sec = @rem(hms, 60);
    var d: i32 = @divTrunc(hms, 60);
    rtc.min = @rem(d, 60);
    d = @divTrunc(d, 60);
    rtc.hour = d;

    //
    // year number
    //
    if (day >= 0) {
        d = 1970;
        while (day >= yrsize(d)[0]) : (d += 1)
            day -= yrsize(d)[0];
    } else {
        d = 1970;
        while (day < 0) : (d -= 1)
            day += yrsize(d - 1)[0];
    }
    rtc.year = d;

    //
    // generate month
    //
    const d2m = yrsize(rtc.year);
    d = 1;
    while (day >= d2m[@intCast(d)]) : (d += 1)
        day -= d2m[@intCast(d)];
    rtc.mday = day + 1;
    rtc.mon = d;

    return;
}

pub fn nvramread(addr_: u32) u8 {
    ilock(&nvrtlock);
    const addr: u8 = @truncate(addr_);
    outb(Paddr, addr);
    const data = inb(Pdata);
    if (addr & 0x80 != 0) {
        // clear NMI disable bit
        outb(Paddr, 0);
        _ = inb(Pdata);
    }
    iunlock(&nvrtlock);

    return data;
}

pub fn nvramwrite(addr_: u32, data: u8) void {
    ilock(&nvrtlock);
    const addr: u8 = @truncate(addr_);
    outb(Paddr, addr);
    outb(Pdata, data);
    if (addr & 0x80 != 0) {
        // clear NMI disable bit
        outb(Paddr, 0);
        _ = inb(Pdata);
    }
    iunlock(&nvrtlock);
}

test "rtc2sec and sec2rtc" {
    const t = std.testing;
    const cases = [_]struct { secs: u32, rtc: Rtc }{
        .{ .secs = 0, .rtc = .{ .sec = 0, .min = 0, .hour = 0, .mday = 1, .mon = 1, .year = 1970 } },
        .{ .secs = 86399, .rtc = .{ .sec = 59, .min = 59, .hour = 23, .mday = 1, .mon = 1, .year = 1970 } },
        // 2000-02-29 12:34:56, a leap day in a year divisible by 400
        .{ .secs = 951827696, .rtc = .{ .sec = 56, .min = 34, .hour = 12, .mday = 29, .mon = 2, .year = 2000 } },
        // 2026-11-10 00:00:00
        .{ .secs = 1794268800, .rtc = .{ .sec = 0, .min = 0, .hour = 0, .mday = 10, .mon = 11, .year = 2026 } },
        // 2038-01-19 03:14:08, one past the largest signed 32-bit time
        .{ .secs = 2147483648, .rtc = .{ .sec = 8, .min = 14, .hour = 3, .mday = 19, .mon = 1, .year = 2038 } },
        // 2106-02-07 06:28:15, the last second
        .{ .secs = 4294967295, .rtc = .{ .sec = 15, .min = 28, .hour = 6, .mday = 7, .mon = 2, .year = 2106 } },
    };
    for (cases) |c| {
        var rtc: Rtc = .{};
        sec2rtc(c.secs, &rtc);
        try t.expectEqual(c.rtc, rtc);
        try t.expectEqual(c.secs, rtc2sec(&c.rtc));
    }
    // a month register of garbage does not run off the table
    _ = rtc2sec(&.{ .mday = 1, .mon = 165, .year = 2000 });
}

test "bcd" {
    const t = std.testing;
    var b: [Nbcd]u8 = @splat(0);
    PUTBCD(&b, 59, 0);
    PUTBCD(&b, 2026, 5);
    try t.expectEqual(@as(u8, 0x59), b[0]);
    try t.expectEqual(@as(u8, 0x26), b[5]);
    try t.expectEqual(@as(i32, 59), GETBCD(&b, 0));
    try t.expectEqual(@as(i32, 26), GETBCD(&b, 5));
    try t.expectEqual(@as(i32, 165), GETBCD(&.{ 0xff, 0, 0, 0, 0, 0 }, 0));
}

test "strtoul" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 1794268800), strtoul("1794268800\n"));
    try t.expectEqual(@as(u32, 0x1f), strtoul("0x1f"));
    try t.expectEqual(@as(u32, 8), strtoul("010"));
    try t.expectEqual(@as(u32, 0), strtoul(""));
    try t.expectEqual(@as(u32, 0xffffffff), strtoul("99999999999"));
}
