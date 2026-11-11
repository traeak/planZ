//! USB eXtensible Host Controller Interface driver: the part that does
//! not depend on the bus the controller sits on.
//! from 9/port/usbxhci.c and 9/port/usbxhci.h
//!
//! DIFF:
//!   - Errors are Zig error returns.  ctlrcmd, waittd and unstall keep
//!     returning the text of what went wrong, or null, as in the C, and
//!     their callers turn it into an error.  A waserror that undoes
//!     something is a defer or errdefer.  waittd's `while(waserror())`
//!     is a loop around the wait, entered again when the wait fails.
//!     recover's `while(waserror());`, which starts recover over when
//!     anything in it is interrupted, is a catch on each of its sleeps:
//!     an interrupted sleep just goes on.
//!   - A Ctlr contains its Xhci as the field `xhci` instead of starting
//!     with it; Hci.aux points at the Xhci and ctlrof gets the Ctlr.
//!   - dmaflush is gone: arch.zig has no such service, and no platform
//!     so far needs one (memory is coherent with device DMA).
//!   - mallocalign's `span` argument (the block may not cross a multiple
//!     of span) is not implemented in alloc.zig; dmaalloc gets the same
//!     effect by raising the alignment to the block's size.
//!   - Registers, rings and device contexts are volatile pointers, and
//!     the 64-bit values in them are written as two 32-bit words, low
//!     word first (the C stores through a u64int pointer).  xecp
//!     returns the index of the capability in the register words, not a
//!     pointer.
//!   - The buffer of a bulk or interrupt transfer is given to the
//!     controller as it is when it is a kernel address and copied
//!     through a Block when it is a user address.  The C's test is
//!     `p <= KZERO`; here the kernel heap is in the direct map, below
//!     KZERO, so the test is "below USTKTOP" as in devsd.zig.
//!   - A root port beyond the 32nd is never marked superspeed: the map
//!     in Hci has 32 bits and the C's shift is undefined there.
//!   - A bug fixed on purpose: when ep0 of a hub is (re)opened the C
//!     issues Configure Endpoint with the ep0 flag set, which the
//!     specification forbids and QEMU refuses; see initep.
//!   - µframe is spelled uframe, Zig identifiers being ASCII.
//!   - A Ring's Lock and an Epio's QLock are named fields; a Ring's
//!     residue table is a slice.
//!   - Interrupts: intrenable gets the PCI tbdf and programs MSI or
//!     MSI-X (every table entry with the one message), so interrupter 0
//!     is the only one enabled, as in the C, and there is no INTx.
//!   - Not in the C, each for a first boot on a machine whose only
//!     console is the screen and whose only keyboard is on this
//!     controller: xhcihandoff halts the controller it has taken from
//!     the firmware; xhciinit prints what the controller is and refuses
//!     one that cannot address the memory it was given; recover notices
//!     when events are left in the event ring with no interrupt and
//!     then polls (lostintr); and a hub's Configure Endpoint that is
//!     refused is tried again in the C's form (initep).

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const ab = @import("allocb.zig");
const proc = @import("proc.zig");
const errmod = @import("error.zig");
const usb = @import("usb.zig");
const p9 = @import("print.zig");

const print = p9.print;
const iprint = p9.iprint;
const panic = p9.panic;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const coherence = arch.coherence;
const delay = arch.delay;
const tsleep = proc.tsleep;
const sleep = proc.sleep;
const wakeup = proc.wakeup;
const return0 = proc.return0;
const allocb = ab.allocb;
const freeb = ab.freeb;
const BLEN = ab.BLEN;

const Error = proc.Error;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Rendez = portdat.Rendez;
const Block = ab.Block;
const Hci = usb.Hci;
const Ep = usb.Ep;
const Udev = usb.Udev;
const OREAD = lib.OREAD;
const OWRITE = lib.OWRITE;
const Tctl = usb.Tctl;
const Tiso = usb.Tiso;
const Tintr = usb.Tintr;
const Epmax = usb.Epmax;
const Devmax = usb.Devmax;
const Fullspeed = usb.Fullspeed;
const Lowspeed = usb.Lowspeed;
const Highspeed = usb.Highspeed;
const Superspeed = usb.Superspeed;
const GET2 = usb.GET2;

// from 9/port/usbxhci.h
//
// I/O interface for usb XHCI controller.

pub const Xhci = struct {
    mmio: [*]volatile u32,
    base: u64,
    size: u64,

    aux: ?*anyopaque = null,
    dmaaddr: *const fn (va: usize) u64,

    active: ?*Hci = null,
};

// Capability Registers
const CAPLENGTH = 0x00 / 4; // 1
const HCIVERSION = 0x02 / 4; // 2
const HCSPARAMS1 = 0x04 / 4;
const HCSPARAMS2 = 0x08 / 4;
const HCSPARAMS3 = 0x0C / 4;

const HCCPARAMS = 0x10 / 4;
const AC64 = 1 << 0;
const BNC = 1 << 1;
const CSZ = 1 << 2;
const PPC = 1 << 3;
const PIND = 1 << 4;
const LHRC = 1 << 5;
const LTC = 1 << 6;
const NSS = 1 << 7;

const DBOFF = 0x14 / 4;
const RTSOFF = 0x18 / 4;

const HCCPARAMS2 = 0x1C / 4;

// Operational Registers
const USBCMD = 0x00 / 4; // USB Command Register
const RUNSTOP = 1 << 0; // Run/Stop - RW
const HCRST = 1 << 1; // Host Controller Reset - RW
const INTE = 1 << 2; // Interrupter Enable - RW
const HSEE = 1 << 3; // Host System Error Enable - RW
const LHCRST = 1 << 7; // Light Host Controller Reset - RO/RW
const CSS = 1 << 8; // Controller Save State - RW
const CRS = 1 << 9; // Controller Restore State - RW
const EWE = 1 << 10; // Enable Wrap Event - RW
const EU3S = 1 << 11; // Enable U3 MFINDEX Stop - RW
const CME = 1 << 13; // CEM Enable - RW
const ETE = 1 << 14; // Extended TBC Enable (ETE)
const TSCEN = 1 << 15; // Extended TBC TRB Status Enable (TSC_EN)
const VTIOEN = 1 << 16; // VTIO Enable - RW
const USBCMD_PRES: u32 = 0xfffe1070; // Reserved - RsvdP

const USBSTS = 0x04 / 4; // USB Status Register
const HCH = 1 << 0; // HCHalted - RO
const HSE = 1 << 2; // Host System Error - RW1C
const EINT = 1 << 3; // Event Interrupt - RW1C
const PCD = 1 << 4; // Port Change Detect - RW1C
const SSS = 1 << 8; // Save State Status - RO
const RSS = 1 << 9; // Restore State Status - RO
const SRE = 1 << 10; // Save/Restore Error - RW1C
const CNR = 1 << 11; // Controller Not Ready - RO
const HCE = 1 << 12; // Host Controller Error - RO
const USBSTS_PRES: u32 = 0xffffe002; // Reserved - RsvdP

const PAGESIZE = 0x08 / 4; // Page Size - RO

const DNCTRL = 0x14 / 4; // Device Notification Control Register - RW
const DNCTL_PRES: u32 = 0xffff0000; // Reserved - RsvdP

const CRCR = 0x18 / 4; // Command Ring Control Register - RW
const RCS = 1 << 0; // Ring Cycle State - RW
const CS = 1 << 1; // Command Stop - RW1S
const CA = 1 << 2; // Command Abort - RW1S
const CRR = 1 << 3; // Command Ring Running - RO
const CRCR_PRES: u32 = 3 << 4; // Reserved - RsvdP

const DCBAAP = 0x30 / 4; // 64-bit

const CONFIG = 0x38 / 4; // Configure Register (MaxSlotEn[7:0])
const CONFIG_PRES: u32 = 0xfffffc00; // Reserved - RsvdP

// Port Register Set
const PORTSC = 0x00 / 4; // Port status and Control Register
const CCS: u32 = 1 << 0; // Current Connect Status - ROS
const PED: u32 = 1 << 1; // Port Enable/Disabled - RW1CS
const OCA: u32 = 1 << 3; // Over-current Active - RO
const PR: u32 = 1 << 4; // Port Reset - RW1S
const PLS: u32 = 15 << 5; // Port Link State - RWS
const PP: u32 = 1 << 9; // Port Power - RWS
const PS: u32 = 15 << 10; // Port Speed - ROS
const PIC: u32 = 3 << 14; // Port Indicator Control - RWS
const LWS: u32 = 1 << 16; // Port Link Write Strobe - RW
const CSC: u32 = 1 << 17; // Connect Status Change - RW1CS
const PEC: u32 = 1 << 18; // Port Enabled/Disabled Change - RW1CS
const WRC: u32 = 1 << 19; // Warm Port Reset Change - RW1CS
const OCC: u32 = 1 << 20; // Over-current Change - RW1CS
const PRC: u32 = 1 << 21; // Port Reset Change - RW1CS
const PLC: u32 = 1 << 22; // Port Link State Change - RW1CS
const CEC: u32 = 1 << 23; // Port Config Error Change - RW1CS
const CAS: u32 = 1 << 24; // Cold Attach Status - RO
const WCE: u32 = 1 << 25; // Wake on Connect Enable - RWS
const WDE: u32 = 1 << 26; // Wake on Disconnect Enable - RWS
const WOE: u32 = 1 << 27; // Wake on Over-current Enable - RWS
const DR: u32 = 1 << 30; // Device Removable - RO
const WPR: u32 = 1 << 31; // Warm Port Reset - RW1S

