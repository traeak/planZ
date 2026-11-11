//! The ipifc protocol: the interfaces of an IP stack, their media,
//! their local addresses, and the cache of addresses the stack answers
//! to.
//! from 9/ip/ipifc.c
//!
//! DIFF:
//!   - Ipself, Ipselftab, hashipa, NHASH and NCACHE are in ipdat.zig.
//!   - The functions that return an error string in C (ipifcbind,
//!     ipifcunbindmedium, ipifcunbind, mediumunbindifc, ipifcsetmtu,
//!     ipifcadd, ipifcdellifc, ipifcdel, ipifcconnect, ipifcra6,
//!     ipifcctl, ipifcadd6, ipifcdel6) return Error!void: rule 2 of
//!     ipdat.zig.  ipifcconnect therefore ignores every error of its
//!     implicit "bind pkt", where the C ignores a returned string but
//!     passes on what the medium's bind raises.
//!   - addselfcache, delselfcache, ipifcregisteraddr and
//!     ipifcregisterproxy cannot fail here: addroute, delroute and
//!     smalloc do not raise, and what a medium's addmulti, delmulti
//!     and areg (and multicastreportfn) return is dropped on the spot
//!     as the C's inner waserror does.  So the waserror sites around
//!     them (ipifcadd, addselfcache, ipifcaddmulti, ipifcdelmulti,
//!     ipifcregisterproxy) have nothing left to catch and are gone;
//!     locks are released on the one path there is.
//!   - Medium.unbind cannot fail (ipdat.zig), so ipifcunbindmedium has
//!     no waserror around it.
//!   - ipifckick is a qio.Bypass and returns nothing: an error from
//!     writing the loopback queue is dropped (the block is gone
//!     either way), where the C raises it to the writer.
//!   - Output buffers hold no NUL (rule 3), so the state, local and
//!     selftab texts may fill the buffer to its last byte where the
//!     C's snprint stops one short.
//!   - Medium.pref2addr gets ifc.mac[0..maclen], the C the whole
//!     array.
//!   - findipifcstr takes the number with netif.strtou (32 bits, the
//!     C's long is as wide); a number too large is no interface
//!     either way.
//!   - mtu, speed and delay stay ints where they are parsed, and are
//!     checked against the usize limits of the medium afterwards.

