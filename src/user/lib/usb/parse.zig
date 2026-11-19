//! from nusb/lib/parse.c
//!
//! Fixed from C: a device descriptor of usb 3 with a bMaxPacketSize0
//! over 30 (the exponent of the size) made a shift by more than the
//! width, which is 0 or anything; it is taken as 9 (512 bytes, the
//! only size usb 3 has).

const std = @import("std");
const libc = @import("libc");
const usb = @import("usb.zig");

const Dev = usb.Dev;
const Usbdev = usb.Usbdev;
const Conf = usb.Conf;
const Iface = usb.Iface;
const Ep = usb.Ep;
const Desc = usb.Desc;
const Error = libc.Error;
const ddprint = usb.ddprint;
const dprint = usb.dprint;

pub fn parsedev(xd: *Dev, b: []const u8) Error!usize {
    const d = xd.usb.?;
    // DDev: bLength 0, bDescriptorType 1, bcdUSB 2, bDevClass 4,
    // bDevSubClass 5, bDevProtocol 6, bMaxPacketSize0 7, idVendor 8,
    // idProduct 10, bcdDev 12, iManufacturer 14, iProduct 15,
    // iSerialNumber 16, bNumConfigurations 17.  The buffer has
    // Ddevlen bytes whatever was read: what was not read is 0.
    var dd: [usb.Ddevlen]u8 = @splat(0);
    @memcpy(dd[0..@min(b.len, dd.len)], b[0..@min(b.len, dd.len)]);
    if (usb.usbdebug > 1)
        libc.fprint(2, "%s: parsedev %s: %H\n", .{ libc.argv0, xd.dir, usb.Hex{ .b = &dd } });
    if (dd[0] < usb.Ddevlen) {
        libc.werrstr("short dev descr. (%d < %d)", .{ dd[0], usb.Ddevlen });
        return error.Plan9;
    }
    if (dd[1] != usb.Ddev) {
        libc.werrstr("%d is not a dev descriptor", .{dd[1]});
        return error.Plan9;
    }
    d.csp = usb.CSP(dd[4], dd[5], dd[6]);
    d.ver = @intCast(usb.GET2(dd[2..]));
    xd.isusb3 = d.ver >= 0x0300;
    if (xd.isusb3)
        xd.maxpkt = @as(i32, 1) << @intCast(if (dd[7] > 30) 9 else dd[7])
    else
        xd.maxpkt = dd[7];
    d.ep[0].?.maxpkt = xd.maxpkt;
    d.class = dd[4];
    d.nconf = dd[17];
    if (d.nconf == 0)
        dprint("%s: %s: no configurations\n", .{ libc.argv0, xd.dir });
    d.vid = @intCast(usb.GET2(dd[8..]));
    d.did = @intCast(usb.GET2(dd[10..]));
    d.dno = @intCast(usb.GET2(dd[12..]));
    d.vsid = dd[14];
    d.psid = dd[15];
    d.ssid = dd[16];
    if (b.len > usb.Ddevlen and usb.usbdebug > 1)
        libc.fprint(2, "%s: %s: parsedev: %d bytes left", .{ libc.argv0, xd.dir, b.len - usb.Ddevlen });
    return usb.Ddevlen;
}

fn parseiface(d: *Usbdev, c: *Conf, b: []const u8) Error!*Iface {
    if (b.len < usb.Difacelen) {
        libc.werrstr("short interface descriptor", .{});
        return error.Plan9;
    }
    // DIface: bInterfaceNumber 2, bAlternateSetting 3, bNumEndpoints
    // 4, bInterfaceClass 5, bInterfaceSubClass 6, bInterfaceProtocol 7
    const class: u32 = b[5];
    const subclass: u32 = b[6];
    const proto: u32 = b[7];
    var csp = usb.CSP(class, subclass, proto);
    if (csp == 0)
        csp = d.csp;
    if (d.class == 0)
        d.class = @intCast(class);
    const alt: i32 = b[3];
    const id: usize = b[2];
    if (id >= c.iface.len) {
        libc.werrstr("bad interface number %d", .{id});
        return error.Plan9;
    }
    var ip = c.iface[id];
    while (ip) |p| : (ip = p.next) {
        if (p.csp == csp and p.alt == alt)
            return p;
    }
    const n = usb.create(Iface);
    n.id = @intCast(id);
    n.csp = csp;
    n.alt = alt;
    n.next = c.iface[id];
    c.iface[id] = n;
    if (d.csp == 0) // use csp from 1st iface
        d.csp = n.csp; // if device has none
    if (c == d.conf[0] and id == 0) // ep0 was already there
        d.ep[0].?.iface = n;
    return n;
}

