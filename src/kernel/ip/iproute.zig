//! The routing tables: a forest of balanced range trees per address
//! family, route lookup with hints, and the text of the iproute file.
//! from 9/ip/iproute.c
//!
//! DIFF:
//!   - There is no RouteTree: every Route is allocated and copied
//!     whole, with the v4 and v6 parts in the extern union `u`
//!     (ipdat.zig).  allocroute, routeadd and flushroutematch lose
//!     their size arithmetic.  The two free lists are kept.
//!   - The match functions of looknodematch take `?*const anyopaque`;
//!     matchtag's argument points to a slice (the tag) or is null.
//!   - Tags are 4 bytes that need not end in a NUL; tageq and tagcpy
//!     are the C's strncmp and strncpy over sizeof(tag).
//!   - rangecompare returns an enum; parseroutetype returns null for
//!     the C's -1.
//!   - Loops over `Route **h <= e` index the root table instead.
//!   - Output buffers hold no NUL (rule 3 of ipdat.zig): seprintroute
//!     may fill the buffer to its last byte, so routeread can return
//!     a.len bytes where the C returns at most n-1 and never stops
//!     its walk early.  The offsets of successive reads still add up.
//!   - hinted() is the test of a Routehint that v4lookup and v6lookup
//!     both spell out in C.
//!   - parseroute and routewrite return errors; routewrite frees the
//!     Cmdbuf with defer.

const std = @import("std");
const proc = @import("../port/proc.zig");
const alloc = @import("../port/alloc.zig");
const ql = @import("../port/qlock.zig");
const parse = @import("../port/parse.zig");
const p9 = @import("../port/print.zig");
const fmt = @import("fmt");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const ipifc = @import("ipifc.zig");
const devip = @import("devip.zig");

const Error = ipdat.Error;
const Chan = ipdat.Chan;
const RWLock = ipdat.RWLock;
const Fs = ipdat.Fs;
const Ipifc = ipdat.Ipifc;
const IPaux = ipdat.IPaux;
const Route = ipdat.Route;
const Routehint = ipdat.Routehint;

const IPaddrlen = ipdat.IPaddrlen;
const IPv4addrlen = ipdat.IPv4addrlen;
const IPv4off = ipdat.IPv4off;
const IPllen = ipdat.IPllen;
const Lroot = ipdat.Lroot;
const Rv4 = ipdat.Rv4;
const Rifc = ipdat.Rifc;
const Rptpt = ipdat.Rptpt;
const Runi = ipdat.Runi;
const Rbcast = ipdat.Rbcast;
const Rmulti = ipdat.Rmulti;
const Rproxy = ipdat.Rproxy;
const Rtrans = ipdat.Rtrans;
const Rsrc = ipdat.Rsrc;

const ipmove = ipdat.ipmove;
const ipcmp = ipdat.ipcmp;
const isv4 = ipaux.isv4;
const nhgetl = ipaux.nhgetl;
const hnputl = ipaux.hnputl;
const IPnoaddr = &ipaux.IPnoaddr;
const v4prefix = &ipaux.v4prefix;

const rlock = ql.rlock;
const runlock = ql.runlock;
const wlock = ql.wlock;
const wunlock = ql.wunlock;
const canrlock = ql.canrlock;

fn streq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// strncmp(a, b, sizeof(Route.tag)) == 0
fn tageq(a: []const u8, b: []const u8) bool {
    for (0..4) |i| {
        const ca: u8 = if (i < a.len) a[i] else 0;
        const cb: u8 = if (i < b.len) b[i] else 0;
        if (ca != cb)
            return false;
        if (ca == 0)
            break;
    }
    return true;
}

/// strncpy(dst, src, sizeof(Route.tag))
fn tagcpy(dst: *[4]u8, src: []const u8) void {
    var i: usize = 0;
    while (i < dst.len and i < src.len and src[i] != 0) : (i += 1)
        dst[i] = src[i];
    while (i < dst.len) : (i += 1)
        dst[i] = 0;
}

// these are used for all instances of IP
var v4freelist: ?*Route = null;
var v6freelist: ?*Route = null;
var routelock: RWLock = .{};
var v4routegeneration: u32 = 0;
var v6routegeneration: u32 = 0;

fn freeroute(r: *Route) void {
    r.ref = 0;
    r.left = null;
    r.right = null;
    const l = if (r.type & Rv4 != 0) &v4freelist else &v6freelist;
    r.mid = l.*;
    l.* = r;
}

fn allocroute(typ: u16) *Route {
    const l = if (typ & Rv4 != 0) &v4freelist else &v6freelist;

    const r = l.* orelse alloc.snew(Route);
    if (l.* != null)
        l.* = r.mid;
    r.* = .{};
    r.type = typ;
    r.ifc = null;
    r.ref = 1;

    return r;
}

