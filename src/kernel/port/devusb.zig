//! USB device driver framework.
//! from 9/port/devusb.c; isaconfig from 9/pc/devarch.c
//!
//! This is in charge of providing access to actual HCIs
//! and providing I/O to the various endpoints of devices.
//! A separate user program (usbd) is in charge of
//! enumerating the bus, setting up endpoints and
//! starting devices (also user programs).
//!
//! The interface provided is a violation of the standard:
//! you're welcome.
//!
//! The interface consists of a root directory with several files
//! plus a directory (epN.M) with two files per endpoint.
//! A device is represented by its first endpoint, which
//! is a control endpoint automatically allocated for each device.
//! Device control endpoints may be used to create new endpoints.
//! Devices corresponding to hubs may also allocate new devices,
//! perhaps also hubs. Initially, a hub device is allocated for
//! each controller present, to represent its root hub. Those can
//! never be removed.
//!
//! All endpoints refer to the first endpoint (epN.0) of the device,
//! which keeps per-device information, and also to the HCI used
//! to reach them. Although all endpoints cache that information.
//!
//! epN.M/data files permit I/O and are considered DMEXCL.
//! epN.M/ctl files provide status info and accept control requests.
//!
//! Endpoints may be given file names to be listed also at #u,
//! for those drivers that have nothing to do after configuring the
//! device and its endpoints.
//!
//! Drivers for different controllers are kept at usb[oue]hci.c
//! It's likely we could factor out much from controllers into
//! a generic controller driver, the problem is that details
//! regarding how to handle toggles, tokens, Tds, etc. will
//! get in the way. Thus, code is probably easier the way it is.
//!
//! DIFF:
//!   - Only the xHCI driver exists (usbxhci.zig): the baseline is
//!     hardware from 2011 on, so UHCI, OHCI and EHCI are not ported.  A
//!     plan9.ini line usbN= without type= still means "uhci", as in the
//!     C, and so matches nothing.
//!   - Errors are Zig error returns.  A waserror that only undoes
//!     something is a defer or errdefer; those around the driver's
//!     epstop and epclose in usbclose and in the detach request, which
//!     swallow the error, are catches.  The ones in usbgen protect
//!     calls that cannot fail here and are gone.
//!   - usbinit: an error from newdev while making a root hub is printed
//!     and that controller skipped; in the C nothing catches it.
//!   - There is no ISA configuration layer: isaconfig is a private
//!     stand-in as in devether.zig, and ISAConf is devether's.
//!   - Strings are slices.  The endpoint name a "newdev" request leaves
//!     in c->aux for the next read is kept there with a terminating NUL
//!     (Chan.aux is a bare pointer).
//!   - 1<<hp->nports is computed by portmask, which gives all ones for
//!     32 ports or more where the C's shift is undefined.
//!   - seprintep indexes its name tables with values the control
//!     requests keep in range, as the C does; seprintdata takes a slice
//!     and the position to append at.
//!   - The debug print macros of usb.h are functions here.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");
const parse = @import("parse.zig");
const netif = @import("netif.zig");
const usb = @import("usb.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const qlock = ql.qlock;
const eqlock = ql.eqlock;
const qunlock = ql.qunlock;
const incref = portdat.incref;
const decref = portdat.decref;
const devdir = devmod.devdir;
const mkqid = devmod.mkqid;

const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const QLock = portdat.QLock;
const Dirtab = devmod.Dirtab;
const Cmdtab = parse.Cmdtab;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DMEXCL = fcall.DMEXCL;
const DEVDOTDOT = portdat.DEVDOTDOT;
const COPEN = portdat.COPEN;
const READSTR = portdat.READSTR;
const OREAD = lib.OREAD;
const OWRITE = lib.OWRITE;
const ORDWR = lib.ORDWR;

const Hci = usb.Hci;
const Ep = usb.Ep;
const Udev = usb.Udev;
const ISAConf = usb.ISAConf;
const Ndeveps = usb.Ndeveps;
const Nhcis = usb.Nhcis;
const Neps = usb.Neps;
const Xfertmout = usb.Xfertmout;
const Tnone = usb.Tnone;
const Tctl = usb.Tctl;
const Tiso = usb.Tiso;
const Tbulk = usb.Tbulk;
const Tintr = usb.Tintr;
const Devmax = usb.Devmax;
const Fullspeed = usb.Fullspeed;
const Lowspeed = usb.Lowspeed;
const Highspeed = usb.Highspeed;
const Nospeed = usb.Nospeed;
const Superspeed = usb.Superspeed;
const Dconfig = usb.Dconfig;
const Denabled = usb.Denabled;
const Ddetach = usb.Ddetach;
const Dreset = usb.Dreset;
const GET2 = usb.GET2;
const usbmodename = usb.usbmodename;

// Qid numbers
const Qdir = 0; // #u
const Qusbdir = 1; // #u/usb
const Qctl = 2; // #u/usb/ctl - control requests

const Qep0dir = 3; // #u/usb/ep0.0 - endpoint 0 dir
const Qep0io = 4; // #u/usb/ep0.0/data - endpoint 0 I/O
const Qep0ctl = 5; // #u/usb/ep0.0/ctl - endpoint 0 ctl.
const Qep0dummy = 6; // give 4 qids to each endpoint

const Qepdir = 0; // (qid-qep0dir)&3 is one of these
const Qepio = 1; // to identify which file for the endpoint
const Qepctl = 2;

// ...

// Usb ctls.
const CMdebug = 0; // debug on|off

// Ep. ctls
const CMnew = 0; // new nb ctl|bulk|intr|iso r|w|rw (endpoint)
const CMnewdev = 1; // newdev full|low|high|super portnb (allocate new devices)
const CMdetach = 2; // detach (abort I/O forever on this ep).
const CMpreset = 3; // reset the port
const CMdebugep = 4; // debug n (set/clear debug for this ep)
const CMclrhalt = 5; // clrhalt (halt was cleared on endpoint)
const CMaddress = 6; // address (address is assigned)
const CMhub = 7; // hub (set the device as a hub)
const CMmaxpkt = 8; // maxpkt size
const CMntds = 9; // ntds nb (max nb. of tds per µframe)
const CMpollival = 10; // pollival interval (interrupt/iso)
const CMtmout = 11; // timeout n (activate timeouts for ep)
const CMhz = 12; // hz n (samples/sec; iso)
const CMsamplesz = 13; // samplesz n (sample size; iso)
const CMsampledelay = 14; // maximum delay introduced by buffering (iso)
const CMuframes = 15; // set uframe mode (iso)
const CMname = 16; // name str (show up as #u/name as well)
const CMinfo = 17; // info infostr (ke.ep info for humans)

// Hub feature selectors
const Rportenable = 1;
const Rportreset = 4;
const Rportpower = 8;
const Rbhportreset = 28;

const Hcitype = struct {
    type: ?[]const u8 = null,
    reset: *const fn (*Hci) i32 = undefined,
};

fn QID(q: Qid) i32 {
    return @bitCast(@as(u32, @truncate(q.path)));
}

const Edetach = "device is detached";
const Edisabled = "device is not enabled";
const Enotconf = "endpoint not configured";
const Ebadtype = "bad endpoint type";
const Ebadport = "bad hub port number";
const Enotahub = "not a hub";

pub const Estalled = usb.Estalled;

const usbctls = [_]Cmdtab{
    .{ .index = CMdebug, .cmd = "debug", .narg = 2 },
};

const epctls = [_]Cmdtab{
    .{ .index = CMnew, .cmd = "new", .narg = 4 },
    .{ .index = CMnewdev, .cmd = "newdev", .narg = 3 },
    .{ .index = CMdetach, .cmd = "detach", .narg = 1 },
    .{ .index = CMpreset, .cmd = "reset", .narg = 1 },
    .{ .index = CMdebugep, .cmd = "debug", .narg = 2 },
    .{ .index = CMclrhalt, .cmd = "clrhalt", .narg = 1 },
    .{ .index = CMaddress, .cmd = "address", .narg = 1 },
    .{ .index = CMhub, .cmd = "hub", .narg = 0 },
    .{ .index = CMmaxpkt, .cmd = "maxpkt", .narg = 2 },
    .{ .index = CMntds, .cmd = "ntds", .narg = 2 },
    .{ .index = CMpollival, .cmd = "pollival", .narg = 2 },
    .{ .index = CMtmout, .cmd = "timeout", .narg = 2 },
    .{ .index = CMhz, .cmd = "hz", .narg = 2 },
    .{ .index = CMsamplesz, .cmd = "samplesz", .narg = 2 },
    .{ .index = CMsampledelay, .cmd = "sampledelay", .narg = 2 },
    .{ .index = CMuframes, .cmd = "uframes", .narg = 2 },
    .{ .index = CMname, .cmd = "name", .narg = 2 },
    .{ .index = CMinfo, .cmd = "info", .narg = 0 },
};

const usbdir = [_]Dirtab{
    .{ .name = "ctl", .qid = .{ .path = Qctl }, .length = 0, .perm = 0o666 },
};

const ttname = [_][]const u8{
    "none", // Tnone
    "control", // Tctl
    "iso", // Tiso
    "bulk", // Tbulk
    "interrupt", // Tintr
};

const spname = [_][]const u8{
    "full", // Fullspeed
    "low", // Lowspeed
    "high", // Highspeed
    "no", // Nospeed
    "super", // Superspeed
};

comptime {
    if (Tnone != 0 or Tctl != 1 or Tiso != 2 or Tbulk != 3 or Tintr != 4)
        @compileError("ttname is indexed by transfer type");
    if (Fullspeed != 0 or Lowspeed != 1 or Highspeed != 2 or Nospeed != 3 or Superspeed != 4)
        @compileError("spname is indexed by speed");
}

fn assert(ok: bool) void {
    if (!ok) panic("usb: assert failed, pc %#p", .{@returnAddress()});
}

var debug: i32 = 0;
var hcitypes: [Nhcis]Hcitype = @splat(.{});
var hcis: [Nhcis]?*Hci = @splat(null);
var epslck: QLock = .{}; // add, del, lookup endpoints
var eps: [Neps]?*Ep = @splat(null); // all endpoints known
var epmax: i32 = 0; // 1 + last endpoint index used

// DIFF: the print macros of usb.h.
fn dprint(comptime format: []const u8, args: anytype) void {
    if (debug != 0) print(format, args);
}

fn ddprint(comptime format: []const u8, args: anytype) void {
    if (debug > 1) print(format, args);
}

fn deprint(ep: *const Ep, comptime format: []const u8, args: anytype) void {
    if (debug != 0 or ep.debug != 0) print(format, args);
}

fn ddeprint(ep: *const Ep, comptime format: []const u8, args: anytype) void {
    if (debug > 1 or ep.debug > 1) print(format, args);
}

/// DIFF: the C's s = seprint(s, se, ...): append at buf[p..] and return
/// the new end.
fn seprint(buf: []u8, p: usize, comptime format: []const u8, args: anytype) usize {
    return p + fmt.snprint(buf[p..], format, args).len;
}

/// DIFF: (1<<n)-1 for a number of ports; all ones from 32 ports on.
fn portmask(n: u32) u32 {
    if (n >= 32)
        return ~@as(u32, 0);
    return (@as(u32, 1) << @intCast(n)) - 1;
}

/// Is there something like this in a library? should it be?
pub fn seprintdata(buf: []u8, p_: usize, d: []const u8) usize {
    var p = seprint(buf, p_, " %#p[%d]: ", .{ @intFromPtr(d.ptr), d.len });
    var l = d.len;
    if (l > 10)
        l = 10;
    for (d[0..l]) |b|
        p = seprint(buf, p, " %2.2ux", .{b});
    if (l < d.len)
        p = seprint(buf, p, "...", .{});
    return p;
}

fn name2speed(name: []const u8) u32 {
    for (spname, 0..) |s, i| {
        if (std.mem.eql(u8, name, s))
            return @intCast(i);
    }
    return Nospeed;
}

fn name2ttype(name: []const u8) u32 {
    for (ttname, 0..) |s, i| {
        if (std.mem.eql(u8, name, s))
            return @intCast(i);
    }
    // may be a std. USB ep. type
    const i = netif.strtoul(name, 0).v;
    switch (i +% 1) {
        Tctl, Tiso, Tbulk, Tintr => return i + 1,
        else => return Tnone,
    }
}

fn name2mode(mode: []const u8) ?u32 {
    for (usbmodename, 0..) |s, i| {
        if (std.mem.eql(u8, mode, s))
            return @intCast(i);
    }
    return null;
}

fn qid2epidx(q_: i32) i32 {
    const q = @divTrunc(q_ - Qep0dir, 4);
    if (q < 0 or q >= epmax or eps[@intCast(q)] == null)
        return -1;
    return q;
}

fn isqtype(q_: i32, typ: i32) bool {
    if (q_ < Qep0dir)
        return false;
    const q = q_ - Qep0dir;
    return (q & 3) == typ;
}

var ntype: usize = 0;

pub fn addhcitype(t: []const u8, r: *const fn (*Hci) i32) void {
    if (ntype == Nhcis)
        panic("too many USB host interface types", .{});
    hcitypes[ntype].type = t;
    hcitypes[ntype].reset = r;
    ntype += 1;
}

fn rootport(ep: *Ep, port_: u32) u32 {
    const hp = ep.hp;
    const hub = ep.dev;
    if (hub.depth >= 0)
        return hub.rootport;

    var mask = hp.superspeed;
    if (hub.speed != Superspeed)
        mask = portmask(hp.nports) & ~mask;

    var port = port_;
    var rp: u32 = 1;
    while (mask != 0) : (rp += 1) {
        if (mask & 1 != 0) {
            port -%= 1;
            if (port == 0)
                return rp;
        }
        mask >>= 1;
    }

    return 0;
}

const dsnames = [_][]const u8{ "config", "enabled", "detached", "reset" };

fn seprintep(buf: []u8, s_: usize, ep: *Ep, all: bool) Error!usize {
    var s = s_;
    const d = ep.dev;

    try eqlock(&ep.qlock);
    defer qunlock(&ep.qlock);
    const di = ep.dev.nb;
    if (all)
        s = seprint(buf, s, "dev %d ep %d ", .{ di, ep.nb });
    s = seprint(buf, s, "%s", .{dsnames[ep.dev.state]});
    s = seprint(buf, s, " %s", .{ttname[ep.ttype]});
    assert(ep.mode == OREAD or ep.mode == OWRITE or ep.mode == ORDWR);
    s = seprint(buf, s, " %s", .{usbmodename[ep.mode]});
    s = seprint(buf, s, " speed %s", .{spname[d.speed]});
    s = seprint(buf, s, " maxpkt %ld", .{ep.maxpkt});
    s = seprint(buf, s, " ntds %d", .{ep.ntds});
    s = seprint(buf, s, " pollival %ld", .{ep.pollival});
    s = seprint(buf, s, " samplesz %ld", .{ep.samplesz});
    s = seprint(buf, s, " hz %ld", .{ep.hz});
    s = seprint(buf, s, " uframes %d", .{ep.uframes});
    s = seprint(buf, s, " hub %d", .{if (ep.dev.hub) |h| h.nb else 0});
    s = seprint(buf, s, " port %d", .{ep.dev.port});
    s = seprint(buf, s, " rootport %d", .{ep.dev.rootport});
    s = seprint(buf, s, " addr %d", .{ep.dev.addr});
    if (ep.inuse)
        s = seprint(buf, s, " busy", .{})
    else
        s = seprint(buf, s, " idle", .{});
    if (all) {
        s = seprint(buf, s, " load %uld", .{ep.load});
        s = seprint(buf, s, " ref %ld addr %#p", .{ ep.ref.ref, @intFromPtr(ep) });
        s = seprint(buf, s, " idx %d", .{ep.idx});
        if (ep.name) |name|
            s = seprint(buf, s, " name '%s'", .{name});
        if (ep.tmout != 0)
            s = seprint(buf, s, " tmout", .{});
        if (ep == ep.ep0) {
            s = seprint(buf, s, " ctlrno %#x", .{ep.hp.ctlrno});
            s = seprint(buf, s, " eps:", .{});
            for (d.eps, 0..) |e, i| {
                if (e != null)
                    s = seprint(buf, s, " ep%d.%d", .{ di, i });
            }
        }
    }
    if (ep.info) |info|
        s = seprint(buf, s, "\n%s %s\n", .{ info, ep.hp.isa.type })
    else
        s = seprint(buf, s, "\n", .{});
    return s;
}

fn epalloc(hp: *Hci) Error!*Ep {
    var i: usize = 0;
    while (i < Neps) : (i += 1) {
        if (eps[i] == null)
            break;
    }
    if (i == Neps)
        return proc.errorf("out of endpoints", .{});

    const ep = alloc.new(Ep) orelse return error.Enomem;
    ep.* = .{ .hp = hp };
    ep.ref.ref = 1;
    ep.idx = i;
    if (epmax <= i)
        epmax = @intCast(i + 1);
    eps[i] = ep;
    ep.hp = hp;
    ep.maxpkt = 8;
    ep.ntds = 1;
    // make them void
    ep.uframes = 0;
    ep.samplesz = 0;
    ep.pollival = 0;
    ep.hz = 0;
    ep.toggle[0] = 0;
    ep.toggle[1] = 0;
    return ep;
}

fn getep(i: i32) ?*Ep {
    if (i < 0 or i >= epmax or eps[@intCast(i)] == null)
        return null;
    qlock(&epslck);
    var ep = eps[@intCast(i)];
    if (ep) |e| {
        if (incref(&e.ref) == 1) {
            // race with putep() below, its dead.
            _ = decref(&e.ref);
            ep = null;
        }
    }
    qunlock(&epslck);
    return ep;
}

fn putep(ep_: ?*Ep) void {
    var next: ?*Ep = ep_;
    while (next) |ep| {
        if (decref(&ep.ref) > 0)
            return;
        assert(!ep.inuse);
        const d = ep.dev;
        deprint(ep, "usb: ep%d.%d %#p released\n", .{ d.nb, ep.nb, @intFromPtr(ep) });
        qlock(&ep.ep0.qlock);
        qlock(&epslck);
        assert(d.eps[ep.nb] == ep);
        d.eps[ep.nb] = null;
        assert(eps[ep.idx] == ep);
        eps[ep.idx] = null;
        if (ep.idx == epmax - 1) {
            while (epmax > 0 and eps[@intCast(epmax - 1)] == null)
                epmax -= 1;
        }
        qunlock(&epslck);
        qunlock(&ep.ep0.qlock);
        if (ep.ep0 != ep)
            next = ep.ep0
        else {
            next = if (d.hub) |h| h.eps[0] else null;
            if (ep.hp.devclose) |devclose|
                devclose(d);
            alloc.free(d);
        }
        if (ep.info) |s| alloc.free(s);
        if (ep.name) |s| alloc.free(s);
        alloc.free(ep);
    }
}

fn newusbid(_: *Hci) u32 {
    var map: [128]u8 = @splat(0);
    map[0] = 1; // dont use

    var id: u32 = 1;
    var i: usize = 0;
    while (i < epmax) : (i += 1) {
        const ep = eps[i] orelse continue;

        const d = ep.dev;
        map[d.nb % map.len] = 1;

        // try use largest id + 1
        if (d.nb >= id)
            id = d.nb + 1;
    }

    // once we ran out, use lowest possible free id
    if (id >= map.len) {
        for (map, 0..) |used, j| {
            if (used == 0)
                return @intCast(j);
        }
    }

    return id;
}

/// Create endpoint 0 for a new device on hub.
/// hub must be locked.
fn newdev(hp: *Hci, hub: ?*Ep, port: u32, speed: u32) Error!*Ep {
    const d = alloc.new(Udev) orelse return error.Enomem;
    errdefer alloc.free(d);
    d.* = .{};

    d.state = Dconfig; // address not yet set
    d.addr = 0;
    d.port = port;
    d.speed = speed;

    d.nports = 0;
    d.rootport = 0;
    d.routestr = 0;
    d.ttport = 0;
    d.ttt = 0;
    d.mtt = 0;
    d.tthub = null;

    d.rhrepl = usb.norepl;
    d.rhresetport = 0;

    if (hub) |h| {
        const dhub = h.dev;
        d.hub = dhub;
        d.depth = dhub.depth + 1;
        if (d.depth > 0) {
            assert(d.depth <= 5);
            d.routestr = dhub.routestr | (if (d.port < 15) d.port else 15) << @intCast(4 * (d.depth - 1));
            if (speed < Highspeed) {
                if (dhub.speed == Highspeed) {
                    d.tthub = dhub;
                    d.ttport = port;
                } else {
                    d.tthub = dhub.tthub;
                    d.ttport = dhub.ttport;
                }
            }
        }
        d.rootport = rootport(h, port);
        if (d.rootport <= 0)
            return proc.errorf("%s", .{Ebadport});
    } else {
        d.hub = null;
        d.depth = -1;
    }

    try eqlock(&epslck);
    defer qunlock(&epslck);
    d.nb = newusbid(hp);

    const ep = try epalloc(hp);
    ep.mode = ORDWR;
    ep.ttype = Tctl;
    ep.tmout = Xfertmout;

    if (speed == Superspeed)
        ep.maxpkt = 512
    else if (speed != Lowspeed)
        ep.maxpkt = 64 // assume full speed
    else
        ep.maxpkt = 8;

    ep.nb = 0;
    ep.ep0 = ep; // no ref counted here
    ep.dev = d;
    d.eps[0] = ep;
    if (hub) |h|
        _ = incref(&h.ref);
    _ = incref(&ep.ref);

    dprint("newdev %#p ep%d.%d %#p\n", .{ @intFromPtr(d), d.nb, ep.nb, @intFromPtr(ep) });
    return ep;
}

/// Create a new endpoint for the device
/// accessed via the given endpoint 0.
/// ep0 must be locked.
fn newdevep(ep0: *Ep, nb: u32, tt: u32, mode: u32) Error!*Ep {
    try eqlock(&epslck);
    defer qunlock(&epslck);
    const d = ep0.dev;
    if (d.eps[nb] != null)
        return error.Einuse;
    const ep = try epalloc(ep0.hp);
    ep.mode = mode;
    ep.ttype = tt;
    // set defaults
    switch (tt) {
        Tctl => ep.tmout = Xfertmout,
        Tintr => ep.pollival = 10,
        Tiso => {
            ep.tmout = Xfertmout;
            ep.pollival = 10;
            ep.samplesz = 1;
        },
        else => {},
    }
    ep.nb = nb;
    ep.ep0 = ep0;
    ep.dev = d;
    d.eps[nb] = ep;
    _ = incref(&ep0.ref);
    _ = incref(&ep.ref);

    deprint(ep, "newdevep ep%d.%d %#p\n", .{ d.nb, ep.nb, @intFromPtr(ep) });
    return ep;
}

fn epdataperm(mode: u32) u32 {
    switch (mode) {
        OREAD => return 0o440 | DMEXCL,
        OWRITE => return 0o220 | DMEXCL,
        else => return 0o660 | DMEXCL,
    }
}

fn usbgen(c: *Chan, _: ?[]const u8, _: []const Dirtab, s_: i32, dp: *Dir) i32 {
    var s = s_;
    const up = arch.up().?;

    if (false) ddprint("usbgen q %#x s %d...", .{ QID(c.qid), s });
    if (s == DEVDOTDOT) {
        if (QID(c.qid) <= Qusbdir) {
            devdir(c, mkqid(Qdir, 0, QTDIR), "#u", 0, proc.eve, 0o555, dp);
        } else {
            devdir(c, mkqid(Qusbdir, 0, QTDIR), "usb", 0, proc.eve, 0o555, dp);
        }
        if (false) ddprint("ok\n", .{});
        return 1;
    }

    const Where = enum { dir, usbdir, epdir };
    var where: Where = undefined;
    var nb: i32 = 0;
    var mode: u32 = 0;
    switch (QID(c.qid)) {
        Qdir => where = .dir,
        Qusbdir => where = .usbdir,
        Qctl => {
            s = 0;
            where = .usbdir;
        },
        else => {
            // list #u/usb/epN.M
            nb = qid2epidx(QID(c.qid));
            const ep = getep(nb) orelse {
                if (false) ddprint("fail\n", .{});
                return -1;
            };
            mode = ep.mode;
            putep(ep);
            if (isqtype(QID(c.qid), Qepdir)) {
                // as asked
            } else if (isqtype(QID(c.qid), Qepctl)) {
                s = 1;
            } else {
                s = 0;
            }
            where = .epdir;
        },
    }

    switch (where) {
        .dir => { // list #u
            if (s == 0) {
                devdir(c, mkqid(Qusbdir, 0, QTDIR), "usb", 0, proc.eve, 0o555, dp);
                if (false) ddprint("ok\n", .{});
                return 1;
            }
            s -= 1;
            if (s < 0 or s >= epmax) {
                if (false) ddprint("fail\n", .{});
                return -1;
            }
            const ep = getep(s);
            if (ep == null or ep.?.name == null) {
                putep(ep);
                if (false) ddprint("skip\n", .{});
                return 0;
            }
            const q = mkqid(@intCast(Qep0io + s * 4), 0, QTFILE);
            const name = fmt.snprint(&up.genbuf, "%s", .{ep.?.name.?});
            devdir(c, q, name, 0, proc.eve, epdataperm(ep.?.mode), dp);
            putep(ep);
            if (false) ddprint("ok\n", .{});
            return 1;
        },
        .usbdir => { // list #u/usb
            if (s < usbdir.len) {
                const dir = &usbdir[@intCast(s)];
                devdir(c, mkqid(dir.qid.path, 0, QTFILE), dir.name, dir.length, proc.eve, dir.perm, dp);
                if (false) ddprint("ok\n", .{});
                return 1;
            }
            s -= usbdir.len;
            if (s < 0 or s >= epmax) {
                if (false) ddprint("fail\n", .{});
                return -1;
            }
            const ep = getep(s) orelse {
                if (false) ddprint("skip\n", .{});
                return 0;
            };
            const name = fmt.snprint(&up.genbuf, "ep%d.%d", .{ ep.dev.nb, ep.nb });
            putep(ep);
            devdir(c, mkqid(@intCast(Qep0dir + 4 * s), 0, QTDIR), name, 0, proc.eve, 0o775, dp);
            if (false) ddprint("ok\n", .{});
            return 1;
        },
        .epdir => {
            switch (s) {
                0 => {
                    const perm = epdataperm(mode);
                    devdir(c, mkqid(@intCast(Qep0io + nb * 4), 0, QTFILE), "data", 0, proc.eve, perm, dp);
                },
                1 => {
                    devdir(c, mkqid(@intCast(Qep0ctl + nb * 4), 0, QTFILE), "ctl", 0, proc.eve, 0o664, dp);
                },
                else => {
                    if (false) ddprint("fail\n", .{});
                    return -1;
                },
            }
            if (false) ddprint("ok\n", .{});
            return 1;
        },
    }
}

/// DIFF: a private stand-in, as in devether.zig; belongs with the
/// platform.
/// from 9/pc/devarch.c
fn isaconfig(class: []const u8, ctlrno: usize, isa: *ISAConf) bool {
    var cc: [32]u8 = undefined;

    const name = fmt.snprint(&cc, "%s%d", .{ class, ctlrno });
    const p = arch.getconf(name) orelse
        return false;

    // the options stay slices into this copy, which is never freed
    var x: []u8 = portdat.nostr;
    proc.kstrdup(&x, p);

    isa.type = "";
    isa.nopt = parse.tokenize(x, &isa.opt);
    for (isa.opt[0..isa.nopt]) |o| {
        if (std.ascii.startsWithIgnoreCase(o, "type="))
            isa.type = o[5..]
        else if (std.ascii.startsWithIgnoreCase(o, "port="))
            isa.port = netif.strtou(u64, o[5..], 0).v
        else if (std.ascii.startsWithIgnoreCase(o, "irq="))
            isa.irq = @bitCast(netif.strtoul(o[4..], 0).v)
        else if (std.ascii.startsWithIgnoreCase(o, "dma="))
            isa.dma = netif.strtoul(o[4..], 0).v
        else if (std.ascii.startsWithIgnoreCase(o, "mem="))
            isa.mem = netif.strtoul(o[4..], 0).v
        else if (std.ascii.startsWithIgnoreCase(o, "size="))
            isa.size = netif.strtoul(o[5..], 0).v
        else if (std.ascii.startsWithIgnoreCase(o, "freq="))
            isa.freq = netif.strtoul(o[5..], 0).v;
    }
    return true;
}

fn hciprobe(cardno_: i32, ctlrno: u32) ?*Hci {
    var cardno = cardno_;

    ddprint("hciprobe %d %d\n", .{ cardno, ctlrno });
    const hp = alloc.new(Hci) orelse {
        print("hciprobe: out of memory\n", .{});
        return null;
    };
    hp.* = .{};

    hp.ctlrno = ctlrno;
    hp.tbdf = arch.BUSUNKNOWN;

    if (cardno < 0) {
        if (!isaconfig("usb", ctlrno, &hp.isa)) {
            alloc.free(hp);
            return null;
        }
        cardno = 0;
        while (cardno < Nhcis) : (cardno += 1) {
            const t = hcitypes[@intCast(cardno)].type orelse break;
            var typ = hp.isa.type;
            if (typ.len == 0)
                typ = "uhci";
            if (std.ascii.eqlIgnoreCase(t, typ))
                break;
        }
    }

    if (cardno >= Nhcis or hcitypes[@intCast(cardno)].type == null) {
        alloc.free(hp);
        return null;
    }
    dprint("%s...", .{hcitypes[@intCast(cardno)].type.?});
    if (hcitypes[@intCast(cardno)].reset(hp) < 0) {
        alloc.free(hp);
        return null;
    }
    return hp;
}

fn usbreset() void {
    if (arch.getconf("*nousbprobe") != null)
        return;
    dprint("usbreset\n", .{});

    var ctlrno: usize = 0;
    while (ctlrno < Nhcis) : (ctlrno += 1) {
        if (hciprobe(-1, @intCast(ctlrno))) |hp|
            hcis[ctlrno] = hp;
    }
    var cardno: usize = 0;
    ctlrno = 0;
    while (cardno < Nhcis and ctlrno < Nhcis and hcitypes[cardno].type != null) {
        if (hcis[ctlrno] != null)
            ctlrno += 1
        else {
            const hp = hciprobe(@intCast(cardno), @intCast(ctlrno));
            if (hp == null)
                cardno += 1;
            hcis[ctlrno] = hp;
            ctlrno += 1;
        }
    }
    if (hcis[Nhcis - 1] != null)
        print("usbreset: bug: Nhcis (%d) too small\n", .{Nhcis});
}

fn numbits(n_: u32) u32 {
    var n = n_;
    var c: u32 = 0;
    while (n != 0) {
        c += 1;
        n = (n -% 1) & n;
    }
    return c;
}

/// DIFF: the two blocks of usbinit that make a root hub.
fn newroothub(hp: *Hci, speed: u32, n: u32) Error!void {
    const up = arch.up().?;
    const d = try newdev(hp, null, 0, speed);
    d.dev.nports = n;
    d.dev.state = Denabled; // although addr == 0
    setstr(&d.info, fmt.snprint(&up.genbuf, "roothub ports %d", .{n}));
    putep(d);
}

fn usbinit() void {
    dprint("usbinit\n", .{});
    for (hcis, 0..) |h, ctlrno| {
        const hp = h orelse continue;

        if (hp.init) |init| {
            init(hp) catch |e| {
                print("usbinit: %s %d: %s\n", .{ hp.isa.type, ctlrno, proc.errtext(e) });
                continue;
            };
        }

        hp.superspeed &= portmask(hp.nports);
        var n = hp.nports - numbits(hp.superspeed);
        if (n > 0) {
            // new LS/FS/HS root hub
            newroothub(hp, if (hp.highspeed) Highspeed else Fullspeed, n) catch |e| {
                print("usbinit: %s %d: %s\n", .{ hp.isa.type, ctlrno, proc.errtext(e) });
                continue;
            };
        }
        n = numbits(hp.superspeed);
        if (n > 0) {
            // new SS root hub
            newroothub(hp, Superspeed, n) catch |e| {
                print("usbinit: %s %d: %s\n", .{ hp.isa.type, ctlrno, proc.errtext(e) });
                continue;
            };
        }
    }
}

/// DIFF: kstrdup for an optional string: replace *p with a copy of s.
fn setstr(p: *?[]u8, s: []const u8) void {
    const t = alloc.smalloc(s.len + 1);
    @memcpy(t[0..s.len], s);
    t[s.len] = 0;
    const prev = p.*;
    p.* = t[0..s.len];
    if (prev) |old| alloc.free(old);
}

fn usbattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('u', spec);
}

