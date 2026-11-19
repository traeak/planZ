//! nusb/kb - USB Human Interaction Device: keyboard and mouse.
//!
//! Mouse events are converted to the format of mouse(3)
//! on mousein file.
//! Keyboard keycodes are translated to scan codes and sent to kbdfs(8)
//! on kbin file.
//! from /sys/src/cmd/nusb/kb/kb.c (hid.h is usbkb/hid.zig; the tables
//! are in usbkb/tab.zig)
//!
//! usage: kb [-d] devid
//!
//! The report descriptor is the device's, and every number in it is
//! taken as it comes.  Where the C then does what C leaves open, this
//! does what the amd64 code of 6c does, so that the two give the same
//! for any descriptor:
//!   - signext shifts by 32 minus the size taken modulo 32;
//!   - sums and products of the descriptor's numbers wrap;
//!   - an absolute position at the logical maximum is 2^31, which is
//!     the most negative number in the message to mousein.
//!
//! Fixed from C, read and not shown (stock dies or reads what is not
//! its own in each):
//!   - A key code over 511 (an array item of more than 9 bits, or of
//!     the consumer page with more than 8) indexed past the scan code
//!     table.  It is no key.
//!   - A report size that is negative, or a sum of sizes past 2^31,
//!     made getbits read before the report.  It reads 0.
//!   - An absolute axis whose logical minimum and maximum are equal
//!     divided by 0, and a relative one whose physical range is the
//!     whole of 32 bits could divide the most negative number by -1:
//!     a trap either way.  The first gives 0; the second wraps.
//!   - Push and Collection items call repparse1 again, each on the
//!     stack: a descriptor of a thousand of them went through the 32K
//!     the proc has.  Past 16 deep the rest of the descriptor is not
//!     read (the descriptors there are go three or four deep).
//!   - A delay or repeat of 0 written to the ctl file was sent to the
//!     proc that sleeps as its message to end, and it freed the
//!     channel the repeat proc went on using.  0 is sent as 1.
//!
//! Kept from C: a collection's usage is read from l[Nu], the 246th
//! place of the list of usages, where the first (l[Nl]) is meant: it
//! is the usage page alone unless an item has that many usages.  So a
//! touch screen's finger (0x0D0022) is never known as one.
//!
//! DIFF:
//!   - hdsetup returns a bool.
//!   - threadsetname's text is made with sprint.

const std = @import("std");
const libc = @import("libc");
const thread = @import("thread");
const p9 = @import("9p");
const usb = @import("usb");
const hid = @import("usbkb/hid.zig");
const tab = @import("usbkb/tab.zig");
const sys = libc.sys;
const fcall = libc.fcall;
const chan = thread.chan;

pub const main = thread.main;

const Dev = usb.Dev;
const Ep = usb.Ep;
const Iface = usb.Iface;
const Req = p9.Req;
const Channel = thread.Channel;
const Alt = thread.Alt;
const usbcmd = usb.usbcmd;

const Awakemsg = 0xdeaddead;
const Diemsg = 0xbeefbeef;
const Rawon = 0x0defaced;
const Dwcidle = 8;

const user = "kb";

const Hiddev = struct {
    dev: ?*Dev = null, // usb device
    ep: ?*Dev = null, // endpoint to get events

    minfd: i32 = -1,
    kinfd: i32 = -1,

    idle: u32 = 0,

    repeatc: ?*Channel = null, // only for keyboard

    // report descriptor
    nrep: usize = 0,

    // use odd size as some devices ignore the high byte of
    // wLength in control transfer reads.
    rep: [1024 - 1]u8 = undefined,
};

const Hidslot = struct {
    valid: bool = false,
    usage: i32 = 0,
    id: i32 = 0,
    oor: bool = false,

    abs: i32 = 0, // for xyz

    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,

    b: i32 = 0,
    m: i32 = 0,

    w: i32 = 0,
    h: i32 = 0,
};

const Hidreport = struct {
    ns: usize = 0,
    s: [16]Hidslot = @splat(.{}),

    nk: usize = 0,
    k: [hid.Nkey]u16 = @splat(0),

    o: i32 = 0,
    /// how much of p was read (the C's e is p + this)
    e: usize = 0,
    p: [128]u8 = @splat(0),
};

// Plan 9 keyboard driver constants.

