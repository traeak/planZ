//! IP version 4: output with fragmentation, input with forwarding and
//! reassembly, the header checksum and the MIB counters of /net/ipifc
//! and friends.  Packets that are not version 4 are passed on to
//! ipv6.zig.
//! from 9/ip/ip.c
//!
//! DIFF:
//!   - waserror in ipoput4 protects two calls, the loopback bypass and
//!     ipifcoput; each handles its error where it is called: count it
//!     in ifc.outerr, unlock, return -1.
//!   - When ipifcoput fails for a fragment, the C returns without
//!     freeing the packet being fragmented (its comment, "bp is freed
//!     by m->bwrite()", holds only for the unfragmented paths).  Here
//!     the packet is freed, since ipoput4 owns bp in every case.
//!   - ipiput4 reads the addresses for its "bogus packet length" log
//!     line before trimblock, which frees the packet when it fails;
//!     the C formats them from the freed block.
//!   - The C's ints are i32 and its ulongs u32 with the same
//!     conversions between them; where a value is stored in a header
//!     or in an Ipfrag it is truncated as the C's assignment does.
//!     Block lengths (BLEN, blocklen) are brought to i32 by int().
//!   - The Ipfrag at the base of a block is reached through a pointer
//!     of alignment 1 (fragof).
//!   - The fragment free lists are slices from alloc.newslice; ipstats
//!     takes a slice and writes no NUL (see ipdat.zig, rule 3).
//!   - A nil dereference in C (a block list shorter than its header
//!     says, an empty fragment list in ipfragallo4) is a `.?` here.

const fmt = @import("fmt");
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
const ipv6 = @import("ipv6.zig");
const icmp = @import("icmp.zig");
const tcp = @import("tcp.zig");
const loopbackmedium = @import("loopbackmedium.zig");

const Block = ab.Block;
const BLEN = ab.BLEN;
const Bipck = ab.Bipck;
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
const Ip4hdr = ipdat.Ip4hdr;
const Ipfrag = ipdat.Ipfrag;
const Fragment4 = ipdat.Fragment4;
const Fragment6 = ipdat.Fragment6;

const IPaddrlen = ipdat.IPaddrlen;
const IPv4addrlen = ipdat.IPv4addrlen;
const V4 = ipdat.V4;
const IP_VER4 = ipdat.IP_VER4;
const IP_HLEN4 = ipdat.IP_HLEN4;
const IP_DF = ipdat.IP_DF;
const IP_MF = ipdat.IP_MF;
const IP_FO = ipdat.IP_FO;
const IP4HDR = ipdat.IP4HDR;
const IP_MAX = ipdat.IP_MAX;
const IPFRAGSZ = ipdat.IPFRAGSZ;
const MAXTTL = ipdat.MAXTTL;
const Logip = ipdat.Logip;
const Rifc = ipdat.Rifc;
const Runi = ipdat.Runi;
const Rbcast = ipdat.Rbcast;
const Rmulti = ipdat.Rmulti;
const Rtrans = ipdat.Rtrans;
const NOW = ipdat.NOW;

const netlog = netlog_.netlog;
const hnputs = ipaux.hnputs;
const nhgets = ipaux.nhgets;
const nhgetl = ipaux.nhgetl;
const v4tov6 = ipaux.v4tov6;