fn usbwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &.{}, usbgen);
}

fn usbstat(c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, &.{}, usbgen);
}

/// µs for the given transfer, for bandwidth allocation.
/// This is a very rough worst case for what 5.11.3
/// of the usb 2.0 spec says.
/// Also, we are using maxpkt and not actual transfer sizes.
/// Only when we are sure we
/// are not exceeding b/w might we consider adjusting it.
fn usbload(speed: u32, maxpkt: i32) u32 {
    const Hostns = 1000;
    const Hubns = 333;

    var l: u32 = 0;
    const bs: u32 = 10 *% @as(u32, @bitCast(maxpkt));
    switch (speed) {
        Highspeed => l = 55 * 8 * 2 + 2 *% (3 +% bs) + Hostns,
        Fullspeed => l = 9107 + 84 *% (4 +% bs) + Hostns,
        Lowspeed => l = 64107 + 2 * Hubns + 667 *% (3 +% bs) + Hostns,
        else => {
            print("usbload: bad speed %d\n", .{speed});
            // let it run
        },
    }
    return l / 1000; // in µs
}

fn isotiming(ep: *Ep) Error!void {
    var max: i32 = switch (ep.dev.speed) {
        Fullspeed => 1024,
        Highspeed => 3 * 1024,
        Superspeed => 48 * 1024,
        else => return error.Egreg,
    };

    if (ep.ntds <= 0)
        return error.Egreg;
    max = @divTrunc(max, ep.ntds);
    if (max < ep.samplesz)
        return error.Egreg;
    if (ep.pollival <= 0)
        return error.Egreg;

    var spp: i32 = undefined;
    if (ep.hz <= 0) {
        spp = @divTrunc(ep.maxpkt, ep.samplesz);
        spp *%= ep.ntds;
        if (ep.dev.speed == Fullspeed or ep.dev.speed == Lowspeed)
            ep.hz = @divTrunc(1000 *% spp, ep.pollival)
        else
            ep.hz = @divTrunc(8000 *% spp, ep.pollival);
        if (ep.hz <= 0)
            return error.Egreg;
    }
    if (ep.dev.speed == Fullspeed or ep.dev.speed == Lowspeed)
        spp = @divTrunc(ep.hz *% ep.pollival +% 999, 1000)
    else
        spp = @divTrunc(ep.hz *% ep.pollival +% 7999, 8000);
    spp = @divTrunc(spp, ep.ntds);
    ep.maxpkt = spp *% ep.samplesz;
    if (ep.maxpkt > max) {
        print("ep%d.%d: maxpkt %ld > %ld for %s, truncating\n", .{
            ep.dev.nb,            ep.nb,
            ep.maxpkt,            max,
            spname[ep.dev.speed],
        });
        ep.maxpkt = max;
    }
}