// Scan codes (see kbd.c)
const SCesc1 = 0xe0; // first of a 2-character sequence
const SCesc2 = 0xe1;
const Consumer = 0x100; // the key is on consumer page
const Keyup = 0x80; // flag bit
const Keymask = 0x7f; // regular scan code bits

/// scan codes >= 0x80 are extended (E0 XX)
fn isext(sc: u8) bool {
    return sc >= 0x80;
}

/// The scan code of a key code; none (0) for one past the table.
fn sctab(k: u16) u8 {
    return if (k < tab.sctab.len) tab.sctab[k] else 0;
}

var debug: i32 = 0;
var kbdelay: i32 = 500;
var kbrepeat: i32 = 100;
var havekbd: bool = false;

fn signext(v: i32, bits: i32) i32 {
    const s: u5 = @truncate(@as(u32, @bitCast(32 -% bits)));
    return (v << s) >> s;
}

/// The bits of the report p[0..e] from bit off on.
fn getbits(p: []const u8, e: usize, bits_: i32, off_: i32) i32 {
    if (off_ < 0)
        return 0;
    var i: usize = @intCast(@divTrunc(off_, 8));
    var off: u3 = @intCast(@mod(off_, 8));
    var bits: u32 = @bitCast(bits_);
    var v: u32 = 0;
    var m: u32 = 1;
    if (i < e) {
        while (bits != 0) : (bits -= 1) {
            if (p[i] & (@as(u8, 1) << off) != 0)
                v |= m;
            if (off == 7) {
                i += 1;
                if (i >= e)
                    break;
                off = 0;
            } else off += 1;
            m <<= 1;
        }
    }
    return @bitCast(v);
}

const Ng = hid.RepCnt + 1;
const UsgCnt = hid.Delim + 1; // fake
const Nl = UsgCnt + 1;
const Nu = 256;

/// How deep Push and Collection items go.
const Maxdepth = 16;

const Repfn = *const fn (t: i32, v: i32, g: *[Ng]i32, l: *[Nl + Nu]i32, c: i32, a: *Hidreport) void;

/// d is where in the descriptor rep to go on; returns where it
/// stopped.
fn repparse1(rep: []const u8, d_: usize, g: *[Ng]i32, l: *[Nl + Nu]i32, c: i32, f: Repfn, a: *Hidreport, depth: u32) usize {
    var d = d_;
    const e = rep.len;

    while (d < e) {
        var v: i32 = 0;
        var t: i32 = rep[d];
        d += 1;
        const z = t & 3;
        t >>= 2;
        const k = t & 3;
        t >>= 2;
        switch (z) {
            3 => {
                d += 4;
                if (d > e) continue;
                v = @bitCast(@as(u32, rep[d - 4]) | @as(u32, rep[d - 3]) << 8 | @as(u32, rep[d - 2]) << 16 | @as(u32, rep[d - 1]) << 24);
            },
            2 => {
                d += 2;
                if (d > e) continue;
                v = @as(i32, rep[d - 2]) | @as(i32, rep[d - 1]) << 8;
            },
            1 => {
                d += 1;
                if (d > e) continue;
                v = rep[d - 1];
            },
            else => {},
        }
        switch (k) {
            0 => { // main item
                switch (t) {
                    hid.Collection => {
                        @memset(l[0..Nl], 0);
                        // Kept from C: l[Nu]; see the top of the file
                        const i = l[Nu] | g[hid.UsagPg] << 16;
                        l[hid.Usage] = i;
                        f(t, v, g, l, c, a);

                        if (depth >= Maxdepth)
                            return e;
                        d = repparse1(rep, d, g, l, v, f, a, depth + 1);

                        l[hid.Usage] = i;
                        f(hid.CollectionEnd, v, g, l, c, a);
                        continue;
                    },
                    hid.CollectionEnd => return d,
                    hid.Input, hid.Output, hid.Feature => {
                        if (l[UsgCnt] == 0 and l[hid.UsagMin] != 0 and l[hid.UsagMin] < l[hid.UsagMax]) {
                            var i = l[hid.UsagMin];
                            while (i <= l[hid.UsagMax] and l[UsgCnt] < Nu) : (i +%= 1) {
                                l[@intCast(Nl + l[UsgCnt])] = i;
                                l[UsgCnt] += 1;
                            }
                        }
                        var i: i32 = 0;
                        while (i < g[hid.RepCnt]) : (i += 1) {
                            l[hid.Usage] = if (i < l[UsgCnt]) l[@intCast(Nl + i)] else 0;
                            f(t, v, g, l, c, a);
                        }
                    },
                    else => {},
                }
                @memset(l[0..Nl], 0);
                continue;
            },
            1 => { // global item
                if (t == hid.Push) {
                    if (depth >= Maxdepth)
                        return e;
                    var w: [Ng]i32 = g.*;
                    d = repparse1(rep, d, &w, l, c, f, a, depth + 1);
                } else if (t == hid.Pop) {
                    return d;
                } else if (t < Ng) {
                    if (t == hid.RepId)
                        v &= 0xFF
                    else if (t == hid.UsagPg)
                        v &= 0xFFFF
                    else if (t != hid.RepSize and t != hid.RepCnt) {
                        v = signext(v, if (z == 3) 32 else 8 * z);
                    }
                    g[@intCast(t)] = v;
                }
                continue;
            },
            2 => { // local item
                if (l[hid.Delim] != 0)
                    continue;
                if (t == hid.Delim) {
                    l[hid.Delim] = 1;
                } else if (t < hid.Delim) {
                    if (z != 3 and (t == hid.Usage or t == hid.UsagMin or t == hid.UsagMax))
                        v = (v & 0xFFFF) | (g[hid.UsagPg] << 16);
                    l[@intCast(t)] = v;
                    if (t == hid.Usage and l[UsgCnt] < Nu) {
                        l[@intCast(Nl + l[UsgCnt])] = v;
                        l[UsgCnt] += 1;
                    }
                }
                continue;
            },
            else => { // long item
                if (t == 15)
                    d += @intCast(v & 0xFF);
                continue;
            },
        }
    }
    return d;
}

