//! Internet Control Message Protocol for IPv6: echo, the error
//! messages, neighbour discovery (solicitations and advertisements
//! sent and answered here; router messages are passed to the
//! conversations that ask for them), and the conversations ping uses.
//! from 9/ip/icmp6.c
//!
//! DIFF:
//!   - The packet structures stop before the C's flexible members;
//!     IPICMPSZ, NDISCSZ and NDPKTSZ are where those start.
//!   - icmpkick6 is a qio.Bypass: it is never handed a nil block.
//!   - icmpiput6: the C's label Advise, shared by three cases of the
//!     switch, is the code after the switch; the cases that do not
//!     advise return from inside it.
//!   - icmpiput6 takes the link-layer address of a neighbour packet
//!     through lnaddr(), which gives only bytes that are in the
//!     packet.  The C passes np->lnaddr with the length 8*olen-2
//!     whatever the packet holds: with no option at all it reads olen
//!     past the end of the packet, and with olen 0 the length is -2.
//!     arpenter refuses a mac shorter than the medium's in each of
//!     these cases, so the result is the same except that bytes after
//!     the packet are never taken for an address.
//!   - valid() is given no ifc (the C's is unused) and returns a bool.
//!   - icmpcreate6 fails with Enomem when a queue cannot be allocated;
//!     the C stores nil and faults later.
//!   - icmpsend6: `arg` is a usize (the mtu of icmppkttoobig6) and is
//!     truncated to the 16 bits of the header, as the C's hnputs does.
//!   - The counters wrap (+%=) as the C's unsigned ones do.
//!   - Kept as in C, though they look like mistakes: an echo reply is
//!     counted in out[EchoReply] and not out[EchoReplyV6]; valid()
//!     tests Sflag against the 16 bit icmpid, where the flags are the
//!     high byte; a packet that fails the checksum is dropped with its
//!     header still overwritten by the pseudo header.