const std = @import("std");
const arch = @import("../arch.zig");
const proc = @import("../port/proc.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const ql = @import("../port/qlock.zig");
const portclock = @import("../port/portclock.zig");
const netif = @import("../port/netif.zig");
const p9 = @import("../port/print.zig");
const fmt = @import("fmt");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const iproute = @import("iproute.zig");
const ipmod = @import("ip.zig");
const devip = @import("devip.zig");
const nullmed = @import("nullmedium.zig");
const loopmed = @import("loopbackmedium.zig");

const Error = ipdat.Error;
const Block = ipdat.Block;
const Conv = ipdat.Conv;
const Fs = ipdat.Fs;
const Ipifc = ipdat.Ipifc;
const Iplifc = ipdat.Iplifc;
const Iplink = ipdat.Iplink;
const Ipmulti = ipdat.Ipmulti;
const Ipself = ipdat.Ipself;
const Ipselftab = ipdat.Ipselftab;
const Medium = ipdat.Medium;
const Proto = ipdat.Proto;
const Routehint = ipdat.Routehint;
const Routerparams = ipdat.Routerparams;

const IPaddrlen = ipdat.IPaddrlen;
const IPv4addrlen = ipdat.IPv4addrlen;
const IPv4off = ipdat.IPv4off;
const V4 = ipdat.V4;
const V6 = ipdat.V6;
const NHASH = ipdat.NHASH;
const Rv4 = ipdat.Rv4;
const Rifc = ipdat.Rifc;
const Rptpt = ipdat.Rptpt;
const Runi = ipdat.Runi;
const Rbcast = ipdat.Rbcast;
const Rmulti = ipdat.Rmulti;
const Rproxy = ipdat.Rproxy;
const Rtrans = ipdat.Rtrans;

const ipmove = ipdat.ipmove;
const ipcmp = ipdat.ipcmp;
const hashipa = ipdat.hashipa;
const NOW = ipdat.NOW;
const islinklocal = ipdat.islinklocal;
const isv6mcast = ipdat.isv6mcast;
const isula = ipdat.isula;
const isv4 = ipaux.isv4;
const maskip = ipaux.maskip;
const parseip = ipaux.parseip;
const parseipandmask = ipaux.parseipandmask;
const IPnoaddr = &ipaux.IPnoaddr;
const IPallbits = &ipaux.IPallbits;
const v6loopback = &ipaux.v6loopback;
const addroute = iproute.addroute;
const delroute = iproute.delroute;
const unboundmedium = &nullmed.unboundmedium;
const loopbackmedium = &loopmed.loopbackmedium;

const qlock = ql.qlock;
const qunlock = ql.qunlock;
const rlock = ql.rlock;
const runlock = ql.runlock;
const wlock = ql.wlock;
const wunlock = ql.wunlock;
const canrlock = ql.canrlock;
const atoi = netif.atoi;
const strtoul = netif.strtoul;
const streq = struct {
    fn f(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
}.f;

const Maxmedia = 32;
const Nself = Maxmedia * 5;
const QMAX = 1024 * 1024;

var media: [Maxmedia]?*const Medium = @splat(null);
pub var multicastreportfn: ?*const fn (f: *Fs, ifc: *Ipifc, ma: *const [IPaddrlen]u8, ia: *const [IPaddrlen]u8, done: bool) Error!void = null;

const tifc = "ifc ";

const Ebound = "interface already bound";
const Eunbound = "interface not bound";

// UGH
const unknownv6 = 0;
const unspecifiedv6 = 1;
const linklocalv6 = 2;
const ulav6 = 3;
const globalv6 = 4;

/// The C's (Ipifc*)c->ptcl.
fn ifcof(c: *Conv) *Ipifc {
    return @ptrCast(@alignCast(c.ptcl.?));
}

fn v6addrtype(addr: *const [IPaddrlen]u8) i32 {
    if (isv4(addr) or ipcmp(addr, IPnoaddr) == 0)
        return unknownv6
    else if (islinklocal(addr) or ipcmp(addr, v6loopback) == 0 or
        isv6mcast(addr) and (addr[1] & 0xF) <= ipdat.Link_local_scop)
        return linklocalv6
    else if (isula(addr))
        return ulav6
    else
        return globalv6;
}

fn comprefixlen(a: []const u8, b: []const u8, n: usize) usize {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var c: u8 = a[i] ^ b[i];
        if (c == 0)
            continue;
        i <<= 3;
        while ((c & 0x80) == 0) : (i += 1)
            c <<= 1;
        return i;
    }
    return i << 3;
}

/// link in a new medium
pub fn addipmedium(med: *const Medium) void {
    for (media[0 .. media.len - 1]) |*mp| {
        if (mp.* == null) {
            mp.* = med;
            return;
        }
    }
    p9.panic("addipmedium: too many mediums", .{});
}

/// find the medium with this name
pub fn ipfindmedium(name: []const u8) ?*const Medium {
    for (media) |mp| {
        const m = mp orelse break;
        if (streq(m.name, name))
            return m;
    }
    return null;
}

/// attach a device (or pkt driver) to the interface.
/// called with c locked
fn ipifcbind(c: *Conv, argv: []const []const u8) Error!void {
    const argc = argv.len;

    if (argc < 2)
        return error.Ebadarg;

    // bind the device to the interface
    const m = ipfindmedium(argv[1]) orelse
        return proc.errorf("unknown interface type", .{});

    const ifc = ifcof(c);
    wlock(&ifc.rwlock);
    if (ifc.m != null) {
        wunlock(&ifc.rwlock);
        return proc.errorf("%s", .{Ebound});
    }
    ifc.m = unboundmedium; // fake until bound
    ifc.arg = null;

    // set the bound device name
    @memset(&ifc.dev, 0);
    if (argc > 2) {
        const n = @min(argv[2].len, ifc.dev.len);
        @memcpy(ifc.dev[0..n], argv[2][0..n]);
    } else {
        _ = fmt.snprint(ifc.dev[0 .. ifc.dev.len - 1], "%s%d", .{ m.name, c.x });
    }
    ifc.dev[ifc.dev.len - 1] = 0;

    // set up parameters
    ifc.maxtu = m.maxtu;
    ifc.delay = 40;
    ifc.speed = 0;

    // default router paramters
    ifc.rp = c.p.?.f.?.v6p.?.rp;
    wunlock(&ifc.rwlock);

    {
        errdefer {
            wlock(&ifc.rwlock);
            ifc.m = null;
            wunlock(&ifc.rwlock);
        }
        if (m != loopbackmedium)
            try loopbackmedium.bind.?(ifc, argv);
        try m.bind.?(ifc, argv);
    }

    wlock(&ifc.rwlock);
    // switch to real medium
    ifc.m = m;
    if (!m.unbindonclose)
        c.inuse += 1;

    // any ancillary structures (like routes) no longer pertain
    iproute.flushrouteifc(c.p.?.f.?, ifc);

    // reopen all the queues closed by a previous unbind
    if (c.rq) |q| qio.qreopen(q);
    if (c.eq) |q| qio.qreopen(q);
    if (c.sq) |q| qio.qreopen(q);
    wunlock(&ifc.rwlock);
}

/// detach a medium from an interface, close the interface
/// ifc->conv is locked, ifc is wlocked
fn ipifcunbindmedium(ifc: *Ipifc, m_: ?*const Medium) Error!void {
    const c = ifc.conv.?;

    const m = m_ orelse return proc.errorf("%s", .{Eunbound});
    if (m == unboundmedium)
        return proc.errorf("%s", .{Eunbound});

    // disassociate logical interfaces
    while (ifc.lifc != null)
        ipifcdellifc(ifc, &ifc.lifc) catch {};

    // disassociate device
    if (m.unbind) |unbind| {
        ifc.m = unboundmedium; // fake until unbound
        wunlock(&ifc.rwlock);
        qunlock(&c.qlock);
        unbind(ifc);
        qlock(&c.qlock);
        wlock(&ifc.rwlock);
    }

    @memset(&ifc.dev, 0);

    ifc.reflect = false;
    ifc.reassemble = false;

    // close queues to stop queuing of packets
    qio.qclose(c.rq);
    qio.qclose(c.wq);
    qio.qclose(c.sq);

    // dissociate routes
    iproute.flushrouteifc(c.p.?.f.?, ifc);
    ifc.m = null;
    ifc.arg = null;

    if (!m.unbindonclose)
        c.inuse -= 1;
}

/// called from Ipifcproto->unbind,
/// with ifc->conv locked.
fn ipifcunbind(ifc: *Ipifc) Error!void {
    wlock(&ifc.rwlock);
    defer wunlock(&ifc.rwlock);
    return ipifcunbindmedium(ifc, ifc.m);
}

/// called from medium at any time to unbind
/// an interface in case of an error such as
/// usb ethernet being un-plugged.
pub fn mediumunbindifc(ifc: *Ipifc) Error!void {
    rlock(&ifc.rwlock);
    const m_ = ifc.m;
    runlock(&ifc.rwlock);

    const m = m_ orelse return proc.errorf("%s", .{Eunbound});
    if (m == unboundmedium)
        return proc.errorf("%s", .{Eunbound});

    const c = ifc.conv.?;
    qlock(&c.qlock);
    defer qunlock(&c.qlock);
    wlock(&ifc.rwlock);
    defer wunlock(&ifc.rwlock);
    if (ifc.m != m)
        return proc.errorf("%s", .{Eunbound});
    return ipifcunbindmedium(ifc, m);
}

const sfixedformat = "device %s maxtu %d sendra %d recvra %d mflag %d oflag %d" ++
    " maxraint %d minraint %d linkmtu %d reachtime %d rxmitra %d ttl %d routerlt %d" ++
    " pktin %lud pktout %lud errin %lud errout %lud speed %d delay %d\n";

const slineformat = "\t%-40I %-10M %-40I %-12lud %-12lud\n";

fn ipifcstate(c: *Conv, state: []u8) usize {
    const ifc = ifcof(c);
    rlock(&ifc.rwlock);
    var m = fmt.snprint(state, sfixedformat, .{
        ifc.devname(),   ifc.maxtu,        @intFromBool(ifc.sendra6), @intFromBool(ifc.recvra6),
        ifc.rp.mflag,    ifc.rp.oflag,     ifc.rp.maxraint,           ifc.rp.minraint,
        ifc.rp.linkmtu,  ifc.rp.reachtime, ifc.rp.rxmitra,            ifc.rp.ttl,
        ifc.rp.routerlt, ifc.in,           ifc.out,                   ifc.inerr,
        ifc.outerr,      ifc.speed,        ifc.delay,
    }).len;

    var lifc = ifc.lifc;
    while (lifc) |l| : (lifc = l.next)
        m += fmt.snprint(state[m..], slineformat, .{
            ipaux.ip(&l.local), ipaux.mask(&l.mask), ipaux.ip(&l.remote), l.validlt, l.preflt,
        }).len;
    if (ifc.lifc == null)
        m += fmt.snprint(state[m..], "\n", .{}).len;
    runlock(&ifc.rwlock);
    return m;
}

fn ipifclocal(c: *Conv, state: []u8) usize {
    const ifc = ifcof(c);
    rlock(&ifc.rwlock);
    var m: usize = 0;
    var lifc = ifc.lifc;
    while (lifc) |l| : (lifc = l.next) {
        m += fmt.snprint(state[m..], "%-40.40I ->", .{ipaux.ip(&l.local)}).len;
        var link = l.link;
        while (link) |lk| : (link = lk.lifclink)
            m += fmt.snprint(state[m..], " %-40.40I", .{ipaux.ip(&lk.self.?.a)}).len;
        m += fmt.snprint(state[m..], "\n", .{}).len;
    }
    runlock(&ifc.rwlock);
    return m;
}

fn ipifcinuse(c: *Conv) bool {
    const ifc = ifcof(c);
    return ifc.m != null;
}

fn ipifcadjustburst(ifc: *Ipifc) void {
    var burst: i32 = @truncate(@divTrunc(@as(i64, ifc.delay) * ifc.speed, 8000));
    if (burst < ifc.maxtu)
        burst = @truncate(@as(i64, @intCast(ifc.maxtu)));
    ifc.burst = burst;
}

/// change an interface's burst delay
/// ifc must be bound and wlock'd
fn ipifcsetdelay(ifc: *Ipifc, delay_: i32) void {
    var delay = delay_;
    if (delay < 0)
        delay = 0
    else if (delay > 1000)
        delay = 1000;
    ifc.delay = delay;
    ipifcadjustburst(ifc);
}

/// change an interface's baud rate
/// ifc must be bound and wlock'd
fn ipifcsetspeed(ifc: *Ipifc, speed_: i32) void {
    var speed = speed_;
    if (speed < 0)
        speed = 0;
    ifc.speed = speed;
    ifc.load = 0;
    ipifcadjustburst(ifc);
}

/// change an interface's mtu
/// ifc must be bound and wlock'd
fn ipifcsetmtu(ifc: *Ipifc, mtu: i32) Error!void {
    const m = ifc.m.?;
    if (mtu < m.mintu or mtu > m.maxtu)
        return error.Ebadarg;
    ifc.maxtu = @intCast(mtu);
    ipifcadjustburst(ifc);
}

pub fn ipifcoput(ifc: *Ipifc, bp_: *Block, version: u8, ip: []const u8, rh: ?*Routehint) Error!void {
    if (ifc.speed != 0) {
        const now = arch.MACHP(0).ticks;
        const dt: i32 = @bitCast(portclock.tk2ms(now -% ifc.ticks));
        ifc.ticks = now;
        ifc.load -%= @truncate(@divTrunc(@as(i64, dt) * ifc.speed, 8000));
        if (ifc.load < 0 or dt < 0 or dt > 1000)
            ifc.load = 0
        else if (ifc.load > ifc.burst) {
            qio.freeblist(bp_);
            return;
        }
    }
    const bp = qio.concatblock(bp_);
    ifc.load +%= @truncate(@as(i64, @intCast(ab.BLEN(bp))));
    ifc.out +%= 1;
    return ifc.m.?.bwrite.?(ifc, bp, version, ip, rh);
}

/// called when a process writes to an interface's 'data'
fn ipifckick(x: ?*anyopaque, bp: *Block) void {
    const c: *Conv = @ptrCast(@alignCast(x.?));

    const ifc = ifcof(c);
    const q = ifc.loopback;
    if (q == null or ifc.lifc == null) {
        ab.freeb(bp);
        return;
    }
    const conv = ifc.conv.?;
    if (conv.snoopers.ref > 0)
        _ = qio.qpass(conv.sq.?, qio.copyblock(bp, ab.BLEN(bp)));
    // DIFF: a Bypass returns nothing; qbwrite has taken bp either way.
    _ = qio.qbwrite(q.?, bp) catch {};
}

/// called when a new ipifc structure is created
fn ipifccreate(c: *Conv) Error!void {
    c.rq = qio.qopen(QMAX, 0, null, null);
    c.wq = qio.qbypass(ipifckick, c);
    c.sq = qio.qopen(QMAX, 0, null, null);
    if (c.rq == null or c.wq == null or c.sq == null)
        return error.Enomem;

    const ifc = ifcof(c);
    ifc.* = .{};
    ifc.conv = c;
    ifc.m = null;
    ifc.reflect = false;
    ifc.reassemble = false;
}

/// called after last close of ipifc data or ctl
fn ipifcclose(c: *Conv) void {
    const ifc = ifcof(c);
    const m = ifc.m;

    if (m != null and m.?.unbindonclose)
        ipifcunbind(ifc) catch {};
}

/// add an address to an interface.
pub fn ipifcadd(ifc: *Ipifc, argv: []const []const u8, tentative_: bool, lifcp: ?*const Iplifc) Error!void {
    var ip: [IPaddrlen]u8 = @splat(0);
    var mask: [IPaddrlen]u8 = @splat(0);
    var rem: [IPaddrlen]u8 = @splat(0);
    var bcast: [IPaddrlen]u8 = undefined;
    var net: [IPaddrlen]u8 = undefined;
    const argc = argv.len;
    var tentative = tentative_;

    var mtu: i32 = 0;
    var typ: u16 = Rifc;
    if (argc < 2 or argc > 6)
        return error.Ebadarg;
    if (argc >= 6) {
        if (std.mem.find(u8, argv[5], "proxy") != null)
            typ |= Rproxy;
        if (std.mem.find(u8, argv[5], "trans") != null)
            typ |= Rtrans;
    }
    if (argc >= 5)
        mtu = @bitCast(strtoul(argv[4], 0).v);
    switch (argc) {
        4, 5, 6 => {
            if (parseipandmask(&ip, &mask, argv[1], argv[2]) == -1 or parseip(&rem, argv[3]) == -1)
                return error.Ebadip;
            maskip(&rem, &mask, &net);
        },
        3 => {
            if (parseipandmask(&ip, &mask, argv[1], argv[2]) == -1)
                return error.Ebadip;
            maskip(&ip, &mask, &rem);
            maskip(&rem, &mask, &net);
        },
        2 => {
            if (parseip(&ip, argv[1]) == -1)
                return error.Ebadip;
            mask = ipaux.defmask(&ip).*;
            maskip(&ip, &mask, &rem);
            maskip(&rem, &mask, &net);
        },
        else => unreachable,
    }

    // check for point-to-point interface
    // skip v6 loopback, it's a special address
    if (ipcmp(&ip, v6loopback) != 0 and ipcmp(&mask, IPallbits) == 0)
        typ |= Rptpt;

    if (isv4(&ip) or ipcmp(&ip, IPnoaddr) == 0) {
        typ |= Rv4;
        tentative = false;
    }

    wlock(&ifc.rwlock);
    if (ifc.m == null or ifc.m == unboundmedium) {
        wunlock(&ifc.rwlock);
        return proc.errorf("%s", .{Eunbound});
    }
    const f = ifc.conv.?.p.?.f.?;
    // DIFF: no waserror; nothing below can fail.  See the head of the
    // file.

    if (mtu > 0)
        ipifcsetmtu(ifc, mtu) catch {};

    var lifc: *Iplifc = undefined;
    done: {
        // ignore if this is already a local address for this ifc
        if (iplocalonifc(ifc, &ip)) |l| {
            lifc = l;
            if (lifcp) |lp| {
                if (!lifc.onlink and lp.onlink) {
                    lifc.onlink = true;
                    addroute(f, &lifc.remote, &lifc.mask, &ip, IPallbits, &lifc.remote, lifc.type & ~Rtrans, ifc, tifc);
                    if (v6addrtype(&ip) != linklocalv6)
                        addroute(f, &lifc.remote, &lifc.mask, &ip, IPnoaddr, &lifc.remote, lifc.type, ifc, tifc);
                }
                lifc.autoflag = lp.autoflag;
                lifc.validlt = lp.validlt;
                lifc.preflt = lp.preflt;
                lifc.origint = lp.origint;
            }
            if (lifc.tentative != tentative) {
                lifc.tentative = tentative;
                break :done;
            }
            wunlock(&ifc.rwlock);
            return;
        }

        // add the address to the list of logical ifc's for this ifc
        lifc = alloc.snew(Iplifc);
        lifc.* = .{};
        ipmove(&lifc.local, &ip);
        ipmove(&lifc.mask, &mask);
        ipmove(&lifc.remote, &rem);
        ipmove(&lifc.net, &net);
        lifc.type = typ;
        lifc.tentative = tentative;
        if (lifcp) |lp| {
            lifc.onlink = lp.onlink;
            lifc.autoflag = lp.autoflag;
            lifc.validlt = lp.validlt;
            lifc.preflt = lp.preflt;
            lifc.origint = lp.origint;
        } else { // default values
            lifc.onlink = true;
            lifc.autoflag = true;
            lifc.validlt = ~@as(u32, 0);
            lifc.preflt = ~@as(u32, 0);
            lifc.origint = NOW() / 1000;
        }
        lifc.next = null;

        var l = &ifc.lifc;
        while (l.*) |x| l = &x.next;
        l.* = lifc;

        // add route for this logical interface
        if (lifc.onlink) {
            addroute(f, &rem, &mask, &ip, IPallbits, &rem, typ & ~Rtrans, ifc, tifc);
            if (v6addrtype(&ip) != linklocalv6)
                addroute(f, &rem, &mask, &ip, IPnoaddr, &rem, typ, ifc, tifc);
        }

        addselfcache(f, ifc, lifc, &ip, Runi);

        // register point-to-point proxy
        if (typ & Rptpt != 0) {
            if (typ & Rproxy != 0)
                ipifcregisterproxy(f, ifc, &rem, true);
            break :done;
        }

        // register local ip if proxy
        if (typ & Rproxy != 0)
            ipifcregisterproxy(f, ifc, &ip, true);

        if (typ & Rv4 != 0) {
            // add subnet directed broadcast address to the self cache
            for (&bcast, ip, mask) |*b, i, m|
                b.* = (i & m) | ~m;
            addselfcache(f, ifc, lifc, &bcast, Rbcast);

            // add subnet directed network address to the self cache
            for (&bcast, ip, mask) |*b, i, m|
                b.* = (i & m) & m;
            addselfcache(f, ifc, lifc, &bcast, Rbcast);

            addselfcache(f, ifc, lifc, &ipaux.IPv4bcast, Rbcast);

            // add all nodes multicast address
            addselfcache(f, ifc, lifc, &ipaux.IPv4allsys, Rmulti);
        } else {
            if (ipcmp(&ip, v6loopback) == 0) {
                // add node-local mcast address
                addselfcache(f, ifc, lifc, &ipaux.v6allnodesN, Rmulti);

                // add route for all node multicast
                addroute(f, &ipaux.v6allnodesN, &ipaux.v6allnodesNmask, &ip, IPallbits, &ipaux.v6allnodesN, Rmulti, ifc, tifc);
            }

            // add all nodes multicast address
            addselfcache(f, ifc, lifc, &ipaux.v6allnodesL, Rmulti);

            // add route for all nodes multicast
            addroute(f, &ipaux.v6allnodesL, &ipaux.v6allnodesLmask, &ip, IPallbits, &ipaux.v6allnodesL, Rmulti, ifc, tifc);

            // add solicited-node multicast address
            ipaux.ipv62smcast(&bcast, &ip);
            addselfcache(f, ifc, lifc, &bcast, Rmulti);
        }
    }

    wunlock(&ifc.rwlock);

    rlock(&ifc.rwlock);
    ipifcregisteraddr(f, ifc, lifc, &ip);
    runlock(&ifc.rwlock);
}

/// remove a logical interface from an ifc
/// called with ifc wlock'd
fn ipifcdellifc(ifc: *Ipifc, l: *?*Iplifc) Error!void {
    const lifc = l.* orelse
        return proc.errorf("address not on this interface", .{});
    const f = ifc.conv.?.p.?.f.?;

    l.* = lifc.next;

    // disassociate any addresses
    while (lifc.link) |link|
        delselfcache(f, ifc, lifc, &link.self.?.a);

    // remove the route for this logical interface
    if (lifc.onlink) {
        delroute(f, &lifc.remote, &lifc.mask, &lifc.local, IPallbits, &lifc.remote, lifc.type & ~Rtrans, ifc, tifc);
        if (v6addrtype(&lifc.local) != linklocalv6)
            delroute(f, &lifc.remote, &lifc.mask, &lifc.local, IPnoaddr, &lifc.remote, lifc.type, ifc, tifc);
    }

    done: {
        // unregister point-to-point proxy
        if (lifc.type & Rptpt != 0) {
            if (lifc.type & Rproxy != 0)
                ipifcregisterproxy(f, ifc, &lifc.remote, false);
            break :done;
        }

        // unregister local ip if proxy
        if (lifc.type & Rproxy != 0)
            ipifcregisterproxy(f, ifc, &lifc.local, false);

        // remove route for all nodes multicast
        if (lifc.type & Rv4 == 0) {
            if (ipcmp(&lifc.local, v6loopback) == 0) {
                delroute(f, &ipaux.v6allnodesN, &ipaux.v6allnodesNmask, &lifc.local, IPallbits, &ipaux.v6allnodesN, Rmulti, ifc, tifc);
            }
            delroute(f, &ipaux.v6allnodesL, &ipaux.v6allnodesLmask, &lifc.local, IPallbits, &ipaux.v6allnodesL, Rmulti, ifc, tifc);
        }
    }

    alloc.free(lifc);
}

/// remove an address from an interface.
pub fn ipifcdel(ifc: *Ipifc, argv: []const []const u8) Error!void {
    var ip: [IPaddrlen]u8 = undefined;
    var mask: [IPaddrlen]u8 = undefined;
    var rem: [IPaddrlen]u8 = undefined;
    const argc = argv.len;

    if (argc < 3)
        return error.Ebadarg;
    if (parseipandmask(&ip, &mask, argv[1], argv[2]) == -1)
        return error.Ebadip;
    if (argc < 4)
        maskip(&ip, &mask, &rem)
    else if (parseip(&rem, argv[3]) == -1)
        return error.Ebadip;

    // find address on this interface and remove from chain.
    // for pt to pt we actually specify the remote address as the
    // addresss to remove.
    wlock(&ifc.rwlock);
    defer wunlock(&ifc.rwlock);
    var l = &ifc.lifc;
    while (l.*) |lifc| {
        if (ipcmp(&ip, &lifc.local) == 0 and
            ipcmp(&mask, &lifc.mask) == 0 and
            ipcmp(&rem, &lifc.remote) == 0)
            break;
        l = &lifc.next;
    }
    return ipifcdellifc(ifc, l);
}

/// associate an address with the interface.  This wipes out any previous
/// addresses.  This is a macro that means, remove all the old interfaces
/// and add a new one.
fn ipifcconnect(c: *Conv, argv: []const []const u8) Error!void {
    const ifc = ifcof(c);

    wlock(&ifc.rwlock);
    while (ifc.lifc != null)
        ipifcdellifc(ifc, &ifc.lifc) catch {};
    wunlock(&ifc.rwlock);

    // when using dial(1), need to bind first
    if (ifc.m == null) {
        const a: []const []const u8 = &.{ "bind", "pkt" };
        // DIFF: see the head of the file.
        ipifcbind(c, a) catch {};
    }

    try ipifcadd(ifc, argv, false, null);

    devip.Fsconnected(c, null);
}

/// change ipv6 router parameters
/// ifc must be bound and wlock'd
fn ipifcra6(ifc: *Ipifc, argv: []const []const u8) Error!void {
    const argc = argv.len;

    var i: usize = 1;
    var argsleft = argc - 1;
    if ((argsleft % 2) != 0)
        return error.Ebadarg;

    var sendra = ifc.sendra6;
    var recvra = ifc.recvra6;
    var rp: Routerparams = ifc.rp;

    while (argsleft > 1) {
        if (streq(argv[i], "recvra"))
            recvra = atoi(argv[i + 1]) != 0
        else if (streq(argv[i], "sendra"))
            sendra = atoi(argv[i + 1]) != 0
        else if (streq(argv[i], "mflag"))
            rp.mflag = @intFromBool(atoi(argv[i + 1]) != 0)
        else if (streq(argv[i], "oflag"))
            rp.oflag = @intFromBool(atoi(argv[i + 1]) != 0)
        else if (streq(argv[i], "maxraint"))
            rp.maxraint = atoi(argv[i + 1])
        else if (streq(argv[i], "minraint"))
            rp.minraint = atoi(argv[i + 1])
        else if (streq(argv[i], "linkmtu"))
            rp.linkmtu = atoi(argv[i + 1])
        else if (streq(argv[i], "reachtime"))
            rp.reachtime = atoi(argv[i + 1])
        else if (streq(argv[i], "rxmitra"))
            rp.rxmitra = atoi(argv[i + 1])
        else if (streq(argv[i], "ttl"))
            rp.ttl = atoi(argv[i + 1])
        else if (streq(argv[i], "routerlt"))
            rp.routerlt = atoi(argv[i + 1])
        else
            return error.Ebadarg;
        argsleft -= 2;
        i += 2;
    }

    // consistency check
    if (rp.maxraint < rp.minraint)
        return error.Ebadarg;

    ifc.rp = rp;
    ifc.sendra6 = sendra;
    ifc.recvra6 = recvra;
}

/// non-standard control messages.
fn ipifcctl(c: *Conv, argv: []const []const u8) Error!void {
    const ifc = ifcof(c);
    const argc = argv.len;

    if (streq(argv[0], "iprouting"))
        ipmod.iprouting(c.p.?.f.?, if (argc > 1) atoi(argv[1]) != 0 else true)
    else if (streq(argv[0], "add"))
        try ipifcadd(ifc, argv, false, null)
    else if (streq(argv[0], "try"))
        try ipifcadd(ifc, argv, true, null)
    else if (streq(argv[0], "del") or streq(argv[0], "remove"))
        try ipifcdel(ifc, argv)
    else if (streq(argv[0], "unbind"))
        try ipifcunbind(ifc)
    else if (streq(argv[0], "add6"))
        try ipifcadd6(ifc, argv)
    else if (streq(argv[0], "del6") or streq(argv[0], "remove6"))
        try ipifcdel6(ifc, argv)
    else {
        wlock(&ifc.rwlock);
        defer wunlock(&ifc.rwlock);
        if (ifc.m == null or ifc.m == unboundmedium)
            return proc.errorf("%s", .{Eunbound});
        if (streq(argv[0], "mtu"))
            try ipifcsetmtu(ifc, if (argc > 1) @bitCast(strtoul(argv[1], 0).v) else 0)
        else if (streq(argv[0], "speed"))
            ipifcsetspeed(ifc, if (argc > 1) atoi(argv[1]) else 0)
        else if (streq(argv[0], "delay"))
            ipifcsetdelay(ifc, if (argc > 1) atoi(argv[1]) else 0)
        else if (streq(argv[0], "reflect"))
            ifc.reflect = if (argc > 1) atoi(argv[1]) != 0 else true
        else if (streq(argv[0], "reassemble"))
            ifc.reassemble = if (argc > 1) atoi(argv[1]) != 0 else true
        else if (streq(argv[0], "ra6"))
            try ipifcra6(ifc, argv)
        else
            return proc.errorf("unsupported ctl", .{});
    }
}

pub fn ipifcstats(ipifc: *Proto, buf: []u8) usize {
    return ipmod.ipstats(ipifc.f.?, buf);
}

pub fn ipifcinit(f: *Fs) void {
    const ipifc = alloc.snew(Proto);
    ipifc.* = .{};
    ipifc.name = "ipifc";
    ipifc.connect = ipifcconnect;
    ipifc.announce = null;
    ipifc.bind = ipifcbind;
    ipifc.state = ipifcstate;
    ipifc.create = ipifccreate;
    ipifc.close = ipifcclose;
    ipifc.rcv = null;
    ipifc.ctl = ipifcctl;
    ipifc.advise = null;
    ipifc.stats = ipifcstats;
    ipifc.inuse = ipifcinuse;
    ipifc.local = ipifclocal;
    ipifc.ipproto = -1;
    ipifc.nc = Maxmedia;
    ipifc.ptclsize = @sizeOf(Ipifc);

    f.ipifc = ipifc;
    const self = alloc.snew(Ipselftab); // hack for ipforme
    self.* = .{};
    f.self = self;

    _ = devip.Fsproto(f, ipifc);
}

/// add to self routing cache
fn addselfcache(f: *Fs, ifc: *Ipifc, lifc: *Iplifc, a: *const [IPaddrlen]u8, type_: u16) void {
    var typ = type_;
    const self = f.self.?;

    if (typ == Runi) typ |= (lifc.type & Rproxy);
    typ |= (lifc.type & Rv4);

    qlock(&self.qlock);
    defer qunlock(&self.qlock);

    // see if the address already exists
    const h = hashipa(a);
    var p_ = self.hash[h];
    while (p_) |x| : (p_ = x.next) {
        if (ipcmp(a, &x.a) == 0)
            break;
    }

    // allocate a local address and add to hash chain
    const p = p_ orelse blk: {
        const x = alloc.snew(Ipself);
        x.* = .{};
        ipmove(&x.a, a);
        x.type = typ;
        x.next = self.hash[h];
        self.hash[h] = x;

        // if the null address, accept all packets
        if (ipcmp(a, &ipaux.v4prefix) == 0 or ipcmp(a, IPnoaddr) == 0)
            self.acceptall = true;
        break :blk x;
    };

    // look for a link for this lifc
    var lp_ = p.link;
    while (lp_) |x| : (lp_ = x.selflink) {
        if (x.lifc == lifc)
            break;
    }

    // allocate a lifc-to-local link and link to both
    if (lp_) |lp| {
        lp.ref += 1;
    } else {
        const lp = alloc.snew(Iplink);
        lp.* = .{};
        lp.ref = 1;
        lp.lifc = lifc;
        lp.self = p;
        lp.selflink = p.link;
        p.link = lp;
        lp.lifclink = lifc.link;
        lifc.link = lp;

        // add to routing table
        addroute(
            f,
            a,
            IPallbits,
            &lifc.local,
            if ((typ & (Rbcast | Rmulti)) != 0 or v6addrtype(a) == linklocalv6)
                IPallbits
            else
                IPnoaddr,
            a,
            typ,
            ifc,
            tifc,
        );

        if (typ & Rmulti != 0) {
            if (ifc.m.?.addmulti) |addmulti|
                addmulti(ifc, a, &lifc.local) catch {};
            if (multicastreportfn) |report|
                report(f, ifc, a, &lifc.local, false) catch {};
        }
    }
}

// These structures are unlinked from their chains while
// other threads may be using them.  To avoid excessive locking,
// just put them aside for a while before freeing them.
// called with f->self locked
var freeiplink: ?*Iplink = null;
var freeipself: ?*Ipself = null;

fn iplinkfree(p: *Iplink) void {
    const now = NOW();

    var l = &freeiplink;
    while (l.*) |np| {
        if (@as(i32, @bitCast(now -% np.expire)) >= 0) {
            l.* = np.next;
            alloc.free(np);
            continue;
        }
        l = &np.next;
    }
    p.expire = now +% 5000; // give other threads 5 secs to get out
    p.next = null;
    l.* = p;
}

fn ipselffree(p: *Ipself) void {
    const now = NOW();

    var l = &freeipself;
    while (l.*) |np| {
        if (@as(i32, @bitCast(now -% np.expire)) >= 0) {
            l.* = np.next;
            alloc.free(np);
            continue;
        }
        l = &np.next;
    }
    p.expire = now +% 5000; // give other threads 5 secs to get out
    p.next = null;
    l.* = p;
}

/// Decrement reference for this address on this link.
/// Unlink from selftab if this is the last ref.
fn delselfcache(f: *Fs, ifc: *Ipifc, lifc: *Iplifc, a: *const [IPaddrlen]u8) void {
    const self = f.self.?;

    qlock(&self.qlock);
    defer qunlock(&self.qlock);

    // find the unique selftab entry
    var l = &self.hash[hashipa(a)];
    while (l.*) |x| {
        if (ipcmp(&x.a, a) == 0)
            break;
        l = &x.next;
    }

    const p = l.* orelse return;

    // walk down links from an ifc looking for one
    // that matches the selftab entry
    var l_lifc = &lifc.link;
    while (l_lifc.*) |x| {
        if (x.self == p)
            break;
        l_lifc = &x.lifclink;
    }

    if (l_lifc.* == null)
        return;

    // walk down the links from the selftab looking for
    // the one we just found
    var l_self = &p.link;
    while (l_self.*) |x| {
        if (x == l_lifc.*)
            break;
        l_self = &x.selflink;
    }

    const link = l_self.* orelse p9.panic("delselfcache", .{});

    link.ref -= 1;
    if (link.ref != 0)
        return;

    // ref == 0, remove from both chains and free the link
    l_lifc.* = link.lifclink;
    l_self.* = link.selflink;
    iplinkfree(link);

    if ((p.type & Rmulti) != 0) {
        if (multicastreportfn) |report|
            report(f, ifc, a, &lifc.local, true) catch {};
        if (ifc.m.?.delmulti) |delmulti|
            delmulti(ifc, a, &lifc.local) catch {};
    }

    // remove from routing table
    delroute(
        f,
        a,
        IPallbits,
        &lifc.local,
        if ((p.type & (Rbcast | Rmulti)) != 0 or v6addrtype(a) == linklocalv6)
            IPallbits
        else
            IPnoaddr,
        a,
        p.type,
        ifc,
        tifc,
    );

    if (p.link != null)
        return;

    // if null address, forget
    if (ipcmp(a, &ipaux.v4prefix) == 0 or ipcmp(a, IPnoaddr) == 0)
        self.acceptall = false;

    // no more links, remove from hash and free
    l.* = p.next;
    ipselffree(p);
}

pub fn ipselftabread(f: *Fs, cp: []u8, offset: usize) usize {
    var state: [8]u8 = undefined;
    const self = f.self.?;
    const n = cp.len;

    var m: usize = 0;
    var off: i64 = @as(i32, @bitCast(@as(u32, @truncate(offset))));
    var i: usize = 0;
    while (i < NHASH and m < n) : (i += 1) {
        var p = self.hash[i];
        while (p != null and m < n) : (p = p.?.next) {
            const s = p.?;
            var nifc: usize = 0;
            var link = s.link;
            while (link) |lk| : (link = lk.selflink)
                nifc += 1;
            const t = iproute.routetype(s.type, &state);
            m += fmt.snprint(cp[m..], "%-44.44I %2.2d %4.4s\n", .{ ipaux.ip(&s.a), nifc, t }).len;
            if (off > 0) {
                off -= @intCast(m);
                m = 0;
            }
        }
    }
    return m;
}

/// returns
///     0       - no match
///     Runi
///     Rbcast
///     Rmulti
pub fn ipforme(f: *Fs, addr: *const [IPaddrlen]u8) u16 {
    const self = f.self.?;

    var p = self.hash[hashipa(addr)];
    while (p) |x| : (p = x.next) {
        if (ipcmp(addr, &x.a) == 0)
            return x.type & (Runi | Rbcast | Rmulti);
    }

    // hack to say accept anything
    if (self.acceptall)
        return Runi;

    return 0;
}

/// find the ifc on same net as the remote system.
/// returns the rlock'd ifc, otherwise nil.
pub fn findipifc(f: *Fs, local: *const [IPaddrlen]u8, remote: *const [IPaddrlen]u8, typ: u16) ?*Ipifc {
    var gnet: [IPaddrlen]u8 = undefined;

    var x: ?*Ipifc = null;
    var xifcid: u8 = 0;
    var xspec: usize = 0;
    for (f.ipifc.?.conv) |cp| {
        const c = cp orelse break;
        const ifc = ifcof(c);
        rlock(&ifc.rwlock);
        var lifc_ = ifc.lifc;
        while (lifc_) |lifc| : (lifc_ = lifc.next) {
            if (typ & Runi != 0) {
                if (ipcmp(remote, &lifc.local) == 0)
                    return ifc;
            } else if (typ & (Rbcast | Rmulti) != 0) {
                if (ipcmp(local, &lifc.local) == 0)
                    return ifc;
            }
            maskip(remote, &lifc.mask, &gnet);
            if (ipcmp(&gnet, &lifc.net) == 0) {
                var spec = comprefixlen(remote, &lifc.local, IPaddrlen) << 8;
                spec += comprefixlen(local, &lifc.local, IPaddrlen);
                if (spec > xspec) {
                    x = ifc;
                    xifcid = ifc.ifcid;
                    xspec = spec;
                }
            }
        }
        runlock(&ifc.rwlock);
    }
    if (x) |ifc| {
        rlock(&ifc.rwlock);
        if (ifc.ifcid == xifcid)
            return ifc;
        runlock(&ifc.rwlock);
    }
    return null;
}

/// find the ifc bound to device name dev.
/// returns the rlock'd ifc, otherwise nil.
pub fn findipifcdev(f: *Fs, dev: []const u8) ?*Ipifc {
    for (f.ipifc.?.conv) |cp| {
        const c = cp orelse break;
        const ifc = ifcof(c);
        rlock(&ifc.rwlock);
        if (ifc.m != null and
            ifc.m != unboundmedium and
            streq(ifc.devname(), dev))
            return ifc;
        runlock(&ifc.rwlock);
    }
    return null;
}

/// find a ifc based on:
/// - its /net/ipifc/X directory number
/// - a local ip address on that interface
/// - bound device name
/// returns the rlock'd ifc, otherwise nil.
pub fn findipifcstr(f: *Fs, s: []const u8) ?*Ipifc {
    var ip: [IPaddrlen]u8 = undefined;

    var ifc: ?*Ipifc = null;
    const r = netif.strtou(u32, s, 10);
    if (r.n > 0 and r.n == s.len) {
        // x < 0
        if (r.v != 0 and std.mem.findScalar(u8, s[0..r.n], '-') != null)
            return null;
        const x: usize = r.v;
        const ipifc = f.ipifc.?;
        if (x < ipifc.nc and x < ipifc.conv.len) {
            if (ipifc.conv[x]) |c| {
                ifc = ifcof(c);
                rlock(&ifc.?.rwlock);
                if (ifc.?.m == null or ifc.?.m == unboundmedium) {
                    runlock(&ifc.?.rwlock);
                    ifc = null;
                }
            }
        }
    } else if (parseip(&ip, s) != -1)
        ifc = findipifc(f, &ip, &ip, Runi)
    else
        ifc = findipifcdev(f, s);
    return ifc;
}

/// find "best" (global > ula > link local > unspecified)
/// local address; address must be current.
fn findprimaryipv6(f: *Fs, local: *[IPaddrlen]u8) void {
    const now = NOW() / 1000;

    ipmove(local, &ipaux.v6Unspecified);
    var atype: i32 = unspecifiedv6;

    for (f.ipifc.?.conv) |cp| {
        const c = cp orelse break;
        const ifc = ifcof(c);
        rlock(&ifc.rwlock);
        var lifc_ = ifc.lifc;
        while (lifc_) |lifc| : (lifc_ = lifc.next) {
            const atypel = v6addrtype(&lifc.local);
            if (atypel > atype and
                (lifc.preflt == ~@as(u32, 0) or lifc.preflt >= now -% lifc.origint))
            {
                ipmove(local, &lifc.local);
                atype = atypel;
                if (atype == globalv6) {
                    runlock(&ifc.rwlock);
                    return;
                }
            }
        }
        runlock(&ifc.rwlock);
    }
}

/// returns first v4 address configured
fn findprimaryipv4(f: *Fs, local: *[IPaddrlen]u8) void {
    // find first ifc local address
    for (f.ipifc.?.conv) |cp| {
        const c = cp orelse break;
        const ifc = ifcof(c);
        rlock(&ifc.rwlock);
        var lifc_ = ifc.lifc;
        while (lifc_) |lifc| : (lifc_ = lifc.next) {
            if ((lifc.type & Rv4) != 0) {
                ipmove(local, &lifc.local);
                runlock(&ifc.rwlock);
                return;
            }
        }
        runlock(&ifc.rwlock);
    }
    ipmove(local, IPnoaddr);
}

// ipv4local, ipv6local:
//  return a local address associated with an interface close to remote.
//  prefixlen is the number of leading bits in the local address that
//  have to match an interface address to be considered. this is used
//  by source specific routes to filter on the source address.
//  return non-zero on success or zero when no address was found.
//
//  for ipv4local, all addresses are 4 byte format.
pub fn ipv4local(ifc: *Ipifc, local: *[IPv4addrlen]u8, prefixlen: usize, remote: *const [IPv4addrlen]u8) bool {
    var b: i32 = -1;
    var lifc_ = ifc.lifc;
    while (lifc_) |lifc| : (lifc_ = lifc.next) {
        if ((lifc.type & Rv4) == 0 or ipcmp(&lifc.local, IPnoaddr) == 0)
            continue;

        if (prefixlen != 0 and comprefixlen(lifc.local[IPv4off..], local, IPv4addrlen) < prefixlen)
            continue;

        const a: i32 = @intCast(comprefixlen(lifc.local[IPv4off..], remote, IPv4addrlen));
        if (a > b) {
            b = a;
            local.* = lifc.local[IPv4off..].*;
        }
    }
    return b >= 0;
}

pub fn ipv6local(ifc: *Ipifc, local: *[IPaddrlen]u8, prefixlen: usize, remote: *const [IPaddrlen]u8) bool {
    const Pref = struct {
        atype: i32,
        deprecated: bool,
        comprefixlen: usize,
    };

    if (isv4(remote)) {
        @memcpy(local[0..IPv4off], ipaux.v4prefix[0..IPv4off]);
        return ipv4local(ifc, local[IPv4off..], prefixlen -| IPv4off * 8, remote[IPv4off..]);
    }

    const atype = v6addrtype(remote);
    var b: Pref = .{ .atype = unknownv6, .deprecated = true, .comprefixlen = 0 };

    const now = NOW() / 1000;
    var lifc_ = ifc.lifc;
    while (lifc_) |lifc| : (lifc_ = lifc.next) {
        if (lifc.tentative)
            continue;

        if (prefixlen != 0 and comprefixlen(&lifc.local, local, IPaddrlen) < prefixlen)
            continue;

        const a: Pref = .{
            .atype = v6addrtype(&lifc.local),
            .deprecated = lifc.preflt != ~@as(u32, 0) and lifc.preflt < now -% lifc.origint,
            .comprefixlen = comprefixlen(&lifc.local, remote, IPaddrlen),
        };

        const good = blk: {
            // prefer appropriate scope
            if (a.atype != b.atype)
                break :blk (a.atype > b.atype and b.atype < atype or
                    a.atype < b.atype and b.atype > atype);
            // prefer non-deprecated addresses
            if (a.deprecated != b.deprecated)
                break :blk b.deprecated;
            // prefer longer common prefix
            if (a.comprefixlen != b.comprefixlen)
                break :blk a.comprefixlen > b.comprefixlen;
            break :blk false;
        };
        if (!good)
            continue;
        b = a;
        ipmove(local, &lifc.local);
    }

    return b.atype >= atype;
}

/// find the local address for a remote destination
pub fn findlocalip(f: *Fs, local: *[IPaddrlen]u8, remote: *const [IPaddrlen]u8) void {
    if (isv4(remote)) {
        @memcpy(local[0..IPv4off], ipaux.v4prefix[0..IPv4off]);
        if (iproute.v4source(f, remote[IPv4off..], local[IPv4off..]) == null)
            findprimaryipv4(f, local);
    } else {
        if (iproute.v6source(f, remote, local) == null)
            findprimaryipv6(f, local);
    }
}

/// see if this address is bound to the interface
pub fn iplocalonifc(ifc: *Ipifc, ip: *const [IPaddrlen]u8) ?*Iplifc {
    var lifc_ = ifc.lifc;
    while (lifc_) |lifc| : (lifc_ = lifc.next) {
        if (ipcmp(ip, &lifc.local) == 0)
            return lifc;
    }
    return null;
}

pub fn ipremoteonifc(ifc: *Ipifc, ip: *const [IPaddrlen]u8) ?*Iplifc {
    var net: [IPaddrlen]u8 = undefined;

    var lifc_ = ifc.lifc;
    while (lifc_) |lifc| : (lifc_ = lifc.next) {
        maskip(ip, &lifc.mask, &net);
        if (ipcmp(&net, &lifc.remote) == 0)
            return lifc;
    }
    return null;
}

/// return link-local interface
pub fn iplinklocalifc(ifc: *Ipifc) ?*Iplifc {
    var lifc_ = ifc.lifc;
    while (lifc_) |lifc| : (lifc_ = lifc.next) {
        if (islinklocal(&lifc.local))
            return lifc;
    }
    return null;
}

/// Return a copy of the multicast addresses on the
/// specified interface and multicast address.
pub fn ipifcgetmulti(f: *Fs, ifc: *Ipifc, ma_: *const [IPaddrlen]u8) ?*Ipmulti {
    var ma: ?*const [IPaddrlen]u8 = ma_;

    var typ: u16 = Rmulti;
    if (isv4(ma_))
        typ |= Rv4;
    if (ipaux.ipismulticast(ma_) == @as(u8, if (typ & Rv4 != 0) V4 else V6)) {
        if (ipforme(f, ma_) != Rmulti)
            return null;
    } else {
        ma = null;
    }

    var head: ?*Ipmulti = null;
    var tail: ?*Ipmulti = null;
    var lifc_ = ifc.lifc;
    while (lifc_) |lifc| : (lifc_ = lifc.next) {
        if ((typ & Rv4) == 0 and !islinklocal(&lifc.local))
            continue;

        var link_ = lifc.link;
        while (link_) |link| : (link_ = link.lifclink) {
            const self = link.self.?;
            if ((self.type & (Rv4 | Rmulti)) != typ)
                continue;

            if (ma) |x| {
                if (ipcmp(&self.a, x) != 0)
                    continue;
            } else {
                if (ipcmp(&self.a, if (typ & Rv4 != 0) &ipaux.IPv4allsys else &ipaux.v6allnodesL) == 0)
                    continue;
            }

            const mcast = alloc.snew(Ipmulti);
            mcast.* = .{};
            mcast.next = null;
            ipmove(&mcast.ma, &self.a);
            ipmove(&mcast.ia, &lifc.local);

            if (ma != null)
                return mcast;

            if (head == null)
                head = mcast
            else
                tail.?.next = mcast;
            tail = mcast;
        }
    }
    return head;
}

/// add a multicast address to an interface.
pub fn ipifcaddmulti(c: *Conv, ma: *const [IPaddrlen]u8, ia: *const [IPaddrlen]u8) Error!void {
    if (ipaux.ipismulticast(ma) == 0)
        return proc.errorf("addmulti for a non multicast address", .{});
    if (isv4(ma) != isv4(ia))
        return proc.errorf("incompatible multicast/interface ip address", .{});

    var l = &c.multi;
    while (l.*) |x| : (l = &x.next) {
        if (ipcmp(ma, &x.ma) == 0 and ipcmp(ia, &x.ia) == 0)
            return; // it's already there
    }

    const f = c.p.?.f.?;
    if (findipifc(f, ia, ma, Rmulti)) |ifc| {
        if (iplocalonifc(ifc, ia)) |lifc|
            addselfcache(f, ifc, lifc, ma, Rmulti);

        // for IPv6, must add also add to the link-local address
        if (!isv4(ia) and !islinklocal(ia)) {
            if (iplinklocalifc(ifc)) |lifc|
                addselfcache(f, ifc, lifc, ma, Rmulti);
        }

        runlock(&ifc.rwlock);
    }

    const multi = alloc.snew(Ipmulti);
    multi.* = .{};
    ipmove(&multi.ma, ma);
    ipmove(&multi.ia, ia);
    multi.next = null;
    l.* = multi;
}

/// remove a multicast address from an interface.
pub fn ipifcdelmulti(c: *Conv, ma: *const [IPaddrlen]u8, ia: *const [IPaddrlen]u8) void {
    var l = &c.multi;
    while (l.*) |x| : (l = &x.next) {
        if (ipcmp(ma, &x.ma) == 0 and ipcmp(ia, &x.ia) == 0)
            break;
    }

    const multi = l.* orelse return; // we don't have it open

    l.* = multi.next;
    multi.next = null;

    const f = c.p.?.f.?;
    if (findipifc(f, ia, ma, Rmulti)) |ifc| {
        if (iplocalonifc(ifc, ia)) |lifc|
            delselfcache(f, ifc, lifc, ma);
        if (!isv4(ia) and !islinklocal(ia)) {
            if (iplinklocalifc(ifc)) |lifc|
                delselfcache(f, ifc, lifc, ma);
        }
        runlock(&ifc.rwlock);
    }
    alloc.free(multi);
}

/// register the address on this network for address resolution
fn ipifcregisteraddr(f: *Fs, ifc: *Ipifc, lifc: *Iplifc, ip: *const [IPaddrlen]u8) void {
    const m = ifc.m orelse return;
    const areg = m.areg orelse return;
    areg(f, ifc, lifc, ip) catch |e| {
        p9.print("ipifcregisteraddr %s %I %I: %s\n", .{ ifc.devname(), ipaux.ip(&lifc.local), ipaux.ip(ip), proc.errtext(e) });
    };
}

fn ipifcregisterproxy(f: *Fs, ifc: *Ipifc, ip: *const [IPaddrlen]u8, add: bool) void {
    var a: [IPaddrlen]u8 = undefined;

    // register the address on any interface that will proxy for the ip
    for (f.ipifc.?.conv) |cp| {
        const c = cp orelse break;
        const nifc = ifcof(c);
        if (nifc == ifc or !canrlock(&nifc.rwlock))
            continue;
        defer runlock(&nifc.rwlock);

        if (nifc.m == null or nifc.m == unboundmedium)
            continue;
        const lifc = ipremoteonifc(nifc, ip) orelse continue;
        if ((lifc.type & Rptpt) != 0)
            continue;

        if ((lifc.type & Rv4) == 0) {
            // add solicited-node multicast addr
            ipaux.ipv62smcast(&a, ip);
            if (add)
                addselfcache(f, nifc, lifc, &a, Rmulti)
            else
                delselfcache(f, nifc, lifc, &a);
        }
        if (add)
            ipifcregisteraddr(f, nifc, lifc, ip);
    }
}

pub fn ipifcadd6(ifc: *Ipifc, argv: []const []const u8) Error!void {
    var plen: i32 = 64;
    var addr: [40]u8 = undefined;
    var preflen: [6]u8 = undefined;
    var prefix: [IPaddrlen]u8 = undefined;
    var lifc: Iplifc = .{};
    const argc = argv.len;

    lifc.onlink = true;
    lifc.autoflag = true;
    lifc.validlt = ~@as(u32, 0);
    lifc.preflt = ~@as(u32, 0);
    lifc.origint = NOW() / 1000;

    if (argc < 2 or argc > 7)
        return error.Ebadarg;
    if (argc >= 7)
        lifc.preflt = strtoul(argv[6], 10).v;
    if (argc >= 6)
        lifc.validlt = strtoul(argv[5], 10).v;
    if (argc >= 5)
        lifc.autoflag = atoi(argv[4]) != 0;
    if (argc >= 4)
        lifc.onlink = atoi(argv[3]) != 0;
    if (argc >= 3)
        plen = atoi(argv[2]);

    if (parseip(&prefix, argv[1]) != 6 or lifc.validlt < lifc.preflt or plen < 0 or
        plen > 64 or islinklocal(&prefix))
        return error.Ebadarg;

    rlock(&ifc.rwlock);
    if (ifc.m == null or ifc.m == unboundmedium) {
        runlock(&ifc.rwlock);
        return proc.errorf("%s", .{Eunbound});
    }
    const m = ifc.m.?;
    if (m.pref2addr != null and m.maclen > 0) {
        // mac → v6 link-local addr
        m.pref2addr.?(&prefix, ifc.mac[0..@min(m.maclen, ifc.mac.len)]);
    } else {
        // copy from existing v6 link-local address
        const llifc = iplinklocalifc(ifc) orelse {
            runlock(&ifc.rwlock);
            return proc.errorf("%s", .{Eunbound});
        };
        @memcpy(prefix[8..], llifc.local[8..]);
    }
    runlock(&ifc.rwlock);

    // issue "add" ctl msg for v6 link-local addr and prefix len
    const params: [3][]const u8 = .{
        "add",
        fmt.snprint(addr[0 .. addr.len - 1], "%I", .{ipaux.ip(&prefix)}),
        fmt.snprint(preflen[0 .. preflen.len - 1], "/%d", .{plen}),
    };

    return ipifcadd(ifc, &params, false, &lifc);
}

pub fn ipifcdel6(ifc: *Ipifc, argv: []const []const u8) Error!void {
    if (argv.len != 1)
        return error.Ebadarg;

    wlock(&ifc.rwlock);
    const now = NOW() / 1000;
    var l = &ifc.lifc;
    while (l.*) |lifc| {
        if ((lifc.type & Rv4) == 0 and
            lifc.validlt != ~@as(u32, 0) and lifc.validlt < now -% lifc.origint)
        {
            if (ipifcdellifc(ifc, l)) |_| continue else |_| {}
        }
        l = &lifc.next;
    }
    wunlock(&ifc.rwlock);
}