const statnames = blk: {
    var t: [ipdat.Nipstats][]const u8 = undefined;
    t[ipdat.Forwarding] = "Forwarding";
    t[ipdat.DefaultTTL] = "DefaultTTL";
    t[ipdat.InReceives] = "InReceives";
    t[ipdat.InHdrErrors] = "InHdrErrors";
    t[ipdat.InAddrErrors] = "InAddrErrors";
    t[ipdat.ForwDatagrams] = "ForwDatagrams";
    t[ipdat.InUnknownProtos] = "InUnknownProtos";
    t[ipdat.InDiscards] = "InDiscards";
    t[ipdat.InDelivers] = "InDelivers";
    t[ipdat.OutRequests] = "OutRequests";
    t[ipdat.OutDiscards] = "OutDiscards";
    t[ipdat.OutNoRoutes] = "OutNoRoutes";
    t[ipdat.ReasmTimeout] = "ReasmTimeout";
    t[ipdat.ReasmReqds] = "ReasmReqds";
    t[ipdat.ReasmOKs] = "ReasmOKs";
    t[ipdat.ReasmFails] = "ReasmFails";
    t[ipdat.FragOKs] = "FragOKs";
    t[ipdat.FragFails] = "FragFails";
    t[ipdat.FragCreates] = "FragCreates";
    break :blk t;
};

/// A length or size as the C's int.
fn int(n: usize) i32 {
    return @bitCast(@as(u32, @truncate(n)));
}

/// The C's conversion of an int to ulong.
fn ulong(n: i32) u32 {
    return @bitCast(n);
}