const std = @import("std");
const fmt = @import("fmt");
const proc = @import("../port/proc.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const devip = @import("devip.zig");
const ipifc = @import("ipifc.zig");
const ipv6 = @import("ipv6.zig");
const arp = @import("arp.zig");
const icmp4 = @import("icmp.zig");
const netlog = @import("netlog.zig").netlog;

const Error = ipdat.Error;
const Block = ipdat.Block;
const Conv = ipdat.Conv;
const Proto = ipdat.Proto;
const Fs = ipdat.Fs;
const Ipifc = ipdat.Ipifc;
const Routehint = ipdat.Routehint;
const Ip6hdr = ipdat.Ip6hdr;
const Fraghdr6 = ipdat.Fraghdr6;

const IPaddrlen = ipdat.IPaddrlen;
const V6 = ipdat.V6;
const IP_VER6 = ipdat.IP_VER6;
const IP6HDR = ipdat.IP6HDR;
const IP6FHDR = ipdat.IP6FHDR;
const ICMPv6 = ipdat.ICMPv6;
const FH = ipdat.FH;
const MAXTTL = ipdat.MAXTTL;
const DFLTTOS = ipdat.DFLTTOS;
const Logicmp = ipdat.Logicmp;
const SRC_UNSPEC = ipdat.SRC_UNSPEC;
const TARG_UNI = ipdat.TARG_UNI;
const SRC_LLADDR = ipdat.SRC_LLADDR;
const TARGET_LLADDR = ipdat.TARGET_LLADDR;

const ipmove = ipdat.ipmove;
const ipcmp = ipdat.ipcmp;
const isv6mcast = ipdat.isv6mcast;
const islinklocal = ipdat.islinklocal;
const issmcast = ipdat.issmcast;
const hnputs = ipaux.hnputs;
const hnputl = ipaux.hnputl;
const nhgets = ipaux.nhgets;
const nhgetl = ipaux.nhgetl;
const v6Unspecified = ipaux.v6Unspecified;
const BLEN = ab.BLEN;

const InMsgs6 = 0;
const InErrors6 = 1;
const OutMsgs6 = 2;
const CsumErrs6 = 3;
const LenErrs6 = 4;
const HlenErrs6 = 5;
const HoplimErrs6 = 6;
const IcmpCodeErrs6 = 7;
const TargetErrs6 = 8;
const OptlenErrs6 = 9;
const AddrmxpErrs6 = 10;
const RouterAddrErrs6 = 11;

const Nstats6 = 12;

const ICMP_USEAD6 = 40;

const Oflag: u8 = 1 << 5;
const Sflag: u8 = 1 << 6;
const Rflag: u8 = 1 << 7;

// ICMPv6 types
const EchoReply = 0;
const UnreachableV6 = 1;
const PacketTooBigV6 = 2;
const TimeExceedV6 = 3;
const SrcQuench = 4;
const ParamProblemV6 = 4;
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
const EchoRequestV6 = 128;
const EchoReplyV6 = 129;
const RouterSolicit = 133;
const RouterAdvert = 134;
const NbrSolicit = 135;
const NbrAdvert = 136;
const RedirectV6 = 137;

const Maxtype6 = 137;

// icmpv6 unreachability codes
const Icmp6_no_route = 0;
const Icmp6_ad_prohib = 1;
const Icmp6_out_src_scope = 2;
const Icmp6_adr_unreach = 3;
const Icmp6_port_unreach = 4;
const Icmp6_gress_src_fail = 5;
const Icmp6_rej_route = 6;
const Icmp6_unknown = 7; // our own invention for internal use

const MinAdvise = IP6HDR + 4; // minimum needed for us to advise another protocol

// on-the-wire packet formats

/// The C's ICMPHDR macro (IPV6HDR and the icmp header), followed by
/// the payload.
const IPICMP = extern struct {
    vcf: [4]u8, // version:4, traffic class:8, flow label:20
    ploadlen: [2]u8, // payload length: packet length - 40
    proto: u8, // next header type
    ttl: u8, // hop limit
    src: [IPaddrlen]u8,
    dst: [IPaddrlen]u8,
    type: u8,
    code: u8,
    cksum: [2]u8,
    icmpid: [2]u8,
    seq: [2]u8,
};

const IPICMPSZ = @sizeOf(IPICMP);

/// ICMPHDR, the target, then the payload.
const NdiscC = extern struct {
    hdr: IPICMP,
    target: [IPaddrlen]u8,
};

const NDISCSZ = @sizeOf(NdiscC);

/// ICMPHDR, the target and one option, whose link-layer address
/// follows (the C's lnaddr[]).
const Ndpkt = extern struct {
    vcf: [4]u8,
    ploadlen: [2]u8,
    proto: u8,
    ttl: u8,
    src: [IPaddrlen]u8,
    dst: [IPaddrlen]u8,
    type: u8,
    code: u8,
    cksum: [2]u8,
    icmpid: [2]u8,
    seq: [2]u8,
    target: [IPaddrlen]u8,
    otype: u8,
    /// length in units of 8 octets(incl type, code),
    /// 1 for IEEE 802 addresses
    olen: u8,
};

/// Where lnaddr starts.
const NDPKTSZ = @sizeOf(Ndpkt);

comptime {
    std.debug.assert(IPICMPSZ == IP6HDR + 8 and @alignOf(IPICMP) == 1);
    std.debug.assert(NDISCSZ == IPICMPSZ + IPaddrlen);
    std.debug.assert(NDPKTSZ == NDISCSZ + 2 and @alignOf(Ndpkt) == 1);
}

const Icmppriv6 = struct {
    stats: [Nstats6]u32 = @splat(0),

    // message counts
    in: [Maxtype6 + 1]u32 = @splat(0),
    out: [Maxtype6 + 1]u32 = @splat(0),
};

const Icmpcb6 = extern struct {
    headers: u8,
};

const icmpnames6: [Maxtype6 + 1]?[]const u8 = blk: {
    var t: [Maxtype6 + 1]?[]const u8 = @splat(null);
    t[EchoReply] = "EchoReply";
    t[UnreachableV6] = "UnreachableV6";
    t[PacketTooBigV6] = "PacketTooBigV6";
    t[TimeExceedV6] = "TimeExceedV6";
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
    t[AddrMaskReply] = "AddrMaskReply";
    t[EchoRequestV6] = "EchoRequestV6";
    t[EchoReplyV6] = "EchoReplyV6";
    t[RouterSolicit] = "RouterSolicit";
    t[RouterAdvert] = "RouterAdvert";
    t[NbrSolicit] = "NbrSolicit";
    t[NbrAdvert] = "NbrAdvert";
    t[RedirectV6] = "RedirectV6";
    break :blk t;
};

const statnames6: [Nstats6][]const u8 = .{
    "InMsgs",
    "InErrors",
    "OutMsgs",
    "CsumErrs",
    "LenErrs",
    "HlenErrs",
    "HoplimErrs",
    "IcmpCodeErrs",
    "TargetErrs",
    "OptlenErrs",
    "AddrmxpErrs",
    "RouterAddrErrs",
};

const unreachcode = [_][]const u8{
    "no route to destination", // Icmp6_no_route
    "comm with destination administratively prohibited", // Icmp6_ad_prohib
    "beyond scope of source address", // Icmp6_out_src_scope
    "address unreachable", // Icmp6_adr_unreach
    "port unreachable", // Icmp6_port_unreach
    "source address failed ingress/egress policy", // Icmp6_gress_src_fail
    "reject route to destination", // Icmp6_rej_route
    "icmp unreachable: unknown code", // Icmp6_unknown
};

fn icmppriv6(icmp: *Proto) *Icmppriv6 {
    return @ptrCast(@alignCast(icmp.priv.?));
}

fn icmpcb6(c: *Conv) *Icmpcb6 {
    return @ptrCast(@alignCast(c.ptcl.?));
}

fn icmpcreate6(c: *Conv) Error!void {
    c.rq = qio.qopen(64 * 1024, qio.Qmsg, null, c) orelse return error.Enomem;
    c.wq = qio.qbypass(icmpkick6, c) orelse return error.Enomem;
}

fn set_cksum(bp: *Block) void {
    const p: *IPICMP = @ptrCast(bp.rp);
    const n = qio.blocklen(bp);

    hnputl(&p.vcf, 0); // borrow IP header as pseudoheader
    hnputs(&p.ploadlen, @truncate(n - IP6HDR));
    p.proto = 0;
    p.ttl = ICMPv6; // ttl gets set later
    hnputs(&p.cksum, 0);
    hnputs(&p.cksum, ipaux.ptclcsum(bp, 0, n));
    p.proto = ICMPv6;
}

fn newIPICMP(packetlen: usize) *Block {
    const nbp = ab.allocb(packetlen);
    nbp.wp += packetlen;
    @memset(nbp.rp[0..packetlen], 0);
    return nbp;
}

fn icmpadvise6(icmp: *Proto, bp: *Block, _: *Ipifc, msg: []const u8) void {
    const p: *IPICMP = @ptrCast(bp.rp);
    const recid = nhgets(&p.icmpid);

    var i: usize = 0;
    while (icmp.conv[i]) |s| : (i += 1) {
        if (s.iphash.lport == recid and
            ipcmp(&s.iphash.laddr, &p.src) == 0 and
            ipcmp(&s.iphash.raddr, &p.dst) == 0)
        {
            if (s.ignoreadvice)
                break;
            qio.qhangup(s.rq.?, msg);
            qio.qhangup(s.wq.?, msg);
            break;
        }
    }
    qio.freeblist(bp);
}

fn icmpkick6(x: ?*anyopaque, bp_: *Block) void {
    var laddr: [IPaddrlen]u8 = undefined;
    var raddr: [IPaddrlen]u8 = undefined;
    const c: *Conv = @ptrCast(@alignCast(x.?));
    var bp = bp_;
    const ipriv = icmppriv6(c.p.?);
    const icb = icmpcb6(c);

    if (icb.headers == 6) {
        // get user specified addresses
        bp = qio.pullupblock(bp, ICMP_USEAD6) orelse return;
        bp.rp += 8;
        ipmove(&laddr, bp.rp[0..IPaddrlen]);
        bp.rp += IPaddrlen;
        ipmove(&raddr, bp.rp[0..IPaddrlen]);
        bp.rp += IPaddrlen;
        bp = qio.padblock(bp, IP6HDR);
    }

    if (BLEN(bp) < IPICMPSZ) {
        qio.freeblist(bp);
        return;
    }
    const p: *IPICMP = @ptrCast(bp.rp);
    if (icb.headers == 6) {
        ipmove(&p.dst, &raddr);
        ipmove(&p.src, &laddr);
    } else {
        ipmove(&p.dst, &c.iphash.raddr);
        ipmove(&p.src, &c.iphash.laddr);
        hnputs(&p.icmpid, c.iphash.lport);
    }

    set_cksum(bp);
    if (p.type <= Maxtype6)
        ipriv.out[p.type] +%= 1;
    _ = ipv6.ipoput6(c.p.?.f.?, bp, null, c.ttl, c.tos, null);
}

fn icmpctl6(c: *Conv, argv: []const []const u8) Error!void {
    const icb = icmpcb6(c);
    if (argv.len == 1 and std.mem.eql(u8, argv[0], "headers")) {
        icb.headers = 6;
        return;
    }
    return proc.errorf("unknown control request", .{});
}

fn goticmpkt6(icmp: *Proto, ifc: *Ipifc, bp: *Block, muxkey: u16) void {
    var recid: u16 = undefined;
    var addr: *const [IPaddrlen]u8 = undefined;
    const p: *IPICMP = @ptrCast(bp.rp);

    if (muxkey == 0) {
        recid = nhgets(&p.icmpid);
        addr = &p.src;
    } else {
        recid = muxkey;
        addr = &p.dst;
    }
    var i: usize = 0;
    while (icmp.conv[i]) |s| : (i += 1) {
        if (s.iphash.lport == recid and
            (ipcmp(&s.iphash.laddr, &p.dst) == 0 or ipcmp(&s.iphash.raddr, addr) == 0) and
            (!islinklocal(&s.iphash.laddr) or ipifc.iplocalonifc(ifc, &s.iphash.laddr) != null))
        {
            _ = qio.qpass(s.rq.?, qio.copyblock(bp, qio.blocklen(bp)));
        }
    }
    qio.freeblist(bp);
}

fn mkechoreply6(bp: *Block, ifc: *Ipifc) ?*Block {
    var addr: [IPaddrlen]u8 = undefined;
    const p: *IPICMP = @ptrCast(bp.rp);

    if (isv6mcast(&p.src))
        return null;
    ipmove(&addr, &p.src);
    if (!isv6mcast(&p.dst))
        ipmove(&p.src, &p.dst)
    else if (!ipifc.ipv6local(ifc, &p.src, 0, &addr))
        return null;
    ipmove(&p.dst, &addr);
    p.type = EchoReplyV6;
    set_cksum(bp);
    return bp;
}

/// sends out an ICMPv6 neighbor solicitation
///     suni == SRC_UNSPEC or SRC_UNI,
///     tuni == TARG_MULTI => multicast for address resolution,
///     and tuni == TARG_UNI => neighbor reachability.
pub fn icmpns6(f: *Fs, src: ?*const [IPaddrlen]u8, suni: u8, targ: *const [IPaddrlen]u8, tuni: u8, mac: []const u8) void {
    const icmp = f.t2p[ICMPv6].?;
    const ipriv = icmppriv6(icmp);
    const olen = (2 + mac.len + 7) / 8;

    const nbp = newIPICMP(NDISCSZ + olen * 8);
    const np: *Ndpkt = @ptrCast(nbp.rp);

    if (suni == SRC_UNSPEC)
        ipmove(&np.src, &v6Unspecified)
    else
        ipmove(&np.src, src.?);

    if (tuni == TARG_UNI)
        ipmove(&np.dst, targ)
    else
        ipaux.ipv62smcast(&np.dst, targ);

    np.type = NbrSolicit;
    np.code = 0;
    ipmove(&np.target, targ);
    if (suni != SRC_UNSPEC) {
        np.otype = SRC_LLADDR;
        np.olen = @intCast(olen);
        @memcpy((nbp.rp + NDPKTSZ)[0..mac.len], mac);
    } else nbp.wp -= olen * 8;

    set_cksum(nbp);
    ipriv.out[NbrSolicit] +%= 1;
    netlog(f, Logicmp, "sending neighbor solicitation %I\n", .{ipaux.ip(targ)});
    _ = ipv6.ipoput6(f, nbp, null, MAXTTL, DFLTTOS, null);
}

/// sends out an ICMPv6 neighbor advertisement. pktflags == RSO flags.
pub fn icmpna6(f: *Fs, src: *const [IPaddrlen]u8, dst: *const [IPaddrlen]u8, targ: *const [IPaddrlen]u8, mac: []const u8, flags: u8) void {
    const icmp = f.t2p[ICMPv6].?;
    const ipriv = icmppriv6(icmp);
    const olen = (2 + mac.len + 7) / 8;

    const nbp = newIPICMP(NDISCSZ + olen * 8);
    const np: *Ndpkt = @ptrCast(nbp.rp);

    ipmove(&np.src, src);
    ipmove(&np.dst, dst);

    np.type = NbrAdvert;
    np.code = 0;
    np.icmpid[0] = flags;
    ipmove(&np.target, targ);

    np.otype = TARGET_LLADDR;
    np.olen = @intCast(olen);
    @memcpy((nbp.rp + NDPKTSZ)[0..mac.len], mac);

    set_cksum(nbp);
    ipriv.out[NbrAdvert] +%= 1;
    netlog(f, Logicmp, "sending neighbor advertisement %I\n", .{ipaux.ip(targ)});
    _ = ipv6.ipoput6(f, nbp, null, MAXTTL, DFLTTOS, null);
}

/// Send a ICMPv6 packet back of type/code/arg in response to packet bp
/// which was received on ifc. The route hint rh is valid for the
/// reverse route.
fn icmpsend6(f: *Fs, ifc: *Ipifc, bp: *Block, typ: u8, code: u8, arg: usize, rh: ?*Routehint) void {
    var ia: [IPaddrlen]u8 = undefined;

    const osz = BLEN(bp);
    if (osz < IP6HDR)
        return;

    const p: *Ip6hdr = @ptrCast(bp.rp);
    if (isv6mcast(&p.dst) or isv6mcast(&p.src) or !ipifc.ipv6local(ifc, &ia, 0, &p.src))
        return;

    netlog(f, Logicmp, "icmpsend6 %s (%d) %d ia %I -> src %I dst %I\n", .{
        icmpnames6[typ] orelse "", typ, code, ipaux.ip(&ia), ipaux.ip(&p.src), ipaux.ip(&p.dst),
    });

    const sz: usize = @min(IPICMPSZ + osz, ipdat.v6MINTU);
    const nbp = newIPICMP(sz);
    var np: *IPICMP = @ptrCast(nbp.rp);
    ipmove(&np.src, &ia);
    ipmove(&np.dst, &p.src);
    np.type = typ;
    np.code = code;
    hnputs(&np.icmpid, 0);
    hnputs(&np.seq, @truncate(arg));
    @memcpy((nbp.rp + IPICMPSZ)[0 .. sz - IPICMPSZ], bp.rp[0 .. sz - IPICMPSZ]);
    set_cksum(nbp);

    const icmp = f.t2p[ICMPv6].?;
    icmppriv6(icmp).out[typ] +%= 1;

    if (rh) |h| {
        if (h.r) |r| {
            if ((r.type & ipdat.Runi) != 0) {
                np = @ptrCast(nbp.rp);
                np.vcf[0] = IP_VER6 | DFLTTOS >> 4;
                np.vcf[1] = DFLTTOS << 4;
                np.ttl = MAXTTL;

                icmp.rcv.?(icmp, ifc, nbp);
                return;
            }
        }
    }

    _ = ipv6.ipoput6(f, nbp, null, MAXTTL, DFLTTOS, rh);
}

pub fn icmpnohost6(f: *Fs, ifc: *Ipifc, bp: *Block, rh: ?*Routehint) void {
    icmpsend6(f, ifc, bp, UnreachableV6, Icmp6_adr_unreach, 0, rh);
}

pub fn icmpnoconv6(f: *Fs, ifc: *Ipifc, bp: *Block) void {
    icmpsend6(f, ifc, bp, UnreachableV6, Icmp6_port_unreach, 0, null);
}

pub fn icmpttlexceeded6(f: *Fs, ifc: *Ipifc, bp: *Block) void {
    icmpsend6(f, ifc, bp, TimeExceedV6, 0, 0, null);
}

pub fn icmppkttoobig6(f: *Fs, ifc: *Ipifc, bp: *Block, mtu: usize) void {
    icmpsend6(f, ifc, bp, PacketTooBigV6, 0, mtu, null);
}

/// RFC 2461, pages 39-40, pages 57-58.
fn valid(icmp: *Proto, bp: *Block, ipriv: *Icmppriv6) bool {
    const f = icmp.f.?;
    const pktsz = BLEN(bp);
    const packet = bp.rp;
    const p: *IPICMP = @ptrCast(packet);

    err: {
        if (pktsz < IPICMPSZ) {
            ipriv.stats[HlenErrs6] +%= 1;
            netlog(f, Logicmp, "icmp hlen %d\n", .{pktsz});
            break :err;
        }

        // Rather than construct explicit pseudoheader, overwrite IPv6 header
        if (p.proto != ICMPv6) {
            // This code assumes no extension headers!!!
            netlog(f, Logicmp, "icmp error: extension header\n", .{});
            break :err;
        }
        const vcf = nhgetl(&p.vcf);
        hnputl(&p.vcf, 0); // borrow IP header as pseudoheader
        const ttl = p.ttl;
        p.ttl = p.proto;
        p.proto = 0;
        if (ipaux.ptclcsum(bp, 0, pktsz) != 0) {
            ipriv.stats[CsumErrs6] +%= 1;
            netlog(f, Logicmp, "icmp checksum error\n", .{});
            break :err;
        }
        p.proto = p.ttl;
        p.ttl = ttl;
        hnputl(&p.vcf, vcf);

        // additional tests for some pkt types
        if (p.type == NbrSolicit or p.type == NbrAdvert or
            p.type == RouterAdvert or p.type == RouterSolicit or
            p.type == RedirectV6)
        {
            if (p.ttl != MAXTTL) {
                ipriv.stats[HoplimErrs6] +%= 1;
                break :err;
            }
            if (p.code != 0) {
                ipriv.stats[IcmpCodeErrs6] +%= 1;
                break :err;
            }

            switch (p.type) {
                NbrSolicit, NbrAdvert => {
                    if (pktsz - IPICMPSZ < IPaddrlen) {
                        ipriv.stats[HlenErrs6] +%= 1;
                        break :err;
                    }
                    const np: *Ndpkt = @ptrCast(packet);
                    if (isv6mcast(&np.target)) {
                        ipriv.stats[TargetErrs6] +%= 1;
                        break :err;
                    }
                    if (pktsz - IPICMPSZ >= IPaddrlen + 2 and np.olen == 0) {
                        ipriv.stats[OptlenErrs6] +%= 1;
                        break :err;
                    }

                    if (p.type == NbrSolicit and
                        ipcmp(&np.src, &v6Unspecified) == 0)
                    {
                        if (!issmcast(&np.dst)) {
                            ipriv.stats[AddrmxpErrs6] +%= 1;
                            break :err;
                        }
                    }

                    if (p.type == NbrAdvert) {
                        if (isv6mcast(&np.dst) and
                            (nhgets(&np.icmpid) & Sflag) != 0)
                        {
                            ipriv.stats[AddrmxpErrs6] +%= 1;
                            break :err;
                        }
                    }
                },
                RouterAdvert => {
                    if (pktsz - IP6HDR < 16) {
                        ipriv.stats[HlenErrs6] +%= 1;
                        break :err;
                    }
                    if (!islinklocal(&p.src)) {
                        ipriv.stats[RouterAddrErrs6] +%= 1;
                        break :err;
                    }
                    var sz: usize = IPICMPSZ + 8;
                    while (sz + 8 <= pktsz) {
                        const osz: usize = packet[sz + 1];
                        if (osz <= 0) {
                            ipriv.stats[OptlenErrs6] +%= 1;
                            break :err;
                        }
                        sz += 8 * osz;
                    }
                },
                RouterSolicit => {
                    if (pktsz - IP6HDR < 8) {
                        ipriv.stats[HlenErrs6] +%= 1;
                        break :err;
                    }
                    const unsp = ipcmp(&p.src, &v6Unspecified) == 0;
                    var sz: usize = IPICMPSZ + 8;
                    while (sz + 8 <= pktsz) {
                        const osz: usize = packet[sz + 1];
                        if (osz <= 0 or
                            (unsp and packet[sz] == SRC_LLADDR))
                        {
                            ipriv.stats[OptlenErrs6] +%= 1;
                            break :err;
                        }
                        sz += 8 * osz;
                    }
                },
                RedirectV6 => {
                    // to be filled in
                },
                else => break :err,
            }
        }
        return true;
    }
    ipriv.stats[InErrors6] +%= 1;
    return false;
}

/// The link-layer address in the option of a neighbour solicitation
/// or advertisement: the C's np->lnaddr, 8*np->olen-2, cut down to
/// what the packet holds.
/// DIFF: see the head of the file.
fn lnaddr(bp: *Block) []const u8 {
    const pktsz = BLEN(bp);
    if (pktsz < NDPKTSZ)
        return &.{};
    const np: *Ndpkt = @ptrCast(bp.rp);
    const olen = 8 * @as(usize, np.olen);
    if (olen < 2)
        return &.{};
    return (bp.rp + NDPKTSZ)[0..@min(olen - 2, pktsz - NDPKTSZ)];
}

fn icmpiput6(icmp: *Proto, ifc: *Ipifc, bp_: *Block) void {
    var m2: [128]u8 = undefined;
    var msg: []const u8 = undefined;
    var ia: [IPaddrlen]u8 = undefined;
    const f = icmp.f.?;
    const ipriv = icmppriv6(icmp);

    const bp = qio.concatblock(bp_);
    const p: *IPICMP = @ptrCast(bp.rp);

    if (!valid(icmp, bp, ipriv) or p.type > Maxtype6) {
        qio.freeblist(bp);
        return;
    }

    ipriv.in[p.type] +%= 1;

    switch (p.type) {
        EchoRequestV6 => {
            const r = mkechoreply6(bp, ifc) orelse {
                qio.freeblist(bp);
                return;
            };
            ipriv.out[EchoReply] +%= 1;
            _ = ipv6.ipoput6(f, r, null, MAXTTL, DFLTTOS, null);
            return;
        },

        UnreachableV6 => {
            if (p.code >= unreachcode.len)
                msg = unreachcode[Icmp6_unknown]
            else
                msg = unreachcode[p.code];
        },

        TimeExceedV6 => {
            if (p.code == 0) {
                msg = fmt.snprint(m2[0 .. m2.len - 1], "ttl exceeded at %I", .{ipaux.ip(&p.src)});
            } else if (p.code == 1) {
                msg = fmt.snprint(m2[0 .. m2.len - 1], "frag time exceeded at %I", .{ipaux.ip(&p.src)});
            } else {
                goticmpkt6(icmp, ifc, bp, 0);
                return;
            }
        },

        PacketTooBigV6 => {
            // the mtu is the four bytes of icmpid and seq
            msg = fmt.snprint(m2[0 .. m2.len - 1], "packet too big for %lud mtu at %I", .{
                nhgetl((bp.rp + IPICMPSZ - 4)[0..4]), ipaux.ip(&p.src),
            });
        },

        RouterAdvert, RouterSolicit => {
            goticmpkt6(icmp, ifc, bp, p.type);
            return;
        },

        NbrSolicit => {
            const maclen = ifc.m.?.maclen;
            if (maclen == 0) {
                qio.freeblist(bp);
                return;
            }
            const np: *Ndpkt = @ptrCast(bp.rp);
            var pktflags: u8 = 0;
            if (ifc.sendra6)
                pktflags |= Rflag;
            const t = arp.arpforme(f, V6, &np.target, &np.src, ifc);
            answer: {
                if (t == ipdat.Runi)
                    pktflags |= Oflag
                else if (t != ipdat.Rproxy)
                    break :answer;
                // wet floor
                if (ipifc.ipv6local(ifc, &ia, 0, &np.src)) {
                    if (arp.arpenter(f, V6, &np.src, lnaddr(bp), &ia, ifc, false) < 0)
                        break :answer;
                    pktflags |= Sflag;
                } else ipmove(&ia, &np.target);
                icmpna6(
                    f,
                    &ia,
                    if ((pktflags & Sflag) != 0) &np.src else &ipaux.v6allnodesL,
                    &np.target,
                    ifc.mac[0..maclen],
                    pktflags,
                );
            }
            qio.freeblist(bp);
            return;
        },

        NbrAdvert => {
            if (ifc.m.?.maclen == 0) {
                qio.freeblist(bp);
                return;
            }
            const np: *Ndpkt = @ptrCast(bp.rp);
            // if the target address matches one of the local interface
            // addresses and the local interface address has tentative bit
            // set, insert into ARP table. this is so the duplicate address
            // detection part of ipconfig can discover duplication through
            // the arp table.
            const lifc = ipifc.iplocalonifc(ifc, &np.target);
            if (lifc != null and lifc.?.tentative)
                _ = arp.arpenter(f, V6, &np.target, lnaddr(bp), &np.target, ifc, false)
            else if (ipifc.ipv6local(ifc, &ia, 0, &np.target))
                _ = arp.arpenter(f, V6, &np.target, lnaddr(bp), &ia, ifc, true);
            qio.freeblist(bp);
            return;
        },

        else => {
            goticmpkt6(icmp, ifc, bp, 0);
            return;
        },
    }

    // Advise:
    bp.rp += IPICMPSZ;
    if (BLEN(bp) < MinAdvise) {
        ipriv.stats[LenErrs6] +%= 1;
        qio.freeblist(bp);
        return;
    }
    const ip: *Ip6hdr = @ptrCast(bp.rp);
    // get rid of fragment header if this is the first fragment
    if ((ip.vcf[0] & 0xF0) == IP_VER6 and ip.proto == FH and BLEN(bp) >= MinAdvise + IP6FHDR and MinAdvise > IP6HDR) {
        const fh: *Fraghdr6 = @ptrCast(bp.rp + IP6HDR);
        if ((nhgets(&fh.offsetRM) & ~@as(u16, 7)) == 0) { // first fragment
            ip.proto = fh.nexthdr;
            // copy down payload over fragment header
            bp.rp += IP6HDR;
            bp.wp -= IP6FHDR;
            const n = BLEN(bp);
            std.mem.copyForwards(u8, bp.rp[0..n], (bp.rp + IP6FHDR)[0..n]);
            hnputs(&ip.ploadlen, @truncate(n));
            bp.rp -= IP6HDR;
        }
    }
    if ((ip.vcf[0] & 0xF0) == IP_VER6 and ip.proto != FH) {
        if (devip.Fsrcvpcolx(f, ip.proto)) |pr| {
            if (pr.advise) |advise| {
                netlog(f, Logicmp, "advising %s!%I -> %I: %s\n", .{ pr.name, ipaux.ip(&ip.src), ipaux.ip(&ip.dst), msg });
                advise(pr, bp, ifc, msg);
                return;
            }
        }
    }
    bp.rp -= IPICMPSZ;
    goticmpkt6(icmp, ifc, bp, 0);
}

fn icmpstats6(icmp6: *Proto, buf: []u8) usize {
    const priv = icmppriv6(icmp6);
    var n: usize = 0;
    for (0..Nstats6) |i|
        n += fmt.snprint(buf[n..], "%s: %lud\n", .{ statnames6[i], priv.stats[i] }).len;
    for (0..Maxtype6 + 1) |i| {
        if (icmpnames6[i]) |name|
            n += fmt.snprint(buf[n..], "%s: %lud %lud\n", .{ name, priv.in[i], priv.out[i] }).len;
    }
    return n;
}

// import from icmp.c: icmpstate, icmpannounce, icmpconnect, icmpclose

fn icmpclose6(c: *Conv) void {
    const icb = icmpcb6(c);
    icb.headers = 0;
    icmp4.icmpclose(c);
}

pub fn icmp6init(fs: *Fs) void {
    const icmp6 = alloc.snew(Proto);
    icmp6.* = .{};

    const priv = alloc.snew(Icmppriv6);
    priv.* = .{};
    icmp6.priv = priv;
    icmp6.name = "icmpv6";
    icmp6.connect = icmp4.icmpconnect;
    icmp6.announce = icmp4.icmpannounce;
    icmp6.state = icmp4.icmpstate;
    icmp6.create = icmpcreate6;
    icmp6.close = icmpclose6;
    icmp6.rcv = icmpiput6;
    icmp6.stats = icmpstats6;
    icmp6.ctl = icmpctl6;
    icmp6.advise = icmpadvise6;
    icmp6.gc = null;
    icmp6.ipproto = ICMPv6;
    icmp6.nc = 16;
    icmp6.ptclsize = @sizeOf(Icmpcb6);

    _ = devip.Fsproto(fs, icmp6);
}
