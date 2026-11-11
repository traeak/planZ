//! Network interfaces: the three-level directory (name/clone, addr,
//! stats, ifstats, N/data, N/ctl, N/type ...) and the bookkeeping that
//! devether and the other multiplexed network devices share.
//! from 9/port/netif.c and 9/port/netif.h
//!
//! DIFF:
//!   - Errors are Zig error returns.  The waserror sites that only
//!     unlock or free became defer; the ones that swallow an error from
//!     a driver routine (the statistics refresh in netifread, the
//!     promiscuous, scanbs and multicast calls in netifclose) became
//!     `catch`.
//!   - A Netif is not a QLock by embedding: the lock is the field
//!     `qlock`.  A device that "is a" Netif in C (Ether) has a field of
//!     type Netif instead.
//!   - Netif.f is a slice of nfile entries.  A Netfile's queue `in` is
//!     never null.  The char flags of a Netfile are bool, except scan,
//!     which is the scanning interval.
//!   - The driver routines take the C's arguments but return errors:
//!     promiscuous(arg, on), multicast(arg, addr, add) and
//!     scanbs(arg, secs) return Error!void.  ifstat(arg, buf) formats
//!     into buf and returns how many bytes it wrote, where the C takes
//!     a start and an end pointer and returns the new start.  The
//!     statistics file calls it with an empty buffer just to make the
//!     driver refresh its counters, as the C does with ifstat(arg, p, p).
//!   - A Devgen is handed a slice of Dirtab, and the C passes the Netif
//!     there with a cast.  Here the Netif travels as the pointer of an
//!     empty slice (niftab, tabnif), so nothing can index it.
//!   - netifwrite returns null where the C returns -1 for a control
//!     message it does not know.
//!   - netifopen checks the open mode before it counts the open, so a
//!     bad mode does not leave the Netfile in use as it does in the C.
//!   - netifclose: the C walks the multicast addresses of the file being
//!     closed with a bit index that it never advances, so it tests bit 0
//!     for every address and drops references the file does not hold.
//!     The index advances here.  (Bug fixed on purpose.)
//!   - netifread takes its offset as u32, the C's ulong.
//!   - The Dir for netifwstat is on the stack and only its strings are
//!     allocated.
//!   - hnput*/nhget* take slices and use the first 8, 4 or 2 bytes.
//!   - parseaddr returns false where the C returns -1.
//!   - strtoul and atoi (libc) and exhausted (9/port/proc.c) are here
//!     until they have a common home; strtoul returns the value and the
//!     number of bytes used, the C's end pointer.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const xalloc = @import("xalloc.zig");
const ab = @import("allocb.zig");
const qio = @import("qio.zig");
const proc = @import("proc.zig");
const devcons = @import("devcons.zig");
const devmod = @import("dev.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const devdir = devmod.devdir;
const readstr = devcons.readstr;
const readnum = devcons.readnum;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const QLock = portdat.QLock;
const Queue = qio.Queue;
const Block = ab.Block;
const Dirtab = devmod.Dirtab;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DEVDOTDOT = portdat.DEVDOTDOT;
const COPEN = portdat.COPEN;
const KNAMELEN = portdat.KNAMELEN;
const NUMSIZE = portdat.NUMSIZE;
const READSTR = portdat.READSTR;

pub const Nmaxaddr = 64;
pub const Nmhash = 31;

pub const Ncloneqid = 1;
pub const Naddrqid = 2;
pub const N2ndqid = 3;
pub const N3rdqid = 4;
pub const Ndataqid = 5;
pub const Nctlqid = 6;
pub const Nstatqid = 7;
pub const Ntypeqid = 8;
pub const Nifstatqid = 9;

//
//  Macros to manage Qid's used for multiplexed devices
//
pub fn NETTYPE(x: u64) u32 {
    return @as(u32, @truncate(x)) & 0x1f;
}

pub fn NETID(x: u64) u32 {
    return @as(u32, @truncate(x)) >> 5;
}

pub fn NETQID(i: u32, t: u32) u64 {
    return (i << 5) | t;
}

/// one per multiplexed connection
pub const Netfile = struct {
    inuse: i32 = 0,
    mode: u32 = 0,
    owner: [KNAMELEN]u8 = @splat(0),

    type: i32 = 0, // multiplexor type

    prom: bool = false, // promiscuous mode
    scan: u8 = 0, // base station scanning interval
    bridge: bool = false, // bridge mode
    bypass: bool = false, // bypass transmission
    headersonly: bool = false, // headers only - no data

    maddr: [8]u8 = @splat(0), // bitmask of multicast addresses requested
    nmaddr: i32 = 0, // number of multicast addresses

    in: *Queue, // input buffer
};

/// a network address
pub const Netaddr = struct {
    next: ?*Netaddr = null, // allocation chain
    hnext: ?*Netaddr = null,
    addr: [Nmaxaddr]u8 = @splat(0),
    ref: i32 = 0,
};

/// a network interface
pub const Netif = struct {
    qlock: QLock = .{},

    // multiplexing
    name: [KNAMELEN]u8 = @splat(0), // for top level directory
    nfile: usize = 0, // max number of Netfiles
    f: []?*Netfile = &.{},
    bypass: ?*Netfile = null,

    // about net
    limit: i32 = 0, // flow control
    alen: usize = 0, // address length
    mbps: i32 = 0, // megabits per sec
    link: i32 = 0, // link status
    addr: [Nmaxaddr]u8 = @splat(0),
    bcast: [Nmaxaddr]u8 = @splat(0),
    maddr: ?*Netaddr = null, // known multicast addresses
    nmaddr: i32 = 0, // number of known multicast addresses
    mhash: [Nmhash]?*Netaddr = @splat(null), // hash table of multicast addresses
    prom: i32 = 0, // number of promiscuous opens
    scan: i32 = 0, // number of base station scanners
    all: i32 = 0, // number of -1 multiplexors

    // statistics
    misses: i32 = 0,
    inpackets: u64 = 0,
    outpackets: u64 = 0,
    crcs: i32 = 0, // input crc errors
    oerrs: i32 = 0, // output errors
    frames: i32 = 0, // framing errors
    overflows: i32 = 0, // packet overflows
    buffs: i32 = 0, // buffering errors
    soverflows: i32 = 0, // software overflow

    // routines for touching the hardware
    arg: ?*anyopaque = null,
    promiscuous: ?*const fn (arg: ?*anyopaque, on: bool) Error!void = null,
    multicast: ?*const fn (arg: ?*anyopaque, addr: []const u8, add: bool) Error!void = null,
    scanbs: ?*const fn (arg: ?*anyopaque, secs: u32) Error!void = null, // scan for base stations
    ifstat: ?*const fn (arg: ?*anyopaque, buf: []u8) Error!usize = null,
};

//
//  Ethernet specific
//
pub const Eaddrlen = 6;
pub const ETHERMINTU = 60; // minimum transmit size
pub const ETHERMAXTU = 1514; // maximum transmit size
pub const ETHERHDRSIZE = 14; // size of an ethernet header

// ethernet packet types
pub const ETARP = 0x0806;
pub const ETIP4 = 0x0800;
pub const ETIP6 = 0x86DD;

pub const Etherpkt = extern struct {
    d: [Eaddrlen]u8,
    s: [Eaddrlen]u8,
    type: [2]u8,
    data: [1500]u8,
};

/// The interface's name as a string.
pub fn nifname(nif: *const Netif) []const u8 {
    return std.mem.sliceTo(&nif.name, 0);
}

/// A Netif dressed as the Dirtab argument of the dev* routines, and
/// back (see DIFF).
fn niftab(nif: *Netif) []const Dirtab {
    comptime std.debug.assert(@alignOf(Netif) >= @alignOf(Dirtab));
    return @as([*]const Dirtab, @ptrCast(nif))[0..0];
}

fn tabnif(tab: []const Dirtab) *Netif {
    return @ptrCast(@alignCast(@constCast(tab.ptr)));
}

/// libc's strtoul for an unsigned type T: the value, and how many bytes
/// of s were used (0 when there are no digits).  A base of 0 means C
/// syntax: 0x for hexadecimal, a leading 0 for octal.
pub fn strtou(comptime T: type, s: []const u8, base_: u32) struct { v: T, n: usize } {
    const S = struct {
        fn at(str: []const u8, i: usize) u8 {
            return if (i < str.len) str[i] else 0;
        }
    };
    const at = S.at;
    var base = base_;
    var p: usize = 0;
    var neg = false;
    var ndig: usize = 0;
    var ovfl = false;
    var n: T = 0;

    // White space
    while (true) : (p += 1) {
        switch (at(s, p)) {
            ' ', '\t', '\n', 0x0c, '\r', 0x0b => continue,
            else => {},
        }
        break;
    }

    // Sign
    if (at(s, p) == '-' or at(s, p) == '+') {
        neg = at(s, p) == '-';
        p += 1;
    }

    // Base
    if (base == 0) {
        if (at(s, p) != '0')
            base = 10
        else {
            base = 8;
            if (at(s, p + 1) == 'x' or at(s, p + 1) == 'X')
                base = 16;
        }
    }
    if (base >= 2 and base <= 36) {
        if (base == 16 and at(s, p) == '0') {
            if ((at(s, p + 1) == 'x' or at(s, p + 1) == 'X') and std.ascii.isHex(at(s, p + 2)))
                p += 2;
        }
        // Non-empty sequence of digits
        const m = @as(T, std.math.maxInt(T)) / @as(T, @intCast(base));
        while (true) : ({
            p += 1;
            ndig += 1;
        }) {
            const c = at(s, p);
            var v: u32 = base;
            if ('0' <= c and c <= '9')
                v = c - '0'
            else if ('a' <= c and c <= 'z')
                v = c - 'a' + 10
            else if ('A' <= c and c <= 'Z')
                v = c - 'A' + 10;
            if (v >= base)
                break;
            if (n > m)
                ovfl = true;
            const nn = n *% @as(T, @intCast(base)) +% @as(T, @intCast(v));
            if (nn < n)
                ovfl = true;
            n = nn;
        }
    }

    if (ndig == 0)
        p = 0;
    if (ovfl)
        return .{ .v = std.math.maxInt(T), .n = p };
    if (neg)
        return .{ .v = 0 -% n, .n = p };
    return .{ .v = n, .n = p };
}

/// libc's strtoul(s, &end, base); the C's ulong is 32 bits.
pub fn strtoul(s: []const u8, base: u32) struct { v: u32, n: usize } {
    const r = strtou(u32, s, base);
    return .{ .v = r.v, .n = r.n };
}

/// libc's atoi, which is strtol(s, nil, 10) (without strtol's clamping
/// of a number that does not fit).
pub fn atoi(s: []const u8) i32 {
    return @bitCast(strtou(u32, s, 10).v);
}

// belongs in proc.zig (9/port/proc.c).
fn exhausted(resource: []const u8) Error {
    const e = proc.errorf("no free %s", .{resource});
    p9.iprint("%s\n", .{proc.errtext(e)});
    return e;
}

/// set up a new network interface
pub fn netifinit(nif: *Netif, name: []const u8, nfile: usize, limit: i32) void {
    if (name.len >= nif.name.len)
        panic("netifinit: name too long: %s", .{name});
    // the name may be nif.name itself, as it is for devether
    if (@intFromPtr(name.ptr) != @intFromPtr(&nif.name)) {
        @memcpy(nif.name[0..name.len], name);
        nif.name[name.len] = 0;
    }
    nif.nfile = nfile;
    const p = xalloc.xalloc(nfile * @sizeOf(?*Netfile)) orelse
        panic("netifinit: no memory", .{});
    const f = @as([*]?*Netfile, @ptrFromInt(p))[0..nfile];
    @memset(f, null);
    nif.f = f;
    nif.limit = limit;
}

/// generate a 3 level directory
fn netifgen(c: *Chan, _: ?[]const u8, vp: []const Dirtab, i_: i32, dp: *Dir) i32 {
    const nif = tabnif(vp);
    const up = arch.up().?;
    var i = i_;
    var q: Qid = .{};

    q.type = QTFILE;
    q.vers = 0;

    // top level directory contains the name of the network
    if (c.qid.path == 0) {
        switch (i) {
            DEVDOTDOT => {
                q.path = 0;
                q.type = QTDIR;
                devdir(c, q, ".", 0, proc.eve, 0o555, dp);
            },
            0 => {
                q.path = N2ndqid;
                q.type = QTDIR;
                const s = fmt.snprint(&up.genbuf, "%s", .{nifname(nif)});
                devdir(c, q, s, 0, proc.eve, 0o555, dp);
            },
            else => return -1,
        }
        return 1;
    }

    // second level contains clone plus all the conversations
    const t = NETTYPE(c.qid.path);
    if (t == N2ndqid or t == Ncloneqid or t == Naddrqid or t == Nstatqid or t == Nifstatqid) {
        switch (i) {
            DEVDOTDOT => {
                q.type = QTDIR;
                q.path = 0;
                devdir(c, q, ".", 0, proc.eve, 0o555, dp);
            },
            0 => {
                q.path = Ncloneqid;
                devdir(c, q, "clone", 0, proc.eve, 0o666, dp);
            },
            1 => {
                q.path = Naddrqid;
                devdir(c, q, "addr", 0, proc.eve, 0o444, dp);
            },
            2 => {
                q.path = Nstatqid;
                devdir(c, q, "stats", 0, proc.eve, 0o444, dp);
            },
            3 => {
                q.path = Nifstatqid;
                devdir(c, q, "ifstats", 0, proc.eve, 0o444, dp);
            },
            else => {
                i -= 4;
                if (i < 0 or @as(usize, @intCast(i)) >= nif.nfile)
                    return -1;
                if (nif.f[@intCast(i)] == null)
                    return 0;
                q.type = QTDIR;
                q.path = NETQID(@intCast(i), N3rdqid);
                const s = fmt.snprint(&up.genbuf, "%d", .{i});
                devdir(c, q, s, 0, proc.eve, 0o555, dp);
            },
        }
        return 1;
    }

    // third level
    const id = NETID(c.qid.path);
    if (id >= nif.f.len)
        return 0;
    const f = nif.f[id] orelse
        return 0;
    var o: []const u8 = undefined;
    var perm: u32 = undefined;
    if (f.owner[0] != 0) {
        o = std.mem.sliceTo(&f.owner, 0);
        perm = f.mode;
    } else {
        o = proc.eve;
        perm = 0o666;
    }
    switch (i) {
        DEVDOTDOT => {
            q.type = QTDIR;
            q.path = N2ndqid;
            const s = fmt.snprint(&up.genbuf, "%s", .{nifname(nif)});
            devdir(c, q, s, 0, proc.eve, 0o555, dp);
        },
        0 => {
            q.path = NETQID(id, Ndataqid);
            devdir(c, q, "data", 0, o, perm, dp);
        },
        1 => {
            q.path = NETQID(id, Nctlqid);
            devdir(c, q, "ctl", 0, o, perm, dp);
        },
        2 => {
            q.path = Nstatqid;
            devdir(c, q, "stats", 0, proc.eve, 0o444, dp);
        },
        3 => {
            q.path = NETQID(id, Ntypeqid);
            devdir(c, q, "type", 0, proc.eve, 0o444, dp);
        },
        4 => {
            q.path = Nifstatqid;
            devdir(c, q, "ifstats", 0, proc.eve, 0o444, dp);
        },
        else => return -1,
    }
    return 1;
}

pub fn netifwalk(nif: *Netif, c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, niftab(nif), netifgen);
}

