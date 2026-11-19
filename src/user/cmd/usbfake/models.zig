//! The devices of usbfake: descriptors, and what each does when it is
//! read.  They are made for the tests, after real ones where it
//! matters (the tablet's report descriptor is QEMU's).

const std = @import("std");

pub const Kind = enum { roothub, hub, hid, disk, other };

/// What a read of an interrupt endpoint gives; or, with hold, a place
/// where the reads wait for "go".
pub const Report = struct {
    ep: u8,
    data: []const u8 = &.{},
    hold: bool = false,
};

pub const LunModel = struct {
    /// the SCSI device type
    type: u8 = 0,
    blocks: usize,
    bs: usize = 512,
    /// vendor (8), product (16), revision (4)
    inquiry: *const [28]u8,
    /// test unit ready fails this often, with this sense
    notready: u32 = 0,
    notreadyasc: u8 = 4,
    notreadyascq: u8 = 1,
    noinquiry: bool = false,
    readonly: bool = false,
    /// a block that cannot be read or written (0: none)
    badlba: usize = 0,
    /// a read that starts here has its status held until "go"
    holdlba: usize = 0,
    /// read capacity says to ask the long way
    cap16: bool = false,
};

pub const Model = struct {
    name: []const u8,
    kind: Kind = .other,
    speed: []const u8 = "full",
    ddesc: []const u8 = &.{},
    confs: []const []const u8 = &.{},
    /// by string index; the first is not used
    strs: []const ?[]const u8 = &.{},
    /// the report descriptor of each interface
    repdescs: []const []const u8 = &.{},
    hubdesc: []const u8 = &.{},
    nports: u8 = 0,
    reports: []const Report = &.{},
    luns: []const LunModel = &.{},
    /// set address fails
    badaddress: bool = false,
    /// set configuration fails
    badconf: bool = false,
    /// its port is never enabled by a reset
    dead: bool = false,
    /// no list of languages
    nolangid: bool = false,
    nomaxlun: bool = false,
    /// the first status is another command's
    badtag: bool = false,
    /// a hub: the status of this port cannot be read
    badport: u32 = 0,
};

fn ddev(ver: u16, class: u8, sub: u8, proto: u8, maxpkt: u8, vid: u16, did: u16, rel: u16, iman: u8, iprod: u8, iser: u8, nconf: u8) [18]u8 {
    return .{
        18,          1,
        @truncate(ver), @truncate(ver >> 8),
        class,       sub,
        proto,       maxpkt,
        @truncate(vid), @truncate(vid >> 8),
        @truncate(did), @truncate(did >> 8),
        @truncate(rel), @truncate(rel >> 8),
        iman,        iprod,
        iser,        nconf,
    };
}

/// A configuration descriptor in front of what it holds.
fn conf(comptime nif: u8, comptime cval: u8, comptime attr: u8, comptime power: u8, comptime body: []const u8) []const u8 {
    const total: u16 = @intCast(9 + body.len);
    const head = [9]u8{ 9, 2, @truncate(total), @truncate(total >> 8), nif, cval, 0, attr, power };
    const whole = head ++ body[0..body.len].*;
    return &whole;
}

fn iface(num: u8, alt: u8, neps: u8, class: u8, sub: u8, proto: u8) [9]u8 {
    return .{ 9, 4, num, alt, neps, class, sub, proto, 0 };
}

fn endp(addr: u8, attr: u8, maxpkt: u16, ival: u8) [7]u8 {
    return .{ 7, 5, addr, attr, @truncate(maxpkt), @truncate(maxpkt >> 8), ival };
}

/// The HID descriptor of an interface whose report descriptor has n
/// bytes.
fn hidd(n: u16) [9]u8 {
    return .{ 9, 0x21, 0x11, 0x01, 0, 1, 0x22, @truncate(n), @truncate(n >> 8) };
}

// ---- root hubs and hubs

const hub4conf = conf(1, 1, 0xE0, 50, &(iface(0, 0, 1, 9, 0, 1) ++ endp(0x81, 3, 1, 12) ++
    iface(0, 1, 1, 9, 0, 2) ++ endp(0x81, 3, 1, 12)));

// a hub of 7 ports whose descriptor is in the configuration, with
// port indicators, compound, and power switched for each port
const hub7desc = [_]u8{ 9, 0x29, 7, 0x8D, 0x00, 25, 100, 0x12, 0xFF };
const hub7conf = conf(1, 1, 0xA0, 45, &(iface(0, 0, 1, 9, 0, 0) ++ hub7desc ++ endp(0x81, 3, 2, 255)));

const hub3sconf = conf(1, 1, 0xE0, 0, &(iface(0, 0, 1, 9, 0, 0) ++ endp(0x81, 3, 2, 8)));

// ---- keyboards and mice

const kbdconf = conf(1, 1, 0xA0, 50, &(iface(0, 0, 1, 3, 1, 1) ++ hidd(63) ++ endp(0x81, 3, 8, 10)));

