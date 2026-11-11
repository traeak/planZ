//! The pnp device, #$: access to PCI configuration space.
//! `#$/pci/B.D.Fctl` describes a function (class, vendor/device,
//! interrupt line, base address registers) and `#$/pci/B.D.Fraw` is
//! its configuration space.  Stock pci(1) reads these.
//! from 9/port/devpnp.c
//!
//!     ISA PNP 1.0 support + access to PCI configuration space
//!
//!     TODO
//!         - implement PNP card configuration (setting io bases etc)
//!         - write user program to drive PNP configuration...
//!         - extend PCI raw access to configuration space (writes, byte/short access?)
//!         - implement PCI access to memory/io space/BIOS ROM
//!         - use c->aux instead of performing lookup on each read/write?
//!
//! DIFF:
//!   - ISA PnP is left out: no machine planZ runs on has ISA PnP cards,
//!     and the isolation protocol needs port I/O (0x279, 0xa79), which
//!     portable code cannot do.  Gone are Card, the card list and its
//!     QLock, key, cmd, initiation, readbit, isolate, getresbyte,
//!     serial, findcsn, newcsn, pnpncfg, pnpscan, csngen, wrconfig and
//!     pnpreset (which only read the "pnp" ISA configuration and
//!     scanned).  The names and the qid layout are kept so that it can
//!     be added: `#$/pnp` and `#$/pnp/ctl` exist, Qcsnctl and Qcsnraw
//!     keep their numbers and CSN()/QID() their bit positions.  With no
//!     cards: `#$/pnp` lists only ctl; ctl reads "disabled\n" (rddata
//!     is never set); writing "port n" to it checks the range as the C
//!     does and then fails with "no cards found", which is what the C
//!     says when the scan finds none; "debug n" is accepted and sets
//!     the flag nothing reads; a csn file cannot be walked to, and
//!     reading or writing one is Egreg as for a card that has gone.
//!   - pnpread and pnpwrite refuse a negative offset on the raw file
//!     with Ebadarg; the C would hand a negative register number to
//!     pcicfgr8.
//!   - pnpwrite copies the text into buf only for the ctl file, which
//!     is the only one that reads it; the C does it for every write.
//!     The clamp of n to sizeof(buf)-1 that goes with the copy is kept
//!     for all files, so a 256 byte write to raw writes 255.
//!   - seprint is a local helper over fmt.snprint.
//!
//! As in the C, the raw file stops at 256 bytes (and stats as 128),
//! although the accessors in port/pci.zig reach the 4096 bytes of
//! extended configuration space where the platform has it.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");
const netif = @import("netif.zig");
const pci = @import("pci.zig");

const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Dirtab = devmod.Dirtab;
const devdir = devmod.devdir;
const devgen = devmod.devgen;
const readstr = devcons.readstr;
const QTDIR = fcall.QTDIR;
const DEVDOTDOT = portdat.DEVDOTDOT;
const Pcidev = pci.Pcidev;
const BUSBDF = pci.BUSBDF;
const BUSBNO = pci.BUSBNO;
const BUSDNO = pci.BUSDNO;
const BUSFNO = pci.BUSFNO;
const MKBUS = pci.MKBUS;
const BusPCI = pci.BusPCI;

const Pnp = struct {
    rddata: i32 = -1,
    debug: u32 = 0,
};

var pnp: Pnp = .{};

const Qtopdir = 0;

const Qpnpdir = 1;
const Qpnpctl = 2;
const Qcsnctl = 3;
const Qcsnraw = 4;

const Qpcidir = 5;
const Qpcictl = 6;
const Qpciraw = 7;

fn TYPE(q: Qid) u32 {
    return @as(u32, @truncate(q.path)) & 0x0F;
}
fn CSN(q: Qid) u32 {
    return (@as(u32, @truncate(q.path)) >> 4) & 0xFF;
}
fn QID(c: u32, t: u32) u64 {
    return (c << 4) | t;
}

const topdir = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qtopdir, .vers = 0, .type = QTDIR }, .length = 0, .perm = 0o555 },
    .{ .name = "pnp", .qid = .{ .path = Qpnpdir, .vers = 0, .type = QTDIR }, .length = 0, .perm = 0o555 },
    .{ .name = "pci", .qid = .{ .path = Qpcidir, .vers = 0, .type = QTDIR }, .length = 0, .perm = 0o555 },
};

