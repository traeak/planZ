//! The Internet Control Message Protocol for IPv4: echo, the error
//! messages sent for packets that cannot be delivered, advice to the
//! protocols about the ones received, and the conversations ping uses.
//! from 9/ip/icmp.c
//!
//! DIFF:
//!   - Icmp stops before the C's data[1]; the data follows the header
//!     at ICMP_IPSIZE+ICMP_HDRSIZE.
//!   - icmpkick is a qio.Bypass: it is never handed a nil block.
//!   - icmpiput: the C's label Advise, shared by two cases of the
//!     switch, is the code after the switch; the cases that do not
//!     advise return from inside it.
//!   - icmpcreate fails with Enomem when a queue cannot be allocated;
//!     the C stores nil and faults later.
//!   - icmpsend: `arg` is a usize (the mtu of icmpcantfrag) and is
//!     truncated to the 16 bits of the header, as the C's hnputs does.
//!   - The counters wrap (+%=) as the C's unsigned ones do.
//!   - IP_ICMPPROTO is in ipdat.zig.

const std = @import("std");
const fmt = @import("fmt");
const proc = @import("../port/proc.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const ql = @import("../port/qlock.zig");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const devip = @import("devip.zig");
const ipifc = @import("ipifc.zig");
const ip = @import("ip.zig");
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
const IP_VER4 = ipdat.IP_VER4;
const IP_HLEN4 = ipdat.IP_HLEN4;
const IP4HDR = ipdat.IP4HDR;
const IP_ICMPPROTO = ipdat.IP_ICMPPROTO;
const MAXTTL = ipdat.MAXTTL;
const DFLTTOS = ipdat.DFLTTOS;
const Logicmp = ipdat.Logicmp;
const Logtrans = ipdat.Logtrans;

const ipmove = ipdat.ipmove;
const ipcmp = ipdat.ipcmp;
const hnputs = ipaux.hnputs;
const nhgets = ipaux.nhgets;
const hnputs_csum = ipaux.hnputs_csum;
const v4tov6 = ipaux.v4tov6;
const v6tov4 = ipaux.v6tov4;
const IPnoaddr = ipaux.IPnoaddr;
const BLEN = ab.BLEN;
const qlock = ql.qlock;
const qunlock = ql.qunlock;

const Icmp = extern struct {
    vihl: u8, // Version and header length
    tos: u8, // Type of service
    length: [2]u8, // packet length
    id: [2]u8, // Identification
    frag: [2]u8, // Fragment information
    ttl: u8, // Time to live
    proto: u8, // Protocol
    ipcksum: [2]u8, // Header checksum
    src: [4]u8, // Ip source
    dst: [4]u8, // Ip destination
    type: u8,
    code: u8,
    cksum: [2]u8,
    icmpid: [2]u8,
    seq: [2]u8,
    // DIFF: data[1] follows; see the head of the file.
};

// Packet Types
const EchoReply = 0;
const Unreachable = 3;
const SrcQuench = 4;
const Redirect = 5;
const EchoRequest = 8;
const TimeExceed = 11;
const InParmProblem = 12;
const Timestamp = 13;
const TimestampReply = 14;
const InfoRequest = 15;
const InfoReply = 16;
const AddrMaskRequest = 17;
const AddrMaskReply = 18;

const Maxtype = 18;

const icmpnames: [Maxtype + 1]?[]const u8 = blk: {
    var t: [Maxtype + 1]?[]const u8 = @splat(null);
    t[EchoReply] = "EchoReply";
    t[Unreachable] = "Unreachable";
    t[SrcQuench] = "SrcQuench";
    t[Redirect] = "Redirect";
    t[EchoRequest] = "EchoRequest";
    t[TimeExceed] = "TimeExceed";
    t[InParmProblem] = "InParmProblem";
    t[Timestamp] = "Timestamp";
    t[TimestampReply] = "TimestampReply";
    t[InfoRequest] = "InfoRequest";
    t[InfoReply] = "InfoReply";
    t[AddrMaskRequest] = "AddrMaskRequest";
    t[AddrMaskReply] = "AddrMaskReply  ";
    break :blk t;
};

const ICMP_IPSIZE = 20;
const ICMP_HDRSIZE = 8;

const MinAdvise = IP4HDR + 4; // minimum needed for us to advise another protocol

comptime {
    std.debug.assert(@sizeOf(Icmp) == ICMP_IPSIZE + ICMP_HDRSIZE and @alignOf(Icmp) == 1);
}

const InMsgs = 0;
const InErrors = 1;
const OutMsgs = 2;
const CsumErrs = 3;
const LenErrs = 4;
const HlenErrs = 5;

const Nstats = 6;

const statnames: [Nstats][]const u8 = .{
    "InMsgs",
    "InErrors",
    "OutMsgs",
    "CsumErrs",
    "LenErrs",
    "HlenErrs",
};

const Icmppriv = struct {
    stats: [Nstats]u32 = @splat(0),

    // message counts
    in: [Maxtype + 1]u32 = @splat(0),
    out: [Maxtype + 1]u32 = @splat(0),

    ht: Ipht = .{},
};

fn icmppriv(icmp: *Proto) *Icmppriv {
    return @ptrCast(@alignCast(icmp.priv.?));
}

fn icmpcreate(c: *Conv) Error!void {
    c.rq = qio.qopen(64 * 1024, qio.Qmsg, null, c) orelse return error.Enomem;
    c.wq = qio.qbypass(icmpkick, c) orelse return error.Enomem;
}

pub fn icmpconnect(c: *Conv, argv: []const []const u8) Error!void {
    try devip.Fsstdconnect(c, argv);
    devip.Fsconnected(c, null);
}

pub fn icmpstate(c: *Conv, state: []u8) usize {
    return fmt.snprint(state, "%s qin %d qout %d\n", .{
        "Datagram",
        if (c.rq) |q| qio.qlen(q) else 0,
        if (c.wq) |q| qio.qlen(q) else 0,
    }).len;
}

pub fn icmpannounce(c: *Conv, argv: []const []const u8) Error!void {
    try devip.Fsstdannounce(c, argv);
    devip.Fsconnected(c, null);
}

pub fn icmpclose(c: *Conv) void {
    qio.qclose(c.rq);
    qio.qclose(c.wq);
    ipmove(&c.iphash.laddr, &IPnoaddr);
    ipmove(&c.iphash.raddr, &IPnoaddr);
    c.iphash.lport = 0;
}

fn icmpkick(x: ?*anyopaque, bp: *Block) void {
    const c: *Conv = @ptrCast(@alignCast(x.?));

    if (BLEN(bp) < ICMP_IPSIZE + ICMP_HDRSIZE) {
        qio.freeblist(bp);
        return;
    }
    const p: *Icmp = @ptrCast(bp.rp);
    p.vihl = IP_VER4;
    const ipriv = icmppriv(c.p.?);
    if (p.type <= Maxtype)
        ipriv.out[p.type] +%= 1;

    _ = v6tov4(&p.dst, &c.iphash.raddr);
    _ = v6tov4(&p.src, &c.iphash.laddr);
    p.proto = IP_ICMPPROTO;
    hnputs(&p.icmpid, c.iphash.lport);
    @memset(&p.cksum, 0);
    hnputs(&p.cksum, ipaux.ptclcsum(bp, ICMP_IPSIZE, qio.blocklen(bp) - ICMP_IPSIZE));
    ipriv.stats[OutMsgs] +%= 1;
    _ = ip.ipoput4(c.p.?.f.?, bp, null, c.ttl, c.tos, null);
}

fn ip4reply(f: *Fs, ip4: *const [4]u8) bool {
    var addr: [IPaddrlen]u8 = undefined;

    if (ipdat.isv4mcast(ip4))
        return false;
    v4tov6(&addr, ip4);
    const i = ipifc.ipforme(f, &addr);
    return i == 0 or i == ipdat.Runi;
}

fn ip4me(f: *Fs, ip4: *const [4]u8) bool {
    var addr: [IPaddrlen]u8 = undefined;

    if (ipdat.isv4mcast(ip4))
        return false;
    v4tov6(&addr, ip4);
    return ipifc.ipforme(f, &addr) == ipdat.Runi;
}

/// Send a ICMP packet back of type/code/arg in response to packet bp
/// which was received on ifc. The route hint rh is valid for the
/// reverse route.
fn icmpsend(f: *Fs, ifc: *Ipifc, bp: *Block, typ: u8, code: u8, arg: usize, rh: ?*Routehint) void {
    var ia: [IPv4addrlen]u8 = undefined;

    const osz = BLEN(bp);
    if (osz < IP4HDR)
        return;

    const p: *Icmp = @ptrCast(bp.rp);
    if (!ip4reply(f, &p.dst) or !ip4reply(f, &p.src) or !ipifc.ipv4local(ifc, &ia, 0, &p.src))
        return;

    netlog(f, Logicmp, "icmpsend %s (%d) %d ia %V -> src %V dst %V\n", .{
        icmpnames[typ] orelse "", typ, code, ipaux.v4(&ia), ipaux.v4(&p.src), ipaux.v4(&p.dst),
    });

    const sz: usize = @min(ICMP_IPSIZE + ICMP_HDRSIZE + osz, ipdat.v4MINTU);
    const nbp = ab.allocb(sz);
    nbp.wp += sz;
    @memset(nbp.rp[0..sz], 0);
    var np: *Icmp = @ptrCast(nbp.rp);
    np.vihl = IP_VER4;
    np.src = ia;
    np.dst = p.src;
    const dlen = sz - ICMP_IPSIZE - ICMP_HDRSIZE;
    @memcpy((nbp.rp + ICMP_IPSIZE + ICMP_HDRSIZE)[0..dlen], bp.rp[0..dlen]);
    np.type = typ;
    np.code = code;
    np.proto = IP_ICMPPROTO;
    hnputs(&np.icmpid, 0);
    hnputs(&np.seq, @truncate(arg));
    @memset(&np.cksum, 0);
    hnputs(&np.cksum, ipaux.ptclcsum(nbp, ICMP_IPSIZE, qio.blocklen(nbp) - ICMP_IPSIZE));

    const icmp = f.t2p[IP_ICMPPROTO].?;
    icmppriv(icmp).out[typ] +%= 1;

    if (rh) |h| {
        if (h.r) |r| {
            if ((r.type & ipdat.Runi) != 0) {
                np = @ptrCast(nbp.rp);
                np.vihl = IP_VER4 | IP_HLEN4;
                np.tos = DFLTTOS;
                np.ttl = MAXTTL;

                icmp.rcv.?(icmp, ifc, nbp);
                return;
            }
        }
    }

    _ = ip.ipoput4(f, nbp, null, MAXTTL, DFLTTOS, rh);
}

pub fn icmpnohost(f: *Fs, ifc: *Ipifc, bp: *Block, rh: ?*Routehint) void {
    icmpsend(f, ifc, bp, Unreachable, 1, 0, rh);
}

pub fn icmpnoconv(f: *Fs, ifc: *Ipifc, bp: *Block) void {
    icmpsend(f, ifc, bp, Unreachable, 3, 0, null);
}

pub fn icmpcantfrag(f: *Fs, ifc: *Ipifc, bp: *Block, mtu: usize) void {
    icmpsend(f, ifc, bp, Unreachable, 4, mtu, null);
}

pub fn icmpttlexceeded(f: *Fs, ifc: *Ipifc, bp: *Block) void {
    icmpsend(f, ifc, bp, TimeExceed, 0, 0, null);
}

fn goticmpkt(icmp: *Proto, bp: *Block, ifc: *Ipifc) void {
    var dst: [IPaddrlen]u8 = undefined;
    var src: [IPaddrlen]u8 = undefined;

    const p: *Icmp = @ptrCast(bp.rp);
    v4tov6(&dst, &p.dst);
    v4tov6(&src, &p.src);
    const recid = nhgets(&p.icmpid);

    qlock(&icmp.qlock);
    raise: {
        if (ipaux.iphtlook(icmp.ht.?, &src, recid, &dst, recid)) |iph| {
            const hop: u32 = p.ttl;

            if (hop <= 1)
                break :raise;
            const q = ipaux.transbackward(icmp, iph) orelse break :raise;
            p.dst = q.forward.raddr[IPv4off..].*;
            hnputs_csum(&p.icmpid, q.forward.rport, &p.cksum);

            // only use route-hint when from original desination
            const rh: ?*Routehint = if (std.mem.eql(u8, &p.src, q.forward.laddr[IPv4off..]))
                &q.routehint
            else
                null;
            qunlock(&icmp.qlock);

            _ = ip.ipoput4(icmp.f.?, bp, ifc, hop - 1, p.tos, rh);
            return;
        }
        var i: usize = 0;
        while (icmp.conv[i]) |s| : (i += 1) {
            if (s.iphash.lport == recid and
                (ipcmp(&s.iphash.laddr, &dst) == 0 or ipcmp(&s.iphash.raddr, &src) == 0))
            {
                _ = qio.qpass(s.rq.?, qio.copyblock(bp, qio.blocklen(bp)));
            }
        }
    }
    qunlock(&icmp.qlock);
    qio.freeblist(bp);
}

fn mkechoreply(bp: *Block, f: *Fs) ?*Block {
    const q: *Icmp = @ptrCast(bp.rp);
    if (!ip4me(f, &q.dst) or !ip4reply(f, &q.src))
        return null;

    q.vihl = IP_VER4;
    const a = q.src;
    q.src = q.dst;
    q.dst = a;
    q.type = EchoReply;
    @memset(&q.cksum, 0);
    hnputs(&q.cksum, ipaux.ptclcsum(bp, ICMP_IPSIZE, qio.blocklen(bp) - ICMP_IPSIZE));

    return bp;
}

const unreachcode = [_][]const u8{
    "net unreachable",
    "host unreachable",
    "protocol unreachable",
    "port unreachable",
    "fragmentation needed and DF set",
    "source route failed",
    "destination network unknown",
    "destination host unknown",
    "source host isolated",
    "network administratively prohibited",
    "host administratively prohibited",
    "network unreachable for tos",
    "host unreachable for tos",
    "communication administratively prohibited",
    "host precedence violation",
    "precedence cutoff in effect",
};

fn icmpiput(icmp: *Proto, ifc: *Ipifc, bp_: *Block) void {
    var m2: [128]u8 = undefined;
    var msg: []const u8 = undefined;

    const f = icmp.f.?;
    const ipriv = icmppriv(icmp);
    ipriv.stats[InMsgs] +%= 1;

    const bp = qio.concatblock(bp_);
    const n = BLEN(bp);
    if (n < ICMP_IPSIZE + ICMP_HDRSIZE) {
        ipriv.stats[InErrors] +%= 1;
        ipriv.stats[HlenErrs] +%= 1;
        netlog(f, Logicmp, "icmp hlen %d\n", .{n});
        qio.freeblist(bp);
        return;
    }
    if (ipaux.ptclcsum(bp, ICMP_IPSIZE, n - ICMP_IPSIZE) != 0) {
        ipriv.stats[InErrors] +%= 1;
        ipriv.stats[CsumErrs] +%= 1;
        netlog(f, Logicmp, "icmp checksum error\n", .{});
        qio.freeblist(bp);
        return;
    }
    var p: *Icmp = @ptrCast(bp.rp);
    netlog(f, Logicmp, "icmpiput %s (%d) %d\n", .{
        (if (p.type < icmpnames.len) icmpnames[p.type] else null) orelse "",
        p.type,
        p.code,
    });
    if (p.type <= Maxtype)
        ipriv.in[p.type] +%= 1;

    switch (p.type) {
        EchoRequest => {
            const r = mkechoreply(bp, f) orelse {
                qio.freeblist(bp);
                return;
            };
            ipriv.out[EchoReply] +%= 1;
            _ = ip.ipoput4(f, r, null, MAXTTL, DFLTTOS, null);
            return;
        },
        TimeExceed => {
            if (p.code != 0) {
                goticmpkt(icmp, bp, ifc);
                return;
            }
            msg = fmt.snprint(m2[0 .. m2.len - 1], "ttl exceeded at %V", .{ipaux.v4(&p.src)});
        },
        Unreachable => {
            if (p.code >= unreachcode.len) {
                msg = fmt.snprint(m2[0 .. m2.len - 1], "unreachable %V -> %V code %d", .{
                    ipaux.v4(&p.src), ipaux.v4(&p.dst), p.code,
                });
            } else msg = unreachcode[p.code];
        },
        else => {
            goticmpkt(icmp, bp, ifc);
            return;
        },
    }

    // Advise:
    bp.rp += ICMP_IPSIZE + ICMP_HDRSIZE;
    if (BLEN(bp) < MinAdvise) {
        ipriv.stats[LenErrs] +%= 1;
        qio.freeblist(bp);
        return;
    }
    p = @ptrCast(bp.rp);
    if (p.vihl == (IP_VER4 | IP_HLEN4) and // advise() does not expect options
        (nhgets(&p.frag) & ipdat.IP_FO) == 0 and // first fragment
        ip.ipcsum(bp.rp) == 0)
    {
        if (devip.Fsrcvpcolx(f, p.proto)) |pr| {
            if (pr.advise) |advise| {
                netlog(f, Logicmp, "advising %s!%V -> %V: %s\n", .{ pr.name, ipaux.v4(&p.src), ipaux.v4(&p.dst), msg });
                advise(pr, bp, ifc, msg);
                return;
            }
        }
    }
    bp.rp -= ICMP_IPSIZE + ICMP_HDRSIZE;
    // wet floor
    goticmpkt(icmp, bp, ifc);
}

/// called from protocol advice handlers when the advice
/// is actually for someone we source translate (ip4).
/// the caller has fixed up the ip address and ports
/// in the inner header, so we just restore the outer
/// ip/icmp headers, recalculating icmp checksum
/// and send the advice to ip4.
pub fn icmpproxyadvice(f: *Fs, ifc: *Ipifc, bp: *Block, ip4: *const [IPv4addrlen]u8) void {
    drop: {
        // inner header
        var p: *Icmp = @ptrCast(bp.rp);
        if (p.vihl != (IP_VER4 | IP_HLEN4))
            break :drop;
        if (ip.ipcsum(bp.rp) != 0)
            break :drop;

        // outer header
        bp.rp -= ICMP_IPSIZE + ICMP_HDRSIZE;
        p = @ptrCast(bp.rp);
        if (p.vihl != (IP_VER4 | (ICMP_IPSIZE >> 2)))
            break :drop;

        const hop: u32 = p.ttl;
        if (hop <= 1)
            break :drop;

        netlog(f, Logicmp | Logtrans, "proxying icmp advice from %V to %V->%V\n", .{
            ipaux.v4(&p.src), ipaux.v4(&p.dst), ipaux.v4(ip4),
        });
        p.dst = ip4.*;

        // recalculate ICMP checksum
        @memset(&p.cksum, 0);
        hnputs(&p.cksum, ipaux.ptclcsum(bp, ICMP_IPSIZE, qio.blocklen(bp) - ICMP_IPSIZE));

        _ = ip.ipoput4(f, bp, ifc, hop - 1, p.tos, null);
        return;
    }
    qio.freeblist(bp);
}

fn icmpadvise(icmp: *Proto, bp: *Block, ifc: *Ipifc, msg: []const u8) void {
    var dst: [IPaddrlen]u8 = undefined;
    var src: [IPaddrlen]u8 = undefined;

    const p: *Icmp = @ptrCast(bp.rp);
    v4tov6(&dst, &p.dst);
    v4tov6(&src, &p.src);
    const recid = nhgets(&p.icmpid);

    qlock(&icmp.qlock);
    raise: {
        if (ipaux.iphtlook(icmp.ht.?, &dst, recid, &src, recid)) |iph| {
            const q = ipaux.transbackward(icmp, iph) orelse break :raise;

            hnputs_csum(p.src[0..2], nhgets(q.forward.raddr[IPv4off + 0 ..][0..2]), &p.ipcksum);
            hnputs_csum(p.src[2..4], nhgets(q.forward.raddr[IPv4off + 2 ..][0..2]), &p.ipcksum);

            hnputs_csum(&p.icmpid, q.forward.rport, &p.cksum);
            qunlock(&icmp.qlock);

            icmpproxyadvice(icmp.f.?, ifc, bp, &p.src);
            return;
        }
        var i: usize = 0;
        while (icmp.conv[i]) |s| : (i += 1) {
            if (s.iphash.lport == recid and
                ipcmp(&s.iphash.laddr, &src) == 0 and
                ipcmp(&s.iphash.raddr, &dst) == 0)
            {
                if (s.ignoreadvice)
                    break;
                qio.qhangup(s.rq.?, msg);
                qio.qhangup(s.wq.?, msg);
                break;
            }
        }
    }
    qunlock(&icmp.qlock);
    qio.freeblist(bp);
}

fn icmpforward(icmp: *Proto, bp: *Block, r: *Route) ?*Block {
    var da: [IPaddrlen]u8 = undefined;
    var sa: [IPaddrlen]u8 = undefined;

    if (BLEN(bp) < ICMP_IPSIZE + ICMP_HDRSIZE) {
        qio.freeblist(bp);
        return null;
    }

    const p: *Icmp = @ptrCast(bp.rp);
    switch (p.type) {
        EchoRequest, Timestamp, InfoRequest, AddrMaskRequest => {},
        else => {
            // no icmpid, can't translate back
            qio.freeblist(bp);
            return null;
        },
    }
    v4tov6(&sa, &p.src);
    v4tov6(&da, &p.dst);
    const id = nhgets(&p.icmpid);

    qlock(&icmp.qlock);
    const q = ipaux.transforward(icmp, &sa, id, &da, id, r) orelse {
        qunlock(&icmp.qlock);
        qio.freeblist(bp);
        return null;
    };
    p.src = q.backward.laddr[IPv4off..].*;
    hnputs_csum(&p.icmpid, q.backward.lport, &p.cksum);
    qunlock(&icmp.qlock);

    return bp;
}

fn icmpstats(icmp: *Proto, buf: []u8) usize {
    const priv = icmppriv(icmp);
    var n: usize = 0;
    for (0..Nstats) |i|
        n += fmt.snprint(buf[n..], "%s: %lud\n", .{ statnames[i], priv.stats[i] }).len;
    for (0..Maxtype + 1) |i| {
        if (icmpnames[i]) |name|
            n += fmt.snprint(buf[n..], "%s: %lud %lud\n", .{ name, priv.in[i], priv.out[i] }).len
        else
            n += fmt.snprint(buf[n..], "%d: %lud %lud\n", .{ i, priv.in[i], priv.out[i] }).len;
    }
    return n;
}

pub fn icmpinit(fs: *Fs) void {
    const icmp = alloc.snew(Proto);
    icmp.* = .{};
    const priv = alloc.snew(Icmppriv);
    priv.* = .{};
    icmp.priv = priv;
    icmp.ht = &priv.ht;
    icmp.name = "icmp";
    icmp.connect = icmpconnect;
    icmp.announce = icmpannounce;
    icmp.state = icmpstate;
    icmp.create = icmpcreate;
    icmp.close = icmpclose;
    icmp.rcv = icmpiput;
    icmp.stats = icmpstats;
    icmp.ctl = null;
    icmp.advise = icmpadvise;
    icmp.forward = icmpforward;
    icmp.gc = null;
    icmp.ipproto = IP_ICMPPROTO;
    icmp.nc = 128;
    icmp.ptclsize = 0;

    _ = devip.Fsproto(fs, icmp);
}
