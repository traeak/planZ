//! usbfake - a USB bus made of files, for the tests of the USB
//! programs (tools/usbzig.rc): what the kernel's #u serves, with
//! devices that are tables in usbfake/models.zig.  Mounted over
//! /dev/usb in a name space of its own, it is what nusb's usbd, kb
//! and disk (9front's and planZ's alike) open, and its ctl file is
//! the record of what they did.
//!
//! usage: usbfake [ -m mtpt ] scene
//!
//! The scenes:
//!     hub         two root hubs (ep1.0 high speed, ep2.0 super speed) with
//!                 nothing in their ports; devices come with "plug"
//!     hid         keyboards, mice and a tablet, as if enumerated:
//!                 ep211.0 and up
//!     disk        mass storage devices: ep221.0 and up
//!     desc        devices with descriptors of every sort, for the
//!                 library's parser: ep231.0 and up
//!
//! The files are the kernel's (port/devusb.c is the model, not the
//! programs): a ctl and an epN.M directory for each endpoint, with ctl
//! and data in it.  A control request is a write of the setup packet
//! and data to epN.0/data, and the reply the read after it; "new" and
//! "newdev" written to a ctl file are followed by a read of the name
//! of what was made, on the same file descriptor.
//!
//! The ctl file in the root is the test's: reading it gives the record
//! (each ctl message and each control request, and for a disk each
//! command; a hub's port status is in it only when it changes), and
//! it takes (the lines "held" and "reports done" say where the reads of
//! an interrupt endpoint are; with two endpoints their order is not
//! fixed, and the test leaves them out of what it compares)
//!     plug hub port model
//!                 a device appears in the port of hub epN.0
//!     unplug hub port
//!                 and goes
//!     go          the reads that are held go on (the first read of
//!                 an interrupt endpoint is held, and those a model
//!                 says; "held" in the record says one waits)
//!     end id [ep] the device's reads fail from now on (or those of
//!                 one endpoint)

const std = @import("std");
const libc = @import("libc");
const p9 = @import("9p");
const models = @import("usbfake/models.zig");
const sys = libc.sys;
const fcall = libc.fcall;

const Req = p9.Req;
const Fid = p9.Fid;
const Dir = p9.Dir;
const Qid = p9.Qid;
const respond = p9.respond;
const Model = models.Model;

// the kernel's texts
const Estall = "endpoint stalled";
const Edetach = "device is detached";
const Edisabled = "device is not enabled";
const Ebadtype = "bad endpoint type";
const Ebadport = "bad hub port number";
const Enonexist = "file does not exist";
const Eio = "i/o error";
const Einuse = "device or object already in use";
const Eperm = "permission denied";
const Ebadusefd = "inappropriate use of fd";
const Ebadctl = "unknown control message";
const Ecmdargs = "wrong #args in control message";

// port status, as usbd has it
const PSpresent = 0x0001;
const PSenable = 0x0002;
const PSsuspend = 0x0004;
const PSreset = 0x0010;
const PSpower = 0x0100;
const PSslow = 0x0200;
const PShigh = 0x0400;

const Port = struct {
    sts: u32 = 0,
    /// the status last put in the record
    told: u32 = 0xFFFFFFFF,
    model: ?*const Model = null,
    child: ?*Dev = null,
};

const Endp = struct {
    used: bool = false,
    type: u32 = 0,
    mode: []const u8 = "rw",
    maxpkt: u32 = 8,
    ntds: u32 = 1,
    pollival: u32 = 0,
    /// its data file is open
    inuse: bool = false,
    /// its reads fail from now on
    ended: bool = false,
    /// which of the model's reports comes next
    next: usize = 0,
    /// the first read waits for "go"
    started: bool = false,
    /// said in the record: a read waits, the reports are at an end
    saidheld: bool = false,
    saiddone: bool = false,
};

/// What a read of a disk's bulk endpoint gives next.
const Chunk = struct {
    data: []u8,
    /// answered only after "go"
    hold: bool = false,
    /// the read fails
    stall: bool = false,
};

const Lun = struct {
    m: *const models.LunModel,
    data: []u8,
    /// test unit ready fails this many times more
    notready: u32,
    key: u8 = 0,
    asc: u8 = 0,
    ascq: u8 = 0,
};

const Dev = struct {
    model: *const Model,
    id: u32,
    slot: usize,
    /// as the kernel has it: a new device is in "config" until it
    /// has an address
    state: enum { config, enabled, detached, reset } = .config,
    detached: bool = false,
    ended: bool = false,
    /// how many ports "hub" said it has (a root hub has its own)
    hubports: u32 = 0,
    parent: ?*Dev = null,
    port: u32 = 0,
    depth: i32 = -1,
    addr: u32 = 0,
    info: []u8 = &.{},
    reply: []u8 = &.{},
    eps: [32]Endp = @splat(.{}),
    ports: []Port = &.{},
    // disk
    luns: []Lun = &.{},
    chunks: std.ArrayList(Chunk) = .empty,
    /// the command whose data is to come on the out endpoint
    cbw: ?[31]u8 = null,
    badtagdone: bool = false,
};

var devs: std.ArrayList(*Dev) = .empty;
var nextid: u32 = 1;
var log: std.ArrayList(u8) = .empty;
/// reads that wait: for a report that is held, or a disk's status
var waiting: std.ArrayList(*Req) = .empty;

/// A device put in a port or taken out, by the test.  Once a usbd is
/// asking the ports for their status, it happens when the round of
/// asking starts again (the first port of ep1.0), and the write that
/// asked for it is answered then: which round a device comes in is
/// not left to the time of day.
const PortEvent = struct {
    r: *Req,
    d: *Dev,
    port: u32,
    model: ?*const Model,
};
var events: std.ArrayList(PortEvent) = .empty;
var polled: bool = false;