pub fn netifopen(nif: *Netif, c: *Chan, omode: u32) Error!*Chan {
    // DIFF: before the open is counted; see the head of the file
    const mode = try devmod.openmode(omode);

    if (c.qid.type & QTDIR != 0) {
        if (omode != lib.OREAD)
            return error.Eperm;
    } else {
        switch (NETTYPE(c.qid.path)) {
            Ndataqid, Nctlqid => {
                const id = NETID(c.qid.path);
                _ = try openfile(nif, id, omode);
            },
            Ncloneqid => {
                const id = try openfile(nif, null, omode);
                c.qid.path = NETQID(@intCast(id), Nctlqid);
            },
            else => {
                if (omode != lib.OREAD)
                    return error.Ebadarg;
            },
        }
    }
    c.mode = @intCast(mode);
    c.flag |= COPEN;
    c.offset = 0;
    c.iounit = qio.qiomaxatomic;
    return c;
}

pub fn netifread(nif: *Netif, c: *Chan, a: []u8, offset: u32) Error!usize {
    if (c.qid.type & QTDIR != 0)
        return devmod.devdirread(c, a, niftab(nif), netifgen);

    switch (NETTYPE(c.qid.path)) {
        Ndataqid => {
            const f = nif.f[NETID(c.qid.path)].?;
            return qio.qread(f.in, a);
        },
        Nctlqid => return readnum(offset, a, NETID(c.qid.path), NUMSIZE),
        Nstatqid => {
            if (offset >= READSTR)
                return 0;
            const p = alloc.smalloc(READSTR);
            defer alloc.free(p);
            p[0] = 0;
            if (nif.ifstat) |ifstat| {
                // only to make the driver bring its counters up to date
                _ = ifstat(nif.arg, p[0..0]) catch 0;
            }
            var s: fmt.Fmt = .{ .buf = p[0 .. READSTR - 1] };
            fmt.fmtprint(&s, "in: %llud\n", .{nif.inpackets});
            fmt.fmtprint(&s, "link: %d\n", .{nif.link});
            fmt.fmtprint(&s, "out: %llud\n", .{nif.outpackets});
            fmt.fmtprint(&s, "crc errs: %d\n", .{nif.crcs});
            fmt.fmtprint(&s, "overflows: %d\n", .{nif.overflows});
            fmt.fmtprint(&s, "soft overflows: %d\n", .{nif.soverflows});
            fmt.fmtprint(&s, "framing errs: %d\n", .{nif.frames});
            fmt.fmtprint(&s, "buffer errs: %d\n", .{nif.buffs});
            fmt.fmtprint(&s, "output errs: %d\n", .{nif.oerrs});
            fmt.fmtprint(&s, "prom: %d\n", .{nif.prom});
            fmt.fmtprint(&s, "mbps: %d\n", .{nif.mbps});
            fmt.fmtprint(&s, "addr: ", .{});
            for (nif.addr[0..nif.alen]) |b|
                fmt.fmtprint(&s, "%2.2ux", .{b});
            fmt.fmtprint(&s, "\n", .{});
            return readstr(offset, a, p[0..s.n]);
        },
        Naddrqid => {
            const up = arch.up().?;
            var s: fmt.Fmt = .{ .buf = up.genbuf[0 .. up.genbuf.len - 1] };
            for (nif.addr[0..nif.alen]) |b|
                fmt.fmtprint(&s, "%2.2ux", .{b});
            return readstr(offset, a, up.genbuf[0..s.n]);
        },
        Ntypeqid => {
            const f = nif.f[NETID(c.qid.path)].?;
            return readnum(offset, a, @bitCast(f.type), NUMSIZE);
        },
        Nifstatqid => {
            const ifstat = nif.ifstat orelse return 0;
            if (offset >= READSTR)
                return 0;
            const p = alloc.smalloc(READSTR);
            defer alloc.free(p);
            p[0] = 0;
            const n = try ifstat(nif.arg, p[0 .. READSTR - 1]);
            return readstr(offset, a, p[0..@min(n, READSTR - 1)]);
        },
        else => {},
    }
    return error.Ebadarg;
}