/// parse the report descriptor and call f for every (Input, Output
/// and Feature) main item as often as it would appear in the report
/// data packet.
fn repparse(rep: []const u8, f: Repfn, a: *Hidreport) void {
    var l: [Nl + Nu]i32 = @splat(0);
    var g: [Ng]i32 = @splat(0);

    _ = repparse1(rep, 0, &g, &l, 0, f, a, 0);
}

fn setproto(f: *Hiddev, iface: *Iface) libc.Error!void {
    const d = f.dev.?;
    const id: u32 = @intCast(iface.id);
    var proto: u32 = undefined;

    _ = usbcmd(d, usb.Rh2d | usb.Rclass | usb.Riface, hid.Setidle, f.idle << 8, id, null) catch {};

    f.nrep = usbcmd(d, usb.Rd2h | usb.Rstd | usb.Riface, usb.Rgetdesc, usb.Dreport << 8, id, &f.rep) catch 0;
    if (f.nrep > 0) {
        if (debug != 0) {
            libc.fprint(2, "report descriptor:", .{});
            for (f.rep[0..f.nrep], 0..) |b, i| {
                if (i % 8 == 0)
                    libc.fprint(2, "\n\t", .{});
                libc.fprint(2, "%#2.2ux ", .{b});
            }
            libc.fprint(2, "\n", .{});
        }
        proto = hid.Reportproto;
    } else {
        switch (iface.csp) {
            hid.KbdCSP => {
                f.nrep = tab.kbdbootrep.len;
                @memcpy(f.rep[0..f.nrep], &tab.kbdbootrep);
            },
            hid.PtrCSP => {
                f.nrep = tab.ptrbootrep.len;
                @memcpy(f.rep[0..f.nrep], &tab.ptrbootrep);
            },
            else => {
                libc.werrstr("no report descriptor", .{});
                return error.Plan9;
            },
        }
        proto = hid.Bootproto;
    }

    // if a HID's subclass code is 1 (boot mode), it will support
    // setproto, otherwise it is not guaranteed to.
    if (usb.Subclass(iface.csp) != 1)
        return;

    _ = try usbcmd(d, usb.Rh2d | usb.Rclass | usb.Riface, hid.Setproto, proto, id, null);
}

fn hdfree(f: *Hiddev) void {
    if (f.kinfd >= 0)
        _ = sys.close(f.kinfd);
    if (f.minfd >= 0)
        _ = sys.close(f.minfd);
    if (f.ep != null)
        usb.closedev(f.ep);
    if (f.dev != null)
        usb.closedev(f.dev);
    libc.allocator.destroy(f);
}