const pnpdir = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qpnpdir, .vers = 0, .type = QTDIR }, .length = 0, .perm = 0o555 },
    .{ .name = "ctl", .qid = .{ .path = Qpnpctl, .vers = 0, .type = 0 }, .length = 0, .perm = 0o666 },
};

/// The C's s = seprint(s, e, ...): append at buf[p..] and return the
/// new end.
fn seprint(buf: []u8, p: usize, comptime format: []const u8, args: anytype) usize {
    return p + fmt.snprint(buf[p..], format, args).len;
}

/// The tbdf of the function a pci file's qid names.
fn qidtbdf(q: Qid) i32 {
    return MKBUS(BusPCI, 0, 0, 0) | BUSBDF(@bitCast(@as(u32, @truncate(q.path))));
}

fn pcigen(c: *Chan, t: u32, tbdf: i32, dp: *Dir) i32 {
    const up = arch.up().?;

    const q = devmod.mkqid(@as(u32, @bitCast(BUSBDF(tbdf))) | t, 0, 0);
    switch (t) {
        Qpcictl => {
            const name = fmt.snprint(&up.genbuf, "%d.%d.%dctl", .{ BUSBNO(tbdf), BUSDNO(tbdf), BUSFNO(tbdf) });
            devdir(c, q, name, 0, proc.eve, 0o444, dp);
            return 1;
        },
        Qpciraw => {
            const name = fmt.snprint(&up.genbuf, "%d.%d.%draw", .{ BUSBNO(tbdf), BUSDNO(tbdf), BUSFNO(tbdf) });
            devdir(c, q, name, 128, proc.eve, 0o660, dp);
            return 1;
        },
        else => {},
    }
    return -1;
}

/// The entry for the top directory, as the parent of the others.
fn topgen(c: *Chan, dp: *Dir) i32 {
    const up = arch.up().?;
    const q = devmod.mkqid(QID(0, Qtopdir), 0, QTDIR);
    const name = fmt.snprint(&up.genbuf, "#%C", .{pnpdevtab.dc});
    devdir(c, q, name, 0, proc.eve, 0o555, dp);
    return 1;
}

fn pnpgen(c: *Chan, _: ?[]const u8, _: []const Dirtab, s_: i32, dp: *Dir) i32 {
    var s = s_;

    switch (TYPE(c.qid)) {
        Qtopdir => {
            if (s == DEVDOTDOT)
                return topgen(c, dp);
            return devgen(c, null, &topdir, s, dp);
        },
        Qpnpdir => {
            if (s == DEVDOTDOT)
                return topgen(c, dp);
            if (s < pnpdir.len - 1)
                return devgen(c, null, &pnpdir, s, dp);
            // DIFF: the cards would follow, two files each; there are none.
            return -1;
        },
        Qpnpctl => return devgen(c, null, &pnpdir, s, dp),
        Qcsnctl, Qcsnraw => {
            // DIFF: findcsn finds no card.
            return -1;
        },
        Qpcidir => {
            if (s == DEVDOTDOT)
                return topgen(c, dp);
            var p = pci.pcimatch(null, 0, 0);
            while (s >= 2 and p != null) {
                p = pci.pcimatch(p, 0, 0);
                s -= 2;
            }
            const d = p orelse return -1;
            return pcigen(c, @as(u32, @intCast(s)) + Qpcictl, d.tbdf, dp);
        },
        Qpcictl, Qpciraw => {
            const tbdf = qidtbdf(c.qid);
            if (pci.pcimatchtbdf(tbdf) == null)
                return -1;
            return pcigen(c, TYPE(c.qid), tbdf, dp);
        },
        else => {},
    }
    return -1;
}

fn pnpattach(spec: []const u8) Error!*Chan {
    return devmod.devattach(pnpdevtab.dc, spec);
}

fn pnpwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &.{}, pnpgen);
}

fn pnpstat(c: *Chan, dp: []u8) Error!usize {
    return devmod.devstat(c, dp, &.{}, pnpgen);
}

fn pnpopen(c: *Chan, omode: u32) Error!*Chan {
    return devmod.devopen(c, omode, &.{}, pnpgen);
}

fn pnpclose(_: *Chan) Error!void {}

