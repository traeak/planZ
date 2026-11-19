//! usbd - enumerate the USB: watch the ports of the hubs, give each
//! device that appears an address and a configuration, and tell the
//! readers of usbevent, which start the drivers
//! from /sys/src/cmd/nusb/usbd/usbd.c (hub.c, hname.c and dat.h are in
//! usbd/)
//!
//! usage: usbd [ -dD ] [ -m share ] [ hub... ]
//!
//! DIFF:
//!   - -m share posts the service in that share instead of usb.  The
//!     C has no such flag; it is for the test that runs this beside
//!     the system's usbd, which has the name usbd in usb.
//!   - The requests that wait are linked through Req.aux, as in C;
//!     the list's head is a ?*anyopaque for that.
//!   - -D is taken and prints nothing (lib9p's chatty9p).

const std = @import("std");
const libc = @import("libc");
const p9 = @import("9p");
const usb = @import("usb");
const dat = @import("usbd/dat.zig");
const hub = @import("usbd/hub.zig");
const hname = @import("usbd/hname.zig").hname;
const sys = libc.sys;
const fcall = libc.fcall;

const Dev = usb.Dev;
const Hub = dat.Hub;
const Req = p9.Req;
const Fid = p9.Fid;
const Dir = p9.Dir;
const Qid = p9.Qid;
const respond = p9.respond;

const Qroot = 0;
const Qusbevent = 1;
const Qusbhubctl = 2;
const Qmax = 3;

const names = [_][]const u8{
    "",
    "usbevent",
    "usbhubctl",
};

const Enonexist = "file does not exist";
const Eperm = "permission denied";

const Event = struct {
    /// the device producing the event,
    /// dev->aux points to Reader processing the event
    dev: ?*Dev = null,
    data: []u8 = &.{},
    link: ?*Event = null,
    /// number of readers which will read this one
    /// the next time they'll read
    ref: i32 = 0,
    /// number of events pointing to this one with
    /// their link pointers
    prev: i32 = 0,
};

const Reader = struct {
    event: ?*Event = null, // next event this reader can read
    order: u32 = 0, // open order
};

var evlast: ?*Event = null;
var reqlist: ?*anyopaque = null; // sorted by open order
var evlock: libc.QLock = .{};

fn asreq(p: ?*anyopaque) ?*Req {
    return @ptrCast(@alignCast(p));
}

fn reader(r: *Req) *Reader {
    return @ptrCast(@alignCast(r.fid.?.aux.?));
}

fn addreader(req: *Req) void {
    const order = reader(req).order;

    var l = &reqlist;
    var r = asreq(l.*);
    while (r) |p| : (r = asreq(l.*)) {
        if (order > reader(p).order)
            break;
        l = &p.aux;
    }

    req.aux = r;
    l.* = req;
}

fn fulfill(req: *Req, e: *Event) void {
    var n = e.data.len;
    if (n > req.ifcall.count)
        n = req.ifcall.count;
    @memcpy(req.rbuf[0..n], e.data[0..n]);
    req.ofcall.count = @intCast(n);
}

fn initevent() void {
    evlast = usb.create(Event);
}

fn putevent(e: *Event) *Event {
    const ee = e.link.?;
    if (e.ref != 0 or e.prev != 0)
        return ee;
    ee.prev -= 1;
    usb.closedev(e.dev);
    libc.allocator.free(e.data);
    libc.allocator.destroy(e);
    return ee;
}

fn procreqs() void {
    var rp = asreq(reqlist);
    while (rp) |r| : (rp = asreq(r.aux)) {
        const rr = reader(r);
        var e = rr.event.?;
        if (e != evlast and e.dev.?.aux == @as(?*anyopaque, rr)) {
            e.dev.?.aux = null; // release device
            e.ref -= 1;
            e = putevent(e);
            e.ref += 1;
            rr.event = e;
        }
    }

    var l = &reqlist;
    while (asreq(l.*)) |r| {
        const rr = reader(r);
        const e = rr.event.?;
        if (e != evlast and e.dev.?.aux == null) {
            e.dev.?.aux = rr; // claim device
            l.* = r.aux;
            r.aux = null;
            fulfill(r, e);
            respond(r, null);
            continue;
        }
        l = &r.aux;
    }
}