fn hdfatal(f: *Hiddev, sts: ?[]const u8) noreturn {
    if (sts) |s|
        libc.fprint(2, "%s: fatal: %s\n", .{ libc.argv0, s })
    else
        libc.fprint(2, "%s: exiting\n", .{libc.argv0});
    if (f.repeatc) |c|
        _ = chan.sendul(c, Diemsg);
    hdfree(f);
    thread.threadexits(sts);
}

fn putscan(f: *Hiddev, sc: u8, up: u8) void {
    var s = [2]u8{ SCesc1, 0 };

    if (sc == 0)
        return;
    s[1] = up | (sc & Keymask);
    if (isext(sc))
        _ = sys.write(f.kinfd, &s)
    else
        _ = sys.write(f.kinfd, s[1..]);
}

fn sleepproc(c: *Channel) void {
    thread.threadsetname("sleepproc");
    while (true) {
        const ms = chan.recvul(c);
        if (ms == 0)
            break;
        libc.sleep(ms) catch {};
    }
    chan.chanfree(c);
}

/// What is sent to sleepproc for a time: 0 is its message to end.
fn sleeptime(ms: i32) u32 {
    const t: u32 = @bitCast(ms);
    return if (t == 0) 1 else t;
}

fn repeatproc(f: *Hiddev) void {
    var l: u32 = undefined;
    var t: u32 = undefined;
    var a: [3]Alt = undefined;

    const repeatc = f.repeatc.?;
    thread.threadsetname("repeatproc");

    const sleepc = chan.chancreate(@sizeOf(u32), 0).?;
    _ = thread.proccreate(sleepproc, sleepc, hid.Stack);

    a[0] = .{ .c = repeatc, .v = @ptrCast(&l), .op = .CHANRCV };
    a[1] = .{ .c = sleepc, .v = @ptrCast(&t), .op = .CHANSND };
    a[2] = .{ .op = .CHANEND };

    l = Awakemsg;
    while (l != Diemsg) {
        if (l == Awakemsg) {
            l = chan.recvul(repeatc);
            continue;
        }
        const sc: u8 = @truncate(l);
        t = sleeptime(kbdelay);
        if (thread.alt(&a) == 1) {
            t = sleeptime(kbrepeat);
            while (thread.alt(&a) == 1)
                putscan(f, sc, 0);
        }
    }
    _ = chan.sendul(sleepc, 0);
    chan.chanfree(repeatc);
    thread.threadexits(null);
}

fn stoprepeat(f: *Hiddev) void {
    _ = chan.sendul(f.repeatc.?, Awakemsg);
}

fn startrepeat(f: *Hiddev, sc: u8) void {
    _ = chan.sendul(f.repeatc.?, sc);
}

