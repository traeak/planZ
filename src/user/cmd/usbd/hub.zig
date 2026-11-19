//! from nusb/usbd/hub.c
//!
//! Kept from C: enumhub, after it clears a port's suspend, returns -1
//! when the port's status can then be read (the test is != -1 where
//! == -1 is meant).  work takes that as a change in the list of hubs
//! and starts its round again, where the port is no longer suspended;
//! when the status cannot be read the function goes on with a status
//! of all ones, on a hub that portstatus has by then marked failed.

const std = @import("std");
const libc = @import("libc");
const usb = @import("usb");
const dat = @import("dat.zig");
const usbd = @import("../usbd.zig");
const sys = libc.sys;

const Dev = usb.Dev;
const Usbdev = usb.Usbdev;
const Hub = dat.Hub;
const Port = dat.Port;
const dprint = usb.dprint;
const devctl = usb.devctl;
const usbcmd = usb.usbcmd;
const argv0 = &libc.argv0;

pub var hubs: ?*Hub = null;
pub var hublock: libc.QLock = .{};
var nhubs: i32 = 0;
var mustdump: bool = false;
var pollms: u32 = dat.Pollms;
var nowms: u32 = 0;

/// What portstatus returns when the status could not be read.
const Nostatus: u32 = 0xFFFFFFFF;

pub fn portfeature(h: *Hub, port: u32, f: u32, on: bool) libc.Error!usize {
    const cmd: u32 = if (on) usb.Rsetfeature else usb.Rclearfeature;
    return usbcmd(h.dev.?, usb.Rh2d | usb.Rclass | usb.Rother, cmd, f, port, null);
}

fn getdesc(d: *Usbdev, typ: u8) ?[]u8 {
    for (d.ddesc) |slot| {
        const dd = slot orelse break;
        // a descriptor of one byte has no type (the C reads the byte
        // after it)
        if (dd.data.len > 1 and dd.data[1] == typ)
            return dd.data;
    }
    return null;
}

fn configusb2hub(h: *Hub, dd: []const u8) bool {
    const nr = dd.len;
    const d = h.dev.?;

    h.nport = dd[2];
    if (h.nport < 1 or h.nport > 127) {
        libc.fprint(2, "%s: %s: bad port count %d for a hub\n", .{ argv0.*, d.dir, h.nport });
        return false;
    }
    const nmap: usize = 1 + @as(usize, h.nport) / 8;
    if (nr < 7 + 2 * nmap) {
        libc.fprint(2, "%s: %s: descr. too small\n", .{ argv0.*, d.dir });
        return false;
    }
    h.port = newports(h.nport);
    h.pwrms = @as(i32, dd[5]) * 2;
    h.maxcurrent = dd[6];
    h.pwrmode = dd[3] & 3;
    h.compound = (dd[3] & (1 << 2)) != 0;
    h.ttt = (dd[3] >> 5) & 3;
    h.leds = (dd[3] & (1 << 7)) != 0;
    // DeviceRemovable is at 7 and PortPwrCtrlMask nmap after it
    var i: usize = 1;
    while (i <= h.nport) : (i += 1) {
        const pp = &h.port[i];
        const offset = i / 8;
        const mask = @as(u8, 1) << @intCast(i % 8);
        pp.removable = (dd[7 + offset] & mask) != 0;
        pp.pwrctl = (dd[7 + nmap + offset] & mask) != 0;
    }
    h.mtt = d.usb.?.ver == 0x0200 and usb.Proto(d.usb.?.csp) == 2;

    if (h.mtt) { // try enable multi TT
        _ = usbcmd(d, usb.Rh2d | usb.Rstd | usb.Riface, usb.Rsetiface, 1, 0, null) catch {
            libc.fprint(2, "%s: %s: setifcace (mtt): %r\n", .{ argv0.*, d.dir });
            h.mtt = false;
        };
    }
    return true;
}

