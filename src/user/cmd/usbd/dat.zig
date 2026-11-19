//! from nusb/usbd/dat.h

const usb = @import("usb");

pub const Stack = 32 * 1024;

pub const Dhub = 0x29; // hub descriptor type
pub const Dhublen = 9; // hub descriptor length

pub const Dsshub = 0x2A; // superspeed hub descriptor type
pub const Dsshublen = 12; // superspeed hub descriptor length

// hub class feature selectors
pub const Fhublocalpower = 0;
pub const Fhubovercurrent = 1;

pub const Fportconnection = 0;
pub const Fportenable = 1;
pub const Fportsuspend = 2;
pub const Fportovercurrent = 3;
pub const Fportreset = 4;
pub const Fportpower = 8;
pub const Fportlowspeed = 9;
pub const Fcportconnection = 16;
pub const Fcportenable = 17;
pub const Fcportsuspend = 18;
pub const Fcportovercurrent = 19;
pub const Fcportreset = 20;
pub const Fportindicator = 22;
pub const Fbhportreset = 28;

// Port status and status change bits
// Constants at /sys/src/9/pc/usb.h starting with HP-
// must have the same values or root hubs won't work.
pub const PSpresent = 0x0001;
pub const PSenable = 0x0002;
pub const PSsuspend = 0x0004;
pub const PSovercurrent = 0x0008;
pub const PSreset = 0x0010;
pub const PSpower = 0x0100;
pub const PSslow = 0x0200;
pub const PShigh = 0x0400;

pub const PSstatuschg = 0x10000; // PSpresent changed
pub const PSchange = 0x20000; // PSenable changed

// port/device state
pub const Pdisabled = 0; // must be 0
pub const Pattached = 1;
pub const Pconfigured = 2;

// Delays, timeouts (ms)
pub const Rootresetdelay = 100; // how much to wait after a root port reset (50ms by standard)
pub const Portresetdelay = 50; // how much to wait after a hub port reset (20ms by standard)
pub const Resumedelay = 50; // how much to wait after a resume (20ms by standard)
pub const Powerdelay = 100; // after powering up ports
pub const Pollms = 250; // port poll interval

pub const Attachdelay = 3000; // attach considered repeated if within Attachdelay
pub const Attachcount = 5; // maximum number of repeated attaches before giving up

// The C's DCL, DSC and DPT (a device table for drivers built into
// usbd) are used nowhere and left out.

pub const Hub = struct {
    pwrmode: u8 = 0,
    compound: bool = false,
    pwrms: i32 = 0, // time to wait in ms
    maxcurrent: u8 = 0, //    after powering port
    ttt: u8 = 0, // tt think-time
    mtt: bool = false, // muti tt enabled
    leds: bool = false, // has port indicators?
    maxpkt: i32 = 0,
    nport: u8 = 0,
    port: []Port = &.{},
    failed: bool = false, // I/O error while enumerating
    dev: ?*usb.Dev = null, // for this hub
    next: ?*Hub = null, // in list of hubs
};

pub const Port = struct {
    state: i32 = 0, // state of the device
    sts: u32 = 0, // old port status
    atime: u32 = 0, // time of last attach in milliseconds
    acount: i32 = 0, // rapid attach counter
    removable: bool = false,
    pwrctl: bool = false,
    dev: ?*usb.Dev = null, // attached device (if non-nil)
    hub: ?*Hub = null, // non-nil if hub attached
};

// USB HUB descriptor (DHub): bLength 0, bDescriptorType 1, bNbrPorts
// 2, wHubCharacteristics 3, bPwrOn2PwrGood 5, bHubContrCurrent 6,
// DeviceRemovable 7 (variable length).
//
// Superspeed HUB descriptor (DSSHub): the same to bHubContrCurrent,
// then bHubHdrDecLat 7, wHubDelay 8, DeviceRemovable 10 (variable
// length).
