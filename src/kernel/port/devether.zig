//! Ethernet, #l: one directory per interface (#l0 is /net/ether0),
//! built on netif.  Drivers register with addethercard; packets they
//! receive come in through etheriq and are handed to every connection
//! that wants their type; packets written go out through the
//! interface's output queue, whose kick routine is the driver's
//! transmit.
//! from 9/port/devether.c and 9/port/etherif.h; ISAConf from
//! 9/pc64/dat.h, isaconfig from 9/pc/devarch.c, parseether from
//! libip/parseether.c, the %E verb from libip/eipfmt.c.
//!
//! DIFF:
//!   - Errors are Zig error returns; the waserror sites became errdefer
//!     or defer.  etheroq can fail (qbwrite on the output queue), so it
//!     and the write entries return error unions.
//!   - An Ether is not an ISAConf and a Netif by embedding: they are
//!     the fields `isa` and `netif` (ether.isa.port, ether.isa.irq,
//!     ether.netif.mbps, ether.netif.arg ...).  etherof() goes back
//!     from the Netif to its Ether.
//!   - The routines a driver fills in keep their C names but are typed:
//!     attach returns Error!void, ctl takes the message as a slice and
//!     returns Error!usize, power takes a bool.  transmit is not handed
//!     to qopen with a cast; the queue's kick is etherkick, which calls
//!     it.
//!   - Ether.interrupt is not in this version of 9front, where every
//!     driver calls intrenable itself.  It is here for drivers written
//!     the older way (9/pc/devether.c before the port/ version): if a
//!     driver's reset sets it, etherprobe enables it on isa.irq.
//!     Drivers that enable their own interrupt (MSI) leave it null.
//!   - ethermux and etheroq name the connection a packet comes from by
//!     its index in netif.f, where the C passes a pointer into that
//!     array and does pointer arithmetic on it.
//!   - The card table's reset returns an i32 as in C: negative for "no
//!     such card here".
//!   - There is no ISA configuration layer; ISAConf and isaconfig are
//!     private stand-ins here (M7).  The options of an ISAConf are
//!     slices into a private copy of the configuration string.
//!   - mainmem->maxsize, which caps the output queue size, does not
//!     exist; the size of kernel memory from conf stands in for it.
//!   - fmtinstall('E', eipfmt) is gone: an address prints itself when
//!     wrapped with ea(), `print("%E", .{ea(ether.ea)})`.
//!   - The network console (console=net ... in plan9.ini) is not
//!     ported: it needs ipcsum from the IP stack and a kernel print
//!     path through consuart, which planZ does not have.  netconsole()
//!     only says so.  (M7: ip)
//!   - dmatproxy needs a few constants and v4tov6 from the IP stack's
//!     headers; they are private here until 9/ip is ported (M7: ip).
//!     Nothing but a wifi driver sets Ether.dmat.
//!   - ethersetlink takes a bool.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const alloc = @import("alloc.zig");
const ab = @import("allocb.zig");
const qio = @import("qio.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const parse = @import("parse.zig");
const portclock = @import("portclock.zig");
const devcons = @import("devcons.zig");
const devmod = @import("dev.zig");
const netif = @import("netif.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const freeb = ab.freeb;
const BLEN = ab.BLEN;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Queue = qio.Queue;
const Block = ab.Block;
const Netif = netif.Netif;
const Netfile = netif.Netfile;
const Etherpkt = netif.Etherpkt;
const NETTYPE = netif.NETTYPE;
const NETID = netif.NETID;
const Ndataqid = netif.Ndataqid;
const KNAMELEN = portdat.KNAMELEN;
const MB = portdat.MB;

pub const Eaddrlen = netif.Eaddrlen;
pub const ETHERMINTU = netif.ETHERMINTU;
pub const ETHERMAXTU = netif.ETHERMAXTU;
pub const ETHERHDRSIZE = netif.ETHERHDRSIZE;
const ETARP = netif.ETARP;
const ETIP4 = netif.ETIP4;
const ETIP6 = netif.ETIP6;

pub const MaxEther = 64;
pub const Ntypes = 8;

pub const DMTE = struct {
    ip: [16]u8 = @splat(0),
    mac: [Eaddrlen]u8 = @splat(0),
    valid: u8 = 0,
};

pub const DMAT = struct {
    tab: [127]DMTE = @splat(.{}), // prime
    map: u64 = 0,
};

pub const Macent = struct {
    ea: [Eaddrlen]u8 = @splat(0),
    port: u16 = 0,
};

// M7: belongs with the platform's isaconfig
pub const NISAOPT = 8;

// M7: belongs with the platform's isaconfig
// from 9/pc64/dat.h
pub const ISAConf = struct {
    type: []const u8 = "",
    port: u64 = 0,
    irq: i32 = 0,
    dma: u32 = 0,
    mem: u32 = 0,
    size: u32 = 0,
    freq: u32 = 0,

    nopt: usize = 0,
    opt: [NISAOPT][]u8 = @splat(&.{}),
};

pub const Ether = struct {
    isa: ISAConf = .{}, // hardware info
    tbdf: i32 = arch.BUSUNKNOWN, // type+busno+devno+funcno

    ctlrno: i32 = 0,
    minmtu: usize = 0,
    maxmtu: usize = 0,

    attach: ?*const fn (*Ether) Error!void = null, // filled in by reset routine
    transmit: ?*const fn (*Ether) void = null,
    ctl: ?*const fn (*Ether, []const u8) Error!usize = null, // custom ctl messages
    power: ?*const fn (*Ether, bool) void = null, // power on/off
    shutdown: ?*const fn (*Ether) void = null, // shutdown hardware before reboot
    /// DIFF: see the head of the file.  Called with the Ether as arg.
    interrupt: ?*const fn (*arch.Ureg, ?*anyopaque) void = null,
    ctlr: ?*anyopaque = null,

    oq: ?*Queue = null,

    netif: Netif = .{},

    ea: [Eaddrlen]u8 = @splat(0),
    mactab: [127]Macent = @splat(.{}), // for bridge

    dmat: ?*DMAT = null,
};

/// The Ether a Netif is part of; what the C does with a cast.
pub fn etherof(nif: *Netif) *Ether {
    return @fieldParentPtr("netif", nif);
}

/// An Ethernet address that prints itself: %E in the C.
pub const Eaddr = struct {
    a: [Eaddrlen]u8,

    pub fn fmt9(self: Eaddr, f: *fmt.Fmt) void {
        const hex = "0123456789abcdef";
        var buf: [2 * Eaddrlen]u8 = undefined;
        for (self.a, 0..) |b, i| {
            buf[2 * i] = hex[b >> 4];
            buf[2 * i + 1] = hex[b & 15];
        }
        f.pad(&buf);
    }
};

/// print("%E", .{ea(ether.ea)})
pub fn ea(addr: [Eaddrlen]u8) Eaddr {
    return .{ .a = addr };
}

pub fn NEXT(x: usize, l: usize) usize {
    return (x + 1) % l;
}

pub fn PREV(x: usize, l: usize) usize {
    return if (x == 0) l - 1 else x - 1;
}

pub fn HOWMANY(x: usize, y: usize) usize {
    return (x + (y - 1)) / y;
}

pub fn ROUNDUP(x: usize, y: usize) usize {
    return HOWMANY(x, y) * y;
}

var etherxx: [MaxEther]?*Ether = @splat(null);

fn drop(_: ?*anyopaque, b: *Block) void {
    freeb(b);
}

fn bypass(arg: ?*anyopaque, b: *Block) void {
    const ether: *Ether = @ptrCast(@alignCast(arg.?));
    const f = ether.netif.bypass orelse {
        freeb(b);
        return;
    };
    if (qio.qpass(f.in, b) < 0)
        ether.netif.soverflows += 1;
}

/// DIFF: the output queue's kick; the C gives qopen ether->transmit
/// itself, cast to take a void*.
fn etherkick(arg: ?*anyopaque) void {
    const ether: *Ether = @ptrCast(@alignCast(arg.?));
    if (ether.transmit) |transmit|
        transmit(ether);
}

pub fn etherattach(spec_: []const u8) Error!*Chan {
    var spec = spec_;
    var ctlrno: usize = 0;
    if (spec.len > 0) {
        const r = netif.strtoul(spec, 10);
        ctlrno = r.v;
        if (ctlrno >= MaxEther)
            return error.Enodev;
        if (r.n == 0)
            return error.Ebadspec;
        if (r.n < spec.len) {
            if (spec[r.n] != ':')
                return error.Ebadspec;
            const conf = spec[r.n + 1 ..];
            spec = spec[0..r.n];
            if (!devcons.iseve())
                return error.Enoattach;
            if (etherxx[ctlrno] != null)
                return error.Einuse;
            etherxx[ctlrno] = etherprobe(null, ctlrno, conf);
        }
    }
    const ether = etherxx[ctlrno] orelse
        return error.Enodev;
    const c = devmod.devattach('l', spec);
    errdefer chan.chanfree(c);
    c.dev = @intCast(ctlrno);
    if (ether.attach) |attach|
        try attach(ether);
    return c;
}

fn etherwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return netif.netifwalk(&etherxx[c.dev].?.netif, c, nc, name);
}

fn etherstat(c: *Chan, dp: []u8) Error!usize {
    return netif.netifstat(&etherxx[c.dev].?.netif, c, dp);
}

fn etheropen(c: *Chan, omode: u32) Error!*Chan {
    return netif.netifopen(&etherxx[c.dev].?.netif, c, omode);
}

fn ethercreate(_: *Chan, _: []const u8, _: u32, _: u32) Error!*Chan {
    return error.Eperm;
}

fn etherclose(c: *Chan) Error!void {
    const ether = etherxx[c.dev].?;

    if (NETTYPE(c.qid.path) == Ndataqid) {
        const f = ether.netif.f[NETID(c.qid.path)].?;
        if (f.bridge or f.bypass)
            @memset(&ether.mactab, .{});
        if (f.bypass) {
            qio.qsetbypass(ether.oq.?, if (ether.netif.link != 0) null else drop);
            qio.qsetlimit(ether.oq.?, etheroqsize(ether));
        }
    }
    netif.netifclose(&ether.netif, c);
}

fn etherread(c: *Chan, buf: []u8, off: i64) Error!usize {
    return netif.netifread(&etherxx[c.dev].?.netif, c, buf, @truncate(@as(u64, @bitCast(off))));
}

fn etherbread(c: *Chan, n: usize, offset: u64) Error!*Block {
    return netif.netifbread(&etherxx[c.dev].?.netif, c, n, offset);
}

fn etherwstat(c: *Chan, dp: []const u8) Error!usize {
    return netif.netifwstat(&etherxx[c.dev].?.netif, c, dp);
}

fn etherrtrace(f: *Netfile, pkt: [*]const u8, len: usize) void {
    if (qio.qfull(f.in))
        return;
    const bp = ab.iallocb(64) orelse
        return;
    const n = if (len < 64) len else 64;
    @memcpy(bp.wp[0..n], pkt[0..n]);
    if (f.type != -2) {
        const ms: u32 = portclock.tk2ms(arch.MACHP(0).ticks);
        bp.wp[58] = @truncate(len >> 8);
        bp.wp[59] = @truncate(len);
        bp.wp[60] = @truncate(ms >> 24);
        bp.wp[61] = @truncate(ms >> 16);
        bp.wp[62] = @truncate(ms >> 8);
        bp.wp[63] = @truncate(ms);
    }
    bp.wp += 64;
    _ = qio.qpass(f.in, bp);
}

fn macent(ether: *Ether, a: *const [Eaddrlen]u8) *Macent {
    const h: u32 = (@as(u32, a[0]) | @as(u32, a[1]) << 8 | @as(u32, a[2]) << 16 | @as(u32, a[3]) << 24) ^
        (@as(u32, a[4]) | @as(u32, a[5]) << 8);
    return &ether.mactab[h % ether.mactab.len];
}

/// Multiplex the packet to all the connections which want it.
/// If the packet is not to be used subsequently (tome || from == nil),
/// attempt to simply pass it into one of the connections, thereby
/// saving a copy of the data (usual case hopefully).
///
/// DIFF: `from` is the index in ether.netif.f of the connection the
/// packet was written on, null for a packet from the wire.
fn ethermux(ether: *Ether, bp: *Block, from: ?usize) ?*Block {
    const nif = &ether.netif;

    const len = BLEN(bp);
    if (len < ETHERHDRSIZE) {
        freeb(bp);
        return null;
    }

    const pkt: *Etherpkt = @ptrCast(bp.rp);
    const frombridge = if (from) |i| nif.f[i].?.bridge else false;
    const multi = pkt.d[0] & 1 != 0;
    var tome: bool = undefined;
    if (!multi) {
        if (from != null and nif.prom == 0)
            return bp;
        tome = (from == null or frombridge) and
            std.mem.eql(u8, &pkt.d, &ether.ea);
    } else {
        if (from == null and nif.prom == 0 and
            !std.mem.eql(u8, &pkt.d, nif.bcast[0..Eaddrlen]) and
            !netif.activemulti(nif, &pkt.d))
        {
            freeb(bp);
            return null;
        }
        tome = false;
    }

    var port: i32 = -1;
    if (nif.prom != 0) {
        if ((from == null or frombridge) and (pkt.s[0] & 1) == 0) {
            const t = macent(ether, &pkt.s);
            t.port = if (from) |i| @intCast(1 + i) else 0;
            t.ea = pkt.s;
        }
        if (!tome and !multi) {
            const t = macent(ether, &pkt.d);
            if (std.mem.eql(u8, &t.ea, &pkt.d))
                port = t.port;
        }
    }

    var x: ?*Netfile = null;
    const typ: i32 = (@as(i32, pkt.type[0]) << 8) | pkt.type[1];
    const dispose = tome or from == null or port > 0;

    for (nif.f[0..Ntypes], 0..) |fp, fi| {
        const f = fp orelse
            continue;
        if (f.type != typ and f.type >= 0)
            continue;
        if (!tome and !multi and !f.prom)
            continue;
        if (f.bypass)
            continue;
        if (f.bridge) {
            if (tome or (from != null and fi == from.?))
                continue;
            if (port >= 0 and port != @as(i32, @intCast(1 + fi)))
                continue;
        }
        if (f.headersonly or f.type == -2) {
            etherrtrace(f, bp.rp, len);
            continue;
        }
        if (dispose and x == null) {
            x = f;
            continue;
        }
        var xbp: ?*Block = null;
        if (bp.pool != null and len <= bp.pool.?.size)
            xbp = ab.iallocbp(bp.pool.?)
        else
            xbp = ab.iallocb(len);
        if (xbp) |xb| {
            @memcpy(xb.wp[0..len], bp.rp[0..len]);
            xb.wp += len;
            xb.flag |= bp.flag & ~(ab.BINTR | ab.BFREE);
            if (qio.qpass(f.in, xb) >= 0)
                continue;
        }
        nif.soverflows += 1;
    }
    if (x) |f| {
        if (qio.qpass(f.in, bp) < 0)
            nif.soverflows += 1;
        return null;
    }

    if (dispose) {
        freeb(bp);
        return null;
    }
    return bp;
}

/// A driver hands each packet it receives to etheriq; may be called
/// from its interrupt routine.
pub fn etheriq(ether: *Ether, bp: *Block) void {
    if (ether.netif.bypass != null) {
        freeb(bp);
        return;
    }
    if (ether.dmat) |dmat|
        dmatproxy(bp, false, &ether.ea, dmat);
    ether.netif.inpackets += 1;
    _ = ethermux(ether, bp, null);
}

fn etheroq(ether: *Ether, bp_: *Block, from_: usize) Error!void {
    var from: ?usize = from_;
    const f = ether.netif.f[from_].?;

    if (!f.bridge)
        @memcpy(bp_.rp[Eaddrlen..][0..Eaddrlen], &ether.ea);

    if (f.bypass) {
        if (ether.dmat) |dmat|
            dmatproxy(bp_, false, &ether.ea, dmat);
        from = null;
    }

    const bp = ethermux(ether, bp_, from) orelse
        return;
    if (ether.dmat) |dmat|
        dmatproxy(bp, true, &ether.ea, dmat);
    ether.netif.outpackets += 1;
    _ = try qio.qbwrite(ether.oq.?, bp);
}

fn etherwrite(c: *Chan, buf: []const u8, _: i64) Error!usize {
    const ether = etherxx[c.dev].?;
    const n = buf.len;

    if (NETTYPE(c.qid.path) != Ndataqid) {
        if (try netif.netifwrite(&ether.netif, c, buf)) |nn| {
            // got bypassed?
            if (ether.netif.f[NETID(c.qid.path)].?.bypass) {
                // bypass output queue
                qio.qsetbypass(ether.oq.?, bypass);
            }
            return nn;
        }
        const cb = try parse.parsecmd(buf);
        if (cb.nf > 0 and std.mem.eql(u8, cb.f[0], "nonblocking")) {
            const onoff = if (cb.nf <= 1) 1 else netif.atoi(cb.f[1]);
            qio.qnoblock(ether.oq.?, onoff != 0);
            alloc.free(cb);
            return n;
        }
        alloc.free(cb);
        if (ether.ctl) |ctl|
            return ctl(ether, buf);

        return error.Ebadctl;
    }

    if (n > ether.maxmtu)
        return error.Etoobig;
    if (n < ether.minmtu)
        return error.Etoosmall;

    const bp = ab.allocb(n);
    @memcpy(bp.rp[0..n], buf);
    bp.wp += n;

    try etheroq(ether, bp, NETID(c.qid.path));
    return n;
}

fn etherbwrite(c: *Chan, bp: *Block, _: u64) Error!usize {
    const n = BLEN(bp);

    if (NETTYPE(c.qid.path) != Ndataqid) {
        defer freeb(bp);
        return etherwrite(c, bp.rp[0..n], 0);
    }

    const ether = etherxx[c.dev].?;
    if (n > ether.maxmtu) {
        freeb(bp);
        return error.Etoobig;
    }
    if (n < ether.minmtu) {
        freeb(bp);
        return error.Etoosmall;
    }
    try etheroq(ether, bp, NETID(c.qid.path));
    return n;
}

const Card = struct {
    type: ?[]const u8 = null,
    reset: ?*const fn (*Ether) i32 = null,
};

var cards: [MaxEther + 1]Card = @splat(.{});
var ncard: usize = 0;

/// Register a driver: `r` is asked to find and set up the next card of
/// type `t`; it returns a negative number if there is none.
pub fn addethercard(t: []const u8, r: *const fn (*Ether) i32) void {
    if (ncard == MaxEther)
        panic("too many ether cards", .{});
    cards[ncard].type = t;
    cards[ncard].reset = r;
    ncard += 1;
}

fn etheroqsize(ether: *Ether) i32 {
    const b: i64 = @as(i64, ether.netif.mbps) * 2 * 125; // 2ms
    var q: i64 = 128 * 1024;
    while (q < b)
        q <<= 1;
    // DIFF: mainmem->maxsize in the C
    const conf = arch.conf;
    const maxsize: i64 = @intCast(@min((conf.npage - conf.upages) * arch.mem.BY2PG, 1 << 40));
    if (@divTrunc(maxsize, 8) < q)
        q = @divTrunc(maxsize, 8);
    return @intCast(@min(q, std.math.maxInt(i32)));
}

/// M7: belongs with the platform's isaconfig
/// from 9/pc/devarch.c
fn isaconfig(class: []const u8, ctlrno: usize, isa: *ISAConf) bool {
    var cc: [32]u8 = undefined;

    const name = fmt.snprint(&cc, "%s%d", .{ class, ctlrno });
    const p = arch.getconf(name) orelse
        return false;

    // the options stay slices into this copy, which is never freed
    var x: []u8 = portdat.nostr;
    proc.kstrdup(&x, p);

    isa.type = "";
    isa.nopt = parse.tokenize(x, &isa.opt);
    for (isa.opt[0..isa.nopt]) |o| {
        if (std.ascii.startsWithIgnoreCase(o, "type="))
            isa.type = o[5..]
        else if (std.ascii.startsWithIgnoreCase(o, "port="))
            isa.port = netif.strtou(u64, o[5..], 0).v
        else if (std.ascii.startsWithIgnoreCase(o, "irq="))
            isa.irq = @bitCast(netif.strtoul(o[4..], 0).v)
        else if (std.ascii.startsWithIgnoreCase(o, "dma="))
            isa.dma = netif.strtoul(o[4..], 0).v
        else if (std.ascii.startsWithIgnoreCase(o, "mem="))
            isa.mem = netif.strtoul(o[4..], 0).v
        else if (std.ascii.startsWithIgnoreCase(o, "size="))
            isa.size = netif.strtoul(o[5..], 0).v
        else if (std.ascii.startsWithIgnoreCase(o, "freq="))
            isa.freq = netif.strtoul(o[5..], 0).v;
    }
    return true;
}

/// Set up interface ctlrno.  With a card number, ask that driver;
/// without, find the driver named by `conf` (an attach specifier) or by
/// plan9.ini's etherN= line.
fn etherprobe(cardno_: ?usize, ctlrno: usize, conf: ?[]const u8) ?*Ether {
    const ether = alloc.new(Ether) orelse {
        print("etherprobe: no memory for Ether\n", .{});
        return null;
    };
    ether.* = .{};
    ether.tbdf = arch.BUSUNKNOWN;
    ether.isa.irq = -1;
    ether.ctlrno = @intCast(ctlrno);
    ether.netif.mbps = 10;
    ether.netif.link = -1; // unknown state
    ether.minmtu = ETHERMINTU;
    ether.maxmtu = ETHERMAXTU;

    var dup: ?[]u8 = null; // the copy of conf that isa.type and isa.opt point into
    const found: ?usize = probe: {
        var cardno: usize = 0;
        if (cardno_) |cn| {
            cardno = cn;
        } else {
            if (conf) |cf| {
                var x: []u8 = portdat.nostr;
                proc.kstrdup(&x, cf);
                dup = x;
                ether.isa.nopt = parse.tokenize(x, &ether.isa.opt);
                if (ether.isa.nopt < 1)
                    break :probe null;
                // the C's ether->type is the start of the copy, which
                // tokenize has cut after the first field
                ether.isa.type = std.mem.sliceTo(x, 0);
                ether.isa.nopt -= 1;
                for (0..ether.isa.nopt) |i|
                    ether.isa.opt[i] = ether.isa.opt[i + 1];
            } else if (!isaconfig("ether", ctlrno, &ether.isa))
                break :probe null;
            for (ether.isa.opt[0..ether.isa.nopt]) |o| {
                if (std.mem.startsWith(u8, o, "ea=")) {
                    if (parseether(&ether.ea, o[3..]) != 0)
                        @memset(&ether.ea, 0);
                }
            }
            while (cards[cardno].type) |t| : (cardno += 1) {
                if (std.ascii.eqlIgnoreCase(t, ether.isa.type))
                    break;
            }
        }
        if (cardno >= MaxEther or cards[cardno].type == null)
            break :probe null;
        const s = fmt.snprint(ether.netif.name[0 .. KNAMELEN - 1], "ether%d", .{ctlrno});
        ether.netif.name[s.len] = 0;
        if (cards[cardno].reset.?(ether) < 0)
            break :probe null;
        break :probe cardno;
    };
    const cardno = found orelse {
        if (dup) |x| alloc.free(x.ptr); // see kstrdup() above
        alloc.free(ether);
        return null;
    };
    ether.isa.type = cards[cardno].type.?;

    // DIFF: see the head of the file.
    // If ether->irq is <0, it is a hack to indicate no interrupt
    if (ether.interrupt) |interrupt| {
        if (ether.isa.irq >= 0)
            arch.intrenable(ether.isa.irq, interrupt, ether, ether.tbdf, netif.nifname(&ether.netif));
    }

    print("#l%d: %s: %dMbps port 0x%lluX irq %d ea %E\n", .{
        ctlrno, ether.isa.type, ether.netif.mbps, ether.isa.port, ether.isa.irq, ea(ether.ea),
    });

    const q = etheroqsize(ether);
    if (ether.oq) |oq| {
        qio.qsetlimit(oq, q);
    } else {
        ether.oq = qio.qopen(q, qio.Qmsg | qio.Qkick, etherkick, ether) orelse
            panic("etherreset %s: can't allocate output queue", .{netif.nifname(&ether.netif)});
    }
    netif.netifinit(&ether.netif, netif.nifname(&ether.netif), Ntypes, 8 * MB);
    ether.netif.alen = Eaddrlen;
    @memcpy(ether.netif.addr[0..Eaddrlen], &ether.ea);
    @memset(ether.netif.bcast[0..Eaddrlen], 0xFF);

    return ether;
}

pub fn ethersetspeed(ether: *Ether, mbps: i32) void {
    if (ether.netif.mbps == mbps)
        return;
    ether.netif.mbps = mbps;
    if (mbps <= 0 or ether.netif.f.len == 0 or ether.oq == null or ether.netif.bypass != null)
        return;
    qio.qsetlimit(ether.oq.?, etheroqsize(ether));
}

pub fn ethersetlink(ether: *Ether, new_: bool) void {
    const old = ether.netif.link;

    const new: i32 = @intFromBool(new_);
    if (old == new)
        return;
    ether.netif.link = new;
    if (ether.netif.f.len == 0 or ether.netif.bypass != null)
        return;
    @memset(&ether.mactab, .{});
    qio.qsetbypass(ether.oq.?, if (ether.netif.link != 0) null else drop);

    if (arch.up() == null or !arch.islo())
        return; // should not print from interrupt

    if (ether.netif.link != 0)
        print("#l%d: %s: link up: %dMbps\n", .{ ether.ctlrno, ether.isa.type, ether.netif.mbps })
    else if (old > 0)
        print("#l%d: %s: link down\n", .{ ether.ctlrno, ether.isa.type });
}

fn etherreset() void {
    // DIFF: no fmtinstall('E', eipfmt); see ea()

    for (0..MaxEther) |ctlrno| {
        const ether = etherprobe(null, ctlrno, null) orelse
            continue;
        etherxx[ctlrno] = ether;
    }

    if (arch.getconf("*noetherprobe") == null) {
        var cardno: usize = 0;
        var ctlrno: usize = 0;
        while (cards[cardno].type != null and ctlrno < MaxEther) {
            if (etherxx[ctlrno] != null) {
                ctlrno += 1;
                continue;
            }
            const ether = etherprobe(cardno, ctlrno, null) orelse {
                cardno += 1;
                continue;
            };
            etherxx[ctlrno] = ether;
            ctlrno += 1;
        }
    }

    netconsole(true);
}

fn ethershutdown() void {
    netconsole(false);

    for (etherxx, 0..) |e, i| {
        const ether = e orelse
            continue;
        const shutdown = ether.shutdown orelse {
            print("#l%d: no shutdown function\n", .{i});
            continue;
        };
        shutdown(ether);
    }
}

const POLY = 0xedb88320;

/// really slow 32 bit crc for ethers
pub fn ethercrc(p: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (p) |c| {
        var b: u32 = c;
        for (0..8) |_| {
            crc = (crc >> 1) ^ (if (((crc ^ b) & 1) != 0) @as(u32, POLY) else 0);
            b >>= 1;
        }
    }
    return crc;
}

/// Parse an Ethernet address, 12 hexadecimal digits with optional
/// colons between the bytes.  Returns -1 if it is too short.
/// from libip/parseether.c
pub fn parseether(to: *[Eaddrlen]u8, from: []const u8) i32 {
    var p: usize = 0;
    for (0..Eaddrlen) |i| {
        if (p >= from.len or from[p] == 0)
            return -1;
        const hi = p;
        p += 1;
        if (p >= from.len or from[p] == 0)
            return -1;
        p += 1;
        to[i] = @truncate(netif.strtoul(from[hi..p], 16).v);
        if (p < from.len and from[p] == ':')
            p += 1;
    }
    return 0;
}

pub const etherdevtab: devmod.Dev = .{
    .dc = 'l',
    .name = "ether",

    .reset = etherreset,
    .shutdown = ethershutdown,
    .attach = etherattach,
    .walk = etherwalk,
    .stat = etherstat,
    .open = etheropen,
    .create = ethercreate,
    .close = etherclose,
    .read = etherread,
    .bread = etherbread,
    .write = etherwrite,
    .bwrite = etherbwrite,
    .wstat = etherwstat,
};

/// M7: ip.  The C's network console (Netconsole, netconsputc and
/// netconsole: kernel print as UDP packets, set up by console=net ...
/// in plan9.ini) is not ported; see the head of the file.
fn netconsole(on: bool) void {
    if (!on)
        return;
    const p = arch.getconf("console") orelse return;
    if (!std.mem.startsWith(u8, p, "net "))
        return;
    print("netconsole: not supported\n", .{});
}

// M7: ip.  From 9/ip/ip.h and 9/ip/ipv6.h, private until the IP stack
// is ported.
const IPaddrlen = 16;
const IP_VER4 = 0x40;
const IP_VER6 = 0x60;
const IP_HLEN4 = 5; // v4: Header length in words
const IP4HDR = IP_HLEN4 << 2; // sizeof(Ip4hdr)
const IP6HDR = 40; // sizeof(Ip6hdr) = 8 + 2*16
const UDP = 17;
const ICMPv6 = 58;
const SRC_LLADDR = 1;
const TARGET_LLADDR = 2;

// M7: ip.  From 9/ip/ipaux.c.
fn v4tov6(v6: *[IPaddrlen]u8, v4: [*]const u8) void {
    v6.* = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, v4[0], v4[1], v4[2], v4[3] };
}