fn addqueue(q: *?*Route, r_: ?*Route) void {
    const r = r_ orelse return;

    const l = allocroute(r.type);
    l.left = r;
    l.mid = q.*;
    q.* = l;
}

/// compare 2 v6 addresses
fn lcmp(a: *const [IPllen]u32, b: *const [IPllen]u32) i32 {
    for (a, b) |x, y| {
        if (x > y)
            return 1;
        if (x < y)
            return -1;
    }
    return 0;
}

/// compare 2 v4 or v6 ranges
const Range = enum {
    Rpreceeds, // a left of b
    Rfollows, // a right of b
    Requals, // a equals b
    Rcontains, // a contians b
    Roverlaps, // a overlaps b
};

fn rangecompare(a_: *const Route, b_: *const Route) Range {
    if (a_.type & Rv4 != 0) {
        const a = &a_.u.v4;
        const b = &b_.u.v4;
        if (a.endaddress < b.address)
            return .Rpreceeds;
        if (a.address > b.endaddress)
            return .Rfollows;
        if (a.address <= b.address and
            a.endaddress >= b.endaddress)
        {
            if (a.address == b.address and
                a.endaddress == b.endaddress)
            {
                if (a.source <= b.source and
                    a.endsource >= b.endsource)
                {
                    if (a.source == b.source and
                        a.endsource == b.endsource)
                        return .Requals;
                    return .Rcontains;
                }
                return .Roverlaps;
            }
            return .Rcontains;
        }
        return .Roverlaps;
    }

    const a = &a_.u.v6;
    const b = &b_.u.v6;
    if (lcmp(&a.endaddress, &b.address) < 0)
        return .Rpreceeds;
    if (lcmp(&a.address, &b.endaddress) > 0)
        return .Rfollows;
    if (lcmp(&a.address, &b.address) <= 0 and
        lcmp(&a.endaddress, &b.endaddress) >= 0)
    {
        if (lcmp(&a.address, &b.address) == 0 and
            lcmp(&a.endaddress, &b.endaddress) == 0)
        {
            if (lcmp(&a.source, &b.source) <= 0 and
                lcmp(&a.endsource, &b.endsource) >= 0)
            {
                if (lcmp(&a.source, &b.source) == 0 and
                    lcmp(&a.endsource, &b.endsource) == 0)
                    return .Requals;
                return .Rcontains;
            }
            return .Roverlaps;
        }
        return .Rcontains;
    }
    return .Roverlaps;
}

/// return 1 if a matches b, otherwise 0
fn matchroute(a: *const Route, b: *const Route) bool {
    if (a == b)
        return true;

    if ((a.type ^ b.type) & (Rifc | Runi | Rmulti | Rbcast) != 0)
        return false;

    if (a.type & Rv4 != 0) {
        if (!std.mem.eql(u8, &a.u.v4.gate, IPnoaddr[IPv4off..]) and
            !std.mem.eql(u8, &a.u.v4.gate, &b.u.v4.gate))
            return false;
    } else {
        if (ipcmp(&a.u.v6.gate, IPnoaddr) != 0 and
            ipcmp(&a.u.v6.gate, &b.u.v6.gate) != 0)
            return false;
    }

    if (a.ifc != b.ifc)
        return false;

    if (a.tag[0] != 0 and !tageq(&a.tag, &b.tag))
        return false;

    return true;
}

fn copygate(old: *Route, new: *const Route) void {
    old.type = new.type;
    old.ifc = new.ifc;
    old.ifcid = new.ifcid;
    if (new.type & Rv4 != 0)
        old.u.v4.gate = new.u.v4.gate
    else
        ipmove(&old.u.v6.gate, &new.u.v6.gate);
    tagcpy(&old.tag, &new.tag);
}

/// walk down a tree adding nodes back in
fn walkadd(f: *Fs, root: *?*Route, p: *Route) void {
    const l = p.left;
    const r = p.right;
    p.left = null;
    p.right = null;
    addnode(f, root, p);
    if (l) |x|
        walkadd(f, root, x);
    if (r) |x|
        walkadd(f, root, x);
}

/// calculate depth
fn calcd(p_: ?*Route) void {
    const p = p_ orelse return;
    var d: u8 = 0;
    if (p.left) |q|
        d = q.depth;
    if (p.right) |q| {
        if (q.depth > d)
            d = q.depth;
    }
    if (p.mid) |q| {
        if (q.depth > d)
            d = q.depth;
    }
    p.depth = d +% 1;
}