/// A keyboard with report numbers: 1 the keys, 2 the keys of the
/// consumer page (one of 16 bits and four that are bits), and lights.
const kbdrepdesc = [_]u8{
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, // keyboard
    0x85, 0x01, // report 1
    0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02, // the modifiers
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, // lights
    0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x26, 0xff, 0x00, 0x05, 0x07,
    0x19, 0x00, 0x2a, 0xff, 0x00, 0x81, 0x00, // six keys
    0xc0,
    0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, // consumer control
    0x85, 0x02, // report 2
    0x15, 0x00, 0x26, 0xff, 0x00, 0x19, 0x00, 0x2a, 0xff, 0x00,
    0x75, 0x10, 0x95, 0x01, 0x81, 0x00, // one key, 16 bits
    0x09, 0xe9, 0x09, 0xea, 0x09, 0xcd, 0x09, 0xb5, // louder, softer, play, next
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x04, 0x81, 0x02,
    0x75, 0x04, 0x95, 0x01, 0x81, 0x03, // padding
    0xc0,
};
const kbdrepconf = conf(1, 1, 0xA0, 50, &(iface(0, 0, 2, 3, 1, 1) ++ hidd(kbdrepdesc.len) ++
    endp(0x81, 3, 8, 10) ++ endp(0x02, 3, 8, 10)));

const mousedesc = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01,
    0x95, 0x05, 0x75, 0x01, 0x81, 0x02, // five buttons
    0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
    0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06, // x, y, wheel
    0xc0, 0xc0,
};
const mouseconf = conf(1, 1, 0xA0, 50, &(iface(0, 0, 1, 3, 1, 2) ++ hidd(mousedesc.len) ++ endp(0x81, 3, 4, 10)));

/// QEMU's usb-tablet.
const tabletdesc = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
    0x95, 0x03, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x05,
    0x81, 0x01, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00,
    0x26, 0xff, 0x7f, 0x35, 0x00, 0x46, 0xff, 0x7f, 0x75, 0x10,
    0x95, 0x02, 0x81, 0x02, 0x05, 0x01, 0x09, 0x38, 0x15, 0x81,
    0x25, 0x7f, 0x35, 0x00, 0x45, 0x00, 0x75, 0x08, 0x95, 0x01,
    0x81, 0x06, 0xc0, 0xc0,
};
const tabletconf = conf(1, 1, 0xA0, 50, &(iface(0, 0, 1, 3, 0, 0) ++ hidd(tabletdesc.len) ++ endp(0x81, 3, 8, 4)));

/// A touch screen of two fingers, report 4: for each finger the tip,
/// in range, a number, and where it is; then how many there are.
fn finger() [50]u8 {
    return .{
        0x09, 0x22, 0xa1, 0x02, // finger
        0x09, 0x42, 0x09, 0x32, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x02, 0x81, 0x02, // tip, in range
        0x95, 0x06, 0x81, 0x03, // padding
        0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x09, 0x51, 0x81, 0x02, // contact identifier
        0xa4, // push
        0x05, 0x01, 0x26, 0xff, 0x0f, 0x75, 0x10, // desktop, to 4095, 16 bits
        0x09, 0x30, 0x81, 0x02, // x
        0x09, 0x31, 0x81, 0x02, // y
        0xb4, // pop
        0xc0,
    };
}
const touchdesc = [_]u8{ 0x05, 0x0d, 0x09, 0x04, 0xa1, 0x01, 0x85, 0x04 } ++ finger() ++ finger() ++
    [_]u8{ 0x09, 0x54, 0x25, 0x02, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0xc0 };
const touchconf = conf(1, 1, 0xA0, 50, &(iface(0, 0, 1, 3, 0, 0) ++ hidd(touchdesc.len) ++ endp(0x81, 3, 16, 4)));

/// The second interface of the two-in-one: a pointer whose report
/// descriptor has items of every form: a long item, 32-bit items,
/// delimiters, a relative axis with a signed physical range over an
/// unsigned logical one, a range of usages, and a vendor's page.
const odddesc = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01,
    0xfe, 0x03, 0x99, 0x01, 0x02, 0x03, // a long item of three bytes
    0x09, 0x01, 0xa1, 0x00,
    0x05, 0x09, 0x1b, 0x01, 0x00, 0x09, 0x00, 0x2b, 0x03, 0x00, 0x09, 0x00, // buttons 1 to 3, in 32 bits
    0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x05, 0x81, 0x01,
    0x05, 0x01,
    // after the item the C has for a delimiter the usages are not
    // taken: a byte that is nothing
    0x99, 0x01, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0x17, 0x00, 0x00, 0x00, 0x00, 0x27, 0xff, 0x00, 0x00, 0x00, // logical 0 to 255, 32 bits
    0x35, 0x81, 0x45, 0x7f, // physical -127 to 127
    0x75, 0x08, 0x95, 0x02, 0x09, 0x30, 0x09, 0x31, 0x81, 0x06, // x, y relative
    0x06, 0x00, 0xff, 0x09, 0x01, 0x15, 0x80, 0x25, 0x7f, 0x35, 0x00, 0x45, 0x00,
    0x75, 0x08, 0x95, 0x01, 0x81, 0x02, // a vendor's byte
    0x05, 0x01, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x81, 0x06, // wheel
    0xc0, 0xc0,
};
const comboconf = conf(2, 1, 0xA0, 50, &(iface(0, 0, 1, 3, 1, 1) ++ hidd(63) ++ endp(0x81, 3, 8, 10) ++
    iface(1, 0, 1, 3, 0, 0) ++ hidd(odddesc.len) ++ endp(0x82, 3, 8, 10)));