const PORTPMSC = 0x04 / 4;
const PORTLI = 0x08 / 4;

// Host Controller Runtime Register
const MFINDEX = 0x0000 / 4; // Microframe Index
const IR0 = 0x0020 / 4; // Interrupt Register Set 0

// Interrupter Registers
const IMAN = 0x00 / 4; // Interrupter Management
const IP = 1 << 0; // Interrupt pending - RW1C
const IE = 1 << 1; // interrupt enable - RW
const IMAN_PRES: u32 = 0xfffffffc; // Reserved - RsvdP
const IMOD = 0x04 / 4; // Interrupter Moderation
const ERSTSZ = 0x08 / 4; // Event Ring Segment Table Size
const ERSTSZ_PRES: u32 = 0xffff0000; // Reserved - RsvdP
const ERSTBA = 0x10 / 4; // Event Ring Segment Table Base Address
const ERSTBA_PRES: u32 = 0x3f; // Reserved - RsvdP
const ERDP = 0x18 / 4; // Event Ring Dequeue Pointer
const EHB = 1 << 3; // Event Handler Busy - RW1C

// TRB flags
const TR_ENT = 1 << 1;
const TR_ISP = 1 << 2;
const TR_NS = 1 << 3;
const TR_CH = 1 << 4;
const TR_IOC = 1 << 5;
const TR_IDT = 1 << 6;
const TR_BEI = 1 << 9;

// TRB types
const TR_RESERVED = 0 << 10;
const TR_NORMAL = 1 << 10;
const TR_SETUPSTAGE = 2 << 10;
const TR_DATASTAGE = 3 << 10;
const TR_STATUSSTAGE = 4 << 10;
const TR_ISOCH = 5 << 10;
const TR_LINK = 6 << 10;
const TR_EVENTDATA = 7 << 10;
const TR_NOOP = 8 << 10;

const CR_ENABLESLOT = 9 << 10;
const CR_DISABLESLOT = 10 << 10;
const CR_ADDRESSDEV = 11 << 10;
const CR_CONFIGEP = 12 << 10;
const CR_EVALCTX = 13 << 10;
const CR_RESETEP = 14 << 10;
const CR_STOPEP = 15 << 10;
const CR_SETTRDQP = 16 << 10;
const CR_RESETDEV = 17 << 10;
const CR_FORCECMD = 18 << 10;
const CR_NEGBW = 19 << 10;
const CR_SETLAT = 20 << 10;
const CR_GETPORTBW = 21 << 10;
const CR_FORCEHDR = 22 << 10;
const CR_NOOP = 23 << 10;

const ER_TRANSFER = 32 << 10;
const ER_CMDCOMPL = 33 << 10;
const ER_PORTSC = 34 << 10;
const ER_BWREQ = 35 << 10;
const ER_DOORBELL = 36 << 10;
const ER_HCE = 37 << 10;
const ER_DEVNOTE = 38 << 10;
const ER_MFINDEXWRAP = 39 << 10;

const Wait = struct {
    next: ?*Wait = null,
    ring: *Ring = undefined,
    td: [*]volatile u32 = undefined,
    er: [4]u32 = @splat(0),
    z: ?*Rendez = null,
};

const Ring = struct {
    id: u32 = 0,

    ctlr: ?*Ctlr = null,
    slot: ?*Slot = null,

    base: ?[*]volatile u32 = null,

    mask: u32 = 0,
    shift: u32 = 0,

    rp: u32 = 0,
    wp: u32 = 0,

    ctx: ?[*]volatile u32 = null,
    doorbell: ?*volatile u32 = null,

    stopped: bool = false,

    residue: ?[]u32 = null,
    pending: ?*Wait = null,
    lock: Lock = .{},
};

const Slot = struct {
    id: u32 = 0,

    ctlr: *Ctlr,
    dev: *Udev,

    ibase: ?[*]volatile u32 = null,
    obase: ?[*]volatile u32 = null,

    // endpoint rings
    nep: u32 = 0,
    epr: [32]Ring = @splat(.{}),
};

const Port = struct {
    spec: [4]u8 = @splat(0),
    proto: u32 = 0,

    reg: [*]volatile u32,
};

const Ctlr = struct {
    xhci: Xhci,

    opr: [*]volatile u32 = undefined, // operational registers
    rts: [*]volatile u32 = undefined, // runtime registers
    dba: [*]volatile u32 = undefined, // doorbell array

    dcba: ?[*]volatile u64 = null, // device context base array

    sba: ?[*]volatile u64 = null, // scratchpad buffer array
    sbp: ?[*]u8 = null, // scratchpad buffer pages

    erst: [1]?[*]volatile u32 = @splat(null), // event ring segment table
    er: [1]Ring = @splat(.{}), // event ring segment
    cr: [1]Ring = @splat(.{}), // command ring segment
    cmdlock: QLock = .{},

    uframe: u32 = 0,

    slotlock: QLock = .{},
    slot: ?[]?*Slot = null, // slots by slot id
    port: ?[]Port = null,

    csz: u1 = 0,
    pagesize: usize = 0,
    nscratch: u32 = 0,
    nintrs: u32 = 0,
    nslots: u32 = 0,

    recover: Rendez = .{},

    // DIFF: not in the C, see lostintr
    polling: bool = false,
};

const Epio = struct {
    qlock: QLock = .{},

    ring: ?*Ring = null,
    b: ?*Block = null,

    // iso
    frame: u32 = 0,
    period: u32 = 0,
    incr: u32 = 0,
    tdsz: u32 = 0,

    // isoread
    rp0: u32 = 0,
    frame0: u32 = 0,

    nleft: u32 = 0,
};

const Ebadlen = "bad usb request length";
const Enotconfig = "usb endpoint not configured";
const Erecover = "xhci controller needs reset";

/// DIFF: the Ctlr of a controller (Ctlr *ctlr = hp->aux in the C).
fn ctlrof(hp: *Hci) *Ctlr {
    const x: *Xhci = @ptrCast(@alignCast(hp.aux.?));
    return @fieldParentPtr("xhci", x);
}

/// DIFF: (*ctlr->dmaaddr)(va).
fn dma(ctlr: *Ctlr, va: anytype) u64 {
    return ctlr.xhci.dmaaddr(@intFromPtr(va));
}

/// DIFF: mallocalign(size, alignment, 0, span), see the top of the file.
fn dmaalloc(size: usize, alignment: usize, span: usize) ?[*]u8 {
    var a = alignment;
    if (span != 0) {
        while (a < size and a < span)
            a <<= 1;
    }
    return alloc.mallocalign(size, a, 0, 0);
}

/// DIFF: the Epio pair of an open endpoint (ep->aux).
fn epio(ep: *Ep) ?*[2]Epio {
    return @ptrCast(@alignCast(ep.aux orelse return null));
}

/// DIFF: memset on device memory, n bytes as 32-bit words.
fn zero(w: [*]volatile u32, n: usize) void {
    var i: usize = 0;
    while (i < n / 4) : (i += 1)
        w[i] = 0;
}

/// DIFF: error(s) for one of the messages ctlrcmd and friends return.
fn errstr(s: []const u8) Error {
    return proc.errorf("%s", .{s});
}

fn setrptr(reg: [*]volatile u32, pa: u64) void {
    coherence();
    reg[0] = @truncate(pa);
    reg[1] = @truncate(pa >> 32);
}

fn uframe(ctlr: *Ctlr) u32 {
    const cur: *volatile u32 = &ctlr.uframe;
    var mu: u32 = undefined;
    while (true) {
        mu = (ctlr.rts[MFINDEX] & ((1 << 14) - 1)) |
            (cur.* & ~@as(u32, (1 << 14) - 1));
        if (@as(i32, @bitCast(mu -% cur.*)) >= 0)
            break;
    }
    return mu;
}

fn freering(r_: ?*Ring) void {
    const r = r_ orelse return;
    if (r.base) |base|
        alloc.free(base);
    if (r.residue) |residue|
        alloc.free(residue);
    r.* = .{};
}

fn initring(ctlr: *Ctlr, r: *Ring, shift: u32) Error!*Ring {
    r.id = 0;
    r.ctlr = ctlr;
    r.slot = null;
    r.ctx = null;
    r.doorbell = null;
    r.pending = null;
    r.residue = null;
    r.stopped = false;
    r.shift = shift;
    r.mask = (@as(u32, 1) << @intCast(shift)) - 1;
    r.rp = 0;
    r.wp = 0;
    const base = dmaalloc(@as(usize, 4 * 4) << @intCast(shift), 64, 64 * 1024) orelse {
        r.base = null;
        freering(r);
        return error.Enomem;
    };
    r.base = @ptrCast(@alignCast(base));
    return r;
}

fn flushring(r: *Ring) void {
    while (r.pending) |w| {
        r.pending = w.next;
        w.next = null;
        if (w.z) |z| {
            w.z = null;
            _ = wakeup(z);
        }
    }
}

fn resetring(r: *Ring) u64 {
    ilock(&r.lock);
    flushring(r);
    r.rp = r.wp;
    const pa = dma(r.ctlr.?, r.base.? + 4 * (r.wp & r.mask)) | ((~r.wp >> @intCast(r.shift)) & 1);
    iunlock(&r.lock);

    return pa;
}