fn configusb3hub(h: *Hub, dd: []const u8) bool {
    const d = h.dev.?;

    h.nport = dd[2];
    if (h.nport < 1 or h.nport > 15) {
        libc.fprint(2, "%s: %s: bad port count %d for a usb3 hub\n", .{ argv0.*, d.dir, h.nport });
        return false;
    }
    h.port = newports(h.nport);
    h.pwrms = @as(i32, dd[5]) * 2;
    h.maxcurrent = dd[6];
    h.pwrmode = dd[3] & 3;
    h.compound = (dd[3] & (1 << 2)) != 0;
    h.ttt = 0;
    h.leds = false;
    var i: usize = 1;
    while (i <= h.nport) : (i += 1) {
        const pp = &h.port[i];
        const offset = i / 8;
        const mask = @as(u8, 1) << @intCast(i % 8);
        // DeviceRemovable is at 10
        pp.removable = (dd[10 + offset] & mask) != 0;
    }
    h.mtt = false;

    _ = usbcmd(d, usb.Rh2d | usb.Rclass | usb.Rdev, usb.Rsethubdepth, @bitCast(d.depth), 0, null) catch {
        libc.fprint(2, "%s: %s: sethubdepth: %r\n", .{ argv0.*, d.dir });
        return false;
    };
    return true;
}

fn confighub(h: *Hub) bool {
    var buf: [128]u8 = undefined;
    const d = h.dev.?;
    var dt: u8 = undefined;
    var dl: usize = undefined;

    if (d.isusb3) {
        dt = dat.Dsshub;
        dl = dat.Dsshublen;
    } else {
        dt = dat.Dhub;
        dl = dat.Dhublen;
    }
    var dd: []const u8 = undefined;
    var nr: usize = undefined;
    if (getdesc(d.usb.?, dt)) |p| {
        dd = p;
        nr = p[0];
    } else {
        nr = usbcmd(d, usb.Rd2h | usb.Rclass | usb.Rdev, usb.Rgetdesc, @as(u32, dt) << 8 | 0, 0, &buf) catch {
            libc.fprint(2, "%s: %s: getdesc hub: %r\n", .{ argv0.*, d.dir });
            return false;
        };
        dd = &buf;
    }
    if (nr < dl) {
        libc.fprint(2, "%s: %s: hub descriptor too small (%d < %d)\n", .{ argv0.*, d.dir, nr, dl });
        return false;
    }
    // what was read, or the descriptor as the configuration had it
    // (which is bLength bytes: parsedesc)
    dd = dd[0..nr];
    if (d.isusb3)
        return configusb3hub(h, dd)
    else
        return configusb2hub(h, dd);
}

fn newports(nport: u8) []Port {
    const p = libc.allocator.alloc(Port, @as(usize, nport) + 1) catch libc.sysfatal("malloc: %r", .{});
    @memset(p, .{});
    return p;
}

fn configroothub(h: *Hub) void {
    var buf: [1024]u8 = undefined;
    const d = h.dev.?;

    h.nport = 2;
    h.maxpkt = 8;
    h.pwrmode = 1; // fake
    done: {
        _ = sys.seek(d.cfd, 0, 0);
        const nr = libc.read(d.cfd, buf[0 .. buf.len - 1]) catch break :done;
        const s = buf[0..nr];
        d.isusb3 = std.mem.indexOf(u8, s, "speed super") != null;
        if (std.mem.indexOf(u8, s, "ports ")) |p|
            h.nport = @truncate(@as(u64, @bitCast(libc.atoi(s[p + 6 ..]))))
        else
            libc.fprint(2, "%s: %s: no port information\n", .{ argv0.*, d.dir });
        if (std.mem.indexOf(u8, s, "maxpkt ")) |p|
            h.maxpkt = @truncate(libc.atoi(s[p + 7 ..]))
        else
            libc.fprint(2, "%s: %s: no maxpkt information\n", .{ argv0.*, d.dir });
    }
    h.port = newports(h.nport);
    dprint("%s: %s: ports %d maxpkt %d\n", .{ argv0.*, d.dir, h.nport, h.maxpkt });
}