/// balance the tree at the current node
fn balancetree(cur: *?*Route) void {
    // if left and right are
    // too out of balance,
    // rotate tree node
    const p = cur.*.?;
    const l = p.left;
    const r = p.right;
    const dl: i32 = if (l) |x| x.depth else 0;
    const dr: i32 = if (r) |x| x.depth else 0;

    if (dl > dr + 1) {
        p.left = l.?.right;
        l.?.right = p;
        cur.* = l;
        calcd(p);
        calcd(l);
    } else if (dr > dl + 1) {
        p.right = r.?.left;
        r.?.left = p;
        cur.* = r;
        calcd(p);
        calcd(r);
    } else calcd(p);
}

/// add a new node to the tree
fn addnode(f: *Fs, cur: *?*Route, new: *Route) void {
    const p = cur.* orelse {
        cur.* = new;
        new.depth = 1;
        return;
    };

    switch (rangecompare(new, p)) {
        .Rpreceeds => addnode(f, &p.left, new),
        .Rfollows => addnode(f, &p.right, new),
        .Rcontains => {
            // if new node is superset
            // of tree node,
            // replace tree node and
            // queue tree node to be
            // merged into root.
            cur.* = new;
            new.depth = 1;
            addqueue(&f.queue, p);
        },
        .Requals => {
            // supercede the old entry if the old one isn't
            // a local interface.
            if ((p.type & Rifc) == 0)
                copygate(p, new)
            else if (new.type & Rifc != 0) {
                p.type = (p.type & ~(Rproxy | Rtrans)) | (new.type & (Rproxy | Rtrans));
                p.ref += 1;
            }
            freeroute(new);
        },
        .Roverlaps => addnode(f, &p.mid, new),
    }

    balancetree(cur);
}

/// find node matching r
fn looknode(cur_: *?*Route, r: *const Route) ?*?*Route {
    var cur = cur_;
    while (true) {
        const p = cur.* orelse return null;
        switch (rangecompare(r, p)) {
            .Rcontains => return null,
            .Rpreceeds => cur = &p.left,
            .Rfollows => cur = &p.right,
            .Roverlaps => cur = &p.mid,
            .Requals => {
                if ((p.type & Rifc) == 0 and !matchroute(r, p))
                    return null;
                return cur;
            },
        }
    }
}

const Match = *const fn (r: *Route, arg: ?*const anyopaque) bool;

fn looknodematch(r_: ?*Route, match: Match, arg: ?*const anyopaque) ?*Route {
    const r = r_ orelse return null;
    if (looknodematch(r.mid, match, arg)) |x|
        return x;
    if (looknodematch(r.left, match, arg)) |x|
        return x;
    if (looknodematch(r.right, match, arg)) |x|
        return x;
    if (match(r, arg))
        return r;
    return null;
}

/// arg is a `*const []const u8`, the tag, or null.
fn matchtag(r: *Route, arg: ?*const anyopaque) bool {
    if (r.type & Rifc != 0)
        return false;
    const tag: *const []const u8 = @ptrCast(@alignCast(arg orelse return true));
    return tageq(tag.*, &r.tag);
}

/// arg is the Ipifc.
fn matchifc(r: *Route, arg: ?*const anyopaque) bool {
    const ifc: ?*const Ipifc = @ptrCast(@alignCast(arg));

    return r.ifc == ifc;
}

fn V4H(a: u32) usize {
    return (a & 0x07ffffff) >> (32 - Lroot - 5);
}

fn V6H(a: *const [IPllen]u32) usize {
    return ((a[0] & 0x80000000) >> (32 - Lroot)) | (a[(IPllen / 2) - 1] & (0xffff >> (16 - Lroot)));
}

fn routeadd(f: *Fs, r: *const Route) void {
    const v4 = r.type & Rv4 != 0;
    const root: []?*Route = if (v4) &f.v4root else &f.v6root;
    var h = if (v4) V4H(r.u.v4.address) else V6H(&r.u.v6.address);
    const e = if (v4) V4H(r.u.v4.endaddress) else V6H(&r.u.v6.endaddress);

    while (h <= e) : (h += 1) {
        const p = allocroute(r.type);

        p.ifc = r.ifc;
        p.ifcid = r.ifcid;

        if (v4)
            p.u.v4 = r.u.v4
        else
            p.u.v6 = r.u.v6;

        p.tag = r.tag;

        addnode(f, &root[h], p);
        while (f.queue) |x| {
            f.queue = x.mid;
            const q = x.left.?;
            freeroute(x);
            walkadd(f, &root[h], q);
        }
    }

    if (v4)
        v4routegeneration +%= 1
    else
        v6routegeneration +%= 1;
}