fn hidparse(t: i32, f: i32, g: *[Ng]i32, l: *[Nl + Nu]i32, _: i32, p: *Hidreport) void {
    var s = &p.s[p.ns];
    var m: i32 = undefined;

    switch (t) {
        hid.Input => {
            if (g[hid.RepId] != 0) {
                if (p.p[0] != g[hid.RepId]) {
                    p.o = 0;
                    return;
                }
                if (p.o < 8)
                    p.o = 8; // skip report id byte
            }
        },
        hid.Collection => {
            if (g[hid.RepId] != 0 and p.p[0] != g[hid.RepId])
                return;
            if (s.valid and p.ns < p.s.len - 1) {
                p.ns += 1;
                s = &p.s[p.ns];
            }
            s.* = .{};
            s.usage = l[hid.Usage];
            s.id = @as(i32, @intCast(p.ns + 1)) << 8 | g[hid.RepId];
            return;
        },
        hid.CollectionEnd => {
            if (g[hid.RepId] != 0 and p.p[0] != g[hid.RepId])
                return;
            if (!s.valid or s.usage != l[hid.Usage])
                return;
            // if out of range or touchscreen finger not touching, ignore the slot
            if (s.oor or s.usage == 0x0D0022 and s.b == 0)
                s.valid = false;
            return;
        },
        else => return,
    }
    var v = getbits(&p.p, p.e, g[hid.RepSize], p.o);
    p.o +%= g[hid.RepSize];

    if ((f & (hid.Fconst | hid.Fdata)) != hid.Fdata)
        return;

    const usg = l[hid.Usage];
    if (debug > 1)
        libc.fprint(2, "hidparse: t=%x f=%x usage=%x v=%x\n", .{ t, f, usg, v });

    const cp = (usg >> 16) == 0x0c;
    if (cp or (usg >> 16) == 0x07) { // consumer/keycode
        if ((f & (hid.Fvar | hid.Farray)) == hid.Fvar) {
            if (v != 0) v = usg & 0xFF;
        }
        if (p.nk < p.k.len and v != 0) {
            p.k[p.nk] = @truncate(@as(u32, @bitCast(v | @as(i32, @intFromBool(cp)) * Consumer)));
            p.nk += 1;
        }
        return;
    }

    if (g[hid.LogiMin] < 0)
        v = signext(v, g[hid.RepSize]);
    if ((f & (hid.Fvar | hid.Farray)) == hid.Fvar and v >= g[hid.LogiMin] and v <= g[hid.LogiMax]) {
        // we use logical units below, but need the
        // sign to be correct for mouse deltas.
        // so if physical unit is signed but logical
        // is unsigned, convert to signed but in logical
        // units.
        if ((f & (hid.Fabs | hid.Frel)) == hid.Frel and
            g[hid.PhysMin] < 0 and g[hid.PhysMax] > 0 and
            g[hid.LogiMin] >= 0 and g[hid.LogiMin] < g[hid.LogiMax])
        {
            const num: i64 = g[hid.PhysMax] *% (g[hid.LogiMax] -% g[hid.LogiMin]);
            const den: i64 = g[hid.PhysMax] -% g[hid.PhysMin];
            v -%= @truncate(@divTrunc(num, den));
        }

        button: {
            switch (usg) {
                else => return,

                0x090001, 0x090002, 0x090003, 0x090004, 0x090005, 0x090006, 0x090007, 0x090008 => {
                    m = @as(i32, 1) << @intCast(usg - 0x090001);
                },

                0x0D0032 => { // In Range
                    s.oor = v == 0;
                    break :button;
                },

                0x0D0042 => m = 1, // Tip Switch
                0x0D0044 => m = 2, // Barrel Switch
                0x0D0045 => m = 4, // Eraser

                0x0D0048 => { // Contact width
                    s.w = v;
                    break :button;
                },
                0x0D0049 => { // Contact height
                    s.h = v;
                    break :button;
                },

                0x0D0051 => { // Contact identifier
                    s.id = v;
                    break :button;
                },

                0x010030 => {
                    if ((f & (hid.Fabs | hid.Frel)) == hid.Fabs) {
                        v = scale(v, g);
                        s.abs |= 1;
                    }
                    s.x = v;
                    break :button;
                },
                0x010031 => {
                    if ((f & (hid.Fabs | hid.Frel)) == hid.Fabs) {
                        v = scale(v, g);
                        s.abs |= 2;
                    }
                    s.y = v;
                    break :button;
                },
                0x010038 => {
                    if ((f & (hid.Fabs | hid.Frel)) == hid.Fabs)
                        s.abs |= 4;
                    s.z = v;
                    break :button;
                },
            }
            // Button:
            s.m |= m;
            s.b &= ~m;
            if (v != 0)
                s.b |= m;
        }
        s.valid = true;
    }
}

/// An absolute position as a part of 2^31 of its logical range.
fn scale(v: i32, g: *[Ng]i32) i32 {
    const range = g[hid.LogiMax] -% g[hid.LogiMin];
    if (range == 0)
        return 0;
    return @truncate(@divTrunc(@as(i64, v -% g[hid.LogiMin]) << 31, @as(i64, range)));
}

fn sethipri() void {
    var name: [64]u8 = undefined;

    const fd = libc.open(libc.sprint(&name, "/proc/%d/ctl", .{libc.getpid()}), sys.OWRITE) catch return;
    libc.fprint(fd, "pri 13", .{});
    _ = sys.close(fd);
}

fn keykey(a: []const u16, k: u16) bool {
    return std.mem.indexOfScalar(u16, a, k) != null;
}

