//! Helpers of the IP stack: well known addresses, checksums, the hash
//! table of conversations, network address translation entries, and
//! the parts of libip the kernel links in: address parsing, masks and
//! the %I %M %V %E format verbs.
//! from 9/ip/ipaux.c; libip/ipaux.c, classmask.c, parseip.c,
//! equivip.c, ptclbsum.c and eipfmt.c.
//!
//! Printing addresses.  There is no fmtinstall: an argument formats
//! itself (see lib/fmt.zig), so the address is wrapped where it is
//! printed:
//!     print("%I %M %V %E\n", .{ ip(a), mask(m), v4(a4), ea(mac) });
//! ip, mask, v4 and ea take an array, a pointer to one, or a slice.
//!
//! DIFF:
//!   - Signatures follow the rules at the head of ipdat.zig: addresses
//!     are pointers to arrays, strings are slices and end at their
//!     length or at a NUL, whichever comes first.
//!   - v4parseip returns how many bytes of the string it used, the C
//!     the pointer to the rest.  parsemac takes the length of `to`
//!     from the slice.
//!   - parseip, parseipmask and parseipandmask keep their C results
//!     (-1 for an error, 6 for a v6 address, otherwise the v4 address
//!     as a number) as an i64.
//!   - transfsize returns null where the C returns -1.  transwrite
//!     with an empty slice and offset 0 flushes, as the C does with
//!     n == 0.  transforward and addtrans take ports as u16.
//!   - iphash computes in 32 bit unsigned arithmetic.  Read with ANSI
//!     promotion rules the C expression is a signed int that can be
//!     negative before the modulus.
//!   - hnputs_csum takes pointers to the two bytes it changes and to
//!     the two bytes of the checksum; only their distance matters.
//!   - eipfmt is the fmt9 method of IPaddr and V4addr.  %i (a v6
//!     address as four longs) is not there: nothing kept uses it.
//!     %E is devether's Eaddr.
//!   - hnputs, hnputl, hnputv, nhgets, nhgetl, nhgetv and parseether
//!     are re-exported from port/netif.zig and port/devether.zig.