fn usbopen(c: *Chan, omode: u32) Error!*Chan {
    const mode = try devmod.openmode(omode);
    const q = QID(c.qid);
    if (q >= Qep0dir and qid2epidx(q) < 0)
        return error.Eio;
    if (q < Qep0dir or isqtype(q, Qepctl) or isqtype(q, Qepdir))
        return devmod.devopen(c, omode, &.{}, usbgen);
    const ep = getep(qid2epidx(q)) orelse
        return error.Eio;
    deprint(ep, "usbopen q %#x fid %d omode %d\n", .{ q, c.fid, mode });
    errdefer putep(ep);
    {
        try eqlock(&ep.qlock);
        defer qunlock(&ep.qlock);
        if (ep.ttype == Tnone)
            return proc.errorf("%s", .{Enotconf});
        if (mode != OREAD and ep.mode == OREAD)
            return error.Eperm;
        if (mode != OWRITE and ep.mode == OWRITE)
            return error.Eperm;
        if (ep.inuse)
            return error.Einuse;
        if (ep.dev.state == Ddetach)
            return proc.errorf("%s", .{Edetach});
        ep.clrhalt = false;
        if (ep.ttype == Tctl)
            ep.dev.rhrepl = usb.norepl;
        if (ep.ttype == Tiso)
            try isotiming(ep);
        if (ep.load == 0 and ep.dev.speed != Superspeed)
            ep.load = usbload(ep.dev.speed, ep.maxpkt);
        try ep.hp.epopen.?(ep);
        ep.inuse = true;
    }
    // don't putep(): ref kept for fid using the ep.

    c.mode = @intCast(mode);
    c.flag |= COPEN;
    c.offset = 0;
    c.aux = null; // paranoia
    return c;
}