fn readerproc(f: *Hiddev) void {
    var errbuf: [libc.ERRMAX]u8 = undefined;
    var mbuf: [80]u8 = undefined;
    var nb: [96]u8 = undefined;
    var lastk: [hid.Nkey]u16 = undefined;
    var uks: [hid.Nkey]u16 = undefined;
    var dks: [hid.Nkey]u16 = undefined;
    var p: Hidreport = .{};
    var lasts: [16]Hidslot = @splat(.{});
    var lastb: i32 = 0;
    var nlastk: usize = 0;

    thread.threadsetname(libc.sprint(&nb, "readerproc %s", .{f.ep.?.dir}));
    sethipri();

    while (true) {
        const ep = f.ep orelse hdfatal(f, null);
        if (ep.maxpkt < 1 or ep.maxpkt > p.p.len)
            hdfatal(f, "hid: weird maxpkt");

        @memset(&p.p, 0);
        const c = sys.read(ep.dfd, p.p[0..@intCast(ep.maxpkt)]);
        if (c <= 0) {
            const err = if (c < 0) libc.rerrstr(&errbuf) else "zero read";

            libc.fprint(2, "%s: hid: %s: read: %s\n", .{ libc.argv0, ep.dir, err });

            // reset the whole device
            _ = usb.devctl(f.dev.?, "reset", .{}) catch {};

            hdfatal(f, err);
        }

        p.o = 0;
        p.e = @intCast(c);
        p.ns = 0;
        p.s[0] = .{};
        repparse(f.rep[0..f.nrep], hidparse, &p);
        if (p.s[p.ns].valid)
            p.ns += 1;

        // handle keyboard report
        if (p.nk != 0 or nlastk != 0) {
            if (debug != 0) {
                libc.fprint(2, "kbd: ", .{});
                for (p.k[0..p.nk]) |k|
                    libc.fprint(2, "%#4.4ux ", .{k});
                libc.fprint(2, "\n", .{});
            }

            if (f.kinfd < 0) {
                f.kinfd = libc.open("/dev/kbin", sys.OWRITE) catch
                    hdfatal(f, "open /dev/kbin");

                f.repeatc = chan.chancreate(@sizeOf(u32), 0) orelse
                    hdfatal(f, "chancreate failed");
                _ = thread.proccreate(repeatproc, f, hid.Stack);
            }

            // collect key presses/releases
            var nuks: usize = 0;
            for (lastk[0..nlastk]) |k| {
                if (!keykey(p.k[0..p.nk], k)) {
                    uks[nuks] = sctab(k);
                    nuks += 1;
                }
            }
            var ndks: usize = 0;
            for (p.k[0..p.nk]) |k| {
                if (!keykey(lastk[0..nlastk], k)) {
                    dks[ndks] = sctab(k);
                    ndks += 1;
                }
            }

            // stop the repeats first to avoid race condition when
            // the key is released but the repeat happens right after
            var stopped = false;
            for (uks[0..nuks]) |k| {
                if (ndks == 0 or keykey(dks[0..ndks], k)) {
                    stoprepeat(f);
                    stopped = true;
                    break;
                }
            }
            for (uks[0..nuks]) |k|
                putscan(f, @truncate(k), Keyup);
            for (dks[0..ndks]) |k|
                putscan(f, @truncate(k), 0);

            if (!stopped and ndks > 0)
                startrepeat(f, @truncate(dks[ndks - 1]));

            nlastk = p.nk;
            @memcpy(lastk[0..nlastk], p.k[0..nlastk]);
            p.nk = 0;
        }

        // handle mouse/touchpad
        if (p.ns == 0)
            continue;

        // combine all the slots
        var bpress: i32 = 0;
        var abs = false;
        var x: i32 = 0;
        var y: i32 = 0;
        var z: i32 = 0;
        var b: i32 = 0;
        var i: usize = 0;
        var s: *Hidslot = undefined;
        var l: *Hidslot = undefined;
        while (i < p.ns) : ({
            l.* = s.*;
            i += 1;
        }) {
            s = &p.s[i];

            // find the last slot of the same id
            var li: usize = 0;
            while (lasts[li].valid and li < lasts.len - 1) : (li += 1) {
                if (lasts[li].usage == s.usage and lasts[li].id == s.id)
                    break;
            }
            l = &lasts[li];
            if (li == lasts.len - 1 or !l.valid)
                l.* = s.*;

            // convert absolute z to relative
            z +%= s.z;
            if (s.abs & 4 != 0)
                z -%= l.z;

            if (debug != 0) {
                if ((s.abs & 3) == 3)
                    libc.fprint(2, "ptr[%d]: id=%x b=%x m=%x x=%f y=%f z=%d\n", .{
                        i,                                                               s.id, s.b, s.m,
                        @as(f64, @floatFromInt(@as(u32, @bitCast(s.x)))) / 2147483648.0,
                        @as(f64, @floatFromInt(@as(u32, @bitCast(s.y)))) / 2147483648.0,
                        s.z,
                    })
                else
                    libc.fprint(2, "ptr[%d]: id=%x b=%x m=%x x=%d y=%d z=%d\n", .{ i, s.id, s.b, s.m, s.x, s.y, s.z });
            }

            // map to mouse buttons
            b |= s.b & 1;
            if (s.b & (4 | 8) != 0)
                b |= 2;
            if (s.b & 2 != 0)
                b |= 4;
            bpress |= s.m;

            // X/Y are absolute?
            if ((s.abs & 3) == 3) {
                // ignore absolute position when nothing changed
                if (s.abs == l.abs and s.x == l.x and s.y == l.y and s.b == l.b)
                    continue;
                abs = true;
                x = s.x;
                y = s.y;
            } else {
                // everything needs to be relative
                if ((s.abs & 3) != 0 or abs)
                    continue;
                x +%= s.x;
                y +%= s.y;
            }
        }

        if (bpress == 0)
            b = lastb & 7;
        if (z != 0)
            b |= if (z > 0) 8 else 16;

        if (abs or x != 0 or y != 0 or z != 0 or b != lastb) {
            lastb = b;

            if (f.minfd < 0) {
                f.minfd = libc.open("/dev/mousein", sys.OWRITE) catch
                    hdfatal(f, "open /dev/mousein");
            }
            const msg = libc.sprint(mbuf[0 .. mbuf.len - 1], "%c%11d %11d %11d", .{ "ma"[@intFromBool(abs)], x, y, b });
            _ = sys.write(f.minfd, msg);
        }
    }
}