pub fn netifbread(nif: *Netif, c: *Chan, n: usize, offset: u64) Error!*Block {
    if ((c.qid.type & QTDIR != 0) or NETTYPE(c.qid.path) != Ndataqid)
        return devmod.devbread(c, n, offset);

    // Dev.bread cannot return "no block" (a closed queue); an empty one
    // reads the same, as in devpipe.
    return (try qio.qbread(nif.f[NETID(c.qid.path)].?.in, n)) orelse ab.allocb(0);
}

/// make sure this type isn't already in use on this device
fn typeinuse(nif: *Netif, typ: i32) bool {
    if (typ <= 0)
        return false;

    for (nif.f) |fp| {
        const f = fp orelse continue;
        if (f.type == typ)
            return true;
    }
    return false;
}

/// the devxxx.c that calls us handles writing data, it knows best
///
/// Returns null for a message that is not one of ours.
pub fn netifwrite(nif: *Netif, c: *Chan, a: []const u8) Error!?usize {
    var bufa: [64]u8 = undefined;
    var binaddr: [Nmaxaddr]u8 = undefined;

    if (NETTYPE(c.qid.path) != Nctlqid)
        return error.Eperm;

    var n = a.len;
    if (n >= bufa.len)
        n = bufa.len - 1;
    @memcpy(bufa[0..n], a[0..n]);
    bufa[n] = 0;
    const buf: []const u8 = std.mem.sliceTo(bufa[0..n], 0);

    qlock(&nif.qlock);
    defer qunlock(&nif.qlock);

    const f = nif.f[NETID(c.qid.path)].?;
    if (matchtoken(buf, "connect")) |p| {
        const typ: i32 = @bitCast(strtoul(p, 0).v);
        if (typeinuse(nif, typ))
            return error.Einuse;
        f.type = typ;
        if (f.type < 0)
            nif.all += 1;
    } else if (matchtoken(buf, "promiscuous") != null) {
        if (!f.prom) {
            if (nif.prom == 0) {
                if (nif.promiscuous) |promiscuous|
                    try promiscuous(nif.arg, true);
            }
            f.prom = true;
            nif.prom += 1;
        }
    } else if (matchtoken(buf, "scanbs")) |p| {
        // scan for base stations
        if (f.scan == 0) {
            var typ = atoi(p);
            if (typ < 5)
                typ = 5;
            if (nif.scanbs) |scanbs|
                try scanbs(nif.arg, @intCast(typ));
            f.scan = @truncate(@as(u32, @bitCast(typ)));
            nif.scan += 1;
        }
    } else if (matchtoken(buf, "bridge") != null) {
        f.bridge = true;
    } else if (matchtoken(buf, "bypass") != null) {
        if (nif.bypass != null)
            return error.Einuse;
        f.bypass = true;
        nif.bypass = f;
    } else if (matchtoken(buf, "headersonly") != null) {
        f.headersonly = true;
    } else if (matchtoken(buf, "addmulti")) |p| {
        if (!parseaddr(&binaddr, p, nif.alen))
            return proc.errorf("bad address", .{});
        try netmulti(nif, f, binaddr[0..nif.alen], true);
    } else if (matchtoken(buf, "delmulti") orelse matchtoken(buf, "remmulti")) |p| {
        if (!parseaddr(&binaddr, p, nif.alen))
            return proc.errorf("bad address", .{});
        try netmulti(nif, f, binaddr[0..nif.alen], false);
    } else return null;
    return n;
}