/// Find the next extended capability with the given id after the one
/// at word p of the registers, or the first if p is null.
fn xecp(ctlr: *Xhci, id: u8, p_: ?usize) ?usize {
    var p: usize = undefined;
    var x: u32 = undefined;

    const e: usize = @intCast(ctlr.size / 4);
    if (p_) |pp| {
        if (pp >= e) panic("xecp", .{});
        p = pp;
        x = (ctlr.mmio[p] >> 8) & 255;
    } else {
        p = 0;
        x = ctlr.mmio[HCCPARAMS] >> 16;
    }
    while (x != 0) {
        p += x;
        if (p >= e)
            break;
        x = ctlr.mmio[p];
        if ((x & 255) == id)
            return p;
        x >>= 8;
        x &= 255;
    }
    return null;
}

pub fn xhcihandoff(ctlr: *Xhci) void {
    // DIFF: the C returns here when there is no legacy capability; the
    // halt below is wanted either way.
    if (xecp(ctlr, 1, null)) |p| {
        const r = ctlr.mmio + p;
        const rb: [*]volatile u8 = @ptrCast(r);
        if ((r[0] & (1 << 16)) != 0 and arch.getconf("*noxhcihandoff") == null) {
            rb[3] |= 1;
            var i: i32 = 5000;
            while ((r[0] & (1 << 16)) != 0 and i >= 0) : (i -= 1)
                delay(1);
            // clear BIOS ownership in case of timeout
            if (i < 0) {
                rb[2] &= ~@as(u8, 1);
                print("usbxhci %llux: timeout: in handoff\n", .{ctlr.base});
            }
        }
        // disable SMI interrupts
        r[1] &= 7 << 1 | 255 << 5 | 7 << 17 | 7 << 29;
    }

    // DIFF: not in the C, which leaves the controller as the firmware
    // had it until xhciinit, and that is after every other driver's
    // reset.  A controller the firmware left running goes on writing
    // key reports and events into memory that was the firmware's and
    // is the kernel's now, so stop it here.  It should halt within
    // 16ms (xHCI 5.4.1.1); xhciinit complains if it has not.
    const opr = ctlr.mmio + (ctlr.mmio[CAPLENGTH] & 0xFF) / 4;
    if ((opr[USBSTS] & (CNR | HCH)) == 0) {
        opr[USBCMD] &= USBCMD_PRES;
        var i: i32 = 32;
        while ((opr[USBSTS] & HCH) == 0 and i >= 0) : (i -= 1)
            delay(1);
    }
}

pub fn xhcishutdown(hp: *Hci) void {
    const ctlr = ctlrof(hp);

    ctlr.opr[USBCMD] &= USBCMD_PRES;
    var i: i32 = 100;
    while ((ctlr.opr[USBSTS] & HCH) == 0 and i >= 0) : (i -= 1)
        delay(1);
    arch.intrdisable(hp.isa.irq, hp.interrupt.?, hp, hp.tbdf, hp.isa.type);
}

fn release(ctlr: *Ctlr) void {
    freering(&ctlr.cr[0]);
    for (&ctlr.er, 0..) |*er, i| {
        freering(er);
        alloc.free(ctlr.erst[i]);
        ctlr.erst[i] = null;
    }
    if (ctlr.port) |port| alloc.free(port);
    ctlr.port = null;
    if (ctlr.slot) |slot| alloc.free(slot);
    ctlr.slot = null;
    alloc.free(ctlr.dcba);
    ctlr.dcba = null;
    alloc.free(ctlr.sba);
    ctlr.sba = null;
    if (ctlr.sbp) |sbp| {
        alloc.free(sbp);
        ctlr.sbp = null;
    }
}

pub fn xhciinit(hp: *Hci) Error!void {
    const up = arch.up().?;
    var u: u32 = undefined;
    var i: i32 = undefined;

    const ctlr = ctlrof(hp);
    const mmio = ctlr.xhci.mmio;
    ctlr.opr = mmio + (mmio[CAPLENGTH] & 0xFF) / 4;
    ctlr.dba = mmio + mmio[DBOFF] / 4;
    ctlr.rts = mmio + mmio[RTSOFF] / 4;

    i = 500;
    u = ctlr.opr[USBSTS];
    while ((u & CNR) != 0 and i >= 0) : (i -= 1) {
        try tsleep(&up.sleep, return0, null, 10);
        u = ctlr.opr[USBSTS];
    }
    if (i < 0) print("usbxhci %llux: timeout: not ready after handoff: %.8ux\n", .{ ctlr.xhci.base, u });

    // halt the controller
    ctlr.opr[USBCMD] &= USBCMD_PRES;
    try tsleep(&up.sleep, return0, null, 1);
    i = 500;
    u = ctlr.opr[USBSTS];
    while ((u & (CNR | HCH)) != HCH and i >= 0) : (i -= 1) {
        try tsleep(&up.sleep, return0, null, 10);
        u = ctlr.opr[USBSTS];
    }
    if (i < 0) print("usbxhci %llux: timeout: not halted before reset: %.8ux\n", .{ ctlr.xhci.base, u });

    // reset the controller
    ctlr.opr[USBCMD] = HCRST | (ctlr.opr[USBCMD] & USBCMD_PRES);
    try tsleep(&up.sleep, return0, null, 1);
    i = 100;
    u = ctlr.opr[USBCMD];
    while ((u & HCRST) != 0 and i >= 0) : (i -= 1) {
        try tsleep(&up.sleep, return0, null, 10);
        u = ctlr.opr[USBCMD];
    }
    if (i < 0) print("usbxhci %llux: timeout: reset command didnt clear: %.8ux\n", .{ ctlr.xhci.base, u });
    i = 500;
    u = ctlr.opr[USBSTS];
    while ((u & (CNR | HCH)) != HCH and i >= 0) : (i -= 1) {
        try tsleep(&up.sleep, return0, null, 10);
        u = ctlr.opr[USBSTS];
    }
    if (i < 0) print("usbxhci %llux: timeout: not halted after reset: %.8ux\n", .{ ctlr.xhci.base, u });

    arch.intrenable(hp.isa.irq, hp.interrupt.?, hp, hp.tbdf, hp.isa.type);

    errdefer {
        hp.shutdown.?(hp);
        release(ctlr);
    }

    ctlr.csz = @intFromBool((mmio[HCCPARAMS] & CSZ) != 0);
    ctlr.pagesize = @as(usize, ctlr.opr[PAGESIZE] & 0xFFFF) << 12;

    ctlr.nscratch = (mmio[HCSPARAMS2] >> 27) & 0x1F | ((mmio[HCSPARAMS2] >> 21) & 0x1F) << 5;
    ctlr.nintrs = (mmio[HCSPARAMS1] >> 8) & 0x7FF;
    ctlr.nslots = (mmio[HCSPARAMS1] >> 0) & 0xFF;
    hp.nports = (mmio[HCSPARAMS1] >> 24) & 0xFF;

    hp.highspeed = true;
    hp.superspeed = 0;
    const port = alloc.newslice(Port, hp.nports) orelse
        return error.Enomem;
    ctlr.port = port;
    for (port, 0..) |*pp, n|
        pp.* = .{ .reg = ctlr.opr + 0x400 / 4 + n * 4 };

    var x: ?usize = null;
    while (true) {
        x = xecp(&ctlr.xhci, 2, x);
        const xp = mmio + (x orelse break);
        var n: u32 = xp[2] & 255;
        var j: u32 = (xp[2] >> 8) & 255;
        while (j != 0) : (j -= 1) {
            if (n < 1 or n > hp.nports)
                break;
            const pp = &port[n - 1];
            pp.proto = xp[0] >> 16;
            std.mem.writeInt(u32, &pp.spec, xp[1], .little);
            // DIFF: the map has 32 bits
            if (std.mem.eql(u8, &pp.spec, "USB ") and pp.proto >= 0x0300 and n <= 32)
                hp.superspeed |= @as(u32, 1) << @intCast(n - 1);
            n += 1;
        }
    }

    // DIFF: the C has this print under if(0), without the version, the
    // superspeed ports and AC64.  It is the one line a controller
    // prints when all goes well.
    print("usbxhci %llux: v%x ports %d usb3 %d slots %d intrs %d ctx %d scratch %d page %d ac64 %d\n", .{
        ctlr.xhci.base,
        mmio[CAPLENGTH] >> 16,
        hp.nports,
        @popCount(hp.superspeed),
        ctlr.nslots,
        ctlr.nintrs,
        @as(u32, 32) << ctlr.csz,
        ctlr.nscratch,
        ctlr.pagesize,
        @intFromBool((mmio[HCCPARAMS] & AC64) != 0),
    });

    const slots = alloc.newslice(?*Slot, 1 + ctlr.nslots);
    ctlr.slot = slots;
    ctlr.dcba = @ptrCast(@alignCast(dmaalloc((1 + ctlr.nslots) * @sizeOf(u64), 64, ctlr.pagesize)));
    if (ctlr.slot == null or ctlr.dcba == null)
        return error.Enomem;
    @memset(slots.?, null);
    const dcba = ctlr.dcba.?;
    // DIFF: not in the C.  Memory comes from anywhere, and a controller
    // without AC64 keeps the low half of an address only.
    if ((mmio[HCCPARAMS] & AC64) == 0 and (dma(ctlr, dcba) >> 32) != 0)
        return proc.errorf("no 64-bit addressing, memory above 4G", .{});
    if (ctlr.nscratch != 0) {
        ctlr.sba = @ptrCast(@alignCast(dmaalloc(ctlr.nscratch * 8, 64, ctlr.pagesize)));
        ctlr.sbp = dmaalloc(ctlr.nscratch * ctlr.pagesize, ctlr.pagesize, 0);
        if (ctlr.sba == null or ctlr.sbp == null)
            return error.Enomem;
        var p = ctlr.sbp.?;
        var n: usize = 0;
        while (n < ctlr.nscratch) : ({
            n += 1;
            p += ctlr.pagesize;
        }) {
            @memset(p[0..ctlr.pagesize], 0);
            ctlr.sba.?[n] = dma(ctlr, p);
        }
        dcba[0] = dma(ctlr, ctlr.sba.?);
    } else {
        dcba[0] = 0;
    }
    {
        var n: usize = 1;
        while (n <= ctlr.nslots) : (n += 1)
            dcba[n] = 0;
    }

    // MaxSlotsEn
    ctlr.opr[CONFIG] = ctlr.nslots | (ctlr.opr[CONFIG] & CONFIG_PRES);

    setrptr(ctlr.opr + DCBAAP, dma(ctlr, dcba));

    _ = try initring(ctlr, &ctlr.cr[0], 8); // 256 entries
    ctlr.cr[0].id = 0;
    ctlr.cr[0].doorbell = &ctlr.dba[0];
    setrptr(ctlr.opr + CRCR, resetring(&ctlr.cr[0]) |
        (ctlr.opr[CRCR] & CRCR_PRES));

    {
        var n: usize = 0;
        while (n < ctlr.nintrs) : (n += 1) {
            const irs = ctlr.rts + IR0 + n * 8;

            // disable interrupt
            irs[IMAN] = irs[IMAN] & (IP | IMAN_PRES);
            irs[IMOD] = 0;

            if (n >= ctlr.er.len) {
                // disable ring
                irs[ERSTSZ] = 0 | (irs[ERSTSZ] & ERSTSZ_PRES);
                continue;
            }

            // allocate and link into event ring segment table
            _ = try initring(ctlr, &ctlr.er[n], 8); // 256 entries
            const erst: [*]volatile u32 = @ptrCast(@alignCast(dmaalloc(4 * 4, 64, 0) orelse
                return error.Enomem));
            ctlr.erst[n] = erst;
            const pa = dma(ctlr, ctlr.er[n].base.?);
            erst[0] = @truncate(pa);
            erst[1] = @truncate(pa >> 32);
            erst[2] = ctlr.er[n].mask + 1;
            erst[3] = 0;

            // just one segment
            irs[ERSTSZ] = 1 | (irs[ERSTSZ] & ERSTSZ_PRES);
            setrptr(irs + ERDP, dma(ctlr, ctlr.er[n].base.?) | EHB);
            setrptr(irs + ERSTBA, dma(ctlr, erst) |
                (irs[ERSTBA] & ERSTBA_PRES));

            // enable interrupt
            irs[IMAN] = IE | (irs[IMAN] & (IP | IMAN_PRES));
        }
    }

    ctlr.uframe = 0;

    // clear status events
    coherence();
    ctlr.opr[USBSTS] = ctlr.opr[USBSTS] & (HSE | EINT | PCD | SRE | USBSTS_PRES);
    coherence();

    // turn controller on
    ctlr.opr[USBCMD] = RUNSTOP | INTE | HSEE | EWE | (ctlr.opr[USBCMD] & USBCMD_PRES);
    i = 500;
    u = ctlr.opr[USBSTS];
    while ((u & (CNR | HCH)) != 0 and i >= 0) : (i -= 1) {
        try tsleep(&up.sleep, return0, null, 10);
        u = ctlr.opr[USBSTS];
    }
    if (i < 0) print("usbxhci %llux: timeout: didnt enable: %.8ux\n", .{ ctlr.xhci.base, u });

    // wait a 100ms to see if we run into trouble
    i = 10;
    while (i >= 0) : (i -= 1) {
        try tsleep(&up.sleep, return0, null, 10);
        u = ctlr.opr[USBSTS];
        if (u & (HCH | HCE | HSE) != 0) {
            print("usbxhci %llux: wedged after enable: %.8ux\n", .{ ctlr.xhci.base, u });
            return proc.errorf("controller wedged", .{});
        }
    }

    proc.kproc("xhcirecover", recover, hp);
}