fn gaomons620(f: *Hiddev) void {
    const idx = [_]i32{ 0x64, 0x65, 0x6e, 0x79, 0x7a, 0x7b, 0xc8, 0xc9 };
    const d = f.dev.?;

    // we have to fetch a bunch of strings to switch to non-phone mode
    for (idx) |i|
        libc.allocator.free(usb.loaddevstr(d, i));

    // override report descriptor
    f.nrep = tab.gaomon.len;
    @memcpy(f.rep[0..f.nrep], &tab.gaomon);
}

fn quirks(f: *Hiddev) void {
    const ud = f.dev.?.usb.?;

    if (ud.vid == 0x256c and ud.did == 0x006d) {
        gaomons620(f);
        return;
    }

    // Elecom trackball report descriptor lies by
    // omission, failing to mention all its buttons.
    // We patch the descriptor with a correct count
    // which lets us parse full reports. Tested with:
    //   Elecom HUGE (M-HT1DRBK, M-HT1URBK)
    if (ud.vid == 0x056e and ud.did == 0x010c) {
        if (f.nrep < 32 or
            f.rep[12] != 0x95 or
            f.rep[14] != 0x75 or
            f.rep[15] != 0x01 or
            f.rep[20] != 0x29 or
            f.rep[30] != 0x75)
            return;

        f.rep[13] = 8;
        f.rep[21] = 8;
        f.rep[31] = 0;
        return;
    }
}

fn hdsetup(d: *Dev, ep: *Ep) bool {
    var desc: [512]u8 = undefined;

    const f = libc.allocator.create(Hiddev) catch libc.sysfatal("malloc: %r", .{});
    f.* = .{};
    @memset(&f.rep, 0);
    usb.incref(&d.ref);
    f.dev = d;
    err: {
        // DWC OTG controller misses some split transaction inputs.
        // Set nonzero idle time to return more frequent reports
        // of keyboard state, to avoid losing key up/down events.
        const n = sys.read(d.cfd, desc[0 .. desc.len - 1]);
        if (n > 0) {
            if (std.mem.indexOf(u8, desc[0..@intCast(n)], "dwcotg") != null)
                f.idle = Dwcidle;
        }
        setproto(f, ep.iface.?) catch {
            libc.fprint(2, "%s: %s: setproto: %r\n", .{ libc.argv0, d.dir });
            break :err;
        };
        f.ep = usb.openep(d, ep) orelse {
            libc.fprint(2, "%s: %s: openep %d: %r\n", .{ libc.argv0, d.dir, ep.id });
            break :err;
        };
        _ = usb.opendevdata(f.ep.?, sys.OREAD) catch {
            libc.fprint(2, "%s: %s: opendevdata: %r\n", .{ libc.argv0, f.ep.?.dir });
            break :err;
        };
        quirks(f);
        _ = thread.procrfork(readerproc, f, hid.Stack, sys.RFNOTEG);
        return true;
    }
    hdfree(f);
    return false;
}