pub fn netifwstat(nif: *Netif, c: *Chan, db: []const u8) Error!usize {
    const up = arch.up().?;
    var dir: Dir = .{};

    const strs = alloc.smalloc(db.len + 1);
    defer alloc.free(strs);
    const m = fcall.convM2D(db, &dir, strs[0 .. db.len + 1]);
    if (m == 0)
        return error.Eshortstat;
    qlock(&nif.qlock);
    defer qunlock(&nif.qlock);
    const id = NETID(c.qid.path);
    if (id >= nif.f.len)
        return error.Enonexist;
    const f = nif.f[id] orelse
        return error.Enonexist;
    if (netown(f, up.user, lib.OWRITE) < 0)
        return error.Eperm;
    if (dir.uid.len != 0) {
        const k = @min(dir.uid.len, KNAMELEN - 1);
        @memcpy(f.owner[0..k], dir.uid[0..k]);
        @memset(f.owner[k..], 0);
    }
    if (dir.mode != ~@as(u32, 0))
        f.mode = dir.mode;
    return m;
}

pub fn netifstat(nif: *Netif, c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, niftab(nif), netifgen);
}

pub fn netifclose(nif: *Netif, c: *Chan) void {
    if (c.flag & COPEN == 0)
        return;

    const t = NETTYPE(c.qid.path);
    if (t != Ndataqid and t != Nctlqid)
        return;

    qlock(&nif.qlock);
    defer qunlock(&nif.qlock);
    const f = nif.f[NETID(c.qid.path)] orelse
        return;
    f.inuse -= 1;
    if (f.inuse != 0)
        return;
    if (f.bypass) {
        nif.bypass = null;
        f.bypass = false;
    }
    if (f.prom) {
        nif.prom -= 1;
        if (nif.prom == 0) {
            if (nif.promiscuous) |promiscuous|
                promiscuous(nif.arg, false) catch {};
        }
        f.prom = false;
    }
    if (f.scan != 0) {
        nif.scan -= 1;
        if (nif.scan == 0) {
            if (nif.scanbs) |scanbs|
                scanbs(nif.arg, 0) catch {};
        }
        f.prom = false;
        f.scan = 0;
    }
    if (f.nmaddr != 0) {
        var i: usize = 0;
        var ap = nif.maddr;
        // DIFF: the C never advances its index; see the head of the file
        while (ap) |p| : ({
            ap = p.next;
            i += 1;
        }) {
            if (i < 8 * f.maddr.len and f.maddr[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0)
                netmulti(nif, f, p.addr[0..nif.alen], false) catch {};
        }
        f.nmaddr = 0;
    }
    if (f.type < 0)
        nif.all -= 1;
    f.owner[0] = 0;
    f.type = 0;
    f.bridge = false;
    f.headersonly = false;
    qio.qclose(f.in);
}

fn netown(p: *Netfile, o: []const u8, omode: u32) i32 {
    const access = [_]u32{ 0o400, 0o200, 0o600, 0o100 };

    if (p.owner[0] != 0) {
        var mode: u32 = undefined;
        if (std.mem.eql(u8, o, std.mem.sliceTo(&p.owner, 0))) // User
            mode = p.mode
        else if (std.mem.eql(u8, o, proc.eve)) // Bootes is group
            mode = p.mode << 3
        else
            mode = p.mode << 6; // Other

        const t = access[omode & 3];
        if ((t & mode) == t)
            return 0
        else
            return -1;
    }
    const k = @min(o.len, KNAMELEN - 1);
    @memcpy(p.owner[0..k], o[0..k]);
    @memset(p.owner[k..], 0);
    p.mode = 0o660;
    return 0;
}

/// Increment the reference count of a network device.
/// If id is null, return an unused ether device.
fn openfile(nif: *Netif, id_: ?usize, omode: u32) Error!usize {
    const up = arch.up().?;

    qlock(&nif.qlock);
    defer qunlock(&nif.qlock);
    if (id_) |id| {
        if (id >= nif.f.len)
            return error.Enodev;
        const f = nif.f[id] orelse
            return error.Enodev;
        if (netown(f, up.user, omode & 7) < 0)
            return error.Eperm;
        f.inuse += 1;
        qio.qreopen(f.in);
        return id;
    }
    for (nif.f, 0..) |*fp, i| {
        var f: *Netfile = undefined;
        if (fp.*) |x| {
            if (x.inuse != 0)
                continue;
            f = x;
        } else {
            f = alloc.new(Netfile) orelse
                return exhausted("memory");
            const in = qio.qopen(nif.limit, qio.Qmsg, null, null) orelse {
                alloc.free(f);
                return exhausted("memory");
            };
            f.* = .{ .in = in };
            arch.coherence();
            fp.* = f;
        }
        f.inuse = 1;
        qio.qreopen(f.in);
        _ = netown(f, up.user, 0);
        return i;
    }
    return error.Enodev;
}

/// look for a token starting a string,
/// return the string from the first non-space char after it
fn matchtoken(p_: []const u8, token: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, p_, token))
        return null;
    var p = p_[token.len..];
    if (p.len == 0)
        return p;
    if (p[0] != ' ' and p[0] != '\t' and p[0] != '\n')
        return null;
    while (p.len > 0 and (p[0] == ' ' or p[0] == '\t' or p[0] == '\n'))
        p = p[1..];
    return p;
}