fn portevent(ev: PortEvent) void {
    const p = &ev.d.ports[ev.port];
    if (ev.model) |m| {
        record("plug %d %d %s\n", .{ ev.d.id, ev.port, m.name });
        p.model = m;
        p.sts |= PSpresent;
        // a port of a usb 3 hub is enabled by the device that comes
        if (std.mem.eql(u8, ev.d.model.speed, "super"))
            p.sts |= PSenable;
    } else {
        record("unplug %d %d\n", .{ ev.d.id, ev.port });
        p.model = null;
        p.sts &= ~@as(u32, PSpresent | PSenable | PSslow | PShigh);
    }
    ev.r.ofcall.count = ev.r.ifcall.count;
    respond(ev.r, null);
}

const a = libc.allocator;

fn oom() noreturn {
    libc.sysfatal("out of memory", .{});
}

fn record(comptime format: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    log.appendSlice(a, libc.sprint(&buf, format, args)) catch oom();
}

fn hex(b: []const u8) Hex {
    return .{ .b = b };
}

const Hex = struct {
    b: []const u8,

    pub fn fmt9(self: Hex, f: *libc.fmt.Fmt) void {
        for (self.b) |c| {
            f.putc("0123456789abcdef"[c >> 4]);
            f.putc("0123456789abcdef"[c & 15]);
        }
    }
};

fn newdev(model: *const Model, id: u32, parent: ?*Dev, port: u32) *Dev {
    const d = a.create(Dev) catch oom();
    d.* = .{ .model = model, .id = id, .slot = devs.items.len, .parent = parent, .port = port };
    if (parent) |p|
        d.depth = p.depth + 1;
    d.eps[0] = .{ .used = true, .type = 0, .maxpkt = if (std.mem.eql(u8, model.speed, "super")) 512 else 64 };
    if (model.nports != 0) {
        d.ports = a.alloc(Port, @as(usize, model.nports) + 1) catch oom();
        @memset(d.ports, .{});
    }
    if (model.kind == .roothub) {
        d.state = .enabled;
        d.hubports = model.nports;
        // what the kernel says of a root hub before usbd names it
        var ib: [32]u8 = undefined;
        d.info = a.dupe(u8, libc.sprint(&ib, "roothub ports %d", .{model.nports})) catch oom();
    }
    if (model.luns.len != 0) {
        d.luns = a.alloc(Lun, model.luns.len) catch oom();
        for (d.luns, model.luns) |*l, *lm| {
            l.* = .{ .m = lm, .data = a.alloc(u8, lm.blocks * lm.bs) catch oom(), .notready = lm.notready };
            // each block says which it is
            for (l.data, 0..) |*c, i| {
                const lba = i / lm.bs;
                const off = i % lm.bs;
                c.* = @truncate(lba *% 7 +% off *% 13 +% (lba >> 8));
            }
        }
    }
    devs.append(a, d) catch oom();
    return d;
}

fn finddev(id: u32) ?*Dev {
    for (devs.items) |d| {
        if (d.id == id and !d.detached)
            return d;
    }
    return null;
}

// qid paths: 0 the root, 1 its ctl; for the device in slot s and its
// endpoint e, (s+1)<<8 | e<<2 | 0 for the directory, 1 ctl, 2 data
const Kdir = 0;
const Kctl = 1;
const Kdata = 2;

fn mkpath(d: *Dev, e: usize, k: u64) u64 {
    return (d.slot + 1) << 8 | e << 2 | k;
}

const Where = struct { d: *Dev, e: usize, k: u64 };

fn where(path: u64) Where {
    return .{ .d = devs.items[@intCast((path >> 8) - 1)], .e = @intCast((path >> 2) & 31), .k = path & 3 };
}

fn fsattach(r: *Req) void {
    r.fid.?.qid = .{ .path = 0, .vers = 0, .type = fcall.QTDIR };
    r.ofcall.qid = r.fid.?.qid;
    respond(r, null);
}

fn fswalk1(fid: *Fid, name: []const u8, qid: *Qid) ?[]const u8 {
    const path = fid.qid.path;
    if (path == 0) {
        if (std.mem.eql(u8, name, "..")) {
            qid.* = fid.qid;
            return null;
        }
        if (std.mem.eql(u8, name, "ctl")) {
            fid.qid = .{ .path = 1, .vers = 0, .type = 0 };
            qid.* = fid.qid;
            return null;
        }
        // epN.M
        if (!std.mem.startsWith(u8, name, "ep"))
            return Enonexist;
        const n = libc.strtoul(name[2..], 10);
        if (n.n == 0 or 2 + n.n >= name.len or name[2 + n.n] != '.')
            return Enonexist;
        const m = libc.strtoul(name[2 + n.n + 1 ..], 10);
        if (m.n == 0 or 2 + n.n + 1 + m.n != name.len or m.v >= 32)
            return Enonexist;
        const d = finddev(@truncate(n.v)) orelse return Enonexist;
        if (!d.eps[@intCast(m.v)].used)
            return Enonexist;
        fid.qid = .{ .path = mkpath(d, @intCast(m.v), Kdir), .vers = 0, .type = fcall.QTDIR };
        qid.* = fid.qid;
        return null;
    }
    if (path == 1 or (path & 3) != Kdir)
        return "not a directory";
    const w = where(path);
    if (std.mem.eql(u8, name, "..")) {
        fid.qid = .{ .path = 0, .vers = 0, .type = fcall.QTDIR };
    } else if (std.mem.eql(u8, name, "ctl")) {
        fid.qid = .{ .path = mkpath(w.d, w.e, Kctl), .vers = 0, .type = 0 };
    } else if (std.mem.eql(u8, name, "data")) {
        fid.qid = .{ .path = mkpath(w.d, w.e, Kdata), .vers = 0, .type = 0 };
    } else return Enonexist;
    qid.* = fid.qid;
    return null;
}

