//! Storage Device, #S: /dev/sdctl and, per unit, /dev/sdXX/ctl, raw
//! and one file per partition.  The generic half of every disk driver.
//! from 9/port/devsd.c and 9/port/sd.h; DevConf and Devport are from
//! 9/port/portdat.h.
//!
//! DIFF:
//!   - Errors are Zig error returns.  Every waserror site became defer or
//!     errdefer, read against what it protected.  The driver entries the
//!     C defines as returning a status keep doing so (enable, disable,
//!     verify, online, rio, ataio return int codes and cannot raise an
//!     error); wctl, wtopctl, bio and probe, which call error() in the
//!     C drivers, return error unions.  The waserror around enable and
//!     verify in sdgetunit and the one around sd2gen in sdgen therefore
//!     had nothing left to catch and are gone.
//!   - sdifc is a slice the configuration sets before chandevreset, not
//!     a nil-terminated array written by mkdevc.
//!   - SDifc.rctl and rtopctl take the rest of the buffer as a slice and
//!     return how much they wrote, where the C passes and returns
//!     (p, e) pointers.
//!   - SDifc.bio takes the data as a slice of exactly nb*secsize bytes;
//!     write flags (SDifc.bio, SDreq.write, sdfakescsirw's rwp) are
//!     bools, with SDread = false and SDwrite = true.
//!   - The embedded SDperm of SDunit, SDpart and SDfile is the field
//!     `perm` (unit.perm.name, unit.perm.user, unit.perm.perm).  Names
//!     are slices, not NUL-terminated.  SDev.name stays a [8]u8;
//!     SDev.namestr() gives it as a slice.
//!   - SDunit.part is a slice; npart is part.len.  SDev.unit and unitflg
//!     are slices of length nunit.  nunit, subno, clen, dlen and rlen
//!     are usize.  SDev.enabled and SDpart.valid are bools.
//!   - SDrw is two types, SDrw (read) and SDww (write), because the
//!     buffers differ in constness.
//!   - An SDev and everything hanging off it is freed with alloc.free,
//!     as in C, so a driver must get its SDev from alloc.new(SDev) (or
//!     snew) and initialise it with `sdev.* = .{ .ifc = &ifc, ... }`.
//!   - sdbio, in-place I/O: the C uses the caller's buffer directly when
//!     it is a page-aligned kernel address and the request is not
//!     "hard".  Here that also requires the request to cover whole
//!     sectors (the C lets a short read run past the end of the caller's
//!     buffer), and "kernel address" is "above the user address space"
//!     rather than "above KZERO", since the kernel heap lives in the
//!     direct map below KZERO.  Otherwise a bounce buffer is used and
//!     the data copied, also to and from user memory, which is
//!     pre-faulted before it gets here.
//!   - sdbio, media change: if sdinitpart fails while handling the
//!     change, unit.ctl is released; the C leaves it held.  A hard write
//!     whose read-back comes up short of the offset writes nothing; the
//!     C computes a negative length.  A sector size of zero is Eio, not
//!     a divide trap.
//!   - sdrio does not copy saved sense data into the buffer of a write
//!     request (it is const here).  The C's `if(n < r->rlen) n = r->rlen`
//!     before the copy out is left out: it can only overrun the buffer.
//!     As in C, a raw read returns the full count asked for.
//!   - sdfakescsi refuses a long read capacity (0x9E) whose buffer is
//!     shorter than the 12 bytes it writes; the C checks for 8.
//!   - sdinitpart applies the boot program's sdXXpart= partitions once
//!     per unit (SDunit.bootpart).  The C tokenizes the configuration
//!     string in place, which has the same effect: the second time the
//!     string is cut short at its first field.
//!   - sdattach, configure, unconfigure and sdannexctlr reject an empty
//!     controller letter; the C's strchr finds the terminating NUL of
//!     devletters and indexes one past the end of devs.
//!   - sdadddevs prints the offending id number; the C prints the
//!     failed index, -1.
//!   - A missing verify makes a unit absent and a missing bio is Eio,
//!     where the C calls through nil.  Indices taken from a qid are
//!     bounds checked.
//!   - Dev has no config entry, so sdconfig is reachable only through
//!     the "config" message of /dev/sdctl (legacytopctl), as in 9front
//!     in practice.  DevConf and Devport are defined here because
//!     nothing else uses them.
//!   - The mmc/sdio host interface of sd.h (SDio, SDiocmd, addmmcio,
//!     annexsdio) is not here; it belongs with sdmmc.c, which is not
//!     ported.  sdannexctlr, its hook in this file, is.
//!   - strtoull (libc) is private here, like the copies in devcons,
//!     devsrv and devuart.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const pgrp = @import("pgrp.zig");
const parse = @import("parse.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Ref = portdat.Ref;
const QLock = portdat.QLock;
const Lock = portdat.Lock;
const Cmdbuf = parse.Cmdbuf;
const Dirtab = devmod.Dirtab;
const incref = portdat.incref;
const decref = portdat.decref;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const kstrdup = proc.kstrdup;
const devdir = devmod.devdir;
const mkqid = devmod.mkqid;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DMEXCL = fcall.DMEXCL;
const DEVDOTDOT = portdat.DEVDOTDOT;
const COPEN = portdat.COPEN;
const NUMSIZE = portdat.NUMSIZE;
const BY2PG = arch.mem.BY2PG;

//
// from 9/port/sd.h
//

pub const SDperm = struct {
    name: []u8 = portdat.nostr,
    user: []u8 = portdat.nostr,
    perm: u32 = 0,
};

pub const SDpart = struct {
    start: u64 = 0,
    end: u64 = 0,
    perm: SDperm = .{},
    valid: bool = false,
    vers: u32 = 0,
};

pub const SDrw = *const fn (unit: *SDunit, c: *Chan, buf: []u8, off: i64) Error!usize;
pub const SDww = *const fn (unit: *SDunit, c: *Chan, buf: []const u8, off: i64) Error!usize;

pub const SDfile = struct {
    perm: SDperm = .{},
    r: ?SDrw = null,
    w: ?SDww = null,
};

pub const SDunit = struct {
    dev: *SDev,
    subno: usize = 0,
    inquiry: [255]u8 = @splat(0), // format follows SCSI spec
    sense: [18]u8 = @splat(0), // format follows SCSI spec
    rsense: [18]u8 = @splat(0), // support seperate rq sense and inline return
    haversense: bool = false,
    perm: SDperm = .{},

    ctl: QLock = .{},
    sectors: u64 = 0,
    secsize: u32 = 0,
    part: []SDpart = &.{}, // empty or array of size npart
    vers: u32 = 0,
    ctlperm: SDperm = .{},

    raw: QLock = .{}, // raw read or write in progress
    rawinuse: u32 = 0, // really just a test-and-set
    state: i32 = 0,
    req: ?*SDreq = null,
    rawperm: SDperm = .{},
    efile: [5]SDfile = @splat(.{}),
    nefile: usize = 0,

    /// DIFF: the sdXXpart= partitions have been added once.
    bootpart: bool = false,
};

/// Each controller is represented by a SDev.
pub const SDev = struct {
    r: Ref = .{}, // Number of callers using device
    ifc: *const SDifc, // pnp/legacy
    ctlr: ?*anyopaque = null,
    idno: u8 = 0,
    name: [8]u8 = @splat(0),
    next: ?*SDev = null,

    qlock: QLock = .{}, // enable/disable
    enabled: bool = false,
    nunit: usize = 0, // Number of units
    unitlock: QLock = .{}, // `Loading' of units
    unitflg: []u8 = &.{}, // Unit flags
    unit: []?*SDunit = &.{},

    /// The name ("sdC") as a slice.
    pub fn namestr(sdev: *const SDev) []const u8 {
        return std.mem.sliceTo(&sdev.name, 0);
    }
};

pub const SDifc = struct {
    name: []const u8,

    pnp: ?*const fn () ?*SDev = null,
    enable: ?*const fn (sdev: *SDev) i32 = null,
    disable: ?*const fn (sdev: *SDev) i32 = null,

    verify: ?*const fn (unit: *SDunit) i32 = null,
    online: ?*const fn (unit: *SDunit) i32 = null,
    rio: ?*const fn (r: *SDreq) i32 = null,
    /// Writes at the start of buf and returns the number of bytes.
    rctl: ?*const fn (unit: *SDunit, buf: []u8) usize = null,
    wctl: ?*const fn (unit: *SDunit, cb: *Cmdbuf) Error!i32 = null,

    /// data.len == nb*unit.secsize.  Returns the number of bytes
    /// transferred, or -1.
    bio: ?*const fn (unit: *SDunit, lun: u32, write: bool, data: []u8, nb: usize, bno: u64) Error!isize = null,
    probe: ?*const fn (cf: *DevConf) Error!?*SDev = null,
    clear: ?*const fn (sdev: *SDev) void = null,
    /// Writes at the start of buf and returns the number of bytes.
    rtopctl: ?*const fn (sdev: *SDev, buf: []u8) usize = null,
    wtopctl: ?*const fn (sdev: ?*SDev, cb: *Cmdbuf) Error!i32 = null,
    ataio: ?*const fn (r: *SDreq) i32 = null,
};

pub const SDreq = struct {
    unit: *SDunit,
    lun: u32 = 0,
    write: bool = false,
    proto: u8 = 0,
    ataproto: u8 = 0,
    cmd: [0x20]u8 = @splat(0),
    clen: usize = 0,
    data: ?[*]u8 = null,
    dlen: usize = 0,

    flags: u32 = 0,

    status: i32 = 0,
    rlen: usize = 0,
    sense: [32]u8 = @splat(0),

    /// data[0..dlen], empty if there is no data.
    pub fn buf(r: *const SDreq) []u8 {
        const d = r.data orelse return &.{};
        return d[0..r.dlen];
    }
};

pub const SDnosense = 0x00000001;
pub const SDvalidsense = 0x00010000;

pub const SDretry = -5; // internal to controllers
pub const SDmalloc = -4;
pub const SDeio = -3;
pub const SDtimeout = -2;
pub const SDnostatus = -1;

pub const SDok = 0;

pub const SDcheck = 0x02; // check condition
pub const SDbusy = 0x08; // busy

pub const SDmaxio = 2048 * 1024;
pub const SDnpart = 16;

pub const SDread = false;
pub const SDwrite = true;

pub const SData = 1;
pub const SDcdb = 2;

/// Avoid extra copying by making sd buffers page-aligned for DMA.
pub fn sdmalloc(n: usize) ?[*]u8 {
    return alloc.mallocalign(n, BY2PG, 0, 0);
}

pub fn sdfree(p: ?[*]u8) void {
    alloc.free(p);
}

//
// from 9/port/portdat.h
//

pub const Devport = struct {
    port: u32 = 0,
    size: i32 = 0,
};

pub const DevConf = struct {
    intnum: u32 = 0, // interrupt number
    type: ?[]const u8 = null, // card type
    ports: []Devport = &.{}, // The ports themselves; nports is ports.len
};

//
// from 9/port/devsd.c
//

/// The drivers in this kernel; set by the configuration before
/// chandevreset.
pub var sdifc: []const *const SDifc = &.{};

const Enoata = "raw ata commands not supported";
const Enoscsi = "raw scsi commands not supported";

const devletters = "0123456789" ++
    "abcdefghijklmnopqrstuvwxyz" ++
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

var devs: [devletters.len]?*SDev = @splat(null);
var devslock: QLock = .{};
var topctlunit: SDunit = .{ .dev = undefined };

const Ahdrsz = 2;

const Rawcmd = 0;
const Rawdata = 1;
const Rawstatus = 2;

const Qtopdir = 1; // top level directory
const Qtopbase = 2;
const Qtopctl = Qtopbase;

const Qunitdir = 3; // directory per unit
const Qunitbase = 4;
const Qctl = Qunitbase;
const Qraw = 5;
const Qpart = 6;
const Qextra = 7;

const TypeLOG = 4;
const NType = 1 << TypeLOG;
const TypeMASK = NType - 1;
const TypeSHIFT = 0;

const PartLOG = 8;
const NPart = 1 << PartLOG;
const PartMASK = NPart - 1;
const PartSHIFT = TypeLOG;

const UnitLOG = 8;
const NUnit = 1 << UnitLOG;
const UnitMASK = NUnit - 1;
const UnitSHIFT = PartLOG + TypeLOG;

const DevLOG = 8;
const NDev = 1 << DevLOG;
const DevMASK = NDev - 1;
const DevSHIFT = UnitLOG + PartLOG + TypeLOG;

const Ncmd = 20;

/// The device character; sddevtab.dc.
const sddc = 'S';

fn TYPE(q: Qid) u32 {
    return (@as(u32, @truncate(q.path)) >> TypeSHIFT) & TypeMASK;
}

fn PART(q: Qid) u32 {
    return (@as(u32, @truncate(q.path)) >> PartSHIFT) & PartMASK;
}

fn UNIT(q: Qid) u32 {
    return (@as(u32, @truncate(q.path)) >> UnitSHIFT) & UnitMASK;
}

fn DEV(q: Qid) u32 {
    return (@as(u32, @truncate(q.path)) >> DevSHIFT) & DevMASK;
}

fn QID(d: usize, u: usize, p: usize, t: usize) u64 {
    return (d << DevSHIFT) | (u << UnitSHIFT) | (p << PartSHIFT) | (t << TypeSHIFT);
}

fn up() *portdat.Proc {
    return arch.up().?;
}

fn streq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn emptystr(s: []const u8) bool {
    return s.len == 0;
}

/// (ulong)off in the C: offsets into the small text files are cut to
/// 32 bits.
fn ul(off: i64) usize {
    return @as(u32, @truncate(@as(u64, @bitCast(off))));
}

/// strtoull(s, &end, base) from libc: optional white space and sign,
/// then a number in the base (0: 16 after 0x, 8 after 0, 10 otherwise).
/// end is the index of the first character not used, 0 if there is no
/// number.  n is the magnitude, saturated; neg says a minus preceded it.
fn strtoull(s: []const u8, base_: u32) struct { n: u64, end: usize, neg: bool } {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or (s[i] >= '\t' and s[i] <= '\r'))) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var base = base_;
    if (base == 0) {
        base = 10;
        if (i < s.len and s[i] == '0') {
            base = 8;
            if (i + 2 < s.len and (s[i + 1] == 'x' or s[i + 1] == 'X') and std.ascii.isHex(s[i + 2])) {
                base = 16;
                i += 2;
            }
        }
    }
    var n: u64 = 0;
    var ndig: usize = 0;
    var over = false;
    while (i < s.len) : (i += 1) {
        const d = std.fmt.charToDigit(s[i], 16) catch break;
        if (d >= base) break;
        const m = @mulWithOverflow(n, @as(u64, base));
        const a = @addWithOverflow(m[0], @as(u64, d));
        if (m[1] != 0 or a[1] != 0) over = true;
        n = a[0];
        ndig += 1;
    }
    if (ndig == 0)
        return .{ .n = 0, .end = 0, .neg = false };
    if (over) n = std.math.maxInt(u64);
    return .{ .n = n, .end = i, .neg = neg };
}