fn pushevent(d: *Dev, data: []u8) void {
    libc.qlock(&evlock);
    const e = evlast.?;
    evlast = usb.create(Event);
    usb.incref(&d.ref);
    e.dev = d;
    e.data = data;
    e.link = evlast;
    evlast.?.prev += 1;
    procreqs();
    _ = putevent(e);
    libc.qunlock(&evlock);
}

fn dirgen(n: i32, d: *Dir, _: ?*anyopaque) bool {
    if (n >= Qmax - 1)
        return false;
    d.* = .{};
    d.qid.path = @intCast(n + 1);
    d.qid.vers = 0;
    switch (d.qid.path) {
        Qroot => {
            d.qid.type = fcall.QTDIR;
            d.mode = 0o555 | fcall.DMDIR;
        },
        Qusbevent => {
            d.qid.type = 0;
            d.mode = 0o444;
        },
        Qusbhubctl => {
            d.qid.type = 0;
            d.mode = 0o222;
        },
        else => {},
    }
    d.uid = p9.estrdup9p(libc.getuser());
    d.gid = p9.estrdup9p(d.uid);
    d.muid = p9.estrdup9p(d.uid);
    d.name = p9.estrdup9p(names[@intCast(n + 1)]);
    d.atime = @truncate(@as(u64, @bitCast(libc.time())));
    d.mtime = d.atime;
    d.length = 0;
    return true;
}

fn usbdattach(req: *Req) void {
    req.fid.?.qid = .{ .path = Qroot, .vers = 0, .type = fcall.QTDIR };
    req.ofcall.qid = req.fid.?.qid;
    respond(req, null);
}

fn usbdwalk(fid: *Fid, name: []const u8, qid: *Qid) ?[]const u8 {
    if (fid.qid.path != Qroot)
        return "not a directory";
    if (std.mem.eql(u8, name, "..")) {
        qid.* = fid.qid;
        return null;
    }
    var i: usize = Qroot + 1;
    while (i < Qmax) : (i += 1) {
        if (std.mem.eql(u8, name, names[i])) {
            fid.qid = .{ .path = i, .vers = 0, .type = 0 };
            qid.* = fid.qid;
            return null;
        }
    }
    return Enonexist;
}

fn usbdread(req: *Req) void {
    switch (req.fid.?.qid.path) {
        Qroot => {
            p9.dirread9p(req, dirgen, null);
            respond(req, null);
        },
        Qusbevent => {
            libc.qlock(&evlock);
            addreader(req);
            procreqs();
            libc.qunlock(&evlock);
        },
        else => respond(req, Enonexist),
    }
}

fn usbdwrite(req: *Req) void {
    var hubid: [16]u8 = undefined;

    if (req.fid.?.qid.path != Qusbhubctl) {
        respond(req, Enonexist);
        return;
    }
    const cb = p9.parsecmd(req.ifcall.data[0..req.ifcall.count]);
    defer p9.freecmd(cb);
    if (cb.f.len < 4) {
        respond(req, "not enough arguments");
        return;
    }
    var feature: u32 = undefined;
    if (std.mem.eql(u8, cb.f[0], "portpower"))
        feature = dat.Fportpower
    else if (std.mem.eql(u8, cb.f[0], "portindicator"))
        feature = dat.Fportindicator
    else {
        respond(req, "unknown feature");
        return;
    }
    const port = libc.atoi(cb.f[2]);
    var on: bool = undefined;
    if (std.mem.eql(u8, cb.f[3], "on"))
        on = true
    else if (std.mem.eql(u8, cb.f[3], "off"))
        on = false
    else
        on = libc.atoi(cb.f[3]) != 0;

    libc.qlock(&hub.hublock);
    var hp = hub.hubs;
    while (hp) |h| : (hp = h.next) {
        const d = h.dev.?;
        if (d.hname != null and std.mem.eql(u8, d.hname.?, cb.f[1]))
            break;
        if (std.mem.eql(u8, libc.sprint(hubid[0 .. hubid.len - 1], "%d", .{d.id}), cb.f[1]))
            break;
    }
    const h = hp orelse {
        libc.qunlock(&hub.hublock);
        respond(req, "unknown hub");
        return;
    };
    if (port < 1 or port > h.nport) {
        libc.qunlock(&hub.hublock);
        respond(req, "unknown port");
        return;
    }
    if (feature == dat.Fportpower and h.pwrmode != 1 or
        feature == dat.Fportindicator and !h.leds)
    {
        libc.qunlock(&hub.hublock);
        respond(req, "not supported");
        return;
    }
    _ = hub.portfeature(h, @intCast(port), feature, on) catch {};
    libc.qunlock(&hub.hublock);
    req.ofcall.count = req.ifcall.count;
    respond(req, null);
}