fn fillstat(d: *Dir, path: u64) void {
    var nb: [32]u8 = undefined;

    d.* = .{};
    d.qid = .{ .path = path, .vers = 0, .type = 0 };
    d.mode = 0o666;
    var name: []const u8 = "";
    if (path == 0) {
        name = "usb";
        d.qid.type = fcall.QTDIR;
        d.mode = fcall.DMDIR | 0o555;
    } else if (path == 1) {
        name = "ctl";
    } else {
        const w = where(path);
        switch (w.k) {
            Kdir => {
                name = libc.sprint(&nb, "ep%d.%d", .{ w.d.id, w.e });
                d.qid.type = fcall.QTDIR;
                d.mode = fcall.DMDIR | 0o775;
            },
            Kctl => {
                name = "ctl";
                d.mode = 0o664;
            },
            else => {
                name = "data";
                d.mode = 0o660;
            },
        }
    }
    d.name = p9.estrdup9p(name);
    d.uid = p9.estrdup9p("usb");
    d.gid = p9.estrdup9p("usb");
    d.muid = p9.estrdup9p("usb");
}

fn fsstat(r: *Req) void {
    fillstat(&r.d, r.fid.?.qid.path);
    respond(r, null);
}

fn rootgen(n: i32, d: *Dir, _: ?*anyopaque) bool {
    if (n == 0) {
        fillstat(d, 1);
        return true;
    }
    var i: i32 = 1;
    for (devs.items) |dv| {
        if (dv.detached)
            continue;
        for (dv.eps, 0..) |e, en| {
            if (!e.used)
                continue;
            if (i == n) {
                fillstat(d, mkpath(dv, en, Kdir));
                return true;
            }
            i += 1;
        }
    }
    return false;
}

fn epgen(n: i32, d: *Dir, aux: ?*anyopaque) bool {
    const path: u64 = @intFromPtr(aux);
    if (n > 1)
        return false;
    fillstat(d, (path & ~@as(u64, 3)) | @as(u64, if (n == 0) Kctl else Kdata));
    return true;
}

fn fsopen(r: *Req) void {
    const path = r.fid.?.qid.path;
    if (path > 1 and (path & 3) == Kdata) {
        // a data file is for one at a time, and for the endpoint's
        // direction
        const w = where(path);
        const e = &w.d.eps[w.e];
        const mode = r.ifcall.mode & 3;
        var err: ?[]const u8 = null;
        if (mode != sys.OREAD and std.mem.eql(u8, e.mode, "r"))
            err = Eperm
        else if (mode != sys.OWRITE and std.mem.eql(u8, e.mode, "w"))
            err = Eperm
        else if (e.inuse)
            err = Einuse
        else if (w.d.detached)
            err = Edetach;
        if (err) |t| {
            respond(r, t);
            return;
        }
        e.inuse = true;
    }
    respond(r, null);
}

/// What follows "new" or "newdev" on the same file: the name.
const Readback = struct {
    buf: [16]u8 = undefined,
    n: usize = 0,
};

fn fsdestroyfid(fid: *Fid) void {
    const path = fid.qid.path;
    if (path > 1 and (path & 3) == Kdata) {
        if (fid.omode != -1) {
            const w = where(path);
            w.d.eps[w.e].inuse = false;
        }
        return;
    }
    freereadback(fid);
}

fn freereadback(fid: *Fid) void {
    if (fid.aux) |p| {
        const rb: *Readback = @ptrCast(@alignCast(p));
        a.destroy(rb);
        fid.aux = null;
    }
}

fn speedof(d: *Dev) []const u8 {
    return d.model.speed;
}

fn ctltext(buf: []u8, d: *Dev, en: usize) []const u8 {
    const e = &d.eps[en];
    const ttname = [_][]const u8{ "control", "iso", "bulk", "interrupt" };
    var f: libc.fmt.Fmt = .{ .buf = buf };
    f.print("%s %s %s speed %s maxpkt %d ntds %d pollival %d samplesz 0 hz 0 uframes 0 hub %d port %d rootport %d addr %d %s\n", .{
        @tagName(d.state),
        ttname[e.type & 3],
        e.mode,
        speedof(d),
        e.maxpkt,
        e.ntds,
        e.pollival,
        if (d.parent) |p| p.id else 0,
        d.port,
        d.port,
        d.addr,
        if (e.inuse) "busy" else "idle",
    });
    if (en == 0 and d.info.len != 0)
        f.print("%s fake\n", .{d.info});
    return buf[0..f.n];
}

fn fsread(r: *Req) void {
    var buf: [512]u8 = undefined;
    const fid = r.fid.?;
    const path = fid.qid.path;

    if (path == 0) {
        p9.dirread9p(r, rootgen, null);
        respond(r, null);
        return;
    }
    if (path == 1) {
        p9.readstr(r, log.items);
        respond(r, null);
        return;
    }
    const w = where(path);
    switch (w.k) {
        Kdir => {
            p9.dirread9p(r, epgen, @ptrFromInt(path));
            respond(r, null);
        },
        Kctl => {
            if (w.d.detached) {
                respond(r, Edetach);
                return;
            }
            if (fid.aux) |p| {
                const rb: *Readback = @ptrCast(@alignCast(p));
                p9.readstr(r, rb.buf[0..rb.n]);
                freereadback(fid);
            } else p9.readstr(r, ctltext(&buf, w.d, w.e));
            respond(r, null);
        },
        else => dataread(r, w.d, w.e, false),
    }
}

