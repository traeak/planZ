//! from nusb/lib/dev.c
//!
//! DIFF:
//!   - usbcmd's data is a slice whose length is the count; for a
//!     request to the device it is only read.
//!   - A Dev's dir is the name as given.  The C allocates 30 bytes
//!     more "to concat /<epfilename>", which nothing here does.
//!
//! Kept from C: setconf tests usbcmd's result for > 0, which a request
//! without data never gives: it reports no failure.  No program here
//! calls it (usbd sends the request itself).

const std = @import("std");
const libc = @import("libc");
const usb = @import("usb.zig");
const sys = libc.sys;

const Dev = usb.Dev;
const Ep = usb.Ep;
const Usbdev = usb.Usbdev;
const Conf = usb.Conf;
const Iface = usb.Iface;
const Error = libc.Error;
const dprint = usb.dprint;

/// epN.M -> N
fn nameid(s: []const u8) i32 {
    var nm: [20]u8 = undefined;

    const r = std.mem.lastIndexOfScalar(u8, s, 'p') orelse return -1;
    const rest = s[r + 1 ..];
    const n = @min(rest.len, nm.len - 1);
    @memcpy(nm[0..n], rest[0..n]);
    const dot = std.mem.indexOfScalar(u8, nm[0..n], '.') orelse return -1;
    return @truncate(libc.atoi(nm[0..dot]));
}

pub fn openep(d: *Dev, ep: *Ep) ?*Dev {
    var namebuf: [40]u8 = undefined;

    if (d.cfd < 0 or d.usb == null) {
        libc.werrstr("device not configured", .{});
        return null;
    }
    const name = libc.sprint(namebuf[0 .. namebuf.len - 1], "/dev/usb/ep%d.%d", .{ d.id, ep.id });
    var epd: *Dev = undefined;
    if (libc.access(name, libc.AEXIST)) {
        dprint("%s: %s already exists; trying to open\n", .{ libc.argv0, name });
        epd = opendev(name) orelse return null;
    } else {
        var mode: []const u8 = "rw"; // How many modes?
        if (ep.dir == usb.Ein)
            mode = "r";
        if (ep.dir == usb.Eout)
            mode = "w";
        _ = devctl(d, "new %d %d %s", .{ ep.id, ep.type, mode }) catch {
            dprint("%s: %s: new: %r\n", .{ libc.argv0, d.dir });
            return null;
        };
        epd = opendev(name) orelse return null;
    }
    epd.ep = ep;
    epd.id = ep.id;
    if (devctl(epd, "maxpkt %d", .{ep.maxpkt})) |_|
        dprint("%s: %s: maxpkt %d\n", .{ libc.argv0, epd.dir, ep.maxpkt })
    else |_|
        libc.fprint(2, "%s: %s: openep: maxpkt: %r\n", .{ libc.argv0, epd.dir });
    epd.maxpkt = ep.maxpkt;
    ntds: {
        if (ep.ntds > 1) {
            _ = devctl(epd, "ntds %d", .{ep.ntds}) catch {
                libc.fprint(2, "%s: %s: openep: ntds: %r\n", .{ libc.argv0, epd.dir });
                break :ntds;
            };
        }
        dprint("%s: %s: ntds %d\n", .{ libc.argv0, epd.dir, ep.ntds });
    }
    if ((ep.type == usb.Eintr or ep.type == usb.Eiso) and ep.pollival != 0)
        _ = devctl(epd, "pollival %d", .{ep.pollival}) catch
            libc.fprint(2, "%s: %s: openep: pollival: %r\n", .{ libc.argv0, epd.dir });
    return epd;
}

pub fn opendev(name: []const u8) ?*Dev {
    const d = usb.create(Dev);
    usb.incref(&d.ref);

    d.dfd = -1;
    d.dir = usb.estrdup(name);
    const ctl = std.mem.concat(libc.allocator, u8, &.{ name, "/ctl" }) catch libc.sysfatal("malloc: %r", .{});
    d.cfd = libc.open(ctl, sys.ORDWR | sys.OCEXEC) catch -1;
    libc.allocator.free(ctl);
    d.ep = null;
    d.id = nameid(name);
    if (d.cfd < 0) {
        libc.werrstr("can't open endpoint %s: %r", .{d.dir});
        libc.allocator.free(d.dir);
        libc.allocator.destroy(d);
        return null;
    }
    d.hname = null;
    dprint("%s: opendev %#p %s\n", .{ libc.argv0, @intFromPtr(d), name });
    return d;
}

pub fn opendevdata(d: *Dev, mode: u32) Error!i32 {
    var buf: [80]u8 = undefined; // more than enough for a usb path

    const name = libc.sprint(buf[0 .. buf.len - 1], "%s/data", .{d.dir});
    d.dfd = libc.open(name, mode | sys.OCEXEC) catch -1;
    if (d.dfd < 0)
        return error.Plan9;
    return d.dfd;
}