pub fn newhub(name: []const u8, dev: ?*Dev) ?*Hub {
    const h = usb.create(Hub);
    fail: {
        if (dev) |d| {
            usb.incref(&d.ref);
            h.dev = d;
            if (!confighub(h))
                break :fail;

            // close control endpoint so we can re-configure as a hub
            _ = sys.close(d.dfd);
            d.dfd = -1;

            _ = devctl(d, "hub %d %d %d", .{ h.nport, h.ttt, @intFromBool(h.mtt) }) catch {
                libc.fprint(2, "%s: %s: devctl hub: %r\n", .{ argv0.*, name });
                _ = devctl(d, "hub", .{}) catch // try old kernel
                    break :fail;
            };

            const ud = d.usb.?;
            _ = devctl(d, "info hub csp %#08ux ports %d vid %#.4ux did %#.4ux %q %q %s", .{
                ud.csp, h.nport, ud.vid, ud.did, ud.vendor, ud.product, d.hname,
            }) catch {};
        } else {
            h.dev = usb.opendev(name) orelse {
                libc.fprint(2, "%s: %s: opendev: %r\n", .{ argv0.*, name });
                break :fail;
            };
            h.dev.?.depth = -1;
            configroothub(h); // never fails
            _ = devctl(h.dev.?, "info roothub csp %#08ux ports %d", .{ @as(u32, 0x000009), h.nport }) catch {};
        }
        _ = usb.opendevdata(h.dev.?, sys.ORDWR) catch {
            dprint("%s: %s: opendevdata: %r\n", .{ argv0.*, name });
            break :fail;
        };
        var i: u32 = 1;
        while (i <= h.nport) : (i += 1)
            _ = portfeature(h, i, dat.Fportpower, true) catch {};
        libc.sleep(@intCast(dat.Powerdelay + h.pwrms)) catch {};
        if (h.leds) {
            i = 1;
            while (i <= h.nport) : (i += 1)
                _ = portfeature(h, i, dat.Fportindicator, true) catch {};
        }
        // link to tail, so we always enumarte from the root
        h.next = null;
        var hl = &hubs;
        while (hl.*) |p|
            hl = &p.next;
        hl.* = h;
        nhubs += 1;
        dprint("%s: %s: hub %#p allocated:", .{ argv0.*, name, @intFromPtr(h) });
        dprint(" ports %d pwrms %d max curr %d pwrm %d cmp %d leds %d\n", .{
            h.nport,   h.pwrms,                  h.maxcurrent,
            h.pwrmode, @intFromBool(h.compound), @intFromBool(h.leds),
        });
        return h;
    }
    usb.closedev(h.dev);
    libc.allocator.free(h.port);
    libc.allocator.destroy(h);
    return null;
}

/// If during enumeration we get an I/O error the hub is gone or
/// in pretty bad shape. Because of retries of failed usb commands
/// (and the sleeps they include) it can take a while to detach all
/// ports for the hub. This detaches all ports and makes the hub void.
/// The parent hub will detect a detach (probably right now) and
/// close it later.
fn hubfail(h: *Hub) void {
    dprint("%s: %s: hub failed %#p\n", .{ argv0.*, h.dev.?.dir, @intFromPtr(h) });
    var i: u32 = 1;
    while (i <= h.nport) : (i += 1)
        portdetach(h, i);
    h.failed = true;
}

