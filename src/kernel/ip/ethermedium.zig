//! The Ethernet media ("ether" and "gbe"): binds an IP interface to an
//! Ethernet device through the device's files, runs the processes that
//! read IPv4, IPv6 and ARP packets from it, resolves addresses with ARP
//! (v4) and neighbour discovery (v6), and maps multicast addresses.
//! from 9/ip/ethermedium.c
//!
//! DIFF:
//!   - The media are constants and their routines have the Zig
//!     signatures of ipdat.Medium: errors are returned, argv is the
//!     whole bind request.
//!   - etherbind checks for three arguments; the C checks for two and
//!     then uses argv[2].
//!   - Etherrock's process pointers hold the C's three states (-1 not
//!     started, nil gone, the process) in one atomic word, since Zig
//!     has no (void*)-1 for a pointer and other processes poll them.
//!   - A device's bread cannot return "no block" (see netif.netifbread:
//!     a closed queue reads as an empty block), so the readers take an
//!     empty block where the C takes nil.
//!   - recvarp drops a packet shorter than an Etherarp; the C reads the
//!     header whatever the length.
//!   - The waserror sites: etherbind's are defer and errdefer;
//!     etherunbind's `while(waserror());` are sleeps whose error is
//!     ignored; in the read processes the outer one is the `catch
//!     break` of bread and the inner one is gone, because ipiput4 and
//!     ipiput6 cannot fail; recvarpproc's is the `catch break` around
//!     recvarp; etherareg's is gone, because icmpns6 cannot fail.
//!   - mediumunbindifc returns an error where the C returns a string.
//!   - etheraddmulti and etherdelmulti work out the version (and
//!     panic on a bad one) before they format the address.