/// An interface of the class with nothing nusb/kb reads.
const nothidconf = conf(1, 1, 0x80, 50, &(iface(0, 0, 1, 3, 0, 5) ++ hidd(tabletdesc.len) ++ endp(0x01, 3, 8, 10)));

/// The Elecom trackball's descriptor as far as the quirk looks: a
/// count at 13 and 21, and a size at 31.
const elecomdesc = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00,
    0x85, 0x01, 0x95, 0x05, 0x75, 0x01, 0x05, 0x09, 0x19, 0x01,
    0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x81, 0x02, 0x95, 0x01,
    0x75, 0x03, 0x81, 0x01, 0x75, 0x10, 0x95, 0x02, 0x05, 0x01,
    0x09, 0x30, 0x09, 0x31, 0x16, 0x00, 0x80, 0x26, 0xff, 0x7f,
    0x81, 0x06, 0xc0, 0xc0,
};
const elecomconf = conf(1, 1, 0xA0, 50, &(iface(0, 0, 1, 3, 1, 2) ++ hidd(elecomdesc.len) ++ endp(0x81, 3, 8, 10)));

const kbdreports = [_]Report{
    .{ .ep = 1, .data = &.{ 0, 0, 0x04, 0, 0, 0, 0, 0 } }, // a
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .ep = 1, .data = &.{ 0x02, 0, 0, 0, 0, 0, 0, 0 } }, // shift
    .{ .ep = 1, .data = &.{ 0x02, 0, 0x04, 0, 0, 0, 0, 0 } }, // and a
    .{ .ep = 1, .data = &.{ 0x02, 0, 0x04, 0x05, 0, 0, 0, 0 } }, // and b
    .{ .ep = 1, .data = &.{ 0x02, 0, 0x05, 0, 0, 0, 0, 0 } }, // a up
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .ep = 1, .data = &.{ 0, 0, 0x4f, 0x50, 0x52, 0x51, 0x4a, 0x4d } }, // arrows, home, end
    .{ .ep = 1, .data = &.{ 0, 0, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 } }, // too many keys
    .{ .ep = 1, .data = &.{ 0x55, 0, 0, 0, 0, 0, 0, 0 } }, // four modifiers
    .{ .ep = 1, .data = &.{ 0xaa, 0, 0x28, 0, 0, 0, 0, 0 } }, // the other four, and enter
    .{ .ep = 1, .data = &.{ 0, 0, 0x28, 0x66, 0x65, 0x46, 0x48, 0x7f } }, // power, menu, print, pause, mute
    .{ .ep = 1, .data = &.{ 0, 0, 0xdd, 0xfe, 0, 0, 0, 0 } }, // codes with no key
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0 } }, // a short report
    .{ .ep = 1, .data = &.{ 0, 0, 0x1d, 0, 0, 0, 0, 0 } }, // z
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
};

const holdreports = [_]Report{
    .{ .ep = 1, .data = &.{ 0, 0, 0x0b, 0, 0, 0, 0, 0 } }, // h, held
    .{ .ep = 1, .hold = true },
    .{ .ep = 1, .data = &.{ 0, 0, 0x0b, 0x4f, 0, 0, 0, 0 } }, // and the right arrow
    .{ .ep = 1, .hold = true },
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
};

const kbdrepreports = [_]Report{
    .{ .ep = 1, .data = &.{ 1, 0, 0x04, 0, 0, 0, 0, 0 } }, // a
    .{ .ep = 1, .data = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .ep = 1, .data = &.{ 2, 0xe9, 0x00, 0x00 } }, // louder, as a key
    .{ .ep = 1, .data = &.{ 2, 0, 0, 0 } },
    .{ .ep = 1, .data = &.{ 2, 0, 0, 0x06 } }, // softer and play, as bits
    .{ .ep = 1, .data = &.{ 2, 0xb6, 0, 0x08 } }, // previous as a key, next as a bit
    .{ .ep = 1, .data = &.{ 2, 0, 0, 0 } },
    .{ .ep = 1, .data = &.{ 3, 0xff, 0xff, 0xff } }, // a report there is not
    .{ .ep = 1, .data = &.{ 1, 0x01, 0x2c, 0, 0, 0, 0, 0 } }, // control and space
    .{ .ep = 1, .data = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
};

const mousereports = [_]Report{
    .{ .ep = 1, .data = &.{ 0, 5, 0xfd, 0 } }, // right 5, up 3
    .{ .ep = 1, .data = &.{ 1, 0, 0, 0 } }, // left button
    .{ .ep = 1, .data = &.{ 1, 0x7f, 0x81, 0 } }, // dragged far
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0 } },
    .{ .ep = 1, .data = &.{ 2, 0, 0, 0 } }, // right button
    .{ .ep = 1, .data = &.{ 4, 0, 0, 0 } }, // middle
    .{ .ep = 1, .data = &.{ 0x18, 0, 0, 0 } }, // the fourth and fifth
    .{ .ep = 1, .data = &.{ 0, 0, 0, 1 } }, // the wheel
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0xff } },
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0 } }, // nothing new
    .{ .ep = 1, .data = &.{ 7, 1, 1, 0x80 } }, // a wheel out of range
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0 } },
};