fn closehub(h: *Hub) void {
    dprint("%s: %s: closing hub %#p\n", .{ argv0.*, h.dev.?.dir, @intFromPtr(h) });
    var hl = &hubs;
    while (hl.*) |p| : (hl = &p.next) {
        if (p == h)
            break;
    }
    if (hl.* == null)
        libc.sysfatal("closehub: no hub", .{});
    hl.* = h.next;
    nhubs -= 1;
    hubfail(h); // detach all ports
    usb.closedev(h.dev);
    libc.allocator.free(h.port);
    libc.allocator.destroy(h);
}

fn portstatus(h: *Hub, p: u32) u32 {
    var buf: [4]u8 = undefined;
    const d = h.dev.?;

    const dbg = usb.usbdebug;
    if (dbg != 0 and dbg < 4)
        usb.usbdebug = 1; // do not be too chatty
    _ = usbcmd(d, usb.Rd2h | usb.Rclass | usb.Rother, usb.Rgetstatus, 0, p, &buf) catch {
        usb.usbdebug = dbg;
        dprint("%s: %s: port %d: get status: %r\n", .{ argv0.*, d.dir, p });

        // try to reset the hubs upstream port
        _ = devctl(d, "reset", .{}) catch {};

        hubfail(h);
        return Nostatus;
    };
    usb.usbdebug = dbg;
    return usb.GET4(&buf);
}

fn stsstr(s: *[80]u8, sts: u32, isusb3: bool) []const u8 {
    var e: usize = 0;
    const put = struct {
        fn f(b: *[80]u8, n: *usize, t: []const u8) void {
            @memcpy(b[n.*..][0..t.len], t);
            n.* += t.len;
        }
    }.f;

    if (sts & dat.PSpresent != 0)
        put(s, &e, "p");
    if (sts & dat.PSenable != 0)
        put(s, &e, "e");
    if (sts & dat.PSovercurrent != 0)
        put(s, &e, "o");
    if (sts & dat.PSreset != 0)
        put(s, &e, "r");
    if (isusb3) {
        if (sts != 0) switch ((sts >> 5) & 0xF) {
            0x00 => put(s, &e, "U0"),
            0x01 => put(s, &e, "U1"),
            0x02 => put(s, &e, "U2"),
            0x03 => put(s, &e, "U3"),
            0x04 => put(s, &e, "SSD"), // SS.Disabled
            0x05 => put(s, &e, "RxD"), // Rx.Detect
            0x06 => put(s, &e, "SSI"), // SS.Inactive
            0x07 => put(s, &e, "P"), // Polling State
            0x08 => put(s, &e, "R"), // Recovery
            0x09 => put(s, &e, "H"), // Hot Reset
            0x0A => put(s, &e, "C"), // Compliance
            0x0B => put(s, &e, "L"), // Loopback
            else => {},
        };
    } else {
        if (sts & dat.PSslow != 0)
            put(s, &e, "l");
        if (sts & dat.PShigh != 0)
            put(s, &e, "h");
        if (sts & dat.PSchange != 0)
            put(s, &e, "c");
        if (sts & dat.PSstatuschg != 0)
            put(s, &e, "s");
        if (sts & dat.PSsuspend != 0)
            put(s, &e, "z");
    }
    if (e == 0)
        put(s, &e, "-");
    return s[0..e];
}

fn getmaxpkt(d: *Dev) i32 {
    var buf: [8]u8 = undefined;

    if (d.isusb3)
        return 512;
    // the start of a DDev: bMaxPacketSize0 is at 7
    const n = usbcmd(d, usb.Rd2h | usb.Rstd | usb.Rdev, usb.Rgetdesc, usb.Ddev << 8 | 0, 0, &buf) catch return -1;
    if (n != buf.len)
        return -1;
    return buf[7];
}