fn routedel(f: *Fs, r: *const Route) void {
    const v4 = r.type & Rv4 != 0;
    const root: []?*Route = if (v4) &f.v4root else &f.v6root;
    var h = if (v4) V4H(r.u.v4.address) else V6H(&r.u.v6.address);
    const e = if (v4) V4H(r.u.v4.endaddress) else V6H(&r.u.v6.endaddress);

    while (h <= e) : (h += 1) {
        const l = looknode(&root[h], r) orelse continue;
        const p = l.*.?;
        p.ref -= 1;
        if (p.ref != 0)
            continue;
        l.* = null;
        addqueue(&f.queue, p.left);
        addqueue(&f.queue, p.mid);
        addqueue(&f.queue, p.right);
        freeroute(p);

        while (f.queue) |x| {
            f.queue = x.mid;
            const q = x.left.?;
            freeroute(x);
            walkadd(f, &root[h], q);
        }
    }

    if (v4)
        v4routegeneration +%= 1
    else
        v6routegeneration +%= 1;
}

fn mkroute(
    a: *const [IPaddrlen]u8,
    mask: *const [IPaddrlen]u8,
    s: *const [IPaddrlen]u8,
    smask: *const [IPaddrlen]u8,
    gate: *const [IPaddrlen]u8,
    typ: u16,
    ifc: *Ipifc,
    ifcid: u8,
    tag: ?[]const u8,
) Route {
    var r: Route = .{};

    r.type = typ;
    r.ifc = ifc;
    r.ifcid = ifcid;

    if (typ & Rv4 != 0) {
        var x = nhgetl(a[IPv4off..]);
        var y = nhgetl(mask[IPv4off..]);
        r.u.v4.address = x & y;
        r.u.v4.endaddress = x | ~y;

        x = nhgetl(s[IPv4off..]);
        y = nhgetl(smask[IPv4off..]);
        if (y != 0)
            r.type |= Rsrc;
        r.u.v4.source = x & y;
        r.u.v4.endsource = x | ~y;

        r.u.v4.gate = gate[IPv4off..].*;
    } else {
        for (0..IPllen) |h| {
            var x = nhgetl(a[4 * h ..]);
            var y = nhgetl(mask[4 * h ..]);
            r.u.v6.address[h] = x & y;
            r.u.v6.endaddress[h] = x | ~y;

            x = nhgetl(s[4 * h ..]);
            y = nhgetl(smask[4 * h ..]);
            if (y != 0)
                r.type |= Rsrc;
            r.u.v6.source[h] = x & y;
            r.u.v6.endsource[h] = x | ~y;
        }

        r.u.v6.gate = gate.*;
    }

    if (tag) |t|
        tagcpy(&r.tag, t);

    return r;
}

pub fn addroute(
    f: *Fs,
    a: *const [IPaddrlen]u8,
    mask: *const [IPaddrlen]u8,
    s: *const [IPaddrlen]u8,
    smask: *const [IPaddrlen]u8,
    gate: *const [IPaddrlen]u8,
    typ: u16,
    ifc: *Ipifc,
    tag: ?[]const u8,
) void {
    const r = mkroute(a, mask, s, smask, gate, typ, ifc, ifc.ifcid, tag);
    wlock(&routelock);
    routeadd(f, &r);
    wunlock(&routelock);
}

pub fn delroute(
    f: *Fs,
    a: *const [IPaddrlen]u8,
    mask: *const [IPaddrlen]u8,
    s: *const [IPaddrlen]u8,
    smask: *const [IPaddrlen]u8,
    gate: *const [IPaddrlen]u8,
    typ: u16,
    ifc: *Ipifc,
    tag: ?[]const u8,
) void {
    const r = mkroute(a, mask, s, smask, gate, typ, ifc, ifc.ifcid, tag);
    wlock(&routelock);
    routedel(f, &r);
    wunlock(&routelock);
}

fn flushroutematch(f: *Fs, match: Match, arg: ?*const anyopaque) void {
    var r: Route = undefined;

    wlock(&routelock);
    for (&f.v4root) |*h| {
        while (looknodematch(h.*, match, arg)) |x| {
            r = x.*;
            routedel(f, &r);
        }
    }
    for (&f.v6root) |*h| {
        while (looknodematch(h.*, match, arg)) |x| {
            r = x.*;
            routedel(f, &r);
        }
    }
    wunlock(&routelock);
}

/// flushrouteifc:
///   remove all routes associated with ifc (wlock()'ed).
pub fn flushrouteifc(f: *Fs, ifc: *Ipifc) void {
    flushroutematch(f, matchifc, ifc);
    ifc.ifcid +%= 1; // invalidate all routes
}

/// The route a hint holds, if it is still good.
fn hinted(rh_: ?*Routehint, generation: u32) ?*Route {
    const rh = rh_ orelse return null;
    if (rh.rgen != generation)
        return null;
    const q = rh.r orelse return null;
    const ifc = q.ifc orelse return null;
    if (q.ifcid == ifc.ifcid and q.ref > 0)
        return q;
    return null;
}