/// strtoull(s, 0, 0)
fn atoull(s: []const u8) u64 {
    const r = strtoull(s, 0);
    return if (r.neg) 0 -% r.n else r.n;
}

fn freeperm(perm: *SDperm) void {
    if (perm.name.ptr != portdat.nostr.ptr)
        alloc.free(perm.name);
    perm.name = portdat.nostr;
    if (perm.user.ptr != portdat.nostr.ptr)
        alloc.free(perm.user);
    perm.user = portdat.nostr;
}

fn freeunit(unit_: ?*SDunit) void {
    const unit = unit_ orelse return;

    for (unit.efile[0..unit.nefile]) |*e|
        freeperm(&e.perm);

    for (unit.part) |*pp|
        freeperm(&pp.perm);
    if (unit.part.len != 0)
        alloc.free(unit.part);

    freeperm(&unit.ctlperm);
    freeperm(&unit.rawperm);
    freeperm(&unit.perm);

    alloc.free(unit);
}

fn freesdev(sdev: *SDev) void {
    // free units and their files
    for (sdev.unit) |u|
        freeunit(u);

    alloc.free(sdev.unitflg.ptr);
    alloc.free(sdev.unit.ptr);
    alloc.free(sdev);
}

fn sdaddpart(unit: *SDunit, name: []const u8, start: u64, end: u64) Error!void {
    // Check name not already used
    // and look for a free slot.
    var partno: ?usize = null;
    if (unit.part.len != 0) {
        for (unit.part, 0..) |*pp, i| {
            if (!pp.valid) {
                if (partno == null)
                    partno = i;
                break;
            }
            if (streq(name, pp.perm.name)) {
                if (pp.start == start and pp.end == end)
                    return;
                return error.Ebadctl;
            }
        }
    } else {
        const pp = alloc.newslice(SDpart, SDnpart) orelse return error.Enomem;
        for (pp) |*x| x.* = .{};
        unit.part = pp;
        partno = 0;
    }

    // If no free slot found then increase the
    // array size (can't get here with unit->part == nil).
    if (partno == null) {
        if (unit.part.len >= NPart)
            return error.Enomem;
        const pp = alloc.newslice(SDpart, unit.part.len + SDnpart) orelse return error.Enomem;
        for (pp) |*x| x.* = .{};
        @memcpy(pp[0..unit.part.len], unit.part);
        alloc.free(unit.part);
        partno = unit.part.len;
        unit.part = pp;
    }

    // Check size and extent are valid.
    if (start > end or end > unit.sectors)
        return error.Eio;
    const pp = &unit.part[partno.?];
    pp.start = start;
    pp.end = end;
    kstrdup(&pp.perm.name, name);
    kstrdup(&pp.perm.user, proc.eve);
    pp.perm.perm = 0o640;
    pp.valid = true;
}