fn usbclose(c: *Chan) Error!void {
    const q = QID(c.qid);
    if (q < Qep0dir or isqtype(q, Qepctl) or isqtype(q, Qepdir))
        return;

    if ((c.flag & COPEN) == 0)
        return;

    alloc.free(c.aux);
    c.aux = null;
    c.flag &= ~@as(@TypeOf(c.flag), COPEN);

    const ep = getep(qid2epidx(q)) orelse
        return;

    deprint(ep, "usbclose q %#x fid %d ref %ld\n", .{ q, c.fid, ep.ref.ref });
    qlock(&ep.qlock);
    if (!ep.inuse)
        qunlock(&ep.qlock)
    else {
        stop: {
            if (ep.hp.epstop) |epstop|
                epstop(ep) catch break :stop;
            if (ep.hp.epclose) |epclose|
                epclose(ep) catch break :stop;
        }
        ep.inuse = false;
        ep.aux = null;
        qunlock(&ep.qlock);
        putep(ep); // release ref from usbopen()
    }
    putep(ep); // release ref of getep() above
}

fn ctlread(c: *Chan, a: []u8, offset: i64) Error!usize {
    const q = QID(c.qid);
    const us = alloc.smalloc(READSTR)[0..READSTR];
    defer alloc.free(us);
    var s: usize = 0;
    if (q == Qctl) {
        var i: i32 = 0;
        while (i < epmax) : (i += 1) {
            if (getep(i)) |ep| {
                defer putep(ep);
                s = seprint(us, s, "ep%d.%d ", .{ ep.dev.nb, ep.nb });
                s = try seprintep(us, s, ep, false);
            }
        }
    } else {
        const ep = getep(qid2epidx(q)) orelse
            return error.Eio;
        defer putep(ep);
        if (c.aux) |aux| {
            // After a new endpoint request we read
            // the new endpoint name back.
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(aux)), 0);
            s = seprint(us, s, "%s", .{name});
            alloc.free(aux);
            c.aux = null;
        } else {
            s = try seprintep(us, s, ep, false);
        }
    }
    // (ulong)offset
    return devcons.readstr(@as(u32, @truncate(@as(u64, @bitCast(offset)))), a, us[0..s]);
}