// v4lookup, v6lookup:
//  lookup a route to destination address a from source address s
//  and return the route. returns nil if no route was found.
//  an optional Routehint can be passed in rh to cache the lookup.
//
//  for v4lookup, addresses are in 4 byte format.
pub fn v4lookup(f: *Fs, a: *const [IPv4addrlen]u8, s: *const [IPv4addrlen]u8, rh: ?*Routehint) ?*Route {
    if (hinted(rh, v4routegeneration)) |q|
        return q;

    var q: ?*Route = null;
    const la = nhgetl(a);
    const ls = nhgetl(s);

    rlock(&routelock);
    var p_ = f.v4root[V4H(la)];
    while (p_) |p| {
        if (la < p.u.v4.address) {
            p_ = p.left;
            continue;
        }
        if (la > p.u.v4.endaddress) {
            p_ = p.right;
            continue;
        }
        if (p.type & Rsrc != 0) {
            if (ls < p.u.v4.source) {
                p_ = p.mid;
                continue;
            }
            if (ls > p.u.v4.endsource) {
                p_ = p.mid;
                continue;
            }
        }
        q = p;
        p_ = p.mid;
    }
    if (rh) |h| {
        h.r = q;
        h.rgen = v4routegeneration;
    }
    runlock(&routelock);
    return q;
}

pub fn v6lookup(f: *Fs, a: *const [IPaddrlen]u8, s: *const [IPaddrlen]u8, rh: ?*Routehint) ?*Route {
    var la: [IPllen]u32 = undefined;
    var ls: [IPllen]u32 = undefined;

    if (isv4(s)) {
        if (isv4(a))
            return v4lookup(f, a[IPv4off..], s[IPv4off..], rh);
        return null;
    }

    if (hinted(rh, v6routegeneration)) |q|
        return q;

    var q: ?*Route = null;
    for (0..IPllen) |h| {
        la[h] = nhgetl(a[4 * h ..]);
        ls[h] = nhgetl(s[4 * h ..]);
    }

    rlock(&routelock);
    var p_ = f.v6root[V6H(&la)];
    next: while (p_) |p| {
        for (la, p.u.v6.address) |x, y| {
            if (x == y)
                continue;
            if (x < y) {
                p_ = p.left;
                continue :next;
            }
            break;
        }
        for (la, p.u.v6.endaddress) |x, y| {
            if (x == y)
                continue;
            if (x > y) {
                p_ = p.right;
                continue :next;
            }
            break;
        }
        if (p.type & Rsrc != 0) {
            for (ls, p.u.v6.source) |x, y| {
                if (x == y)
                    continue;
                if (x < y) {
                    p_ = p.mid;
                    continue :next;
                }
                break;
            }
            for (ls, p.u.v6.endsource) |x, y| {
                if (x == y)
                    continue;
                if (x > y) {
                    p_ = p.mid;
                    continue :next;
                }
                break;
            }
        }
        q = p;
        p_ = p.mid;
    }
    if (rh) |h| {
        h.r = q;
        h.rgen = v6routegeneration;
    }
    runlock(&routelock);
    return q;
}

// v4source, v6source:
//  lookup a route to destination address a and also find
//  a suitable source address s on the outgoing interface.
//  return the route on success or nil when no route
//  was found.
//
//  for v4source, addresses are in 4 byte format.
pub fn v4source(f: *Fs, a: *const [IPv4addrlen]u8, s: *[IPv4addrlen]u8) ?*Route {
    var src: [IPv4addrlen]u8 = @splat(0);

    const la = nhgetl(a);
    again: while (true) {
        var q: ?*Route = null;
        rlock(&routelock);
        var p_ = f.v4root[V4H(la)];
        while (p_) |p| {
            if (la < p.u.v4.address) {
                p_ = p.left;
                continue;
            }
            if (la > p.u.v4.endaddress) {
                p_ = p.right;
                continue;
            }
            const ifc = p.ifc.?;
            if (!canrlock(&ifc.rwlock)) {
                const gen = v4routegeneration;
                runlock(&routelock);
                rlock(&ifc.rwlock);
                rlock(&routelock);
                if (v4routegeneration != gen) {
                    runlock(&routelock);
                    runlock(&ifc.rwlock);
                    continue :again;
                }
            }
            var splen: usize = 0;
            if (p.type & Rsrc != 0) {
                // calculate local prefix length for source specific routes
                var x = ~(p.u.v4.endsource ^ p.u.v4.source);
                while (x & 0x80000000 != 0) : (x <<= 1)
                    splen += 1;
                hnputl(&src, p.u.v4.source);
            }
            if (!ipifc.ipv4local(ifc, &src, splen, if ((p.type & (Rifc | Rbcast | Rmulti | Rv4)) == Rv4) &p.u.v4.gate else a)) {
                runlock(&ifc.rwlock);
                p_ = p.mid;
                continue;
            }
            s.* = src;
            runlock(&ifc.rwlock);
            q = p;
            p_ = p.mid;
        }
        runlock(&routelock);
        return q;
    }
}

