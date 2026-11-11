//! common USB definitions.
//! from 9/port/usb.h
//!
//! DIFF:
//!   - Hci is not an ISAConf and an Hciimpl by embedding: the ISAConf is
//!     the field `isa` (hp->port, hp->irq and hp->type are hp.isa.port,
//!     hp.isa.irq and hp.isa.type) and the entries of Hciimpl are fields
//!     of Hci itself, each optional as each may be nil in C.  ISAConf is
//!     devether's until the platform has an isaconfig of its own.
//!   - The driver entries return Zig errors where the C can raise one.
//!     epread and epwrite take slices; seprintep takes the buffer and
//!     returns how much of it it wrote; a port number and its on/off
//!     argument are an unsigned number and a bool.
//!   - An Ep's Ref and QLock are the named fields `ref` and `qlock`.
//!     Its name and info are optional slices.
//!   - The dprint family of macros tests a debug variable of the file
//!     that uses it; devusb.zig has them as functions.
//!   - GET2 and PUT2 take pointers to bytes.
//!   - Interrupts are by message only (see PLAN.md), so Hci.isa.irq is
//!     only what the PCI configuration says; a controller that has
//!     neither MSI nor MSI-X does not interrupt.

const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const devether = @import("devether.zig");
const lib = @import("lib.zig");

const Error = proc.Error;
const Ref = portdat.Ref;
const QLock = portdat.QLock;

pub const ISAConf = devether.ISAConf;

pub fn GET2(p: [*]const u8) u32 {
    return (@as(u32, p[1]) << 8) | p[0];
}

pub fn PUT2(p: [*]u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}

// fundamental constants
pub const Ndeveps = 32; // max nb. of endpoints per device (16 in + 16 out)

// tunable parameters
pub const Nhcis = 16; // max nb. of HCIs
pub const Neps = 64; // max nb. of endpoints
pub const Maxctllen = 32 * 1024; // max allowed sized for ctl. xfers; see Maxdevconf
pub const Xfertmout = 2000; // default request time out (ms)

// transfer types. keep this order
pub const Tnone = 0; // no tranfer type configured
pub const Tctl = 1; // wr req + rd/wr data + wr/rd sts
pub const Tiso = 2; // stream rd or wr (real time)
pub const Tbulk = 3; // stream rd or wr
pub const Tintr = 4; // msg rd or wr
pub const Nttypes = 5; // number of transfer types

pub const Epmax = 0xF; // max ep. addr
pub const Devmax = 0x7F; // max dev. addr

// Speeds
pub const Fullspeed = 0;
pub const Lowspeed = 1;
pub const Highspeed = 2;
pub const Nospeed = 3;
pub const Superspeed = 4;

// request type
pub const Rh2d = 0 << 7;
pub const Rd2h = 1 << 7;
pub const Rstd = 0 << 5;
pub const Rclass = 1 << 5;
pub const Rdev = 0;
pub const Rep = 2;
pub const Rother = 3;

// req offsets
pub const Rtype = 0;
pub const Rreq = 1;
pub const Rvalue = 2;
pub const Rindex = 4;
pub const Rcount = 6;
pub const Rsetuplen = 8;

// standard requests
pub const Rgetstatus = 0;
pub const Rclearfeature = 1;
pub const Rsetfeature = 3;
pub const Rsetaddr = 5;
pub const Rgetdesc = 6;

// device states
pub const Dconfig = 0; // configuration in progress
pub const Denabled = 1; // address assigned
pub const Ddetach = 2; // device is detached
pub const Dreset = 3; // its port is being reset

// (root) Hub reply to port status (reported to usbd)
pub const HPpresent = 0x1;
pub const HPenable = 0x2;
pub const HPsuspend = 0x4;
pub const HPovercurrent = 0x8;
pub const HPreset = 0x10;
pub const HPpower = 0x100;
pub const HPslow = 0x200;
pub const HPhigh = 0x400;
pub const HPstatuschg = 0x10000;
pub const HPchange = 0x20000;

// Services provided by the driver.
// epopen allocates hardware structures to prepare the endpoint
// for I/O. This happens when the user opens the data file.
// epstop canceles in-flight I/O and epclose releases them.
// This happens when the data file is closed.
// epwrite tries to write the given bytes, waiting until all of them
// have been written (or failed) before returning; but not for Iso.
// epread does the same for reading.
// It can be assumed that endpoints are DMEXCL but concurrent
// read/writes may be issued and the controller must take care.
// For control endpoints, device-to-host requests must be followed by
// a read of the expected length if needed.
// The port requests are called when usbd issues commands for root
// hubs. Port status must return bits as a hub request would do.
// Toggle handling and other details are left for the controller driver
// to avoid mixing too much the controller and the comon device.
// While an endpoint is stopped, its toggles are saved in the Ep struct.
//
// DIFF: Hciimpl's entries are the second block of fields of Hci.