const std = @import("std");
const builtin = @import("builtin");
const fmt = @import("fmt");
const portdat = @import("../port/portdat.zig");
const proc = @import("../port/proc.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const ql = @import("../port/qlock.zig");
const taslock = @import("../port/taslock.zig");
const parse = @import("../port/parse.zig");
const netif = @import("../port/netif.zig");
const devether = @import("../port/devether.zig");
const p9 = @import("../port/print.zig");
const ipdat = @import("ipdat.zig");
const netlog_ = @import("netlog.zig");

const ipifc = @import("ipifc.zig");
const iproute = @import("iproute.zig");
const devip = @import("devip.zig");

const Error = proc.Error;
const Block = ab.Block;
const BLEN = ab.BLEN;
const Conv = ipdat.Conv;
const Fs = ipdat.Fs;
const Ipifc = ipdat.Ipifc;
const Iphash = ipdat.Iphash;
const Ipht = ipdat.Ipht;
const Proto = ipdat.Proto;
const Route = ipdat.Route;
const Routehint = ipdat.Routehint;
const Translation = ipdat.Translation;
const IPaddrlen = ipdat.IPaddrlen;
const IPv4addrlen = ipdat.IPv4addrlen;
const IPv4off = ipdat.IPv4off;
const V4 = ipdat.V4;
const V6 = ipdat.V6;
const Nipht = ipdat.Nipht;
const NOW = ipdat.NOW;
const ipcmp = ipdat.ipcmp;
const ipmove = ipdat.ipmove;
const netlog = netlog_.netlog;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const lock = taslock.lock;
const unlock = taslock.unlock;
const strtoul = netif.strtoul;

pub const hnputv = netif.hnputv;
pub const hnputl = netif.hnputl;
pub const hnputs = netif.hnputs;
pub const nhgetv = netif.nhgetv;
pub const nhgetl = netif.nhgetl;
pub const nhgets = netif.nhgets;
pub const parseether = devether.parseether;

/// Names of the v6 header types; null where the C has nil.
pub const v6hdrtypes: [ipdat.Maxhdrtype]?[]const u8 = blk: {
    var t: [ipdat.Maxhdrtype]?[]const u8 = @splat(null);
    t[ipdat.HBH] = "HopbyHop";
    t[ipdat.ICMP] = "ICMP";
    t[ipdat.IGMP] = "IGMP";
    t[ipdat.GGP] = "GGP";
    t[ipdat.IPINIP] = "IP";
    t[ipdat.ST] = "ST";
    t[ipdat.TCP] = "TCP";
    t[ipdat.UDP] = "UDP";
    t[ipdat.ISO_TP4] = "ISO_TP4";
    t[ipdat.RH] = "Routinghdr";
    t[ipdat.FH] = "Fraghdr";
    t[ipdat.IDRP] = "IDRP";
    t[ipdat.RSVP] = "RSVP";
    t[ipdat.AH] = "Authhdr";
    t[ipdat.ESP] = "ESP";
    t[ipdat.ICMPv6] = "ICMPv6";
    t[ipdat.NNH] = "Nonexthdr";
    t[ipdat.ISO_IP] = "ISO_IP";
    t[ipdat.IGRP] = "IGRP";
    t[ipdat.OSPF] = "OSPF";
    break :blk t;
};

//
//  well known IPv6 addresses
//
pub const v6Unspecified: [IPaddrlen]u8 = .{
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
};
pub const v6loopback: [IPaddrlen]u8 = .{
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0x01,
};

pub const v6linklocal: [IPaddrlen]u8 = .{
    0xfe, 0x80, 0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
};
pub const v6linklocalmask: [IPaddrlen]u8 = .{
    0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff,
    0,    0,    0,    0,
    0,    0,    0,    0,
};
pub const v6llpreflen = 8; // link-local prefix length in bytes

pub const v6multicast: [IPaddrlen]u8 = .{
    0xff, 0, 0, 0,
    0,    0, 0, 0,
    0,    0, 0, 0,
    0,    0, 0, 0,
};
pub const v6multicastmask: [IPaddrlen]u8 = .{
    0xff, 0, 0, 0,
    0,    0, 0, 0,
    0,    0, 0, 0,
    0,    0, 0, 0,
};
pub const v6mcpreflen = 1; // multicast prefix length

pub const v6allnodesN: [IPaddrlen]u8 = .{
    0xff, 0x01, 0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0x01,
};
pub const v6allroutersN: [IPaddrlen]u8 = .{
    0xff, 0x01, 0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0x02,
};
pub const v6allnodesNmask: [IPaddrlen]u8 = .{
    0xff, 0xff, 0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
};
pub const v6aNpreflen = 2; // all nodes (N) prefix

pub const v6allnodesL: [IPaddrlen]u8 = .{
    0xff, 0x02, 0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0x01,
};
pub const v6allroutersL: [IPaddrlen]u8 = .{
    0xff, 0x02, 0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0x02,
};
pub const v6allnodesLmask: [IPaddrlen]u8 = .{
    0xff, 0xff, 0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0,
};
pub const v6aLpreflen = 2; // all nodes (L) prefix

pub const v6solicitednode: [IPaddrlen]u8 = .{
    0xff, 0x02, 0, 0,
    0,    0,    0, 0,
    0,    0,    0, 0x01,
    0xff, 0,    0, 0,
};
pub const v6solicitednodemask: [IPaddrlen]u8 = .{
    0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff,
    0xff, 0x0,  0x0,  0x0,
};
pub const v6snpreflen = 13;

pub fn ptclcsum(bp_: ?*Block, offset_: usize, len_: usize) u16 {
    var bp = bp_;
    var offset = offset_;
    var len = len_;

    // Correct to front of data area
    while (bp != null and offset != 0 and offset >= BLEN(bp.?)) {
        offset -= BLEN(bp.?);
        bp = bp.?.next;
    }
    var b = bp orelse return 0;

    var addr = b.rp + offset;
    var blocklen = BLEN(b) - offset;

    if (b.next == null) {
        if (blocklen < len)
            len = blocklen;
        return ptclbsum(addr[0..len]) ^ 0xffff;
    }

    var losum: u32 = 0;
    var hisum: u32 = 0;

    var odd: usize = 0;
    while (len != 0) {
        var x = blocklen;
        if (len < x)
            x = len;

        const csum = ptclbsum(addr[0..x]);
        if (odd != 0)
            hisum +%= csum
        else
            losum +%= csum;
        odd = (odd + x) & 1;
        len -= x;

        b = b.next orelse break;
        blocklen = BLEN(b);
        addr = b.rp;
    }

    losum +%= hisum >> 8;
    losum +%= (hisum & 0xff) << 8;
    while (losum >> 16 != 0)
        losum = (losum >> 16) + (losum & 0xffff);

    return @as(u16, @truncate(losum)) ^ 0xffff;
}

const Isprefix = 16;

fn CLASS(p: *const [IPv4addrlen]u8) u8 {
    return p[0] >> 6;
}

pub fn ipv62smcast(smcast: *[IPaddrlen]u8, a: *const [IPaddrlen]u8) void {
    const a13 = a[13];
    const a14 = a[14];
    const a15 = a[15];
    ipmove(smcast, &v6solicitednode);
    smcast[13] = a13;
    smcast[14] = a14;
    smcast[15] = a15;
}

/// The byte of a C string at i: 0 from its end on.
fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

/// The C string from i on.
fn rest(s: []const u8, i: usize) []const u8 {
    return if (i < s.len) s[i..] else s[s.len..];
}

/// parse a hex mac address
pub fn parsemac(to: []u8, from: []const u8) usize {
    var p: usize = 0;
    @memset(to, 0);
    var i: usize = 0;
    while (i < to.len) : (i += 1) {
        if (at(from, p) == 0 or at(from, p + 1) == 0)
            break;

        const nip = from[p .. p + 2];
        p += 2;

        to[i] = @truncate(strtoul(nip, 16).v);
        if (at(from, p) == ':')
            p += 1;
    }
    return i;
}

/// return multicast version if any
pub fn ipismulticast(ip_: *const [IPaddrlen]u8) u8 {
    if (isv4(ip_)) {
        if (ipdat.isv4mcast(ip_[IPv4off..]))
            return V4;
    } else if (ipdat.isv6mcast(ip_))
        return V6;
    return 0;
}

/// return ip version of a connection
pub fn convipvers(c: *Conv) u8 {
    if (isv4(&c.iphash.raddr) and isv4(&c.iphash.laddr) or ipcmp(&c.iphash.raddr, &IPnoaddr) == 0)
        return V4
    else
        return V6;
}

/// hashing tcp, udp, ... connections
fn iphash(sa: *const [IPaddrlen]u8, sp: u16, da: *const [IPaddrlen]u8, dp: u16) usize {
    // DIFF: see the head of the file.
    return ((@as(u32, sa[IPaddrlen - 1]) << 24) ^ (@as(u32, sp) << 16) ^ (@as(u32, da[IPaddrlen - 1]) << 8) ^ dp) % Nipht;
}

pub fn iphtadd(ht: *Ipht, h: *Iphash) void {
    if (ipcmp(&h.raddr, &IPnoaddr) != 0)
        h.match = ipdat.IPmatchexact
    else {
        if (ipcmp(&h.laddr, &IPnoaddr) != 0) {
            if (h.lport == 0)
                h.match = ipdat.IPmatchaddr
            else
                h.match = ipdat.IPmatchpa;
        } else {
            if (h.lport == 0)
                h.match = ipdat.IPmatchany
            else
                h.match = ipdat.IPmatchport;
        }
    }
    lock(&ht.lock);
    const hv = iphash(&h.raddr, h.rport, &h.laddr, h.lport);
    h.nextiphash = ht.tab[hv];
    ht.tab[hv] = h;
    unlock(&ht.lock);
}

pub fn iphtrem(ht: *Ipht, h: *Iphash) void {
    lock(&ht.lock);
    const hv = iphash(&h.raddr, h.rport, &h.laddr, h.lport);
    var l = &ht.tab[hv];
    while (l.*) |x| : (l = &x.nextiphash) {
        if (x == h) {
            l.* = h.nextiphash;
            h.nextiphash = null;
            break;
        }
    }
    unlock(&ht.lock);
}

/// look for a matching iphash with the following precedence
///     raddr,rport,laddr,lport
///     laddr,lport
///     *,lport
///     laddr,*
///     *,*
pub fn iphtlook(ht: *Ipht, sa: *const [IPaddrlen]u8, sp: u16, da: *const [IPaddrlen]u8, dp: u16) ?*Iphash {
    lock(&ht.lock);
    defer unlock(&ht.lock);

    // exact 4 pair match (connection)
    var hv = iphash(sa, sp, da, dp);
    var h = ht.tab[hv];
    while (h) |x| : (h = x.nextiphash) {
        if (x.match != ipdat.IPmatchexact)
            continue;
        if (sp == x.rport and dp == x.lport and ipcmp(sa, &x.raddr) == 0 and ipcmp(da, &x.laddr) == 0)
            return x;
    }

    // match local address and port
    hv = iphash(&IPnoaddr, 0, da, dp);
    h = ht.tab[hv];
    while (h) |x| : (h = x.nextiphash) {
        if (x.match != ipdat.IPmatchpa)
            continue;
        if (dp == x.lport and ipcmp(da, &x.laddr) == 0)
            return x;
    }

    // match just port
    hv = iphash(&IPnoaddr, 0, &IPnoaddr, dp);
    h = ht.tab[hv];
    while (h) |x| : (h = x.nextiphash) {
        if (x.match != ipdat.IPmatchport)
            continue;
        if (dp == x.lport)
            return x;
    }

    // match local address
    hv = iphash(&IPnoaddr, 0, da, 0);
    h = ht.tab[hv];
    while (h) |x| : (h = x.nextiphash) {
        if (x.match != ipdat.IPmatchaddr)
            continue;
        if (ipcmp(da, &x.laddr) == 0)
            return x;
    }

    // look for something that matches anything
    hv = iphash(&IPnoaddr, 0, &IPnoaddr, 0);
    h = ht.tab[hv];
    while (h) |x| : (h = x.nextiphash) {
        if (x.match != ipdat.IPmatchany)
            continue;
        return x;
    }
    return null;
}

fn deltrans(p: *Proto, q: *Translation) *Translation {
    netlog(p.f.?, ipdat.Logtrans, "trans: removing %s!%I!%d -> %I!%d -> %I!%d\n", .{
        p.name,
        ip(&q.forward.raddr),
        q.forward.rport,
        ip(&q.backward.laddr),
        q.backward.lport,
        ip(&q.forward.laddr),
        q.forward.lport,
    });

    iphtrem(p.ht.?, &q.forward);
    iphtrem(p.ht.?, &q.backward);

    return q;
}

fn newtrans(p: *Proto) ?*Translation {
    // Use freelist
    if (p.freetranslations) |q|
        return q;

    // Reuse expired entries
    var num: usize = 0;
    const now = NOW();
    var l = p.translations;
    while (l) |q| : (l = q.next) {
        num += 1;
        if (num >= 1000 or (now -% q.time) >= 5 * 60 * 1000)
            return deltrans(p, q);
    }

    // Allocate, never freed
    const q = alloc.new(Translation) orelse return null;
    q.* = .{};
    return q;
}

/// Move entry to front of Proto.translations
/// and update the timestamp.
///
/// Proto is locked.
fn transupdate(p: *Proto, q: *Translation) *Translation {
    q.time = NOW();

    // already head of translations list?
    if (q.link == &p.translations)
        return q;

    // unlink (from translations or freelist)
    if (q.link) |link| {
        link.* = q.next;
        if (q.next) |n|
            n.link = q.link;
    }

    // link to front of translations list
    q.next = p.translations;
    if (q.next) |n|
        n.link = &q.next;
    p.translations = q;
    q.link = &p.translations;

    return q;
}

fn addtrans(
    p: *Proto,
    da: *const [IPaddrlen]u8,
    dp: u16,
    sa: *const [IPaddrlen]u8,
    sp: u16,
    la: *const [IPaddrlen]u8,
    lp: u16,
    rh: Routehint,
) ?*Translation {
    const q = newtrans(p) orelse return null;

    // Match what needs to be forwarded
    q.forward.trans = 1;
    q.forward.lport = dp;
    q.forward.rport = sp;
    ipmove(&q.forward.laddr, da);
    ipmove(&q.forward.raddr, sa);

    // Match what comes back to us
    q.backward.trans = 2;
    q.backward.lport = lp;
    ipmove(&q.backward.laddr, la);
    if (p.ipproto == 1 or p.ipproto == 17) {
        // ICMP and UDP allow reply from anyone (for hole punching)
        q.backward.rport = 0;
        ipmove(&q.backward.raddr, &IPnoaddr);
    } else {
        q.backward.rport = dp;
        ipmove(&q.backward.raddr, da);
    }

    netlog(p.f.?, ipdat.Logtrans, "trans: adding %s!%I!%d -> %I!%d -> %I!%d\n", .{
        p.name,
        ip(&q.forward.raddr),
        q.forward.rport,
        ip(&q.backward.laddr),
        q.backward.lport,
        ip(&q.forward.laddr),
        q.forward.lport,
    });

    q.routehint = rh;

    iphtadd(p.ht.?, &q.forward);
    iphtadd(p.ht.?, &q.backward);

    return transupdate(p, q);
}

/// Called with the 4-tuple (sa,sp,da,dp)
/// that should be source translated,
/// returning the translation.
///
/// Proto is locked.
pub fn transforward(
    p: *Proto,
    sa: *const [IPaddrlen]u8,
    sp: u16,
    da: *const [IPaddrlen]u8,
    dp: u16,
    r_: ?*Route,
) ?*Translation {
    const f = p.f.?;
    var la: [IPaddrlen]u8 = undefined;
    var rh: Routehint = .{};

    // Translation already exists?
    if (iphtlook(p.ht.?, sa, sp, da, dp)) |iph| {
        if (iph.trans == 1)
            return transupdate(p, ipdat.iphforward(iph));
        if (iph.match == ipdat.IPmatchexact) {
            netlog(f, ipdat.Logtrans, "trans: backwards collision: %s!%I!%d -> %I!%d\n", .{ p.name, ip(sa), sp, ip(da), dp });
            return null;
        }
    }

    // No route means dont make a new entry
    var r = r_ orelse return null;

    // Bad forward route?
    const ifc = r.ifc orelse {
        netlog(f, ipdat.Logtrans, "trans: no interface: %s!%I!%d -> %I!%d\n", .{ p.name, ip(sa), sp, ip(da), dp });
        return null;
    };

    // Bad source address?
    if (ipismulticast(sa) != 0 or ipifc.ipforme(f, sa) != 0) {
        netlog(f, ipdat.Logtrans, "trans: bad source address: %s!%I!%d -> %I!%d\n", .{ p.name, ip(sa), sp, ip(da), dp });
        return null;
    }

    // Find a source address on the destination interface
    ql.rlock(&ifc.rwlock);
    @memcpy(la[0..IPv4off], v4prefix[0..IPv4off]);
    @memset(la[IPv4off..], 0);
    const remote: *const [IPv4addrlen]u8 =
        if (r.type & (ipdat.Rifc | ipdat.Runi | ipdat.Rbcast | ipdat.Rmulti) != 0) da[IPv4off..] else &r.u.v4.gate;
    if (!ipifc.ipv4local(ifc, la[IPv4off..], 0, remote)) {
        ql.runlock(&ifc.rwlock);
        netlog(f, ipdat.Logtrans, "trans: no source ip: %s!%I!%d -> %I!%d\n", .{ p.name, ip(sa), sp, ip(da), dp });
        return null;
    }
    ql.runlock(&ifc.rwlock);

    // Check backward route
    const back = if (ipismulticast(da) != 0)
        iproute.v4lookup(f, sa[IPv4off..], la[IPv4off..], null)
    else
        iproute.v4lookup(f, sa[IPv4off..], da[IPv4off..], &rh);
    if (back) |b| r = b;
    if (back == null or (r.ifc == ifc and !ifc.reflect)) {
        netlog(f, ipdat.Logtrans, "trans: bad backward route: %s!%I!%d <- %I <- %I!%d\n", .{ p.name, ip(sa), sp, ip(&la), ip(da), dp });
        return null;
    }

    // Find local port
    const lp = devip.unusedlport(p) orelse {
        netlog(f, ipdat.Logtrans, "trans: no local port: %s!%I!%d <- %I <- %I!%d\n", .{ p.name, ip(sa), sp, ip(&la), ip(da), dp });
        return null;
    };

    return addtrans(p, da, dp, sa, sp, &la, lp, rh);
}

/// Check if backward translation is valid and
/// update timestamp.
///
/// Proto is locked.
pub fn transbackward(p: *Proto, iph_: ?*Iphash) ?*Translation {
    const iph = iph_ orelse return null;
    if (iph.trans != 2)
        return null;
    return transupdate(p, ipdat.iphbackward(iph));
}

const Transfmtsize = 3 * 16 + 3 * 6; // excluding \0

pub fn transfsize(p: *Proto) ?usize {
    var n: usize = 0;

    if (p.ht == null or p.forward == null)
        return null;

    qlock(&p.qlock);
    var l = p.translations;
    while (l) |q| : (l = q.next)
        n += Transfmtsize;
    qunlock(&p.qlock);

    return n;
}

pub fn transread(p: *Proto, a: []u8, off_: usize) Error!usize {
    var off = off_;
    var n = a.len;
    if (n > portdat.READSTR)
        n = portdat.READSTR;

    const b = alloc.malloc(n + 1) orelse return error.Enomem;
    defer alloc.free(b);
    var s: usize = 0;

    qlock(&p.qlock);
    var l = p.translations;
    while (l) |q| : (l = q.next) {
        if (n < Transfmtsize)
            break;
        const m = fmt.snprint(b[s..][0..n], "%-15I %5d %-15I %5d %-15I %5d\n", .{
            ip(&q.forward.laddr), q.forward.lport, // da, dp
            ip(&q.forward.raddr), q.forward.rport, // sa, sp
            ip(&q.backward.laddr), q.backward.lport, // la, lp
        }).len;
        if (off != 0) {
            if (m < off)
                off -= m
            else
                off = 0;
            continue;
        }
        s += m;
        n -= m;
    }
    qunlock(&p.qlock);

    // copy outside of lock
    @memcpy(a[0..s], b[0..s]);

    return s;
}

fn flushtrans(p: *Proto) void {
    // Delete all active translations
    var last: ?*Translation = null;
    var it = p.translations;
    while (it) |q| : (it = q.next)
        last = deltrans(p, q);
    const l = last orelse return;

    // Tanslation list becomes freelist
    const q = p.translations.?;
    p.translations = null;
    l.next = p.freetranslations;
    if (l.next) |n|
        n.link = &l.next;
    q.link = &p.freetranslations;
    p.freetranslations = q;
}

pub fn transwrite(p: *Proto, a: []const u8, off: usize) Error!usize {
    var buf: [Transfmtsize + 1]u8 = undefined;
    var f: [6][]u8 = undefined;
    var da: [IPaddrlen]u8 = undefined;
    var sa: [IPaddrlen]u8 = undefined;
    var la: [IPaddrlen]u8 = undefined;
    var rh: Routehint = .{};
    const n = a.len;
    const fs = p.f.?;

    if (p.ht == null or p.forward == null)
        return proc.errorf("protocol does not support translations", .{});

    if (n == 0 and off == 0) {
        qlock(&p.qlock);
        flushtrans(p);
        qunlock(&p.qlock);
        return n;
    }
    if (n >= buf.len)
        return error.Ebadctl;
    @memcpy(buf[0..n], a);
    if (parse.tokenize(buf[0..n], &f) != 6)
        return error.Ebadctl;

    if (parseip(&da, f[0]) == -1 or !isv4(&da))
        return error.Ebadctl;
    const dp = strtoul(f[1], 0).v;
    if (dp & ~@as(u32, 0xffff) != 0)
        return error.Ebadctl;
    if (parseip(&sa, f[2]) == -1 or !isv4(&sa))
        return error.Ebadctl;
    const sp = strtoul(f[3], 0).v;
    if (sp & ~@as(u32, 0xffff) != 0)
        return error.Ebadctl;
    if (parseip(&la, f[4]) == -1 or !isv4(&la))
        return error.Ebadctl;
    const lp = strtoul(f[5], 0).v;
    if (lp & ~@as(u32, 0xffff) != 0)
        return error.Ebadctl;

    if (ipifc.ipforme(fs, &la) != ipdat.Runi)
        return proc.errorf("local ip not found", .{});

    if (ipismulticast(&sa) != 0 or ipifc.ipforme(fs, &sa) != 0)
        return proc.errorf("bad source address", .{});

    // check forward route
    var r = iproute.v4lookup(fs, da[IPv4off..], sa[IPv4off..], null);
    if (r == null or (r.?.type & ipdat.Rtrans) == 0)
        return proc.errorf("no translating route to desination", .{});

    // check backward route
    if (ipismulticast(&da) != 0)
        r = iproute.v4lookup(fs, sa[IPv4off..], la[IPv4off..], null)
    else
        r = iproute.v4lookup(fs, sa[IPv4off..], da[IPv4off..], &rh);
    if (r == null)
        return proc.errorf("no route to soruce address", .{});

    qlock(&p.qlock);
    defer qunlock(&p.qlock);
    if (devip.lportinuse(p, @intCast(lp)))
        return proc.errorf("local port in use", .{});
    _ = addtrans(p, &da, @intCast(dp), &sa, @intCast(sp), &la, @intCast(lp), rh);

    return n;
}

/// Checksum adjusting hnputs()
pub fn hnputs_csum(p: *[2]u8, v_: u16, pcsum: *[2]u8) void {
    var v = v_;

    var csum: u32 = nhgets(pcsum) ^ 0xFFFF;
    var o = nhgets(p);
    hnputs(p, v);
    if ((@intFromPtr(p) -% @intFromPtr(pcsum)) & 1 != 0) {
        o = o << 8 | o >> 8;
        v = v << 8 | v >> 8;
    }
    csum += o ^ 0xFFFF;
    csum += v;
    while (csum >> 16 != 0)
        csum = (csum & 0xFFFF) + (csum >> 16);
    hnputs(pcsum, @as(u16, @truncate(csum)) ^ 0xFFFF);
}

//
// from libip/ipaux.c
//

//
//  well known IP addresses
//
pub const IPv4bcast: [IPaddrlen]u8 = .{
    0,    0,    0,    0,
    0,    0,    0,    0,
    0,    0,    0xff, 0xff,
    0xff, 0xff, 0xff, 0xff,
};
pub const IPv4allsys: [IPaddrlen]u8 = .{
    0,    0, 0,    0,
    0,    0, 0,    0,
    0,    0, 0xff, 0xff,
    0xe0, 0, 0,    0x01,
};
pub const IPv4allrouter: [IPaddrlen]u8 = .{
    0,    0, 0,    0,
    0,    0, 0,    0,
    0,    0, 0xff, 0xff,
    0xe0, 0, 0,    0x02,
};
pub const IPallbits: [IPaddrlen]u8 = @splat(0xff);
pub const IPnoaddr: [IPaddrlen]u8 = @splat(0);

//
//  prefix of all v4 addresses
//
pub const v4prefix: [IPaddrlen]u8 = .{
    0, 0, 0,    0,
    0, 0, 0,    0,
    0, 0, 0xff, 0xff,
    0, 0, 0,    0,
};

pub fn isv4(ip_: *const [IPaddrlen]u8) bool {
    return std.mem.eql(u8, ip_[0..IPv4off], v4prefix[0..IPv4off]);
}

//
//  the following routines are unrolled with no memset's to speed
//  up the usual case
//
pub fn v4tov6(v6: *[IPaddrlen]u8, v4_: *const [IPv4addrlen]u8) void {
    // DIFF: the four bytes are read first, so v4_ may be any part of v6.
    const a = v4_.*;
    v6[0] = 0;
    v6[1] = 0;
    v6[2] = 0;
    v6[3] = 0;
    v6[4] = 0;
    v6[5] = 0;
    v6[6] = 0;
    v6[7] = 0;
    v6[8] = 0;
    v6[9] = 0;
    v6[10] = 0xff;
    v6[11] = 0xff;
    v6[12] = a[0];
    v6[13] = a[1];
    v6[14] = a[2];
    v6[15] = a[3];
}

/// 0, or -1 if v6 is neither a v4 address nor IPnoaddr.
pub fn v6tov4(v4_: *[IPv4addrlen]u8, v6: *const [IPaddrlen]u8) i32 {
    if (v6[0] == 0 and
        v6[1] == 0 and
        v6[2] == 0 and
        v6[3] == 0 and
        v6[4] == 0 and
        v6[5] == 0 and
        v6[6] == 0 and
        v6[7] == 0 and
        v6[8] == 0 and
        v6[9] == 0 and
        v6[10] == 0xff and
        v6[11] == 0xff)
    {
        v4_[0] = v6[12];
        v4_[1] = v6[13];
        v4_[2] = v6[14];
        v4_[3] = v6[15];
        return 0;
    } else {
        const none = std.mem.eql(u8, v6, &IPnoaddr);
        @memset(v4_, 0);
        if (none)
            return 0;
        return -1;
    }
}

//
// from libip/classmask.c
//

const classmask: [4][IPaddrlen]u8 = .{
    .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00 },
    .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00 },
    .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00 },
    .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 },
};