/// The C's conversion of an int to ushort or uchar.
fn ushort(n: i32) u16 {
    return @truncate(ulong(n));
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

fn initfrag(ip: *IP, n: usize) void {
    const fq4 = alloc.newslice(Fragment4, n) orelse p9.panic("initfrag", .{});
    for (fq4, 0..) |*fq, i| {
        fq.* = .{};
        fq.next = if (i + 1 < n) &fq4[i + 1] else null;
    }
    ip.fragfree4 = &fq4[0];

    const fq6 = alloc.newslice(Fragment6, n) orelse p9.panic("initfrag", .{});
    for (fq6, 0..) |*fq, i| {
        fq.* = .{};
        fq.next = if (i + 1 < n) &fq6[i + 1] else null;
    }
    ip.fragfree6 = &fq6[0];
}

pub fn ip_init(f: *Fs) void {
    const ip = alloc.snew(IP);
    ip.* = .{};
    ip.stats[ipdat.DefaultTTL] = MAXTTL;
    initfrag(ip, 100);
    f.ip = ip;

    ipv6.ip_init_6(f);
}

pub fn iprouting(f: *Fs, on: bool) void {
    const ip = f.ip.?;
    ip.iprouting = on;
    if (!ip.iprouting)
        ip.stats[ipdat.Forwarding] = 2
    else
        ip.stats[ipdat.Forwarding] = 1;
}

pub fn ipoput4(f: *Fs, bp: *Block, gating: ?*Ipifc, ttl: u32, tos: u32, rh: ?*Routehint) i32 {
    var rv: i32 = 0;

    const ip = f.ip.?;
    ip.stats[ipdat.OutRequests] += 1;

    free: {
        // Fill out the ip header
        const eh: *Ip4hdr = @ptrCast(bp.rp);
        if (BLEN(bp) < IP4HDR)
            p9.panic("ipoput4: assert failed, pc %#p", .{@returnAddress()});
        const len = int(blocklen(bp));
        if (len >= IP_MAX) {
            ip.stats[ipdat.OutDiscards] += 1;
            netlog(f, Logip, "%V -> %V: exceeded ip max size: %d\n", .{ ipaux.v4(&eh.src), ipaux.v4(&eh.dst), len });
            break :free;
        }

        const r: ?*Route = iproute.v4lookup(f, &eh.dst, &eh.src, rh);
        const ifc: *Ipifc = (if (r) |x| x.ifc else null) orelse {
            ip.stats[ipdat.OutNoRoutes] += 1;
            netlog(f, Logip, "%V -> %V: no interface\n", .{ ipaux.v4(&eh.src), ipaux.v4(&eh.dst) });
            rv = -1;
            break :free;
        };
        const rt = r.?;

        const gate: []const u8 = if (rt.type & (Rifc | Runi | Rbcast | Rmulti) != 0)
            &eh.dst
        else
            &rt.u.v4.gate;

        if (!canrlock(&ifc.rwlock)) {
            ip.stats[ipdat.OutDiscards] += 1;
            break :free;
        }
        raise: {
            const m = ifc.m orelse {
                rv = -1;
                break :raise;
            };
            if (ifc.ifcid != rt.ifcid) {
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
                eh.vihl = IP_VER4 | IP_HLEN4;
                eh.tos = @truncate(tos);

                // bypass for loopback
                if (rt.type & Runi != 0) {
                    eh.ttl = @truncate(ttl);
                    hnputs(&eh.length, ushort(len));
                    hnputs(&eh.id, ushort(incref(&ip.id4)));
                    eh.frag[0] = 0;
                    eh.frag[1] = 0;
                    eh.cksum[0] = 0;
                    eh.cksum[1] = 0;
                    hnputs(&eh.cksum, ipcsum(@ptrCast(eh)));
                    bp.flag |= Bipck;
                    loopbackmedium.loopbackmedium.bwrite.?(ifc, concatblock(bp), V4, gate, rh) catch {
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
                hnputs(&eh.length, ushort(len));
                if (gating == null) {
                    hnputs(&eh.id, ushort(incref(&ip.id4)));
                    eh.frag[0] = 0;
                    eh.frag[1] = 0;
                }
                eh.cksum[0] = 0;
                eh.cksum[1] = 0;
                hnputs(&eh.cksum, ipcsum(@ptrCast(eh)));
                ipifc.ipifcoput(ifc, bp, V4, gate, rh) catch {
                    ifc.outerr +%= 1;
                    runlock(&ifc.rwlock);
                    // bp is freed by m->bwrite() called from ipifcoput()
                    return -1;
                };
                runlock(&ifc.rwlock);
                return 0;
            }

            if (eh.frag[0] & (IP_DF >> 8) != 0) {
                ip.stats[ipdat.FragFails] += 1;
                ip.stats[ipdat.OutDiscards] += 1;
                icmp.icmpcantfrag(f, gating orelse ifc, bp, size(medialen));
                netlog(f, Logip, "%V -> %V: can't fragment with DF flag set\n", .{ ipaux.v4(&eh.src), ipaux.v4(&eh.dst) });
                break :raise;
            }

            const hlen: i32 = @as(i32, eh.vihl & 0xF) << 2;
            var seglen: i32 = (medialen -% hlen) & ~@as(i32, 7);
            if (seglen < 8) {
                ip.stats[ipdat.FragFails] += 1;
                ip.stats[ipdat.OutDiscards] += 1;
                netlog(f, Logip, "%V -> %V: can't fragment with seglen < 8\n", .{ ipaux.v4(&eh.src), ipaux.v4(&eh.dst) });
                break :raise;
            }

            var dlen: i32 = len - hlen;
            var xp: ?*Block = bp;
            const lid: i32 = if (gating != null)
                nhgets(&eh.id)
            else
                incref(&ip.id4);

            var offset: i32 = hlen;
            while (offset != 0 and offset >= int(BLEN(xp.?))) {
                offset -= int(BLEN(xp.?));
                xp = xp.?.next;
            }
            xp.?.rp += @as(usize, @intCast(offset));

            // The C's fragoff is a ulong: the sums and comparisons
            // with it are unsigned.  When gating it starts with the
            // flag bits of the packet above the offset, so a fragment
            // of a fragment keeps IP_MF.
            var fragoff: u32 = if (gating != null)
                @as(u32, nhgets(&eh.frag)) << 3
            else
                0;
            dlen = @bitCast(ulong(dlen) +% fragoff);
            while (fragoff < ulong(dlen)) : (fragoff +%= ulong(seglen)) {
                const nb = allocb(@intCast(hlen + seglen));
                const feh: *Ip4hdr = @ptrCast(nb.rp);

                const hl: usize = @intCast(hlen);
                @memcpy(nb.wp[0..hl], @as([*]const u8, @ptrCast(eh))[0..hl]);
                nb.wp += hl;

                if (fragoff +% ulong(seglen) >= ulong(dlen)) {
                    seglen = @bitCast(ulong(dlen) -% fragoff);
                    hnputs(&feh.frag, @truncate(fragoff >> 3));
                } else hnputs(&feh.frag, @truncate((fragoff >> 3) | IP_MF));

                hnputs(&feh.length, ushort(seglen + hlen));
                hnputs(&feh.id, ushort(lid));

                // Copy up the data area
                var chunk: i32 = seglen;
                while (chunk != 0) {
                    const x = xp orelse {
                        ip.stats[ipdat.OutDiscards] += 1;
                        ip.stats[ipdat.FragFails] += 1;
                        freeblist(nb);
                        netlog(f, Logip, "xp == nil: chunk %d\n", .{chunk});
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

                feh.cksum[0] = 0;
                feh.cksum[1] = 0;
                hnputs(&feh.cksum, ipcsum(@ptrCast(feh)));
                ipifc.ipifcoput(ifc, nb, V4, gate, rh) catch {
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

pub fn ipiput4(f: *Fs, ifc: *Ipifc, bp_: *Block) void {
    var bp = bp_;
    var v6dst: [IPaddrlen]u8 = undefined;

    if ((bp.rp[0] & 0xF0) != IP_VER4) {
        ipv6.ipiput6(f, ifc, bp);
        return;
    }

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
        var hl: i32 = undefined;
        if (BLEN(bp) < 64) {
            hl = int(blocklen(bp));
            if (hl < IP4HDR)
                hl = IP4HDR;
            if (hl > 64)
                hl = 64;
            bp = pullupblock(bp, @intCast(hl)) orelse return;
        }

        var h: *Ip4hdr = @ptrCast(bp.rp);
        hl = @as(i32, h.vihl & 0xF) << 2;
        if (hl < IP4HDR or hl > int(BLEN(bp))) {
            ip.stats[ipdat.InHdrErrors] += 1;
            netlog(f, Logip, "%V -> %V: bad ip header length: %d\n", .{ ipaux.v4(&h.src), ipaux.v4(&h.dst), hl });
            break :drop;
        }
        if ((bp.flag & Bipck) == 0 and ipcsum(bp.rp) != 0) {
            ip.stats[ipdat.InHdrErrors] += 1;
            netlog(f, Logip, "%V -> %V: bad ip header checksum\n", .{ ipaux.v4(&h.src), ipaux.v4(&h.dst) });
            break :drop;
        }
        var len: i32 = nhgets(&h.length);
        {
            // DIFF: copied before trimblock can free the packet
            const src = h.src;
            const dst = h.dst;
            const short = len < hl;
            const nbp: ?*Block = if (short) bp else trimblock(bp, 0, len);
            if (short or nbp == null) {
                ip.stats[ipdat.InHdrErrors] += 1;
                netlog(f, Logip, "%V -> %V: bogus packet length: %d\n", .{ ipaux.v4(&src), ipaux.v4(&dst), len });
                if (nbp != null)
                    break :drop;
                return;
            }
            bp = nbp.?;
        }
        h = @ptrCast(bp.rp);

        // route
        v4tov6(&v6dst, &h.dst);
        if (ipifc.ipforme(f, &v6dst) == 0) {
            var rh: Routehint = .{};

            if (!ip.iprouting)
                break :drop;

            // don't forward to source's network
            rh.r = null;
            rh.a = null;
            const r = iproute.v4lookup(f, &h.dst, &h.src, &rh) orelse {
                ip.stats[ipdat.OutDiscards] += 1;
                break :drop;
            };
            const nifc = r.ifc orelse {
                ip.stats[ipdat.OutDiscards] += 1;
                break :drop;
            };
            if (nifc == ifc and !ifc.reflect) {
                ip.stats[ipdat.OutDiscards] += 1;
                break :drop;
            }

            // don't forward if packet has timed out
            const hop: i32 = h.ttl;
            if (hop <= 1) {
                ip.stats[ipdat.InHdrErrors] += 1;
                icmp.icmpttlexceeded(f, ifc, bp);
                break :drop;
            }

            if (r.type & Rtrans != 0) {
                const p = devip.Fsrcvpcolx(f, h.proto) orelse {
                    ip.stats[ipdat.OutDiscards] += 1;
                    break :drop;
                };
                const forward = p.forward orelse {
                    ip.stats[ipdat.OutDiscards] += 1;
                    break :drop;
                };

                if (hl > IP4HDR) {
                    hl -= IP4HDR;
                    len -= hl;
                    bp.rp += @as(usize, @intCast(hl));
                    @memmove(bp.rp[0..IP4HDR], @as([*]u8, @ptrCast(h))[0..IP4HDR]);
                    h = @ptrCast(bp.rp);
                    h.vihl = IP_VER4 | IP_HLEN4;
                    hnputs(&h.length, ushort(len));
                }

                const frag = nhgets(&h.frag);
                if (frag & (IP_MF | IP_FO) != 0)
                    bp = ip4reassemble(ip, frag, bp) orelse return;

                bp = forward(p, bp, r) orelse return;
                h = @ptrCast(bp.rp);
            } else if (nifc.reassemble) {
                // reassemble as the interface expects it
                const frag = nhgets(&h.frag);
                if (frag & (IP_MF | IP_FO) != 0) {
                    bp = ip4reassemble(ip, frag, bp) orelse return;
                    h = @ptrCast(bp.rp);
                }
            }

            ip.stats[ipdat.ForwDatagrams] += 1;
            _ = ipoput4(f, bp, ifc, @intCast(hop - 1), h.tos, &rh);
            return;
        }

        // If this is not routed strip off the options
        if (hl > IP4HDR) {
            hl -= IP4HDR;
            len -= hl;
            bp.rp += @as(usize, @intCast(hl));
            @memmove(bp.rp[0..IP4HDR], @as([*]u8, @ptrCast(h))[0..IP4HDR]);
            h = @ptrCast(bp.rp);
            h.vihl = IP_VER4 | IP_HLEN4;
            hnputs(&h.length, ushort(len));
        }

        const frag = nhgets(&h.frag);
        if (frag & (IP_MF | IP_FO) != 0) {
            bp = ip4reassemble(ip, frag, bp) orelse return;
            h = @ptrCast(bp.rp);
        }

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

pub fn ipstats(f: *Fs, buf: []u8) usize {
    const ip = f.ip.?;
    var n: usize = 0;
    for (statnames, 0..) |name, i|
        n += fmt.snprint(buf[n..], "%s: %llud\n", .{ name, ip.stats[i] }).len;
    return n;
}

fn ip4reassemble(ip: *IP, offset_: i32, bp_: *Block) ?*Block {
    var offset = offset_;

    //
    //  block lists are too hard, concatblock into a single block
    //
    var bp = concatblock(bp_);

    var ih: *Ip4hdr = @ptrCast(bp.rp);
    const src = nhgetl(&ih.src);
    const dst = nhgetl(&ih.dst);
    const id = nhgets(&ih.id);
    var fragsize: i32 = int(BLEN(bp)) - (@as(i32, ih.vihl & 0xF) << 2);

    qlock(&ip.fraglock4);

    //
    //  find a reassembly queue for this fragment
    //
    var fnext: ?*Fragment4 = null;
    var fl = ip.flisthead4;
    while (fl) |x| : (fl = fnext) {
        fnext = x.next; // because ipfragfree4 changes the list
        if (x.id == id and x.src == src and x.dst == dst)
            break;
        if (x.age < NOW()) {
            ip.stats[ipdat.ReasmTimeout] += 1;
            ipfragfree4(ip, x);
        }
    }

    //
    //  if this isn't a fragmented packet, accept it
    //  and get rid of any fragments that might go
    //  with it.
    //
    if ((offset & (IP_MF | IP_FO)) == 0) {
        if (fl) |x| {
            ip.stats[ipdat.ReasmFails] += 1;
            ipfragfree4(ip, x);
        }
        qunlock(&ip.fraglock4);
        return bp;
    }

    if (@intFromPtr(bp.base) + IPFRAGSZ > @intFromPtr(bp.rp)) {
        bp = padblock(bp, IPFRAGSZ);
        bp.rp += IPFRAGSZ;
    }

    var fp = fragof(bp);
    fp.foff = ushort((offset & IP_FO) << 3);
    fp.flen = ushort(fragsize);

    // First fragment allocates a reassembly queue
    const f = fl orelse {
        const x = ipfragallo4(ip);
        x.id = id;
        x.src = src;
        x.dst = dst;

        x.blist = bp;

        ip.stats[ipdat.ReasmReqds] += 1;
        qunlock(&ip.fraglock4);

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
                qunlock(&ip.fraglock4);
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
                // move up ip header
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
    //  without IP_MF set, we're done.
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

        ih = @ptrCast(x.rp);
        if (ih.frag[0] & (IP_MF >> 8) != 0)
            continue;

        const first = f.blist.?;
        var len: i32 = int(BLEN(first));

        //
        // Pullup all the fragment headers and
        // return a complete packet
        //
        var b = first.next;
        while (b) |y| : (b = y.next) {
            if (!(len < IP_MAX))
                break;
            const fq = fragof(y);
            fragsize = fq.flen;
            y.rp = y.wp - @as(usize, @intCast(fragsize));
            len += fragsize;
        }

        if (len >= IP_MAX) {
            ipfragfree4(ip, f);
            ip.stats[ipdat.ReasmFails] += 1;
            qunlock(&ip.fraglock4);
            return null;
        }

        f.blist = null;
        ipfragfree4(ip, f);

        ih = @ptrCast(first.rp);
        ih.frag[0] = 0;
        ih.frag[1] = 0;
        hnputs(&ih.length, ushort(len));

        ip.stats[ipdat.ReasmOKs] += 1;
        qunlock(&ip.fraglock4);

        return first;
    }
    qunlock(&ip.fraglock4);
    return null;
}

/// ipfragfree4 - Free a list of fragments - assume hold fraglock4
fn ipfragfree4(ip: *IP, frag: *Fragment4) void {
    if (frag.blist != null)
        freeblist(frag.blist);
    frag.blist = null;
    frag.id = 0;
    frag.src = 0;
    frag.dst = 0;

    var l: *?*Fragment4 = &ip.flisthead4;
    var fl = l.*;
    while (fl) |x| : (fl = x.next) {
        if (x == frag) {
            l.* = frag.next;
            break;
        }
        l = &x.next;
    }

    frag.next = ip.fragfree4;
    ip.fragfree4 = frag;
}

/// ipfragallo4 - allocate a reassembly queue - assume hold fraglock4
fn ipfragallo4(ip: *IP) *Fragment4 {
    while (ip.fragfree4 == null) {
        // free last entry on fraglist
        var f = ip.flisthead4.?;
        while (f.next) |x|
            f = x;
        ipfragfree4(ip, f);
    }
    const f = ip.fragfree4.?;
    ip.fragfree4 = f.next;
    f.next = ip.flisthead4;
    ip.flisthead4 = f;
    f.age = NOW() +% 30000;

    return f;
}

pub fn ipcsum(addr_: [*]const u8) u16 {
    var addr = addr_;
    var sum: u32 = 0;
    var len: i32 = @as(i32, addr[0] & 0xf) << 2;

    while (len > 0) {
        sum +%= @as(u32, addr[0]) << 8 | addr[1];
        len -= 2;
        addr += 2;
    }

    sum = (sum & 0xffff) + (sum >> 16);
    sum = (sum & 0xffff) + (sum >> 16);

    return @truncate(sum ^ 0xffff);
}