fn needrecover(arg: ?*anyopaque) bool {
    const ctlr: *Ctlr = @ptrCast(@alignCast(arg.?));
    return @as(*volatile bool, &ctlr.er[0].stopped).* or
        (ctlr.opr[USBSTS] & (HCH | HCE | HSE)) != 0;
}

/// DIFF: not in the C.  Is there an event the interrupt handler has not
/// taken?  The count of events taken so far goes to rp.
fn eventpending(ctlr: *Ctlr, rp: *u32) bool {
    const ring = &ctlr.er[0];
    const base = ring.base orelse return false;
    if (ring.ctlr != ctlr)
        return false;
    ilock(&ring.lock);
    const x = ring.rp;
    const td = base + 4 * (x & ring.mask);
    const pending = (((x >> @intCast(ring.shift)) ^ td[3]) & 1) != 0;
    iunlock(&ring.lock);
    rp.* = x;
    return pending;
}

/// DIFF: not in the C, where a controller whose interrupt never comes
/// (no MSI capability that works, a message that goes nowhere) fails
/// each command after 5 seconds and resets itself for ever, with
/// nothing said about why.  An event that is still the next one to
/// take after 20ms, three times over, was not announced: the handler
/// would have taken it within microseconds.  recover then runs the
/// handler itself, a hundred times a second, which is slow but leaves
/// the keyboard working.
fn lostintr(ctlr: *Ctlr) bool {
    const up = arch.up().?;
    var rp0: u32 = undefined;
    var rp: u32 = undefined;

    if (!eventpending(ctlr, &rp0))
        return false;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        tsleep(&up.sleep, return0, null, 20) catch {};
        if (!eventpending(ctlr, &rp) or rp != rp0)
            return false;
    }
    return true;
}

fn recover(arg: ?*anyopaque) void {
    const hp: *Hci = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(hp);
    const up = arch.up().?;

    // DIFF: while(waserror()) ; see the top of the file
    // DIFF: the C sleeps a second at a time and does nothing else here;
    // see lostintr.
    while (!needrecover(ctlr)) {
        if (ctlr.polling) {
            tsleep(&ctlr.recover, needrecover, ctlr, 10) catch {};
            poll(hp);
            continue;
        }
        tsleep(&ctlr.recover, needrecover, ctlr, 1000) catch {};
        if (!needrecover(ctlr) and lostintr(ctlr)) {
            print("usbxhci %llux: no interrupts, polling\n", .{ctlr.xhci.base});
            ctlr.polling = true;
        }
    }

    print("usbxhci %llux: need recover: USBSTS=%ux, er stopped=%d\n", .{
        ctlr.xhci.base, ctlr.opr[USBSTS], @intFromBool(ctlr.er[0].stopped),
    });

    hp.shutdown.?(hp);

    // flush all transactions and wait until all devices have
    // been detached by usbd.
    while (true) {
        ilock(&ctlr.cr[0].lock);
        ctlr.cr[0].stopped = true;
        flushring(&ctlr.cr[0]);
        iunlock(&ctlr.cr[0].lock);

        qlock(&ctlr.slotlock);
        var active: u32 = 0;
        var i: usize = 1;
        while (i <= ctlr.nslots) : (i += 1) {
            const slot = ctlr.slot.?[i] orelse continue;
            active += 1;
            var j: usize = 0;
            while (j < slot.nep) : (j += 1) {
                const ring = &slot.epr[j];
                if (ring.base == null)
                    continue;
                ilock(&ring.lock);
                ring.stopped = true;
                flushring(ring);
                iunlock(&ring.lock);
            }
        }
        if (active == 0)
            break; // keep ctlr->slotlock
        qunlock(&ctlr.slotlock);

        tsleep(&up.sleep, return0, null, 100) catch {};
    }

    qlock(&ctlr.cmdlock);
    release(ctlr);
    if (hp.init.?(hp)) |_| {} else |e| {
        print("usbxhci %llux: recovery failed: %s\n", .{ ctlr.xhci.base, proc.errtext(e) });
    }
    qunlock(&ctlr.cmdlock);
    qunlock(&ctlr.slotlock);

    proc.pexit("", true);
}

fn queuetd(r: *Ring, c: u32, s: u32, p: u64, w_: ?*Wait) void {
    const base = r.base.?;
    var td: [*]volatile u32 = undefined;

    var x = r.wp;
    r.wp +%= 1;
    if ((x & r.mask) == r.mask) {
        td = base + 4 * (x & r.mask);
        const pa = dma(r.ctlr.?, base);
        td[0] = @truncate(pa);
        td[1] = @truncate(pa >> 32);
        td[2] = 0;
        td[3] = ((~x >> @intCast(r.shift)) & 1) | (1 << 1) | TR_LINK;
        x = r.wp;
        r.wp +%= 1;
    }
    td = base + 4 * (x & r.mask);
    if (w_) |w| {
        w.er = @splat(0);
        w.ring = r;
        w.td = td;
        w.z = &arch.up().?.sleep;

        ilock(&r.lock);
        w.next = r.pending;
        r.pending = w;
        iunlock(&r.lock);
    }
    if (r.residue) |residue|
        residue[x & r.mask] = s;
    coherence();
    td[0] = @truncate(p);
    td[1] = @truncate(p >> 32);
    td[2] = s;
    td[3] = ((~x >> @intCast(r.shift)) & 1) | c;
}

