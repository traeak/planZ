//! address resolution tables: the cache that maps IP addresses to
//! medium (MAC) addresses for ARP and for IPv6 neighbour discovery, the
//! process that retransmits neighbour solicitations and times out
//! unanswered entries, and the text of the arp file.
//! from 9/ip/arp.c
//!
//! DIFF:
//!   - Arp, Arpent, NHASH, NCACHE and hashipa are in ipdat.zig (see
//!     there).
//!   - Signatures follow the rules of ipdat.zig: addresses whose length
//!     depends on the version are slices, a mac and its length are one
//!     slice, arpread and arpwrite take slices and return counts,
//!     arpforme returns route type bits as u16.
//!   - Times are u32 and their differences are taken with wrapping
//!     subtraction, which is what the C's ulong arithmetic does.
//!   - arpenter: the waserror around ipifcoput is a catch.  ipifcoput
//!     gets the caller's `ip` slice for V4, the same four bytes as the
//!     C's v6ip+IPv4off.
//!   - ndpsendsol and drop: icmpns6, icmpnohost and icmpnohost6 cannot
//!     fail here, so their waserror is gone.
//!   - arpwrite: the request is not copied and cut up with NULs, the
//!     fields are sub-slices of at most the first 255 bytes (up to a
//!     NUL, as strncpy would stop there).  getfields is a private copy
//!     of libc's with mflag set and " " as the delimiters.  Ebadarp is
//!     raised with errorf.
//!   - arpread formats into up.genbuf as the C does but takes the line
//!     from the slice snprint returns.
//!   - rxmitproc: the waserror that ends the process is the `catch
//!     break` of its two sleeps.