pub fn defmask(ip_: *const [IPaddrlen]u8) *const [IPaddrlen]u8 {
    if (isv4(ip_))
        return &classmask[ip_[IPv4off] >> 6]
    else {
        if (ipcmp(ip_, &v6loopback) == 0)
            return &IPallbits
        else if (std.mem.eql(u8, ip_[0..v6llpreflen], v6linklocal[0..v6llpreflen]))
            return &v6linklocalmask
        else if (std.mem.eql(u8, ip_[0..v6snpreflen], v6solicitednode[0..v6snpreflen]))
            return &v6solicitednodemask
        else if (std.mem.eql(u8, ip_[0..v6mcpreflen], v6multicast[0..v6mcpreflen]))
            return &v6multicastmask;
        return &IPallbits;
    }
}

/// `to` may be `from`.
pub fn maskip(from: *const [IPaddrlen]u8, mask_: *const [IPaddrlen]u8, to: *[IPaddrlen]u8) void {
    for (0..IPaddrlen) |i|
        to[i] = from[i] & mask_[i];
}

//
// from libip/equivip.c
//

pub fn equivip4(a: *const [IPv4addrlen]u8, b: *const [IPv4addrlen]u8) bool {
    for (0..IPv4addrlen) |i| {
        if (a[i] != b[i])
            return false;
    }
    return true;
}