pub fn hnputv(p: []u8, v: u64) void {
    hnputl(p, @truncate(v >> 32));
    hnputl(p[4..], @truncate(v));
}

pub fn hnputl(p: []u8, v: u32) void {
    p[0] = @truncate(v >> 24);
    p[1] = @truncate(v >> 16);
    p[2] = @truncate(v >> 8);
    p[3] = @truncate(v);
}

pub fn hnputs(p: []u8, v: u16) void {
    p[0] = @truncate(v >> 8);
    p[1] = @truncate(v);
}

pub fn nhgetv(p: []const u8) u64 {
    return (@as(u64, nhgetl(p)) << 32) | nhgetl(p[4..]);
}

pub fn nhgetl(p: []const u8) u32 {
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | (@as(u32, p[3]) << 0);
}

pub fn nhgets(p: []const u8) u16 {
    return (@as(u16, p[0]) << 8) | (@as(u16, p[1]) << 0);
}

fn hash(a: []const u8) u32 {
    var sum: u32 = 0;

    for (a) |c|
        sum = (sum << 1) +% c;
    return sum % Nmhash;
}

/// Is addr one of the multicast addresses somebody asked for?
pub fn activemulti(nif: *Netif, addr: []const u8) bool {
    var hp = nif.mhash[hash(addr)];
    while (hp) |h| : (hp = h.hnext) {
        if (std.mem.eql(u8, addr, h.addr[0..addr.len]))
            return h.ref > 0;
    }
    return false;
}

