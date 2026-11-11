//! IP version 6: output with fragmentation, input with forwarding,
//! the walk over the extension headers and reassembly.
//! from 9/ip/ipv6.c
//!
//! DIFF:
//!   - waserror in ipoput6 protects two calls, the loopback bypass and
//!     ipifcoput; each handles its error where it is called: count it
//!     in ifc.outerr, unlock, return -1.
//!   - When ipifcoput fails for a fragment, the C returns without
//!     freeing the packet being fragmented.  Here the packet is freed,
//!     since ipoput6 owns bp in every case.
//!   - ipiput6 reads the addresses for its "bogus packet length" log
//!     line before trimblock, which frees the packet when it fails;
//!     the C formats them from the freed block.
//!   - The C's ints are i32 with the same conversions; where a value
//!     is stored in a header or in an Ipfrag it is truncated as the
//!     C's assignment does.  Block lengths are brought to i32 by int().
//!   - unfraglen compares addresses as integers; its setfh and popfh,
//!     and the doreasm of procxtns, are bools.
//!   - The Ipfrag at the base of a block is reached through a pointer
//!     of alignment 1 (fragof).
//!   - A nil dereference in C (a block list shorter than its header
//!     says, an empty fragment list in ipfragallo6) is a `.?` here.

const std = @import("std");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const ql = @import("../port/qlock.zig");
const portdat = @import("../port/portdat.zig");
const p9 = @import("../port/print.zig");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const netlog_ = @import("netlog.zig");
const devip = @import("devip.zig");
const iproute = @import("iproute.zig");
const ipifc = @import("ipifc.zig");
const icmp6 = @import("icmp6.zig");
const tcp = @import("tcp.zig");
const loopbackmedium = @import("loopbackmedium.zig");

const Block = ab.Block;
const BLEN = ab.BLEN;
const allocb = ab.allocb;
const freeb = ab.freeb;
const freeblist = qio.freeblist;
const blocklen = qio.blocklen;
const concatblock = qio.concatblock;
const pullupblock = qio.pullupblock;
const trimblock = qio.trimblock;
const padblock = qio.padblock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const canrlock = ql.canrlock;
const runlock = ql.runlock;
const incref = portdat.incref;

const Fs = ipdat.Fs;
const IP = ipdat.IP;
const Ipifc = ipdat.Ipifc;
const Route = ipdat.Route;
const Routehint = ipdat.Routehint;
const Ip6hdr = ipdat.Ip6hdr;
const Fraghdr6 = ipdat.Fraghdr6;
const Ipfrag = ipdat.Ipfrag;
const Fragment6 = ipdat.Fragment6;
const v6params = ipdat.v6params;

const IPaddrlen = ipdat.IPaddrlen;
const V6 = ipdat.V6;
const IP_VER6 = ipdat.IP_VER6;
const IP_MAX = ipdat.IP_MAX;
const IP6HDR = ipdat.IP6HDR;
const IP6FHDR = ipdat.IP6FHDR;
const IPFRAGSZ = ipdat.IPFRAGSZ;
const MAXTTL = ipdat.MAXTTL;
const RETRANS_TIMER = ipdat.RETRANS_TIMER;
const HBH = ipdat.HBH;
const RH = ipdat.RH;
const FH = ipdat.FH;
const DOH = ipdat.DOH;
const Link_local_scop = ipdat.Link_local_scop;
const Logip = ipdat.Logip;
const Rv4 = ipdat.Rv4;
const Rifc = ipdat.Rifc;
const Runi = ipdat.Runi;
const Rbcast = ipdat.Rbcast;
const Rmulti = ipdat.Rmulti;
const NOW = ipdat.NOW;
const ipcmp = ipdat.ipcmp;
const islinklocal = ipdat.islinklocal;
const isv6mcast = ipdat.isv6mcast;