fn get16(p: [*]const u8) u32 {
    return @as(u32, p[0]) << 8 | p[1];
}

/// Dynamic Mac Address Translation (DMAT)
///
/// Wifi does not allow spoofing of the source mac which breaks
/// bridging. To solve this we proxy mac addresses, maintaining
/// a translation table from ip address to destination mac address.
/// Upstream ARP and NDP packets get ther source mac address changed
/// to proxy and a translation entry is added with the original mac
/// for downstream translation. The proxy does not appear in the
/// table.
///
/// The packet is addressed through unchecked pointers, as in the C,
/// which checks lengths by hand.
fn dmatproxy(bp: *Block, upstream: bool, proxy: *const [Eaddrlen]u8, t: *DMAT) void {
    const arp4 = [_]u8{
        0x00, 0x01,
        0x08, 0x00,
        0x06, 0x04,
        0x00,
    };
    var ip: [IPaddrlen]u8 = undefined;
    var mac: [Eaddrlen]u8 = @splat(0xFF);
    var targ: ?[*]const u8 = null;
    var csum: u32 = undefined;
    var proto: u8 = undefined;

    const end = @intFromPtr(bp.wp);
    const pkt: *Etherpkt = @ptrCast(bp.rp);
    var a: [*]u8 = bp.rp + ETHERHDRSIZE; // pkt->data
    if (@intFromPtr(a) >= end)
        return;

    if (upstream)
        pkt.s = proxy.*
    else if (t.map == 0 or (pkt.d[0] & 1) != 0 or !std.mem.eql(u8, &pkt.d, proxy))
        return;

    switch (get16(&pkt.type)) {
        else => return,
        ETIP4, ETIP6 => ipcase: {
            switch (a[0] & 0xF0) {
                else => return,
                IP_VER4 => {
                    if (@intFromPtr(a) + IP4HDR > end or (a[0] & 15) < IP_HLEN4)
                        return;
                    v4tov6(&ip, a + 12 + 4 * @as(usize, @intFromBool(!upstream)));
                    proto = a[9];
                    a += @as(usize, a[0] & 15) * 4;
                },
                IP_VER6 => {
                    if (@intFromPtr(a) + IP6HDR > end)
                        return;
                    @memcpy(&ip, (a + 8 + 16 * @as(usize, @intFromBool(!upstream)))[0..16]);
                    proto = a[6];
                    a += IP6HDR;
                },
            }
            if (!upstream)
                break :ipcase;
            switch (proto) {
                ICMPv6 => {
                    if (@intFromPtr(a) + 8 > end)
                        return;
                    var o: [*]u8 = undefined;
                    switch (a[0]) {
                        else => return,
                        133 => o = a + 8, // Router Solicitation
                        134 => o = a + 8 + 8, // Router Advertisement
                        136 => { // Neighbor Advertisement
                            targ = a + 8;
                            o = a + 8 + 16;
                        },
                        135 => o = a + 8 + 16, // Neighbor Solicitation
                        137 => o = a + 8 + 16 + 16, // Redirect
                    }
                    @memset(&mac, 0xFF);
                    csum = get16(a + 2) ^ 0xFFFF;
                    while (@intFromPtr(o) + 8 <= end and o[1] != 0) {
                        switch (o[0]) {
                            SRC_LLADDR, TARGET_LLADDR => {
                                var i: usize = 0;
                                while (i < Eaddrlen) : (i += 2)
                                    csum +%= get16(o + 2 + i) ^ 0xFFFF;
                                @memcpy(&mac, (o + 2)[0..Eaddrlen]);
                                @memcpy((o + 2)[0..Eaddrlen], proxy);
                                i = 0;
                                while (i < Eaddrlen) : (i += 2)
                                    csum +%= get16(o + 2 + i);
                            },
                            else => {},
                        }
                        o += @as(usize, o[1]) * 8;
                    }
                    while (true) {
                        const c = csum >> 16;
                        if (c == 0) break;
                        csum = (csum & 0xFFFF) + c;
                    }
                    csum ^= 0xFFFF;
                    a[2] = @truncate(csum >> 8);
                    a[3] = @truncate(csum);
                },
                UDP => { // for BOOTP
                    if (@intFromPtr(a) + 42 > end or
                        get16(a) != 68 or
                        get16(a + 2) != 67 or
                        a[8] != 1 or
                        a[9] != 1 or
                        a[10] != Eaddrlen or
                        (a[18] & 0x80) != 0 or
                        std.mem.eql(u8, (a + 36)[0..Eaddrlen], proxy))
                        return;

                    csum = get16(a + 6) ^ 0xFFFF;

                    // set the broadcast flag so response reaches us
                    csum +%= (@as(u32, a[18]) << 8) ^ 0xFFFF;
                    a[18] |= 0x80;
                    csum +%= @as(u32, a[18]) << 8;

                    while (true) {
                        const c = csum >> 16;
                        if (c == 0) break;
                        csum = (csum & 0xFFFF) + c;
                    }
                    csum ^= 0xFFFF;

                    a[6] = @truncate(csum >> 8);
                    a[7] = @truncate(csum);
                    return;
                },
                else => return,
            }
        },
        ETARP => {
            if (@intFromPtr(a) + 26 > end or !std.mem.eql(u8, a[0..arp4.len], &arp4) or (a[7] != 1 and a[7] != 2))
                return;
            v4tov6(&ip, a + 14 + 10 * @as(usize, @intFromBool(!upstream)));
            if (upstream) {
                @memcpy(&mac, (a + 8)[0..Eaddrlen]);
                @memcpy((a + 8)[0..Eaddrlen], proxy);
            }
        },
    }

    while (true) {
        var h: u32 = (@as(u32, ip[IPaddrlen - 1] ^ proxy[2]) << 24 |
            @as(u32, ip[IPaddrlen - 2] ^ proxy[3]) << 16 |
            @as(u32, ip[IPaddrlen - 3] ^ proxy[4]) << 8 |
            @as(u32, ip[IPaddrlen - 4] ^ proxy[5])) % @as(u32, t.tab.len);
        var te: usize = h;
        h &= 63;

        if (upstream) {
            if ((mac[0] & 1) != 0 or std.mem.eql(u8, &mac, proxy))
                return;
            var i: usize = 0;
            while (t.tab[te].valid != 0 and i < t.tab.len) : (i += 1) {
                if (std.mem.eql(u8, &t.tab[te].ip, &ip))
                    break;
                te += 1;
                if (te >= t.tab.len)
                    te = 0;
            }
            t.tab[te].mac = mac;
            t.tab[te].ip = ip;
            t.tab[te].valid = 1;
            t.map |= @as(u64, 1) << @intCast(h);
            if (targ) |tp| {
                @memcpy(&ip, tp[0..IPaddrlen]);
                targ = null;
                continue;
            }
        } else {
            if ((t.map >> @intCast(h)) & 1 == 0)
                return;
            var i: usize = 0;
            while (t.tab[te].valid != 0 and i < t.tab.len) : (i += 1) {
                if (std.mem.eql(u8, &t.tab[te].ip, &ip)) {
                    pkt.d = t.tab[te].mac;
                    return;
                }
                te += 1;
                if (te >= t.tab.len)
                    te = 0;
            }
        }
        return;
    }
}

test "ethercrc" {
    // the CRC-32 check value, before the final inversion
    try std.testing.expectEqual(~@as(u32, 0xCBF43926), ethercrc("123456789"));
}

test "parseether and %E" {
    var a: [Eaddrlen]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), parseether(&a, "00:50:c2:00:01:02"));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ea 0050c2000102", fmt.snprint(&buf, "ea %E", .{ea(a)}));
    try std.testing.expectEqual(@as(i32, 0), parseether(&a, "0050c2000102"));
    try std.testing.expectEqual(@as(i32, -1), parseether(&a, "0050c2"));
}