pub fn equivip6(a: *const [IPaddrlen]u8, b: *const [IPaddrlen]u8) bool {
    for (0..IPaddrlen) |i| {
        if (a[i] != b[i])
            return false;
    }
    return true;
}

//
// from libip/parseip.c
//

/// Parse a dotted v4 address, which may leave out zero bytes in the
/// middle as class A and B addresses once did.  Returns how many bytes
/// of `from` it used.
pub fn v4parseip(to: *[IPv4addrlen]u8, from: []const u8) usize {
    var p: usize = 0;
    var i: usize = 0;
    while (i < 4 and at(from, p) != 0) : (i += 1) {
        const r = strtoul(rest(from, p), 0);
        to[i] = @truncate(r.v);
        p += r.n;
        if (at(from, p) == '.')
            p += 1;
    }
    switch (CLASS(to)) {
        0, 1 => { // class A - 1 uchar net
            if (i == 3) {
                to[3] = to[2];
                to[2] = to[1];
                to[1] = 0;
            } else if (i == 2) {
                to[3] = to[1];
                to[1] = 0;
            }
        },
        2 => { // class B - 2 uchar net
            if (i == 3) {
                to[3] = to[2];
                to[2] = 0;
            }
        },
        else => {},
    }
    return p;
}

fn ipcharok(c: u8) bool {
    return c == '.' or c == ':' or (std.ascii.isAscii(c) and std.ascii.isHex(c));
}