const netlog = netlog_.netlog;
const hnputs = ipaux.hnputs;
const hnputl = ipaux.hnputl;
const nhgets = ipaux.nhgets;
const nhgetl = ipaux.nhgetl;

/// A length or size as the C's int.
fn int(n: usize) i32 {
    return @bitCast(@as(u32, @truncate(n)));
}

/// The C's conversion of an int to ushort.
fn ushort(n: i32) u16 {
    return @truncate(@as(u32, @bitCast(n)));
}

/// An int that the C passes on as an int, for a usize parameter: sign
/// extended, so that what is truncated from it later is what the C
/// truncates.
fn size(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// The Ipfrag kept at the base of a block: the C's (Ipfrag*)bp->base.
fn fragof(bp: *Block) *align(1) Ipfrag {
    return @ptrCast(bp.base);
}

pub fn ip_init_6(f: *Fs) void {
    const v6p = alloc.snew(v6params);
    v6p.* = .{};

    v6p.rp.mflag = 0; // default not managed
    v6p.rp.oflag = 0;
    v6p.rp.maxraint = 600000; // millisecs
    v6p.rp.minraint = 200000;
    v6p.rp.linkmtu = 0; // no mtu sent
    v6p.rp.reachtime = 0;
    v6p.rp.rxmitra = 0;
    v6p.rp.ttl = MAXTTL;
    v6p.rp.routerlt = @divTrunc(3 * v6p.rp.maxraint, 1000);

    v6p.hp.rxmithost = RETRANS_TIMER;

    f.v6p = v6p;
}

pub fn ipoput6(f: *Fs, bp: *Block, gating: ?*Ipifc, ttl: u32, tos: u32, rh: ?*Routehint) i32 {
    var rv: i32 = 0;
    var nexthdr: u8 = undefined;
    var fraghdr: Fraghdr6 = undefined;

    const ip = f.ip.?;
    ip.stats[ipdat.OutRequests] += 1;

    free: {
        // Fill out the ip header
        const eh: *Ip6hdr = @ptrCast(bp.rp);
        if (BLEN(bp) < IP6HDR)
            p9.panic("ipoput6: assert failed, pc %#p", .{@returnAddress()});
        const len = int(blocklen(bp));
        if (len >= IP_MAX) {
            ip.stats[ipdat.OutDiscards] += 1;
            netlog(f, Logip, "%I -> %I: exceeded ip max size: %d\n", .{ ipaux.ip(&eh.src), ipaux.ip(&eh.dst), len });
            break :free;
        }

        const r: ?*Route = iproute.v6lookup(f, &eh.dst, &eh.src, rh);
        const ifc: *Ipifc = (if (r) |x| (if (x.type & Rv4 != 0) null else x.ifc) else null) orelse {
            ip.stats[ipdat.OutNoRoutes] += 1;
            netlog(f, Logip, "%I -> %I: no interface\n", .{ ipaux.ip(&eh.src), ipaux.ip(&eh.dst) });
            rv = -1;
            break :free;
        };
        const rt = r.?;

        const gate: []const u8 = if (rt.type & (Rifc | Runi | Rbcast | Rmulti) != 0)
            &eh.dst
        else
            &rt.u.v6.gate;

        if (!canrlock(&ifc.rwlock)) {
            ip.stats[ipdat.OutDiscards] += 1;
            break :free;
        }
        raise: {
            const m = ifc.m orelse {
                rv = -1;
                break :raise;
            };
            if (rt.ifcid != ifc.ifcid) {
                rv = -1;
                break :raise;
            }

            const medialen = int(ifc.maxtu) -% int(m.hsize);
            if (gating) |g| {
                var mtu = int(g.maxtu) -% int(g.m.?.hsize);
                if (medialen < mtu)
                    mtu = medialen;
                tcp.tcpmssclamp(bp.rp[0..BLEN(bp)], size(mtu));
            } else {
                eh.vcf[0] = IP_VER6;
                eh.vcf[0] |= @truncate(tos >> 4);
                eh.vcf[1] = @truncate(tos << 4);

                // bypass for loopback
                if (rt.type & Runi != 0) {
                    eh.ttl = @truncate(ttl);
                    hnputs(&eh.ploadlen, ushort(len - IP6HDR));
                    loopbackmedium.loopbackmedium.bwrite.?(ifc, concatblock(bp), V6, gate, rh) catch {
                        ifc.outerr +%= 1;
                        runlock(&ifc.rwlock);
                        // bp is freed by m->bwrite()
                        return -1;
                    };
                    runlock(&ifc.rwlock);
                    return 0;
                }
            }
            eh.ttl = @truncate(ttl);

            // If we dont need to fragment just send it
            if (len <= medialen) {
                hnputs(&eh.ploadlen, ushort(len - IP6HDR));
                ipifc.ipifcoput(ifc, bp, V6, gate, rh) catch {
                    ifc.outerr +%= 1;
                    runlock(&ifc.rwlock);
                    // bp is freed by m->bwrite() called from ipifcoput()
                    return -1;
                };
                runlock(&ifc.rwlock);
                return 0;
            }

            if (gating != null and !ifc.reassemble) {
                //
                // v6 intermediate nodes are not supposed to fragment pkts;
                // we fragment if ifc->reassemble is turned on; an exception
                // needed for nat.
                //
                ip.stats[ipdat.OutDiscards] += 1;
                icmp6.icmppkttoobig6(f, gating.?, bp, size(medialen));
                netlog(f, Logip, "%I -> %I: gated pkts not fragmented\n", .{ ipaux.ip(&eh.src), ipaux.ip(&eh.dst) });
                break :raise;
            }

            // start v6 fragmentation
            const uflen = unfraglen(bp, &nexthdr, true, false);
            if (uflen < IP6HDR or nexthdr == FH) {
                ip.stats[ipdat.FragFails] += 1;
                ip.stats[ipdat.OutDiscards] += 1;
                netlog(f, Logip, "%I -> %I: fragment header botch\n", .{ ipaux.ip(&eh.src), ipaux.ip(&eh.dst) });
                break :raise;
            }
            if (uflen > medialen) {
                ip.stats[ipdat.FragFails] += 1;
                ip.stats[ipdat.OutDiscards] += 1;
                netlog(f, Logip, "%I -> %I: unfragmentable part too big: %d\n", .{ ipaux.ip(&eh.src), ipaux.ip(&eh.dst), uflen });
                break :raise;
            }

            const flen: i32 = len - uflen;
            var seglen: i32 = (medialen - (uflen + IP6FHDR)) & ~@as(i32, 7);
            if (seglen < 8) {
                ip.stats[ipdat.FragFails] += 1;
                ip.stats[ipdat.OutDiscards] += 1;
                netlog(f, Logip, "%I -> %I: seglen < 8\n", .{ ipaux.ip(&eh.src), ipaux.ip(&eh.dst) });
                break :raise;
            }

            const lid: i32 = incref(&ip.id6);
            fraghdr.nexthdr = nexthdr;
            fraghdr.res = 0;
            hnputl(&fraghdr.id, @bitCast(lid));

            var xp: ?*Block = bp;
            var offset: i32 = uflen;
            while (offset != 0 and offset >= int(BLEN(xp.?))) {
                offset -= int(BLEN(xp.?));
                xp = xp.?.next;
            }
            xp.?.rp += @as(usize, @intCast(offset));

            var fragoff: i32 = 0;
            var morefrags: u8 = 1;

            const ul: usize = @intCast(uflen);
            while (fragoff < flen) : (fragoff += seglen) {
                const nb = allocb(@intCast(uflen + IP6FHDR + seglen));

                if (fragoff + seglen >= flen) {
                    seglen = flen - fragoff;
                    morefrags = 0;
                }

                hnputs(&eh.ploadlen, ushort(seglen + IP6FHDR));
                @memcpy(nb.wp[0..ul], @as([*]const u8, @ptrCast(eh))[0..ul]);
                nb.wp += ul;

                hnputs(&fraghdr.offsetRM, ushort(fragoff)); // last 3 bits must be 0
                fraghdr.offsetRM[1] |= morefrags;
                @memcpy(nb.wp[0..IP6FHDR], std.mem.asBytes(&fraghdr));
                nb.wp += IP6FHDR;

                // Copy data
                var chunk: i32 = seglen;
                while (chunk != 0) {
                    const x = xp orelse {
                        ip.stats[ipdat.OutDiscards] += 1;
                        ip.stats[ipdat.FragFails] += 1;
                        freeblist(nb);
                        netlog(f, Logip, "xp == nil: chunk in v6%d\n", .{chunk});
                        break :raise;
                    };
                    var blklen: i32 = chunk;
                    if (int(BLEN(x)) < chunk)
                        blklen = int(BLEN(x));
                    const n: usize = @intCast(blklen);
                    @memcpy(nb.wp[0..n], x.rp[0..n]);

                    nb.wp += n;
                    x.rp += n;
                    chunk -= blklen;
                    if (x.rp == x.wp)
                        xp = x.next;
                }
                ipifc.ipifcoput(ifc, nb, V6, gate, rh) catch {
                    ifc.outerr +%= 1;
                    runlock(&ifc.rwlock);
                    // DIFF: the C leaks bp here
                    freeblist(bp);
                    return -1;
                };
                ip.stats[ipdat.FragCreates] += 1;
            }
            ip.stats[ipdat.FragOKs] += 1;
        }
        runlock(&ifc.rwlock);
    }
    freeblist(bp);
    return rv;
}

pub fn ipiput6(f: *Fs, ifc: *Ipifc, bp_: *Block) void {
    var bp = bp_;

    drop: {
        if (ifc.lifc == null)
            break :drop;

        ifc.in +%= 1;

        const ip = f.ip.?;
        ip.stats[ipdat.InReceives] += 1;

        //
        //  Ensure we have all the header info in the first
        //  block.  Make life easier for other protocols by
        //  collecting up to the first 64 bytes in the first block.
        //
        if (BLEN(bp) < 64) {
            var hl: i32 = int(blocklen(bp));
            if (hl < IP6HDR)
                hl = IP6HDR;
            if (hl > 64)
                hl = 64;
            bp = pullupblock(bp, @intCast(hl)) orelse return;
        }

        // Check header version
        var h: *Ip6hdr = @ptrCast(bp.rp);
        if ((h.vcf[0] & 0xF0) != IP_VER6) {
            ip.stats[ipdat.InHdrErrors] += 1;
            netlog(f, Logip, "ip: bad version %ux\n", .{@as(u32, h.vcf[0] & 0xF0) >> 2});
            break :drop;
        }
        const len: i32 = IP6HDR + @as(i32, nhgets(&h.ploadlen));
        {
            // DIFF: copied before trimblock can free the packet
            const src = h.src;
            const dst = h.dst;
            bp = trimblock(bp, 0, len) orelse {
                ip.stats[ipdat.InHdrErrors] += 1;
                netlog(f, Logip, "%I -> %I: bogus packet length: %d\n", .{ ipaux.ip(&src), ipaux.ip(&dst), len });
                return;
            };
        }
        h = @ptrCast(bp.rp);

        // route
        if (ipifc.ipforme(f, &h.dst) == 0) {
            var rh: Routehint = .{};

            if (!ip.iprouting)
                break :drop;

            // don't forward to link-local destinations
            if (islinklocal(&h.dst) or
                (isv6mcast(&h.dst) and (h.dst[1] & 0xF) <= Link_local_scop))
            {
                ip.stats[ipdat.OutDiscards] += 1;
                break :drop;
            }

            // don't forward to source's network
            rh.r = null;
            rh.a = null;
            const r = iproute.v6lookup(f, &h.dst, &h.src, &rh) orelse {
                ip.stats[ipdat.OutDiscards] += 1;
                break :drop;
            };
            const nifc = r.ifc orelse {
                ip.stats[ipdat.OutDiscards] += 1;
                break :drop;
            };
            if ((r.type & Rv4) != 0 or (nifc == ifc and !ifc.reflect)) {
                ip.stats[ipdat.OutDiscards] += 1;
                break :drop;
            }

            // don't forward if packet has timed out
            const hop: i32 = h.ttl;
            if (hop <= 1) {
                ip.stats[ipdat.InHdrErrors] += 1;
                icmp6.icmpttlexceeded6(f, ifc, bp);
                break :drop;
            }

            // process headers & reassemble if the interface expects it
            bp = procxtns(ip, bp, nifc.reassemble) orelse return;

            ip.stats[ipdat.ForwDatagrams] += 1;
            h = @ptrCast(bp.rp);
            const tos: u32 = (@as(u32, h.vcf[0] & 0x0F) << 2) | (@as(u32, h.vcf[1] & 0xF0) >> 2);
            _ = ipoput6(f, bp, ifc, @intCast(hop - 1), tos, &rh);
            return;
        }

        // reassemble & process headers if needed
        bp = procxtns(ip, bp, true) orelse return;

        h = @ptrCast(bp.rp);
        if (devip.Fsrcvpcol(f, h.proto)) |p| {
            if (p.rcv) |rcv| {
                ip.stats[ipdat.InDelivers] += 1;
                rcv(p, ifc, bp);
                return;
            }
        }

        ip.stats[ipdat.InDiscards] += 1;
        ip.stats[ipdat.InUnknownProtos] += 1;
    }
    freeblist(bp);
}

/// ipfragfree6 - copied from ipfragfree4 - assume hold fraglock6
fn ipfragfree6(ip: *IP, frag: *Fragment6) void {
    if (frag.blist != null)
        freeblist(frag.blist);
    frag.blist = null;
    frag.id = 0;
    @memset(&frag.src, 0);
    @memset(&frag.dst, 0);

    var l: *?*Fragment6 = &ip.flisthead6;
    var fl = l.*;
    while (fl) |x| : (fl = x.next) {
        if (x == frag) {
            l.* = frag.next;
            break;
        }
        l = &x.next;
    }

    frag.next = ip.fragfree6;
    ip.fragfree6 = frag;
}

/// ipfragallo6 - copied from ipfragalloc4
fn ipfragallo6(ip: *IP) *Fragment6 {
    while (ip.fragfree6 == null) {
        // free last entry on fraglist
        var f = ip.flisthead6.?;
        while (f.next) |x|
            f = x;
        ipfragfree6(ip, f);
    }
    const f = ip.fragfree6.?;
    ip.fragfree6 = f.next;
    f.next = ip.flisthead6;
    ip.flisthead6 = f;
    f.age = NOW() +% 30000;

    return f;
}

fn procxtns(ip: *IP, bp_: *Block, doreasm: bool) ?*Block {
    var bp = bp_;
    var proto: u8 = undefined;

    var offset = unfraglen(bp, &proto, false, doreasm);
    if (offset >= IP6HDR and proto == FH and doreasm) {
        bp = ip6reassemble(ip, offset, bp) orelse return null;
        offset = unfraglen(bp, &proto, false, false);
        if (proto == FH)
            offset = -1;
    }
    if (offset < IP6HDR) {
        ip.stats[ipdat.InHdrErrors] += 1;
        ip.stats[ipdat.InDiscards] += 1;
        freeblist(bp);
        return null;
    }
    if (proto == DOH or offset > IP6HDR)
        bp = procopts(bp);
    return bp;
}

/// returns length of "Unfragmentable part", i.e., sum of lengths of ipv6 hdr,
/// hop-by-hop & routing headers if present; *nexthdr is set to nexthdr value
/// of the last header in the "Unfragmentable part"; if setfh != 0, nexthdr
/// field of the last header in the "Unfragmentable part" is set to FH.
/// When the last header is a fragment header and popfh != 0 then set
/// the nexthdr value of the previous header to the nexthdr value of the
/// fragment header. returns -1 on error.
fn unfraglen(bp: *Block, nexthdr: *u8, setfh: bool, popfh: bool) i32 {
    const e = @intFromPtr(bp.wp);
    var p = bp.rp;
    var q = p + 6; // proto, = p+sizeof(Ip6hdr.vcf)+sizeof(Ip6hdr.ploadlen)
    nexthdr.* = q[0];
    p += IP6HDR;
    while (nexthdr.* == HBH or nexthdr.* == RH) {
        if (@intFromPtr(p) + 2 > e)
            return -1;
        q = p;
        nexthdr.* = q[0];
        p += (@as(usize, p[1]) + 1) * 8;
    }
    if (@intFromPtr(p) > e)
        return -1;
    if (nexthdr.* == FH) {
        if (@intFromPtr(p) + IP6FHDR > e or p[0] == FH)
            return -1;
        if (popfh)
            q[0] = p[0];
    } else if (setfh)
        q[0] = FH;
    return int(@intFromPtr(p) - @intFromPtr(bp.rp));
}

fn procopts(bp: *Block) *Block {
    return bp;
}

fn ip6reassemble(ip: *IP, uflen_: i32, bp_: *Block) ?*Block {
    const uflen: usize = @intCast(uflen_);

    //
    //  block lists are too hard, concatblock into a single block
    //
    var bp = concatblock(bp_);

    var ih: *Ip6hdr = @ptrCast(bp.rp);
    var fraghdr: *Fraghdr6 = @ptrCast(bp.rp + uflen);
    const id = nhgetl(&fraghdr.id);
    var offset: i32 = nhgets(&fraghdr.offsetRM);
    var fragsize: i32 = int(BLEN(bp)) - uflen_ - IP6FHDR;

    const src = ih.src;
    const dst = ih.dst;

    qlock(&ip.fraglock6);

    //
    //  find a reassembly queue for this fragment
    //
    var fnext: ?*Fragment6 = null;
    var fl = ip.flisthead6;
    while (fl) |x| : (fl = fnext) {
        fnext = x.next;
        if (x.id == id and ipcmp(&x.src, &src) == 0 and ipcmp(&x.dst, &dst) == 0)
            break;
        if (x.age < NOW()) {
            ip.stats[ipdat.ReasmTimeout] += 1;
            ipfragfree6(ip, x);
        }
    }

    //
    //  if this isn't a fragmented packet, accept it
    //  and get rid of any fragments that might go
    //  with it.
    //
    if ((offset & ~@as(i32, 6)) == 0) { // 1st frag is also last
        if (fl) |x| {
            ip.stats[ipdat.ReasmFails] += 1;
            ipfragfree6(ip, x);
        }
        qunlock(&ip.fraglock6);

        // get rid of frag header
        @memmove((bp.rp + IP6FHDR)[0..uflen], bp.rp[0..uflen]);
        bp.rp += IP6FHDR;
        ih = @ptrCast(bp.rp);
        hnputs(&ih.ploadlen, ushort(int(BLEN(bp)) - IP6HDR));

        return bp;
    }

    if (@intFromPtr(bp.base) + IPFRAGSZ > @intFromPtr(bp.rp)) {
        bp = padblock(bp, IPFRAGSZ);
        bp.rp += IPFRAGSZ;
    }

    var fp = fragof(bp);
    fp.foff = ushort(offset & ~@as(i32, 7));
    fp.flen = ushort(fragsize);

    // First fragment allocates a reassembly queue
    const f = fl orelse {
        const x = ipfragallo6(ip);
        x.id = id;
        x.src = src;
        x.dst = dst;

        x.blist = bp;

        ip.stats[ipdat.ReasmReqds] += 1;
        qunlock(&ip.fraglock6);

        return null;
    };

    //
    //  find the new fragment's position in the queue
    //
    var prev: ?*Block = null;
    var l: *?*Block = &f.blist;
    var bl = f.blist;
    while (bl) |x| {
        if (!(fp.foff > fragof(x).foff))
            break;
        prev = x;
        l = &x.next;
        bl = x.next;
    }

    // Check overlap of a previous fragment - trim away as necessary
    if (prev) |x| {
        const fq = fragof(x);
        const ovlap: i32 = @as(i32, fq.foff) + @as(i32, fq.flen) - @as(i32, fp.foff);
        if (ovlap > 0) {
            if (ovlap >= fp.flen) {
                qunlock(&ip.fraglock6);
                freeb(bp);
                return null;
            }
            fq.flen = ushort(@as(i32, fq.flen) - ovlap);
        }
    }

    // Link onto assembly queue
    bp.next = l.*;
    l.* = bp;

    // Check to see if succeeding segments overlap
    if (bp.next != null) {
        l = &bp.next;
        offset = @as(i32, fp.foff) + @as(i32, fp.flen);

        // Take completely covered segments out
        while (l.*) |x| {
            const fq = fragof(x);
            const ovlap: i32 = offset - @as(i32, fq.foff);
            if (ovlap <= 0)
                break;
            if (ovlap < fq.flen) {
                // move up ip and frag header
                const o: usize = @intCast(ovlap);
                const n = BLEN(x) - fq.flen;
                @memmove((x.rp + o)[0..n], x.rp[0..n]);
                x.rp += o;
                fq.flen = ushort(@as(i32, fq.flen) - ovlap);
                fq.foff = ushort(@as(i32, fq.foff) + ovlap);
                break;
            }
            l.* = x.next;
            x.next = null;
            freeb(x);
        }
    }

    //
    //  look for a complete packet.  if we get to a fragment
    //  with the trailing bit of fraghdr->offsetRM[1] set, we're done.
    //
    offset = 0;
    bl = f.blist;
    while (bl) |x| : ({
        bl = x.next;
        offset += fp.flen;
    }) {
        fp = fragof(x);
        if (fp.foff != offset)
            break;

        fraghdr = @ptrCast(x.wp - fp.flen - IP6FHDR);
        if (fraghdr.offsetRM[1] & 1 != 0)
            continue;

        const first = f.blist.?;
        var fq = fragof(first);

        // get rid of frag header in first fragment
        const n = BLEN(first) - fq.flen - IP6FHDR;
        @memmove((first.rp + IP6FHDR)[0..n], first.rp[0..n]);
        first.rp += IP6FHDR;
        var len: i32 = int(BLEN(first));

        //
        // Pullup all the fragment headers and
        // return a complete packet
        //
        var b = first.next;
        while (b) |y| : (b = y.next) {
            if (!(len < IP_MAX))
                break;
            fq = fragof(y);
            fragsize = fq.flen;
            y.rp = y.wp - @as(usize, @intCast(fragsize));
            len += fragsize;
        }

        if (len >= IP_MAX) {
            ipfragfree6(ip, f);
            ip.stats[ipdat.ReasmFails] += 1;
            qunlock(&ip.fraglock6);

            return null;
        }

        f.blist = null;
        ipfragfree6(ip, f);

        ih = @ptrCast(first.rp);
        hnputs(&ih.ploadlen, ushort(len - IP6HDR));

        ip.stats[ipdat.ReasmOKs] += 1;
        qunlock(&ip.fraglock6);

        return first;
    }
    qunlock(&ip.fraglock6);
    return null;
}