const std = @import("std");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const proc = @import("../port/proc.zig");
const ql = @import("../port/qlock.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const p9 = @import("../port/print.zig");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const ipifc = @import("ipifc.zig");
const iproute = @import("iproute.zig");
const icmp = @import("icmp.zig");
const icmp6 = @import("icmp6.zig");

const Error = proc.Error;
const Block = ab.Block;
const Fs = ipdat.Fs;
const Arp = ipdat.Arp;
const Arpent = ipdat.Arpent;
const Ipifc = ipdat.Ipifc;
const Iplifc = ipdat.Iplifc;
const Medium = ipdat.Medium;
const Route = ipdat.Route;
const Routehint = ipdat.Routehint;
const Ip4hdr = ipdat.Ip4hdr;
const Ip6hdr = ipdat.Ip6hdr;

const IPaddrlen = ipdat.IPaddrlen;
const IPv4addrlen = ipdat.IPv4addrlen;
const IPv4off = ipdat.IPv4off;
const MAClen = ipdat.MAClen;
const V4 = ipdat.V4;
const V6 = ipdat.V6;
const NCACHE = ipdat.NCACHE;
const RETRANS_TIMER = ipdat.RETRANS_TIMER;
const NOW = ipdat.NOW;
const hashipa = ipdat.hashipa;
const ipmove = ipdat.ipmove;
const ipcmp = ipdat.ipcmp;

const AOK = 1;
const AWAIT = 2;

const MAXAGE_TIMER = 15 * 60 * 1000;

const arpstate = [_][]const u8{
    "UNUSED",
    "OK",
    "WAIT",
};

fn Ebadarp() Error {
    return proc.errorf("bad arp", .{});
}

fn assert(ok: bool) void {
    if (!ok) p9.panic("arp: assert failed, pc %#p", .{@returnAddress()});
}

pub fn arpinit(f: *Fs) void {
    const arp = alloc.snew(Arp);
    arp.* = .{};
    f.arp = arp;
    arp.f = f;
    arp.rxmt[0] = null;
    arp.rxmt[1] = null;
    arp.dropf = null;
    arp.dropl = null;
    proc.kproc("rxmitproc", rxmitproc, arp);
}

fn freeblistchain(bp_: ?*Block) void {
    var bp = bp_;
    while (bp) |b| {
        const next = b.list;
        qio.freeblist(b);
        bp = next;
    }
}

/// take out of re-transmit chain
fn rxmtunchain(arp: *Arp, a: *Arpent) *?*Arpent {
    var l: *?*Arpent = &arp.rxmt[@intFromBool(ipaux.isv4(&a.ip))];
    while (l.*) |x| : (l = &x.nextrxt) {
        if (x == a) {
            l.* = a.nextrxt;
            break;
        }
    }
    a.nextrxt = null;
    return l;
}

fn cleanarpent(arp: *Arp, a: *Arpent) void {
    // take out of current chain
    var l: *?*Arpent = &arp.hash[hashipa(&a.ip)];
    while (l.*) |x| : (l = &x.hash) {
        if (x == a) {
            l.* = a.hash;
            break;
        }
    }
    a.hash = null;

    // remove from retransmit / timout chain
    _ = rxmtunchain(arp, a);

    // queue packets for icmp unreachable for rxmitproc later on, w/o arp lock
    if (a.hold) |bp| {
        if (arp.dropf == null)
            arp.dropf = bp
        else
            arp.dropl.?.list = bp;
        arp.dropl = a.last;
        if (bp == arp.dropf)
            _ = proc.wakeup(&arp.rxmtq);
    }
    a.hold = null;
    a.last = null;

    a.ifc = null;
    a.ifcid = 0;

    a.state = 0;
    a.rxtsrem = 0;

    a.utime = 0;
    a.ctime = 0;
}

/// create a new arp entry for an ip address on ifc.
fn newarpent(arp: *Arp, ip: *const [IPaddrlen]u8, ifc: *Ipifc) *Arpent {
    // find oldest entry
    var a: *Arpent = &arp.cache[0];
    var t: u32 = a.utime;
    var i: usize = 1;
    while (t > 0 and i < NCACHE) : (i += 1) {
        const f = &arp.cache[i];
        if (f.utime < t) {
            t = f.utime;
            a = f;
        }
    }
    cleanarpent(arp, a);

    ipmove(&a.ip, ip);
    a.ifc = ifc;
    a.ifcid = ifc.ifcid;

    // insert into new chain
    const l = &arp.hash[hashipa(ip)];
    a.hash = l.*;
    l.* = a;

    return a;
}

fn arplookup(arp: *Arp, ifc: *Ipifc, ip: *const [IPaddrlen]u8) ?*Arpent {
    var a = arp.hash[hashipa(ip)];
    while (a) |x| : (a = x.hash) {
        if (x.ifc == ifc and x.ifcid == ifc.ifcid and ipcmp(ip, &x.ip) == 0)
            return x;
    }
    return null;
}

fn arphit(a: *Arpent, mac: []u8, rh: ?*Routehint) bool {
    if (a.state == AOK) {
        @memcpy(mac, a.mac[0..mac.len]);
        a.utime = NOW();
        if (a.utime -% a.ctime < MAXAGE_TIMER) {
            if (rh) |h|
                h.a = a;
            return true;
        }
    }
    return false;
}

/// fill in the media address if we have it.  Otherwise return an
/// Arpent that represents the state of the address resolution FSM
/// for ip.  Add the packet to be sent onto the list of packets
/// waiting for ip->mac to be resolved.
pub fn arpget(arp: *Arp, bp: ?*Block, version: u8, ifc: *Ipifc, ip_: []const u8, mac_: []u8, rh: ?*Routehint) ?*Arpent {
    var v6ip: [IPaddrlen]u8 = undefined;

    if (version == V4)
        ipaux.v4tov6(&v6ip, ip_[0..IPv4addrlen])
    else
        v6ip = ip_[0..IPaddrlen].*;
    const ip = &v6ip;
    const mac = mac_[0..ifc.m.?.maclen];

    if (rh) |h| {
        if (h.a) |a| {
            if (a.ifc == ifc and
                a.ifcid == ifc.ifcid and
                ipcmp(ip, &a.ip) == 0 and
                arphit(a, mac, null))
                return null;
        }
    }

    ql.rlock(&arp.rwlock);
    if (arplookup(arp, ifc, ip)) |a| {
        if (arphit(a, mac, rh)) {
            ql.runlock(&arp.rwlock);
            return null;
        }
    }
    if (rh) |h|
        h.a = null;
    ql.runlock(&arp.rwlock);

    ql.wlock(&arp.rwlock);
    const a = blk: {
        if (arplookup(arp, ifc, ip)) |x| {
            if (arphit(x, mac, rh)) {
                ql.wunlock(&arp.rwlock);
                return null;
            }
            break :blk x;
        }
        break :blk newarpent(arp, ip, ifc);
    };
    a.state = AWAIT;
    a.utime = NOW();
    if (bp) |b| {
        // needs to be a single block
        assert(b.list == null);

        if (a.hold == null)
            a.hold = b
        else
            a.last.?.list = b;
        a.last = b;
    }
    return a; // return with arp locked
}

/// continue address resolution for the entry,
/// schedule it on the retransmit / timeout chains
/// and unlock the arp cache.
pub fn arpcontinue(arp: *Arp, a: *Arpent) void {
    // remove all but the last message
    while (a.hold) |bp| {
        if (bp == a.last)
            break;
        a.hold = bp.list;
        qio.freeblist(bp);
    }

    // try to keep it around for a second more
    a.utime = NOW();
    a.ctime = a.utime;

    // put on end of re-transmit / timeout chain
    var l = rxmtunchain(arp, a);
    while (l.*) |x|
        l = &x.nextrxt;
    l.* = a;

    if (l == &arp.rxmt[0] or l == &arp.rxmt[1])
        _ = proc.wakeup(&arp.rxmtq);

    ql.wunlock(&arp.rwlock);
}

/// called with arp locked
pub fn arprelease(arp: *Arp, _: *Arpent) void {
    ql.wunlock(&arp.rwlock);
}

/// Copy out the mac address from the Arpent.  Return the
/// first block waiting to get sent to this mac address.
///
/// called with arp locked
pub fn arpresolve(arp: *Arp, a: *Arpent, mac: []const u8, rh: ?*Routehint) ?*Block {
    const maclen = a.ifc.?.m.?.maclen;
    @memcpy(a.mac[0..maclen], mac[0..maclen]);
    if (a.state == AWAIT) {
        _ = rxmtunchain(arp, a);
        a.rxtsrem = 0;
    }
    const bp = a.hold;
    a.hold = null;
    a.last = null;
    a.utime = NOW();
    a.ctime = a.utime;
    a.state = AOK;
    if (rh) |h|
        h.a = a;
    ql.wunlock(&arp.rwlock);

    if (bp) |b| {
        freeblistchain(b.list);
        b.list = null;
    }
    return bp;
}

pub fn arpenter(fs: *Fs, version: u8, ip_: []const u8, mac: []const u8, ia: []const u8, ifc: *Ipifc, refresh: bool) i32 {
    var rh: Routehint = .{};
    var v6ip: [IPaddrlen]u8 = undefined;

    const m = ifc.m orelse return -1;
    if (mac.len < m.maclen or m.maclen == 0)
        return -1;

    rh.r = null;
    rh.a = null;
    var r: ?*Route = undefined;
    switch (version) {
        V4 => {
            r = iproute.v4lookup(fs, ip_[0..IPv4addrlen], ia[0..IPv4addrlen], &rh);
            ipaux.v4tov6(&v6ip, ip_[0..IPv4addrlen]);
        },
        V6 => {
            r = iproute.v6lookup(fs, ip_[0..IPaddrlen], ia[0..IPaddrlen], &rh);
            v6ip = ip_[0..IPaddrlen].*;
        },
        else => p9.panic("arpenter: version %d", .{version}),
    }
    const ip = &v6ip;

    const rt = r orelse return -1;
    if (rt.ifc != ifc or (rt.type & (ipdat.Rbcast | ipdat.Rmulti)) != 0)
        return -1;

    const arp = fs.arp.?;

    ql.wlock(&arp.rwlock);
    const a = arplookup(arp, ifc, ip) orelse blk: {
        if (refresh) {
            ql.wunlock(&arp.rwlock);
            return 0;
        }
        break :blk newarpent(arp, ip, ifc);
    };
    var bp = a.hold;
    a.hold = null;
    a.last = null;
    _ = arpresolve(arp, a, mac, &rh); // unlocks arp
    // DIFF: the C's ip += IPv4off for V4 is the caller's ip_ here.
    const oip: []const u8 = if (version == V4) ip_[0..IPv4addrlen] else ip[0..];
    while (bp) |b| {
        const next = b.list;
        b.list = null;
        ipifc.ipifcoput(ifc, b, version, oip, &rh) catch {
            freeblistchain(next);
            break;
        };
        bp = next;
    }
    return 1;
}

/// arpforme() checks if we should respond to arp/ndp on a specific interface.
///
/// returns Runi if targ is a non-tentative local address on ifc.
/// returns Rproxy if we have a proxy route for targ to another interface.
pub fn arpforme(fs: *Fs, version: u8, targ: []const u8, src: []const u8, ifc: *Ipifc) u16 {
    var ipv6: [IPaddrlen]u8 = undefined;

    if (version == V4)
        ipaux.v4tov6(&ipv6, targ[0..IPv4addrlen])
    else
        ipv6 = targ[0..IPaddrlen].*;
    if (ipifc.iplocalonifc(ifc, &ipv6)) |lifc| {
        if (lifc.tentative)
            return 0;
        return ipdat.Runi;
    }
    const r = (if (version == V4)
        iproute.v4lookup(fs, targ[0..IPv4addrlen], src[0..IPv4addrlen], null)
    else
        iproute.v6lookup(fs, &ipv6, src[0..IPaddrlen], null)) orelse return 0;
    if (r.ifc == ifc and r.ifcid == ifc.ifcid)
        return 0;
    return r.type & ipdat.Rproxy;
}

/// DIFF: libc's getfields(str, args, nelem(args), 1, " "): fields are
/// separated by runs of spaces, and the last of args takes the rest of
/// the string.  With no field at all args[0] is the empty string.
fn getfields(str: []const u8, args: [][]const u8) usize {
    var narg: usize = 0;
    var start: usize = 0;
    var intok = false;

    args[0] = str[0..0];
    for (str, 0..) |c, i| {
        if (c == ' ') {
            if (narg >= args.len)
                break;
            if (intok)
                args[narg - 1] = str[start..i];
            intok = false;
            start = i + 1;
        } else {
            if (!intok)
                narg += 1;
            intok = true;
        }
    }
    if (intok)
        args[narg - 1] = str[start..];
    return narg;
}

pub fn arpwrite(fs: *Fs, s: []const u8) Error!usize {
    var fields: [5][]const u8 = @splat("");
    var ip: [IPaddrlen]u8 = undefined;
    var ia: [IPaddrlen]u8 = undefined;
    var mac: [MAClen]u8 = undefined;

    const arp = fs.arp.?;

    var len = s.len;
    if (len == 0)
        return Ebadarp();
    if (len >= 256)
        len = 256 - 1;
    var buf: []const u8 = std.mem.sliceTo(s[0..len], 0);
    if (len > 0 and buf.len == len and buf[len - 1] == '\n')
        buf = buf[0 .. len - 1];

    var n = getfields(buf, &fields);
    const f = &fields;
    if (std.mem.eql(u8, f[0], "flush")) {
        ql.wlock(&arp.rwlock);
        for (&arp.cache) |*a| {
            a.hash = null;
            a.nextrxt = null;
            a.ifc = null;
            a.ifcid = 0;
            a.state = 0;
            a.rxtsrem = 0;
            a.ctime = 0;
            a.utime = 0;
            freeblistchain(a.hold);
            a.hold = null;
            a.last = null;
        }
        @memset(&arp.hash, null);
        freeblistchain(arp.dropf);
        arp.dropf = null;
        arp.dropl = null;
        arp.rxmt[0] = null;
        arp.rxmt[1] = null;
        ql.wunlock(&arp.rwlock);
    } else if (std.mem.eql(u8, f[0], "add")) {
        switch (n) {
            3 => {
                if (ipaux.parseip(&ip, f[1]) == -1)
                    return error.Ebadip;
                n = ipaux.parsemac(&mac, f[2]);
                if (n == 0)
                    return Ebadarp();
                ipifc.findlocalip(fs, &ia, &ip);
            },
            4 => {
                const m = ipifc.ipfindmedium(f[1]) orelse return Ebadarp();
                if (m.maclen == 0)
                    return Ebadarp();
                if (ipaux.parseip(&ip, f[2]) == -1)
                    return error.Ebadip;
                n = ipaux.parsemac(&mac, f[3]);
                if (n != m.maclen)
                    return Ebadarp();
                ipifc.findlocalip(fs, &ia, &ip);
            },
            5 => {
                const m = ipifc.ipfindmedium(f[1]) orelse return Ebadarp();
                if (m.maclen == 0)
                    return Ebadarp();
                if (ipaux.parseip(&ip, f[2]) == -1)
                    return error.Ebadip;
                n = ipaux.parsemac(&mac, f[3]);
                if (n != m.maclen)
                    return Ebadarp();
                if (ipaux.parseip(&ia, f[4]) == -1)
                    return error.Ebadip;
            },
            else => return error.Ebadarg,
        }
        const ifc = ipifc.findipifc(fs, &ia, &ia, ipdat.Runi) orelse
            return proc.errorf("no interface", .{});
        if (!ipifc.ipv6local(ifc, &ia, 0, &ip) or arpenter(fs, V6, &ip, mac[0..n], &ia, ifc, false) < 0) {
            ql.runlock(&ifc.rwlock);
            return proc.errorf("destination unreachable", .{});
        }
        ql.runlock(&ifc.rwlock);
    } else if (std.mem.eql(u8, f[0], "del")) {
        if (n != 2)
            return error.Ebadarg;
        if (ipaux.parseip(&ip, f[1]) == -1)
            return error.Ebadip;
        ql.wlock(&arp.rwlock);
        var a = arp.hash[hashipa(&ip)];
        while (a) |e| {
            const x = e.hash;
            if (ipcmp(&ip, &e.ip) == 0)
                cleanarpent(arp, e);
            a = x;
        }
        ql.wunlock(&arp.rwlock);
    } else if (std.mem.eql(u8, f[0], "garp")) {
        if (n != 2)
            return error.Ebadarg;
        if (ipaux.parseip(&ip, f[1]) == -1)
            return error.Ebadip;

        const ifc = ipifc.findipifc(fs, &ip, &ip, ipdat.Runi) orelse
            return proc.errorf("no interface", .{});
        defer ql.runlock(&ifc.rwlock);
        if (ifc.m) |m| {
            if (m.areg) |areg| {
                if (ipifc.iplocalonifc(ifc, &ip)) |lifc|
                    try areg(fs, ifc, lifc, &ip);
            }
        }
    } else return Ebadarp();

    return len;
}

fn convmac(p: []u8, mac: []const u8) []u8 {
    const hex = "0123456789abcdef";
    for (mac, 0..) |b, i| {
        p[2 * i] = hex[b >> 4];
        p[2 * i + 1] = hex[b & 15];
    }
    return p[0 .. 2 * mac.len];
}

pub fn arpread(arp: *Arp, s: []u8, offset: usize) usize {
    var macbuf: [2 * MAClen]u8 = undefined;
    var ip: [IPaddrlen]u8 = undefined;
    var ia: [IPaddrlen]u8 = undefined;
    const up = arch.up().?;

    var p: usize = 0;
    var len = s.len;
    var o: i64 = -@as(i64, @intCast(offset));
    for (&arp.cache) |*a| {
        if (len == 0)
            break;
        if (a.state == 0)
            continue;
        const ifc = a.ifc orelse continue;

        ql.rlock(&ifc.rwlock);
        ql.rlock(&arp.rwlock);
        ipmove(&ip, &a.ip);
        if (ifc.m == null or a.state == 0 or a.ifc != ifc or a.ifcid != ifc.ifcid or !ipifc.ipv6local(ifc, &ia, 0, &ip)) {
            ql.runlock(&arp.rwlock);
            ql.runlock(&ifc.rwlock);
            continue;
        }
        const mname = ifc.m.?.name;
        const state = arpstate[a.state];
        const mac = convmac(&macbuf, a.mac[0..ifc.m.?.maclen]);
        ql.runlock(&arp.rwlock);
        ql.runlock(&ifc.rwlock);

        const line = fmt.snprint(&up.genbuf, "%-6.6s %-4.4s %-40.40I %-16.16s %I\n", .{ mname, state, ipaux.ip(&ip), mac, ipaux.ip(&ia) });
        const n = line.len;
        o += @intCast(n);
        if (o <= 0)
            continue;
        if (n > len)
            break;
        @memcpy(s[p..][0..n], line);
        len -= n;
        p += n;
    }

    return p;
}

pub fn ndpsendsol(f: *Fs, a: *Arpent) void {
    const ifc = a.ifc.?;
    var targ: [IPaddrlen]u8 = undefined;
    var src: [IPaddrlen]u8 = undefined;

    if (a.rxtsrem == 0)
        a.rxtsrem = ipdat.MAX_MULTICAST_SOLICIT
    else
        a.rxtsrem -= 1;

    // try to use source address of original packet
    ipmove(&targ, &a.ip);
    send: {
        if (a.last) |last| {
            const h: *Ip6hdr = @ptrCast(last.rp);
            ipmove(&src, &h.src);
            arpcontinue(f.arp.?, a);
            if (arpforme(f, V6, &src, &targ, ifc) != 0)
                break :send;
        } else {
            arpcontinue(f.arp.?, a);
        }
        if (!ipifc.ipv6local(ifc, &src, 0, &targ))
            return;
    }
    icmp6.icmpns6(f, &src, ipdat.SRC_UNI, &targ, ipdat.TARG_MULTI, ifc.mac[0..ifc.m.?.maclen]);
}

fn rxmt(arp: *Arp) ?*Block {
    ql.wlock(&arp.rwlock);

    // retransmit ipv6 solicitations
    while (arp.rxmt[0]) |a| {
        if (!(NOW() -% a.ctime > 3 * RETRANS_TIMER / 4))
            break;
        if (a.rxtsrem > 0) {
            if (a.ifc) |ifc| {
                if (ql.canrlock(&ifc.rwlock)) {
                    if (a.ifcid == ifc.ifcid) {
                        ndpsendsol(arp.f.?, a); // unlocks arp
                        ql.runlock(&ifc.rwlock);

                        ql.wlock(&arp.rwlock);
                        continue;
                    }
                    ql.runlock(&ifc.rwlock);
                }
            }
        }
        cleanarpent(arp, a);
    }

    // timeout waiting ipv4 arp entries
    while (arp.rxmt[1]) |a| {
        if (!(NOW() -% a.ctime > 3 * RETRANS_TIMER))
            break;
        cleanarpent(arp, a);
    }

    const bp = arp.dropf;
    arp.dropf = null;
    arp.dropl = null;

    ql.wunlock(&arp.rwlock);

    return bp;
}

fn drop(f: *Fs, bp_: ?*Block) void {
    var rh: Routehint = .{};

    var bp = bp_;
    while (bp) |b| {
        const next = b.list;
        b.list = null;

        rh.r = null;
        rh.a = null;
        const isv4 = (b.rp[0] & 0xF0) == ipdat.IP_VER4;
        const r = if (isv4) blk: {
            const h: *Ip4hdr = @ptrCast(b.rp);
            break :blk iproute.v4lookup(f, &h.src, &h.dst, &rh);
        } else blk: {
            const h: *Ip6hdr = @ptrCast(b.rp);
            break :blk iproute.v6lookup(f, &h.src, &h.dst, &rh);
        };
        if (r) |rt| {
            if (rt.ifc) |ifc| {
                if (ql.canrlock(&ifc.rwlock)) {
                    if (ifc.ifcid == rt.ifcid) {
                        if (isv4)
                            icmp.icmpnohost(f, ifc, b, &rh)
                        else
                            icmp6.icmpnohost6(f, ifc, b, &rh);
                    }
                    ql.runlock(&ifc.rwlock);
                }
            }
        }
        qio.freeblist(b);
        bp = next;
    }
}

fn rxready(v: ?*anyopaque) bool {
    const arp: *Arp = @ptrCast(@alignCast(v.?));

    return arp.rxmt[0] != null or arp.rxmt[1] != null or arp.dropf != null;
}

fn rxmitproc(v: ?*anyopaque) void {
    const arp: *Arp = @ptrCast(@alignCast(v.?));

    arp.rxmitp = arch.up();
    while (true) {
        proc.sleep(&arp.rxmtq, rxready, v) catch break;
        drop(arp.f.?, rxmt(arp));
        proc.tsleep(&arp.rxmtq, proc.return0, null, RETRANS_TIMER / 4) catch break;
    }
    arp.rxmitp = null;
    proc.pexit("hangup", true);
}