fn fsread(r: *Req) void {
    var msg: [48]u8 = undefined;

    var s: []const u8 = "";
    if (havekbd)
        s = libc.sprint(msg[0 .. msg.len - 1], "repeat %d\ndelay %d\n", .{ kbrepeat, kbdelay });
    p9.readstr(r, s);
    p9.respond(r, null);
}

fn fswrite(r: *Req) void {
    var msg: [256]u8 = undefined;
    var f: [4][]u8 = undefined;

    const fid = r.fid.?;
    const dev: *Dev = @ptrCast(@alignCast(fid.file.?.aux.?));
    const data = r.ifcall.data[0..r.ifcall.count];
    const rawon: ?*anyopaque = @ptrFromInt(Rawon);
    if (fid.aux == rawon) {
        if (std.mem.eql(u8, data, "rawoff"))
            fid.aux = null
        else {
            // the report is sent from a copy: usbcmd's data is not const
            const copy = usb.estrdup(data);
            defer libc.allocator.free(copy);
            _ = usbcmd(dev, usb.Rh2d | usb.Rclass | usb.Riface, hid.Setreport, hid.Reportout, 0, copy) catch {
                p9.responderror(r);
                return;
            };
        }
    } else {
        // the text as far as a 0, and no more than fits
        var n = std.mem.indexOfScalar(u8, data, 0) orelse data.len;
        n = @min(n, msg.len - 1);
        @memcpy(msg[0..n], data[0..n]);
        const nf = libc.tokenize(msg[0..n], &f);
        if (nf == 1 and std.mem.eql(u8, f[0], "rawon"))
            fid.aux = rawon
        else if (nf == 2 and std.mem.eql(u8, f[0], "repeat"))
            kbrepeat = @truncate(libc.atoi(f[1]))
        else if (nf == 2 and std.mem.eql(u8, f[0], "delay"))
            kbdelay = @truncate(libc.atoi(f[1]))
        else if (nf == 2 and std.mem.eql(u8, f[0], "debug"))
            debug = @truncate(libc.atoi(f[1]))
        else {
            p9.respond(r, "invalid ctl message");
            return;
        }
    }
    r.ofcall.count = r.ifcall.count;
    p9.respond(r, null);
}

var fs: p9.Srv = .{
    .read = fsread,
    .write = fswrite,
};

fn usage() noreturn {
    libc.fprint(2, "usage: %s [-d] devid\n", .{libc.argv0});
    thread.threadexits("usage");
}

pub fn threadmain(argv: []const []const u8) void {
    var buf: [32]u8 = undefined;

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'd' => debug += 1,
        else => usage(),
    };
    const rest = args.rest();
    if (rest.len != 1)
        usage();
    const d = usb.getdev(rest[0]) orelse libc.sysfatal("getdev: %r", .{});
    const ud = d.usb.?;
    var n: usize = 0;
    for (ud.ep) |slot| {
        const ep = slot orelse continue;
        if (ep.type != usb.Eintr or ep.dir != usb.Ein)
            continue;
        switch (ep.iface.?.csp) {
            hid.KbdCSP, hid.PtrCSP, hid.PtrNonBootCSP, hid.HidCSP => |csp| {
                if (csp == hid.KbdCSP)
                    havekbd = true;
                n += @intFromBool(hdsetup(d, ep));
            },
            else => {},
        }
    }
    // the name is copied first: d is gone when it is closed if no
    // interface was set up
    var hb: [64]u8 = undefined;
    const hname = libc.sprint(&hb, "%s", .{d.hname});
    usb.closedev(d);
    if (n > 0) {
        fs.tree = p9.alloctree(user, "usb", fcall.DMDIR | 0o555, null);
        _ = p9.createfile(fs.tree.?.root, libc.sprint(buf[0 .. buf.len - 1], "hidU%sctl", .{hname}), user, 0o666, d) catch {};
        p9.threadpostsharesrv(&fs, null, "usb", libc.sprint(buf[0 .. buf.len - 1], "%s.hid", .{hname}));
    }
    thread.threadexits(null);
}