fn sddelpart(unit: *SDunit, name: []const u8) Error!void {
    // Look for the partition to delete.
    // Can't delete if someone still has it open.
    const pp = for (unit.part) |*pp| {
        if (pp.valid and streq(name, pp.perm.name))
            break pp;
    } else return error.Ebadctl;
    if (!streq(up().user, pp.perm.user) and !devcons.iseve())
        return error.Eperm;
    pp.valid = false;
    pp.vers +%= 1;
}

fn sdincvers(unit: *SDunit) void {
    unit.vers +%= 1;
    for (unit.part) |*pp| {
        pp.valid = false;
        pp.vers +%= 1;
    }
}

fn sdinitpart(unit: *SDunit) Error!bool {
    if (unit.sectors > 0) {
        unit.sectors = 0;
        unit.secsize = 0;
        sdincvers(unit);
    }

    if (unit.inquiry[0] & 0xC0 != 0)
        return false;
    switch (unit.inquiry[0] & 0x1F) {
        0x00, // DA
        0x04, // WORM
        0x05, // CD-ROM
        0x07, // MO
        => {},
        else => return false,
    }

    if (unit.dev.ifc.online) |online|
        _ = online(unit);

    if (unit.sectors != 0) {
        sdincvers(unit);
        try sdaddpart(unit, "data", 0, unit.sectors);

        // Use partitions passed from boot program,
        // e.g.
        //   sdC0part=dos 63 123123/plan9 123123 456456
        // This happens before /boot sets hostname so the
        // partitions will have the null-string for user.
        // The gen functions patch it up.
        var buf: [10]u8 = undefined;
        const conf = arch.getconf(fmt.snprint(buf[0 .. buf.len - 1], "%spart", .{unit.perm.name}));
        if (conf != null and !unit.bootpart) {
            unit.bootpart = true;
            // DIFF: tokenize edits its text and the configuration is
            // constant here, so work on a copy.
            const copy = alloc.smalloc(conf.?.len + 1)[0..conf.?.len];
            defer alloc.free(copy);
            @memcpy(copy, conf.?);
            var rest: ?[]u8 = copy;
            while (rest) |p_| {
                var p = p_;
                if (std.mem.findScalar(u8, p, '/')) |q| {
                    rest = p[q + 1 ..];
                    p = p[0..q];
                } else rest = null;
                var f: [4][]u8 = undefined;
                const nf = parse.tokenize(p, &f);
                if (nf < 3)
                    continue;

                const start = atoull(f[1]);
                const end = atoull(f[2]);
                sdaddpart(unit, f[0], start, end) catch {};
            }
        }
    }

    return true;
}

fn sdindex(idno: u32) ?usize {
    if (idno == 0 or idno > 0x7f)
        return null;
    return std.mem.findScalar(u8, devletters, @intCast(idno));
}

fn sdgetdev(idno: u32) ?*SDev {
    const i = sdindex(idno) orelse return null;

    qlock(&devslock);
    const sdev = devs[i];
    if (sdev) |s|
        _ = incref(&s.r);
    qunlock(&devslock);
    return sdev;
}

fn sdgetunit(sdev: *SDev, subno: usize) ?*SDunit {
    if (subno >= sdev.nunit)
        return null;

    // Associate a unit with a given device and sub-unit
    // number on that device.
    // The device will be probed if it has not already been
    // successfully accessed.
    qlock(&sdev.unitlock);
    defer qunlock(&sdev.unitlock);
    if (sdev.unit[subno]) |unit|
        return unit;

    // Probe the unit only once. This decision
    // may be a little severe and reviewed later.
    if (sdev.unitflg[subno] != 0)
        return null;
    sdev.unitflg[subno] = 1;

    const unit = alloc.snew(SDunit);
    unit.* = .{ .dev = sdev, .subno = subno };
    var buf: [32]u8 = undefined;
    kstrdup(&unit.perm.name, fmt.snprint(buf[0 .. buf.len - 1], "%s%x", .{ sdev.namestr(), subno }));
    kstrdup(&unit.perm.user, proc.eve);
    unit.perm.perm = 0o555;

    // DIFF: enable and verify return a status and cannot raise an
    // error, so the waserror that freed the unit is the plain test
    // below.
    if (!sdev.enabled)
        sdev.enabled = if (sdev.ifc.enable) |enable| enable(sdev) != 0 else true;

    // No need to lock anything here as this is only
    // called before the unit is made available in the
    // sdunit[] array.
    const verify = sdev.ifc.verify;
    if (!sdev.enabled or verify == null or verify.?(unit) == 0) {
        freeunit(unit);
        return null;
    }
    sdev.unit[subno] = unit;
    return unit;
}

fn sdreset() void {
    // Probe all known controller types and register any devices found.
    for (sdifc) |ifc| {
        const pnp = ifc.pnp orelse continue;
        sdadddevs(pnp());
    }
}

/// The `giveup:` label of sdadddevs.
fn giveup(sdev: *SDev, unit: ?[]?*SDunit, unitflg: ?[]u8) void {
    if (sdev.ifc.clear) |clear|
        clear(sdev);
    if (unitflg) |u| alloc.free(u.ptr);
    if (unit) |u| alloc.free(u.ptr);
    alloc.free(sdev);
}

pub fn sdadddevs(sdev_: ?*SDev) void {
    var next: ?*SDev = sdev_;
    while (next) |sdev| {
        next = sdev.next;

        // DIFF: allocated with room for at least one unit, so that an
        // SDev with none still has blocks to free, as the C's
        // malloc(0) gives it.
        const unit = alloc.newslice(?*SDunit, @max(sdev.nunit, 1));
        const unitflg = alloc.newslice(u8, @max(sdev.nunit, 1));
        if (unit == null or unitflg == null) {
            print("sdadddevs: out of memory\n", .{});
            giveup(sdev, unit, unitflg);
            continue;
        }
        for (unit.?) |*u| u.* = null;
        sdev.unit = unit.?[0..sdev.nunit];
        sdev.unitflg = unitflg.?[0..sdev.nunit];

        const id = sdindex(sdev.idno) orelse {
            print("sdadddevs: bad id number %d (%C)\n", .{ sdev.idno, sdev.idno });
            giveup(sdev, unit, unitflg);
            continue;
        };
        qlock(&devslock);
        var i: usize = 0;
        while (i < devs.len) : (i += 1) {
            const j = (id + i) % devs.len;
            if (devs[j] == null) {
                sdev.idno = devletters[j];
                devs[j] = sdev;
                const s = fmt.snprint(sdev.name[0 .. sdev.name.len - 1], "sd%c", .{devletters[j]});
                sdev.name[s.len] = 0;
                break;
            }
        }
        qunlock(&devslock);
        if (i == devs.len) {
            print("sdadddevs: out of device letters\n", .{});
            giveup(sdev, unit, unitflg);
            continue;
        }
    }
}