pub fn v6source(f: *Fs, a: *const [IPaddrlen]u8, s: *[IPaddrlen]u8) ?*Route {
    var src: [IPaddrlen]u8 = @splat(0);
    var la: [IPllen]u32 = undefined;

    for (0..IPllen) |h|
        la[h] = nhgetl(a[4 * h ..]);
    again: while (true) {
        var q: ?*Route = null;
        rlock(&routelock);
        var p_ = f.v6root[V6H(&la)];
        next: while (p_) |p| {
            for (la, p.u.v6.address) |x, y| {
                if (x == y)
                    continue;
                if (x < y) {
                    p_ = p.left;
                    continue :next;
                }
                break;
            }
            for (la, p.u.v6.endaddress) |x, y| {
                if (x == y)
                    continue;
                if (x > y) {
                    p_ = p.right;
                    continue :next;
                }
                break;
            }
            const ifc = p.ifc.?;
            if (!canrlock(&ifc.rwlock)) {
                const gen = v6routegeneration;
                runlock(&routelock);
                rlock(&ifc.rwlock);
                rlock(&routelock);
                if (v6routegeneration != gen) {
                    runlock(&routelock);
                    runlock(&ifc.rwlock);
                    continue :again;
                }
            }
            var splen: usize = 0;
            if (p.type & Rsrc != 0) {
                // calculate local prefix length for source specific routes
                for (0..IPllen) |h| {
                    hnputl(src[4 * h ..], p.u.v6.source[h]);
                    var x = ~(p.u.v6.endsource[h] ^ p.u.v6.source[h]);
                    if (x != ~@as(u32, 0)) {
                        while (x & 0x80000000 != 0) : (x <<= 1)
                            splen += 1;
                        break;
                    }
                    splen += 32;
                }
            }
            if (!ipifc.ipv6local(ifc, &src, splen, a)) {
                runlock(&ifc.rwlock);
                p_ = p.mid;
                continue;
            }
            ipmove(s, &src);
            runlock(&ifc.rwlock);
            q = p;
            p_ = p.mid;
        }
        runlock(&routelock);
        return q;
    }
}

fn parseroutetype(p: []const u8) ?u16 {
    var typ: u16 = 0;
    if (p.len == 0)
        return null;
    switch (p[0]) {
        '4' => typ |= Rv4,
        '6' => {},
        else => return null,
    }
    var i: usize = 1;
    while (true) : (i += 1) {
        const c: u8 = if (i < p.len) p[i] else 0;
        switch (c) {
            'i' => {
                typ ^= Rifc;
                if ((typ & Rifc) != Rifc) return null;
            },
            'u' => {
                typ ^= Runi;
                if ((typ & (Runi | Rbcast | Rmulti)) != Runi) return null;
            },
            'b' => {
                typ ^= Rbcast;
                if ((typ & (Runi | Rbcast | Rmulti)) != Rbcast) return null;
            },
            'm' => {
                typ ^= Rmulti;
                if ((typ & (Runi | Rbcast | Rmulti)) != Rmulti) return null;
            },
            'p' => {
                typ ^= Rptpt;
                if ((typ & Rptpt) != Rptpt) return null;
            },
            'y' => {
                typ ^= Rproxy;
                if ((typ & Rproxy) != Rproxy) return null;
            },
            't' => {
                typ ^= Rtrans;
                if ((typ & Rtrans) != Rtrans) return null;
            },
            0 => return typ,
            else => return null,
        }
    }
}

pub fn routetype(typ: u16, p: *[8]u8) []const u8 {
    var n: usize = 0;

    if (typ & Rv4 != 0)
        p[n] = '4'
    else
        p[n] = '6';
    n += 1;

    if (typ & Rifc != 0) {
        p[n] = 'i';
        n += 1;
    }

    if (typ & Runi != 0) {
        p[n] = 'u';
        n += 1;
    } else if (typ & Rbcast != 0) {
        p[n] = 'b';
        n += 1;
    } else if (typ & Rmulti != 0) {
        p[n] = 'm';
        n += 1;
    }

    if (typ & Rptpt != 0) {
        p[n] = 'p';
        n += 1;
    }

    if (typ & Rproxy != 0) {
        p[n] = 'y';
        n += 1;
    }

    if (typ & Rtrans != 0) {
        p[n] = 't';
        n += 1;
    }

    p[n] = 0;
    return p[0..n];
}