fn delimchar(c: u8) bool {
    if (c == 0)
        return true;
    if (c == '.' or c == ':' or (std.ascii.isAscii(c) and std.ascii.isAlphanumeric(c)))
        return false;
    return true;
}

/// `from' may contain an address followed by other characters,
/// at least in /boot, so we permit whitespace (and more) after the address.
/// we do ensure that "delete" cannot be parsed as "de::".
///
/// some callers don't check the return value for errors, so
/// set `to' to something distinctive in the case of a parse error.
pub fn parseip(to: *[IPaddrlen]u8, from: []const u8) i64 {
    var elipsis: usize = 0;
    var isv4addr = true;

    @memset(to, 0);
    var p: usize = 0;
    var i: usize = 0;
    while (i < IPaddrlen and ipcharok(at(from, p))) : (i += 2) {
        const op = p;
        const r = strtoul(rest(from, p), 16);
        const x = r.v;
        p += r.n;
        if (at(from, p) == '.' or (at(from, p) == 0 and i == 0)) { // ends with v4?
            if (i > IPaddrlen - 4) {
                @memset(to, 0);
                return -1; // parse error
            }
            p = op + v4parseip(to[i..][0..4], rest(from, op));
            i += 4;
            break;
        }
        // v6: at most 4 hex digits, followed by colon or delim
        if (x != @as(u16, @truncate(x)) or (at(from, p) != ':' and !delimchar(at(from, p)))) {
            @memset(to, 0);
            return -1; // parse error
        }
        to[i] = @truncate(x >> 8);
        to[i + 1] = @truncate(x);
        if (at(from, p) == ':') {
            isv4addr = false;
            p += 1;
            if (at(from, p) == ':') { // :: is elided zero short(s)
                if (elipsis != 0) {
                    @memset(to, 0);
                    return -1; // second ::
                }
                elipsis = i + 2;
                p += 1;
            }
        } else if (p == op) // strtoul made no progress?
            break;
    }
    if (p == 0 or !delimchar(at(from, p))) {
        @memset(to, 0);
        return -1; // parse error
    }
    if (i < IPaddrlen) {
        const n = i - elipsis;
        @memmove(to[elipsis + IPaddrlen - i ..][0..n], to[elipsis..][0..n]);
        @memset(to[elipsis..][0 .. IPaddrlen - i], 0);
    }
    if (isv4addr) {
        to[10] = 0xff;
        to[11] = 0xff;
        return nhgetl(to[IPv4off..]);
    } else return 6;
}

/// hack to allow ip v4 masks to be entered in the old
/// style
pub fn parseipmask(to: *[IPaddrlen]u8, from: []const u8, isv4addr: bool) i64 {
    var x: i64 = undefined;

    if (at(from, 0) == '/') {
        // as a number of prefix bits
        var i = netif.atoi(from[1..]);
        if (i < 0)
            i = 0;
        if (i <= 32 and isv4addr)
            i += 96;
        if (i > 128)
            i = 128;
        const w = i;
        @memset(to, 0);
        var p: usize = 0;
        while (i >= 8) : (i -= 8) {
            to[p] = 0xff;
            p += 1;
        }
        if (i > 0)
            to[p] = ~@as(u8, @truncate((@as(u32, 1) << @intCast(8 - i)) - 1));
        // identify as ipv6 if the mask is inexpressible as a v4 mask
        // (because it has too few mask bits).  Arguably, we could
        // always return 6 here.
        if (w < 96)
            return if (isv4addr) -1 else 6;
        x = nhgetl(to[IPv4off..]);
    } else {
        // as a straight v4 bit mask
        x = parseip(to, from);
        if (std.mem.eql(u8, to[0..IPv4off], v4prefix[0..IPv4off]))
            @memset(to[0..IPv4off], 0xff)
        else if (isv4addr and !std.mem.eql(u8, to[0..IPv4off], IPallbits[0..IPv4off]))
            x = -1;
    }
    return x;
}

pub fn parseipandmask(ip_: *[IPaddrlen]u8, mask_: *[IPaddrlen]u8, ipstr: []const u8, maskstr: ?[]const u8) i64 {
    var x = parseip(ip_, ipstr);
    if (maskstr) |ms| {
        if (parseipmask(mask_, ms, std.mem.eql(u8, ip_[0..IPv4off], v4prefix[0..IPv4off])) == -1)
            x = -1;
    } else @memset(mask_, 0xff);
    return x;
}

//
// from libip/ptclbsum.c
//

const LITTLE = builtin.cpu.arch.endian() == .little;

fn word(addr: [*]const u8) u32 {
    return @as(*align(1) const u16, @ptrCast(addr)).*;
}

/// The sum of the data as 16 bit big-endian words, folded to 16 bits
/// but not inverted.  A block that starts at an odd address or has an
/// odd length is handled.
pub fn ptclbsum(data: []const u8) u16 {
    var addr = data.ptr;
    var len = data.len;

    var losum: u32 = 0;
    var hisum: u32 = 0;
    var mdsum: u32 = 0;

    var x = false;
    if (@intFromPtr(addr) & 1 != 0) {
        if (len != 0) {
            hisum +%= addr[0];
            len -= 1;
            addr += 1;
        }
        x = true;
    }
    while (len >= 16) {
        mdsum +%= word(addr + 0);
        mdsum +%= word(addr + 2);
        mdsum +%= word(addr + 4);
        mdsum +%= word(addr + 6);
        mdsum +%= word(addr + 8);
        mdsum +%= word(addr + 10);
        mdsum +%= word(addr + 12);
        mdsum +%= word(addr + 14);
        len -= 16;
        addr += 16;
    }
    while (len >= 2) {
        mdsum +%= word(addr);
        len -= 2;
        addr += 2;
    }
    if (x) {
        if (len != 0)
            losum +%= addr[0];
        if (LITTLE)
            losum +%= mdsum
        else
            hisum +%= mdsum;
    } else {
        if (len != 0)
            hisum +%= addr[0];
        if (LITTLE)
            hisum +%= mdsum
        else
            losum +%= mdsum;
    }

    losum +%= hisum >> 8;
    losum +%= (hisum & 0xff) << 8;
    while (losum >> 16 != 0)
        losum = (losum >> 16) + (losum & 0xffff);

    return @truncate(losum);
}

//
// from libip/eipfmt.c
//