const ccerrtab = blk: {
    var t: [37]?[]const u8 = @splat(null);
    t[2] = "Data Buffer Error";
    t[3] = "Babble Detected Error";
    t[4] = "USB Transaction Error";
    t[5] = "TRB Error";
    t[6] = "Stall Error";
    t[7] = "Resume Error";
    t[8] = "Bandwidth Error";
    t[9] = "No Slots Available";
    t[10] = "Invalid Stream Type";
    t[11] = "Slot Not Enabled";
    t[12] = "Endpoint Not Enabled";
    t[13] = "Short Packet";
    t[14] = "Ring Underrun";
    t[15] = "Ring Overrun";
    t[16] = "VF Event Ring Full";
    t[17] = "Parameter Error";
    t[18] = "Bandwidth Overrun Error";
    t[19] = "Context State Error";
    t[20] = "No Ping Response";
    t[21] = "Event Ring Full";
    t[22] = "Incompatible Device";
    t[23] = "Missed Service Error";
    t[24] = "Command Ring Stopped";
    t[25] = "Command Aborted";
    t[26] = "Stopped";
    t[27] = "Stoppe - Length Invalid";
    t[29] = "Max Exit Latency Too Large";
    t[31] = "Isoch Buffer Overrun";
    t[32] = "Event Lost Error";
    t[33] = "Undefined Error";
    t[34] = "Invalid Stream ID";
    t[35] = "Secondary Bandwidth Error";
    t[36] = "Split Transaction Error";
    break :blk t;
};

fn ccerrstr(cc: u32) ?[]const u8 {
    if (cc == 1 or cc == 13)
        return null;
    if (cc < ccerrtab.len) {
        if (ccerrtab[cc]) |s|
            return s;
    }
    return "???";
}

fn waitdone(a: ?*anyopaque) bool {
    const w: *volatile Wait = @ptrCast(@alignCast(a.?));
    return w.z == null;
}

fn waittd(w: *Wait, tmout_: i32) ?[]const u8 {
    const up = arch.up().?;
    const r = w.ring;
    const c = r.ctlr.?;
    var tmout = tmout_;

    coherence();
    r.doorbell.?.* = r.id;

    while (true) {
        const done: Error!void = wait: {
            if (tmout > 0) {
                tsleep(&up.sleep, waitdone, w, @intCast(tmout)) catch |e| break :wait e;
                if (!waitdone(w))
                    break :wait proc.errorf("timed out", .{});
            } else {
                while (!waitdone(w))
                    sleep(&up.sleep, waitdone, w) catch |e| break :wait e;
            }
            break :wait {};
        };
        if (done) |_| break else |_| {}

        if (r.stopped) {
            c.er[0].stopped = true;
            _ = wakeup(&c.recover);

            // wait for rescue
            tmout = 0;
            continue;
        }

        if (r == &c.cr[0])
            c.opr[CRCR] |= CA
        else
            _ = ctlrcmd(c, CR_STOPEP | (r.id << 16) | (r.slot.?.id << 24), 0, 0, null);
        r.stopped = true;

        // time to abort the transaction
        tmout = 5000;
    }
    return ccerrstr(@as(*volatile u32, &w.er[2]).* >> 24);
}

fn ctlrcmd(ctlr: *Ctlr, c: u32, s: u32, p: u64, er: ?*[4]u32) ?[]const u8 {
    var w: Wait = .{};

    qlock(&ctlr.cmdlock);
    if (needrecover(ctlr)) {
        qunlock(&ctlr.cmdlock);
        return Erecover;
    }
    if (ctlr.cr[0].base == null or ctlr.cr[0].ctlr != ctlr) {
        qunlock(&ctlr.cmdlock);
        return errmod.errstr(error.Egreg);
    }
    ctlr.cr[0].stopped = false;
    queuetd(&ctlr.cr[0], c, s, p, &w);
    const err = waittd(&w, 5000);
    qunlock(&ctlr.cmdlock);

    if (er) |e|
        e.* = @as(*volatile [4]u32, &w.er).*;

    return err;
}

fn completering(ctlr: *Ctlr, r: *Ring, er: [*]volatile u32) void {
    const base = r.base orelse return;
    if (r.ctlr != ctlr)
        return;

    const pa = (@as(u64, er[1]) << 32 | er[0]) & ~@as(u64, 15);
    ilock(&r.lock);
    var x = r.rp;
    while (@as(i32, @bitCast(r.wp -% x)) > 0) : (x +%= 1) {
        const td = base + 4 * (x & r.mask);
        if (dma(ctlr, td) == pa) {
            if (r.residue) |residue|
                residue[x & r.mask] = er[2] & 0xFFFFFF;
            r.rp = x +% 1;
            break;
        }
    }

    var wp = &r.pending;
    while (wp.*) |w| {
        if (dma(ctlr, w.td) == pa) {
            const z = w.z;

            w.er = .{ er[0], er[1], er[2], er[3] };
            wp.* = w.next;
            w.next = null;

            if (z) |rz| {
                w.z = null;
                _ = wakeup(rz);
            }
            break;
        } else {
            wp = &w.next;
        }
    }

    iunlock(&r.lock);
}

fn interrupt(_: *arch.Ureg, arg: ?*anyopaque) void {
    poll(@ptrCast(@alignCast(arg.?)));
}

/// DIFF: the body of the C's interrupt, so that recover can run it too
/// when no interrupt comes (see lostintr).  For that the event ring's
/// lock, which the C never takes, is held while events are taken.
fn poll(hp: *Hci) void {
    const ctlr = ctlrof(hp);
    const ring = &ctlr.er[0];
    var td: [*]volatile u32 = undefined;

    const base = ring.base orelse return;
    if (ring.ctlr != ctlr)
        return;

    ilock(&ring.lock);
    defer iunlock(&ring.lock);

    const irs = ctlr.rts + IR0;
    var x = irs[IMAN];
    if (x & IP != 0) irs[IMAN] = x;

    x = ring.rp;
    while (true) : ({
        ring.rp +%= 1;
        x = ring.rp;
    }) {
        td = base + 4 * (x & ring.mask);

        if ((((x >> @intCast(ring.shift)) ^ td[3]) & 1) == 0)
            break;

        switch (td[3] & 0xFC00) {
            ER_CMDCOMPL => completering(ctlr, &ctlr.cr[0], td),
            ER_TRANSFER => {
                x = td[3] >> 24;
                if (x == 0 or x > ctlr.nslots)
                    continue;
                const slots = ctlr.slot orelse continue;
                const slot = slots[x] orelse continue;
                if (slot.ctlr != ctlr)
                    continue;
                completering(ctlr, &slot.epr[((td[3] >> 16) -% 1) & 31], td);
            },
            ER_MFINDEXWRAP => {
                ctlr.uframe = (ctlr.rts[MFINDEX] & ((1 << 14) - 1)) |
                    ((ctlr.uframe +% (1 << 14)) & ~@as(u32, (1 << 14) - 1));
            },
            ER_HCE => {
                iprint("usbxhci %llux: host controller error: %ux %ux %ux %ux\n", .{
                    ctlr.xhci.base, td[0], td[1], td[2], td[3],
                });
                ctlr.er[0].stopped = true;
                _ = wakeup(&ctlr.recover);
                return;
            },
            ER_PORTSC => {},
            // ER_BWREQ, ER_DOORBELL, ER_DEVNOTE
            else => {
                iprint("usbxhci %llux: event %ud: %ux %ux %ux %ux\n", .{
                    ctlr.xhci.base, x, td[0], td[1], td[2], td[3],
                });
            },
        }
    }

    setrptr(irs + ERDP, dma(ctlr, td) | EHB);
}

fn freeslot(slot_: ?*Slot) void {
    const slot = slot_ orelse return;
    if (slot.id > 0) {
        const ctlr = slot.ctlr;
        qlock(&ctlr.slotlock);
        if (ctlr.slot) |slots| {
            if (slot.id <= ctlr.nslots and slots[slot.id] == slot) {
                _ = ctlrcmd(ctlr, CR_DISABLESLOT | (slot.id << 24), 0, 0, null);
                ctlr.dcba.?[slot.id] = 0;
                slots[slot.id] = null;
            }
        }
        qunlock(&ctlr.slotlock);
    }
    freering(&slot.epr[0]);
    alloc.free(slot.ibase);
    alloc.free(slot.obase);
    alloc.free(slot);
}

fn allocslot(ctlr: *Ctlr, dev: *Udev) Error!*Slot {
    var r: [4]u32 = undefined;

    const slot = alloc.new(Slot) orelse
        return error.Enomem;

    // DIFF: field by field; a Slot is too big to build on the stack.
    slot.ctlr = ctlr;
    slot.dev = dev;
    slot.nep = 0;
    slot.id = 0;
    slot.ibase = null;
    slot.obase = null;
    for (&slot.epr) |*ring|
        ring.* = .{};

    qlock(&ctlr.slotlock);
    {
        errdefer {
            qunlock(&ctlr.slotlock);
            freeslot(slot);
        }
        if (ctlr.slot == null)
            return errstr(Erecover);
        slot.ibase = @ptrCast(@alignCast(dmaalloc(@as(usize, 32 * 33) << ctlr.csz, 64, ctlr.pagesize)));
        slot.obase = @ptrCast(@alignCast(dmaalloc(@as(usize, 32 * 32) << ctlr.csz, 64, ctlr.pagesize)));
        if (slot.ibase == null or slot.obase == null)
            return error.Enomem;

        if (ctlrcmd(ctlr, CR_ENABLESLOT, 0, 0, &r)) |err|
            return errstr(err);
        slot.id = r[3] >> 24;
        if (slot.id <= 0 or slot.id > ctlr.nslots or ctlr.slot.?[slot.id] != null) {
            slot.id = 0;
            return proc.errorf("bad slot id from controller", .{});
        }
    }

    ctlr.dcba.?[slot.id] = dma(ctlr, slot.obase.?);

    ctlr.slot.?[slot.id] = slot;
    qunlock(&ctlr.slotlock);

    return slot;
}