fn answer(r: *Req, data: []const u8) void {
    const n = @min(data.len, r.ifcall.count);
    @memcpy(r.rbuf[0..n], data[0..n]);
    r.ofcall.count = @intCast(n);
    respond(r, null);
}

/// A read of a data file.  With pass, it is one that waited and "go"
/// was said: it goes past what held it.
fn dataread(r: *Req, d: *Dev, en: usize, pass: bool) void {
    if (d.detached) {
        respond(r, Edetach);
        return;
    }
    if (std.mem.eql(u8, d.eps[en].mode, "w") or !d.eps[en].inuse) {
        respond(r, Ebadusefd);
        return;
    }
    if (en == 0) {
        // the reply to the control request
        const rep = d.reply;
        d.reply = &.{};
        answer(r, rep);
        a.free(rep);
        return;
    }
    if (d.ended or d.eps[en].ended) {
        respond(r, Eio);
        return;
    }
    if (d.luns.len != 0) {
        diskread(r, d, pass);
        return;
    }
    // a report
    const e = &d.eps[en];
    var passed = pass;
    if (!e.started) {
        if (!gopast(&passed)) {
            holdread(r, d, en);
            return;
        }
        e.started = true;
        e.saidheld = false;
    }
    var i = e.next;
    while (i < d.model.reports.len) : (i += 1) {
        const rep = &d.model.reports[i];
        if (rep.ep != en)
            continue;
        if (rep.hold) {
            if (!gopast(&passed)) {
                e.next = i;
                holdread(r, d, en);
                return;
            }
            e.saidheld = false;
            continue;
        }
        e.next = i + 1;
        answer(r, rep.data);
        return;
    }
    // no more: it waits for the device's end
    e.next = i;
    if (!e.saiddone) {
        e.saiddone = true;
        record("ep%d.%d reports done\n", .{ d.id, en });
    }
    waiting.append(a, r) catch oom();
}

/// A "go" that found no read held is kept for the next that would
/// be: the test's "go" may come before the program's read.
var keptgo: bool = false;
var wentpast: bool = false;

/// Whether a read at a place where reads are held goes on: with the
/// "go" it waited for, or one that was kept.
fn gopast(passed: *bool) bool {
    if (passed.*) {
        passed.* = false;
        wentpast = true;
        return true;
    }
    if (keptgo) {
        keptgo = false;
        return true;
    }
    return false;
}

fn holdread(r: *Req, d: *Dev, en: usize) void {
    const e = &d.eps[en];
    if (!e.saidheld) {
        e.saidheld = true;
        record("ep%d.%d held\n", .{ d.id, en });
    }
    waiting.append(a, r) catch oom();
}

/// Go through the reads that wait again.
fn rerun(pass: bool) void {
    const old = waiting.toOwnedSlice(a) catch oom();
    defer a.free(old);
    for (old) |r| {
        const w = where(r.fid.?.qid.path);
        dataread(r, w.d, w.e, pass);
    }
}

fn fsflush(r: *Req) void {
    for (waiting.items, 0..) |o, i| {
        if (o == r.oldreq) {
            _ = waiting.orderedRemove(i);
            respond(o, "interrupted");
            break;
        }
    }
    respond(r, null);
}

fn words(s: []u8, f: [][]u8) [][]u8 {
    return f[0..libc.tokenize(s, f)];
}

fn num(s: []const u8) u32 {
    return @truncate(libc.strtoul(s, 0).v);
}

fn setreadback(fid: *Fid, d: *Dev, en: usize) void {
    freereadback(fid);
    const rb = a.create(Readback) catch oom();
    rb.* = .{};
    rb.n = libc.sprint(&rb.buf, "ep%d.%d", .{ d.id, en }).len;
    fid.aux = rb;
}

fn detach(d: *Dev) void {
    d.detached = true;
    d.state = .detached;
    // what waited on it fails
    const old = waiting.toOwnedSlice(a) catch oom();
    defer a.free(old);
    for (old) |r| {
        if (where(r.fid.?.qid.path).d == d)
            respond(r, Edetach)
        else
            waiting.append(a, r) catch oom();
    }
}