fn sd2gen(c: *Chan, unit: *SDunit, i: i32, dp: *Dir) i32 {
    switch (i) {
        Qctl => {
            const q = mkqid(QID(DEV(c.qid), UNIT(c.qid), PART(c.qid), Qctl), unit.vers, QTFILE);
            const perm = &unit.ctlperm;
            if (emptystr(perm.user)) {
                kstrdup(&perm.user, proc.eve);
                perm.perm = 0o640;
            }
            devdir(c, q, "ctl", 0, perm.user, perm.perm, dp);
            return 1;
        },

        Qraw => {
            const q = mkqid(QID(DEV(c.qid), UNIT(c.qid), PART(c.qid), Qraw), unit.vers, QTFILE);
            const perm = &unit.rawperm;
            if (emptystr(perm.user)) {
                kstrdup(&perm.user, proc.eve);
                perm.perm = DMEXCL | 0o600;
            }
            devdir(c, q, "raw", 0, perm.user, perm.perm, dp);
            return 1;
        },

        Qpart => {
            if (PART(c.qid) >= unit.part.len)
                return -1;
            const pp = &unit.part[PART(c.qid)];
            const l = (pp.end -% pp.start) *% unit.secsize;
            const q = mkqid(QID(DEV(c.qid), UNIT(c.qid), PART(c.qid), Qpart), unit.vers +% pp.vers, QTFILE);
            if (emptystr(pp.perm.user))
                kstrdup(&pp.perm.user, proc.eve);
            devdir(c, q, pp.perm.name, @bitCast(l), pp.perm.user, pp.perm.perm, dp);
            return 1;
        },

        Qextra => {
            const t = PART(c.qid);
            if (t >= unit.nefile)
                return -1;
            const q = mkqid(QID(DEV(c.qid), UNIT(c.qid), PART(c.qid), Qextra), unit.vers, QTFILE);
            const e = &unit.efile[t];
            if (emptystr(e.perm.user))
                kstrdup(&e.perm.user, proc.eve);
            devdir(c, q, e.perm.name, 0, e.perm.user, e.perm.perm, dp);
            return 1;
        },

        else => {},
    }

    return -1;
}

fn sd1gen(c: *Chan, i: i32, dp: *Dir) i32 {
    switch (i) {
        Qtopctl => {
            const q = mkqid(QID(0, 0, 0, Qtopctl), 0, QTFILE);
            qlock(&topctlunit.ctl);
            const p = &topctlunit.ctlperm;
            if (emptystr(p.user)) {
                kstrdup(&p.name, "sdctl");
                kstrdup(&p.user, proc.eve);
                p.perm = 0o640;
            }
            devdir(c, q, p.name, 0, p.user, p.perm, dp);
            qunlock(&topctlunit.ctl);
            return 1;
        },
        else => {},
    }
    return -1;
}

fn efilegen(c: *Chan, unit: *SDunit, i_: i32, dp: *Dir) i32 {
    const i = i_ - SDnpart;
    if (unit.nefile == 0 or i >= @as(i32, @intCast(unit.nefile)))
        return -1;
    if (i < 0)
        return 0;
    const e = &unit.efile[@intCast(i)];
    if (emptystr(e.perm.user))
        kstrdup(&e.perm.user, proc.eve);
    const q = mkqid(QID(DEV(c.qid), UNIT(c.qid), @intCast(i), Qextra), unit.vers, QTFILE);
    devdir(c, q, e.perm.name, 0, e.perm.user, e.perm.perm, dp);
    return 1;
}

/// The entry for the top directory, "#S".
fn topdirgen(c: *Chan, dp: *Dir) i32 {
    const u = up();
    const q = mkqid(QID(0, 0, 0, Qtopdir), 0, QTDIR);
    devdir(c, q, fmt.snprint(u.genbuf[0 .. u.genbuf.len - 1], "#%C", .{sddc}), 0, proc.eve, 0o555, dp);
    return 1;
}

fn sdgen(c: *Chan, _: ?[]const u8, _: []const Dirtab, s_: i32, dp: *Dir) i32 {
    switch (TYPE(c.qid)) {
        Qtopdir => {
            if (s_ == DEVDOTDOT)
                return topdirgen(c, dp);

            if (s_ + Qtopbase < Qunitdir)
                return sd1gen(c, s_ + Qtopbase, dp);
            var s: usize = @intCast(s_ - (Qunitdir - Qtopbase));

            qlock(&devslock);
            var i: usize = 0;
            while (i < devs.len) : (i += 1) {
                if (devs[i]) |d| {
                    if (s < d.nunit)
                        break;
                    s -= d.nunit;
                }
            }

            if (i == devs.len) {
                // Run off the end of the list
                qunlock(&devslock);
                return -1;
            }

            const sdev = devs[i] orelse {
                qunlock(&devslock);
                return 0;
            };

            _ = incref(&sdev.r);
            qunlock(&devslock);

            const unit = sdgetunit(sdev, s) orelse {
                _ = decref(&sdev.r);
                return 0;
            };

            const q = mkqid(QID(sdev.idno, s, 0, Qunitdir), 0, QTDIR);
            if (emptystr(unit.perm.user))
                kstrdup(&unit.perm.user, proc.eve);
            devdir(c, q, unit.perm.name, 0, unit.perm.user, unit.perm.perm, dp);
            _ = decref(&sdev.r);
            return 1;
        },

        Qunitdir => {
            if (s_ == DEVDOTDOT)
                return topdirgen(c, dp);

            const sdev = sdgetdev(DEV(c.qid)) orelse return -1;
            defer _ = decref(&sdev.r);
            const unit = chanunit(sdev, c) orelse return -1;
            qlock(&unit.ctl);
            defer qunlock(&unit.ctl);

            // Check for media change.
            // If one has already been detected, sectors will be zero.
            // If there is one waiting to be detected, online
            // will return > 1.
            // Online is a bit of a large hammer but does the job.
            if (unit.sectors == 0 or
                (unit.dev.ifc.online != null and unit.dev.ifc.online.?(unit) > 1))
                _ = sdinitpart(unit) catch return -1;

            var i = s_ + Qunitbase;
            if (i < Qpart)
                return sd2gen(c, unit, i, dp);
            i -= Qpart;
            if (unit.part.len == 0 or i >= @as(i32, @intCast(unit.part.len)))
                return efilegen(c, unit, i, dp);

            const pp = &unit.part[@intCast(i)];
            if (!pp.valid or unit.sectors == 0)
                return 0;
            const l = (pp.end -% pp.start) *% @as(u64, unit.secsize);
            const q = mkqid(QID(DEV(c.qid), UNIT(c.qid), @intCast(i), Qpart), unit.vers +% pp.vers, QTFILE);
            if (emptystr(pp.perm.user))
                kstrdup(&pp.perm.user, proc.eve);
            devdir(c, q, pp.perm.name, @bitCast(l), pp.perm.user, pp.perm.perm, dp);
            return 1;
        },
        Qraw, Qctl, Qpart, Qextra => {
            const sdev = sdgetdev(DEV(c.qid)) orelse return -1;
            defer _ = decref(&sdev.r);
            const unit = chanunit(sdev, c) orelse return -1;
            qlock(&unit.ctl);
            defer qunlock(&unit.ctl);
            return sd2gen(c, unit, @intCast(TYPE(c.qid)), dp);
        },
        Qtopctl => return sd1gen(c, @intCast(TYPE(c.qid)), dp),
        else => {},
    }

    return -1;
}

/// sdev->unit[UNIT(c->qid)].  DIFF: checked; a qid only names a unit
/// that sdgetunit has made, so nil does not happen.
fn chanunit(sdev: *SDev, c: *Chan) ?*SDunit {
    const u = UNIT(c.qid);
    if (u >= sdev.unit.len)
        return null;
    return sdev.unit[u];
}

fn sdattach(spec: []const u8) Error!*Chan {
    if (spec.len == 0) {
        const c = devmod.devattach(sddc, spec);
        c.qid = mkqid(QID(0, 0, 0, Qtopdir), 0, QTDIR);
        return c;
    }

    if (spec.len < 3 or spec[0] != 's' or spec[1] != 'd')
        return error.Ebadspec;
    const idno = spec[2];
    const r = strtoull(spec[3..], 10);
    if (r.end == 0 or (r.neg and r.n != 0))
        return error.Ebadspec;
    const subno = std.math.cast(usize, r.n) orelse std.math.maxInt(usize);

    const sdev = sdgetdev(idno) orelse return error.Enonexist;
    defer _ = decref(&sdev.r);
    if (sdgetunit(sdev, subno) == null)
        return error.Enonexist;
    const c = devmod.devattach(sddc, spec);
    c.qid = mkqid(QID(sdev.idno, subno, 0, Qunitdir), 0, QTDIR);
    c.dev = (@as(u32, sdev.idno) << UnitLOG) + @as(u32, @intCast(subno));
    return c;
}

fn sdwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &.{}, sdgen);
}