/// Max device conf is also limited by max control request size as
/// limited by Maxctllen in the kernel usb.h (both limits are arbitrary).
/// Some devices ignore the high byte of control transfer reads so keep
/// the low byte all ones. asking for 16K kills Newsham's disk.
const Maxdevconf = 4 * 1024 - 1;

pub fn loaddevconf(d: *Dev, n: usize) Error!usize {
    const ud = d.usb.?;
    if (n >= ud.conf.len) {
        libc.werrstr("loaddevconf: bug: out of configurations in device", .{});
        libc.fprint(2, "%s: %r\n", .{libc.argv0});
        return error.Plan9;
    }
    const buf = usb.emallocz(Maxdevconf, false);
    defer libc.allocator.free(buf);
    const typ = usb.Rd2h | usb.Rstd | usb.Rdev;
    const nr = try usbcmd(d, typ, usb.Rgetdesc, usb.Dconf << 8 | @as(u32, @intCast(n)), 0, buf);
    if (nr < usb.Dconflen)
        return error.Plan9;
    if (ud.conf[n] == null)
        ud.conf[n] = usb.create(Conf);
    return usb.parseconf(ud, ud.conf[n].?, buf[0..nr]);
}

pub fn mkep(d: *Usbdev, id: i32) *Ep {
    const ep = usb.create(Ep);
    ep.id = id;

    const i: usize = @intCast(id & usb.Epmax);
    ep.next = d.ep[i];
    d.ep[i] = ep;

    return ep;
}

/// b is the buffer the string descriptor was read into and n how much
/// of it was read (0 if nothing was).
fn mkstr(b: []const u8, n_: usize) []u8 {
    var n = n_;
    if (n > 0 and n > b[0])
        n = b[0];
    if (n <= 2 or (n & 1) != 0)
        return usb.estrdup("none");
    n = (n - 2) / 2;
    const us = usb.emallocz(n * libc.UTFmax + 1, false);
    var s: usize = 0;
    var i: usize = 2;
    while (n > 0) : (n -= 1) {
        s += libc.runetochar(us[s..], usb.GET2(b[i..]));
        i += 2;
    }
    // DIFF: the block is made the length of the text, which is a slice
    return libc.allocator.realloc(us, s) catch us[0..s];
}

pub fn loaddevstr(d: *Dev, sid: i32) []u8 {
    var buf: [256 - 2]u8 = undefined; // keep size < 256

    if (sid == 0)
        return usb.estrdup("none");
    const typ = usb.Rd2h | usb.Rstd | usb.Rdev;

    // there are devices which do not return a string if used
    // with invalid language id, so at least try to use the first
    // one and choose english if failed
    var nr = usbcmd(d, typ, usb.Rgetdesc, usb.Dstr << 8, 0, &buf) catch 0;
    var langid: u32 = undefined;
    if (nr < 4)
        langid = 0x0409 // english
    else
        langid = @as(u32, buf[3]) << 8 | buf[2];

    nr = usbcmd(d, typ, usb.Rgetdesc, usb.Dstr << 8 | @as(u32, @intCast(sid & 0xFF)), langid, &buf) catch 0;
    return mkstr(&buf, nr);
}

pub fn loaddevdesc(d: *Dev) Error!usize {
    var buf: [usb.Ddevlen]u8 = @splat(0);

    const typ = usb.Rd2h | usb.Rstd | usb.Rdev;
    const nr = try usbcmd(d, typ, usb.Rgetdesc, usb.Ddev << 8 | 0, 0, &buf);
    // Several hubs are returning descriptors of 17 bytes, not 18.
    // We accept them and leave number of configurations as zero.
    // (a get configuration descriptor also fails for them!)
    if (nr < usb.Ddevlen) {
        dprint("%s: %s: warning: device with short descriptor (got %d bytes)\n", .{ libc.argv0, d.dir, nr });
        if (nr < usb.Ddevlen - 1) {
            libc.werrstr("short device descriptor (%d bytes)", .{nr});
            return error.Plan9;
        }
    }
    const ud = usb.create(Usbdev);
    d.usb = ud;
    const ep0 = mkep(ud, 0);
    ep0.dir = usb.Eboth;
    ep0.type = usb.Econtrol;
    ep0.maxpkt = 8; // a default
    d.maxpkt = 8;
    d.ep = ep0;
    const r = try usb.parsedev(d, buf[0..nr]);
    ud.vendor = loaddevstr(d, ud.vsid);
    if (!std.mem.eql(u8, ud.vendor.?, "none")) {
        ud.product = loaddevstr(d, ud.psid);
        ud.serial = loaddevstr(d, ud.ssid);
    }
    return r;
}