/// BUG: does not consider max. power avail.
fn portattach(h: *Hub, p: u32) i32 {
    var fname: [80]u8 = undefined;
    var buf: [40]u8 = undefined;
    var sb: [80]u8 = undefined;
    var sts: u32 = undefined;
    var sp: []const u8 = undefined;

    const d = h.dev.?;
    const pp = &h.port[p];
    if (pp.state != dat.Pdisabled)
        return -1;
    // prevent repeated attaches in short succession as it is a indication
    // for a reset loop or a very flanky device.
    if (pp.acount != 0 and nowms -% pp.atime >= dat.Attachdelay)
        pp.acount = 0;
    pp.atime = nowms;
    pp.acount += 1;
    if (pp.acount > dat.Attachcount) {
        libc.fprint(2, "%s: %s: port %d: too many attaches in short succession\n", .{ argv0.*, d.dir, p });
        // don't call portfail()
        return 1;
    }
    if (d.isusb3) {
        sts = pp.sts;
        sp = "super";
    } else {
        _ = portfeature(h, p, dat.Fportreset, true) catch {
            dprint("%s: %s: port %d: set reset: %r\n", .{ argv0.*, d.dir, p });
            return -1;
        };
        libc.sleep(if (d.depth < 0) dat.Rootresetdelay else dat.Portresetdelay) catch {};
        sts = portstatus(h, p);
        if (sts == Nostatus)
            return -1;
        sp = "full";
        if (sts & dat.PSslow != 0)
            sp = "low";
        if (sts & dat.PShigh != 0)
            sp = "high";
    }
    dprint("%s: %s: port %d: attached status %s %#ux, speed %s\n", .{ argv0.*, d.dir, p, stsstr(&sb, sts, d.isusb3), sts, sp });
    if ((sts & dat.PSenable) == 0) {
        dprint("%s: %s: port %d: not enabled?\n", .{ argv0.*, d.dir, p });
        return -1;
    }
    pp.sts = sts;
    pp.state = dat.Pattached;
    _ = devctl(d, "newdev %s %d", .{ sp, p }) catch {
        libc.fprint(2, "%s: %s: port %d: newdev: %r\n", .{ argv0.*, d.dir, p });
        return -1;
    };
    _ = sys.seek(d.cfd, 0, 0);
    const nr = sys.read(d.cfd, buf[0 .. buf.len - 1]);
    if (nr <= 0) {
        if (nr == 0) libc.werrstr("eof", .{});
        libc.fprint(2, "%s: %s: port %d: newdev: %r\n", .{ argv0.*, d.dir, p });
        return -1;
    }
    const name = libc.sprint(fname[0 .. fname.len - 1], "/dev/usb/%s", .{buf[0..@intCast(nr)]});
    const nd = usb.opendev(name) orelse {
        libc.fprint(2, "%s: %s: port %d: opendev: %r\n", .{ argv0.*, d.dir, p });
        return -1;
    };
    pp.dev = nd;
    nd.depth = d.depth + 1;
    nd.isusb3 = d.isusb3;
    if (usb.usbdebug > 2)
        _ = devctl(nd, "debug 1", .{}) catch {};
    var i: u32 = 1;
    while (true) : (i += 1) {
        if (usb.opendevdata(nd, sys.ORDWR)) |_|
            break
        else |_| {}
        if (i >= 10) {
            dprint("%s: %s: opendevdata: %r\n", .{ argv0.*, nd.dir });
            return -1;
        }
        sts = portstatus(h, p);
        if (sts == Nostatus)
            return -1;
        if ((sts & dat.PSenable) == 0)
            return -1;
        libc.sleep(i * 50) catch {};
    }
    // for xhci, this command is ignored by the driver as the device address
    // has already been assigned by the controller firmware when opening ep0.
    _ = usbcmd(nd, usb.Rh2d | usb.Rstd | usb.Rdev, usb.Rsetaddress, @intCast(nd.id & 0x7f), 0, null) catch {
        dprint("%s: %s: port %d: setaddress: %r\n", .{ argv0.*, d.dir, p });
        return -1;
    };
    _ = devctl(nd, "address", .{}) catch {
        dprint("%s: %s: port %d: set address: %r\n", .{ argv0.*, d.dir, p });
        return -1;
    };

    const mp = getmaxpkt(nd);
    if (mp < 0) {
        dprint("%s: %s: port %d: getmaxpkt: %r\n", .{ argv0.*, d.dir, p });
        return -1;
    }
    dprint("%s; %s: port %d: maxpkt %d\n", .{ argv0.*, d.dir, p, mp });

    // force reopen in configdev() after setting maxpkt
    _ = sys.close(nd.dfd);
    nd.dfd = -1;

    _ = devctl(nd, "maxpkt %d", .{mp}) catch {};

    usb.configdev(nd) catch {
        dprint("%s: %s: port %d: configdev: %r\n", .{ argv0.*, d.dir, p });
        return -1;
    };

    // assign stable name based on device descriptor
    usbd.assignhname(nd);

    // We always set conf #1. BUG.
    _ = usbcmd(nd, usb.Rh2d | usb.Rstd | usb.Rdev, usb.Rsetconf, 1, 0, null) catch {
        libc.fprint(2, "%s: %s: port %d: setconf: %r\n", .{ argv0.*, d.dir, p });
        _ = usbcmd(nd, usb.Rh2d | usb.Rstd | usb.Rdev, usb.Rsetconf, 1, 0, null) catch
            return -1;
    };

    pp.state = dat.Pconfigured;
    dprint("%s: %s: port %d: configured: %s\n", .{ argv0.*, d.dir, p, nd.dir });

    // Hubs are handled directly by this process avoiding
    // concurrent operation so that at most one device
    // has the config address in use.
    const ud = nd.usb.?;
    if (ud.class == usb.Clhub) {
        pp.hub = newhub(nd.dir, nd);
        if (pp.hub == null)
            return -1;
        return 0;
    }

    // close control endpoint so driver can open it
    _ = sys.close(nd.dfd);
    nd.dfd = -1;

    // set device info for ctl file
    var cb: [12]u8 = undefined;
    _ = devctl(nd, "info %s csp %#08ux vid %#.4ux did %#.4ux %q %q %s", .{
        usb.classname(usb.Class(ud.csp), &cb), ud.csp, ud.vid, ud.did,
        ud.vendor,                             ud.product, nd.hname,
    }) catch {};

    // notify driver
    usbd.attachdev(nd);

    return 0;
}