const tabletreports = [_]Report{
    .{ .ep = 1, .data = &.{ 0, 0x00, 0x40, 0x00, 0x20, 0 } }, // the middle, a quarter down
    .{ .ep = 1, .data = &.{ 0, 0x00, 0x40, 0x00, 0x20, 0 } }, // the same: nothing
    .{ .ep = 1, .data = &.{ 1, 0x00, 0x40, 0x00, 0x20, 0 } }, // a button
    .{ .ep = 1, .data = &.{ 1, 0x00, 0x00, 0x00, 0x00, 0 } }, // the corner
    .{ .ep = 1, .data = &.{ 0, 0xff, 0x7f, 0xff, 0x7f, 0 } }, // the far corner
    .{ .ep = 1, .data = &.{ 0, 0xff, 0x7f, 0xff, 0x7f, 1 } }, // the wheel
    .{ .ep = 1, .data = &.{ 0, 0xff, 0x7f, 0xff, 0x7f, 0xff } },
    .{ .ep = 1, .data = &.{ 4, 0x01, 0x00, 0xfe, 0x7f, 0 } },
    .{ .ep = 1, .data = &.{ 0, 0x00, 0x80, 0x00, 0x80, 0 } }, // past the range: not taken
    .{ .ep = 1, .data = &.{ 0, 0x34, 0x12, 0x78, 0x56, 0 } },
};

const touchreports = [_]Report{
    // one finger down
    .{ .ep = 1, .data = &.{ 4, 0x03, 7, 0x00, 0x08, 0x00, 0x04, 0x00, 0, 0, 0, 0, 0, 1 } },
    .{ .ep = 1, .data = &.{ 4, 0x03, 7, 0x10, 0x08, 0x10, 0x04, 0x00, 0, 0, 0, 0, 0, 1 } },
    // and a second
    .{ .ep = 1, .data = &.{ 4, 0x03, 7, 0x10, 0x08, 0x10, 0x04, 0x03, 9, 0xff, 0x0f, 0x00, 0x00, 2 } },
    .{ .ep = 1, .data = &.{ 4, 0x03, 7, 0x20, 0x08, 0x20, 0x04, 0x03, 9, 0xf0, 0x0f, 0x10, 0x00, 2 } },
    // the first lifted, in range
    .{ .ep = 1, .data = &.{ 4, 0x02, 7, 0x20, 0x08, 0x20, 0x04, 0x03, 9, 0xf0, 0x0f, 0x10, 0x00, 1 } },
    // and gone
    .{ .ep = 1, .data = &.{ 4, 0x00, 7, 0x20, 0x08, 0x20, 0x04, 0x03, 9, 0xe0, 0x0f, 0x20, 0x00, 1 } },
    .{ .ep = 1, .data = &.{ 4, 0x00, 0, 0, 0, 0, 0, 0x00, 0, 0, 0, 0, 0, 0 } },
    // another report number
    .{ .ep = 1, .data = &.{ 5, 0x03, 7, 0x20, 0x08, 0x20, 0x04, 0x03, 9, 0xe0, 0x0f, 0x20, 0x00, 1 } },
};

const comboreports = [_]Report{
    .{ .ep = 1, .data = &.{ 0, 0, 0x06, 0, 0, 0, 0, 0 } }, // c
    .{ .ep = 1, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .ep = 2, .data = &.{ 0x01, 0x05, 0x80, 0x7f, 0x11, 0x00 } }, // x 128 (as 1), y 127 (as 0)
    .{ .ep = 2, .data = &.{ 0x00, 0x00, 0xff, 0x00, 0x22, 0x00 } },
    .{ .ep = 2, .data = &.{ 0x02, 0xfb, 0x7f, 0x7f, 0x33, 0x01 } },
    .{ .ep = 2, .data = &.{ 0x05, 0x00, 0x00, 0xff, 0x44, 0xff } },
    .{ .ep = 2, .data = &.{ 0x00, 0x00, 0x7f, 0x7f, 0x00, 0x00 } },
};

const elecomreports = [_]Report{
    .{ .ep = 1, .data = &.{ 1, 0x81, 0x05, 0x00, 0xfb, 0xff } }, // the first and eighth buttons
    .{ .ep = 1, .data = &.{ 1, 0x00, 0x00, 0x00, 0x00, 0x00 } },
    .{ .ep = 1, .data = &.{ 1, 0x24, 0xff, 0x7f, 0x00, 0x80 } },
    .{ .ep = 1, .data = &.{ 1, 0x00, 0x00, 0x00, 0x00, 0x00 } },
};