fn sdstat(c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, &.{}, sdgen);
}

fn sdopen(c_: *Chan, omode: u32) Error!*Chan {
    const c = try devmod.devopen(c_, omode, &.{}, sdgen);
    if (TYPE(c.qid) < Qunitbase)
        return c;
    errdefer c.flag &= ~@as(u16, COPEN);
    const sdev = sdgetdev(DEV(c.qid)) orelse return error.Enonexist;
    errdefer _ = decref(&sdev.r);
    const unit = chanunit(sdev, c) orelse return error.Enonexist;
    switch (TYPE(c.qid)) {
        Qctl, Qextra => c.qid.vers = unit.vers,
        Qraw => {
            qlock(&unit.raw);
            if (unit.rawinuse != 0) {
                qunlock(&unit.raw);
                return error.Einuse;
            }
            unit.state = Rawcmd;
            c.qid.vers = unit.vers;
            qunlock(&unit.raw);
        },
        Qpart => {
            qlock(&unit.ctl);
            defer qunlock(&unit.ctl);
            if (PART(c.qid) >= unit.part.len)
                return error.Enonexist;
            const pp = &unit.part[PART(c.qid)];
            c.qid.vers = unit.vers +% pp.vers;
        },
        else => {},
    }
    // keep the reference to unit->dev (sdev)
    c.aux = unit;
    return c;
}

fn sdclose(c: *Chan) Error!void {
    if (c.flag & COPEN == 0)
        return;
    if (TYPE(c.qid) < Qunitbase)
        return;
    const unit = auxunit(c);
    switch (TYPE(c.qid)) {
        Qraw => {
            qlock(&unit.raw);
            unit.rawinuse = 0;
            qunlock(&unit.raw);
        },
        else => {},
    }
    _ = decref(&unit.dev.r);
}

/// c->aux of an open file below a unit directory.
fn auxunit(c: *Chan) *SDunit {
    return @ptrCast(@alignCast(c.aux.?));
}

/// DIFF: the C's test is (uintptr)a > KZERO.  Here the kernel heap is
/// in the direct map, below KZERO, so the test is "not a user address".
fn iskaddr(a: [*]const u8) bool {
    return @intFromPtr(a) >= arch.mem.USTKTOP;
}

/// For a write, a is the caller's constant buffer with the const cast
/// away; it is only read (SDifc.bio does not modify the data of a
/// write).
fn sdbio(c: *Chan, write: bool, a: [*]u8, len: usize, off: u64) Error!usize {
    const unit = auxunit(c);
    qlock(&unit.ctl);
    var nchange: u32 = 0;
    while (true) {
        // DIFF: `held` says whether sdbio1 still holds unit.ctl; it is
        // what the C tracks by popping its error label when it unlocks.
        var held = true;
        if (sdbio1(c, unit, write, a, len, off, &held)) |n| {
            if (held)
                qunlock(&unit.ctl);
            return n;
        } else |e| {
            if (!held)
                return e;
            // notification of media change; go around again
            if (streq(proc.errtext(e), proc.errtext(error.Eio)) and unit.sectors == 0 and nchange == 0) {
                nchange += 1;
                _ = sdinitpart(unit) catch |e2| {
                    qunlock(&unit.ctl);
                    return e2;
                };
                continue;
            }

            // other errors; give up
            qunlock(&unit.ctl);
            return e;
        }
    }
}

/// The body of sdbio, entered with unit.ctl held.  It releases the
/// lock, and says so in *held, only for a drive without removable media.
fn sdbio1(c: *Chan, unit: *SDunit, write: bool, a: [*]u8, len_: usize, off: u64, held: *bool) Error!usize {
    var len: u64 = len_;
    if (PART(c.qid) >= unit.part.len)
        return error.Echange;
    const pp = &unit.part[PART(c.qid)];
    if (unit.vers +% pp.vers != c.qid.vers)
        return error.Echange;
    const secsize: u64 = unit.secsize;
    if (secsize == 0)
        return error.Eio;

    // Check the request is within bounds.
    // Removeable drives are locked throughout the I/O
    // in case the media changes unexpectedly.
    // Non-removeable drives are not locked during the I/O
    // to allow the hardware to optimise if it can; this is
    // a little fast and loose.
    // It's assumed that non-removeable media parameters
    // (sectors, secsize) can't change once the drive has
    // been brought online.
    const bno = (off / secsize) +% pp.start;
    var nb = ((off +% len +% secsize -% 1) / secsize) +% pp.start -% bno;
    const max = SDmaxio / secsize;
    if (nb > max)
        nb = max;
    if (bno +% nb > pp.end)
        nb = pp.end -% bno;
    if (bno >= pp.end or nb == 0) {
        if (write)
            return error.Eio;
        return 0;
    }
    const locked = (unit.inquiry[1] & 0x80) != 0;
    if (!locked) {
        qunlock(&unit.ctl);
        held.* = false;
    }

    const offset = off % secsize;
    if (offset + len > nb * secsize)
        len = nb * secsize - offset;
    const hard = offset != 0 or (write and len % secsize != 0);

    const bio = unit.dev.ifc.bio orelse return error.Eio;

    var b: [*]u8 = undefined;
    var allocd = false;
    // DIFF: len == nb*secsize is not in the C; see the top of the file.
    if (iskaddr(a) and (@intFromPtr(a) & (BY2PG - 1)) == 0 and !hard and len == nb * secsize) {
        b = a;
    } else {
        while (true) {
            if (sdmalloc(@intCast(nb * secsize))) |p| {
                b = p;
                break;
            }
            try pgrp.resrcwait("no memory for sdbio");
        }
        allocd = true;
    }
    defer if (allocd) sdfree(b);

    if (write) {
        if (hard) {
            const l = try bio(unit, 0, false, b[0..@intCast(nb * secsize)], @intCast(nb), bno);
            if (l < 0)
                return error.Eio;
            const ul_: u64 = @intCast(l);
            if (ul_ < nb * secsize) {
                nb = ul_ / secsize;
                const l2 = (nb * secsize) -| offset;
                if (len > l2)
                    len = l2;
            }
        }
        if (allocd)
            @memcpy(b[@intCast(offset)..][0..@intCast(len)], a[0..@intCast(len)]);
        const l = try bio(unit, 0, true, b[0..@intCast(nb * secsize)], @intCast(nb), bno);
        if (l < 0)
            return error.Eio;
        const ul_: u64 = @intCast(l);
        if (ul_ < offset)
            len = 0
        else if (len > ul_ - offset)
            len = ul_ - offset;
    } else {
        const l = try bio(unit, 0, false, b[0..@intCast(nb * secsize)], @intCast(nb), bno);
        if (l < 0)
            return error.Eio;
        const ul_: u64 = @intCast(l);
        if (ul_ < offset)
            len = 0
        else if (len > ul_ - offset)
            len = ul_ - offset;
        if (allocd)
            @memcpy(a[0..@intCast(len)], b[@intCast(offset)..][0..@intCast(len)]);
    }

    return @intCast(len);
}

/// For a write request (r.write), a is the caller's constant buffer
/// with the const cast away; it is only read.
fn sdrio(r: *SDreq, a: [*]u8, n: usize) Error!usize {
    if (n >= SDmaxio)
        return error.Etoobig;
    const u = r.unit;
    if (u.haversense and r.cmd[0] == 0x03) {
        u.haversense = false;
        r.rlen = u.rsense.len;
        if (r.rlen > n)
            r.rlen = n;
        // DIFF: not into the buffer of a write
        if (!r.write)
            @memcpy(a[0..r.rlen], u.rsense[0..r.rlen]);
        r.status = SDok;
        return r.rlen;
    }

    var data: ?[*]u8 = null;
    if (n > 0) {
        while (true) {
            data = sdmalloc(n);
            if (data != null)
                break;
            try pgrp.resrcwait("no memory for sdrio");
        }
        if (r.write)
            @memcpy(data.?[0..n], a[0..n]);
    }
    defer if (n > 0) {
        r.data = null;
        sdfree(data);
    };
    r.data = data;
    r.dlen = n;

    var f: ?*const fn (*SDreq) i32 = undefined;
    var errstr: []const u8 = undefined;
    if (r.proto == SData) {
        f = u.dev.ifc.ataio;
        errstr = Enoata;
    } else {
        f = u.dev.ifc.rio;
        errstr = Enoscsi;
    }
    const rio = f orelse return proc.errorf("%s", .{errstr});
    const rv = rio(r);
    if (r.flags & SDvalidsense != 0) {
        @memcpy(&u.rsense, r.sense[0..u.rsense.len]);
        u.haversense = true;
    }
    if (rv != SDok)
        return error.Eio;

    r.data = null;
    if (n > 0) {
        // DIFF: the C has `if(n < r->rlen) n = r->rlen;` here, which
        // can only make the copy overrun both buffers; left out.
        if (!r.write)
            @memcpy(a[0..n], data.?[0..n]);
    }
    return n;
}