// Fake root hub emulation.

fn rhubread(ep: *Ep, a: []u8) ?usize {
    var b: [8]u8 = undefined;

    const dev = ep.dev;

    if (dev.depth >= 0 or ep.nb != 0 or a.len < 2 or dev.rhrepl == usb.norepl)
        return null;

    std.mem.writeInt(u64, &b, dev.rhrepl, .little);

    dev.rhrepl = usb.norepl;

    var n = a.len;
    if (n > b.len)
        n = b.len;
    @memcpy(a[0..n], b[0..n]);

    return n;
}

fn rhubwrite(ep: *Ep, s: []const u8) Error!?usize {
    const up = arch.up().?;
    const hp = ep.hp;
    const dev = ep.dev;

    if (dev.depth >= 0 or ep.nb != 0)
        return null;
    if (s.len != usb.Rsetuplen)
        return proc.errorf("root hub is a toy hub", .{});
    if (s[usb.Rtype] != (usb.Rh2d | usb.Rclass | usb.Rother) and s[usb.Rtype] != (usb.Rd2h | usb.Rclass | usb.Rother))
        return proc.errorf("root hub is a toy hub", .{});

    // terminate previous port reset
    var port = dev.rhresetport;
    if (port > 0) {
        dev.rhresetport = 0;

        // Some controllers have to clear reset and set enable manually.
        // We assume that clearing reset will transition the bus from
        // SE0 to idle state, and setting enable starts transmitting
        // SOF packets (keep alive).
        //
        // The delay between clearing reset and setting enable must
        // not exceed 3ms as this makes devices suspend themselfs.
        if (hp.portreset) |portreset| {
            portreset(hp, port, false);
            try proc.tsleep(&up.sleep, proc.return0, null, 2);
        }
        if (hp.portenable) |portenable| {
            portenable(hp, port, true);
            try proc.tsleep(&up.sleep, proc.return0, null, 2);
        }
    }

    const cmd = s[usb.Rreq];
    const feature = GET2(s.ptr + usb.Rvalue);
    port = rootport(ep, GET2(s.ptr + usb.Rindex));
    if (port <= 0)
        return proc.errorf("%s", .{Ebadport});

    dev.rhrepl = 0;
    switch (feature) {
        Rportpower => {
            if (hp.portpower) |portpower|
                portpower(hp, port, cmd == usb.Rsetfeature);
        },
        Rportenable => {
            if (cmd == usb.Rclearfeature) {
                if (hp.portenable) |portenable|
                    portenable(hp, port, false);
            }
        },
        Rbhportreset => {
            if (cmd == usb.Rsetfeature) {
                if (hp.bhportreset) |bhportreset|
                    bhportreset(hp, port, true);
            }
        },
        Rportreset => {
            if (cmd == usb.Rsetfeature) {
                if (hp.portreset) |portreset| {
                    portreset(hp, port, true);
                    // port reset in progress
                    dev.rhresetport = port;
                }
            }
        },
        usb.Rgetstatus => {
            if (hp.portstatus) |portstatus|
                dev.rhrepl = portstatus(hp, port);
        },
        else => {},
    }
    return s.len;
}

