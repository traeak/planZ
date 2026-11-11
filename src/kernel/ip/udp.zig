//! The User Datagram Protocol, for IPv4 and IPv6.
//! from 9/ip/udp.c
//!
//! DIFF:
//!   - udpkick is a qio.Bypass: it is never handed a nil block, so the
//!     C's test for one is gone.  Nothing it calls can raise.
//!   - The three labels of udpiput (Badhdr, Badcrc, Noconv) are the
//!     functions badhdr, badcrc and noconv.
//!   - udpcreate fails with Enomem when a queue cannot be allocated;
//!     the C stores nil and faults later.
//!   - Lengths taken from the user or the wire are stored in headers
//!     with @truncate where the C's hnputs truncates silently (a
//!     datagram longer than 64K gets a wrong length, as in C, instead
//!     of a panic).
//!   - udpiput: srcip starts as IPnoaddr; the C leaves it unset when
//!     ipv6local finds no address.
//!   - The counters wrap (+%=) as the C's unsigned ones do.
//!   - DPRINT (if(0)print) and the unused constants Udprxms,
//!     Udptickms and Udpmaxxmit are left out.  IP_UDPPROTO is in
//!     ipdat.zig.

const std = @import("std");
const fmt = @import("fmt");
const proc = @import("../port/proc.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const ql = @import("../port/qlock.zig");
const p9 = @import("../port/print.zig");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const devip = @import("devip.zig");
const ipifc = @import("ipifc.zig");
const iproute = @import("iproute.zig");
const ip = @import("ip.zig");
const ipv6 = @import("ipv6.zig");
const icmp = @import("icmp.zig");
const icmp6 = @import("icmp6.zig");
const netlog = @import("netlog.zig").netlog;

const Error = ipdat.Error;
const Block = ipdat.Block;
const Conv = ipdat.Conv;
const Proto = ipdat.Proto;
const Fs = ipdat.Fs;
const Ipifc = ipdat.Ipifc;
const Ipht = ipdat.Ipht;
const Route = ipdat.Route;
const Routehint = ipdat.Routehint;

const IPaddrlen = ipdat.IPaddrlen;
const IPv4addrlen = ipdat.IPv4addrlen;
const IPv4off = ipdat.IPv4off;
const V4 = ipdat.V4;
const V6 = ipdat.V6;
const IP_VER4 = ipdat.IP_VER4;
const IP_VER6 = ipdat.IP_VER6;
const IP_UDPPROTO = ipdat.IP_UDPPROTO;
const Logudp = ipdat.Logudp;
const Logudpmsg = ipdat.Logudpmsg;

const ipmove = ipdat.ipmove;
const ipcmp = ipdat.ipcmp;
const hnputs = ipaux.hnputs;
const hnputl = ipaux.hnputl;
const nhgets = ipaux.nhgets;
const nhgetl = ipaux.nhgetl;
const hnputs_csum = ipaux.hnputs_csum;
const v4tov6 = ipaux.v4tov6;
const v6tov4 = ipaux.v6tov4;
const IPnoaddr = ipaux.IPnoaddr;
const BLEN = ab.BLEN;
const qlock = ql.qlock;
const qunlock = ql.qunlock;

const UDP_UDPHDR_SZ = 8;

const UDP4_PHDR_OFF = 8;
const UDP4_PHDR_SZ = 12;
const UDP4_IPHDR_SZ = 20;
const UDP6_IPHDR_SZ = 40;
const UDP6_PHDR_SZ = 40;
const UDP6_PHDR_OFF = 0;

const UDP_USEAD7 = 52;

const Udp4hdr = extern struct {
    // ip header
    vihl: u8, // Version and header length
    tos: u8, // Type of service
    length: [2]u8, // packet length
    id: [2]u8, // Identification
    frag: [2]u8, // Fragment information
    ttl: u8, // Time to live
    udpproto: u8, // Protocol
    udpplen: [2]u8, // Header plus data length
    udpsrc: [IPv4addrlen]u8, // Ip source
    udpdst: [IPv4addrlen]u8, // Ip destination

    // udp header
    udpsport: [2]u8, // Source port
    udpdport: [2]u8, // Destination port
    udplen: [2]u8, // data length
    udpcksum: [2]u8, // Checksum
};

const Udp6hdr = extern struct {
    viclfl: [4]u8,
    len: [2]u8,
    nextheader: u8,
    hoplimit: u8,
    udpsrc: [IPaddrlen]u8,
    udpdst: [IPaddrlen]u8,

    // udp header
    udpsport: [2]u8, // Source port
    udpdport: [2]u8, // Destination port
    udplen: [2]u8, // data length
    udpcksum: [2]u8, // Checksum
};

comptime {
    std.debug.assert(@sizeOf(Udp4hdr) == UDP4_IPHDR_SZ + UDP_UDPHDR_SZ and @alignOf(Udp4hdr) == 1);
    std.debug.assert(@sizeOf(Udp6hdr) == UDP6_IPHDR_SZ + UDP_UDPHDR_SZ and @alignOf(Udp6hdr) == 1);
}

/// MIB II counters
const Udpstats = struct {
    udpInDatagrams: u64 = 0,
    udpNoPorts: u32 = 0,
    udpInErrors: u32 = 0,
    udpOutDatagrams: u64 = 0,
};

const Udppriv = struct {
    ht: Ipht = .{},

    // MIB counters
    ustats: Udpstats = .{},

    // non-MIB stats
    csumerr: u32 = 0, // checksum errors
    lenerr: u32 = 0, // short packet
};

/// protocol specific part of Conv
const Udpcb = extern struct {
    headers: u8,

    /// source ip used for transmission
    srcip: [IPaddrlen]u8,
};

fn udppriv(udp: *Proto) *Udppriv {
    return @ptrCast(@alignCast(udp.priv.?));
}

fn udpcb(c: *Conv) *Udpcb {
    return @ptrCast(@alignCast(c.ptcl.?));
}

fn udpconnect(c: *Conv, argv: []const []const u8) Error!void {
    const upriv = udppriv(c.p.?);
    devip.Fsstdconnect(c, argv) catch |e| {
        devip.Fsconnected(c, proc.errtext(e));
        return e;
    };
    devip.Fsconnected(c, null);
    ipmove(&udpcb(c).srcip, &c.iphash.laddr);
    ipaux.iphtadd(&upriv.ht, &c.iphash);
}

fn udpstate(c: *Conv, state: []u8) usize {
    return fmt.snprint(state, "%s qin %d qout %d\n", .{
        @as([]const u8, if (c.inuse != 0) "Open" else "Closed"),
        if (c.rq) |q| qio.qlen(q) else 0,
        if (c.wq) |q| qio.qlen(q) else 0,
    }).len;
}

fn udpannounce(c: *Conv, argv: []const []const u8) Error!void {
    const upriv = udppriv(c.p.?);
    try devip.Fsstdannounce(c, argv);
    devip.Fsconnected(c, null);
    ipmove(&udpcb(c).srcip, &c.iphash.laddr);
    ipaux.iphtadd(&upriv.ht, &c.iphash);
}

fn udpcreate(c: *Conv) Error!void {
    c.rq = qio.qopen(512 * 1024, qio.Qmsg, null, null) orelse return error.Enomem;
    c.wq = qio.qbypass(udpkick, c) orelse return error.Enomem;
}

fn udpclose(c: *Conv) void {
    const upriv = udppriv(c.p.?);
    ipaux.iphtrem(&upriv.ht, &c.iphash);

    c.state = 0;
    qio.qclose(c.rq);
    qio.qclose(c.wq);
    qio.qclose(c.eq);
    c.iphash.lport = 0;
    ipmove(&c.iphash.laddr, &IPnoaddr);
    c.iphash.rport = 0;
    ipmove(&c.iphash.raddr, &IPnoaddr);

    const ucb = udpcb(c);
    ucb.headers = 0;
    ipmove(&ucb.srcip, &IPnoaddr);
}

fn udpkick(x: ?*anyopaque, bp_: *Block) void {
    const c: *Conv = @ptrCast(@alignCast(x.?));
    var bp = bp_;
    var rport: u16 = undefined;
    var laddr: [IPaddrlen]u8 = undefined;
    var raddr: [IPaddrlen]u8 = undefined;
    var version: u8 = undefined;
    var rh: ?*Routehint = undefined;

    const upriv = udppriv(c.p.?);
    const f = c.p.?.f.?;

    // netlog(c.p.f, Logudp, "udp: kick\n", .{}); // frequent and uninteresting

    const ucb = udpcb(c);
    switch (ucb.headers) {
        7 => {
            // get user specified addresses
            bp = qio.pullupblock(bp, UDP_USEAD7) orelse return;
            ipmove(&raddr, bp.rp[0..IPaddrlen]);
            bp.rp += IPaddrlen;
            ipmove(&laddr, bp.rp[0..IPaddrlen]);
            bp.rp += IPaddrlen;
            const ifcaddr: *const [IPaddrlen]u8 = bp.rp[0..IPaddrlen];
            const t = ipifc.ipforme(f, &laddr);
            if (t == ipdat.Runi) {
                // use it
            } else if ((t == ipdat.Rmulti or t == ipdat.Rbcast) and
                ipcmp(ifcaddr, &IPnoaddr) != 0 and
                ipifc.ipforme(f, ifcaddr) == ipdat.Runi and
                iproute.v6lookup(f, &raddr, ifcaddr, null) != null)
            {
                // use ifc address for bcast/mcast reply
                ipmove(&laddr, ifcaddr);
            } else {
                // pick interface closest to dest
                ipifc.findlocalip(f, &laddr, &raddr);
            }
            bp.rp += IPaddrlen; // Ignore ifc address
            rport = nhgets(bp.rp[0..2]);
            bp.rp += 2 + 2; // Ignore local port
        },
        else => {
            ipmove(&laddr, &IPnoaddr);
            rport = 0;
        },
    }

    if (ucb.headers != 0) {
        if (ipaux.isv4(&laddr) or ipcmp(&laddr, &IPnoaddr) == 0)
            version = V4
        else
            version = V6;
    } else {
        version = ipaux.convipvers(c);
        ipmove(&laddr, &ucb.srcip);
    }

    const dlen = qio.blocklen(bp);

    // fill in pseudo header and compute checksum
    switch (version) {
        V4 => {
            bp = qio.padblock(bp, UDP4_IPHDR_SZ + UDP_UDPHDR_SZ);
            const uh4: *Udp4hdr = @ptrCast(bp.rp);
            const ptcllen = dlen + UDP_UDPHDR_SZ;
            uh4.ttl = 0;
            uh4.udpproto = IP_UDPPROTO;
            uh4.frag[0] = 0;
            uh4.frag[1] = 0;
            hnputs(&uh4.udpplen, @truncate(ptcllen));
            if (ucb.headers != 0) {
                _ = v6tov4(&uh4.udpdst, &raddr);
                hnputs(&uh4.udpdport, rport);
                rh = null;
            } else {
                _ = v6tov4(&uh4.udpdst, &c.iphash.raddr);
                hnputs(&uh4.udpdport, c.iphash.rport);
                rh = &c.routehint;
            }
            _ = v6tov4(&uh4.udpsrc, &laddr);
            hnputs(&uh4.udpsport, c.iphash.lport);
            hnputs(&uh4.udplen, @truncate(ptcllen));
            uh4.udpcksum[0] = 0;
            uh4.udpcksum[1] = 0;
            var csum = ipaux.ptclcsum(bp, UDP4_PHDR_OFF, dlen + UDP_UDPHDR_SZ + UDP4_PHDR_SZ);
            if (csum == 0)
                csum = 0xffff; // -0
            hnputs(&uh4.udpcksum, csum);
            uh4.vihl = IP_VER4;
            _ = ip.ipoput4(f, bp, null, c.ttl, c.tos, rh);
        },
        V6 => {
            // using the v6 ip header to create pseudo header
            // first then reset it to the normal ip header
            bp = qio.padblock(bp, UDP6_IPHDR_SZ + UDP_UDPHDR_SZ);
            const uh6: *Udp6hdr = @ptrCast(bp.rp);
            @memset(bp.rp[0..8], 0);
            const ptcllen = dlen + UDP_UDPHDR_SZ;
            hnputl(&uh6.viclfl, @truncate(ptcllen));
            uh6.hoplimit = IP_UDPPROTO;
            if (ucb.headers != 0) {
                ipmove(&uh6.udpdst, &raddr);
                hnputs(&uh6.udpdport, rport);
                rh = null;
            } else {
                ipmove(&uh6.udpdst, &c.iphash.raddr);
                hnputs(&uh6.udpdport, c.iphash.rport);
                rh = &c.routehint;
            }
            ipmove(&uh6.udpsrc, &laddr);
            hnputs(&uh6.udpsport, c.iphash.lport);
            hnputs(&uh6.udplen, @truncate(ptcllen));
            uh6.udpcksum[0] = 0;
            uh6.udpcksum[1] = 0;
            var csum = ipaux.ptclcsum(bp, UDP6_PHDR_OFF, dlen + UDP_UDPHDR_SZ + UDP6_PHDR_SZ);
            if (csum == 0)
                csum = 0xffff; // -0
            hnputs(&uh6.udpcksum, csum);
            @memset(bp.rp[0..8], 0);
            uh6.viclfl[0] = IP_VER6;
            hnputs(&uh6.len, @truncate(ptcllen));
            uh6.nextheader = IP_UDPPROTO;
            _ = ipv6.ipoput6(f, bp, null, c.ttl, c.tos, rh);
        },
        else => p9.panic("udpkick: version %d", .{version}),
    }
    upriv.ustats.udpOutDatagrams +%= 1;
}

/// The C's label Badhdr in udpiput.
fn badhdr(upriv: *Udppriv, f: *Fs, bp: *Block) void {
    upriv.lenerr +%= 1;
    upriv.ustats.udpInErrors +%= 1;
    netlog(f, Logudp, "udp: bad header\n", .{});
    qio.freeblist(bp);
}

/// The C's label Badcrc in udpiput.
fn badcrc(upriv: *Udppriv, f: *Fs, bp: *Block, raddr: *const [IPaddrlen]u8) void {
    upriv.csumerr +%= 1;
    upriv.ustats.udpInErrors +%= 1;
    netlog(f, Logudp, "udp: checksum error %I\n", .{ipaux.ip(raddr)});
    qio.freeblist(bp);
}

/// The C's label Noconv in udpiput: no conversation found.
/// Called with udp locked; unlocks it.
fn noconv(
    udp: *Proto,
    ifc: *Ipifc,
    bp: *Block,
    version: u8,
    raddr: *const [IPaddrlen]u8,
    rport: u16,
    laddr: *const [IPaddrlen]u8,
    lport: u16,
) void {
    const upriv = udppriv(udp);
    const f = udp.f.?;

    upriv.ustats.udpNoPorts +%= 1;
    qunlock(&udp.qlock);
    netlog(f, Logudp, "udp: no conv %I!%d -> %I!%d\n", .{ ipaux.ip(raddr), rport, ipaux.ip(laddr), lport });

    switch (version) {
        V4 => icmp.icmpnoconv(f, ifc, bp),
        V6 => icmp6.icmpnoconv6(f, ifc, bp),
        else => p9.panic("udpiput2: version %d", .{version}),
    }

    qio.freeblist(bp);
}

fn udpiput(udp: *Proto, ifc: *Ipifc, bp_: *Block) void {
    var bp = bp_;
    var raddr: [IPaddrlen]u8 = undefined;
    var laddr: [IPaddrlen]u8 = undefined;
    var rport: u16 = undefined;
    var lport: u16 = undefined;
    var len: i32 = undefined;

    const upriv = udppriv(udp);
    const f = udp.f.?;
    upriv.ustats.udpInDatagrams +%= 1;

    const uh4: *Udp4hdr = @ptrCast(bp.rp);
    const uh6: *Udp6hdr = @ptrCast(bp.rp);
    const version: u8 = if ((uh4.vihl & 0xF0) == IP_VER6) V6 else V4;

    // Put back pseudo header for checksum
    // (remember old values for icmpnoconv())
    switch (version) {
        V4 => {
            if (BLEN(bp) < UDP4_IPHDR_SZ + UDP_UDPHDR_SZ)
                return badhdr(upriv, f, bp);
            const ottl = uh4.ttl;
            uh4.ttl = 0;
            len = nhgets(&uh4.udplen);
            const olen = nhgets(&uh4.udpplen);
            hnputs(&uh4.udpplen, @intCast(len));

            v4tov6(&raddr, &uh4.udpsrc);
            v4tov6(&laddr, &uh4.udpdst);
            lport = nhgets(&uh4.udpdport);
            rport = nhgets(&uh4.udpsport);

            if (nhgets(&uh4.udpcksum) != 0) {
                if (ipaux.ptclcsum(bp, UDP4_PHDR_OFF, @as(usize, @intCast(len)) + UDP4_PHDR_SZ) != 0)
                    return badcrc(upriv, f, bp, &raddr);
            }
            uh4.ttl = ottl;
            hnputs(&uh4.udpplen, olen);
        },
        V6 => {
            if (BLEN(bp) < UDP6_IPHDR_SZ + UDP_UDPHDR_SZ)
                return badhdr(upriv, f, bp);
            len = nhgets(&uh6.udplen);
            const oviclfl = nhgetl(&uh6.viclfl);
            const olen = nhgets(&uh6.len);
            const ottl = uh6.hoplimit;
            ipmove(&raddr, &uh6.udpsrc);
            ipmove(&laddr, &uh6.udpdst);
            lport = nhgets(&uh6.udpdport);
            rport = nhgets(&uh6.udpsport);
            @memset(bp.rp[0..8], 0);
            hnputl(&uh6.viclfl, @intCast(len));
            uh6.hoplimit = IP_UDPPROTO;
            if (ipaux.ptclcsum(bp, UDP6_PHDR_OFF, @as(usize, @intCast(len)) + UDP6_PHDR_SZ) != 0)
                return badcrc(upriv, f, bp, &raddr);
            hnputl(&uh6.viclfl, oviclfl);
            hnputs(&uh6.len, olen);
            uh6.nextheader = IP_UDPPROTO;
            uh6.hoplimit = ottl;
        },
        else => p9.panic("udpiput: version %d", .{version}),
    }

    qlock(&udp.qlock);
    const iph = ipaux.iphtlook(udp.ht.?, &raddr, rport, &laddr, lport) orelse
        return noconv(udp, ifc, bp, version, &raddr, rport, &laddr, lport);
    if (iph.trans != 0) {
        const hop: u32 = uh4.ttl;
        const q = (if (hop <= 1) null else ipaux.transbackward(udp, iph)) orelse {
            qunlock(&udp.qlock);
            qio.freeblist(bp);
            return;
        };
        hnputs_csum(uh4.udpdst[0..2], nhgets(q.forward.raddr[IPv4off + 0 ..][0..2]), &uh4.udpcksum);
        hnputs_csum(uh4.udpdst[2..4], nhgets(q.forward.raddr[IPv4off + 2 ..][0..2]), &uh4.udpcksum);
        hnputs_csum(&uh4.udpdport, q.forward.rport, &uh4.udpcksum);

        // only use route-hint when from original desination
        const rh: ?*Routehint = if (std.mem.eql(u8, &uh4.udpsrc, q.forward.laddr[IPv4off..]))
            &q.routehint
        else
            null;
        qunlock(&udp.qlock);
        _ = ip.ipoput4(f, bp, ifc, hop - 1, uh4.tos, rh);
        return;
    }
    var c = ipdat.iphconv(iph);
    var ucb = udpcb(c);

    if (c.state == ipdat.Announced) {
        if (ucb.headers == 0) {
            var srcip: [IPaddrlen]u8 = IPnoaddr;

            switch (ipifc.ipforme(f, &laddr)) {
                ipdat.Runi => ipmove(&srcip, &laddr),
                ipdat.Rmulti, ipdat.Rbcast => {
                    // use the multicast address for reception,
                    // and local unicast ip for transmission.
                    _ = ipifc.ipv6local(ifc, &srcip, 0, &raddr);
                },
                else => return noconv(udp, ifc, bp, version, &raddr, rport, &laddr, lport),
            }
            c = devip.Fsnewcall(c, &raddr, rport, &laddr, lport, version) orelse {
                qunlock(&udp.qlock);
                qio.freeblist(bp);
                return;
            };
            ucb = udpcb(c);
            ipmove(&ucb.srcip, &srcip);
            ipaux.iphtadd(&upriv.ht, &c.iphash);
        }
    }

    qlock(&c.qlock);
    qunlock(&udp.qlock);

    // Trim the packet down to data size
    len -= UDP_UDPHDR_SZ;
    const tbp = switch (version) {
        V4 => qio.trimblock(bp, UDP4_IPHDR_SZ + UDP_UDPHDR_SZ, len),
        V6 => qio.trimblock(bp, UDP6_IPHDR_SZ + UDP_UDPHDR_SZ, len),
        else => p9.panic("udpiput4: version %d", .{version}),
    };
    bp = tbp orelse {
        qunlock(&c.qlock);
        netlog(f, Logudp, "udp: len err %I.%d -> %I.%d\n", .{ ipaux.ip(&raddr), rport, ipaux.ip(&laddr), lport });
        upriv.lenerr +%= 1;
        return;
    };

    netlog(f, Logudpmsg, "udp: %I.%d -> %I.%d l %d\n", .{ ipaux.ip(&raddr), rport, ipaux.ip(&laddr), lport, len });

    switch (ucb.headers) {
        7 => {
            // pass the src address
            bp = qio.padblock(bp, UDP_USEAD7);
            var p = bp.rp;
            ipmove(p[0..IPaddrlen], &raddr);
            p += IPaddrlen;
            ipmove(p[0..IPaddrlen], &laddr);
            p += IPaddrlen;
            if (!ipifc.ipv6local(ifc, p[0..IPaddrlen], 0, &raddr))
                ipmove(p[0..IPaddrlen], if (ifc.lifc) |lifc| &lifc.local else &IPnoaddr);
            p += IPaddrlen;
            hnputs(p[0..2], rport);
            p += 2;
            hnputs(p[0..2], lport);
        },
        else => {},
    }

    if (qio.qfull(c.rq.?)) {
        netlog(f, Logudp, "udp: qfull %I.%d -> %I.%d\n", .{ ipaux.ip(&raddr), rport, ipaux.ip(&laddr), lport });
        qio.freeblist(bp);
    } else {
        _ = qio.qpass(c.rq.?, qio.concatblock(bp));
    }
    qunlock(&c.qlock);
}

fn udpctl(c: *Conv, f: []const []const u8) Error!void {
    const ucb = udpcb(c);
    if (f.len == 1) {
        if (std.mem.eql(u8, f[0], "hangup")) {
            qio.qhangup(c.rq.?, null);
            qio.qhangup(c.wq.?, null);
            return;
        }
        if (std.mem.eql(u8, f[0], "headers")) {
            ucb.headers = 7; // new headers format
            return;
        }
    }
    return proc.errorf("unknown control request", .{});
}

fn udpadvise(udp: *Proto, bp: *Block, ifc: *Ipifc, msg: []const u8) void {
    var source: [IPaddrlen]u8 = undefined;
    var dest: [IPaddrlen]u8 = undefined;
    var psource: u16 = undefined;
    var pdest: u16 = undefined;

    const h4: *Udp4hdr = @ptrCast(bp.rp);
    const h6: *Udp6hdr = @ptrCast(bp.rp);

    if ((h4.vihl & 0xF0) == IP_VER4) {
        v4tov6(&dest, &h4.udpdst);
        v4tov6(&source, &h4.udpsrc);
        psource = nhgets(&h4.udpsport);
        pdest = nhgets(&h4.udpdport);
    } else {
        ipmove(&dest, &h6.udpdst);
        ipmove(&source, &h6.udpsrc);
        psource = nhgets(&h6.udpsport);
        pdest = nhgets(&h6.udpdport);
    }

    // Look for a connection (source/dest reversed; this is the original packet we sent)
    qlock(&udp.qlock);
    raise: {
        const iph = ipaux.iphtlook(udp.ht.?, &dest, pdest, &source, psource) orelse break :raise;
        if (iph.match != ipdat.IPmatchexact)
            break :raise;
        if (iph.trans != 0) {
            const q = ipaux.transbackward(udp, iph) orelse break :raise;

            // h4.udpplen is the ip header checksum
            hnputs_csum(h4.udpsrc[0..2], nhgets(q.forward.raddr[IPv4off + 0 ..][0..2]), &h4.udpplen);
            hnputs_csum(h4.udpsrc[2..4], nhgets(q.forward.raddr[IPv4off + 2 ..][0..2]), &h4.udpplen);

            // dont bother fixing udp checksum, packet is most likely truncated
            hnputs(&h4.udpsport, q.forward.rport);
            qunlock(&udp.qlock);

            icmp.icmpproxyadvice(udp.f.?, ifc, bp, &h4.udpsrc);
            return;
        }
        const s = ipdat.iphconv(iph);
        if (s.ignoreadvice or s.state == ipdat.Announced)
            break :raise;
        qlock(&s.qlock);
        qunlock(&udp.qlock);
        qio.qhangup(s.rq.?, msg);
        qio.qhangup(s.wq.?, msg);
        qunlock(&s.qlock);
        qio.freeblist(bp);
        return;
    }
    qunlock(&udp.qlock);
    qio.freeblist(bp);
}

fn udpforward(udp: *Proto, bp: *Block, r: *Route) ?*Block {
    var da: [IPaddrlen]u8 = undefined;
    var sa: [IPaddrlen]u8 = undefined;

    if (BLEN(bp) < UDP4_IPHDR_SZ + UDP_UDPHDR_SZ) {
        qio.freeblist(bp);
        return null;
    }

    const uh4: *Udp4hdr = @ptrCast(bp.rp);
    v4tov6(&sa, &uh4.udpsrc);
    v4tov6(&da, &uh4.udpdst);
    const dp = nhgets(&uh4.udpdport);
    const sp = nhgets(&uh4.udpsport);

    qlock(&udp.qlock);
    const q = ipaux.transforward(udp, &sa, sp, &da, dp, r) orelse {
        qunlock(&udp.qlock);
        qio.freeblist(bp);
        return null;
    };
    hnputs_csum(uh4.udpsrc[0..2], nhgets(q.backward.laddr[IPv4off + 0 ..][0..2]), &uh4.udpcksum);
    hnputs_csum(uh4.udpsrc[2..4], nhgets(q.backward.laddr[IPv4off + 2 ..][0..2]), &uh4.udpcksum);
    hnputs_csum(&uh4.udpsport, q.backward.lport, &uh4.udpcksum);
    qunlock(&udp.qlock);

    return bp;
}

fn udpstats(udp: *Proto, buf: []u8) usize {
    const upriv = udppriv(udp);
    return fmt.snprint(buf, "InDatagrams: %llud\nNoPorts: %lud\n" ++
        "InErrors: %lud\nOutDatagrams: %llud\n", .{
        upriv.ustats.udpInDatagrams,
        upriv.ustats.udpNoPorts,
        upriv.ustats.udpInErrors,
        upriv.ustats.udpOutDatagrams,
    }).len;
}

pub fn udpinit(fs: *Fs) void {
    const udp = alloc.snew(Proto);
    udp.* = .{};
    const upriv = alloc.snew(Udppriv);
    upriv.* = .{};
    udp.priv = upriv;
    udp.ht = &upriv.ht;
    udp.name = "udp";
    udp.connect = udpconnect;
    udp.announce = udpannounce;
    udp.ctl = udpctl;
    udp.state = udpstate;
    udp.create = udpcreate;
    udp.close = udpclose;
    udp.rcv = udpiput;
    udp.advise = udpadvise;
    udp.forward = udpforward;
    udp.stats = udpstats;
    udp.ipproto = IP_UDPPROTO;
    udp.nc = ipdat.Nchans;
    udp.ptclsize = @sizeOf(Udpcb);

    _ = devip.Fsproto(fs, udp);
}