pub fn configdev(d: *Dev) Error!void {
    if (d.dfd < 0)
        _ = opendevdata(d, sys.ORDWR) catch {};
    if (d.dfd < 0)
        return error.Plan9;
    _ = try loaddevdesc(d);
    var i: usize = 0;
    while (i < d.usb.?.nconf) : (i += 1)
        _ = try loaddevconf(d, i);
}

fn closeconf(conf: ?*Conf) void {
    const c = conf orelse return;
    for (&c.iface) |*slot| {
        while (slot.*) |f| {
            slot.* = f.next;
            libc.allocator.destroy(f);
        }
    }
    libc.allocator.destroy(c);
}

fn freestr(s: ?[]u8) void {
    if (s) |p|
        libc.allocator.free(p);
}

pub fn closedev(dev: ?*Dev) void {
    const d = dev orelse return;
    if (usb.decref(&d.ref) != 0)
        return;
    dprint("%s: closedev %#p %s\n", .{ libc.argv0, @intFromPtr(d), d.dir });
    if (d.cfd >= 0)
        _ = sys.close(d.cfd);
    if (d.dfd >= 0)
        _ = sys.close(d.dfd);
    d.cfd = -1;
    d.dfd = -1;
    libc.allocator.free(d.dir);
    d.dir = &.{};
    freestr(d.hname);
    d.hname = null;
    const usbdev = d.usb;
    d.usb = null;
    if (usbdev) |ud| {
        freestr(ud.vendor);
        freestr(ud.product);
        freestr(ud.serial);
        for (&ud.ep) |*slot| {
            while (slot.*) |ep| {
                slot.* = ep.next;
                libc.allocator.destroy(ep);
            }
        }
        for (ud.ddesc) |dd| {
            if (dd) |p| {
                libc.allocator.free(p.data);
                libc.allocator.destroy(p);
            }
        }
        for (ud.conf) |c|
            closeconf(c);
        libc.allocator.destroy(ud);
    }
    libc.allocator.destroy(d);
}

fn reqstr(buf: *[40]u8, typ: u32, req: u32) []const u8 {
    const ds = [_][]const u8{ "dev", "if", "ep", "oth" };

    var f: libc.fmt.Fmt = .{ .buf = buf[0..39] };
    if (typ & usb.Rd2h != 0)
        f.puts("d2h")
    else
        f.puts("h2d");
    if (typ & usb.Rclass != 0)
        f.puts("|cls")
    else if (typ & usb.Rvendor != 0)
        f.puts("|vnd")
    else
        f.puts("|std");
    f.putc('|');
    f.puts(ds[typ & 3]);

    switch (req) {
        usb.Rgetstatus => f.puts(" getsts"),
        usb.Rclearfeature => f.puts(" clrfeat"),
        usb.Rsetfeature => f.puts(" setfeat"),
        usb.Rsetaddress => f.puts(" setaddr"),
        usb.Rgetdesc => f.puts(" getdesc"),
        usb.Rsetdesc => f.puts(" setdesc"),
        usb.Rgetconf => f.puts(" getcnf"),
        usb.Rsetconf => f.puts(" setcnf"),
        usb.Rgetiface => f.puts(" getif"),
        usb.Rsetiface => f.puts(" setif"),
        else => {},
    }
    return buf[0..f.n];
}

/// -1 where the C's returns -1.
fn cmdreq(d: *Dev, typ: u32, req: u32, value: u32, index: u32, data: ?[]const u8, count: usize) isize {
    var buf: [8]u8 = undefined;
    var wp: []u8 = &buf;
    var ndata: usize = 0;

    if (data) |p| {
        ndata = count;
        wp = usb.emallocz(8 + ndata, false);
        @memcpy(wp[8..], p[0..ndata]);
    }
    defer if (data != null) libc.allocator.free(wp);
    wp[0] = @truncate(typ);
    wp[1] = @truncate(req);
    usb.PUT2(wp[2..], value);
    usb.PUT2(wp[4..], index);
    usb.PUT2(wp[6..], @truncate(count));
    if (usb.usbdebug > 2) {
        var rb: [40]u8 = undefined;
        libc.fprint(2, "%s: %s val %d|%d idx %d cnt %d out[%d] %H\n", .{
            d.dir,        reqstr(&rb, typ, req), value >> 8, value & 0xFF,
            index,        count,                 ndata + 8,
            usb.Hex{ .b = wp },
        });
    }
    const n = sys.write(d.dfd, wp);
    if (n < 0)
        return -1;
    if (n != 8 + ndata) {
        dprint("%s: cmd: short write: %d\n", .{ libc.argv0, n });
        return -1;
    }
    return @intCast(ndata);
}