fn usbdstat(req: *Req) void {
    if (!dirgen(@as(i32, @intCast(req.fid.?.qid.path)) - 1, &req.d, null))
        respond(req, Enonexist)
    else
        respond(req, null);
}

fn formatdev(d: *Dev, detach: bool) []u8 {
    var buf: [128]u8 = undefined;
    const u = d.usb.?;
    return usb.estrdup(libc.sprint(&buf, "%s %d %.4x %.4x %.6ux %s\n", .{
        if (detach) "detach" else "attach",
        d.id,
        u.vid,
        u.did,
        u.csp,
        if (d.hname) |s| s else "",
    }));
}

/// The devices there are, as a list of events that ends in evlast.
fn enumerate() *Event {
    var head: ?*Event = null;
    var l = &head;

    var hp = hub.hubs;
    while (hp) |h| : (hp = h.next) {
        var i: usize = 1;
        while (i <= h.nport) : (i += 1) {
            const p = &h.port[i];
            const d = p.dev orelse continue;
            if (d.usb == null or p.hub != null)
                continue;
            const e = usb.create(Event);
            usb.incref(&d.ref);
            e.dev = d;
            e.data = formatdev(d, false);
            e.prev = 1;
            l.* = e;
            l = &e.link;
        }
    }
    l.* = evlast;
    evlast.?.prev += 1;
    return head.?;
}

var openorder: u32 = 0;

fn usbdopen(req: *Req) void {
    switch (req.fid.?.qid.path) {
        Qusbevent => {
            if (req.ifcall.mode != sys.OREAD) {
                respond(req, Eperm);
                return;
            }
            libc.qlock(&hub.hublock);
            libc.qlock(&evlock);

            const e = enumerate();
            e.prev -= 1;
            e.ref += 1;

            const rr = usb.create(Reader);
            rr.event = e;
            openorder += 1;
            rr.order = openorder;
            req.fid.?.aux = rr;

            libc.qunlock(&evlock);
            libc.qunlock(&hub.hublock);
        },
        Qusbhubctl => {
            if ((req.ifcall.mode & ~@as(u8, sys.OTRUNC)) != sys.OWRITE) {
                respond(req, Eperm);
                return;
            }
        },
        else => {},
    }
    respond(req, null);
}

fn usbddestroyfid(fid: *Fid) void {
    if (fid.qid.path == Qusbevent) {
        libc.qlock(&evlock);
        if (fid.aux) |aux| {
            const rr: *Reader = @ptrCast(@alignCast(aux));
            fid.aux = null;
            if (rr.event) |first| {
                var e = first;
                if (e.dev != null and e.dev.?.aux == @as(?*anyopaque, rr)) {
                    e.dev.?.aux = null; // release device
                    procreqs();
                }
                e.ref -= 1;
                while (e.ref == 0 and e.prev == 0 and e != evlast)
                    e = putevent(e);
            }
            libc.allocator.destroy(rr);
        }
        libc.qunlock(&evlock);
    }
}

fn usbdflush(req: *Req) void {
    libc.qlock(&evlock);
    var l = &reqlist;
    while (asreq(l.*)) |r| {
        if (r == req.oldreq) {
            l.* = r.aux;
            r.aux = null;
            respond(r, "interrupted");
            break;
        }
        l = &r.aux;
    }
    libc.qunlock(&evlock);
    respond(req, null);
}

fn usbdstart(_: *p9.Srv) void {
    _ = libc.spawn(sys.RFNOWAIT, hub.work, {}) catch libc.sysfatal("rfork: %r", .{});
}

fn usbdend(_: *p9.Srv) void {
    libc.postnote(libc.PNGROUP, libc.getpid(), "shutdown") catch {};
}