fn usbread(c: *Chan, a: []u8, offset: i64) Error!usize {
    const up = arch.up().?;
    const q = QID(c.qid);

    if (c.qid.type == QTDIR)
        return devmod.devdirread(c, a, &.{}, usbgen);

    if (q == Qctl or isqtype(q, Qepctl))
        return ctlread(c, a, offset);

    const ep = getep(qid2epidx(q)) orelse
        return error.Eio;
    defer putep(ep);
    if (ep.mode == OWRITE or !ep.inuse)
        return error.Ebadusefd;
    if (ep.dev.state == Ddetach)
        return proc.errorf("%s", .{Edetach});

    switch (ep.ttype) {
        Tnone => return proc.errorf("%s", .{Enotconf}),
        Tctl => {
            if (rhubread(ep, a)) |nr|
                return nr;
            // else fall
        },
        else => {},
    }
    ddeprint(ep, "\nusbread q %#x fid %d cnt %ld off %lld\n", .{ q, c.fid, a.len, offset });
    while (true) {
        const nr = try ep.hp.epread.?(ep, a);
        if (nr == 0 and ep.ttype == Tiso and ep.dev.state != Ddetach) {
            try proc.tsleep(&up.sleep, proc.return0, null, @intCast(2 * ep.pollival));
            continue;
        }
        return nr;
    }
}

