//! from nusb/lib/dump.c
//!
//! Fixed from C, read and not shown: fmtprintiface tests an
//! endpoint's direction and type with <= nelem before it indexes the
//! names, one past the end (the parser gives neither value).

const std = @import("std");
const libc = @import("libc");
const usb = @import("usb.zig");

const Dev = usb.Dev;
const Usbdev = usb.Usbdev;
const Iface = usb.Iface;
const Fmt = libc.fmt.Fmt;

const edir = [_][]const u8{ "in", "out", "inout" };
const etype = [_][]const u8{ "ctl", "iso", "bulk", "intr" };
const cnames = [_]?[]const u8{
    "none", // 0x00
    "audio", // 0x01
    "comms", // 0x02
    "hid", // 0x03
    null,
    "phys", // 0x05
    "image", // 0x06
    "printer", // 0x07
    "storage", // 0x08
    "hub", // 0x09
    "data", // 0x0A
    "smartcard", // 0x0B
    null,
    "drm", // 0x0D
    "video", // 0x0E
    "healthcare", // 0x0F
    "av", // 0x10
    "billboard", // 0x11
    "usbc", // 0x12
    "display", // 0x13
    "mctp", // 0x14
};

/// The name of a class; one without a name is its number, in buf.
pub fn classname(c: u32, buf: *[12]u8) []const u8 {
    if (c < cnames.len) {
        if (cnames[c]) |s|
            return s;
    }
    switch (c) {
        0x3C => return "i3c", // I3C Device Class
        0xDC => return "debug", // Diagnostic Device
        0xE0 => return "wireless", // Wireless Controller
        0xEF => return "misc", // Miscellaneous
        0xFE => return "application", // Application specific
        0xFF => return "vendor", // Vendor specific
        else => return libc.sprint(buf[0..11], "%d", .{c}),
    }
}

fn fmtprintiface(f: *Fmt, i: *Iface) void {
    var cb: [12]u8 = undefined;

    f.print("\t\tiface csp %s.%ud.%ud alt %d\n", .{ classname(usb.Class(i.csp), &cb), usb.Subclass(i.csp), usb.Proto(i.csp), i.alt });
    for (i.ep) |slot| {
        const ep = slot orelse break;
        var eds: []const u8 = "";
        var ets: []const u8 = "";
        if (ep.dir < edir.len)
            eds = edir[ep.dir];
        if (ep.type < etype.len)
            ets = etype[ep.type];
        f.print("\t\t  ep id %d addr %d dir %s type %s" ++
            "  attrib %x maxpkt %d ntds %d pollival %d\n", .{
            ep.id,     ep.id & usb.Epmax, eds,     ets, ep.attrib,
            ep.maxpkt, ep.ntds,           ep.pollival,
        });
    }
}

fn fmtprintconf(f: *Fmt, d: *Usbdev, ci: usize) void {
    const c = d.conf[ci].?;
    f.print("\tconf: cval %d attrib %x %d mA\n", .{ c.cval, c.attrib, c.milliamps });
    for (c.iface) |first| {
        var fc = first;
        while (fc) |p| : (fc = p.next)
            fmtprintiface(f, p);
    }
    for (d.ddesc) |slot| {
        const dd = slot orelse break;
        // a descriptor of one byte has no type: 0 (the C prints the
        // byte after it in its block)
        if (dd.conf == c)
            f.print("\t\tdev desc %x[%d]: %H\n", .{ if (dd.data.len > 1) dd.data[1] else 0, dd.data[0], usb.Hex{ .b = dd.data } });
    }
}

/// The C's %U: a device and what was read of its descriptors.
pub const U = struct {
    d: ?*Dev,

    pub fn fmt9(self: U, f: *Fmt) void {
        var cb: [12]u8 = undefined;

        const d = self.d orelse {
            f.print("<nildev>\n", .{});
            return;
        };
        f.print("%s", .{d.dir});
        const ud = d.usb orelse {
            f.print(" %d refs\n", .{d.ref.ref});
            return;
        };
        f.print(" csp %s.%ud.%ud", .{ classname(usb.Class(ud.csp), &cb), usb.Subclass(ud.csp), usb.Proto(ud.csp) });
        f.print(" vid %#ux did %#ux", .{ ud.vid, ud.did });
        f.print(" refs %d\n", .{d.ref.ref});
        f.print("\t%s %s %s\n", .{ ud.vendor, ud.product, ud.serial });
        for (ud.conf, 0..) |c, i| {
            if (c == null)
                break;
            fmtprintconf(f, ud, i);
        }
    }
};

pub fn estrdup(s: []const u8) []u8 {
    return libc.allocator.dupe(u8, s) catch libc.sysfatal("strdup: %r", .{});
}

pub fn emallocz(size: usize, zero: bool) []u8 {
    const x = libc.allocator.alloc(u8, size) catch libc.sysfatal("malloc: %r", .{});
    if (zero)
        @memset(x, 0);
    return x;
}

/// A T as its declaration starts it (emallocz(sizeof(T), 1) in C).
pub fn create(comptime T: type) *T {
    const x = libc.allocator.create(T) catch libc.sysfatal("malloc: %r", .{});
    x.* = .{};
    return x;
}