const prefixvals: [256]u8 = blk: {
    var t: [256]u8 = @splat(0);
    t[0x00] = 0 | Isprefix;
    t[0x80] = 1 | Isprefix;
    t[0xC0] = 2 | Isprefix;
    t[0xE0] = 3 | Isprefix;
    t[0xF0] = 4 | Isprefix;
    t[0xF8] = 5 | Isprefix;
    t[0xFC] = 6 | Isprefix;
    t[0xFE] = 7 | Isprefix;
    t[0xFF] = 8 | Isprefix;
    break :blk t;
};

/// libc's fmtstrcpy: the precision cuts the string, the width pads it.
fn fmtstrcpy(f: *fmt.Fmt, s_: []const u8) void {
    var s = s_; // ASCII only
    if (f.flags.prec and f.prec < s.len)
        s = s[0..f.prec];
    f.pad(s);
}

fn eipv4(f: *fmt.Fmt, p: *const [IPv4addrlen]u8) void {
    var buf: [5 * 8]u8 = undefined;
    fmtstrcpy(f, fmt.snprint(&buf, "%d.%d.%d.%d", .{ p[0], p[1], p[2], p[3] }));
}

fn eipcommon(f: *fmt.Fmt, p: *const [IPaddrlen]u8) void {
    var buf: [5 * 8]u8 = undefined;

    if (std.mem.eql(u8, p[0..12], v4prefix[0..12]))
        return eipv4(f, p[12..16]);

    // find longest elision
    var eln: usize = 0;
    var eli: usize = IPaddrlen; // none
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        var j = i;
        while (j < 16) : (j += 2) {
            if (p[j] != 0 or p[j + 1] != 0)
                break;
        }
        if (j > i and j - i > eln) {
            eli = i;
            eln = j - i;
        }
    }

    // print with possible elision
    var n: usize = 0;
    i = 0;
    while (i < 16) : (i += 2) {
        if (i == eli) {
            n += fmt.snprint(buf[n..], "::", .{}).len;
            i += eln;
            if (i >= 16)
                break;
        } else if (i != 0)
            n += fmt.snprint(buf[n..], ":", .{}).len;
        const s = @as(u16, p[i]) << 8 | p[i + 1];
        n += fmt.snprint(buf[n..], "%ux", .{s}).len;
    }
    fmtstrcpy(f, buf[0..n]);
}

/// A 16 byte address or mask that prints itself: the C's eipfmt for
/// %I (an address; dotted when it is a v4 address), %M (a mask, as
/// /bits when it can be) and %V (the first four bytes, dotted).
pub const IPaddr = struct {
    a: [IPaddrlen]u8,

    pub fn fmt9(self: IPaddr, f: *fmt.Fmt) void {
        var buf: [5 * 8]u8 = undefined;
        const p = &self.a;

        switch (f.r) {
            'I' => eipcommon(f, p), // Ip address
            'V' => eipv4(f, p[0..4]), // v4 ip address
            'M' => { // ip mask
                // look for a prefix mask
                var i: usize = 0;
                while (i < 16) : (i += 1) {
                    if (p[i] != 0xff)
                        break;
                }
                var n: usize = undefined;
                if (i < 16) {
                    if ((prefixvals[p[i]] & Isprefix) == 0)
                        return eipcommon(f, p);
                    for (p[i + 1 ..]) |c| {
                        if (c != 0)
                            return eipcommon(f, p);
                    }
                    n = 8 * i + (prefixvals[p[i]] & ~@as(u8, Isprefix));
                } else n = 8 * 16;

                // got one, use /xx format
                fmtstrcpy(f, fmt.snprint(&buf, "/%d", .{n}));
            },
            else => fmtstrcpy(f, "(eipfmt)"),
        }
    }
};

/// A 4 byte address that prints itself dotted, for %V.
pub const V4addr = struct {
    a: [IPv4addrlen]u8,

    pub fn fmt9(self: V4addr, f: *fmt.Fmt) void {
        eipv4(f, &self.a);
    }
};

pub const Eaddr = devether.Eaddr;

/// The first n bytes of an array, of what a pointer to an array points
/// to, or of a slice.
fn bytes(comptime n: usize, a: anytype) [n]u8 {
    return switch (@typeInfo(@TypeOf(a))) {
        .array => a,
        .pointer => |ptr| switch (ptr.size) {
            .one => a.*,
            else => a[0..n].*,
        },
        else => @compileError("ipaux: cannot format " ++ @typeName(@TypeOf(a)) ++ " as an address"),
    };
}

/// print("%I", .{ip(addr)})
pub fn ip(a: anytype) IPaddr {
    return .{ .a = bytes(IPaddrlen, a) };
}

/// print("%M", .{mask(m)})
pub fn mask(a: anytype) IPaddr {
    return .{ .a = bytes(IPaddrlen, a) };
}

/// print("%V", .{v4(addr)}), addr in 4 byte form.
pub fn v4(a: anytype) V4addr {
    return .{ .a = bytes(IPv4addrlen, a) };
}

/// print("%E", .{ea(mac)})
pub fn ea(a: anytype) Eaddr {
    return .{ .a = bytes(netif.Eaddrlen, a) };
}

fn expectfmt(want: []const u8, comptime format: []const u8, args: anytype) !void {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(want, fmt.snprint(&buf, format, args));
}

fn parsed(s: []const u8) [IPaddrlen]u8 {
    var a: [IPaddrlen]u8 = undefined;
    _ = parseip(&a, s);
    return a;
}

fn pmask(s: []const u8) [IPaddrlen]u8 {
    var a: [IPaddrlen]u8 = undefined;
    _ = parseipmask(&a, s, true);
    return a;
}

test "parseip" {
    var a: [IPaddrlen]u8 = undefined;

    try std.testing.expectEqual(@as(i64, 0x0a000102), parseip(&a, "10.0.1.2"));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 1, 2 }, &a);
    try std.testing.expectEqual(@as(i64, 0xc0a80001), parseip(&a, "192.168.0.1 and more"));
    try std.testing.expectEqual(@as(i64, 0xffffffff), parseip(&a, "255.255.255.255"));
    // old style: zero bytes left out of class A and B addresses
    try std.testing.expectEqual(@as(i64, 0x0a000001), parseip(&a, "10.1"));
    try std.testing.expectEqual(@as(i64, 0x0a000102), parseip(&a, "10.1.2"));
    try std.testing.expectEqual(@as(i64, 0x80010002), parseip(&a, "128.1.2"));
    // a string that ends at a NUL
    try std.testing.expectEqual(@as(i64, 0x7f000001), parseip(&a, "127.0.0.1\x00junk"));

    try std.testing.expectEqual(@as(i64, 6), parseip(&a, "2001:db8::1"));
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &a);
    try std.testing.expectEqual(@as(i64, 6), parseip(&a, "::1"));
    try std.testing.expectEqualSlices(u8, &v6loopback, &a);
    try std.testing.expectEqual(@as(i64, 6), parseip(&a, "::"));
    try std.testing.expectEqualSlices(u8, &IPnoaddr, &a);
    try std.testing.expectEqual(@as(i64, 6), parseip(&a, "fe80::"));
    try std.testing.expectEqualSlices(u8, &v6linklocal, &a);
    try std.testing.expectEqual(@as(i64, 6), parseip(&a, "ff02::1:ff00:0"));
    try std.testing.expectEqualSlices(u8, &v6solicitednode, &a);
    try std.testing.expectEqual(@as(i64, 6), parseip(&a, "1:2:3:4:5:6:7:8"));
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8 }, &a);
    try std.testing.expectEqual(@as(i64, 6), parseip(&a, "::ffff:1.2.3.4"));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 1, 2, 3, 4 }, &a);
    try std.testing.expectEqual(@as(i64, 6), parseip(&a, "fe80::1%ether0"));

    try std.testing.expectEqual(@as(i64, -1), parseip(&a, ""));
    try std.testing.expectEqualSlices(u8, &IPnoaddr, &a);
    try std.testing.expectEqual(@as(i64, -1), parseip(&a, "delete"));
    try std.testing.expectEqual(@as(i64, -1), parseip(&a, "1::2::3"));
    try std.testing.expectEqual(@as(i64, -1), parseip(&a, "12345::"));
    try std.testing.expectEqual(@as(i64, -1), parseip(&a, "1:2:3:4:5:6:7:1.2.3.4"));
    try std.testing.expectEqual(@as(i64, -1), parseip(&a, "hello"));
}