// ---- disks

fn diskconf(comptime proto: u8) []const u8 {
    return conf(1, 1, 0x80, 250, &(iface(0, 0, 2, 8, 6, proto) ++ endp(0x81, 2, 512, 0) ++ endp(0x02, 2, 512, 0)));
}

// its first setting has no endpoints; the second is USB-attached SCSI
const uasconf = conf(1, 1, 0x80, 250, &(iface(0, 0, 0, 8, 6, 0x50) ++
    iface(0, 1, 2, 8, 6, 0x62) ++ endp(0x83, 2, 512, 0) ++ endp(0x04, 2, 512, 0)));

const notdiskconf = conf(1, 1, 0x80, 250, &(iface(0, 0, 2, 8, 6, 0x50) ++ endp(0x81, 3, 64, 1) ++ endp(0x02, 3, 64, 1)));

// one endpoint both ways cannot be: an address has one direction.
// Two interfaces of the class, the first with one endpoint only.
const halfconf = conf(2, 1, 0x80, 250, &(iface(0, 0, 1, 8, 6, 0x50) ++ endp(0x81, 2, 512, 0) ++
    iface(1, 0, 3, 8, 6, 0x50) ++ endp(0x85, 3, 8, 9) ++ endp(0x06, 2, 64, 0) ++ endp(0x87, 2, 64, 0)));

// ---- descriptors of every sort, for the library

// two configurations.  The first: an interface with two settings
// (the second isochronous, three transactions a microframe), one
// whose in and out endpoints have the same number and are one, class
// descriptors between them, a device descriptor where none belongs,
// and an endpoint before any interface.
const multiconf1 = conf(2, 1, 0xC0, 1, &(endp(0x8f, 2, 64, 0) ++
    iface(0, 0, 2, 0xff, 1, 2) ++ [_]u8{ 5, 0x24, 0, 0x10, 0x01 } ++ endp(0x81, 3, 16, 7) ++
    [_]u8{ 3, 0x25, 0x99 } ++ endp(0x02, 2, 64, 0) ++
    iface(0, 1, 3, 0xff, 1, 2) ++ endp(0x81, 1, 0x1400 | 1023, 1) ++ endp(0x02, 1, 0x0800 | 512, 1) ++ endp(0x83, 1, 3, 4) ++
    [_]u8{ 18, 1, 0, 2, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } ++
    iface(1, 0, 2, 2, 2, 1) ++ [_]u8{ 4, 0x24, 6, 0 } ++ endp(0x04, 2, 512, 0) ++ endp(0x84, 2, 512, 0) ++
    [_]u8{ 2, 0x30 }));
const multiconf2 = conf(1, 2, 0x80, 250, &(iface(0, 0, 1, 7, 1, 2) ++ endp(0x01, 2, 64, 0)));

// the same endpoint number in two interfaces, of two types: the
// second gets a number of its own
const clashconf = conf(2, 1, 0x80, 50, &(iface(0, 0, 2, 0xff, 0, 0) ++ endp(0x81, 3, 8, 10) ++ endp(0x02, 2, 64, 0) ++
    iface(1, 0, 3, 0xff, 0, 0) ++ endp(0x81, 2, 64, 0) ++ endp(0x82, 2, 64, 0) ++ endp(0x02, 1, 64, 1)));

const plainconf = conf(1, 1, 0x80, 50, &(iface(0, 0, 1, 0xff, 0, 0) ++ endp(0x81, 2, 64, 0)));

// says it is longer than what comes
const truncconf = [_]u8{ 9, 2, 0x00, 0x02, 1, 1, 0, 0x80, 50 } ++ iface(0, 0, 1, 0xff, 0, 0) ++ endp(0x81, 2, 64, 0);

// interface 16
const badifaceconf = conf(1, 1, 0x80, 50, &(iface(16, 0, 1, 0xff, 0, 0) ++ endp(0x81, 2, 64, 0)));

// a descriptor that ends early, and one of no length
const raggedconf = conf(1, 1, 0x80, 50, &(iface(0, 0, 1, 0xff, 0, 0) ++ endp(0x81, 2, 64, 0) ++ [_]u8{ 0, 5, 1, 2 }));
const shortepconf = conf(1, 1, 0x80, 50, &(iface(0, 0, 1, 0xff, 0, 0) ++ [_]u8{ 5, 5, 0x81, 2, 64 }));

const acme = [_]?[]const u8{ null, "ACME", "Thing", "0001" };