fn parseaddr(to: []u8, from: []const u8, alen: usize) bool {
    var p: usize = 0;
    for (0..alen) |i| {
        if (p >= from.len or from[p] == 0)
            return false;
        const hi = p;
        p += 1;
        if (p >= from.len or from[p] == 0)
            return false;
        p += 1;
        to[i] = @truncate(strtoul(from[hi..p], 16).v);
        if (p < from.len and from[p] == ':')
            p += 1;
    }
    return true;
}

/// keep track of multicast addresses
fn netmulti(nif: *Netif, f: *Netfile, addr: []const u8, add: bool) Error!void {
    const multicast = nif.multicast orelse
        return proc.errorf("interface does not support multicast", .{});

    var i: usize = 0;
    var l: *?*Netaddr = &nif.maddr;
    var ap: ?*Netaddr = l.*;
    while (ap) |p| : (ap = l.*) {
        if (std.mem.eql(u8, addr[0..nif.alen], p.addr[0..nif.alen]))
            break;
        i += 1;
        l = &p.next;
    }

    const bit = @as(u8, 1) << @intCast(i % 8);
    if (add) {
        var p: *Netaddr = undefined;
        if (ap) |x| {
            p = x;
            p.ref += 1;
        } else {
            p = alloc.new(Netaddr) orelse
                return error.Enomem;
            p.* = .{};
            @memcpy(p.addr[0..nif.alen], addr[0..nif.alen]);
            const h = hash(p.addr[0..nif.alen]);
            p.hnext = nif.mhash[h];
            p.ref = 1;
            arch.coherence();
            nif.mhash[h] = p;
            l.* = p;
        }
        if (p.ref == 1) {
            nif.nmaddr += 1;
            try multicast(nif.arg, addr, true);
        }
        if (i < 8 * f.maddr.len) {
            if (f.maddr[i / 8] & bit == 0)
                f.nmaddr += 1;
            f.maddr[i / 8] |= bit;
        }
    } else {
        const p = ap orelse return;
        if (p.ref == 0)
            return;
        p.ref -= 1;
        if (p.ref == 0) {
            nif.nmaddr -= 1;
            try multicast(nif.arg, addr, false);
        }
        if (i < 8 * f.maddr.len) {
            if (f.maddr[i / 8] & bit != 0)
                f.nmaddr -= 1;
            f.maddr[i / 8] &= ~bit;
        }
    }
}