fn cmdrep(d: *Dev, buf: []u8) isize {
    const nb = sys.read(d.dfd, buf);
    if (nb > 0 and usb.usbdebug > 2)
        libc.fprint(2, "%s: in[%d] %H\n", .{ d.dir, nb, usb.Hex{ .b = buf[0..@intCast(nb)] } });
    return nb;
}

/// A control request on d's data file: to the device with data (or
/// none) after it, or (Rd2h in typ) from the device into data.  The
/// number of bytes that went or came.
pub fn usbcmd(d: *Dev, typ: u32, req: u32, value: u32, index: u32, data: ?[]u8) Error!usize {
    var errbuf: [libc.ERRMAX]u8 = undefined;
    var err: []const u8 = "";
    var r: isize = undefined;
    var tries: u32 = 1;
    const count: usize = if (data) |p| p.len else 0;

    // Some devices do not respond to commands some times.
    // Others even report errors but later work just fine. Retry.
    while (true) : (tries += 1) {
        if (typ & usb.Rd2h != 0)
            r = cmdreq(d, typ, req, value, index, null, count)
        else
            r = cmdreq(d, typ, req, value, index, data, count);
        if (r >= 0) {
            if (typ & usb.Rd2h == 0)
                break;
            r = cmdrep(d, data orelse &.{});
            if (r > 0)
                break;
            if (r == 0)
                libc.werrstr("no data from device", .{});
        }
        if (err.len == 0)
            err = libc.rerrstr(&errbuf);
        if (tries >= usb.Uctries)
            break;
        libc.sleep(usb.Ucdelay) catch {};
    }
    if (r >= 0 and tries > 1) {
        // let the user know the device is not in good shape
        var rb: [40]u8 = undefined;
        libc.fprint(2, "%s: usbcmd: %s: %s required %d attempts (%s)\n", .{ libc.argv0, d.dir, reqstr(&rb, typ, req), tries, err });
    }
    if (r < 0)
        return error.Plan9;
    return @intCast(r);
}

pub fn unstall(dev: *Dev, ep: *Dev, dir_: u32) Error!void {
    const dir: u32 = if (dir_ == usb.Ein) 0x80 else 0;
    const r = usb.Rh2d | usb.Rstd | usb.Rep;
    _ = usbcmd(dev, r, usb.Rclearfeature, usb.Fhalt, @as(u32, @intCast(ep.id & 0xF)) | dir, null) catch {
        libc.werrstr("unstall: %s: %r", .{ep.dir});
        return error.Plan9;
    };
    _ = devctl(ep, "clrhalt", .{}) catch {
        libc.werrstr("clrhalt: %s: %r", .{ep.dir});
        return error.Plan9;
    };
}

pub fn setconf(d: *Dev, c: *Conf) void {
    // Kept from C: see the top of the file
    _ = usbcmd(d, usb.Rh2d | usb.Rstd | usb.Rdev, usb.Rsetconf, @intCast(c.cval), 0, null) catch {};
}

pub fn setalt(d: *Dev, ifc: *Iface) Error!void {
    _ = usbcmd(d, usb.Rh2d | usb.Rstd | usb.Riface, usb.Rsetiface, @intCast(ifc.alt), @intCast(ifc.id), null) catch {
        libc.werrstr("setalt: %s: %r", .{d.dir});
        return error.Plan9;
    };
}

/// To be sure it uses a single write.
pub fn devctl(dev: *Dev, comptime format: []const u8, args: anytype) Error!usize {
    var buf: [128]u8 = undefined;

    return libc.write(dev.cfd, libc.sprint(buf[0 .. buf.len - 1], format, args));
}

pub fn getdev(devid: []const u8) ?*Dev {
    var buf: [40]u8 = undefined;
    var name: []u8 = undefined;
    // the hash name: what follows the colon
    var p: ?[]const u8 = null;

    if (devid.len > 0 and (devid[0] == '/' or devid[0] == '#')) {
        name = libc.sprint(buf[0 .. buf.len - 1], "%s", .{devid});
        if (std.mem.lastIndexOfScalar(u8, name, '/') != null) {
            if (std.mem.lastIndexOfScalar(u8, name, ':')) |i| {
                p = name[i + 1 ..];
                name = name[0..i];
            }
        }
    } else {
        const n = libc.strtol32(devid, 10);
        if (n.n < devid.len and devid[n.n] == ':')
            p = devid[n.n + 1 ..];
        name = libc.sprint(buf[0 .. buf.len - 1], "/dev/usb/ep%d.0", .{n.v});
    }

    const d = opendev(name) orelse return null;
    configdev(d) catch {
        closedev(d);
        return null;
    };

    if (p) |h| {
        d.hname = usb.estrdup(h);
    } else {
        var nb: [16]u8 = undefined;
        d.hname = usb.estrdup(libc.sprint(&nb, "%d", .{d.id}));
    }

    return d;
}