var usbdsrv: p9.Srv = .{
    .start = usbdstart,
    .end = usbdend,
    .attach = usbdattach,
    .walk1 = usbdwalk,
    .read = usbdread,
    .write = usbdwrite,
    .stat = usbdstat,
    .open = usbdopen,
    .flush = usbdflush,
    .destroyfid = usbddestroyfid,
};

pub fn assignhname(dev: *Dev) void {
    var buf: [64]u8 = undefined;

    const ud = dev.usb.?;

    // build string of device unique stuff
    const s = libc.sprint(buf[0 .. buf.len - 1], "%.4x%.4x%.4x%.6ux%s", .{ ud.vid, ud.did, ud.dno, ud.csp, ud.serial });

    const name = hname(&buf, s.len);
    const n = name.len;

    // check for collisions
    var col: i64 = 0;
    var hp = hub.hubs;
    while (hp) |h| : (hp = h.next) {
        if (ud.class == usb.Clhub) {
            const hn = h.dev.?.hname orelse continue;
            if (std.mem.startsWith(u8, hn, name)) {
                const nr = libc.atoi(hn[n..]) + 1;
                if (nr > col)
                    col = nr;
            }
            continue;
        }
        var i: usize = 1;
        while (i <= h.nport) : (i += 1) {
            const pd = h.port[i].dev orelse continue;
            const hn = pd.hname orelse continue;
            if (pd == dev)
                continue;
            if (std.mem.startsWith(u8, hn, name)) {
                const nr = libc.atoi(hn[n..]) + 1;
                if (nr > col)
                    col = nr;
            }
        }
    }

    if (col == 0)
        dev.hname = usb.estrdup(name)
    else {
        var nb: [96]u8 = undefined;
        dev.hname = usb.estrdup(libc.sprint(&nb, "%s%d", .{ name, col }));
    }
}

pub fn attachdev(d: *Dev) void {
    // create all endpoint files for default conf #1
    // but do not create endpoints that have an altsetting.
    const ud = d.usb.?;
    var id: usize = 1;
    while (id < ud.ep.len) : (id += 1) {
        const ep = ud.ep[id] orelse continue;
        if (ep.next == null and
            ep.conf != null and
            ep.conf.?.cval == 1 and
            ep.iface.?.alt == 0)
        {
            if (usb.openep(d, ep)) |epd|
                usb.closedev(epd);
        }
    }
    pushevent(d, formatdev(d, false));
}

pub fn detachdev(d: *Dev) void {
    pushevent(d, formatdev(d, true));
}

/// we create /env/usbbusy on startup and once all devices have been
/// enumerated and readers have consumed all the events, we remove the
/// file so nusbrc can continue.
var busyfd: i32 = -1;

pub fn checkidle() void {
    if (busyfd < 0 or reqlist == null or evlast == null or evlast.?.prev > 0)
        return;

    _ = sys.close(busyfd);
    busyfd = -1;
}

pub fn main(argv: []const []const u8) void {
    var share: []const u8 = "usb";

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'D' => p9.chatty9p += 1,
        'd' => usb.usbdebug += 1,
        'm' => share = args.value() orelse break,
        else => {},
    };
    const rest = args.rest();

    initevent();

    hub.hubs = null;
    if (rest.len == 0) {
        const fd = libc.open("/dev/usb", sys.OREAD) catch libc.sysfatal("/dev/usb: %r", .{});
        var dirs: ?libc.Dirs = libc.dirreadall(libc.allocator, fd) catch null;
        _ = sys.close(fd);
        if (dirs) |*ds| {
            for (ds.dirs) |*d| {
                if (std.mem.eql(u8, d.name, "ctl"))
                    continue;
                const name = std.mem.concat(libc.allocator, u8, &.{ "/dev/usb/", d.name }) catch libc.sysfatal("malloc: %r", .{});
                _ = hub.newhub(name, null);
                libc.allocator.free(name);
            }
            ds.deinit(libc.allocator);
        }
    } else {
        for (rest) |a|
            _ = hub.newhub(a, null);
    }

    if (hub.hubs == null)
        libc.sysfatal("no hubs", .{});

    busyfd = libc.create("/env/usbbusy", sys.ORCLOSE, 0o600) catch -1;
    p9.postsharesrv(&usbdsrv, null, share, "usbd");
    libc.exits(null);
}