pub const all = [_]Model{
    .{ .name = "root2", .kind = .roothub, .speed = "high", .nports = 4 },
    .{ .name = "root3", .kind = .roothub, .speed = "super", .nports = 2 },
    .{
        .name = "hub4",
        .kind = .hub,
        .speed = "high",
        .ddesc = &ddev(0x0200, 9, 0, 2, 64, 0x05e3, 0x0608, 0x8537, 0, 1, 0, 1),
        .confs = &.{hub4conf},
        .strs = &.{ null, "USB2.0 Hub" },
        .hubdesc = &.{ 9, 0x29, 4, 0x29, 0x00, 50, 100, 0x00, 0xFF },
        .nports = 4,
    },
    .{
        .name = "hub7",
        .kind = .hub,
        .speed = "full",
        .ddesc = &ddev(0x0110, 9, 0, 0, 8, 0x0451, 0x2077, 0x0100, 1, 2, 3, 1),
        .confs = &.{hub7conf},
        .strs = &.{ null, "TI", "Hub of 7", "H7" },
        .nports = 7,
    },
    .{
        .name = "hub3s",
        .kind = .hub,
        .speed = "super",
        .ddesc = &ddev(0x0300, 9, 0, 3, 9, 0x2109, 0x0813, 0x9011, 1, 2, 0, 1),
        .confs = &.{hub3sconf},
        .strs = &.{ null, "VIA", "USB3.0 Hub" },
        .hubdesc = &.{ 12, 0x2A, 2, 0x09, 0x00, 10, 0, 4, 0xd0, 0x02, 0x04, 0x00 },
        .nports = 2,
    },
    .{
        .name = "badhub",
        .kind = .hub,
        .speed = "full",
        .ddesc = &ddev(0x0110, 9, 0, 0, 8, 0x0451, 0x2078, 0x0100, 0, 0, 0, 1),
        .confs = &.{hub3sconf},
        .hubdesc = &.{ 9, 0x29, 2, 0x09, 0x00, 1, 0, 0x00, 0xFF },
        .nports = 2,
        .badport = 2,
    },
    .{
        .name = "tinyhub",
        .kind = .hub,
        .speed = "full",
        .ddesc = &ddev(0x0110, 9, 0, 0, 8, 0x0451, 0x2079, 0x0100, 0, 0, 0, 1),
        .confs = &.{hub3sconf},
        .hubdesc = &.{ 7, 0x29, 2, 0x09, 0x00, 1, 0 },
        .nports = 2,
    },
    .{
        .name = "kbd",
        .kind = .hid,
        .speed = "low",
        .ddesc = &ddev(0x0110, 0, 0, 0, 8, 0x046d, 0xc31c, 0x6401, 1, 2, 0, 1),
        .confs = &.{kbdconf},
        .strs = &.{ null, "Logitech", "USB Keyboard" },
        .repdescs = &.{&.{}},
        .reports = &kbdreports,
    },
    .{
        .name = "kbdrep",
        .kind = .hid,
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0x04d9, 0x1603, 0x0110, 0, 2, 0, 1),
        .confs = &.{kbdrepconf},
        .strs = &.{ null, null, "Keyboard with reports" },
        .repdescs = &.{&kbdrepdesc},
        .reports = &kbdrepreports,
    },
    .{
        .name = "mouse",
        .kind = .hid,
        .speed = "low",
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0x046d, 0xc077, 0x7200, 1, 2, 0, 1),
        .confs = &.{mouseconf},
        .strs = &.{ null, "Logitech", "USB Optical Mouse" },
        .repdescs = &.{&mousedesc},
        .reports = &mousereports,
    },
    .{
        .name = "tablet",
        .kind = .hid,
        .speed = "high",
        .ddesc = &ddev(0x0200, 0, 0, 0, 64, 0x0627, 0x0001, 0x0000, 1, 2, 10, 1),
        .confs = &.{tabletconf},
        .strs = &.{ null, "QEMU", "QEMU USB Tablet", null, null, null, null, null, null, null, "28754-0000:00:02.0-1" },
        .repdescs = &.{&tabletdesc},
        .reports = &tabletreports,
    },
    .{
        .name = "touch",
        .kind = .hid,
        .ddesc = &ddev(0x0200, 0, 0, 0, 16, 0x0eef, 0x0005, 0x0200, 1, 2, 0, 1),
        .confs = &.{touchconf},
        .strs = &.{ null, "eGalax", "Touch" },
        .repdescs = &.{&touchdesc},
        .reports = &touchreports,
    },
    .{
        .name = "combo",
        .kind = .hid,
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0x1234, 0x5678, 0x0001, 1, 2, 3, 1),
        .confs = &.{comboconf},
        .strs = &.{ null, "Two", "in one", "S~00e9rie 1" },
        .repdescs = &.{ &.{}, &odddesc },
        .reports = &comboreports,
    },
    .{
        .name = "kbdhold",
        .kind = .hid,
        .speed = "low",
        .ddesc = &ddev(0x0110, 0, 0, 0, 8, 0x046d, 0xc31d, 0x6401, 1, 2, 0, 1),
        .confs = &.{kbdconf},
        .strs = &.{ null, "Logitech", "USB Keyboard" },
        .repdescs = &.{&.{}},
        .reports = &holdreports,
    },
    .{
        .name = "nothid",
        .kind = .hid,
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0x1234, 0x0003, 0x0001, 0, 0, 0, 1),
        .confs = &.{nothidconf},
        .repdescs = &.{&tabletdesc},
    },
    .{
        .name = "gaomon",
        .kind = .hid,
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0x256c, 0x006d, 0x0001, 1, 2, 0, 1),
        .confs = &.{tabletconf},
        .strs = &.{ null, "GAOMON", "S620" },
        .repdescs = &.{&tabletdesc},
        .reports = &.{
            .{ .ep = 1, .data = &.{ 8, 0x81, 0x00, 0x40, 0x00, 0x28, 0x00, 0x80 } },
            .{ .ep = 1, .data = &.{ 8, 0x82, 0x10, 0x40, 0x10, 0x28, 0x00, 0x00 } },
            .{ .ep = 1, .data = &.{ 8, 0x04, 0x10, 0x40, 0x10, 0x28, 0x00, 0x00 } },
            .{ .ep = 1, .data = &.{ 8, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
        },
    },
    .{
        .name = "elecom",
        .kind = .hid,
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0x056e, 0x010c, 0x0001, 1, 2, 0, 1),
        .confs = &.{elecomconf},
        .strs = &.{ null, "ELECOM", "HUGE TrackBall" },
        .repdescs = &.{&elecomdesc},
        .reports = &elecomreports,
    },

    .{
        .name = "disk3",
        .kind = .disk,
        .speed = "high",
        .ddesc = &ddev(0x0200, 0, 0, 0, 64, 0x0781, 0x5567, 0x0100, 1, 2, 3, 1),
        .confs = &.{diskconf(0x50)},
        .strs = &.{ null, "SanDisk", "Cruzer", "4C530001" },
        .luns = &.{
            .{ .blocks = 2048, .inquiry = "FAKE    Disk of 1M      1.00", .notready = 2, .badlba = 300, .holdlba = 400 },
            .{ .type = 5, .blocks = 64, .bs = 2048, .inquiry = "FAKE    Read only       2.0 ", .readonly = true },
            .{ .type = 3, .blocks = 8, .inquiry = "FAKE    Not a disk      0   " },
        },
    },
    .{
        .name = "disk1",
        .kind = .disk,
        .speed = "high",
        .ddesc = &ddev(0x0210, 0, 0, 0, 64, 0x174c, 0x55aa, 0x0100, 0, 2, 3, 1),
        .confs = &.{diskconf(0x50)},
        .strs = &.{ null, null, "Big blocks", "0123456789ABCDEF0123" },
        .luns = &.{.{ .blocks = 256, .bs = 4096, .inquiry = "FAKE    4K blocks       9.99", .cap16 = true }},
        .nomaxlun = true,
        .badtag = true,
    },
    .{
        .name = "uas",
        .kind = .disk,
        .speed = "high",
        .ddesc = &ddev(0x0200, 0, 0, 0, 64, 0x152d, 0x0578, 0x0100, 1, 2, 3, 1),
        .confs = &.{uasconf},
        .strs = &.{ null, "JMicron", "UAS", "DB98765" },
        .luns = &.{.{ .blocks = 100, .inquiry = "FAKE    Other setting   1   " }},
    },
    .{
        .name = "notdisk",
        .kind = .disk,
        .ddesc = &ddev(0x0200, 0, 0, 0, 64, 0x1111, 0x0001, 0x0100, 0, 0, 0, 1),
        .confs = &.{notdiskconf},
        .luns = &.{.{ .blocks = 100, .inquiry = "FAKE    No endpoints    1   " }},
    },
    .{
        .name = "deadlun",
        .kind = .disk,
        .ddesc = &ddev(0x0200, 0, 0, 0, 64, 0x1111, 0x0002, 0x0100, 0, 0, 0, 1),
        .confs = &.{diskconf(0x50)},
        .luns = &.{
            .{ .blocks = 100, .inquiry = "FAKE    No inquiry      1   ", .noinquiry = true },
            .{ .blocks = 100, .inquiry = "FAKE    No inquiry      2   ", .noinquiry = true },
        },
    },
    .{
        .name = "empty",
        .kind = .disk,
        .ddesc = &ddev(0x0200, 0, 0, 0, 64, 0x1111, 0x0003, 0x0100, 1, 2, 0, 1),
        .confs = &.{halfconf},
        .strs = &.{ null, "Reader", "of cards" },
        .luns = &.{.{ .blocks = 100, .inquiry = "FAKE    Card reader     1   ", .notready = 1000000, .notreadyasc = 0x3A, .notreadyascq = 0 }},
    },

    .{
        .name = "multi",
        .ddesc = &ddev(0x0200, 0xef, 2, 1, 64, 0xabcd, 0x0001, 0x1234, 1, 2, 3, 2),
        .confs = &.{ multiconf1, multiconf2 },
        .strs = &.{ null, "Many", "Configurations", "X1" },
    },
    .{
        .name = "clash",
        .ddesc = &ddev(0x0200, 0xff, 0, 0, 8, 0xabcd, 0x0002, 0x0001, 0, 0, 0, 1),
        .confs = &.{clashconf},
    },
    .{
        .name = "short17",
        .ddesc = ddev(0x0110, 0xff, 0, 0, 8, 0xabcd, 0x0003, 0x0001, 1, 2, 0, 1)[0..17],
        .confs = &.{plainconf},
        .strs = &.{ null, "Seventeen", "bytes" },
    },
    .{
        .name = "short16",
        .ddesc = ddev(0x0110, 0xff, 0, 0, 8, 0xabcd, 0x0004, 0x0001, 1, 2, 0, 1)[0..16],
        .confs = &.{plainconf},
    },
    .{
        .name = "notdev",
        .ddesc = &.{ 18, 2, 0x10, 0x01, 0xff, 0, 0, 8, 0xcd, 0xab, 5, 0, 1, 0, 0, 0, 0, 1 },
        .confs = &.{plainconf},
    },
    .{
        .name = "smalldev",
        .ddesc = &.{ 12, 1, 0x10, 0x01, 0xff, 0, 0, 8, 0xcd, 0xab, 6, 0, 1, 0, 0, 0, 0, 1 },
        .confs = &.{plainconf},
    },
    .{
        .name = "trunc",
        .ddesc = &ddev(0x0200, 0xff, 0, 0, 8, 0xabcd, 0x0007, 0x0001, 0, 0, 0, 1),
        .confs = &.{&truncconf},
    },
    .{
        .name = "strings",
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0xabcd, 0x0008, 0x0001, 1, 2, 3, 1),
        .confs = &.{plainconf},
        .strs = &.{ null, "Caf~00e9 ~65e5~672c", "~20ac and a longer name, to see where a long one ends: 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789", "" },
        .nolangid = true,
    },
    .{
        .name = "usb3",
        .speed = "super",
        .ddesc = &ddev(0x0310, 0, 0, 0, 9, 0xabcd, 0x0009, 0x0001, 0, 2, 0, 1),
        .confs = &.{plainconf},
        .strs = &.{ null, null, "No vendor" },
    },
    .{
        .name = "badiface",
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0xabcd, 0x000a, 0x0001, 0, 0, 0, 1),
        .confs = &.{badifaceconf},
    },
    .{
        .name = "ragged",
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0xabcd, 0x000b, 0x0001, 0, 0, 0, 1),
        .confs = &.{raggedconf},
    },
    .{
        .name = "shortep",
        .ddesc = &ddev(0x0200, 0, 0, 0, 8, 0xabcd, 0x000c, 0x0001, 0, 0, 0, 1),
        .confs = &.{shortepconf},
    },
    .{
        .name = "noconf",
        .ddesc = &ddev(0x0200, 0xff, 0, 0, 8, 0xabcd, 0x000d, 0x0001, 0, 0, 0, 0),
    },
    .{
        .name = "manyconf",
        .ddesc = &ddev(0x0200, 0xff, 0, 0, 8, 0xabcd, 0x000e, 0x0001, 0, 0, 0, 3),
        .confs = &.{plainconf},
    },

    // for the hub scene alone
    .{
        .name = "badaddr",
        .ddesc = &ddev(0x0200, 0xff, 0, 0, 8, 0xdead, 0x0001, 0x0001, 0, 0, 0, 1),
        .confs = &.{plainconf},
        .badaddress = true,
    },
    .{
        .name = "dead",
        .ddesc = &ddev(0x0200, 0xff, 0, 0, 8, 0xdead, 0x0002, 0x0001, 0, 0, 0, 1),
        .confs = &.{plainconf},
        .dead = true,
    },
    .{
        .name = "badconf",
        .ddesc = &ddev(0x0200, 0xff, 0, 0, 8, 0xdead, 0x0003, 0x0001, 0, 0, 0, 1),
        .confs = &.{plainconf},
        .badconf = true,
    },
    .{
        .name = "sdisk",
        .kind = .disk,
        .speed = "super",
        .ddesc = &ddev(0x0300, 0, 0, 0, 9, 0x0781, 0x5581, 0x0100, 1, 2, 3, 1),
        .confs = &.{diskconf(0x50)},
        .strs = &.{ null, "SanDisk", "Ultra", "4C530002" },
        .luns = &.{.{ .blocks = 64, .inquiry = "FAKE    Fast            1   " }},
    },
};

pub fn find(name: []const u8) ?*const Model {
    for (&all) |*m| {
        if (std.mem.eql(u8, m.name, name))
            return m;
    }
    return null;
}

pub const hidscene = &[_][]const u8{ "kbd", "kbdrep", "mouse", "tablet", "touch", "combo", "kbdhold", "nothid", "gaomon", "elecom" };
pub const diskscene = &[_][]const u8{ "disk3", "disk1", "uas", "notdisk", "deadlun", "empty" };
pub const descscene = &[_][]const u8{ "multi", "clash", "short17", "short16", "notdev", "smalldev", "trunc", "strings", "usb3", "badiface", "ragged", "shortep", "noconf", "manyconf", "kbdrep", "disk3", "hub7" };