fn portdetach(h: *Hub, p: u32) void {
    const d = h.dev.?;
    const pp = &h.port[p];

    if (pp.state == dat.Pdisabled)
        return;
    dprint("%s: %s: port %d: detached\n", .{ argv0.*, d.dir, p });
    if (pp.dev) |pd| {
        _ = devctl(pd, "detach", .{}) catch {};

        if (pp.state == dat.Pconfigured and pd.usb.?.class != usb.Clhub)
            usbd.detachdev(pd);

        usb.closedev(pd);
        pp.dev = null;
    }
    if (pp.hub) |ph| {
        closehub(ph);
        pp.hub = null;
    }
    pp.state = dat.Pdisabled;
}

fn portfail(h: *Hub, p: u32, what: []const u8) void {
    const d = h.dev.?;
    dprint("%s: %s: port %d: failed: %s\n", .{ argv0.*, d.dir, p, what });
    portdetach(h, p);
    if (d.isusb3) {
        _ = portfeature(h, p, dat.Fbhportreset, true) catch
            dprint("%s: %s: port %d: set warm reset: %r\n", .{ argv0.*, d.dir, p });
    } else {
        _ = portfeature(h, p, dat.Fportenable, false) catch
            dprint("%s: %s: port %d: clear enable: %r\n", .{ argv0.*, d.dir, p });
    }
}

fn portresetwanted(dev: ?*Dev) bool {
    var buf: [5]u8 = undefined;

    const d = dev orelse return false;
    if (d.cfd >= 0 and sys.pread(d.cfd, &buf, 0) == 5)
        return std.mem.eql(u8, &buf, "reset");
    return false;
}