test "strtoul" {
    const eq = std.testing.expectEqual;
    try eq(@as(u32, 12), strtoul("12:rest", 10).v);
    try eq(@as(usize, 2), strtoul("12:rest", 10).n);
    try eq(@as(usize, 0), strtoul(":x", 10).n);
    try eq(@as(u32, 0x800), strtoul("0x800", 0).v);
    try eq(@as(u32, 8), strtoul("010", 0).v);
    try eq(@as(i32, -1), @as(i32, @bitCast(strtoul("-1", 0).v)));
    try eq(@as(u32, 0xff), strtoul("ff", 16).v);
    try eq(@as(i32, 5), atoi(" 5 "));
}

test "matchtoken and parseaddr" {
    try std.testing.expectEqualStrings("0x800", matchtoken("connect 0x800", "connect").?);
    try std.testing.expectEqualStrings("", matchtoken("promiscuous", "promiscuous").?);
    try std.testing.expect(matchtoken("connected", "connect") == null);
    var a: [6]u8 = undefined;
    try std.testing.expect(parseaddr(&a, "01:00:5e:00:00:fb", 6));
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0x5e, 0, 0, 0xfb }, &a);
    try std.testing.expect(parseaddr(&a, "01005e0000fb", 6));
    try std.testing.expect(!parseaddr(&a, "01005e", 6));
}
