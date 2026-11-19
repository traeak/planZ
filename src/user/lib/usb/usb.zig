//! The library of the USB programs (usbd and the device drivers that
//! run in user space on the kernel's #u): a device's endpoint
//! directories opened, control requests, and the descriptors read and
//! taken apart.  usb.h, and the library's functions under their C
//! names.
//! from 9front 11952's /sys/src/cmd/nusb/lib, one file per C file in
//! this directory
//!
//! DIFF (all files):
//!   - Strings are slices.  A function that returns -1 with the error
//!     string set in C returns libc.Error here; one that returns nil,
//!     null (the error string is set as in C).
//!   - usbcmd returns the count as the C does, which is 0 for a
//!     request with no data and may be 0 for one whose reply never
//!     came ("no data from device", after the tries).
//!   - A Desc's data is the descriptor's bytes as a slice (the C has a
//!     DDesc with the bytes after it): data[0] is bLength, data[1]
//!     bDescriptorType.
//!   - The descriptors' layouts (DDev, DConf, DIface, DEp) are byte
//!     offsets where they are read, not structures laid over the
//!     buffer.
//!   - %U and %H are the types U and Hex, which format themselves.
//!   - classname is given the buffer for a class it has no name for.
//!   - No malloc tags.

const std = @import("std");
const libc = @import("libc");
const thread = @import("thread");

const dev_ = @import("dev.zig");
const dump_ = @import("dump.zig");
const parse_ = @import("parse.zig");

pub const Ref = thread.Ref;
pub const incref = thread.incref;
pub const decref = thread.decref;

// tunable parameters
pub const Nep = 64; // max. endpoints per interface
pub const Nconf = 16; // max. configurations per usb device
pub const Nddesc = 8 * Nep; // max. device-specific descriptors per usb device
pub const Niface = 16; // max. interfaces per configuration
pub const Uctries = 4; // no. of tries for usbcmd
pub const Ucdelay = 50; // delay before retrying

// fundamental constants
pub const Epmax = 0xF; // endpoint address mask

// request type
pub const Rh2d = 0 << 7; // host to device
pub const Rd2h = 1 << 7; // device to host

pub const Rstd = 0 << 5; // types
pub const Rclass = 1 << 5;
pub const Rvendor = 2 << 5;

pub const Rdev = 0; // recipients
pub const Riface = 1;
pub const Rep = 2; // endpoint
pub const Rother = 3;

// standard requests (USB2.0)
pub const Rgetstatus = 0;
pub const Rclearfeature = 1;
pub const Rsetfeature = 3;
pub const Rsetaddress = 5;
pub const Rgetdesc = 6;
pub const Rsetdesc = 7;
pub const Rgetconf = 8;
pub const Rsetconf = 9;
pub const Rgetiface = 10;
pub const Rsetiface = 11;
pub const Rsynchframe = 12;

// standard requests (USB3.0)
pub const Rsethubdepth = 12;
pub const Rgetporterrcnt = 13;

// dev classes
pub const Clnone = 0; // not in usb
pub const Claudio = 1;
pub const Clcomms = 2;
pub const Clhid = 3;
pub const Clprinter = 7;
pub const Clstorage = 8;
pub const Clhub = 9;
pub const Cldata = 10;

// standard descriptor sizes
pub const Ddevlen = 18;
pub const Dconflen = 9;
pub const Difacelen = 9;
pub const Deplen = 7;

// descriptor types
pub const Ddev = 1;
pub const Dconf = 2;
pub const Dstr = 3;
pub const Diface = 4;
pub const Dep = 5;
pub const Dreport = 0x22;
pub const Dfunction = 0x24;
pub const Dphysical = 0x23;

// feature selectors
pub const Fdevremotewakeup = 1;
pub const Fhalt = 0;

// device state
pub const Detached = 0;
pub const Attached = 1;
pub const Enabled = 2;
pub const Assigned = 3;
pub const Configured = 4;

// endpoint direction
pub const Ein = 0;
pub const Eout = 1;
pub const Eboth = 2;

// endpoint type
pub const Econtrol = 0;
pub const Eiso = 1;
pub const Ebulk = 2;
pub const Eintr = 3;

// endpoint isousage
pub const Edata = 0;
pub const Efeedback = 1;
pub const Eimplicit = 2;

// config attrib
pub const Cbuspowered = 1 << 7;
pub const Cselfpowered = 1 << 6;
pub const Cremotewakeup = 1 << 5;

// The report types of usb.h (Tmtype and the rest) are used by no
// program here and are left out; nusb/kb has its own in hid.h.

/// Usb device (when used for ep0s) or endpoint.
/// RC: One ref because of existing, another one per ogoing I/O.
/// per-driver resources (including FS if any) are released by aux
/// once the last ref is gone. This may include other Devs using
/// to access endpoints for actual I/O.
pub const Dev = struct {
    ref: Ref = .{},
    dir: []u8 = &.{}, // path for the endpoint dir
    id: i32 = 0, // usb id for device or ep. number
    dfd: i32 = -1, // descriptor for the data file
    cfd: i32 = -1, // descriptor for the control file
    isusb3: bool = false, // this is a usb3 device
    depth: i32 = 0, // hub depth from roothub -1
    maxpkt: i32 = 0, // cached from usb description
    usb: ?*Usbdev = null, // USB description
    ep: ?*Ep = null, // endpoint from epopen()
    aux: ?*anyopaque = null, // for the device driver
    hname: ?[]u8 = null, // hash name, unique for device
};