/// A message to an endpoint's ctl, as the kernel's epctl takes it.
fn ctlwrite(r: *Req, d: *Dev, en: usize) ?[]const u8 {
    var buf: [256]u8 = undefined;
    var fb: [8][]u8 = undefined;
    const fid = r.fid.?;
    const msg = r.ifcall.data[0..r.ifcall.count];

    if (d.detached)
        return Edetach;
    record("ep%d.%d ctl %s\n", .{ d.id, en, msg });
    if (fid.aux != null) {
        freereadback(fid);
        return "read, not write, expected";
    }
    const n = @min(msg.len, buf.len);
    @memcpy(buf[0..n], msg[0..n]);
    const f = words(buf[0..n], &fb);
    if (f.len == 0)
        return "empty control message";
    const Cmd = struct { name: []const u8, narg: usize };
    const cmds = [_]Cmd{
        .{ .name = "new", .narg = 4 },      .{ .name = "newdev", .narg = 3 },
        .{ .name = "detach", .narg = 1 },   .{ .name = "reset", .narg = 1 },
        .{ .name = "debug", .narg = 2 },    .{ .name = "clrhalt", .narg = 1 },
        .{ .name = "address", .narg = 1 },  .{ .name = "hub", .narg = 0 },
        .{ .name = "maxpkt", .narg = 2 },   .{ .name = "ntds", .narg = 2 },
        .{ .name = "pollival", .narg = 2 }, .{ .name = "timeout", .narg = 2 },
        .{ .name = "name", .narg = 2 },     .{ .name = "info", .narg = 0 },
    };
    const cmd = f[0];
    const ct = for (cmds) |c| {
        if (std.mem.eql(u8, c.name, cmd)) break c;
    } else return Ebadctl;
    if (ct.narg != 0 and ct.narg != f.len)
        return Ecmdargs;
    const is = struct {
        fn eq(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.eq;
    if (is(cmd, "new") or is(cmd, "newdev") or is(cmd, "hub") or is(cmd, "reset") or is(cmd, "address")) {
        if (en != 0)
            return "allowed only on a setup endpoint";
    }
    const e = &d.eps[en];
    const fast = is(d.model.speed, "high") or is(d.model.speed, "super");
    if (is(cmd, "new")) {
        const nb = libc.strtol(f[1], 0).v;
        if (nb < 0 or nb >= d.eps.len)
            return "bad endpoint number";
        const ttname = [_][]const u8{ "control", "iso", "bulk", "interrupt" };
        var tt: ?u32 = null;
        for (ttname, 0..) |tn, i| {
            if (is(f[2], tn)) tt = @intCast(i);
        }
        if (tt == null) {
            // may be a std. USB ep. type
            const v = libc.strtol(f[2], 0).v;
            if (v < 0 or v > 3)
                return Ebadtype;
            tt = @intCast(v);
        }
        var mode: []const u8 = undefined;
        if (is(f[3], "r")) mode = "r" else if (is(f[3], "w")) mode = "w" else if (is(f[3], "rw")) mode = "rw" else return "unknown i/o mode";
        if (d.eps[@intCast(nb)].used)
            return Einuse;
        d.eps[@intCast(nb)] = .{ .used = true, .type = tt.?, .mode = mode, .pollival = if (tt.? == 3 or tt.? == 1) 10 else 0 };
    } else if (is(cmd, "newdev")) {
        if (d.state != .enabled)
            return Edisabled;
        const sp = f[1];
        if (!is(sp, "full") and !is(sp, "low") and !is(sp, "high") and !is(sp, "super"))
            return "speed must be full|low|high|super";
        const hs = d.model.speed;
        if (!is(sp, hs)) {
            const ok = (is(hs, "high") and (is(sp, "full") or is(sp, "low"))) or (is(hs, "full") and is(sp, "low"));
            if (!ok)
                return "wrong speed for hub/device";
        }
        const port = num(f[2]);
        if (port < 1 or port > d.hubports or port >= d.ports.len)
            return Ebadport;
        const p = &d.ports[port];
        // the kernel makes a device whatever is in the port; here
        // there must be one, of that speed
        const m = p.model orelse return Ebadport;
        if (!is(sp, m.speed))
            return "wrong speed for hub/device";
        const nd = newdev(m, nextid, d, port);
        nextid += 1;
        p.child = nd;
        setreadback(fid, nd, 0);
    } else if (is(cmd, "detach")) {
        if (d.model.kind == .roothub)
            return "can't detach a root hub";
        detach(d);
    } else if (is(cmd, "reset")) {
        if (d.state != .enabled)
            return Edisabled;
        d.state = .reset;
    } else if (is(cmd, "address")) {
        if (d.state != .config)
            return "address already set";
        d.state = .enabled;
    } else if (is(cmd, "hub")) {
        if (f.len < 2)
            return Ebadctl;
        if (e.inuse)
            return Einuse;
        const port = num(f[1]);
        if (port < 1 or port > 127 or (port > 15 and is(d.model.speed, "super")))
            return Ebadport;
        d.hubports = port;
    } else if (is(cmd, "maxpkt")) {
        if (e.inuse)
            return Einuse;
        const l = num(f[1]);
        if (l < 1 or l > 1024)
            return "maxpkt not in [1:1024]";
        e.maxpkt = l;
    } else if (is(cmd, "ntds")) {
        if (e.inuse)
            return Einuse;
        const l = num(f[1]);
        if (l < 1 or l > 3)
            return "ntds not in [1:3]";
        e.ntds = l;
    } else if (is(cmd, "pollival")) {
        if (e.type != 3 and e.type != 1)
            return Ebadtype;
        if (e.inuse)
            return Einuse;
        var l = num(f[1]);
        if (!fast) {
            if (l < 1 or l > 255)
                return "pollival not in [1:255]";
        } else {
            if (l < 1 or l > 16)
                return "pollival power not in [1:16]";
            l = @as(u32, 1) << @intCast(l - 1);
        }
        e.pollival = l;
    } else if (is(cmd, "timeout")) {
        if (e.type == 1 or e.type == 0)
            return Ebadtype;
        if (e.inuse)
            return Einuse;
    } else if (is(cmd, "name")) {
        if (e.inuse)
            return Einuse;
    } else if (is(cmd, "info")) {
        if (msg.len < 5)
            return Ebadctl;
        a.free(d.info);
        const text = msg[5..];
        d.info = a.dupe(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len]) catch oom();
    }
    // debug and clrhalt are taken
    return null;
}

/// A message to the root's ctl; it answers the request.
fn rootctl(r: *Req) void {
    var buf: [128]u8 = undefined;
    var fb: [6][]u8 = undefined;
    const msg = r.ifcall.data[0..r.ifcall.count];
    const n = @min(msg.len, buf.len);
    @memcpy(buf[0..n], msg[0..n]);
    const f = words(buf[0..n], &fb);
    r.ofcall.count = r.ifcall.count;
    if (f.len == 0) {
        respond(r, "empty");
        return;
    }
    if (std.mem.eql(u8, f[0], "go")) {
        respond(r, null);
        wentpast = false;
        rerun(true);
        if (!wentpast)
            keptgo = true;
        return;
    }
    if (std.mem.eql(u8, f[0], "end") and (f.len == 2 or f.len == 3)) {
        const d = finddev(num(f[1])) orelse {
            respond(r, "no such device");
            return;
        };
        if (f.len == 3) {
            const en = num(f[2]);
            if (en == 0 or en >= d.eps.len) {
                respond(r, "no such endpoint");
                return;
            }
            d.eps[en].ended = true;
        } else d.ended = true;
        respond(r, null);
        rerun(false);
        return;
    }
    if ((std.mem.eql(u8, f[0], "plug") and f.len == 4) or (std.mem.eql(u8, f[0], "unplug") and f.len == 3)) {
        const d = finddev(num(f[1])) orelse {
            respond(r, "no such hub");
            return;
        };
        const port = num(f[2]);
        if (port == 0 or port >= d.ports.len) {
            respond(r, "no such port");
            return;
        }
        var m: ?*const Model = null;
        if (f[0][0] == 'p') {
            m = models.find(f[3]) orelse {
                respond(r, "no such model");
                return;
            };
        }
        const ev: PortEvent = .{ .r = r, .d = d, .port = port, .model = m };
        if (polled)
            events.append(a, ev) catch oom()
        else
            portevent(ev);
        return;
    }
    respond(r, "unknown");
}

fn setreply(d: *Dev, data: []const u8, len: usize) void {
    a.free(d.reply);
    d.reply = a.dupe(u8, data[0..@min(data.len, len)]) catch oom();
}

/// A control request written to epN.0/data: the setup packet and what
/// follows it.
fn control(d: *Dev, msg: []const u8) ?[]const u8 {
    if (msg.len < 8)
        return "short setup";
    const typ = msg[0];
    const req = msg[1];
    const value = @as(u32, msg[3]) << 8 | msg[2];
    const index = @as(u32, msg[5]) << 8 | msg[4];
    const len: usize = @as(u32, msg[7]) << 8 | msg[6];
    const m = d.model;

    a.free(d.reply);
    d.reply = &.{};

    // a hub's ports: said in the record only when something changes
    if ((typ == 0xA3 or typ == 0x23) and d.ports.len != 0) {
        if (index == 0 or index >= d.ports.len)
            return "bad hub port number";
        const p = &d.ports[index];
        if (typ == 0xA3 and req == 0) { // get status
            polled = true;
            if (d.id == 1 and index == 1) {
                // a round starts
                const evs = events.toOwnedSlice(a) catch oom();
                defer a.free(evs);
                for (evs) |ev|
                    portevent(ev);
            }
            if (m.badport != 0 and index == m.badport)
                return Estall;
            if (p.sts != p.told) {
                record("ep%d.0 port %d status %#ux\n", .{ d.id, index, p.sts });
                p.told = p.sts;
            }
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, p.sts, .little);
            setreply(d, &b, len);
            return null;
        }
        record("ep%d.0 port %d %s feature %d\n", .{ d.id, index, if (req == 3) "set" else "clear", value });
        if (req == 3) switch (value) { // set feature
            4 => { // reset
                if (p.model) |pm| {
                    if (!pm.dead) {
                        p.sts |= PSenable;
                        if (std.mem.eql(u8, pm.speed, "low")) p.sts |= PSslow;
                        if (std.mem.eql(u8, pm.speed, "high")) p.sts |= PShigh;
                    }
                }
            },
            8 => p.sts |= PSpower,
            else => {},
        } else switch (value) { // clear feature
            1 => p.sts &= ~@as(u32, PSenable),
            2 => p.sts &= ~@as(u32, PSsuspend),
            8 => p.sts &= ~@as(u32, PSpower),
            else => {},
        }
        // what a feature does to the status is said by this line: the
        // status is not said again when it is next asked for, which
        // is whenever the one who asks comes round
        p.told = p.sts;
        return null;
    }

    if (msg.len > 8)
        record("ep%d.0 req %.2x %.2x %.4x %.4x %d: %H\n", .{ d.id, typ, req, value, index, len, hex(msg[8..]) })
    else
        record("ep%d.0 req %.2x %.2x %.4x %.4x %d\n", .{ d.id, typ, req, value, index, len });

    if (m.kind == .roothub)
        return "root hub is a toy hub";

    switch (@as(u32, typ) << 8 | req) {
        0x8006 => { // get descriptor
            switch (value >> 8) {
                1 => setreply(d, m.ddesc, len),
                2 => {
                    const n = value & 0xFF;
                    if (n >= m.confs.len)
                        return Estall;
                    setreply(d, m.confs[n], len);
                },
                3 => {
                    var b: [256]u8 = undefined;
                    const n = value & 0xFF;
                    if (n == 0) {
                        if (m.nolangid)
                            return Estall;
                        setreply(d, &.{ 4, 3, 0x09, 0x04 }, len);
                        return null;
                    }
                    if (n >= m.strs.len)
                        return Estall;
                    const s = m.strs[n] orelse return Estall;
                    // DIFF from a device: each byte of the model's
                    // text is a character, but ~XXXX which is that
                    // one (hexadecimal)
                    var o: usize = 2;
                    var i: usize = 0;
                    while (i < s.len and o + 2 <= 254) {
                        var c: u16 = s[i];
                        i += 1;
                        if (c == '~' and i + 4 <= s.len) {
                            c = @truncate(libc.strtoul(s[i..][0..4], 16).v);
                            i += 4;
                        }
                        b[o] = @truncate(c);
                        b[o + 1] = @truncate(c >> 8);
                        o += 2;
                    }
                    b[0] = @truncate(o);
                    b[1] = 3;
                    setreply(d, b[0..o], len);
                },
                else => return Estall,
            }
        },
        0x0005 => { // set address
            if (m.badaddress)
                return Estall;
            d.addr = value;
        },
        0x0009 => { // set configuration
            if (m.badconf)
                return Estall;
        },
        0x010B => {}, // set interface
        0x0201 => {}, // clear feature (an endpoint's halt)
        0x0003 => {}, // set feature
        0xA006 => { // hub descriptor
            if (m.hubdesc.len == 0)
                return Estall;
            setreply(d, m.hubdesc, len);
        },
        0x200C => {}, // set hub depth
        0x210A => {}, // hid: set idle
        0x210B => { // hid: set protocol
            if (m.kind != .hid)
                return Estall;
        },
        0x8106 => { // hid: get report descriptor
            if (value >> 8 != 0x22 or index >= m.repdescs.len or m.repdescs[index].len == 0)
                return Estall;
            setreply(d, m.repdescs[index], len);
        },
        0x2109 => {}, // hid: set report
        0x21FF => { // storage: reset
            if (m.kind != .disk)
                return Estall;
        },
        0xA1FE => { // storage: get max lun
            if (m.kind != .disk or m.nomaxlun)
                return Estall;
            setreply(d, &.{@as(u8, @intCast(m.luns.len - 1))}, len);
        },
        else => return Estall,
    }
    return null;
}