fn setdebug(_: *Hci, _: i32) void {}

fn speedid(speed: u32) u32 {
    switch (speed) {
        Fullspeed => return 1,
        Lowspeed => return 2,
        Highspeed => return 3,
        Superspeed => return 4,
        else => return 0,
    }
}

/// initialize input control and slot context
fn initdevctx(ctlr: *Ctlr, slot: *Slot) [*]volatile u32 {
    const dev = slot.dev;

    // (input) control context
    var w = slot.ibase.?;
    zero(w, @as(usize, 2 * 32) << ctlr.csz);

    // (input) slot context
    w += @as(usize, 8) << ctlr.csz;
    w[0] = dev.routestr | speedid(dev.speed) << 20 | slot.nep << 27;
    w[1] = dev.rootport << 16;
    w[2] = 0;
    w[3] = 0;

    if (dev.nports > 0) {
        w[0] |= dev.mtt << 25 | 1 << 26; // Hub flag
        w[1] |= dev.nports << 24;
        w[2] |= dev.ttt << 16;
    }

    if (dev.tthub) |tthub| {
        if (tthub.aux) |aux| {
            const hub: *Slot = @ptrCast(@alignCast(aux));
            if (hub.dev == tthub) {
                w[0] |= hub.dev.mtt << 25;
                w[2] |= hub.id | dev.ttport << 8;
            }
        }
    }

    return slot.ibase.?;
}

fn epstop(ep: *Ep) Error!void {
    if (ep.nb == 0 or ep.dev.depth < 0)
        return;

    const io = epio(ep) orelse
        return;

    const ctlr = ctlrof(ep.hp);
    const slot: *Slot = @ptrCast(@alignCast(ep.dev.aux.?));

    if (io[OREAD].ring) |ring| {
        if (!ring.stopped) {
            _ = ctlrcmd(ctlr, CR_STOPEP | (ring.id << 16) | (slot.id << 24), 0, 0, null);
            ring.stopped = true;
        }
    }
    if (io[OWRITE].ring) |ring| {
        if (!ring.stopped) {
            _ = ctlrcmd(ctlr, CR_STOPEP | (ring.id << 16) | (slot.id << 24), 0, 0, null);
            ring.stopped = true;
        }
    }
}

fn epclose(ep: *Ep) Error!void {
    if (ep.dev.depth < 0)
        return;

    const io = epio(ep) orelse
        return;
    ep.aux = null;

    const ctlr = ctlrof(ep.hp);

    if (ep.nb > 0 and (io[OREAD].ring != null or io[OWRITE].ring != null)) {
        const slot: *Slot = @ptrCast(@alignCast(ep.dev.aux.?));

        // (input) control context
        var w = initdevctx(ctlr, slot);
        w[1] = 1; // modify slot context (for nep)
        if (io[OREAD].ring) |ring| {
            w[0] |= @as(u32, 1) << @intCast(ring.id);
            if (ring.id == slot.nep)
                slot.nep -= 1;
        }
        if (io[OWRITE].ring) |ring| {
            w[0] |= @as(u32, 1) << @intCast(ring.id);
            if (ring.id == slot.nep)
                slot.nep -= 1;
        }

        // find largest index still in use
        while (slot.nep > 1 and slot.epr[slot.nep - 1].base == null)
            slot.nep -= 1;

        // (input) slot context
        w += @as(usize, 8) << ctlr.csz;
        w[0] = (w[0] & ~@as(u32, 0x1F << 27)) | slot.nep << 27;

        // (input) ep context
        w += @as(usize, (ep.nb & Epmax) * 2 * 8) << ctlr.csz;
        zero(w, @as(usize, 2 * 32) << ctlr.csz);

        _ = ctlrcmd(ctlr, CR_CONFIGEP | (slot.id << 24), 0, dma(ctlr, slot.ibase.?), null);

        freering(io[OREAD].ring);
        freering(io[OWRITE].ring);
    }
    freeb(io[OREAD].b);
    freeb(io[OWRITE].b);
    alloc.free(io);
}

fn initepctx(ctlr: *Ctlr, w: [*]volatile u32, r: *Ring, ep: *Ep) void {
    var ival: u32 = undefined;

    if (ep.dev.speed == Lowspeed or ep.dev.speed == Fullspeed) {
        ival = 3;
        while (ival < 11 and (@as(i32, 1) << @intCast(ival)) < ep.pollival) ival += 1;
    } else {
        ival = 0;
        while (ival < 15 and (@as(i32, 1) << @intCast(ival)) < ep.pollival) ival += 1;
    }
    const maxpkt: u32 = @bitCast(ep.maxpkt);
    const ntds: u32 = @bitCast(ep.ntds);
    zero(w, @as(usize, 32) << ctlr.csz);
    w[0] = ival << 16;
    w[1] = ((ep.ttype -% Tctl) | (r.id & 1) << 2) << 3 | (ntds -% 1) << 8 | maxpkt << 16;
    if (ep.ttype != Tiso)
        w[1] |= 3 << 1;
    const pa = dma(ctlr, r.base.?) | 1;
    w[2] = @truncate(pa);
    w[3] = @truncate(pa >> 32);
    w[4] = 2 *% maxpkt;
    if (ep.ttype == Tintr or ep.ttype == Tiso)
        w[4] |= (maxpkt *% ntds) << 16;
}

fn initisoio(io: *Epio, ep: *Ep) void {
    const ring = io.ring orelse
        return;
    io.rp0 = ring.wp;
    io.frame0 = 0;
    io.frame = 0;
    io.period = @as(u32, @bitCast(ep.pollival)) <<
        (3 * @as(u5, @intFromBool(ep.dev.speed == Fullspeed or ep.dev.speed == Lowspeed)));
    if (ring.id & 1 != 0) {
        ring.residue = alloc.snewslice(u32, ring.mask + 1);
        @memset(ring.residue.?, 0);
        io.incr = 0;
        io.tdsz = @bitCast(ep.maxpkt *% ep.ntds);
    } else {
        io.incr = @truncate(@as(u64, @bitCast(@divTrunc((@as(i64, ep.hz) * io.period) << 8, 8000))));
        io.tdsz = ((io.incr +% 255) >> 8) *% @as(u32, @bitCast(ep.samplesz));
    }
    io.b = allocb(@as(usize, ring.mask + 1) * io.tdsz);
}

fn initep(ep: *Ep) Error!void {
    const io = epio(ep).?;
    const ctlr = ctlrof(ep.hp);
    const slot: *Slot = @ptrCast(@alignCast(ep.dev.aux.?));

    // (input) control context
    var w = initdevctx(ctlr, slot);
    w[1] = 1; // update slot (for nep, hub)
    if (ep.nb == 0) {
        w[1] |= 2; // update ep0 (for packet size)

        // (input) ep context 0
        w += @as(usize, 16) << ctlr.csz;
        io[OWRITE].ring = &slot.epr[0];
        initepctx(ctlr, w, &slot.epr[0], ep);

        if (ctlrcmd(ctlr, CR_EVALCTX | (slot.id << 24), 0, dma(ctlr, slot.ibase.?), null)) |err|
            return errstr(err);

        // if this is a hub, the HUB, TTT and MTT fields
        // are only updated with the Configure Endpoint
        // command.
        //
        // DIFF: the C sends one command, Configure Endpoint in place
        // of Evaluate Context for a hub, with the slot and ep0 flags
        // both set.  Configure Endpoint must not have the ep0 flag
        // (xHCI 4.6.6: A1 shall be 0, the ep0 context is ignored), and
        // QEMU answers such a command with TRB Error, so no hub behind
        // its controller ever attaches.  Here ep0 is evaluated as for
        // any device, and a hub's slot is then configured with the
        // slot flag alone.
        //
        // Only the C's form is known to work on real controllers, so
        // one that refuses the proper command is given that.
        if (ep.dev.nports > 0) {
            slot.ibase.?[1] = 1;
            if (ctlrcmd(ctlr, CR_CONFIGEP | (slot.id << 24), 0, dma(ctlr, slot.ibase.?), null)) |err1| {
                slot.ibase.?[1] = 3;
                if (ctlrcmd(ctlr, CR_CONFIGEP | (slot.id << 24), 0, dma(ctlr, slot.ibase.?), null)) |_| {
                    print("usbxhci %llux: hub slot %d: %s\n", .{ ctlr.xhci.base, slot.id, err1 });
                    return errstr(err1);
                }
            }
        }
        return;
    }

    io[OREAD].ring = null;
    io[OWRITE].ring = null;
    errdefer {
        freering(io[OWRITE].ring);
        io[OWRITE].ring = null;
        freering(io[OREAD].ring);
        io[OREAD].ring = null;
    }
    const cw = w;
    if (ep.mode != OREAD) {
        io[OWRITE].ring = &slot.epr[(ep.nb & Epmax) * 2 - 1];
        const ring = try initring(ctlr, io[OWRITE].ring.?, 8);
        ring.id = (ep.nb & Epmax) * 2;
        if (ring.id > slot.nep)
            slot.nep = ring.id;
        ring.slot = slot;
        ring.doorbell = &ctlr.dba[slot.id];
        ring.ctx = slot.obase.? + (@as(usize, ring.id * 8) << ctlr.csz);
        cw[1] |= @as(u32, 1) << @intCast(ring.id);
    }
    if (ep.mode != OWRITE) {
        io[OREAD].ring = &slot.epr[(ep.nb & Epmax) * 2];
        const ring = try initring(ctlr, io[OREAD].ring.?, 8);
        ring.id = (ep.nb & Epmax) * 2 + 1;
        if (ring.id > slot.nep)
            slot.nep = ring.id;
        ring.slot = slot;
        ring.doorbell = &ctlr.dba[slot.id];
        ring.ctx = slot.obase.? + (@as(usize, ring.id * 8) << ctlr.csz);
        cw[1] |= @as(u32, 1) << @intCast(ring.id);
    }

    // (input) slot context
    w += @as(usize, 8) << ctlr.csz;
    w[0] = (w[0] & ~@as(u32, 0x1F << 27)) | slot.nep << 27;

    // (input) ep context
    w += @as(usize, (ep.nb & Epmax) * 2 * 8) << ctlr.csz;
    if (io[OWRITE].ring) |ring|
        initepctx(ctlr, w, ring, ep);

    w += @as(usize, 8) << ctlr.csz;
    if (io[OREAD].ring) |ring|
        initepctx(ctlr, w, ring, ep);

    if (ctlrcmd(ctlr, CR_CONFIGEP | (slot.id << 24), 0, dma(ctlr, slot.ibase.?), null)) |err|
        return errstr(err);

    if (ep.ttype == Tiso) {
        initisoio(&io[OWRITE], ep);
        initisoio(&io[OREAD], ep);
    }
}