test "parseipmask and parseipandmask" {
    var a: [IPaddrlen]u8 = undefined;
    var m: [IPaddrlen]u8 = undefined;

    try std.testing.expectEqual(@as(i64, 0xffffff00), parseipmask(&m, "/24", true));
    try expectfmt("/120", "%M", .{mask(m)});
    try std.testing.expectEqual(@as(i64, 0xffffff00), parseipmask(&m, "/120", false));
    try std.testing.expectEqual(@as(i64, 6), parseipmask(&m, "/64", false));
    try std.testing.expectEqualSlices(u8, &v6linklocalmask, &m);
    try std.testing.expectEqual(@as(i64, -1), parseipmask(&m, "/64", true));
    try std.testing.expectEqual(@as(i64, 0xfffffe00), parseipmask(&m, "/23", true));
    try std.testing.expectEqual(@as(u8, 0xfe), m[14]);
    try std.testing.expectEqual(@as(i64, 0xffff0000), parseipmask(&m, "255.255.0.0", true));
    try expectfmt("/112", "%M", .{mask(&m)});
    try std.testing.expectEqual(@as(i64, 6), parseipmask(&m, "ffff:ffff::", false));
    try expectfmt("/32", "%M", .{mask(&m)});
    try std.testing.expectEqual(@as(i64, -1), parseipmask(&m, "ffff:ffff::", true));
    try std.testing.expectEqual(@as(i64, 0xffffffff), parseipmask(&m, "/200", true));
    try std.testing.expectEqualSlices(u8, &IPallbits, &m);

    try std.testing.expectEqual(@as(i64, 0x0a000001), parseipandmask(&a, &m, "10.0.0.1", "/8"));
    try expectfmt("10.0.0.1 /104", "%I %M", .{ ip(a), mask(m) });
    try std.testing.expectEqual(@as(i64, 0x0a000001), parseipandmask(&a, &m, "10.0.0.1", null));
    try std.testing.expectEqualSlices(u8, &IPallbits, &m);
    try std.testing.expectEqual(@as(i64, 6), parseipandmask(&a, &m, "2001:db8::", "/32"));
    try expectfmt("2001:db8:: /32", "%I %M", .{ ip(a), mask(m) });
    try std.testing.expectEqual(@as(i64, -1), parseipandmask(&a, &m, "10.0.0.1", "/8x"[0..0]));
}