/// SCSI simulation for non-SCSI devices
///
/// see /sys/src/cmd/scuzz/sense.c for information on key.
/// see /sys/lib/scsicodes for asc:ascq codes
pub fn sdsetsense(r: *SDreq, status: i32, key: u8, asc: u8, ascq: u8) i32 {
    const unit = r.unit;
    unit.sense[0] = 0x80 | 0x70; // valid; fixed-format
    unit.sense[2] = key;
    unit.sense[12] = asc;
    unit.sense[13] = ascq;

    r.status = status;
    if (status == SDcheck and r.flags & SDnosense == 0) {
        // request sense case from sdfakescsi
        var len: usize = unit.sense.len;
        if (len > r.sense.len - 1)
            len = r.sense.len - 1;
        @memcpy(r.sense[0..len], unit.sense[0..len]);
        unit.sense[2] = 0;
        unit.sense[12] = 0;
        unit.sense[13] = 0;
        r.flags |= SDvalidsense;
        return SDok;
    }
    return status;
}

pub fn sdfakescsi(r: *SDreq) i32 {
    const cmd = &r.cmd;
    r.rlen = 0;
    const unit = r.unit;

    // Map SCSI commands into ATA commands for discs.
    // Fail any command with a LUN except INQUIRY which
    // will return 'logical unit not supported'.
    if ((cmd[1] >> 5) != 0 and cmd[0] != 0x12)
        return sdsetsense(r, SDcheck, 0x05, 0x25, 0);

    switch (cmd[0]) {
        else => return sdsetsense(r, SDcheck, 0x05, 0x20, 0),

        0x00 => // test unit ready
        return sdsetsense(r, SDok, 0, 0, 0),

        0x03 => { // request sense
            const len: usize = if (cmd[4] < unit.sense.len) cmd[4] else unit.sense.len;
            if (r.data != null and r.dlen >= len) {
                @memcpy(r.data.?[0..len], unit.sense[0..len]);
                r.rlen = len;
            }
            return sdsetsense(r, SDok, 0, 0, 0);
        },

        0x12 => { // inquiry
            const len: usize = if (cmd[4] < unit.inquiry.len) cmd[4] else unit.inquiry.len;
            if (r.data != null and r.dlen >= len) {
                @memcpy(r.data.?[0..len], unit.inquiry[0..len]);
                r.rlen = len;
            }
            return sdsetsense(r, SDok, 0, 0, 0);
        },

        0x1B => // start/stop unit
        // nop for now, can use power management later.
        return sdsetsense(r, SDok, 0, 0, 0),

        0x25 => { // read capacity
            if ((cmd[1] & 0x01) != 0 or cmd[2] != 0 or cmd[3] != 0)
                return sdsetsense(r, SDcheck, 0x05, 0x24, 0);
            if (r.data == null or r.dlen < 8)
                return sdsetsense(r, SDcheck, 0x05, 0x20, 1);

            // Read capacity returns the LBA of the last sector.
            var len: u64 = unit.sectors;
            if (len >= 0xffffffff)
                len = 0xffffffff
            else if (len > 0)
                len -= 1;
            const p = r.data.?;
            std.mem.writeInt(u32, p[0..4], @truncate(len), .big);
            std.mem.writeInt(u32, p[4..8], unit.secsize, .big);
            r.rlen = 8;
            return sdsetsense(r, SDok, 0, 0, 0);
        },

        0x9E => { // long read capacity
            if ((cmd[1] & 0x01) != 0 or cmd[2] != 0 or cmd[3] != 0)
                return sdsetsense(r, SDcheck, 0x05, 0x24, 0);
            if (r.data == null or r.dlen < 8)
                return sdsetsense(r, SDcheck, 0x05, 0x20, 1);
            // DIFF: the reply is 12 bytes and the C only checks for 8;
            // a shorter buffer is refused the same way.
            if (r.dlen < 12)
                return sdsetsense(r, SDcheck, 0x05, 0x20, 1);
            // Read capcity returns the LBA of the last sector.
            var len: u64 = unit.sectors;
            if (len > 0)
                len -= 1;
            const p = r.data.?;
            std.mem.writeInt(u64, p[0..8], len, .big);
            std.mem.writeInt(u32, p[8..12], unit.secsize, .big);
            r.rlen = 12;
            return sdsetsense(r, SDok, 0, 0, 0);
        },

        0x35, // synchronize cache
        0x91,
        => return sdsetsense(r, SDok, 0, 0, 0),

        0x08, // read6
        0x0a, // write6
        0x28, // read10
        0x2a, // write10
        0xa8, // read12
        0xaa, // write12
        0x88, // read16
        0x8a, // write16
        => return SDnostatus,
    }
}

pub fn sdfakescsirw(r: *SDreq, llba: *u64, nsec: *u32, rwp: ?*bool) i32 {
    const c = &r.cmd;
    var rw = SDread;
    if ((c[0] & 0xf) == 0xa)
        rw = SDwrite;
    var lba: u64 = undefined;
    var count: u32 = undefined;
    switch (c[0]) {
        0x08, // read6
        0x0a,
        => {
            lba = @as(u64, c[1] & 0xf) << 16 | @as(u64, c[2]) << 8 | c[3];
            count = c[4];
        },
        0x28, // read10
        0x2a,
        => {
            lba = std.mem.readInt(u32, c[2..6], .big);
            count = std.mem.readInt(u16, c[7..9], .big);
        },
        0xa8, // read12
        0xaa,
        => {
            lba = std.mem.readInt(u32, c[2..6], .big);
            count = std.mem.readInt(u32, c[6..10], .big);
        },
        0x88, // read16
        0x8a,
        => {
            // ata commands only go to 48-bit lba
            if (c[2] != 0 or c[3] != 0)
                return sdsetsense(r, SDcheck, 3, 0xc, 2);
            lba = @as(u64, c[4]) << 40 | @as(u64, c[5]) << 32;
            lba |= std.mem.readInt(u32, c[6..10], .big);
            count = std.mem.readInt(u32, c[10..14], .big);
        },
        else => {
            print("%s: bad cmd 0x%.2ux\n", .{ r.unit.perm.name, c[0] });
            r.status = sdsetsense(r, SDcheck, 0x05, 0x20, 0);
            return SDcheck;
        },
    }
    if (r.data == null)
        return SDok;
    const secsize: u64 = r.unit.secsize;
    if (secsize != 0 and r.dlen < count * secsize)
        count = @intCast(r.dlen / secsize);
    if (rwp) |p|
        p.* = rw;
    llba.* = lba;
    nsec.* = count;
    return SDnostatus;
}

fn extrarw(c: *Chan, comptime write: bool, a: if (write) []const u8 else []u8, off: i64) Error!usize {
    const unit = auxunit(c);

    if (unit.vers != c.qid.vers)
        return error.Echange;
    const i = PART(c.qid);
    if (i >= unit.nefile)
        return error.Enonexist;
    const f = (if (write) unit.efile[i].w else unit.efile[i].r) orelse return error.Eperm;
    return f(unit, c, a, off);
}

fn deftopctl(s: *SDev, buf: []u8) usize {
    return fmt.snprint(buf, "sd%c %s %d units\n", .{ s.idno, s.ifc.name, s.nunit }).len;
}