fn convroute(
    r: *const Route,
    addr: *[IPaddrlen]u8,
    mask: *[IPaddrlen]u8,
    src: *[IPaddrlen]u8,
    smask: *[IPaddrlen]u8,
    gate: *[IPaddrlen]u8,
) void {
    if (r.type & Rv4 != 0) {
        const v4 = &r.u.v4;
        @memcpy(addr[0..IPv4off], v4prefix[0..IPv4off]);
        hnputl(addr[IPv4off..], v4.address);

        @memset(mask[0..IPv4off], 0xff);
        hnputl(mask[IPv4off..], ~(v4.endaddress ^ v4.address));

        @memcpy(src[0..IPv4off], v4prefix[0..IPv4off]);
        hnputl(src[IPv4off..], v4.source);

        @memset(smask[0..IPv4off], 0xff);
        hnputl(smask[IPv4off..], ~(v4.endsource ^ v4.source));

        @memcpy(gate[0..IPv4off], v4prefix[0..IPv4off]);
        gate[IPv4off..].* = v4.gate;
    } else {
        const v6 = &r.u.v6;
        for (0..IPllen) |i| {
            hnputl(addr[4 * i ..], v6.address[i]);
            hnputl(mask[4 * i ..], ~(v6.endaddress[i] ^ v6.address[i]));
            hnputl(src[4 * i ..], v6.source[i]);
            hnputl(smask[4 * i ..], ~(v6.endsource[i] ^ v6.source[i]));
        }
        gate.* = v6.gate;
    }
}

/// Returns the number of bytes written to p.
fn seprintroute(p: []u8, r: *const Route) usize {
    var addr: [IPaddrlen]u8 = undefined;
    var mask: [IPaddrlen]u8 = undefined;
    var src: [IPaddrlen]u8 = undefined;
    var smask: [IPaddrlen]u8 = undefined;
    var gate: [IPaddrlen]u8 = undefined;
    var typ: [8]u8 = undefined;
    var ifbuf: [3]u8 = undefined; // the C's char[4] less its NUL

    convroute(r, &addr, &mask, &src, &smask, &gate);
    const t = routetype(r.type, &typ);
    const ifs = fmt.snprint(&ifbuf, "%d", .{r.ifc.?.conv.?.x});
    return fmt.snprint(p, "%-15I %-4M %-15I %-4s %4.4s %3s %-15I %-4M\n", .{
        ipaux.ip(&addr),            ipaux.mask(&mask), ipaux.ip(&gate), t,
        std.mem.sliceTo(&r.tag, 0), ifs,               ipaux.ip(&src),  ipaux.mask(&smask),
    }).len;
}

const Routewalk = struct {
    o: i64,
    h: usize,
    buf: []u8, // the C's p at the start, to e
    p: usize, // index into buf
};

fn rr1(rw: *Routewalk, r: *const Route) bool {
    const n: i64 = @intCast(seprintroute(rw.buf[rw.p..], r));
    if (rw.o < 0) {
        if (n > -rw.o) {
            const skip: usize = @intCast(-rw.o);
            const keep: usize = @intCast(n + rw.o);
            std.mem.copyForwards(u8, rw.buf[rw.p..][0..keep], rw.buf[rw.p + skip ..][0..keep]);
            rw.p += keep;
        }
        rw.o += n;
    } else rw.p += @intCast(n);
    return rw.p < rw.buf.len;
}

fn rr(r_: ?*const Route, rw: *Routewalk) bool {
    const r = r_ orelse return true;
    if (!rr(r.left, rw))
        return false;
    const h = if (r.type & Rv4 != 0)
        V4H(r.u.v4.address)
    else
        V6H(&r.u.v6.address);
    if (h == rw.h) {
        if (!rr1(rw, r))
            return false;
    }
    if (!rr(r.mid, rw))
        return false;
    return rr(r.right, rw);
}

pub fn routeread(f: *Fs, p: []u8, offset: usize) usize {
    if (offset > std.math.maxInt(i32))
        return 0;
    var rw: Routewalk = .{
        .buf = p,
        .p = 0,
        .o = -@as(i64, @intCast(offset)),
        .h = 0,
    };

    rlock(&routelock);
    if (rw.p < rw.buf.len) {
        rw.h = 0;
        while (rw.h < f.v4root.len) : (rw.h += 1) {
            if (!rr(f.v4root[rw.h], &rw))
                break;
        }
    }
    if (rw.p < rw.buf.len) {
        rw.h = 0;
        while (rw.h < f.v6root.len) : (rw.h += 1) {
            if (!rr(f.v6root[rw.h], &rw))
                break;
        }
    }
    runlock(&routelock);

    return rw.p;
}