/// device description as reported by USB (unpacked).
pub const Usbdev = struct {
    ver: i32 = 0, // usb version
    csp: u32 = 0, // USB class/subclass/proto
    vid: i32 = 0, // vendor id
    did: i32 = 0, // product (device) id
    dno: i32 = 0, // device release number
    vendor: ?[]u8 = null,
    product: ?[]u8 = null,
    serial: ?[]u8 = null,
    vsid: i32 = 0,
    psid: i32 = 0,
    ssid: i32 = 0,
    class: i32 = 0, // from descriptor
    nconf: i32 = 0, // from descriptor
    conf: [Nconf]?*Conf = @splat(null), // configurations
    ep: [Epmax + 1]?*Ep = @splat(null), // all endpoints in device (chained), indexed by address
    ddesc: [Nddesc]?*Desc = @splat(null), // (raw) device specific descriptors
};

pub const Ep = struct {
    iface: ?*Iface = null, // the endpoint belongs to
    conf: ?*Conf = null, // the endpoint belongs to

    id: i32 = 0, // endpoint number: (id & Epmax) == endpoint address
    dir: u8 = 0, // direction, Ein/Eout/Eboth
    type: u8 = 0, // Econtrol, Eiso, Ebulk, Eintr

    attrib: i32 = 0,
    pollival: i32 = 0,
    maxpkt: i32 = 0, // max. packet size
    ntds: i32 = 0, // nb. of Tds per µframe

    // chain of endpoints with same address (used in different interfaces/altsettings)
    next: ?*Ep = null,

    aux: ?*anyopaque = null, // for the driver program
};

pub const Iface = struct {
    id: i32 = 0, // interface number
    alt: i32 = 0, // altsetting for this interface
    csp: u32 = 0, // USB class/subclass/proto
    next: ?*Iface = null, // chain of interfaces of different altsettings
    ep: [Nep]?*Ep = @splat(null), // consecutive array of endpoints in this interface (not including ep0)

    aux: ?*anyopaque = null, // for the driver program
};

pub const Conf = struct {
    cval: i32 = 0, // value for set configuration
    attrib: i32 = 0,
    milliamps: i32 = 0, // maximum power in this config.
    iface: [Niface]?*Iface = @splat(null),
};

/// Device-specific descriptors.
/// They show up mixed with other descriptors
/// within a configuration.
/// These are unknown to the library but handed to the driver.
pub const Desc = struct {
    conf: ?*Conf = null, // where this descriptor was read
    iface: ?*Iface = null, // last iface before desc in conf.
    ep: ?*Ep = null, // last endpt before desc in conf.
    data: []u8 = &.{}, // unparsed standard USB descriptor
};

pub fn Class(csp: u32) u32 {
    return csp & 0xff;
}

pub fn Subclass(csp: u32) u32 {
    return (csp >> 8) & 0xff;
}

pub fn Proto(csp: u32) u32 {
    return (csp >> 16) & 0xff;
}

pub fn CSP(c: u32, s: u32, p: u32) u32 {
    return c | s << 8 | p << 16;
}

pub fn GET2(p: []const u8) u32 {
    return @as(u32, p[1]) << 8 | p[0];
}

pub fn PUT2(p: []u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}

pub fn GET4(p: []const u8) u32 {
    return @as(u32, p[3]) << 24 | @as(u32, p[2]) << 16 | @as(u32, p[1]) << 8 | p[0];
}

pub fn PUT4(p: []u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}

/// more messages for bigger values
pub var usbdebug: i32 = 0;

pub fn dprint(comptime format: []const u8, args: anytype) void {
    if (usbdebug != 0)
        libc.fprint(2, format, args);
}

pub fn ddprint(comptime format: []const u8, args: anytype) void {
    if (usbdebug > 1)
        libc.fprint(2, format, args);
}

/// The C's %H (encodefmt): the bytes in hexadecimal, capitals.
pub const Hex = struct {
    b: []const u8,

    pub fn fmt9(self: Hex, f: *libc.fmt.Fmt) void {
        for (self.b) |c| {
            f.putc("0123456789ABCDEF"[c >> 4]);
            f.putc("0123456789ABCDEF"[c & 15]);
        }
    }
};

pub const U = dump_.U;
pub const classname = dump_.classname;
pub const emallocz = dump_.emallocz;
pub const estrdup = dump_.estrdup;
pub const create = dump_.create;

pub const openep = dev_.openep;
pub const opendev = dev_.opendev;
pub const opendevdata = dev_.opendevdata;
pub const loaddevconf = dev_.loaddevconf;
pub const mkep = dev_.mkep;
pub const loaddevstr = dev_.loaddevstr;
pub const loaddevdesc = dev_.loaddevdesc;
pub const configdev = dev_.configdev;
pub const closedev = dev_.closedev;
pub const usbcmd = dev_.usbcmd;
pub const unstall = dev_.unstall;
pub const setconf = dev_.setconf;
pub const setalt = dev_.setalt;
pub const devctl = dev_.devctl;
pub const getdev = dev_.getdev;

pub const parsedev = parse_.parsedev;
pub const parsedesc = parse_.parsedesc;
pub const parseconf = parse_.parseconf;