fn sdread(c: *Chan, a: []u8, off: i64) Error!usize {
    const n = a.len;
    const offset = ul(off);
    switch (TYPE(c.qid)) {
        else => return error.Eperm,
        Qtopctl => {
            const m = 64 * 1024; // room for register dumps
            const buf = alloc.smalloc(m)[0 .. m - 1];
            defer alloc.free(buf);
            var p: usize = 0;
            qlock(&devslock);
            for (devs) |d| {
                const sdev = d orelse continue;
                if (sdev.ifc.rtopctl) |rtopctl|
                    p += rtopctl(sdev, buf[p..])
                else
                    p += deftopctl(sdev, buf[p..]);
            }
            qunlock(&devslock);
            return devcons.readstr(offset, a, buf[0..p]);
        },

        Qtopdir, Qunitdir => return devmod.devdirread(c, a, &.{}, sdgen),

        Qctl => {
            const m = 16 * 1024; // room for register dumps
            const buf = alloc.smalloc(m)[0 .. m - 1];
            defer alloc.free(buf);
            var p: usize = 0;
            const unit = auxunit(c);
            {
                qlock(&unit.ctl);
                defer qunlock(&unit.ctl);
                p += fmt.snprint(buf[p..], "inquiry %.48s\n", .{std.mem.sliceTo(unit.inquiry[8..], 0)}).len;
                // If there's a device specific routine it must
                // provide all information pertaining to night geometry
                // and the garscadden trains.
                if (unit.dev.ifc.rctl) |rctl|
                    p += rctl(unit, buf[p..]);
                if (unit.sectors == 0)
                    _ = try sdinitpart(unit);
                if (unit.sectors != 0) {
                    if (unit.dev.ifc.rctl == null)
                        p += fmt.snprint(buf[p..], "geometry %llud %lud\n", .{ unit.sectors, unit.secsize }).len;
                    for (unit.part) |*pp| {
                        if (pp.valid)
                            p += fmt.snprint(buf[p..], "part %s %llud %llud\n", .{ pp.perm.name, pp.start, pp.end }).len;
                    }
                }
            }
            return devcons.readstr(offset, a, buf[0..p]);
        },

        Qraw => {
            const unit = auxunit(c);
            qlock(&unit.raw);
            defer qunlock(&unit.raw);
            var i: usize = 0;
            if (unit.state == Rawdata) {
                unit.state = Rawstatus;
                const r = unit.req.?;
                i = try sdrio(r, a.ptr, n);
            } else if (unit.state == Rawstatus) {
                const r = unit.req.?;
                unit.req = null;
                unit.state = Rawcmd;
                const status = r.status;
                if (r.proto == SData) {
                    i = 16 + Ahdrsz;
                    if (n < i)
                        i = n;
                    if (i > 0)
                        a[0] = @truncate(@as(u32, @bitCast(status)));
                    if (i > Ahdrsz)
                        @memcpy(a[Ahdrsz..i], r.cmd[0 .. i - Ahdrsz]);
                } else i = devcons.readnum(0, a, @bitCast(status), NUMSIZE);
                alloc.free(r);
            }
            return i;
        },

        Qpart => return sdbio(c, false, a.ptr, n, @bitCast(off)),
        Qextra => return extrarw(c, false, a, off),
    }
}

fn sdwrite(c: *Chan, a_: []const u8, off: i64) Error!usize {
    var a = a_;
    var n = a.len;

    switch (TYPE(c.qid)) {
        else => return error.Eperm,
        Qtopctl => {
            const cb = try parse.parsecmd(a);
            defer alloc.free(cb);
            if (cb.nf == 0)
                return proc.errorf("empty control message", .{});
            const f0 = cb.f[0];
            cb.f = cb.f[1..];
            cb.nf -= 1;
            if (streq(f0, "config")) {
                // wormhole into ugly legacy interface
                try legacytopctl(cb);
                return n;
            }
            var ifc: ?*const SDifc = null;
            var sdev: ?*SDev = null;
            // "ata arg..." invokes sdifc[i]->wtopctl(nil, cb),
            // where sdifc[i]->name=="ata" and cb contains the args.
            for (sdifc) |x| {
                if (streq(x.name, f0)) {
                    ifc = x;
                    break;
                }
            }
            // "sd1 arg..." invokes sdifc[i]->wtopctl(sdev, cb),
            // where sdifc[i] and sdev match controller letter "1",
            // and cb contains the args.
            if (ifc == null and f0.len == 3 and f0[0] == 's' and f0[1] == 'd') {
                sdev = sdgetdev(f0[2]);
                if (sdev) |s|
                    ifc = s.ifc;
            }
            const i = ifc orelse return proc.errorf("unknown interface", .{});

            // subtopctl:
            defer if (sdev) |s| {
                _ = decref(&s.r);
            };
            const wtopctl = i.wtopctl orelse return error.Ebadctl;
            _ = try wtopctl(sdev, cb);
        },

        Qctl => {
            const cb = try parse.parsecmd(a);
            defer alloc.free(cb);
            const unit = auxunit(c);
            qlock(&unit.ctl);
            defer qunlock(&unit.ctl);
            if (unit.vers != c.qid.vers)
                return error.Echange;

            if (cb.nf < 1)
                return error.Ebadctl;
            if (streq(cb.f[0], "part")) {
                if (cb.nf != 4)
                    return error.Ebadctl;
                if (unit.sectors == 0 and !try sdinitpart(unit))
                    return error.Eio;
                const start = atoull(cb.f[2]);
                const end = atoull(cb.f[3]);
                try sdaddpart(unit, cb.f[1], start, end);
            } else if (streq(cb.f[0], "delpart")) {
                if (cb.nf != 2 or unit.part.len == 0)
                    return error.Ebadctl;
                try sddelpart(unit, cb.f[1]);
            } else if (unit.dev.ifc.wctl) |wctl| {
                _ = try wctl(unit, cb);
            } else return error.Ebadctl;
        },

        Qraw => {
            var proto: u8 = SDcdb;
            var ataproto: u8 = 0;
            var atacdb: usize = 0;
            const unit = auxunit(c);
            qlock(&unit.raw);
            defer qunlock(&unit.raw);
            switch (unit.state) {
                Rawcmd => {
                    // sneaky ata commands
                    if (n > 1 and a[0] == 0xff) {
                        proto = SData;
                        ataproto = a[1];
                        a = a[2..];
                        atacdb = Ahdrsz;
                        n -= Ahdrsz;
                    }
                    if (n < 6 or n > 0x20) // sizeof(req->cmd)
                        return error.Ebadarg;
                    const req = alloc.snew(SDreq);
                    req.* = .{ .unit = unit };
                    @memcpy(req.cmd[0..n], a[0..n]);
                    req.clen = n;
                    // req->flags = SDnosense;
                    req.status = ~@as(i32, 0);
                    req.proto = proto;
                    req.ataproto = ataproto;
                    unit.req = req;
                    unit.state = Rawdata;
                    n += atacdb;
                },

                Rawstatus => {
                    unit.state = Rawcmd;
                    alloc.free(unit.req);
                    unit.req = null;
                    return error.Ebadusefd;
                },

                Rawdata => {
                    unit.state = Rawstatus;
                    const req = unit.req.?;
                    req.write = true;
                    n = try sdrio(req, @constCast(a.ptr), n);
                },
                else => {},
            }
        },
        Qpart => return sdbio(c, true, @constCast(a.ptr), n, @bitCast(off)),
        Qextra => return extrarw(c, true, a, off),
    }

    return n;
}

fn sdwstat(c: *Chan, dp: []const u8) Error!usize {
    if (c.qid.type & QTDIR != 0)
        return error.Eperm;
    var unit: *SDunit = undefined;
    var sdev: ?*SDev = null;
    if (TYPE(c.qid) == Qtopctl) {
        unit = &topctlunit;
    } else {
        sdev = sdgetdev(DEV(c.qid)) orelse return error.Enonexist;
        unit = chanunit(sdev.?, c) orelse {
            _ = decref(&sdev.?.r);
            return error.Enonexist;
        };
    }
    defer if (sdev) |s| {
        _ = decref(&s.r);
    };
    qlock(&unit.ctl);
    defer qunlock(&unit.ctl);

    var perm: *SDperm = undefined;
    switch (TYPE(c.qid)) {
        else => return error.Eperm,
        Qtopctl, Qctl => perm = &unit.ctlperm,
        Qraw => perm = &unit.rawperm,
        Qpart => {
            if (PART(c.qid) >= unit.part.len)
                return error.Enonexist;
            const pp = &unit.part[PART(c.qid)];
            if (unit.vers +% pp.vers != c.qid.vers)
                return error.Enonexist;
            perm = &pp.perm;
        },
    }

    if (!streq(up().user, perm.user) and !devcons.iseve())
        return error.Eperm;

    var d: Dir = .{};
    const strs = alloc.smalloc(dp.len + 4)[0 .. dp.len + 4];
    defer alloc.free(strs);
    const n = fcall.convM2D(dp, &d, strs);
    if (n == 0)
        return error.Eshortstat;
    if (d.atime != ~@as(u32, 0) or d.mtime != ~@as(u32, 0) or d.length != ~@as(i64, 0))
        return error.Eperm;
    if (!emptystr(d.muid) or !emptystr(d.name))
        return error.Eperm;
    if (!emptystr(d.gid) and !streq(d.gid, proc.eve))
        return error.Eperm;
    // committed
    if (!emptystr(d.uid))
        kstrdup(&perm.user, d.uid);
    if (d.mode != ~@as(u32, 0))
        perm.perm = (perm.perm & ~@as(u32, 0o777)) | (d.mode & 0o777);
    return n;
}