// A disk: the bulk-only transport, and the SCSI commands a disk gets.

fn be32(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

fn sense(l: *Lun, key: u8, asc: u8, ascq: u8) void {
    l.key = key;
    l.asc = asc;
    l.ascq = ascq;
}

fn pushchunk(d: *Dev, data: []const u8, hold: bool, stall: bool) void {
    d.chunks.append(a, .{ .data = a.dupe(u8, data) catch oom(), .hold = hold, .stall = stall }) catch oom();
}

fn pushcsw(d: *Dev, cbw: *const [31]u8, residue: u32, status: u8, hold: bool) void {
    var csw: [13]u8 = undefined;
    @memcpy(csw[0..4], "USBS");
    @memcpy(csw[4..8], cbw[4..8]);
    std.mem.writeInt(u32, csw[8..12], residue, .little);
    csw[12] = status;
    if (d.model.badtag and !d.badtagdone) {
        // one status for another command first
        d.badtagdone = true;
        var other = csw;
        other[4] ^= 0xFF;
        pushchunk(d, &other, false, false);
    }
    pushchunk(d, &csw, hold, false);
}

/// The command in cbw, with the data that came for it (a write's).
fn scsicmd(d: *Dev, cbw: *const [31]u8, out: []const u8) void {
    const datalen = std.mem.readInt(u32, cbw[8..12], .little);
    const lunno = cbw[13];
    const cmd = cbw[15..31];
    var buf: [64]u8 = @splat(0);

    if (lunno >= d.luns.len) {
        pushcsw(d, cbw, datalen, 1, false);
        return;
    }
    const l = &d.luns[lunno];
    const lm = l.m;
    var resp: []const u8 = &.{};
    var status: u8 = 0;
    var hold = false;
    var stall = false;
    var big: []u8 = &.{};
    defer a.free(big);

    switch (cmd[0]) {
        0x00 => { // test unit ready
            if (l.notready > 0) {
                l.notready -= 1;
                sense(l, 2, lm.notreadyasc, lm.notreadyascq);
                status = 1;
            }
        },
        0x03 => { // request sense
            buf[0] = 0x70;
            buf[2] = l.key;
            buf[7] = 10;
            buf[12] = l.asc;
            buf[13] = l.ascq;
            resp = buf[0..18];
            sense(l, 0, 0, 0);
        },
        0x12 => { // inquiry
            if (lm.noinquiry) {
                sense(l, 5, 0x20, 0);
                status = 1;
            } else {
                buf[0] = lm.type;
                buf[1] = 0x80;
                buf[2] = 4;
                buf[4] = 31;
                @memcpy(buf[8..36], lm.inquiry);
                resp = buf[0..36];
            }
        },
        0x1B => {}, // start
        0x25 => { // read capacity
            if (lm.blocks == 0) {
                sense(l, 2, 0x3A, 0);
                status = 1;
            } else {
                std.mem.writeInt(u32, buf[0..4], if (lm.cap16) 0xFFFFFFFF else @intCast(lm.blocks - 1), .big);
                std.mem.writeInt(u32, buf[4..8], @intCast(lm.bs), .big);
                resp = buf[0..8];
            }
        },
        0x9E => { // read capacity (16)
            std.mem.writeInt(u64, buf[0..8], lm.blocks - 1, .big);
            std.mem.writeInt(u32, buf[8..12], @intCast(lm.bs), .big);
            resp = buf[0..32];
        },
        0x28, 0x2A => { // read, write
            const lba: usize = be32(cmd[2..6]);
            const nb: usize = @as(usize, cmd[7]) << 8 | cmd[8];
            if (lba + nb > lm.blocks) {
                sense(l, 5, 0x21, 0);
                status = 1;
            } else if (lm.badlba != 0 and lba <= lm.badlba and lm.badlba < lba + nb) {
                // the data stage fails, then the status says why
                sense(l, 3, 0x11, 0);
                status = 1;
                stall = cmd[0] == 0x28;
            } else if (cmd[0] == 0x28) {
                big = a.dupe(u8, l.data[lba * lm.bs ..][0 .. nb * lm.bs]) catch oom();
                resp = big;
                hold = lm.holdlba != 0 and lba == lm.holdlba;
            } else if (lm.readonly) {
                sense(l, 7, 0x27, 0);
                status = 1;
            } else {
                const n = @min(out.len, nb * lm.bs);
                @memcpy(l.data[lba * lm.bs ..][0..n], out[0..n]);
            }
        },
        else => {
            sense(l, 5, 0x20, 0);
            status = 1;
        },
    }
    if (cbw[12] & 0x80 != 0 and datalen != 0) {
        // data to the host: as much as was asked for, at most
        const n = @min(resp.len, datalen);
        if (stall)
            pushchunk(d, &.{}, false, true)
        else if (n != 0 or status == 0)
            pushchunk(d, resp[0..n], false, false);
        if (status != 0 and !stall and n == 0)
            pushchunk(d, &.{}, false, true);
        pushcsw(d, cbw, @intCast(datalen - n), status, hold);
    } else {
        const got: u32 = @intCast(@min(out.len, datalen));
        pushcsw(d, cbw, if (status == 0) datalen - got else datalen, status, hold);
    }
}

fn sum(b: []const u8) u32 {
    var s: u32 = 0;
    for (b) |c|
        s = s *% 31 +% c;
    return s;
}

fn diskwrite(d: *Dev, msg: []const u8) ?[]const u8 {
    if (d.cbw) |cbw| {
        // the data of a write
        d.cbw = null;
        record("ep%d data out %d sum %ud\n", .{ d.id, msg.len, sum(msg) });
        scsicmd(d, &cbw, msg);
        return null;
    }
    if (msg.len != 31 or !std.mem.eql(u8, msg[0..4], "USBC"))
        return "not a command block wrapper";
    const datalen = std.mem.readInt(u32, msg[8..12], .little);
    record("ep%d cbw lun %d cmd %H len %d %s\n", .{ d.id, msg[13], hex(msg[15..][0..@min(msg[14], 16)]), datalen, if (msg[12] & 0x80 != 0) "in" else "out" });
    if (msg[12] & 0x80 == 0 and datalen != 0) {
        d.cbw = msg[0..31].*;
        return null;
    }
    scsicmd(d, msg[0..31], &.{});
    return null;
}

fn diskread(r: *Req, d: *Dev, pass: bool) void {
    if (d.chunks.items.len == 0) {
        // nothing to say: a stall
        respond(r, Estall);
        return;
    }
    if (d.chunks.items[0].hold) {
        var passed = pass;
        if (!gopast(&passed)) {
            holdread(r, d, 1);
            return;
        }
    }
    d.eps[1].saidheld = false;
    const ch = d.chunks.orderedRemove(0);
    if (ch.stall)
        respond(r, Estall)
    else
        answer(r, ch.data);
    a.free(ch.data);
}

fn fswrite(r: *Req) void {
    const path = r.fid.?.qid.path;
    var err: ?[]const u8 = null;

    if (path == 0) {
        respond(r, "is a directory");
        return;
    }
    if (path == 1) {
        rootctl(r);
        return;
    } else {
        const w = where(path);
        const msg = r.ifcall.data[0..r.ifcall.count];
        switch (w.k) {
            Kctl => err = ctlwrite(r, w.d, w.e),
            Kdata => {
                if (std.mem.eql(u8, w.d.eps[w.e].mode, "r") or !w.d.eps[w.e].inuse)
                    err = Ebadusefd
                else if (w.d.detached)
                    err = Edetach
                else if (w.e == 0)
                    err = control(w.d, msg)
                else if (w.d.luns.len != 0)
                    err = diskwrite(w.d, msg)
                else {
                    record("ep%d.%d out %H\n", .{ w.d.id, w.e, hex(msg) });
                }
            },
            else => err = "is a directory",
        }
    }
    if (err == null)
        r.ofcall.count = r.ifcall.count;
    respond(r, err);
}

var fs: p9.Srv = .{
    .attach = fsattach,
    .walk1 = fswalk1,
    .open = fsopen,
    .read = fsread,
    .write = fswrite,
    .stat = fsstat,
    .flush = fsflush,
    .destroyfid = fsdestroyfid,
};

fn usage() noreturn {
    libc.fprint(2, "usage: usbfake [-m mtpt] hub|hid|disk|desc\n", .{});
    libc.exits("usage");
}

/// A device as usbd leaves one: with an address, and the endpoints of
/// its first configuration not yet made.
fn present(first: u32, names: []const []const u8) void {
    var id = first;
    for (names) |n| {
        const m = models.find(n) orelse libc.sysfatal("no model %s", .{n});
        const d = newdev(m, id, null, 0);
        d.state = .enabled;
        d.addr = id & 0x7f;
        id += 1;
    }
}

pub fn main(argv: []const []const u8) void {
    var mtpt: []const u8 = "/n/usbfake";

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'm' => mtpt = args.value() orelse usage(),
        'D' => p9.chatty9p += 1,
        else => usage(),
    };
    const rest = args.rest();
    if (rest.len != 1)
        usage();
    const scene = rest[0];
    if (std.mem.eql(u8, scene, "hub")) {
        present(1, &.{ "root2", "root3" });
        nextid = 3;
    } else if (std.mem.eql(u8, scene, "hid")) {
        present(211, models.hidscene);
    } else if (std.mem.eql(u8, scene, "disk")) {
        present(221, models.diskscene);
    } else if (std.mem.eql(u8, scene, "desc")) {
        present(231, models.descscene);
    } else usage();
    p9.postmountsrv(&fs, null, mtpt, sys.MREPL);
    libc.exits(null);
}