fn devclose(dev: *Udev) void {
    freeslot(@ptrCast(@alignCast(dev.aux)));
}

fn epopen(ep: *Ep) Error!void {
    const ctlr = ctlrof(ep.hp);

    if (ep.dev.depth < 0)
        return;
    if (needrecover(ctlr))
        return errstr(Erecover);
    const io = alloc.newslice(Epio, 2) orelse
        return error.Enomem;
    io[0] = .{};
    io[1] = .{};
    ep.aux = io.ptr;
    errdefer epclose(ep) catch {};
    const dev = ep.dev;
    if (dev.aux) |aux| {
        const slot: *Slot = @ptrCast(@alignCast(aux));
        if (slot.dev == dev) {
            try initep(ep);
            return;
        }
    }

    // first open has to be control endpoint
    if (ep.nb != 0)
        return error.Egreg;

    const slot = try allocslot(ctlr, dev);
    errdefer freeslot(slot);

    // allocate control ep 0 ring
    io[OWRITE].ring = &slot.epr[0];
    const ring = try initring(ctlr, &slot.epr[0], 4);
    ring.id = 1;
    slot.nep = 1;
    ring.slot = slot;
    ring.doorbell = &ctlr.dba[slot.id];
    ring.ctx = slot.obase.? + (@as(usize, 8) << ctlr.csz);

    // (input) control context
    var w = initdevctx(ctlr, slot);
    w[1] = 3; // adding slot and ep0

    // (input) ep context 0
    w += @as(usize, 16) << ctlr.csz;
    initepctx(ctlr, w, ring, ep);

    if (ctlrcmd(ctlr, CR_ADDRESSDEV | (slot.id << 24), 0, dma(ctlr, slot.ibase.?), null)) |err|
        return errstr(err);

    // (output) slot context
    w = slot.obase.?;

    if (((w[3] >> 27) & 0x1F) < 2)
        return proc.errorf("xhci did not set device address", .{});

    dev.addr = w[3] & 0xFF;
    if (dev.addr == 0 or dev.addr > Devmax) {
        dev.addr = 0;
        return proc.errorf("xhci returned invalid device address", .{});
    }

    dev.aux = slot;
}

fn isoread(ep: *Ep, a: []u8) Error!usize {
    var p = a.ptr;
    var n = a.len;

    const io = &epio(ep).?[OREAD];
    qlock(&io.qlock);
    defer qunlock(&io.qlock);
    const mu = io.period;
    const ctlr = ctlrof(ep.hp);
    if (needrecover(ctlr))
        return errstr(Erecover);

    const ring = io.ring.?;
    const residue = ring.residue.?;
    var i = io.frame0;
    while (@as(i32, @bitCast(ring.rp -% io.rp0)) > 0 and n > 0) : (i +%= 1) {
        if ((io.rp0 & ring.mask) == ring.mask)
            io.rp0 +%= 1;
        const left: i32 = @bitCast(io.tdsz -% residue[io.rp0 & ring.mask]);
        if (left > 0) {
            var m: usize = @intCast(left);
            var d = io.b.?.rp + @as(usize, i & ring.mask) * io.tdsz;
            d += io.nleft;
            // DIFF: the C trusts nleft to be less than what arrived
            m -|= io.nleft;
            if (n < m) {
                @memcpy(p[0..n], d[0..n]);
                io.nleft += @intCast(n);
                p += n;
                break;
            }
            @memcpy(p[0..m], d[0..m]);
            p += m;
            n -= m;

            if (ep.uframes == 1)
                n = 0;
        }
        io.nleft = 0;
        io.rp0 +%= 1;
    }
    io.frame0 = i;

    i = io.frame;
    while (true) : (i +%= 1) {
        const m: i32 = @bitCast(ring.wp -% io.rp0);
        if (m <= 0) {
            i = (80 +% uframe(ctlr)) / mu;
            io.frame0 = i;
            io.rp0 = ring.wp;
            io.nleft = 0;
        } else if (@as(u32, @bitCast(m + 1)) >= ring.mask)
            break;
        const d = io.b.?.rp + @as(usize, i & ring.mask) * io.tdsz;
        queuetd(ring, TR_ISOCH | ((i *% mu / 8) & 0x7ff) << 20 | TR_IOC, io.tdsz, dma(ctlr, d), null);
    }
    io.frame = i;

    ring.doorbell.?.* = ring.id;

    return @intFromPtr(p) - @intFromPtr(a.ptr);
}

fn isowrite(ep: *Ep, a: []const u8) Error!usize {
    const up = arch.up().?;
    var p = a.ptr;
    var n = a.len;

    const io = &epio(ep).?[OWRITE];
    qlock(&io.qlock);
    defer qunlock(&io.qlock);
    const mu = io.period;
    const ctlr = ctlrof(ep.hp);
    const ring = io.ring.?;
    // the interrupt handler moves rp
    const rp: *volatile u32 = &ring.rp;

    var i = io.frame;
    while (true) : (i +%= 1) {
        while (true) {
            if (needrecover(ctlr))
                return errstr(Erecover);
            const m: i32 = @bitCast(ring.wp -% rp.*);
            if (m <= 0)
                i = (80 +% uframe(ctlr)) / mu;
            if (@as(u32, @bitCast(m +% 1)) < ring.mask)
                break;

            ring.doorbell.?.* = ring.id;
            try tsleep(&up.sleep, return0, null, 5);
        }
        var m: usize = ((io.incr +% ((i *% io.incr) & 255)) >> 8) *% @as(u32, @bitCast(ep.samplesz));
        var d = io.b.?.rp + @as(usize, i & ring.mask) * io.tdsz;
        // DIFF: the C trusts nleft to be less than the packet
        m -|= io.nleft;
        d += io.nleft;
        if (n < m) {
            @memcpy(d[0..n], p[0..n]);
            p += n;
            io.nleft += @intCast(n);
            break;
        }
        @memcpy(d[0..m], p[0..m]);
        p += m;
        n -= m;
        m += io.nleft;
        d -= io.nleft;
        io.nleft = 0;
        queuetd(ring, TR_ISOCH | ((i *% mu / 8) & 0x7ff) << 20 | TR_IOC, @intCast(m), dma(ctlr, d), null);
    }
    io.frame = i;

    while (rp.* != ring.wp) {
        var d: i32 = @divTrunc(@as(i32, @bitCast(i *% mu -% uframe(ctlr))), 8);
        d -= @divTrunc(ep.sampledelay *% 1000, ep.hz);
        if (d < 5)
            break;

        ring.doorbell.?.* = ring.id;
        try tsleep(&up.sleep, return0, null, @intCast(d));
        if (needrecover(ctlr))
            return errstr(Erecover);
    }

    return @intFromPtr(p) - @intFromPtr(a.ptr);
}

fn unstall(ep: *Ep, r: *Ring) ?[]const u8 {
    switch (r.ctx.?[0] & 7) {
        2, // halted
        4, // error
        => ep.clrhalt = true,
        else => {},
    }
    if (ep.clrhalt) {
        ep.clrhalt = false;
        if (ctlrcmd(r.ctlr.?, CR_RESETEP | (r.id << 16) | (r.slot.?.id << 24), 0, 0, null)) |err|
            return err;
        r.stopped = true;
    }
    if (r.stopped) {
        if (ctlrcmd(r.ctlr.?, CR_SETTRDQP | (r.id << 16) | (r.slot.?.id << 24), 0, resetring(r), null)) |err|
            return err;
        r.stopped = false;
    }
    if (r.wp -% r.rp >= r.mask)
        return "Ring Full";
    return null;
}

/// DIFF: the C's (uintptr)p <= KZERO; see the top of the file.
fn isuaddr(p: [*]const u8) bool {
    return @intFromPtr(p) < arch.mem.USTKTOP;
}