fn configure(spec: []const u8, cf: *DevConf) Error!i32 {
    if (spec.len == 0 or sdindex(spec[0]) == null)
        return proc.errorf("bad sd spec", .{});

    // DIFF: the C cuts the type at its '/' for the comparison and
    // puts the '/' back.
    const typ = cf.type orelse "";
    const name = if (std.mem.findScalar(u8, typ, '/')) |p| typ[0..p] else typ;

    const ifc = for (sdifc) |x| {
        if (streq(x.name, name))
            break x;
    } else return proc.errorf("sd type not found", .{});

    const probe = ifc.probe orelse return proc.errorf("sd type cannot probe", .{});

    const sdev = try probe(cf);
    var s = sdev;
    while (s) |x| : (s = x.next)
        x.idno = spec[0];
    sdadddevs(sdev);
    return 0;
}

fn unconfigure(spec: []const u8) Error!i32 {
    const i = (if (spec.len == 0) null else sdindex(spec[0])) orelse return error.Enonexist;

    qlock(&devslock);
    const sdev = devs[i] orelse {
        qunlock(&devslock);
        return error.Enonexist;
    };
    if (sdev.r.ref != 0) {
        qunlock(&devslock);
        return error.Einuse;
    }
    devs[i] = null;
    qunlock(&devslock);

    // make sure no interrupts arrive anymore before removing resources
    if (sdev.enabled) {
        if (sdev.ifc.disable) |disable|
            _ = disable(sdev);
    }

    // free controller specific info
    if (sdev.ifc.clear) |clear|
        clear(sdev);

    freesdev(sdev);

    return 0;
}

fn sdconfig(on: bool, spec: []const u8, cf: *DevConf) Error!i32 {
    if (on)
        return configure(spec, cf);
    return unconfigure(spec);
}

var sdaddfilelk: Lock = .{};

pub fn sdaddfile(unit_: ?*SDunit, s: []const u8, perm: u32, u: []const u8, r: ?SDrw, w: ?SDww) i32 {
    const unit = unit_ orelse return -1;
    taslock.lock(&sdaddfilelk);
    var i: usize = 0;
    while (i < unit.nefile) : (i += 1) {
        if (streq(unit.efile[i].perm.name, s))
            break;
    }
    if (i >= unit.efile.len) {
        taslock.unlock(&sdaddfilelk);
        return -1;
    }
    if (i >= unit.nefile)
        unit.nefile = i + 1;
    const e = &unit.efile[i];
    kstrdup(&e.perm.name, s);
    kstrdup(&e.perm.user, u);
    e.perm.perm = perm;
    e.r = r;
    e.w = w;
    taslock.unlock(&sdaddfilelk);
    return 0;
}

fn sdshutdown() void {
    for (devs, 0..) |d, i| {
        const sdev = d orelse continue;
        const disable = sdev.ifc.disable orelse {
            print("#S/sd%c: no disable function\n", .{devletters[i]});
            continue;
        };
        _ = disable(sdev);
    }
}

/// find a SDdev, make sure its enabled and free it,
/// returning its controller. This is used by
/// annexsdio() to take over sdio from devsd.
pub fn sdannexctlr(spec: []const u8, ifc: *const SDifc) Error!?*anyopaque {
    const i = (if (spec.len == 0) null else sdindex(spec[0])) orelse return error.Enonexist;

    qlock(&devslock);
    const sdev = devs[i] orelse {
        qunlock(&devslock);
        return error.Enonexist;
    };
    if (sdev.ifc != ifc) {
        qunlock(&devslock);
        return error.Enonexist;
    }
    if (sdev.r.ref != 0) {
        qunlock(&devslock);
        return error.Einuse;
    }
    devs[i] = null;
    qunlock(&devslock);

    if (!sdev.enabled) {
        if (ifc.enable) |enable|
            _ = enable(sdev);
    }

    const ctlr = sdev.ctlr;
    freesdev(sdev);

    return ctlr;
}

pub const sddevtab: devmod.Dev = .{
    .dc = sddc,
    .name = "sd",

    .reset = sdreset,
    .shutdown = sdshutdown,
    .attach = sdattach,
    .walk = sdwalk,
    .stat = sdstat,
    .open = sdopen,
    .close = sdclose,
    .read = sdread,
    .write = sdwrite,
    .wstat = sdwstat,
    // DIFF: Dev has no power or config entry; see sdconfig.
};

// This is wrong for so many reasons.  This code must go.
const Confdata = struct {
    on: i32 = 0,
    spec: ?[]const u8 = null,
    cf: DevConf = .{},
};

fn parseswitch(cd: *Confdata, option: []const u8) Error!void {
    if (streq("on", option))
        cd.on = 1
    else if (streq("off", option))
        cd.on = 0
    else
        return error.Ebadarg;
}

fn parsespec(cd: *Confdata, option: []const u8) Error!void {
    if (option.len > 1)
        return error.Ebadarg;
    cd.spec = option;
}

fn getnewport(dc: *DevConf) *Devport {
    const p = alloc.newslice(Devport, dc.ports.len + 1) orelse
        panic("sd: no memory for Devport", .{});
    if (dc.ports.len > 0) {
        @memcpy(p[0..dc.ports.len], dc.ports);
        alloc.free(dc.ports);
    }
    dc.ports = p;
    const np = &dc.ports[dc.ports.len - 1];
    np.size = -1;
    np.port = ~@as(u32, 0);
    return np;
}

fn parseport(cd: *Confdata, option: []const u8) Error!void {
    const p = if (cd.cf.ports.len == 0 or cd.cf.ports[cd.cf.ports.len - 1].port != ~@as(u32, 0))
        getnewport(&cd.cf)
    else
        &cd.cf.ports[cd.cf.ports.len - 1];
    const r = strtoull(option, 0);
    p.port = @truncate(if (r.neg) 0 -% r.n else r.n);
    if (r.end != option.len)
        return error.Ebadarg;
}

fn parsesize(cd: *Confdata, option: []const u8) Error!void {
    const p = if (cd.cf.ports.len == 0 or cd.cf.ports[cd.cf.ports.len - 1].size != -1)
        getnewport(&cd.cf)
    else
        &cd.cf.ports[cd.cf.ports.len - 1];
    const r = strtoull(option, 0);
    p.size = @bitCast(@as(u32, @truncate(if (r.neg) 0 -% r.n else r.n)));
    if (r.end != option.len)
        return error.Ebadarg;
}

fn parseirq(cd: *Confdata, option: []const u8) Error!void {
    const r = strtoull(option, 0);
    cd.cf.intnum = @truncate(if (r.neg) 0 -% r.n else r.n);
    if (r.end != option.len)
        return error.Ebadarg;
}

fn parsetype(cd: *Confdata, option: []const u8) Error!void {
    cd.cf.type = option;
}

const options = [_]struct {
    name: []const u8,
    parse: *const fn (*Confdata, []const u8) Error!void,
}{
    .{ .name = "switch", .parse = parseswitch },
    .{ .name = "spec", .parse = parsespec },
    .{ .name = "port", .parse = parseport },
    .{ .name = "size", .parse = parsesize },
    .{ .name = "irq", .parse = parseirq },
    .{ .name = "type", .parse = parsetype },
};

fn legacytopctl(cb: *Cmdbuf) Error!void {
    var cd: Confdata = .{};
    cd.on = -1;
    // As in C, cd.cf.ports is not freed: a driver's probe may keep it.
    var i: usize = 0;
    while (i < cb.nf) : (i += 2) {
        if (i + 2 > cb.nf)
            return error.Ebadarg;
        const opt = cb.f[i];
        for (options) |o| {
            if (streq(opt, o.name)) {
                try o.parse(&cd, cb.f[i + 1]);
                break;
            }
        } else return error.Ebadarg;
    }
    if (cd.on < 0 or cd.spec == null)
        return error.Ebadarg;
    if (cd.on != 0 and cd.cf.type == null)
        return error.Ebadarg;
    _ = try sdconfig(cd.on != 0, cd.spec.?, &cd.cf);
}