test "eipfmt" {
    try expectfmt("10.0.1.2", "%I", .{ip(parsed("10.0.1.2"))});
    try expectfmt("0.0.0.0", "%I", .{ip(&v4prefix)});
    try expectfmt("255.255.255.255", "%I", .{ip(IPv4bcast)});
    try expectfmt("::", "%I", .{ip(&IPnoaddr)});
    try expectfmt("::1", "%I", .{ip(&v6loopback)});
    try expectfmt("fe80::", "%I", .{ip(&v6linklocal)});
    try expectfmt("ff02::1", "%I", .{ip(&v6allnodesL)});
    try expectfmt("ff02::1:ff00:0", "%I", .{ip(&v6solicitednode)});
    try expectfmt("2001:db8::1", "%I", .{ip(parsed("2001:db8:0:0:0:0:0:1"))});
    // the first of two runs of the same length
    try expectfmt("1::2:0:0:3:4", "%I", .{ip(parsed("1:0:0:2:0:0:3:4"))});
    // the longer run, wherever it is
    try expectfmt("1:0:0:2::3", "%I", .{ip(parsed("1:0:0:2:0:0:0:3"))});
    // a single zero is elided too
    try expectfmt("1:2:3::5:6:7:8", "%I", .{ip(parsed("1:2:3:0:5:6:7:8"))});
    try expectfmt("1:2:3:4:5:6:7::", "%I", .{ip(parsed("1:2:3:4:5:6:7:0"))});
    try expectfmt("1:2:3:4:5:6:7:8", "%I", .{ip(parsed("1:2:3:4:5:6:7:8"))});
    try expectfmt("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "%I", .{ip(IPallbits)});
    // no leading zeros, lower case
    try expectfmt("fe80::a:bc:def:1234", "%I", .{ip(parsed("fe80::000a:00bc:0def:1234"))});

    // width, left justification and precision as fmtstrcpy does them
    try expectfmt("[10.0.0.1       ]", "[%-15I]", .{ip(parsed("10.0.0.1"))});
    try expectfmt("[       10.0.0.1]", "[%15I]", .{ip(parsed("10.0.0.1"))});
    try expectfmt("[fe80::1                                 ]", "[%-40.40I]", .{ip(parsed("fe80::1"))});
    try expectfmt("[2001:d]", "[%.6I]", .{ip(parsed("2001:db8::1"))});

    try expectfmt("/128", "%M", .{mask(IPallbits)});
    try expectfmt("/0", "%M", .{mask(IPnoaddr)});
    try expectfmt("/64", "%M", .{mask(v6linklocalmask)});
    try expectfmt("/104", "%M", .{mask(v6solicitednodemask)});
    try expectfmt("/121", "%M", .{mask(pmask("255.255.255.128"))});
    // an address is not a mask
    try expectfmt("255.255.255.128", "%M", .{mask(parsed("255.255.255.128"))});
    try expectfmt("/97", "%M", .{mask(parsed("ffff:ffff:ffff:ffff:ffff:ffff:8000:0"))});
    // not a prefix: printed as an address
    try expectfmt("ffff:ffff:ffff:ffff:ffff:ffff:ff00:ff00", "%M", .{mask(parsed("ffff:ffff:ffff:ffff:ffff:ffff:ff00:ff00"))});
    try expectfmt("ffff:ffff:ffff:ffff:ffff:ffff:a000::", "%M", .{mask(parsed("ffff:ffff:ffff:ffff:ffff:ffff:a000:0"))});
    try expectfmt("255.0.255.0", "%M", .{mask(parsed("255.0.255.0"))});
    try expectfmt("[/120      ]", "[%-10M]", .{mask(parsed("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ff00"))});

    const a4: [4]u8 = .{ 192, 168, 1, 200 };
    try expectfmt("192.168.1.200", "%V", .{v4(a4)});
    try expectfmt("192.168.1.200", "%V", .{v4(&a4)});
    try expectfmt("1.2.3.4", "%V", .{v4(parsed("1.2.3.4")[IPv4off..])});
    try expectfmt("0.0.0.0", "%V", .{ip(v4prefix)});

    const mac: [8]u8 = .{ 0x00, 0x50, 0xc2, 0x0a, 0xbc, 0xff, 0, 0 };
    try expectfmt("0050c20abcff", "%E", .{ea(mac[0..6])});
    try expectfmt("(eipfmt)", "%d", .{ip(IPnoaddr)});
}

/// The checksum the slow way.
fn refsum(data: []const u8) u16 {
    var sum: u32 = 0;
    for (data, 0..) |c, i|
        sum += if (i & 1 == 0) @as(u32, c) << 8 else c;
    while (sum >> 16 != 0)
        sum = (sum >> 16) + (sum & 0xffff);
    return @truncate(sum);
}

test "ptclbsum" {
    // the example of RFC 1071
    const rfc: [8]u8 align(2) = .{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try std.testing.expectEqual(@as(u16, 0xddf2), ptclbsum(&rfc));

    var buf: [259]u8 align(16) = undefined;
    for (&buf, 0..) |*c, i|
        c.* = @truncate(i *% 151 +% 43);
    buf[0] = 0xff;
    buf[1] = 0xff;
    // every start (even and odd addresses) and every length up to
    // beyond the unrolled loop
    for (0..9) |start| {
        for (0..120) |len| {
            const d = buf[start..][0..len];
            try std.testing.expectEqual(refsum(d), ptclbsum(d));
        }
    }
    try std.testing.expectEqual(refsum(&buf), ptclbsum(&buf));
    try std.testing.expectEqual(refsum(buf[1..]), ptclbsum(buf[1..]));
    try std.testing.expectEqual(@as(u16, 0), ptclbsum(buf[0..0]));
    try std.testing.expectEqual(@as(u16, 0xffff), ptclbsum(buf[0..2]));

    // a real v4 header: the sum over it with its checksum is ffff
    const hdr: [20]u8 align(2) = .{
        0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11,
        0xb8, 0x61, 0xc0, 0xa8, 0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7,
    };
    try std.testing.expectEqual(@as(u16, 0xffff), ptclbsum(&hdr));
}

test "ptclcsum over a block list" {
    var data: [64]u8 align(8) = undefined;
    for (&data, 0..) |*c, i|
        c.* = @truncate(i *% 89 +% 7);

    // one block
    var b1: Block = .{ .rp = &data, .wp = @as([*]u8, &data) + 64, .lim = @as([*]u8, &data) + 64, .base = &data };
    try std.testing.expectEqual(refsum(data[4..40]) ^ 0xffff, ptclcsum(&b1, 4, 36));
    // asking for more than there is
    try std.testing.expectEqual(refsum(data[4..]) ^ 0xffff, ptclcsum(&b1, 4, 1000));

    // the same bytes cut into blocks of odd sizes
    var b3: Block = .{ .rp = @as([*]u8, &data) + 30, .wp = @as([*]u8, &data) + 64, .lim = @as([*]u8, &data) + 64, .base = &data };
    var b2: Block = .{ .next = &b3, .rp = @as([*]u8, &data) + 13, .wp = @as([*]u8, &data) + 30, .lim = @as([*]u8, &data) + 64, .base = &data };
    var b0: Block = .{ .next = &b2, .rp = &data, .wp = @as([*]u8, &data) + 13, .lim = @as([*]u8, &data) + 64, .base = &data };
    try std.testing.expectEqual(refsum(&data) ^ 0xffff, ptclcsum(&b0, 0, 64));
    try std.testing.expectEqual(refsum(data[5..55]) ^ 0xffff, ptclcsum(&b0, 5, 50));
    try std.testing.expectEqual(refsum(data[13..33]) ^ 0xffff, ptclcsum(&b0, 13, 20));
    try std.testing.expectEqual(refsum(data[20..64]) ^ 0xffff, ptclcsum(&b0, 20, 44));
    try std.testing.expectEqual(@as(u16, 0), ptclcsum(null, 0, 10));
}

test "hnputs_csum" {
    // changing a 16 bit field at an even and at an odd distance from
    // the checksum keeps the checksum right
    for ([_]usize{ 4, 7 }) |pos| {
        var pkt: [16]u8 align(2) = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0, 0, 13, 14 };
        hnputs(pkt[12..14], refsum(&pkt) ^ 0xffff);
        try std.testing.expectEqual(@as(u16, 0xffff), refsum(&pkt));
        hnputs_csum(pkt[pos..][0..2], 0xbeef, pkt[12..14]);
        try std.testing.expectEqual(@as(u16, 0xbeef), nhgets(pkt[pos..]));
        try std.testing.expectEqual(@as(u16, 0xffff), refsum(&pkt));
    }
}

test "v4tov6, v6tov4, isv4" {
    var a: [IPaddrlen]u8 = @splat(0xaa);
    var b: [IPv4addrlen]u8 = undefined;

    v4tov6(&a, &.{ 10, 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 1, 2, 3 }, &a);
    try std.testing.expect(isv4(&a));
    try std.testing.expectEqual(@as(i32, 0), v6tov4(&b, &a));
    try std.testing.expectEqualSlices(u8, &.{ 10, 1, 2, 3 }, &b);
    // v4 may be the last four bytes of v6
    a[12..16].* = .{ 9, 8, 7, 6 };
    v4tov6(&a, a[12..16]);
    try expectfmt("9.8.7.6", "%I", .{ip(a)});

    try std.testing.expect(!isv4(&v6loopback));
    try std.testing.expect(!isv4(&IPnoaddr));
    try std.testing.expectEqual(@as(i32, 0), v6tov4(&b, &IPnoaddr));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &b);
    b = .{ 1, 1, 1, 1 };
    try std.testing.expectEqual(@as(i32, -1), v6tov4(&b, &v6loopback));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &b);

    try std.testing.expectEqual(@as(u8, V4), ipismulticast(&IPv4allsys));
    try std.testing.expectEqual(@as(u8, V6), ipismulticast(&v6allnodesL));
    try std.testing.expectEqual(@as(u8, 0), ipismulticast(&IPv4bcast));
    try std.testing.expectEqual(@as(u8, 0), ipismulticast(&v6linklocal));
}

test "defmask, maskip, equivip, ipv62smcast, parsemac" {
    try expectfmt("/104", "%M", .{mask(defmask(&parsed("10.1.2.3")))});
    try expectfmt("/104", "%M", .{mask(defmask(&parsed("127.0.0.1")))});
    try expectfmt("/112", "%M", .{mask(defmask(&parsed("172.16.1.1")))});
    try expectfmt("/120", "%M", .{mask(defmask(&parsed("192.168.1.1")))});
    try expectfmt("/120", "%M", .{mask(defmask(&parsed("224.0.0.1")))});
    try expectfmt("/128", "%M", .{mask(defmask(&v6loopback))});
    try expectfmt("/64", "%M", .{mask(defmask(&parsed("fe80::1")))});
    try expectfmt("/104", "%M", .{mask(defmask(&parsed("ff02::1:ff12:3456")))});
    try expectfmt("/8", "%M", .{mask(defmask(&v6allnodesL))});
    try expectfmt("/128", "%M", .{mask(defmask(&parsed("2001:db8::1")))});

    var net: [IPaddrlen]u8 = parsed("192.168.17.200");
    maskip(&net, defmask(&net), &net);
    try expectfmt("192.168.17.0", "%I", .{ip(net)});

    try std.testing.expect(equivip6(&v6loopback, &parsed("::1")));
    try std.testing.expect(!equivip6(&v6loopback, &IPnoaddr));
    try std.testing.expect(equivip4(&.{ 1, 2, 3, 4 }, parsed("1.2.3.4")[IPv4off..]));
    try std.testing.expect(!equivip4(&.{ 1, 2, 3, 4 }, &.{ 1, 2, 3, 5 }));
    try std.testing.expectEqual(@as(i32, 0), ipcmp(&v6loopback, &parsed("::1")));
    try std.testing.expectEqual(@as(i32, 1), ipcmp(&v6loopback, &IPnoaddr));

    var sm: [IPaddrlen]u8 = undefined;
    ipv62smcast(&sm, &parsed("fe80::1:2:ab34:5678"));
    try expectfmt("ff02::1:ff34:5678", "%I", .{ip(sm)});
    try std.testing.expect(ipdat.issmcast(&sm));
    try std.testing.expect(ipdat.islinklocal(&parsed("fe80::1")));
    try std.testing.expect(ipdat.isula(&parsed("fd00::1")));

    var mac: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), parsemac(&mac, "0050c20abcff\n"));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x50, 0xc2, 0x0a, 0xbc, 0xff, 0, 0 }, &mac);
    try std.testing.expectEqual(@as(usize, 6), parsemac(mac[0..6], "00:50:c2:0a:bc:ff"));
    try std.testing.expectEqual(@as(usize, 1), parsemac(&mac, "0a1"));
}