fn epread(ep: *Ep, va: []u8) Error!usize {
    var w: Wait = .{};

    if (ep.dev.depth < 0)
        return error.Egreg;

    const p = va.ptr;
    var n = va.len;
    if (ep.ttype == Tctl) {
        const io = &epio(ep).?[OREAD];
        qlock(&io.qlock);
        defer qunlock(&io.qlock);
        const b = io.b orelse return 0;
        if (BLEN(b) == 0)
            return 0;
        if (n > BLEN(b))
            n = BLEN(b);
        @memcpy(p[0..n], b.rp[0..n]);
        b.rp += n;
        return n;
    } else if (ep.ttype == Tiso)
        return isoread(ep, va);

    if (isuaddr(p)) {
        const b = allocb(n);
        defer freeb(b);
        n = try epread(ep, b.rp[0..n]);
        @memcpy(p[0..n], b.rp[0..n]);
        return n;
    }

    const ctlr = ctlrof(ep.hp);
    const io = &epio(ep).?[OREAD];
    qlock(&io.qlock);
    defer qunlock(&io.qlock);

    if (unstall(ep, io.ring.?)) |err|
        return errstr(err);

    queuetd(io.ring.?, TR_NORMAL | TR_IOC, @truncate(n), dma(ctlr, p), &w);
    if (waittd(&w, ep.tmout)) |err|
        return errstr(err);

    return n -| (@as(*volatile u32, &w.er[2]).* & 0xFFFFFF);
}

fn epwrite(ep: *Ep, va: []const u8) Error!usize {
    var w: [3]Wait = @splat(.{});

    if (ep.dev.depth < 0)
        return error.Egreg;

    const p = va.ptr;
    const n = va.len;
    if (ep.ttype == Tctl) {
        if (n < 8)
            return error.Eshort;

        if (p[0] == 0x00 and p[1] == 0x05)
            return n;

        const ctlr = ctlrof(ep.hp);
        const ios = epio(ep).?;
        const io = &ios[OREAD];
        const ring = ios[OWRITE].ring.?;
        qlock(&io.qlock);
        defer qunlock(&io.qlock);
        errdefer {
            ilock(&ring.lock);
            ring.pending = null;
            iunlock(&ring.lock);
        }
        if (io.b) |b| {
            freeb(b);
            io.b = null;
        }
        const len: u32 = GET2(p + 6);
        const dir: u32 = @intFromBool((p[0] & usb.Rd2h) != 0);
        if (len > 0) {
            const b = allocb(len);
            io.b = b;
            if (dir == 0) { // out
                if (n - 8 < len)
                    return error.Eshort;
                @memcpy(b.wp[0..len], p[8..][0..len]);
            } else {
                @memset(b.wp[0..len], 0);
                b.wp += len;
            }
        }
        if (unstall(ep, ring)) |err|
            return errstr(err);

        queuetd(ring, TR_SETUPSTAGE | (if (len > 0) 2 + dir else 0) << 16 | TR_IDT | TR_IOC, 8, p[0] | @as(u64, p[1]) << 8 | @as(u64, GET2(p + 2)) << 16 |
            @as(u64, GET2(p + 4) | len << 16) << 32, &w[0]);
        if (len > 0) {
            queuetd(ring, TR_DATASTAGE | dir << 16 | TR_IOC, len, dma(ctlr, io.b.?.rp), &w[1]);
        }
        queuetd(ring, TR_STATUSSTAGE | @as(u32, @intFromBool(len == 0 or dir == 0)) << 16 | TR_IOC, 0, 0, &w[2]);

        if (waittd(&w[0], ep.tmout)) |err|
            return errstr(err);
        if (len > 0) {
            if (waittd(&w[1], ep.tmout)) |err|
                return errstr(err);
            if (dir != 0) {
                const b = io.b.?;
                const resid: usize = @as(*volatile u32, &w[1].er[2]).* & 0xFFFFFF;
                if (resid > BLEN(b))
                    b.wp = b.rp
                else
                    b.wp -= resid;
            }
        }
        if (waittd(&w[2], ep.tmout)) |err|
            return errstr(err);

        return n;
    } else if (ep.ttype == Tiso)
        return isowrite(ep, va);

    if (isuaddr(p)) {
        const b = allocb(n);
        defer freeb(b);
        @memcpy(b.wp[0..n], p[0..n]);
        return epwrite(ep, b.wp[0..n]);
    }

    const ctlr = ctlrof(ep.hp);
    const io = &epio(ep).?[OWRITE];
    qlock(&io.qlock);
    defer qunlock(&io.qlock);

    if (unstall(ep, io.ring.?)) |err|
        return errstr(err);

    queuetd(io.ring.?, TR_NORMAL | TR_IOC, @truncate(n), dma(ctlr, p), &w[0]);
    if (waittd(&w[0], ep.tmout)) |err|
        return errstr(err);

    return n;
}

fn seprintep(_: []u8, _: *Ep) usize {
    return 0;
}

fn portstatus(hp: *Hci, port: u32) u32 {
    const ctlr = ctlrof(hp);

    const ports = ctlr.port orelse return 0;
    if (needrecover(ctlr))
        return 0;

    var ps: u32 = 0;
    const psc = ports[port - 1].reg[PORTSC];
    if (psc & CCS != 0) ps |= usb.HPpresent;
    if (psc & PED != 0) ps |= usb.HPenable;
    if (psc & OCA != 0) ps |= usb.HPovercurrent;
    if (psc & PR != 0) ps |= usb.HPreset;

    if (port <= 32 and (hp.superspeed & (@as(u32, 1) << @intCast(port - 1))) != 0) {
        ps |= psc & (PLS | PP);
        if (psc & CSC != 0) ps |= 1 << (0 + 16);
        if (psc & OCC != 0) ps |= 1 << (3 + 16);
        if (psc & PRC != 0) ps |= 1 << (4 + 16);
        if (psc & WRC != 0) ps |= 1 << (5 + 16);
        if (psc & PLC != 0) ps |= 1 << (6 + 16);
        if (psc & CEC != 0) ps |= 1 << (7 + 16);
    } else {
        if ((ps & usb.HPreset) == 0) {
            switch ((psc >> 10) & 15) {
                1 => {
                    // full speed
                },
                2 => ps |= usb.HPslow,
                3 => ps |= usb.HPhigh,
                else => {},
            }
        }
        if (psc & PP != 0) ps |= usb.HPpower;
        if (psc & CSC != 0) ps |= usb.HPstatuschg;
        if (psc & PRC != 0) ps |= usb.HPchange;
    }

    return ps;
}

const RW1S: u32 = PR | WPR;
const RW1CS: u32 = PED | CSC | PEC | WRC | OCC | PRC | PLC | CEC;

fn portenable(hp: *Hci, port: u32, on: bool) void {
    const ctlr = ctlrof(hp);

    const ports = ctlr.port orelse return;
    if (on or needrecover(ctlr))
        return;
    const portsc: *volatile u32 = &ports[port - 1].reg[PORTSC];
    portsc.* = (portsc.* & ~(RW1CS | RW1S)) | PED;
}

fn portreset(hp: *Hci, port: u32, on: bool) void {
    const ctlr = ctlrof(hp);

    const ports = ctlr.port orelse return;
    if (!on or needrecover(ctlr))
        return;
    const portsc: *volatile u32 = &ports[port - 1].reg[PORTSC];
    portsc.* = (portsc.* & ~(RW1CS | RW1S)) | PR;
}

fn bhportreset(hp: *Hci, port: u32, on: bool) void {
    const ctlr = ctlrof(hp);

    const ports = ctlr.port orelse return;
    if (!on or needrecover(ctlr))
        return;
    const portsc: *volatile u32 = &ports[port - 1].reg[PORTSC];
    portsc.* = (portsc.* & ~(RW1CS | RW1S)) | WPR;
}

fn portpower(hp: *Hci, port: u32, on: bool) void {
    const ctlr = ctlrof(hp);

    const ports = ctlr.port orelse return;
    if (needrecover(ctlr))
        return;
    const portsc: *volatile u32 = &ports[port - 1].reg[PORTSC];
    if (on)
        portsc.* = (portsc.* & ~(RW1CS | RW1S | PP)) | PP
    else
        portsc.* = (portsc.* & ~(RW1CS | RW1S | PP));
}

fn physaddr(va: usize) u64 {
    return arch.paddr(va);
}

pub fn xhcialloc(mmio: [*]volatile u32, base: u64, size: u64) ?*Xhci {
    const ctlr = alloc.new(Ctlr) orelse {
        print("usbxhci %llux: no memory for controller\n", .{base});
        return null;
    };
    ctlr.* = .{ .xhci = .{
        .mmio = mmio,
        .base = base,
        .size = size,

        .dmaaddr = physaddr,
    } };

    return &ctlr.xhci;
}

pub fn xhcilinkage(hp: *Hci, ctlr: *Xhci) void {
    hp.isa.port = ctlr.base;
    hp.aux = ctlr;

    hp.init = xhciinit;
    hp.shutdown = xhcishutdown;

    hp.interrupt = interrupt;
    hp.epopen = epopen;
    hp.epstop = epstop;
    hp.epclose = epclose;
    hp.epread = epread;
    hp.epwrite = epwrite;
    hp.seprintep = seprintep;
    hp.devclose = devclose;
    hp.portenable = portenable;
    hp.portreset = portreset;
    hp.bhportreset = bhportreset;
    hp.portpower = portpower;
    hp.portstatus = portstatus;

    hp.debug = setdebug;
    hp.isa.type = "xhci";

    ctlr.active = hp;
}

pub fn usbxhcilink() void {}