/// -1, 0, or 1 when the list of hubs changed.
fn enumhub(h: *Hub, p: u32) i32 {
    var sb: [80]u8 = undefined;

    if (h.failed)
        return 0;
    const d = h.dev.?;
    if (usb.usbdebug > 3)
        libc.fprint(2, "%s: %s: port %d enumhub\n", .{ argv0.*, d.dir, p });
    var sts = portstatus(h, p);
    if (sts == Nostatus)
        return -1;
    if ((sts & dat.PSsuspend) != 0 and !d.isusb3) {
        _ = portfeature(h, p, dat.Fportsuspend, false) catch
            dprint("%s: %s: port %d: clear suspend: %r\n", .{ argv0.*, d.dir, p });
        libc.sleep(dat.Resumedelay) catch {};
        sts = portstatus(h, p);
        // Kept from C: see the top of the file
        if (sts != Nostatus)
            return -1;
        dprint("%s: %s: port %d: unsuspended sts: %s %#ux\n", .{ argv0.*, d.dir, p, stsstr(&sb, sts, d.isusb3), sts });
    }
    const onhubs = nhubs;
    const pp = &h.port[p];
    if (sts != pp.sts) {
        dprint("%s: %s port %d: sts %s %#ux ->", .{ argv0.*, d.dir, p, stsstr(&sb, pp.sts, d.isusb3), pp.sts });
        dprint(" %s %#ux\n", .{ stsstr(&sb, sts, d.isusb3), sts });
    }
    if ((sts & dat.PSpresent) == 0 and (pp.sts & dat.PSpresent) != 0) {
        pp.sts = sts;
        portdetach(h, p);
    } else if ((sts & dat.PSenable) == 0 and (pp.sts & dat.PSenable) != 0) {
        pp.sts = 0;
        portfail(h, p, "reconnect");
    } else if ((sts & dat.PSenable) != 0 and portresetwanted(pp.dev)) {
        pp.sts = 0;
        portfail(h, p, "reset");
    } else if ((sts & dat.PSpresent) != 0 and (pp.sts & dat.PSpresent) == 0) {
        pp.sts = sts;
        if (portattach(h, p) < 0) {
            if (h.failed)
                return -1;
            if (pp.state != dat.Pdisabled)
                pp.sts = 0; // force re-attach
            portfail(h, p, "attach");
        }
    } else {
        pp.sts = sts;
    }
    return @intFromBool(onhubs != nhubs);
}

fn dump() void {
    mustdump = false;
    var hp = hubs;
    while (hp) |h| : (hp = h.next) {
        var i: usize = 1;
        while (i <= h.nport) : (i += 1)
            libc.fprint(2, "%s: hub %#p %s port %d: %U\n", .{ argv0.*, @intFromPtr(h), h.dev.?.dir, i, usb.U{ .d = h.port[i].dev } });
    }
}

pub fn work(_: void) void {
    // Enumerate (and acknowledge after first enumeration).
    // Do NOT perform enumeration concurrently for the same
    // controller. new devices attached respond to a default
    // address (0) after reset, thus enumeration has to work
    // one device at a time at least before addresses have been
    // assigned.
    // Do not use hub interrupt endpoint because we
    // have to poll the root hub(s) in any case.
    while (true) : (nowms +%= pollms) {
        libc.qlock(&hublock);
        again: while (true) {
            var hp = hubs;
            while (hp) |h| : (hp = h.next) {
                var i: u32 = 1;
                while (i <= h.nport) : (i += 1) {
                    if (enumhub(h, i) != 0) {
                        // changes in hub list; repeat
                        continue :again;
                    }
                }
            }
            break;
        }
        libc.qunlock(&hublock);
        usbd.checkidle();
        libc.sleep(pollms) catch {};
        if (mustdump)
            dump();
    }
}