/// Host Controller Interface
pub const Hci = struct {
    isa: ISAConf = .{}, // hardware info
    tbdf: i32 = arch.BUSUNKNOWN, // type+busno+devno+funcno
    ctlrno: u32 = 0, // controller number
    nports: u32 = 0, // number of ports in hub
    highspeed: bool = false, // supports highspeed devices
    superspeed: u32 = 0, // bitmap of superspeed ports

    // Hciimpl: link to the controller impl.
    aux: ?*anyopaque = null, // for controller info
    init: ?*const fn (*Hci) Error!void = null, // init. controller
    interrupt: ?*const fn (*arch.Ureg, ?*anyopaque) void = null, // service interrupt
    epopen: ?*const fn (*Ep) Error!void = null, // prepare ep. for I/O
    epstop: ?*const fn (*Ep) Error!void = null, // cancel I/O on ep.
    epclose: ?*const fn (*Ep) Error!void = null, // release I/O on ep. (after epstop)
    epread: ?*const fn (*Ep, []u8) Error!usize = null, // transmit data for ep
    epwrite: ?*const fn (*Ep, []const u8) Error!usize = null, // receive data for ep
    seprintep: ?*const fn ([]u8, *Ep) usize = null, // debug
    devclose: ?*const fn (*Udev) void = null, // release the device
    portenable: ?*const fn (*Hci, u32, bool) void = null, // enable/disable root port
    portreset: ?*const fn (*Hci, u32, bool) void = null, // set/clear root port reset
    bhportreset: ?*const fn (*Hci, u32, bool) void = null, // set/clear warm root port reset (usb3)
    portpower: ?*const fn (*Hci, u32, bool) void = null, // set/clear root port power state
    portstatus: ?*const fn (*Hci, u32) u32 = null, // get root port status
    shutdown: ?*const fn (*Hci) void = null, // shutdown for reboot
    debug: ?*const fn (*Hci, i32) void = null, // set/clear debug flag
};

/// USB endpoint.
/// All endpoints are kept in a global array. The first
/// block of fields is constant after endpoint creation.
/// The rest is configuration information given to all controllers.
/// The first endpoint for a device (known as ep0) represents the
/// device and is used to configure it and create other endpoints.
/// Its QLock also protects per-device data in dev.
/// See Hciimpl for clues regarding how this is used by controllers.
pub const Ep = struct {
    ref: Ref = .{}, // one per fid (and per dev ep for ep0s)

    // const once inited.
    idx: usize = 0, // index in global eps array
    nb: u32 = 0, // endpoint number in device
    hp: *Hci, // HCI it belongs to
    dev: *Udev = undefined, // device for the endpoint
    ep0: *Ep = undefined, // control endpoint for its device

    qlock: QLock = .{}, // protect fields below
    name: ?[]u8 = null, // for ep file names at #u/
    inuse: bool = false, // endpoint is open
    mode: u32 = 0, // OREAD, OWRITE, or ORDWR
    clrhalt: bool = false, // true if halt was cleared on ep.
    debug: i32 = 0, // per endpoint debug flag
    info: ?[]u8 = null, // for humans to read
    maxpkt: i32 = 0, // maximum packet size
    ttype: u32 = Tnone, // tranfer type
    load: u32 = 0, // in µs, for a transfer of maxpkt bytes
    aux: ?*anyopaque = null, // for controller specific info
    toggle: [2]i32 = .{ 0, 0 }, // saved toggles (while ep is not in use)
    pollival: i32 = 0, // poll interval ([µ]frames; intr/iso)
    hz: i32 = 0, // poll frequency (iso)
    samplesz: i32 = 0, // sample size (iso)
    ntds: i32 = 0, // nb. of Tds per µframe
    tmout: i32 = 0, // 0 or timeout for transfers (ms)
    sampledelay: i32 = 0, // maximum delay introduced by buffering (iso)
    uframes: i32 = 0, // uframes mode (iso); 0 = normal behaviour, 1 = return only one uframe per read
};

/// Per-device configuration and cached list of endpoints.
/// eps[0]->QLock protects it.
pub const Udev = struct {
    nb: u32 = 0, // USB device number
    state: u32 = Dconfig, // state for the device
    nports: u32 = 0, // number of downstream ports for hub
    speed: u32 = 0, // Full/Low/High/Super -speed
    port: u32 = 0, // port number on parent hub
    addr: u32 = 0, // device address
    depth: i32 = 0, // hub depth from root port -1
    rootport: u32 = 0, // port number on root hub
    routestr: u32 = 0, // route string

    hub: ?*Udev = null, // parent hub; keeping ref to hub->eps[0]

    tthub: ?*Udev = null, // the TT HS hub
    ttport: u32 = 0, // port number on TT HS hub
    ttt: u32 = 0, // TT Think-Time for HS hub
    mtt: u32 = 0, // Multi TT enabled for HS hub

    aux: ?*anyopaque = null,

    eps: [Ndeveps]?*Ep = @splat(null), // end points for this device (cached)

    rhrepl: u64 = norepl, // fake root hub replies
    rhresetport: u32 = 0, // root port being reset
};

/// DIFF: Udev.rhrepl when there is no reply to read (-1 in the C).
pub const norepl: u64 = ~@as(u64, 0);

pub const usbmodename = [_][]const u8{
    "r", // OREAD
    "w", // OWRITE
    "rw", // ORDWR
};

comptime {
    if (lib.OREAD != 0 or lib.OWRITE != 1 or lib.ORDWR != 2)
        @compileError("usbmodename is indexed by open mode");
}

pub const Estalled = "endpoint stalled";

// addhcitype and seprintdata are in devusb.zig.