/// Many endpoint ctls. simply update the portable representation
/// of the endpoint. The actual controller driver will look
/// at them to setup the endpoints as dictated.
fn epctl(ep: *Ep, c: *Chan, a: []const u8) Error!usize {
    const up = arch.up().?;
    var n = a.len;

    const cb = try parse.parsecmd(a);
    defer alloc.free(cb);
    const ct = try parse.lookupcmd(cb, &epctls);
    deprint(ep, "usb epctl %s\n", .{cb.f[0]});
    const i = ct.index;
    if (i == CMnew or i == CMnewdev or i == CMhub or i == CMpreset or i == CMaddress)
        if (ep != ep.ep0)
            return proc.errorf("allowed only on a setup endpoint", .{});
    try eqlock(&ep.qlock);
    // DIFF: the detach request gives the lock up early.
    var locked = true;
    defer if (locked) qunlock(&ep.qlock);
    const d = ep.dev;
    if (d.state == Ddetach)
        return proc.errorf("%s", .{Edetach});
    switch (i) {
        CMnew => {
            const nb = netif.strtoul(cb.f[1], 0).v;
            if (nb >= Ndeveps)
                return proc.errorf("bad endpoint number", .{});
            const tt = name2ttype(cb.f[2]);
            if (tt == Tnone)
                return proc.errorf("%s", .{Ebadtype});
            const mode = name2mode(cb.f[3]) orelse
                return proc.errorf("unknown i/o mode", .{});
            const nep = try newdevep(ep, nb, tt, mode);
            nep.debug = ep.debug;
            putep(nep);
        },
        CMnewdev => {
            if (d.state != Denabled)
                return proc.errorf("%s", .{Edisabled});
            const l = name2speed(cb.f[1]);
            if (l == Nospeed)
                return proc.errorf("speed must be full|low|high|super", .{});
            if (l != d.speed) {
                // a high speed hub takes full and low speed devices, a
                // full speed one low speed devices
                const ok = switch (d.speed) {
                    Highspeed => l == Fullspeed or l == Lowspeed,
                    Fullspeed => l == Lowspeed,
                    else => false,
                };
                if (!ok)
                    return proc.errorf("wrong speed for hub/device", .{});
            }
            const port = netif.strtoul(cb.f[2], 0).v;
            if (port < 1 or port > d.nports)
                return proc.errorf("%s", .{Ebadport});
            const nep = try newdev(ep.hp, ep, port, l);
            // next read request will read
            // the name for the new endpoint
            const name = fmt.snprint(&up.genbuf, "ep%d.%d", .{ nep.dev.nb, nep.nb });
            var aux: ?[]u8 = null;
            setstr(&aux, name);
            alloc.free(c.aux);
            c.aux = aux.?.ptr;
            putep(nep);
        },
        CMdetach => {
            if (d.depth < 0)
                return proc.errorf("can't detach a root hub", .{});
            d.state = Ddetach;
            qunlock(&ep.qlock);
            locked = false;
            for (&d.eps) |*e| {
                const dep = e.* orelse continue;
                qlock(&dep.qlock);
                if (dep.inuse) {
                    if (dep.hp.epstop) |epstop|
                        epstop(dep) catch {};
                }
                qunlock(&dep.qlock);
                putep(dep);
            }
            return n;
        },
        CMpreset => {
            if (d.state != Denabled)
                return proc.errorf("%s", .{Edisabled});
            d.state = Dreset;
        },
        CMdebugep => {
            if (std.mem.eql(u8, cb.f[1], "on"))
                ep.debug = 1
            else if (std.mem.eql(u8, cb.f[1], "off"))
                ep.debug = 0
            else
                ep.debug = @bitCast(netif.strtoul(cb.f[1], 0).v);
            print("usb: ep%d.%d debug %d\n", .{ d.nb, ep.nb, ep.debug });
        },
        CMclrhalt => ep.clrhalt = true,
        CMaddress => {
            if (d.state != Dconfig)
                return proc.errorf("address already set", .{});
            if (d.addr == 0)
                d.addr = d.nb & Devmax;
            d.state = Denabled;
        },
        CMhub => {
            if (cb.nf < 2)
                return error.Ebadctl;
            if (ep.inuse)
                return error.Einuse;
            if (d.depth >= 5)
                return proc.errorf("hub depth exceeded", .{});
            const port = netif.strtoul(cb.f[1], 0).v;
            if (port < 1 or port > 127 or (port > 15 and d.speed == Superspeed))
                return proc.errorf("%s", .{Ebadport});
            d.nports = port;
            if (d.speed == Highspeed and cb.nf >= 4) {
                d.ttt = netif.strtoul(cb.f[2], 0).v & 3;
                d.mtt = @intFromBool(netif.strtoul(cb.f[3], 0).v != 0);
            }
        },
        CMmaxpkt => {
            if (ep.inuse)
                return error.Einuse;
            const l: i32 = @bitCast(netif.strtoul(cb.f[1], 0).v);
            if (l < 1 or l > 1024)
                return proc.errorf("maxpkt not in [1:1024]", .{});
            ep.maxpkt = l;
            ep.hz = 0; // recalculate
        },
        CMntds => {
            if (ep.inuse)
                return error.Einuse;
            const l: i32 = @bitCast(netif.strtoul(cb.f[1], 0).v);
            if (l < 1 or l > 3)
                return proc.errorf("ntds not in [1:3]", .{});
            ep.ntds = l;
            ep.hz = 0; // recalculate
        },
        CMpollival => {
            if (ep.ttype != Tintr and ep.ttype != Tiso)
                return proc.errorf("%s", .{Ebadtype});
            if (ep.inuse)
                return error.Einuse;
            var l: i32 = @bitCast(netif.strtoul(cb.f[1], 0).v);
            if (d.speed == Fullspeed or d.speed == Lowspeed) {
                if (l < 1 or l > 255)
                    return proc.errorf("pollival not in [1:255]", .{});
            } else {
                if (l < 1 or l > 16)
                    return proc.errorf("pollival power not in [1:16]", .{});
                l = @as(i32, 1) << @intCast(l - 1);
            }
            ep.pollival = l;
            ep.hz = 0; // recalculate
        },
        CMtmout => {
            if (ep.ttype == Tiso or ep.ttype == Tctl)
                return proc.errorf("%s", .{Ebadtype});
            if (ep.inuse)
                return error.Einuse;
            var l: i32 = @bitCast(netif.strtoul(cb.f[1], 0).v);
            if (l != 0 and l < Xfertmout)
                l = Xfertmout;
            ep.tmout = l;
        },
        CMhz => {
            if (ep.ttype != Tiso)
                return proc.errorf("%s", .{Ebadtype});
            if (ep.inuse)
                return error.Einuse;
            const l: i32 = @bitCast(netif.strtoul(cb.f[1], 0).v);
            if (l <= 0 or l > 1000000000)
                return proc.errorf("hz not in [1:1000000000]", .{});
            ep.hz = l;
        },
        CMsamplesz => {
            if (ep.ttype != Tiso)
                return proc.errorf("%s", .{Ebadtype});
            if (ep.inuse)
                return error.Einuse;
            const l: i32 = @bitCast(netif.strtoul(cb.f[1], 0).v);
            if (l <= 0 or l > 8)
                return proc.errorf("samplesz not in [1:8]", .{});
            ep.samplesz = l;
        },
        CMsampledelay => {
            if (ep.ttype != Tiso)
                return proc.errorf("%s", .{Ebadtype});
            if (ep.inuse)
                return error.Einuse;
            const l: i32 = @bitCast(netif.strtoul(cb.f[1], 0).v);
            ep.sampledelay = l;
        },
        CMuframes => {
            if (ep.ttype != Tiso)
                return proc.errorf("%s", .{Ebadtype});
            if (ep.inuse)
                return error.Einuse;
            const l: i32 = @bitCast(netif.strtoul(cb.f[1], 0).v);
            if (l != 0 and l != 1)
                return proc.errorf("uframes not in [0:1]", .{});
            ep.uframes = l;
        },
        CMname => {
            if (ep.inuse)
                return error.Einuse;
            const s = cb.f[1];
            if (s.len >= up.genbuf.len)
                return error.Etoolong;
            try chan.validname(s, false);
            setstr(&ep.name, s);
        },
        CMinfo => {
            // "info "
            if (n < 5)
                return error.Ebadctl;
            var s = a[5..];
            // As in the C, the count returned is short by these five.
            n -= 5;
            if (std.mem.findScalar(u8, s, 0)) |k|
                s = s[0..k];
            if (std.mem.findScalar(u8, s, '\n')) |k|
                s = s[0..k];
            setstr(&ep.info, s);
        },
        else => return error.Ebadctl,
    }
    return n;
}