const std = @import("std");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("../port/portdat.zig");
const lib = @import("../port/lib.zig");
const proc = @import("../port/proc.zig");
const ql = @import("../port/qlock.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const chan = @import("../port/chan.zig");
const devmod = @import("../port/dev.zig");
const netif = @import("../port/netif.zig");
const p9 = @import("../port/print.zig");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const arp = @import("arp.zig");
const chandial = @import("chandial.zig");
const ip = @import("ip.zig");
const ipv6 = @import("ipv6.zig");
const ipifc = @import("ipifc.zig");
const iproute = @import("iproute.zig");
const icmp6 = @import("icmp6.zig");

const Error = proc.Error;
const Block = ab.Block;
const BLEN = ab.BLEN;
const Chan = portdat.Chan;
const Proc = portdat.Proc;
const Fs = ipdat.Fs;
const Arpent = ipdat.Arpent;
const Ipifc = ipdat.Ipifc;
const Iplifc = ipdat.Iplifc;
const Medium = ipdat.Medium;
const Routehint = ipdat.Routehint;

const IPaddrlen = ipdat.IPaddrlen;
const IPv4addrlen = ipdat.IPv4addrlen;
const IPv4off = ipdat.IPv4off;
const Maxpath = ipdat.Maxpath;
const V4 = ipdat.V4;
const V6 = ipdat.V6;
const RETRANS_TIMER = ipdat.RETRANS_TIMER;
const ipcmp = ipdat.ipcmp;

const ETHERHDRSIZE = netif.ETHERHDRSIZE;
const ETHERMINTU = netif.ETHERMINTU;
const ETARP = netif.ETARP;
const ETIP4 = netif.ETIP4;
const hnputs = ipaux.hnputs;
const nhgets = ipaux.nhgets;

const Etherhdr = extern struct {
    d: [6]u8,
    s: [6]u8,
    t: [2]u8,
};

pub const ethermedium: Medium = .{
    .name = "ether",
    .hsize = ETHERHDRSIZE,
    .mintu = ETHERMINTU,
    .maxtu = ETHERHDRSIZE + 1500,
    .maclen = 6,
    .bind = etherbind,
    .unbind = etherunbind,
    .bwrite = etherbwrite,
    .addmulti = etheraddmulti,
    .delmulti = etherdelmulti,
    .areg = etherareg,
    .pref2addr = etherpref2addr,
};

pub const gbemedium: Medium = .{
    .name = "gbe",
    .hsize = ETHERHDRSIZE,
    .mintu = ETHERMINTU,
    .maxtu = ETHERHDRSIZE + 9000,
    .maclen = 6,
    .bind = etherbind,
    .unbind = etherunbind,
    .bwrite = etherbwrite,
    .addmulti = etheraddmulti,
    .delmulti = etherdelmulti,
    .areg = etherareg,
    .pref2addr = etherpref2addr,
};

/// DIFF: a process pointer of the rock: Starting is the C's (void*)-1,
/// 0 its nil.  See the head of the file.
const Procp = struct {
    v: std.atomic.Value(usize) = .init(Starting),

    const Starting = std.math.maxInt(usize);

    fn set(p: *Procp, x: ?*Proc) void {
        p.v.store(@intFromPtr(x), .release);
    }

    fn starting(p: *const Procp) bool {
        return p.v.load(.acquire) == Starting;
    }

    /// The process, if there is one and it is not `me`.
    fn other(p: *const Procp, me: *Proc) ?*Proc {
        const x = p.v.load(.acquire);
        if (x == 0 or x == Starting or x == @intFromPtr(me))
            return null;
        return @ptrFromInt(x);
    }
};

const Etherrock = struct {
    f: *Fs, // file system we belong to
    arpp: Procp = .{}, // arp process
    read4p: Procp = .{}, // reading process (v4)
    read6p: Procp = .{}, // reading process (v6)
    mchan4: ?*Chan = null, // Data channel for v4
    achan: ?*Chan = null, // Arp channel
    cchan4: ?*Chan = null, // Control channel for v4
    mchan6: ?*Chan = null, // Data channel for v6
    cchan6: ?*Chan = null, // Control channel for v6
};

fn rock(ifc: *Ipifc) *Etherrock {
    return @ptrCast(@alignCast(ifc.arg.?));
}

fn dev(c: *const Chan) *const devmod.Dev {
    return devmod.devtab[c.type];
}

// ethernet arp request
const ARPREQUEST = 1;
const ARPREPLY = 2;

const Etherarp = extern struct {
    d: [6]u8,
    s: [6]u8,
    type: [2]u8,
    hrd: [2]u8,
    pro: [2]u8,
    hln: u8,
    pln: u8,
    op: [2]u8,
    sha: [6]u8,
    spa: [4]u8,
    tha: [6]u8,
    tpa: [4]u8,
};

const nbmsg = "nonblocking";

/// called to bind an IP ifc to an ethernet device
fn etherbind(ifc: *Ipifc, argv: []const []const u8) Error!void {
    var addr: [Maxpath]u8 = undefined;
    var dir: [Maxpath]u8 = undefined;

    // DIFF: the C tests argc < 2 and uses argv[2].
    if (argv.len < 3)
        return error.Ebadarg;

    // get mac address
    {
        const c = try chan.namec(fmt.snprint(addr[0 .. addr.len - 1], "%s/addr", .{argv[2]}), portdat.Aopen, lib.OREAD, 0);
        defer chan.cclose(c);
        const n = try dev(c).read(c, addr[0 .. addr.len - 1], 0);
        if (ipaux.parsemac(&ifc.mac, addr[0..n]) != 6)
            return proc.errorf("could not find mac address", .{});
    }

    const er = alloc.snew(Etherrock);
    er.* = .{ .f = ifc.conv.?.p.?.f.? };

    errdefer {
        if (er.mchan4) |c|
            chan.cclose(c);
        if (er.cchan4) |c|
            chan.cclose(c);
        if (er.mchan6) |c|
            chan.cclose(c);
        if (er.cchan6) |c|
            chan.cclose(c);
        if (er.achan) |c|
            chan.cclose(c);
        alloc.free(er);
    }

    // open ipv4 conversation
    //
    // the dial will fail if the type is already open on
    // this device.
    er.mchan4 = try chandial.chandial(fmt.snprint(addr[0 .. addr.len - 1], "%s!0x800", .{argv[2]}), null, &dir, &er.cchan4); // ETIP4

    // make it non-blocking
    _ = try dev(er.cchan4.?).write(er.cchan4.?, nbmsg, 0);

    // open ipv6 conversation
    //
    // the dial will fail if the type is already open on
    // this device.
    er.mchan6 = try chandial.chandial(fmt.snprint(addr[0 .. addr.len - 1], "%s!0x86DD", .{argv[2]}), null, &dir, &er.cchan6); // ETIP6

    // make it non-blocking
    _ = try dev(er.cchan6.?).write(er.cchan6.?, nbmsg, 0);

    // open arp conversation
    er.achan = try chandial.chandial(fmt.snprint(addr[0 .. addr.len - 1], "%s!0x806", .{argv[2]}), null, null, null); // ETARP

    ifc.arg = er;

    proc.kproc("etherread4", etherread4, ifc);
    proc.kproc("etherread6", etherread6, ifc);
    proc.kproc("recvarpproc", recvarpproc, ifc);
}

/// called from devip due to
/// manual unbind or from one of the reader procs
/// due to read error from the ethernet device.
/// this is called only once!
fn etherunbind(ifc: *Ipifc) void {
    const er = rock(ifc);
    const up = arch.up().?;

    // wait for readers to start
    // (a note must not end the wait: the C's while(waserror());)
    while (er.arpp.starting() or er.read4p.starting() or er.read6p.starting())
        proc.tsleep(&up.sleep, proc.return0, null, 300) catch {};

    if (er.read4p.other(up)) |p|
        _ = proc.postnote(p, true, "unbind", 0);
    if (er.read6p.other(up)) |p|
        _ = proc.postnote(p, true, "unbind", 0);
    if (er.arpp.other(up)) |p|
        _ = proc.postnote(p, true, "unbind", 0);

    // wait for readers to die
    while (er.arpp.other(up) != null or
        er.read4p.other(up) != null or
        er.read6p.other(up) != null)
        proc.tsleep(&up.sleep, proc.return0, null, 300) catch {};

    if (er.mchan4) |c|
        chan.cclose(c);
    if (er.cchan4) |c|
        chan.cclose(c);
    if (er.mchan6) |c|
        chan.cclose(c);
    if (er.cchan6) |c|
        chan.cclose(c);
    if (er.achan) |c|
        chan.cclose(c);

    alloc.free(er);
}

/// called by ipoput with a single block to write with ifc rlock'd
fn etherbwrite(ifc: *Ipifc, bp_: *Block, version: u8, ipa: []const u8, rh: ?*Routehint) Error!void {
    var mac: [6]u8 = undefined;
    const er = rock(ifc);
    var bp = bp_;

    // get mac address of destination
    if (arp.arpget(er.f.arp.?, bp, version, ifc, ipa, &mac, rh)) |a| {
        // check for broadcast or multicast
        bp = multicastarp(er.f, a, &mac, rh) orelse {
            // don't do anything if it's been less than a second since the last
            if (a.utime -% a.ctime < RETRANS_TIMER) {
                arp.arprelease(er.f.arp.?, a); // unlocks arp
                return;
            }
            switch (version) {
                V4 => try sendarpreq(er.f, a), // unlocks arp
                V6 => arp.ndpsendsol(er.f, a), // unlocks arp
                else => p9.panic("etherbwrite: version %d", .{version}),
            }
            return;
        };
    }

    // need to have single block
    if (bp.list != null)
        p9.panic("etherbwrite: bp->list != nil, pc %#p", .{@returnAddress()});

    // make it a single block with space for the ether header
    bp = qio.padblock(bp, ETHERHDRSIZE);
    if (BLEN(bp) < ETHERMINTU)
        bp = qio.adjustblock(bp, ETHERMINTU).?;
    const eh: *Etherhdr = @ptrCast(bp.rp);

    // copy in mac addresses and ether type
    eh.s = ifc.mac[0..6].*;
    eh.d = mac;

    switch (version) {
        V4 => {
            eh.t[0] = 0x08;
            eh.t[1] = 0x00;
            _ = try dev(er.mchan4.?).bwrite(er.mchan4.?, bp, 0);
        },
        V6 => {
            eh.t[0] = 0x86;
            eh.t[1] = 0xDD;
            _ = try dev(er.mchan6.?).bwrite(er.mchan6.?, bp, 0);
        },
        else => p9.panic("etherbwrite2: version %d", .{version}),
    }
}

/// process to read from the ethernet
fn etherread4(a: ?*anyopaque) void {
    const ifc: *Ipifc = @ptrCast(@alignCast(a.?));
    const er = rock(ifc);
    er.read4p.set(arch.up()); // hide identity under a rock for unbind
    while (true) {
        const bp = dev(er.mchan4.?).bread(er.mchan4.?, ifc.maxtu, 0) catch break;
        // DIFF: an empty block is the C's nil; see the head of the file.
        if (BLEN(bp) == 0) {
            ab.freeb(bp);
            break;
        }
        ql.rlock(&ifc.rwlock);
        if (BLEN(bp) <= ETHERHDRSIZE)
            ab.freeb(bp)
        else {
            bp.rp += ETHERHDRSIZE;
            ip.ipiput4(er.f, ifc, bp);
        }
        ql.runlock(&ifc.rwlock);
    }
    if (ipifc.mediumunbindifc(ifc)) |_| {} else |_| er.read4p.set(null); // someone else is doing the unbind
    proc.pexit("hangup", true);
}

/// process to read from the ethernet, IPv6
fn etherread6(a: ?*anyopaque) void {
    const ifc: *Ipifc = @ptrCast(@alignCast(a.?));
    const er = rock(ifc);
    er.read6p.set(arch.up()); // hide identity under a rock for unbind
    while (true) {
        const bp = dev(er.mchan6.?).bread(er.mchan6.?, ifc.maxtu, 0) catch break;
        // DIFF: an empty block is the C's nil; see the head of the file.
        if (BLEN(bp) == 0) {
            ab.freeb(bp);
            break;
        }
        ql.rlock(&ifc.rwlock);
        if (BLEN(bp) <= ETHERHDRSIZE)
            ab.freeb(bp)
        else {
            bp.rp += ETHERHDRSIZE;
            ipv6.ipiput6(er.f, ifc, bp);
        }
        ql.runlock(&ifc.rwlock);
    }
    if (ipifc.mediumunbindifc(ifc)) |_| {} else |_| er.read6p.set(null); // someone else is doing the unbind
    proc.pexit("hangup", true);
}

fn etheraddmulti(ifc: *Ipifc, a: *const [IPaddrlen]u8, _: *const [IPaddrlen]u8) Error!void {
    var mac: [6]u8 = @splat(0);
    var buf: [64]u8 = undefined;
    const er = rock(ifc);

    const version = multicastea(&mac, a);
    const c = switch (version) {
        V4 => er.cchan4.?,
        V6 => er.cchan6.?,
        else => p9.panic("etheraddmulti: version %d", .{version}),
    };
    _ = try dev(c).write(c, fmt.snprint(&buf, "addmulti %E", .{ipaux.ea(&mac)}), 0);
}

fn etherdelmulti(ifc: *Ipifc, a: *const [IPaddrlen]u8, _: *const [IPaddrlen]u8) Error!void {
    var mac: [6]u8 = @splat(0);
    var buf: [64]u8 = undefined;
    const er = rock(ifc);

    const version = multicastea(&mac, a);
    const c = switch (version) {
        V4 => er.cchan4.?,
        V6 => er.cchan6.?,
        else => p9.panic("etherdelmulti: version %d", .{version}),
    };
    _ = try dev(c).write(c, fmt.snprint(&buf, "remmulti %E", .{ipaux.ea(&mac)}), 0);
}

fn newEARP() *Block {
    const bp = ab.allocb(ETHERMINTU);
    bp.wp += ETHERMINTU;
    @memset(bp.rp[0..ETHERMINTU], 0);
    return bp;
}

/// send an ethernet arp
/// (only v4, v6 uses the neighbor discovery, rfc1970)
fn sendarpreq(f: *Fs, a: *Arpent) Error!void {
    const ifc = a.ifc.?;
    const er = rock(ifc);
    var src: [IPv4addrlen]u8 = undefined;

    const targ: [IPv4addrlen]u8 = a.ip[IPv4off..].*;
    arp.arpcontinue(f.arp.?, a);

    if (!ipifc.ipv4local(ifc, &src, 0, &targ))
        return;

    const bp = newEARP();
    const e: *Etherarp = @ptrCast(bp.rp);
    e.tpa = targ;
    e.spa = src;
    e.sha = ifc.mac[0..6].*;
    @memset(&e.d, 0xff); // ethernet broadcast
    e.s = ifc.mac[0..6].*;

    hnputs(&e.type, ETARP);
    hnputs(&e.hrd, 1);
    hnputs(&e.pro, ETIP4);
    e.hln = @sizeOf(@TypeOf(e.sha));
    e.pln = @sizeOf(@TypeOf(e.spa));
    hnputs(&e.op, ARPREQUEST);

    _ = try dev(er.achan.?).bwrite(er.achan.?, bp, 0);
}

/// send a gratuitous arp to refresh arp caches
fn sendgarp(ifc: *Ipifc, ipa: *const [IPaddrlen]u8) Error!void {
    const er = rock(ifc);

    const bp = newEARP();
    const e: *Etherarp = @ptrCast(bp.rp);
    e.tpa = ipa[IPv4off..].*;
    e.spa = ipa[IPv4off..].*;
    e.sha = ifc.mac[0..6].*;
    @memset(&e.d, 0xff); // ethernet broadcast
    e.s = ifc.mac[0..6].*;

    hnputs(&e.type, ETARP);
    hnputs(&e.hrd, 1);
    hnputs(&e.pro, ETIP4);
    e.hln = @sizeOf(@TypeOf(e.sha));
    e.pln = @sizeOf(@TypeOf(e.spa));
    hnputs(&e.op, ARPREQUEST);

    _ = try dev(er.achan.?).bwrite(er.achan.?, bp, 0);
}

/// The C's static eprinted of recvarp.
var eprinted: [4]u8 = @splat(0);

fn recvarp(ifc: *Ipifc) Error!void {
    const er = rock(ifc);

    const ebp = try dev(er.achan.?).bread(er.achan.?, ifc.maxtu, 0);
    // DIFF: an empty block is the C's nil; see the head of the file.
    if (BLEN(ebp) == 0) {
        ab.freeb(ebp);
        return error.Ehungup;
    }
    // DIFF: the C does not look at the length.
    if (BLEN(ebp) < @sizeOf(Etherarp)) {
        ab.freeb(ebp);
        return;
    }

    ql.rlock(&ifc.rwlock);

    const e: *Etherarp = @ptrCast(ebp.rp);
    sw: switch (nhgets(&e.op)) {
        ARPREPLY => {
            // make sure not to enter multi/broadcat address
            if (e.sha[0] & 1 != 0)
                break :sw;

            // check for machine using my ip address
            if (arp.arpforme(er.f, V4, &e.spa, &e.tpa, ifc) != 0) {
                if (!std.mem.eql(u8, &e.sha, ifc.mac[0..6])) {
                    p9.print("arprep: 0x%E/0x%E also has ip addr %V\n", .{ ipaux.ea(&e.s), ipaux.ea(&e.sha), ipaux.v4(&e.spa) });
                    break :sw;
                }
            }

            // refresh what we know about sender
            _ = arp.arpenter(er.f, V4, &e.spa, &e.sha, &e.tpa, ifc, true);
        },

        ARPREQUEST => {
            // don't reply to multi/broadcat addresses
            if (e.sha[0] & 1 != 0)
                break :sw;

            // don't answer arps till we know who we are
            if (ifc.lifc == null)
                break :sw;

            // check for machine using my ip or ether address
            if (arp.arpforme(er.f, V4, &e.spa, &e.tpa, ifc) != 0) {
                if (!std.mem.eql(u8, &e.sha, ifc.mac[0..6])) {
                    if (!std.mem.eql(u8, &eprinted, &e.spa)) {
                        // print only once
                        p9.print("arpreq: 0x%E also has ip addr %V\n", .{ ipaux.ea(&e.sha), ipaux.v4(&e.spa) });
                        eprinted = e.spa;
                    }
                    break :sw;
                }
            }

            // when request is for our address or systems we're proxying for,
            // enter senders address into arp table and reply, otherwise just
            // refresh the senders address.
            const forme = arp.arpforme(er.f, V4, &e.tpa, &e.spa, ifc) != 0;
            if (arp.arpenter(er.f, V4, &e.spa, &e.sha, &e.tpa, ifc, !forme) < 0 or !forme)
                break :sw;

            const rbp = newEARP();
            const r: *Etherarp = @ptrCast(rbp.rp);
            hnputs(&r.type, ETARP);
            hnputs(&r.hrd, 1);
            hnputs(&r.pro, ETIP4);
            r.hln = @sizeOf(@TypeOf(r.sha));
            r.pln = @sizeOf(@TypeOf(r.spa));
            hnputs(&r.op, ARPREPLY);
            r.tha = e.sha;
            r.tpa = e.spa;
            r.sha = ifc.mac[0..6].*;
            r.spa = e.tpa;
            r.d = e.sha;
            r.s = ifc.mac[0..6].*;

            ql.runlock(&ifc.rwlock);
            ab.freeb(ebp);

            _ = try dev(er.achan.?).bwrite(er.achan.?, rbp, 0);
            return;
        },

        else => {},
    }

    ql.runlock(&ifc.rwlock);
    ab.freeb(ebp);
}

fn recvarpproc(v: ?*anyopaque) void {
    const ifc: *Ipifc = @ptrCast(@alignCast(v.?));
    const er = rock(ifc);

    er.arpp.set(arch.up());
    while (true)
        recvarp(ifc) catch break;
    if (ipifc.mediumunbindifc(ifc)) |_| {} else |_| er.arpp.set(null); // someone else is doing the unbind
    proc.pexit("hangup", true);
}

fn multicastea(ea: *[6]u8, ipa: *const [IPaddrlen]u8) u8 {
    const x = ipaux.ipismulticast(ipa);
    switch (x) {
        V4 => {
            ea[0] = 0x01;
            ea[1] = 0x00;
            ea[2] = 0x5e;
            ea[3] = ipa[13] & 0x7f;
            ea[4] = ipa[14];
            ea[5] = ipa[15];
        },
        V6 => {
            ea[0] = 0x33;
            ea[1] = 0x33;
            ea[2] = ipa[12];
            ea[3] = ipa[13];
            ea[4] = ipa[14];
            ea[5] = ipa[15];
        },
        else => {},
    }
    return x;
}

/// fill in an arp entry for broadcast or multicast
/// addresses.  Return the first queued packet for the
/// IP address.
fn multicastarp(f: *Fs, a: *Arpent, mac: *[6]u8, rh: ?*Routehint) ?*Block {
    // is it broadcast?
    if (ipifc.ipforme(f, &a.ip) == ipdat.Rbcast) {
        @memset(mac[0..a.ifc.?.m.?.maclen], 0xff);
        return arp.arpresolve(f.arp.?, a, mac, rh);
    }

    // if multicast, fill in mac
    switch (multicastea(mac, &a.ip)) {
        V4, V6 => return arp.arpresolve(f.arp.?, a, mac, rh),
        else => {},
    }

    // let arp take care of it
    return null;
}

pub fn ethermediumlink() void {
    ipifc.addipmedium(&ethermedium);
    ipifc.addipmedium(&gbemedium);
}

fn etherpref2addr(pref: *[IPaddrlen]u8, ea: []const u8) void {
    pref[8] = ea[0] ^ 0x2;
    pref[9] = ea[1];
    pref[10] = ea[2];
    pref[11] = 0xFF;
    pref[12] = 0xFE;
    pref[13] = ea[3];
    pref[14] = ea[4];
    pref[15] = ea[5];
}

fn etherareg(f: *Fs, ifc: *Ipifc, lifc: *Iplifc, ipa: *const [IPaddrlen]u8) Error!void {
    const tdad = "dad6";
    var a: [IPaddrlen]u8 = undefined;

    if (ipcmp(ipa, &ipaux.IPnoaddr) == 0 or ipcmp(ipa, &ipaux.v4prefix) == 0)
        return;

    if (ipaux.isv4(ipa)) {
        try sendgarp(ifc, ipa);
        return;
    }

    if ((lifc.type & ipdat.Rv4) != 0)
        return;

    if (!lifc.tentative) {
        icmp6.icmpna6(f, &lifc.local, &ipaux.v6allnodesL, ipa, ifc.mac[0..6], 1 << 5);
        return;
    }

    if (ipcmp(&lifc.local, ipa) != 0)
        return;

    // temporarily add route for duplicate address detection
    ipaux.ipv62smcast(&a, ipa);
    iproute.addroute(f, &a, &ipaux.IPallbits, &ipaux.v6Unspecified, &ipaux.IPallbits, ipa, ipdat.Rmulti, ifc, tdad);
    icmp6.icmpns6(f, null, ipdat.SRC_UNSPEC, ipa, ipdat.TARG_MULTI, ifc.mac[0..6]);
    iproute.delroute(f, &a, &ipaux.IPallbits, &ipaux.v6Unspecified, &ipaux.IPallbits, ipa, ipdat.Rmulti, ifc, tdad);
}