fn pnpread(c: *Chan, va: []u8, offset: i64) Error!usize {
    const up = arch.up().?;
    var buf: [256]u8 = undefined;
    var n = va.len;

    switch (TYPE(c.qid)) {
        Qtopdir, Qpnpdir, Qpcidir => return devmod.devdirread(c, va, &.{}, pnpgen),
        Qpnpctl => {
            const s = if (pnp.rddata > 0)
                fmt.snprint(&up.genbuf, "enabled %#x\n", .{pnp.rddata})
            else
                fmt.snprint(&up.genbuf, "disabled\n", .{});
            return readstr(@intCast(@max(offset, 0)), va, s);
        },
        Qcsnraw, Qcsnctl => {
            // DIFF: findcsn finds no card.
            return error.Egreg;
        },
        Qpcictl => {
            const p = pci.pcimatchtbdf(qidtbdf(c.qid)) orelse return error.Egreg;
            const ebuf = buf[0 .. buf.len - 1]; // -1 for newline
            var w = seprint(ebuf, 0, "%.2x.%.2x.%.2x %.4x/%.4x %3d", .{ p.ccrb, p.ccru, p.ccrp, p.vid, p.did, p.intl });
            for (p.mem, 0..) |m, i| {
                if (m.size == 0)
                    continue;
                w = seprint(ebuf, w, " %d:%.8llux %lld", .{ i, m.bar, m.size });
            }
            buf[w] = '\n';
            w += 1;
            return readstr(@intCast(@max(offset, 0)), va, buf[0..w]);
        },
        Qpciraw => {
            const p = pci.pcimatchtbdf(qidtbdf(c.qid)) orelse return error.Egreg;
            if (offset < 0)
                return error.Ebadarg;
            if (offset > 256)
                return 0;
            const off: usize = @intCast(offset);
            if (n + off > 256)
                n = 256 - off;
            var r: i32 = @intCast(off);
            if (r & 3 == 0 and n == 4) {
                std.mem.writeInt(u32, va[0..4], pci.pcicfgr32(p, r), .little);
                return 4;
            }
            if (r & 1 == 0 and n == 2) {
                std.mem.writeInt(u16, va[0..2], @truncate(@as(u32, @bitCast(pci.pcicfgr16(p, r)))), .little);
                return 2;
            }
            var i: usize = 0;
            while (i < n) : (i += 1) {
                va[i] = @truncate(@as(u32, @bitCast(pci.pcicfgr8(p, r))));
                r += 1;
            }
            return i;
        },
        else => return error.Egreg,
    }
}

fn pnpwrite(c: *Chan, va: []const u8, offset: i64) Error!usize {
    var buf: [256]u8 = undefined;
    var n = va.len;

    if (n >= buf.len)
        n = buf.len - 1;

    switch (TYPE(c.qid)) {
        Qpnpctl => {
            @memcpy(buf[0..n], va[0..n]);
            const s = buf[0 .. std.mem.findScalar(u8, buf[0..n], 0) orelse n];
            if (std.mem.startsWith(u8, s, "port ")) {
                const port = netif.strtoul(s[5..], 0).v;
                if (port < 0x203 or port > 0x3ff)
                    return proc.errorf("bad value for rddata port", .{});
                if (pnp.rddata > 0)
                    return proc.errorf("pnp port already set", .{});
                // DIFF: no pnpscan; it would find nothing.
                return proc.errorf("no cards found", .{});
            } else if (std.mem.startsWith(u8, s, "debug ")) {
                pnp.debug = netif.strtoul(s[6..], 0).v;
            } else return error.Ebadctl;
        },
        Qcsnctl => {
            // DIFF: findcsn finds no card.
            return error.Egreg;
        },
        Qpciraw => {
            const p = pci.pcimatchtbdf(qidtbdf(c.qid)) orelse return error.Egreg;
            if (offset < 0)
                return error.Ebadarg;
            if (offset > 256)
                return 0;
            const off: usize = @intCast(offset);
            if (n + off > 256)
                n = 256 - off;
            var r: i32 = @intCast(off);
            if (r & 3 == 0 and n == 4) {
                pci.pcicfgw32(p, r, std.mem.readInt(u32, va[0..4], .little));
                return 4;
            }
            if (r & 1 == 0 and n == 2) {
                pci.pcicfgw16(p, r, std.mem.readInt(u16, va[0..2], .little));
                return 2;
            }
            var i: usize = 0;
            while (i < n) : (i += 1) {
                pci.pcicfgw8(p, r, va[i]);
                r += 1;
            }
            return i;
        },
        else => return error.Egreg,
    }
    return n;
}

pub const pnpdevtab: devmod.Dev = .{
    .dc = '$',
    .name = "pnp",

    .attach = pnpattach,
    .walk = pnpwalk,
    .stat = pnpstat,
    .open = pnpopen,
    .close = pnpclose,
    .read = pnpread,
    .write = pnpwrite,
};