fn usbctl(a: []const u8) Error!usize {
    const cb = try parse.parsecmd(a);
    defer alloc.free(cb);
    const ct = try parse.lookupcmd(cb, &usbctls);
    dprint("usb ctl %s\n", .{cb.f[0]});
    switch (ct.index) {
        CMdebug => {
            if (std.mem.eql(u8, cb.f[1], "on"))
                debug = 1
            else if (std.mem.eql(u8, cb.f[1], "off"))
                debug = 0
            else
                debug = @bitCast(netif.strtoul(cb.f[1], 0).v);
            var i: i32 = 0;
            while (i < epmax) : (i += 1) {
                if (getep(i)) |ep| {
                    if (ep.hp.debug) |setdebug|
                        setdebug(ep.hp, debug);
                    putep(ep);
                }
            }
        },
        else => {},
    }
    return a.len;
}

fn ctlwrite(c: *Chan, a: []const u8) Error!usize {
    const q = QID(c.qid);
    if (q == Qctl)
        return usbctl(a);

    const ep = getep(qid2epidx(q)) orelse
        return error.Eio;
    defer putep(ep);
    if (ep.dev.state == Ddetach)
        return proc.errorf("%s", .{Edetach});

    if (isqtype(q, Qepctl) and c.aux != null) {
        // Be sure we don't keep a cloned ep name
        alloc.free(c.aux);
        c.aux = null;
        return proc.errorf("read, not write, expected", .{});
    }
    return epctl(ep, c, a);
}

fn usbwrite(c: *Chan, a: []const u8, off: i64) Error!usize {
    if (c.qid.type == QTDIR)
        return error.Eisdir;

    const q = QID(c.qid);

    if (q == Qctl or isqtype(q, Qepctl))
        return ctlwrite(c, a);

    const ep = getep(qid2epidx(q)) orelse
        return error.Eio;
    defer putep(ep);
    if (ep.mode == OREAD or !ep.inuse)
        return error.Ebadusefd;
    if (ep.dev.state == Ddetach)
        return proc.errorf("%s", .{Edetach});

    switch (ep.ttype) {
        Tnone => return proc.errorf("%s", .{Enotconf}),
        Tctl => {
            if (try rhubwrite(ep, a)) |nr|
                return nr;
            // else fall
        },
        else => {},
    }
    ddeprint(ep, "\nusbwrite q %#x fid %d cnt %ld off %lld\n", .{ q, c.fid, a.len, off });
    _ = try ep.hp.epwrite.?(ep, a);
    return a.len;
}

pub fn usbshutdown() void {
    for (hcis) |h| {
        const hp = h orelse continue;
        if (hp.shutdown) |shutdown|
            shutdown(hp)
        else
            print("#u: no shutdown function for %s\n", .{hp.isa.type});
    }
}

pub const usbdevtab: devmod.Dev = .{
    .dc = 'u',
    .name = "usb",

    .reset = usbreset,
    .init = usbinit,
    .shutdown = usbshutdown,
    .attach = usbattach,
    .walk = usbwalk,
    .stat = usbstat,
    .open = usbopen,
    .close = usbclose,
    .read = usbread,
    .write = usbwrite,
};