//      4       add     addr    mask    gate
//      5       add     addr    mask    gate                    ifc
//      6       add     addr    mask    gate                            src     smask
//      7       add     addr    mask    gate                    ifc     src     smask
//      8       add     addr    mask    gate    type            ifc     src     smask
//      9       add     addr    mask    gate    type    tag     ifc     src     smask
//
//      3       del     addr    mask
//      4       del     addr    mask    gate
//      5       del     addr    mask                                    src     smask
//      6       del     addr    mask    gate                            src     smask
//      7       del     addr    mask    gate                    ifc     src     smask
//      8       del     addr    mask    gate    type            ifc     src     smask
//      9       del     addr    mask    gate    type    tag     ifc     src     smask
fn parseroute(f: *Fs, argv: []const []const u8) Error!Route {
    var addr: [IPaddrlen]u8 = undefined;
    var mask: [IPaddrlen]u8 = undefined;
    var src: [IPaddrlen]u8 = undefined;
    var smask: [IPaddrlen]u8 = undefined;
    var gate: [IPaddrlen]u8 = undefined;
    const argc = argv.len;

    var typ: u16 = 0;
    var tag: ?[]const u8 = null;
    var ifcstr: ?[]const u8 = null;
    ipmove(&gate, IPnoaddr);
    ipmove(&src, IPnoaddr);
    ipmove(&smask, IPnoaddr);

    if (argc < 3)
        return error.Ebadctl;

    if (ipaux.parseipandmask(&addr, &mask, argv[1], argv[2]) == -1)
        return error.Ebadip;

    const add = streq(argv[0], "add");
    if (add or (argc > 3 and argc != 5)) {
        if (argc < 4)
            return error.Ebadctl;
        if (ipaux.parseip(&gate, argv[3]) == -1)
            return error.Ebadip;
    }

    if (argc > 4 and (!add or argc != 5)) {
        if (ipaux.parseipandmask(&src, &smask, argv[argc - 2], argv[argc - 1]) == -1)
            return error.Ebadip;
    }

    if (argc == 5 and add)
        ifcstr = argv[4]
    else if (argc > 6)
        ifcstr = argv[argc - 3];

    if (argc > 7)
        typ = parseroutetype(argv[4]) orelse return error.Ebadctl;
    if (isv4(&addr))
        typ |= Rv4;

    if (argc > 8)
        tag = argv[5];
    if (argc > 9)
        return error.Ebadctl;

    if (typ & Rv4 != 0) {
        if (ipcmp(&smask, IPnoaddr) != 0 and !isv4(&src))
            return error.Ebadip;
        if (ipcmp(&gate, IPnoaddr) != 0 and !isv4(&gate))
            return error.Ebadip;
    } else {
        if (isv4(&addr))
            return error.Ebadip;
    }

    const ifc = (if (ifcstr != null and !streq(ifcstr.?, "-"))
        ipifc.findipifcstr(f, ifcstr.?)
    else
        ipifc.findipifc(f, &src, &gate, typ)) orelse
        return proc.errorf("interface not found", .{});
    const ifcid = ifc.ifcid;
    runlock(&ifc.rwlock);

    return mkroute(&addr, &mask, &src, &smask, &gate, typ, ifc, ifcid, tag);
}

pub fn routewrite(f: *Fs, c: *Chan, p: []const u8) Error!usize {
    const cb = try parse.parsecmd(p);
    defer alloc.free(cb);
    const argv: []const []const u8 = cb.f[0..cb.nf];

    if (cb.nf < 1)
        return proc.errorf("short control request", .{});
    if (streq(argv[0], "flush")) {
        flushroutematch(f, matchtag, if (cb.nf < 2) null else @ptrCast(&argv[1]));
    } else if (streq(argv[0], "add") or
        streq(argv[0], "del") or
        streq(argv[0], "remove"))
    {
        var r = try parseroute(f, argv);
        if (r.tag[0] == 0) {
            const a: *IPaux = @ptrCast(@alignCast(c.aux.?));
            tagcpy(&r.tag, &a.tag);
        }
        wlock(&routelock);
        if (streq(argv[0], "add"))
            routeadd(f, &r)
        else
            routedel(f, &r);
        wunlock(&routelock);
    } else if (streq(argv[0], "tag")) {
        if (cb.nf < 2)
            return error.Ebadarg;
        const a: *IPaux = @ptrCast(@alignCast(c.aux.?));
        c.aux = devip.newipaux(a.owner, argv[1]);
        alloc.free(a);
    } else return error.Ebadctl;

    return p.len;
}