fn parseendpt(d: *Usbdev, c: *Conf, ip: *Iface, b: []const u8) Error!*Ep {
    if (b.len < usb.Deplen) {
        libc.werrstr("short endpoint descriptor", .{});
        return error.Plan9;
    }
    // DEp: bEndpointAddress 2, bmAttributes 3, wMaxPacketSize 4,
    // bInterval 6
    const typ: u8 = b[3] & 0x03;
    const addr: i32 = b[2];
    var dir: u8 = if (addr & 0x80 != 0) usb.Ein else usb.Eout;

    // the endpoint id is created once, setting
    // type and direction, meaning the endpoint's
    // id must be unique for (type, dir) relative
    // to all other potential endpoints from
    // interfaces/altsettings on this device.
    //
    // the low Epmax bits of the id contains the
    // endpoint address that must be preserved.
    var id: i32 = addr & usb.Epmax;
    var ep: ?*Ep = undefined;
    again: while (true) {
        ep = d.ep[@intCast(id & usb.Epmax)];
        while (ep) |p| : (ep = p.next) {
            if (p.id != id)
                continue;
            if (p.type != typ) {
                id += usb.Epmax + 1;
                continue :again;
            }
            if (p.dir == dir)
                break;
            // Ein/Eout endpoints from the same
            // interface/altsetting can be merged
            // into one. (except for iso).
            if (p.iface != ip or typ == usb.Eiso) {
                id += usb.Epmax + 1;
                continue :again;
            }
            dir = usb.Eboth;
            break;
        }
        break;
    }

    if (ep == null or ep.?.iface != ip)
        ep = usb.mkep(d, id);
    const e = ep.?;

    e.dir = dir;
    e.type = typ;
    e.iface = ip;
    e.conf = c;
    e.maxpkt = @intCast(usb.GET2(b[4..]));
    e.ntds = 1 + ((e.maxpkt >> 11) & 3);
    e.maxpkt &= 0x7FF;
    e.attrib = b[3];
    e.pollival = b[6];

    var i: usize = 0;
    while (i < ip.ep.len) : (i += 1) {
        if (ip.ep[i] == null) {
            ip.ep[i] = e;
            break;
        }
        if (ip.ep[i] == e)
            break;
    }
    if (i >= ip.ep.len)
        libc.fprint(2, "%s: parseendpt: too many endpoints in interface", .{libc.argv0});

    return e;
}

fn dname(dtype: u8) []const u8 {
    return switch (dtype) {
        usb.Ddev => "device",
        usb.Dconf => "config",
        usb.Dstr => "string",
        usb.Diface => "interface",
        usb.Dep => "endpoint",
        usb.Dreport => "report",
        usb.Dphysical => "phys",
        else => "desc",
    };
}

pub fn parsedesc(d: *Usbdev, c: *Conf, b_: []const u8) Error!usize {
    var b = b_;
    var tot: usize = 0;
    var ip: ?*Iface = null;
    var ep: ?*Ep = null;
    var nd: usize = 0;
    while (nd < d.ddesc.len) : (nd += 1) {
        if (d.ddesc[nd] == null)
            break;
    }

    while (b.len > 2 and b[0] != 0 and b[0] <= b.len) {
        const len: usize = b[0];
        if (usb.usbdebug > 1) {
            libc.fprint(2, "%s:\t\tparsedesc %s %x[%d] %H\n", .{ libc.argv0, dname(b[1]), b[1], b[0], usb.Hex{ .b = b[0..len] } });
        }
        switch (b[1]) {
            usb.Ddev, usb.Dconf => {
                libc.werrstr("unexpected descriptor %d", .{b[1]});
                ddprint("%s\tparsedesc: %r", .{libc.argv0});
            },
            usb.Diface => {
                ip = parseiface(d, c, b) catch |e| {
                    ddprint("%s\tparsedesc: %r\n", .{libc.argv0});
                    return e;
                };
            },
            usb.Dep => ept: {
                const p = ip orelse {
                    libc.werrstr("unexpected endpoint descriptor", .{});
                    break :ept;
                };
                ep = parseendpt(d, c, p, b) catch |e| {
                    ddprint("%s\tparsedesc: %r\n", .{libc.argv0});
                    return e;
                };
            },
            else => other: {
                if (nd >= d.ddesc.len) {
                    libc.fprint(2, "%s: parsedesc: too many " ++
                        "device-specific descriptors for device" ++
                        " %s %s\n", .{ libc.argv0, d.vendor, d.product });
                    break :other;
                }
                const dd = usb.create(Desc);
                dd.iface = ip;
                dd.ep = ep;
                dd.conf = c;
                dd.data = usb.estrdup(b[0..len]);
                d.ddesc[nd] = dd;
                nd += 1;
            },
        }
        b = b[len..];
        tot += len;
    }
    return tot;
}

pub fn parseconf(d: *Usbdev, c: *Conf, b: []const u8) Error!usize {
    // DConf: wTotalLength 2, bNumInterfaces 4, bConfigurationValue 5,
    // iConfiguration 6, bmAttributes 7, MaxPower 8
    if (usb.usbdebug > 1)
        libc.fprint(2, "%s:\tparseconf %H\n", .{ libc.argv0, usb.Hex{ .b = b[0..@min(b.len, usb.Dconflen)] } });
    // DIFF: the C reads the nine bytes whatever it was given; here
    // fewer are a short descriptor (loaddevconf gives nine at least)
    if (b.len < usb.Dconflen or b[0] < usb.Dconflen) {
        libc.werrstr("short configuration descriptor", .{});
        return error.Plan9;
    }
    if (b[1] != usb.Dconf) {
        libc.werrstr("not a configuration descriptor", .{});
        return error.Plan9;
    }
    c.cval = b[5];
    c.attrib = b[7];
    c.milliamps = @as(i32, b[8]) * 2;
    const l: usize = usb.GET2(b[2..]);
    if (b.len < l) {
        libc.werrstr("truncated configuration info", .{});
        return error.Plan9;
    }
    var n = b.len - usb.Dconflen;
    var nr: usize = 0;
    if (n > 0)
        nr = try parsedesc(d, c, b[usb.Dconflen..]);
    n -= nr;
    if (n > 0 and usb.usbdebug > 1)
        libc.fprint(2, "%s:\tparseconf: %d bytes left\n", .{ libc.argv0, n });
    return l;
}
