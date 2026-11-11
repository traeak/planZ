//! intel/amd ahci sata controller
//! copyright © 2007-10 coraid, inc.
//! from 9/pc/sdiahci.c and 9/pc/ahci.h (advanced host controller
//! interface (sata), © 2007-9 coraid, inc)
//!
//! It lives in port/ because it needs nothing but PCI and memory-mapped
//! registers (see "Portability rules" in PLAN.md).
//!
//! DIFF:
//!   - no LEDs.  port/led.c, the Ledport in each Drive, the enclosure
//!     management (Aenc, Aledmsg, ahciencinit, ahciencreset, esbenc,
//!     blink, blinkesb, ledstate, the led tables), ahciledr/ahciledw and
//!     the "led" file, the ialed kproc and the "ledprint" topctl switch
//!     are left out.  The enclosure capability bits are still printed by
//!     iartopctl.
//!   - Controllers are matched by class code alone (mass storage, SATA,
//!     AHCI programming interface) whatever the vendor; the C refuses a
//!     vendor it does not list.  Dropped with the vendor table, since
//!     the baseline is 2011+ UEFI firmware that hands the controller
//!     over in AHCI mode:
//!       * Tich and iasetupahci: the Intel ICH5..PCH list and the code
//!         that switches such a controller from IDE to AHCI mode
//!         (command block decode off, GHC.AE, the write to the ports
//!         implemented register, config registers 0x90 and 0x92).  An
//!         Intel controller is a plain "ahci" one here, also by name in
//!         the boot message and in sdctl ("ich" in 9front).
//!       * Tesb (Intel 63xxESB): it differs only in its LEDs.
//!       * sbsetupahci: rewriting the class code of an ATI SB600/SB700
//!         or AMD Hudson controller left in IDE mode.
//!     Kept, being a line or two each: ATI/AMD (vendor 1002) controllers
//!     are Tsb600 (transfers limited to 255 sectors, an ATAPI error
//!     quirk); JMicron and ALi are Tjmicron (interface-fatal bit
//!     ignored); the VIA 3349 is taken whatever its class code says.
//!   - Interrupts are messages (MSI).  intrenable does that; nothing
//!     changes here, but a controller with neither MSI nor MSI-X runs
//!     only on the missed-interrupt poll of the iasata kproc (every
//!     256ms, and only for the first controller's first drive, as in C).
//!   - iainterrupt(nil, c), the poll for missed interrupts, is
//!     iaintr(c, true); the interrupt handler calls iaintr(c, false).
//!   - Errors.  `if(waserror()) return; tsleep` is `tsleep catch {}`;
//!     `while(waserror());` in satakproc is `catch continue`.  The
//!     `while(waserror()) if(interrupt){...}` of io() is a loop around
//!     sleep.  fisreqchk's error(Eio) for a command that is not 16 bytes
//!     is the status SDeio (ataio returns a status; devsd makes it Eio).
//!     forcestate, iawctl and iawtopctl return errors.  ahcibio returns
//!     -1 where the C does; only scsibio (ATAPI) can return an error
//!     through it.
//!   - Aportc, the "redundant ptr to port and portm", is not stored in
//!     the Drive but made when wanted (Drive.portc()) and passed by
//!     value.
//!   - The anonymous members are named: Drive.lock, Ctlr.lock,
//!     Aportm.qlock, Aportm.rendez, Aportm.sfis.
//!   - Registers (Ahba, Aport) and what the controller writes in memory
//!     (the command header and the received-fis area) are reached
//!     through volatile pointers.
//!   - iarctl and iartopctl follow SDifc: they write at the start of a
//!     slice and return the count.  A link speed number above 3 prints
//!     as "?" instead of indexing past the modes table.
//!   - iapnp frees the SDev when it skips a controller after allocating
//!     it; the C leaks it.  The static Ctlr is cleared bytewise instead
//!     of by assignment, which would build a 40K temporary on an 8K
//!     stack.
//!   - iawctl answers Ebadctl to an empty command instead of looking at
//!     f[0].
//!   - There is no NCQ in the C driver and none here: one command at a
//!     time per port, in slot 0.
//!
//!   - ahcibio fails a transfer whose io() status is SDcheck (the drive
//!     reported an error).  The C looks only for SDeio and SDretry, so
//!     after printing "i/o error" it counts the sectors as transferred
//!     and a read returns whatever was in the buffer.
//!   - Real hardware.  None of this is in the C:
//!       * Missing interrupts.  io() and ahciwait sleep 10ms at a time
//!         and look at the controller in between (io) or at the command
//!         issue register (ahciwait); the C sleeps until the interrupt
//!         or, in io(), until the iasata kproc's poll every 256ms.
//!         iaenable handles what the ports raised before interrupts were
//!         enabled: a controller that sends a message only when its
//!         interrupt status goes from zero to non-zero would otherwise
//!         never send one.  "no interrupts; polling" is printed for a
//!         controller whose polls find work before any interrupt came.
//!       * ahciidle waits for the fis engine (FR) to stop after clearing
//!         FRE; the C reads back the bit it has just cleared.
//!       * With staggered spin-up (CAP.SSS) ahciconfigdrive gives a port
//!         that detects nothing 200ms, not 1.4s.
//!       * A port multiplier or enclosure (by signature) is reported and
//!         left alone; the C sends it IDENTIFY.
//!       * iaonline waits at most Onlineto ms for a drive that has a link
//!         but does not come ready; the C waits for ever.
//!       * A controller without 64-bit addressing (CAP.S64A) is not
//!         given memory above 4GiB: such a port is left alone and such a
//!         transfer fails.
//!       * The unit count is the number of ports that fit in the
//!         registers' BAR, not the number implemented.
//!       * A failed packet command prints "i/o error" only with aprint
//!         on: for an ATAPI drive it is the normal answer to TEST UNIT
//!         READY with no medium.  "slow reset" is printed always.

const std = @import("std");
const arch = @import("../arch.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const portdat = @import("portdat.zig");
const errmod = @import("error.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const pci = @import("pci.zig");
const parse = @import("parse.zig");
const netif = @import("netif.zig");
const devsd = @import("devsd.zig");
const sdscsi = @import("sdscsi.zig");
const fis = @import("fis.zig");
const p9 = @import("print.zig");
const fmt = @import("fmt");

const print = p9.print;
const panic = p9.panic;

const Error = proc.Error;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Rendez = portdat.Rendez;
const Cmdbuf = parse.Cmdbuf;
const Pcidev = pci.Pcidev;
const SDev = devsd.SDev;
const SDunit = devsd.SDunit;
const SDreq = devsd.SDreq;
const SDifc = devsd.SDifc;
const SDok = devsd.SDok;
const SDcheck = devsd.SDcheck;
const SDeio = devsd.SDeio;
const SDretry = devsd.SDretry;
const SDtimeout = devsd.SDtimeout;
const SDnostatus = devsd.SDnostatus;
const SDwrite = devsd.SDwrite;
const Sfis = fis.Sfis;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const wakeup = proc.wakeup;
const delay = arch.delay;
const microdelay = arch.microdelay;

const ASerr = fis.ASerr;
const ASdrq = fis.ASdrq;
const ASdrdy = fis.ASdrdy;
const ASbsy = fis.ASbsy;
const Efatal = fis.Efatal;
const Eidnf = fis.Eidnf;
const Dlba = fis.Dlba;
const Dllba = fis.Dllba;
const Dpower = fis.Dpower;
const Dnop = fis.Dnop;
const Datapi = fis.Datapi;
const Ppkt = fis.Ppkt;
const Pdma = fis.Pdma;
const Pprotom = fis.Pprotom;
const Pspinup = fis.Pspinup;
const Pidready = fis.Pidready;
const Ffeat = fis.Ffeat;

//
// from 9/pc/ahci.h
//

// pci configuration
const Abar = 5;

// ahci memory configuration
//
// 0000-0023    generic host control
// 0024-009f    reserved
// 00a0-00ff    vendor specific.
// 0100-017f    port 0
// ...
// 1080-1100    port 31

// cap bits: supported features
const H64a: u32 = 1 << 31; // 64-bit addressing
const Hncq: u32 = 1 << 30; // ncq
const Hsntf: u32 = 1 << 29; // snotification reg.
const Hmps: u32 = 1 << 28; // mech pres switch
const Hss: u32 = 1 << 27; // staggered spinup
const Halp: u32 = 1 << 26; // aggressive link pm
const Hal: u32 = 1 << 25; // activity led
const Hclo: u32 = 1 << 24; // command-list override
const Hiss: u32 = 1 << 20; // for interface speed
const Ham: u32 = 1 << 18; // ahci-mode only
const Hpm: u32 = 1 << 17; // port multiplier
const Hfbs: u32 = 1 << 16; // fis-based switching
const Hpmb: u32 = 1 << 15; // multiple-block pio
const Hssc: u32 = 1 << 14; // slumber state
const Hpsc: u32 = 1 << 13; // partial-slumber state
const Hncs: u32 = 1 << 8; // n command slots
const Hcccs: u32 = 1 << 7; // coal
const Hems: u32 = 1 << 6; // enclosure mgmt.
const Hxs: u32 = 1 << 5; // external sata
const Hnp: u32 = 1 << 0; // n ports

// ghc bits
const Hae: u32 = 1 << 31; // enable ahci
const Hie: u32 = 1 << 1; // " interrupts
const Hhr: u32 = 1 << 0; // hba reset

// cap2 bits
const Apts: u32 = 1 << 2; // automatic partial to slumber
const Nvmp: u32 = 1 << 1; // nvmhci present; nvram
const Boh: u32 = 1 << 0; // bios/os handoff supported

// bios bits
const Bos: u32 = 1 << 0;
const Oos: u32 = 1 << 1;

// emctl bits
const Pm: u32 = 1 << 27; // port multiplier support
const Alhd: u32 = 1 << 26; // activity led hardware driven
const Xonly: u32 = 1 << 25; // rx messages not supported
const Smb: u32 = 1 << 24; // single msg buffer; rx limited
const Esgpio: u32 = 1 << 19; // sgpio messages supported
const Eses2: u32 = 1 << 18; // ses-2 supported
const Esafte: u32 = 1 << 17; // saf-te supported
const Elmt: u32 = 1 << 16; // led msg types support
const Emrst: u32 = 1 << 9; // reset all em logic
const Tmsg: u32 = 1 << 8; // transmit message
const Mr: u32 = 1 << 0; // message rx'd
const Emtype: u32 = Esgpio | Eses2 | Esafte | Elmt;

const Ahba = extern struct {
    cap: u32,
    ghc: u32,
    isr: u32,
    pi: u32, // ports implemented
    ver: u32,
    ccc: u32, // coaleasing control
    cccports: u32,
    emloc: u32,
    emctl: u32,
    cap2: u32,
    bios: u32,
};

const Acpds: u32 = 1 << 31; // cold port detect status
const Atfes: u32 = 1 << 30; // task file error status
const Ahbfs: u32 = 1 << 29; // hba fatal
const Ahbds: u32 = 1 << 28; // hba error (parity error)
const Aifs: u32 = 1 << 27; // interface fatal  §6.1.2
const Ainfs: u32 = 1 << 26; // interface error (recovered)
const Aofs: u32 = 1 << 24; // too many bytes from disk
const Aipms: u32 = 1 << 23; // incorrect prt mul status
const Aprcs: u32 = 1 << 22; // PhyRdy change status Pxserr.diag.n
const Adpms: u32 = 1 << 7; // mechanical presence status
const Apcs: u32 = 1 << 6; // port connect  diag.x
const Adps: u32 = 1 << 5; // descriptor processed
const Aufs: u32 = 1 << 4; // unknown fis diag.f
const Asdbs: u32 = 1 << 3; // set device bits fis received w/ i bit set
const Adss: u32 = 1 << 2; // dma setup
const Apio: u32 = 1 << 1; // pio setup fis
const Adhrs: u32 = 1 << 0; // device to host register fis

const IEM: u32 = Acpds | Atfes | Ahbds | Ahbfs | Ahbds | Aifs | Ainfs | Aprcs | Apcs | Adps |
    Aufs | Asdbs | Adss | Adhrs;
const Ifatal: u32 = Ahbfs | Ahbds | Aifs;

// serror bits
const SerrX: u32 = 1 << 26; // exchanged
const SerrF: u32 = 1 << 25; // unknown fis
const SerrT: u32 = 1 << 24; // transition error
const SerrS: u32 = 1 << 23; // link sequence
const SerrH: u32 = 1 << 22; // handshake
const SerrC: u32 = 1 << 21; // crc
const SerrD: u32 = 1 << 20; // not used by ahci
const SerrB: u32 = 1 << 19; // 10-tp-8 decode
const SerrW: u32 = 1 << 18; // comm wake
const SerrI: u32 = 1 << 17; // phy internal
const SerrN: u32 = 1 << 16; // phyrdy change

const ErrE: u32 = 1 << 11; // internal
const ErrP: u32 = 1 << 10; // ata protocol violation
const ErrC: u32 = 1 << 9; // communication
const ErrT: u32 = 1 << 8; // transient
const ErrM: u32 = 1 << 1; // recoverd comm
const ErrI: u32 = 1 << 0; // recovered data integrety

const ErrAll: u32 = ErrE | ErrP | ErrC | ErrT | ErrM | ErrI;
const SerrAll: u32 = SerrX | SerrF | SerrT | SerrS | SerrH | SerrC | SerrD | SerrB | SerrW |
    SerrI | SerrN | ErrAll;
const SerrBad: u32 = 0x7f << 19;

// cmd register bits
const Aicc: u32 = 1 << 28; // interface communcations control. 4 bits
const Aasp: u32 = 1 << 27; // aggressive slumber & partial sleep
const Aalpe: u32 = 1 << 26; // aggressive link pm enable
const Adlae: u32 = 1 << 25; // drive led on atapi
const Aatapi: u32 = 1 << 24; // device is atapi
const Apste: u32 = 1 << 23; // automatic slumber to partial cap
const Afbsc: u32 = 1 << 22; // fis-based switching capable
const Aesp: u32 = 1 << 21; // external sata port
const Acpd: u32 = 1 << 20; // cold presence detect
const Ampsp: u32 = 1 << 19; // mechanical pres.
const Ahpcp: u32 = 1 << 18; // hot plug capable
const Apma: u32 = 1 << 17; // pm attached
const Acps: u32 = 1 << 16; // cold presence state
const Acr: u32 = 1 << 15; // cmdlist running
const Afr: u32 = 1 << 14; // fis running
const Ampss: u32 = 1 << 13; // mechanical presence switch state
const Accs: u32 = 1 << 8; // current command slot 12:08
const Afre: u32 = 1 << 4; // fis enable receive
const Aclo: u32 = 1 << 3; // command list override
const Apod: u32 = 1 << 2; // power on dev (requires cold-pres. detect)
const Asud: u32 = 1 << 1; // spin-up device;  requires ss capability
const Ast: u32 = 1 << 0; // start

const Arun: u32 = Ast | Acr | Afre | Afr;
const Apwr: u32 = Apod | Asud;

// ctl register bits
const Aipm: u32 = 1 << 8; // interface power mgmt. 3=off
const Aspd: u32 = 1 << 4;
const Adet: u32 = 1 << 0; // device detection

// sstatus register bits

// sstatus det
const Smissing: u32 = 0 << 0;
const Spresent: u32 = 1 << 0;
const Sphylink: u32 = 3 << 0;
const Sbist: u32 = 4 << 0;
const Smask: u32 = 7 << 0;

// sstatus speed
const Gmissing: u32 = 0 << 4;
const Gi: u32 = 1 << 4;
const Gii: u32 = 2 << 4;
const Giii: u32 = 3 << 4;
const Gmask: u32 = 7 << 4;

// sstatus ipm
const Imissing: u32 = 0 << 8;
const Iactive: u32 = 1 << 8;
const Isleepy: u32 = 2 << 8;
const Islumber: u32 = 6 << 8;
const Imask: u32 = 7 << 8;

const SImask: u32 = Smask | Imask;
const SSmask: u32 = Smask | Isleepy;

/// The C names scr0..scr4 and defines sstatus, sctl, serror, sactive
/// and ntf as those.
const Aport = extern struct {
    list: u32, // PxCLB must be 1kb aligned
    listhi: u32,
    fis: u32, // 256-byte aligned
    fishi: u32,
    isr: u32,
    ie: u32, // interrupt enable
    cmd: u32,
    res1: u32,
    task: u32,
    sig: u32,
    sstatus: u32, // scr0
    sctl: u32, // scr2
    serror: u32, // scr1
    sactive: u32, // scr3
    ci: u32, // command issue
    ntf: u32, // scr4
    fbs: u32,
    res2: [11]u32,
    vendor: [4]u32,
};

/// in host's memory; not memory mapped
const Afis = struct {
    base: ?[*]volatile u8 = null,
    d: ?[*]volatile u8 = null,
    p: ?[*]volatile u8 = null,
    r: ?[*]volatile u8 = null,
    u: ?[*]volatile u8 = null,
    devicebits: ?*volatile u32 = null,
};

const Lprdtl: u32 = 1 << 16; // physical region descriptor table len
const Lpmp: u32 = 1 << 12; // port multiplier port
const Lclear: u32 = 1 << 10; // clear busy on R_OK
const Lbist: u32 = 1 << 9;
const Lreset: u32 = 1 << 8;
const Lpref: u32 = 1 << 7; // prefetchable
const Lwrite: u32 = 1 << 6;
const Latapi: u32 = 1 << 5;
const Lcfl: u32 = 1 << 0; // command fis length in double words

/// in hosts memory; memory mapped
const Alist = extern struct {
    flags: u32,
    len: u32,
    ctab: u32,
    ctabhi: u32,
    reserved: [16]u8,
};

const Aprdt = extern struct {
    dba: u32,
    dbahi: u32,
    pad: u32,
    count: u32,
};

const Actab = extern struct {
    cfis: [0x40]u8,
    atapi: [0x10]u8,
    pad: [0x30]u8,
    prdt: Aprdt,

    /// The command fis as the fis functions want it: the start of
    /// the table, up to the end of the atapi packet.
    fn fisbuf(t: *Actab) []u8 {
        return @as([*]u8, @ptrCast(t))[0 .. 0x40 + 0x10];
    }
};

// DIFF: no LEDs: the enclosure message header, Aledmsg, the led bits
// and Aenc are not here.

const Ferror = 1;
const Fdone = 2;

const Aportm = struct {
    qlock: QLock = .{},
    rendez: Rendez = .{},
    flag: u8 = 0,
    sfis: Sfis = .{},
    fis: Afis = .{},
    list: ?*volatile Alist = null,
    ctab: ?*Actab = null,
    /// DIFF: the controller takes 64-bit addresses (CAP.S64A).
    dma64: bool = false,
    /// DIFF: mkalist was given memory the controller cannot address.
    baddma: bool = false,
};

/// DIFF: made by Drive.portc(), not stored.
const Aportc = struct {
    p: *volatile Aport,
    m: *Aportm,
};

//
// from 9/pc/sdiahci.c
//

fn Ticks() u32 {
    return arch.MACHP(0).ticks;
}

fn MS2TK(t: u32) u32 {
    return (t *% arch.mem.HZ) / 1000;
}

const NCtlr = 4;
const NCtlrdrv = 32;
const NDrive = NCtlr * NCtlrdrv;

const Fahdrs = 4;

// DIFF: no LEDs: Eesb

// pci space configuration
const Pmap = 0x90;
const Ppcs = 0x91;
const Prev = 0xa8;

// DIFF: Tesb and Tich are gone; see the top of the file.
const Tsb600 = 0;
const Tjmicron = 1;
const Tahci = 2;

const tname = [_][]const u8{
    "sb600",
    "jmicron",
    "ahci",
};

fn Tname(c: *const Ctlr) []const u8 {
    return tname[c.typ];
}

const Dnull = 0;
const Dmissing = 1;
const Dnew = 2;
const Dready = 3;
const Derror = 4;
const Dreset = 5;
const Doffline = 6;
const Dportreset = 7;
const Dlast = 8;

const diskstates = [Dlast][]const u8{
    "null",
    "missing",
    "new",
    "ready",
    "error",
    "reset",
    "offline",
    "portreset",
};

const DMautoneg = 0;
const DMsatai = 1;
const DMsataii = 2;
const DMsataiii = 3;
const DMlast = 4;

const modes = [DMlast][]const u8{
    "auto",
    "satai",
    "sataii",
    "sataiii",
};

/// DIFF: the C indexes modes directly, also with the controller's
/// speed field, which has room for more than it knows.
fn modename(i: u32) []const u8 {
    if (i >= modes.len)
        return "?";
    return modes[i];
}

const Htab = struct {
    bit: u32,
    name: []const u8,
};

const Drive = struct {
    lock: Lock = .{},

    ctlr: ?*Ctlr = null,
    unit: ?*SDunit = null,
    name: [10]u8 = @splat(0),
    port: ?*volatile Aport = null,
    portm: Aportm = .{},
    // DIFF: no portc (see Aportc), no LEDs (Ledport)

    drivechange: bool = false,
    nodma: bool = false,
    state: u8 = 0,

    sectors: u64 = 0,
    secsize: u32 = 0,
    totick: u32 = 0,
    lastseen: u32 = 0,
    wait: u32 = 0,
    mode: u8 = 0,
    active: u8 = 0,

    serial: [20 + 1]u8 = @splat(0),
    firmware: [8 + 1]u8 = @splat(0),
    model: [40 + 1]u8 = @splat(0),
    wwn: u64 = 0,

    info: [0x200]u16 = @splat(0),

    // ahci allows non-sequential ports.
    // to avoid this hassle, we let
    // driveno      ctlr*NCtlrdrv + unit
    // portno       nth available port
    driveno: u32 = 0,
    portno: u32 = 0,

    fn portc(d: *Drive) Aportc {
        return .{ .p = d.port.?, .m = &d.portm };
    }
};

const Ctlr = struct {
    lock: Lock = .{},

    typ: u8 = 0,
    enabled: bool = false,
    sdev: ?*SDev = null,
    pci: ?*Pcidev = null,

    mmio: usize = 0,
    hba: ?*volatile Ahba = null,
    // DIFF: no LEDs (Aenc, enctype)

    rawdrive: [NCtlrdrv]Drive = @splat(.{}),
    drive: [NCtlrdrv]?*Drive = @splat(null),
    ndrive: usize = 0,

    missirq: u32 = 0,
    /// DIFF: interrupts taken, and whether their absence was reported.
    nintr: u32 = 0,
    nointr: bool = false,
};

var iactlr: [NCtlr]Ctlr = @splat(.{});
var niactlr: usize = 0;

var iadrive: [NDrive]?*Drive = @splat(null);
var niadrive: usize = 0;

var debug: bool = false;
var prid: bool = true;
var datapi: bool = false;

// The C's dprint, idprint and aprint macros are written out as
// `if (debug) print(...)`, so that their arguments (often register
// reads) are evaluated only when wanted.

const stab = blk: {
    var t: [27]u8 = @splat(0);
    t[0] = 'i';
    t[1] = 'm';
    for ("tcpe", 8..) |ch, i| t[i] = ch;
    for ("NIWBDCHSTFX", 16..) |ch, i| t[i] = ch;
    break :blk t;
};

/// Writes the names of the bits of r at the start of buf and returns
/// that part of it.
fn serrstr(r: u32, buf: []u8) []u8 {
    var s: usize = 0;
    const e = buf.len - 3;
    var i: u5 = 0;
    while (i < stab.len and s < e) : (i += 1) {
        if (r & (@as(u32, 1) << i) != 0 and stab[i] != 0) {
            buf[s] = stab[i];
            s += 1;
            if (SerrBad & (@as(u32, 1) << i) != 0) {
                buf[s] = '*';
                s += 1;
            }
        }
    }
    return buf[0..s];
}

const ntab = "0123456789abcdef";

fn preg(reg: []const u8) void {
    var buf: [25 * 3 + 1]u8 = undefined;

    var e: usize = 0;
    for (reg) |b| {
        buf[e] = ntab[b >> 4];
        buf[e + 1] = ntab[b & 0xf];
        buf[e + 2] = ' ';
        e += 3;
    }
    buf[e] = '\n';
    e += 1;
    if (debug) print("%s", .{buf[0..e]});
}

fn dreg(s: []const u8, p: *volatile Aport) void {
    if (debug) print("%stask=%lux; cmd=%lux; ci=%lux; is=%lux\n", .{ s, p.task, p.cmd, p.ci, p.isr });
}

fn esleep(ms: u32) void {
    proc.tsleep(&arch.up().?.sleep, proc.return0, null, ms) catch {};
}

const Asleep = struct {
    p: *volatile Aport,
    i: u32,
};

fn ahciclear(v: ?*anyopaque) bool {
    const s: *Asleep = @ptrCast(@alignCast(v.?));
    return (s.p.ci & s.i) == 0;
}

/// DIFF: the C is one tsleep of ms, which without the interrupt lasts
/// the whole of it.
fn aesleep(m: *Aportm, a: *Asleep, ms: u32) void {
    var t: u32 = 0;
    while (t < ms and !ahciclear(a)) : (t += 10)
        proc.tsleep(&m.rendez, ahciclear, a, @min(10, ms - t)) catch {};
}

/// DIFF: whether the controller can address pa.
fn dmaok(m: *const Aportm, pa: u64, len: usize) bool {
    return m.dma64 or (pa + len) >> 32 == 0;
}

fn ahciwait(c: Aportc, ms: u32) i32 {
    const p = c.p;
    // DIFF: see dmaok
    if (c.m.baddma) {
        c.m.baddma = false;
        return -1;
    }
    p.ci = 1;
    var as: Asleep = .{ .p = p, .i = 1 };
    aesleep(c.m, &as, ms);
    if ((p.task & 1) == 0 and p.ci == 0)
        return 0;
    dreg("ahciwait fail/timeout ", c.p);
    return -1;
}

fn mkalist(m: *Aportm, flags_: u32, data: ?[*]u8, len: usize) *volatile Alist {
    var flags = flags_;

    const t = m.ctab.?;
    if (data != null and len > 0) {
        const pa = arch.paddr(@intFromPtr(data.?));
        if (!dmaok(m, pa, len))
            m.baddma = true; // DIFF
        const p = &t.prdt;
        p.dba = @truncate(pa);
        p.dbahi = @truncate(pa >> 32);
        p.count = 1 << 31 | (@as(u32, @intCast(len)) - 2) | 1;
        flags |= 1 << 16;
    }
    const pa = arch.paddr(@intFromPtr(t));
    const l = m.list.?;
    l.flags = flags | 0x5;
    l.len = 0;
    l.ctab = @truncate(pa);
    l.ctabhi = @truncate(pa >> 32);
    return l;
}

fn nop(pc: Aportc) i32 {
    if ((pc.m.sfis.feat & Dnop) == 0)
        return -1;
    const c = pc.m.ctab.?.fisbuf();
    _ = fis.nopfis(&pc.m.sfis, c, false);
    _ = mkalist(pc.m, Lwrite, null, 0);
    return ahciwait(pc, 3 * 1000);
}

fn setfeatures(pc: Aportc, f: u8, w: u32) i32 {
    const c = pc.m.ctab.?.fisbuf();
    _ = fis.featfis(&pc.m.sfis, c, f);
    _ = mkalist(pc.m, Lwrite, null, 0);
    return ahciwait(pc, w);
}

/// ata 7, required for sata, requires that all devices "support"
/// udma mode 5,   however sata:pata bridges allow older devices
/// which may not.  the innodisk satadom, for example allows
/// only udma mode 2.  on the assumption that actual udma is
/// taking place on these bridges, we set the highest udma mode
/// available, or pio if there is no udma mode available.
fn settxmode(pc: Aportc, f: u8) i32 {
    const c = pc.m.ctab.?.fisbuf();
    if (fis.txmodefis(&pc.m.sfis, c, f) == null)
        return 0;
    _ = mkalist(pc.m, Lwrite, null, 0);
    return ahciwait(pc, 3 * 1000);
}

fn asleep(ms: u32) void {
    if (arch.up() == null or !arch.islo())
        delay(ms)
    else
        esleep(ms);
}

fn ahciportreset(c: Aportc, mode: u32) void {
    const p = c.p;
    p.cmd &= ~(Afre | Ast);
    var i: u32 = 0;
    while (i < 500) : (i += 25) {
        if ((p.cmd & Acr) == 0)
            break;
        asleep(25);
    }
    if ((p.cmd & Apwr) != Apwr)
        p.cmd |= Apwr;
    p.sctl = 3 * Aipm | 0 * Aspd | Adet;
    delay(1);
    p.sctl = 3 * Aipm | mode * Aspd;
}

fn ahciflushcache(pc: Aportc) i32 {
    const c = pc.m.ctab.?.fisbuf();
    _ = fis.flushcachefis(&pc.m.sfis, c);
    _ = mkalist(pc.m, Lwrite, null, 0);

    if (ahciwait(pc, 60000) == -1 or pc.p.task & (1 | 32) != 0) {
        if (debug) print("ahciflushcache fail [task %lux]\n", .{pc.p.task});
        // preg(pc->m->fis.r, 20);
        return -1;
    }
    return 0;
}

fn ahciidentify0(pc: Aportc, id: *[0x200]u16) i32 {
    const t = pc.m.ctab.?;
    const c = t.fisbuf();
    @memset(id[0 .. 0x200 / 2], 0);
    _ = fis.identifyfis(&pc.m.sfis, c);
    _ = mkalist(pc.m, 0, @ptrCast(id), 0x200);
    return ahciwait(pc, 3 * 1000);
}

fn ahciidentify(pc: Aportc, id: *[0x200]u16, ss: *u32, d: []const u8) i64 {
    const m = pc.m;
    var i: u32 = 0;
    while (true) : (i += 1) {
        if (i > 5 or ahciidentify0(pc, id) != 0)
            return -1;
        const n = fis.idpuis(id);
        if (n & Pspinup != 0 and setfeatures(pc, 7, 20 * 1000) == -1)
            print("%s: puis spinup fail\n", .{d});
        if (n & Pidready != 0)
            break;
        print("%s: puis waiting\n", .{d});
    }
    const s = fis.idfeat(&m.sfis, id);
    ss.* = fis.idss(&m.sfis, id);
    if (s == -1 or (m.sfis.feat & Dlba) == 0) {
        if ((m.sfis.feat & Dlba) == 0) {
            if (debug) print("%s: no lba support\n", .{d});
        }
        return -1;
    }
    return s;
}

fn ahciquiet(a: *volatile Aport) i32 {
    a.cmd &= ~Ast;
    var i: u32 = 0;
    while (true) : (i += 50) {
        if (i >= 500)
            return -1;
        if ((a.cmd & Acr) == 0)
            break;
        asleep(50);
    }
    // stop:
    if ((a.task & (ASdrq | ASbsy)) == 0) {
        a.cmd |= Ast;
        return 0;
    }

    a.cmd |= Aclo;
    i = 0;
    while (true) : (i += 50) {
        if (i >= 500)
            return -1;
        if ((a.cmd & Aclo) == 0)
            break;
        asleep(50);
    }
    // stop1:
    // extra check
    if (debug) print("ahci: clo clear [task %lux]\n", .{a.task});
    if (a.task & ASbsy != 0)
        return -1;
    a.cmd |= Afre | Ast;
    return 0;
}

fn ahcicomreset(pc: Aportc) i32 {
    dreg("comreset ", pc.p);
    if (ahciquiet(pc.p) == -1) {
        if (debug) print("ahci: ahciquiet failed\n", .{});
        return -1;
    }
    dreg("comreset ", pc.p);

    const c = pc.m.ctab.?.fisbuf();
    _ = fis.nopfis(&pc.m.sfis, c, true);
    _ = mkalist(pc.m, Lclear | Lreset, null, 0);
    if (ahciwait(pc, 500) == -1) {
        if (debug) print("ahci: comreset1 failed\n", .{});
        return -1;
    }
    microdelay(250);
    dreg("comreset ", pc.p);

    _ = fis.nopfis(&pc.m.sfis, c, false);
    _ = mkalist(pc.m, Lwrite, null, 0);
    if (ahciwait(pc, 150) == -1) {
        if (debug) print("ahci: comreset2 failed\n", .{});
        return -1;
    }
    dreg("comreset ", pc.p);
    return 0;
}

fn ahciidle(port: *volatile Aport) i32 {
    if ((port.cmd & Arun) == 0)
        return 0;
    port.cmd &= ~Ast;
    var r: i32 = -1;
    var i: u32 = 0;
    while (i < 500) : (i += 25) {
        if ((port.cmd & Acr) == 0) {
            r = 0;
            break;
        }
        asleep(25);
    }
    // stop:
    if ((port.cmd & Afre) == 0)
        return r;
    port.cmd &= ~Afre;
    i = 0;
    while (i < 500) : (i += 25) {
        // DIFF: Afr; the C tests Afre, which it has just cleared.
        if ((port.cmd & (Afre | Afr)) == 0)
            return 0;
        asleep(25);
    }
    return -1;
}

/// §6.2.2.1  first part; comreset handled by reset disk.
///      - remainder is handled by configdisk.
///      - ahcirecover is a quick recovery from a failed command.
fn ahciswreset(pc: Aportc) i32 {
    const i = ahciidle(pc.p);
    pc.p.cmd |= Afre;
    if (i == -1)
        return -1;
    if (pc.p.task & (ASdrq | ASbsy) != 0)
        return -1;
    return 0;
}

fn ahcirecover(pc: Aportc) i32 {
    _ = ahciswreset(pc);
    pc.p.cmd |= Ast;
    if (settxmode(pc, pc.m.sfis.udma) == -1)
        return -1;
    return 0;
}

/// Zeroed memory for the controller to use; never freed.  (The C uses
/// xspanalloc, which also panics when there is none.)
fn malign(size: usize, alignment: usize) [*]u8 {
    const v = alloc.mallocalign(size, alignment, 0, 0) orelse
        panic("ahci: no memory for %lud bytes", .{size});
    @memset(v[0..size], 0);
    return v;
}

fn setupfis(f: *Afis) void {
    const base: [*]volatile u8 = malign(0x100, 0x100);
    f.base = base;
    f.d = base + 0;
    f.p = base + 0x20;
    f.r = base + 0x40;
    f.u = base + 0x60;
    f.devicebits = @ptrCast(@alignCast(base + 0x58));
}

fn ahciwakeup(c: Aportc, mode: u32) void {
    const p = c.p;
    const s: u16 = @truncate(p.sstatus);
    if ((s & Isleepy) == 0)
        return;
    if ((s & Smask) != Spresent) {
        if (debug) print("ahci: slumbering drive missing [ss %.3ux]\n", .{s});
        return;
    }
    ahciportreset(c, mode);
    if (debug) print("ahci: wake %.3ux -> %.3lux\n", .{ s, c.p.sstatus });
}

fn ahciconfigdrive(h: *volatile Ahba, c: Aportc, mode: u32) i32 {
    const p = c.p;
    const m = c.m;

    if (m.list == null) {
        setupfis(&m.fis);
        m.list = @ptrCast(@alignCast(malign(@sizeOf(Alist), 1024)));
        m.ctab = @ptrCast(@alignCast(malign(@sizeOf(Actab), 128)));
    }
    // DIFF: see dmaok
    m.dma64 = (h.cap & H64a) != 0;
    if (!dmaok(m, arch.paddr(@intFromPtr(m.list.?)), @sizeOf(Alist)) or
        !dmaok(m, arch.paddr(@intFromPtr(m.fis.base.?)), 0x100) or
        !dmaok(m, arch.paddr(@intFromPtr(m.ctab.?)), @sizeOf(Actab)))
        return -2;

    if (ahciidle(p) == -1) {
        if (debug) print("ahci: port not idle\n", .{});
        return -1;
    }

    var pa = arch.paddr(@intFromPtr(m.list.?));
    p.list = @truncate(pa);
    p.listhi = @truncate(pa >> 32);
    pa = arch.paddr(@intFromPtr(m.fis.base.?));
    p.fis = @truncate(pa);
    p.fishi = @truncate(pa >> 32);

    p.cmd |= Afre;

    if ((p.cmd & Apwr) != Apwr)
        p.cmd |= Apwr;

    if ((h.cap & Hss) != 0) {
        if (debug) print("ahci: spin up ... [%.3lux]\n", .{p.sstatus});
        var i: u32 = 0;
        while (i < 1400) : (i += 50) {
            if ((p.sstatus & Sbist) != 0)
                break;
            if ((p.sstatus & Smask) == Sphylink)
                break;
            // DIFF: nothing answered the spin-up's reset: an empty port.
            if (i >= 200 and (p.sstatus & Smask) == Smissing)
                break;
            asleep(50);
        }
    }

    if ((p.sstatus & SSmask) == (Isleepy | Spresent))
        ahciwakeup(c, mode);

    p.serror = SerrAll;
    p.ie = IEM;

    // we will get called again once phylink has been established
    if ((p.sstatus & Smask) != Sphylink)
        return 0;

    // disable power managment sequence from book.
    p.sctl = 3 * Aipm | mode * Aspd | 0 * Adet;
    p.cmd &= ~Aalpe;

    p.cmd |= Afre | Ast;

    return 0;
}

fn ahcienable(h: *volatile Ahba) i32 {
    h.ghc |= Hie;
    return 0;
}

fn ahcidisable(h: *volatile Ahba) i32 {
    h.ghc &= ~Hie;
    return 0;
}

fn countbits(u: u32) usize {
    var n: usize = 0;
    var i: u5 = 0;
    while (true) : (i += 1) {
        if (u & (@as(u32, 1) << i) != 0)
            n += 1;
        if (i == 31)
            break;
    }
    return n;
}

fn ahciconf(c: *Ctlr) usize {
    const h: *volatile Ahba = @ptrFromInt(c.mmio);
    c.hba = h;
    const u = h.cap;

    if ((u & Ham) == 0)
        h.ghc |= Hae;

    return countbits(h.pi);
}

fn ahcihandoff(h: *volatile Ahba) i32 {
    if ((h.cap2 & Boh) == 0)
        return 0;
    h.bios |= Oos;
    var wait: u32 = 0;
    while (wait < 2000) : (wait += 100) {
        if ((h.bios & Bos) == 0)
            return 0;
        delay(100);
    }
    print("ahci: bios handoff timed out\n", .{});
    return -1;
}

fn ahcihbareset(h: *volatile Ahba) i32 {
    h.ghc |= Hhr;
    var wait: u32 = 0;
    while (wait < 1000) : (wait += 100) {
        if ((h.ghc & Hhr) == 0)
            return 0;
        delay(100);
    }
    return -1;
}

fn dnam(d: *const Drive) []const u8 {
    if (d.unit) |u| {
        if (u.perm.name.len != 0)
            return u.perm.name;
    }
    return std.mem.sliceTo(&d.name, 0);
}

fn identify(d: *Drive) i32 {
    var oserial: [21]u8 = undefined;

    const id = &d.info;
    const s = ahciidentify(d.portc(), id, &d.secsize, dnam(d));
    if (s == -1)
        return -1;
    const osectors = d.sectors;
    @memcpy(&oserial, &d.serial);

    d.sectors = @bitCast(s);

    fis.idmove(&d.serial, id[10..], 20);
    fis.idmove(&d.firmware, id[23..], 8);
    fis.idmove(&d.model, id[27..], 40);
    d.wwn = fis.idwwn(&d.portm.sfis, id);

    const u = d.unit.?;
    @memset(&u.inquiry, 0);
    u.inquiry[2] = 2;
    u.inquiry[3] = 2;
    u.inquiry[4] = u.inquiry.len - 4;
    @memcpy(u.inquiry[8..][0..40], d.model[0..40]);

    if (osectors != d.sectors or !std.mem.eql(u8, &oserial, &d.serial)) {
        d.drivechange = true;
        d.nodma = false;
        u.sectors = 0;
    }
    return 0;
}

fn clearci(p: *volatile Aport) void {
    if (p.cmd & Ast != 0) {
        p.cmd &= ~Ast;
        p.cmd |= Ast;
    }
}

fn ignoreahdrs(d: *const Drive) bool {
    return d.portm.sfis.feat & Datapi != 0 and d.ctlr.?.typ == Tsb600;
}

/// The C's `static ulong last` in updatedrive.
var updatedrive_last: u32 = 0;

fn updatedrive(d: *Drive) void {
    var pr = true;
    var ewake = false;
    var f: u8 = 0;
    const p = d.port.?;
    var cause = p.isr;
    if (d.ctlr.?.typ == Tjmicron)
        cause &= ~Aifs;
    const serr = p.serror;
    p.isr = cause;

    if (p.ci == 0) {
        f |= Fdone;
        pr = false;
    } else if (cause & Adps != 0) {
        pr = false;
    } else if (cause & Atfes != 0) {
        f |= Ferror;
        ewake = true;
        pr = false;
    }
    if (cause & Ifatal != 0) {
        ewake = true;
        if (debug) print("%s: fatal\n", .{dnam(d)});
    }
    if (cause & Adhrs != 0) {
        if (p.task & 33 != 0) {
            if (ignoreahdrs(d) and serr & ErrE != 0)
                f |= Fahdrs;
            if (debug) print("%s: Adhrs cause %lux serr %lux task %lux\n", .{ dnam(d), cause, serr, p.task });
            f |= Ferror;
            ewake = true;
        }
        pr = false;
    }
    if (debug and p.task & 1 != 0 and updatedrive_last != cause)
        print("%s: err ca %lux serr %lux task %lux sstat %.3lux\n", .{ dnam(d), cause, serr, p.task, p.sstatus });
    if (pr) {
        if (debug) print("%s: upd %lux ta %lux\n", .{ dnam(d), cause, p.task });
    }

    if (cause & (Aprcs | Aifs) != 0) {
        const s0 = d.state;
        switch (p.sstatus & Smask) {
            Smissing => d.state = Dmissing,
            Spresent => {
                if ((p.sstatus & Imask) == Islumber)
                    d.state = Dnew
                else
                    d.state = Derror;
            },
            Sphylink => {
                // power mgnt crap for suprise removal
                p.ie |= Aprcs | Apcs; // is this required?
                d.state = Dreset;
            },
            Sbist => d.state = Doffline,
            else => {},
        }
        if (debug) print("%s: updatedrive: %s → %s [ss %.3lux]\n", .{ dnam(d), diskstates[s0], diskstates[d.state], p.sstatus });
        if (s0 == Dready and d.state != Dready) {
            if (debug) print("%s: pulled\n", .{dnam(d)});
        }
        if (d.state != Dready)
            f |= Ferror;
        if (d.state != Dready or p.ci != 0)
            ewake = true;
    }
    p.serror = serr;
    if (ewake)
        clearci(p);
    if (f != 0) {
        d.portm.flag = f;
        _ = wakeup(&d.portm.rendez);
    }
    updatedrive_last = cause;
}

fn dstatus(d: *Drive, s: u8) void {
    if (debug) print("%s: dstatus: %s → %s from pc=%p\n", .{ dnam(d), diskstates[d.state], diskstates[s], @returnAddress() });

    ilock(&d.lock);
    d.state = s;
    iunlock(&d.lock);
}

fn configdrive(d: *Drive) void {
    switch (ahciconfigdrive(d.ctlr.?.hba.?, d.portc(), d.mode)) {
        -1 => {
            dstatus(d, Dportreset);
            return;
        },
        // DIFF: see dmaok
        -2 => {
            print("%s: no 64-bit dma; ignored\n", .{dnam(d)});
            dstatus(d, Dnull);
            return;
        },
        else => {},
    }

    ilock(&d.lock);
    switch (d.port.?.sstatus & Smask) {
        Spresent => {
            if (d.state == Dnull)
                d.state = Dportreset;
        },
        Sphylink => {
            if (d.state != Dready) {
                d.wait = 0;
                d.state = Dnew;
            }
        },
        Sbist => d.state = Doffline,
        // default, Smissing
        else => d.state = Dmissing,
    }
    iunlock(&d.lock);

    if (debug) print("%s: configdrive: %s\n", .{ dnam(d), diskstates[d.state] });
}

fn resetdisk(d: *Drive) void {
    const p = d.port.?;
    const det = p.sctl & 7;
    const stat = p.sstatus & Smask;
    const state = (p.cmd >> 28) & 0xf;
    if (debug) print("%s: resetdisk [icc %ux; det %.3ux; sdet %.3ux]\n", .{ dnam(d), state, det, stat });

    ilock(&d.lock);
    if (d.state != Dready and d.state != Dnew)
        d.portm.flag |= Ferror;
    if (stat != Sphylink)
        d.state = Dportreset
    else
        d.state = Dreset;
    clearci(p); // satisfy sleep condition.
    _ = wakeup(&d.portm.rendez);
    iunlock(&d.lock);

    if (stat != Sphylink)
        return;

    qlock(&d.portm.qlock);
    if (p.cmd & Ast != 0 and ahciswreset(d.portc()) == -1)
        dstatus(d, Dportreset) // get a bigger stick.
    else
        configdrive(d);
    qunlock(&d.portm.qlock);
}

fn newdrive(d: *Drive) i32 {
    const c = d.portc();
    const m = &d.portm;

    qlock(&m.qlock);
    fis.setfissig(&m.sfis, c.p.sig);
    lose: {
        if (identify(d) == -1) {
            if (debug) print("%s: identify failure\n", .{dnam(d)});
            break :lose;
        }
        if (settxmode(c, m.sfis.udma) == -1) {
            if (debug) print("%s: can't set udma mode\n", .{dnam(d)});
            break :lose;
        }
        if (m.sfis.feat & Dpower != 0 and setfeatures(c, 0x85, 3 * 1000) == -1) {
            if (debug) print("%s: can't disable apm\n", .{dnam(d)});
            m.sfis.feat &= ~@as(u16, Dpower);
            if (ahcirecover(c) == -1)
                break :lose;
        }
        dstatus(d, Dready);
        qunlock(&m.qlock);

        var s: []const u8 = "";
        if (m.sfis.feat & Dllba != 0)
            s = "L";
        if (prid) {
            print("%s: %sLBA %,lld sectors\n", .{ dnam(d), s, d.sectors });
            print("  %s %s %s %s\n", .{
                std.mem.sliceTo(&d.model, 0),            std.mem.sliceTo(&d.firmware, 0), std.mem.sliceTo(&d.serial, 0),
                if (d.drivechange) "[newdrive]" else "",
            });
        }
        return 0;
    }

    // lose:
    if (prid) print("%s: can't be initialized\n", .{dnam(d)});
    dstatus(d, Dnull);
    qunlock(&m.qlock);
    return -1;
}

const Nms = 256;
const Mcomrwait = 1 * 1024 / Nms - 1;
const Mphywait = 2 * 1024 / Nms - 1;
const Midwait = 16 * 1024 / Nms - 1;

fn hangck(d: *Drive) void {
    if (d.active != 0 and d.totick != 0 and @as(i32, @bitCast(Ticks() -% d.totick)) > 0) {
        if (debug) print("%s: drive hung [task %lux; ci %lux; serr %lux]%s\n", .{
            dnam(d),                                 d.port.?.task, d.port.?.ci, d.port.?.serror,
            if (!d.nodma) "; disabling dma" else "",
        });
        d.nodma = true;
        d.state = Dreset;
    }
}

var olds: [NCtlr * NCtlrdrv]u16 = @splat(0);

fn doportreset(d: *Drive) void {
    qlock(&d.portm.qlock);
    ahciportreset(d.portc(), d.mode);
    qunlock(&d.portm.qlock);

    if (debug) print("ahci: portreset: %s [task %lux; ss %.3lux]\n", .{ diskstates[d.state], d.port.?.task, d.port.?.sstatus });
}

/// drive must be locked
fn statechange(d: *Drive) void {
    switch (d.state) {
        Dnull, Doffline => {
            if (d.unit) |u| {
                if (u.sectors != 0) {
                    d.sectors = 0;
                    d.drivechange = true;
                }
            }
            d.wait = 0;
        },
        Dready => d.wait = 0,
        else => {},
    }
}

fn maxmode(c: *const Ctlr) u32 {
    return (c.hba.?.cap & 0xf * Hiss) / Hiss;
}

fn checkdrive(d: *Drive, i: usize) void {
    if (!d.ctlr.?.enabled)
        return;
    if (d.driveno == 0)
        iaintr(d.ctlr.?, true); // check for missed irq's

    const port = d.port.?;
    ilock(&d.lock);
    var s: u16 = @truncate(port.sstatus);
    if (s != 0)
        d.lastseen = Ticks();
    if (s != olds[i]) {
        if (debug) print("%s: status: %.3ux -> %.3ux: %s\n", .{ dnam(d), olds[i], s, diskstates[d.state] });
        olds[i] = s;
        d.wait = 0;
    }
    hangck(d);
    // DIFF: the C's gotos out of the switch (reset, portreset) and its
    // falls from one case into the next are the steps taken after it.
    var step: enum { none, reset, resetdisk, portreset } = .none;
    switch (d.state) {
        Dnull, Dready => {},
        Dmissing, Dnew => switch (s & (Iactive | Smask)) {
            Spresent => ahciwakeup(d.portc(), d.mode),
            Smissing => {},
            Iactive | Sphylink => active: {
                if (d.unit == null)
                    break :active;
                d.wait += 1;
                if ((d.wait & Midwait) == 0) {
                    // DIFF: not only with debug on
                    print("%s: slow reset [task %lux; ss %.3ux; wait %d]\n", .{ dnam(d), port.task, s, d.wait });
                    step = .reset;
                    break :active;
                }
                s = @as(u8, @truncate(port.task));
                const sig = port.sig >> 16;
                // DIFF: the C's one test, with the signatures that are
                // not drives taken out in the middle.
                if (s == 0x7f or s & ASbsy != 0)
                    break :active;
                if (sig == 0x9669 or sig == 0xc33c) {
                    print("%s: %s; ignored\n", .{ dnam(d), if (sig == 0x9669) "port multiplier" else "enclosure" });
                    d.state = Dnull;
                    break :active;
                }
                if (sig != 0xeb14 and (s & ASdrdy) == 0)
                    break :active;
                iunlock(&d.lock);
                _ = newdrive(d);
                ilock(&d.lock);
            },
            else => {
                if (s & (Iactive | Smask) != Iactive) {
                    if (debug) print("%s: unknown status %.3ux\n", .{ dnam(d), s });
                }
                // fall through
                // case Iactive: active, no device
                d.wait += 1;
                if (d.wait & Mphywait == 0)
                    step = .reset;
            },
        },
        Doffline => {
            const w = d.wait;
            d.wait += 1;
            if (w & Mcomrwait == 0)
                step = .resetdisk;
        },
        Derror, Dreset => step = .resetdisk,
        Dportreset => step = .portreset,
        else => {},
    }
    if (step == .reset) {
        if (d.mode == 0)
            d.mode = @intCast(maxmode(d.ctlr.?))
        else
            d.mode -= 1;
        if (d.mode == DMautoneg) {
            d.wait = 0;
            d.state = Dportreset;
            step = .portreset;
        } else {
            if (debug) print("%s: reset; new mode %s\n", .{ dnam(d), modename(d.mode) });
            iunlock(&d.lock);
            resetdisk(d);
            ilock(&d.lock);
        }
    }
    if (step == .resetdisk) {
        if (debug) print("%s: reset [%s]: mode %d; status %.3ux\n", .{ dnam(d), diskstates[d.state], d.mode, s });
        iunlock(&d.lock);
        resetdisk(d);
        ilock(&d.lock);
    }
    if (step == .portreset) portreset: {
        const w = d.wait;
        d.wait += 1;
        if (w & Mcomrwait != 0)
            break :portreset;
        if (d.wait > Mcomrwait and (s & Iactive) == 0) {
            d.state = Dnull; // stuck in portreset
            break :portreset;
        }
        if (debug) print("%s: portreset [%s]: mode %d; status %.3ux\n", .{ dnam(d), diskstates[d.state], d.mode, s });
        d.portm.flag |= Ferror;
        clearci(port);
        _ = wakeup(&d.portm.rendez);
        if ((s & Smask) == Smissing) {
            d.state = Dmissing;
            break :portreset;
        }
        iunlock(&d.lock);
        doportreset(d);
        ilock(&d.lock);
    }
    statechange(d);
    iunlock(&d.lock);
}

fn satakproc(_: ?*anyopaque) void {
    while (true) {
        proc.tsleep(&arch.up().?.sleep, proc.return0, null, Nms) catch continue;
        var i: usize = 0;
        while (i < niadrive) : (i += 1)
            checkdrive(iadrive[i].?, i);
    }
}

fn iainterrupt(_: *arch.Ureg, a: ?*anyopaque) void {
    const c: *Ctlr = @ptrCast(@alignCast(a.?));
    c.nintr +%= 1; // DIFF
    iaintr(c, false);
}

/// DIFF: the C's iainterrupt; poll is its `u == 0`, a call from
/// checkdrive looking for an interrupt that never came.
fn iaintr(c: *Ctlr, poll: bool) void {
    ilock(&c.lock);
    const hba = c.hba.?;
    var cause = hba.isr;
    var i: usize = 0;
    while (cause != 0) : (i += 1) {
        const m = @as(u32, 1) << @intCast(i);
        if ((cause & m) == 0)
            continue;
        cause &= ~m;
        const d = &c.rawdrive[i];
        ilock(&d.lock);
        if (d.port) |port| {
            if (port.isr != 0 and hba.pi & m != 0)
                updatedrive(d);
        }
        hba.isr = m;
        iunlock(&d.lock);
    }
    if (poll and i > 0)
        c.missirq +%= 1;
    // DIFF: say so once if no interrupt has ever come.
    const pr = c.missirq >= 3 and c.nintr == 0 and !c.nointr;
    if (pr)
        c.nointr = true;
    iunlock(&c.lock);
    if (pr)
        print("%s: ahci: no interrupts; polling\n", .{c.sdev.?.namestr()});
}

// DIFF: no LEDs.  Here the C has ahciencreset, the led tables,
// ledstate, blink, esbbits, blinkesb, ahciledr, ahciledw and ledkproc.

fn waitready(d: *Drive) i32 {
    var i: u32 = 0;
    while (true) : (i += 250) {
        if (d.state == Dreset or d.state == Dportreset or d.state == Dnew)
            return 1;
        ilock(&d.lock);
        const s = d.port.?.sstatus;
        if (d.state == Dready and (s & Smask) == Sphylink) {
            iunlock(&d.lock);
            return 0;
        }
        const dt = Ticks() -% d.lastseen;
        if (d.state == Dnull or dt > 10 * 1000)
            break;
        if ((s & Imask) == 0 and dt > 1500)
            break;
        if (i >= 15 * 1000) {
            d.state = Doffline;
            iunlock(&d.lock);
            print("%s: not responding; offline\n", .{dnam(d)});
            return -1;
        }
        iunlock(&d.lock);
        esleep(250);
    }
    iunlock(&d.lock);
    return -1;
}

fn iaverify(u: *SDunit) i32 {
    const c: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));
    const d = c.drive[u.subno].?;
    ilock(&c.lock);
    ilock(&d.lock);
    if (d.unit == null) {
        d.unit = u;
        // DIFF: no LEDs: no "led" file
    }
    iunlock(&d.lock);
    iunlock(&c.lock);
    checkdrive(d, d.driveno); // c->d0 + d->driveno
    return 1;
}

fn iaonline(u: *SDunit) i32 {
    const c: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));
    const d = c.drive[u.subno].?;

    // DIFF: the C waits for ever.
    const t0 = Ticks();
    while (d.state != Dmissing and waitready(d) == 1) {
        if (Ticks() -% t0 > MS2TK(Onlineto)) {
            print("%s: not ready [%s; task %lux; ss %.3lux]\n", .{ dnam(d), diskstates[d.state], d.port.?.task, d.port.?.sstatus });
            break;
        }
        esleep(1);
    }

    if (debug) print("%s: iaonline: %s\n", .{ dnam(d), diskstates[d.state] });

    ilock(&d.lock);
    if (d.portm.sfis.feat & Datapi != 0) {
        const r = d.drivechange;
        d.drivechange = false;
        iunlock(&d.lock);
        if (r)
            _ = sdscsi.scsiverify(u);
        return sdscsi.scsionline(u);
    }
    var r: i32 = 0;
    if (d.drivechange) {
        d.drivechange = false;
        r = 2;
    } else if (d.state == Dready)
        r = 1;
    if (r != 0) {
        u.sectors = d.sectors;
        u.secsize = d.secsize;
    }
    iunlock(&d.lock);

    return r;
}

/// DIFF: how long iaonline waits for a drive to come ready, in ms.
const Onlineto = 30 * 1000;

/// The C's `static int once` in iaenable.
var iaenable_once: usize = 0;

fn iaenable(s: *SDev) i32 {
    var namebuf: [32]u8 = undefined;

    const c: *Ctlr = @ptrCast(@alignCast(s.ctlr.?));
    ilock(&c.lock);
    if (c.enabled) {
        iunlock(&c.lock);
        return 1;
    }
    if (c.ndrive == 0)
        panic("iaenable: zero s->ctlr->ndrive", .{});
    const name = fmt.snprint(&namebuf, "%s (%s)", .{ s.namestr(), s.ifc.name });
    arch.intrenable(c.pci.?.intl, iainterrupt, c, c.pci.?.tbdf, name);
    // supposed to squelch leftover interrupts here.
    _ = ahcienable(c.hba.?);
    c.enabled = true;
    iunlock(&c.lock);
    // DIFF: what the ports raised since iapnp; see the top of the file.
    iaintr(c, false);

    if (iaenable_once == 0)
        proc.kproc("iasata", satakproc, null);
    // DIFF: no LEDs: no ialed kproc after the last controller
    iaenable_once += 1;

    return 1;
}

fn iadisable(s: *SDev) i32 {
    var namebuf: [32]u8 = undefined;

    const c: *Ctlr = @ptrCast(@alignCast(s.ctlr.?));
    ilock(&c.lock);
    _ = ahcidisable(c.hba.?);
    const name = fmt.snprint(&namebuf, "%s (%s)", .{ s.namestr(), s.ifc.name });
    arch.intrdisable(c.pci.?.intl, iainterrupt, c, c.pci.?.tbdf, name);
    c.enabled = false;
    iunlock(&c.lock);
    return 1;
}

fn ahcibuild(d: *Drive, rw: bool, data: ?[*]u8, nsect: usize, lba: u64) *volatile Alist {
    const m = &d.portm;
    const c = m.ctab.?.fisbuf();
    _ = fis.rwfis(&m.sfis, c, rw, @intCast(nsect), lba);
    var flags: u32 = Lpref;
    if (rw == SDwrite)
        flags |= Lwrite;
    return mkalist(m, flags, data, nsect * d.secsize);
}

fn ahcibuildpkt(d: *Drive, r: *SDreq, data: ?[*]u8, n: usize) *volatile Alist {
    const m = &d.portm;
    const t = m.ctab.?;
    const c = t.fisbuf();

    _ = fis.atapirwfis(&m.sfis, c, r.cmd[0..r.clen], 0x2000);
    if ((n & 15) != 0 or d.nodma)
        c[Ffeat] &= ~@as(u8, 1) // use pio
    else if (c[Ffeat] & 1 != 0 and d.info[62] & (1 << 15) != 0) // dma direction
        c[Ffeat] = (c[Ffeat] & ~@as(u8, 1 << 2)) | (@as(u8, @intFromBool(!r.write)) << 2);
    var flags: u32 = Lpref | Latapi;
    if (r.write and data != null)
        flags |= Lwrite;
    return mkalist(m, flags, data, n);
}

fn ahcibuildfis(d: *Drive, r: *SDreq, data: ?[*]u8, n: usize) *volatile Alist {
    if ((r.ataproto & Pprotom) == Ppkt)
        return ahcibuildpkt(d, r, data, n);

    const m = &d.portm;
    const c = m.ctab.?.fisbuf();
    @memcpy(c[0..r.clen], r.cmd[0..r.clen]);
    var flags: u32 = Lpref;
    if (r.write or n == 0)
        flags |= Lwrite;
    return mkalist(m, flags, data, n);
}

/// Returns with d.portm locked, whatever the result.
fn lockready(d: *Drive) i32 {
    qlock(&d.portm.qlock);
    while (true) {
        const i = waitready(d);
        if (i != 1)
            return i;
        qunlock(&d.portm.qlock);
        esleep(1);
        qlock(&d.portm.qlock);
    }
}

fn flushcache(d: *Drive) i32 {
    var i: i32 = -1;
    if (lockready(d) == 0)
        i = ahciflushcache(d.portc());
    qunlock(&d.portm.qlock);
    return i;
}

fn io(d: *Drive, proto: u32, to: i32, interrupt: bool) i32 {
    switch (waitready(d)) {
        -1 => return SDeio,
        1 => return SDretry,
        else => {},
    }

    // DIFF: see dmaok
    if (d.portm.baddma) {
        d.portm.baddma = false;
        print("%s: no 64-bit dma\n", .{dnam(d)});
        return SDeio;
    }

    ilock(&d.lock);
    d.portm.flag = 0;
    iunlock(&d.lock);
    const p = d.port.?;
    p.ci = 1;

    var as: Asleep = .{ .p = p, .i = 1 };
    d.totick = 0;
    if (to > 0)
        d.totick = (Ticks() +% MS2TK(@intCast(to))) | 1; // fix fencepost
    d.active +%= 1;

    // DIFF: `while(waserror()) if(interrupt){...}` then sleep: an
    // interrupted sleep is taken up again unless the caller wants out.
    // DIFF: the sleep is 10ms at a time, with a look at the controller
    // when the interrupt has not said how the command went.
    while (true) {
        proc.tsleep(&d.portm.rendez, ahciclear, &as, 10) catch {
            if (interrupt) {
                d.active -%= 1;
                p.ci = 0;
                if (ahcicomreset(d.portc()) == -1)
                    dstatus(d, Dreset);
                return SDtimeout;
            }
            continue;
        };
        if (@as(*volatile u8, &d.portm.flag).* == 0 or !ahciclear(&as))
            iaintr(d.ctlr.?, true);
        if (ahciclear(&as))
            break;
    }

    d.active -%= 1;
    ilock(&d.lock);
    const stat = d.state;
    var flag: u32 = d.portm.flag;
    var task = p.task;
    iunlock(&d.lock);

    var rv: i32 = SDok;
    if (proto & Ppkt != 0 and stat == Dready) {
        rv = @intCast(task >> (8 + 4) & 0xf);
        flag &= ~@as(u32, Fahdrs);
        flag |= Fdone;
    } else if (task & (Efatal << 8) != 0 or (task & (ASbsy | ASdrq) != 0 and stat == Dready)) {
        p.ci = 0;
        _ = ahcirecover(d.portc());
        task = p.task;
        flag &= ~@as(u32, Fdone); // either an error or do-over
    }
    if (flag == 0) {
        print("%s: retry\n", .{dnam(d)});
        return SDretry;
    }
    if (flag & (Fahdrs | Ferror) != 0) {
        // DIFF: not for a packet command unless aprint is on
        if ((task & Eidnf) == 0 and (proto & Ppkt == 0 or datapi))
            print("%s: i/o error %ux\n", .{ dnam(d), task });
        return SDcheck;
    }
    return rv;
}

fn iariopkt(r: *SDreq, d: *Drive) i32 {
    const cmd = &r.cmd;
    if (datapi) print("%s: %.2ux %.2ux %c %d %p\n", .{
        dnam(d),                     cmd[0], cmd[2],
        "rw"[@intFromBool(r.write)], r.dlen, @intFromPtr(r.data),
    });

    r.rlen = 0;

    // prevent iaonline() to hang forever by timing out
    // inquiry and capacity commands after 5 seconds.
    var to: i32 = 30 * 1000;
    switch (cmd[0]) {
        0x9e => if (cmd[1] == 0x10) {
            to = 5 * 1000;
        },
        0x25, 0x12 => to = 5 * 1000,
        else => {},
    }

    var try_: u32 = 0;
    while (try_ < 10) : (try_ += 1) {
        qlock(&d.portm.qlock);
        const l = ahcibuildpkt(d, r, r.data, r.dlen);
        r.status = io(d, Ppkt, to, false);
        switch (r.status) {
            SDeio => {
                qunlock(&d.portm.qlock);
                return SDeio;
            },
            SDretry => {
                qunlock(&d.portm.qlock);
                continue;
            },
            else => {},
        }
        r.rlen = l.len;
        qunlock(&d.portm.qlock);
        return SDok;
    }
    print("%s: bad disk\n", .{dnam(d)});
    r.status = SDcheck;
    return SDcheck;
}

fn ahcibio(u: *SDunit, lun: u32, write: bool, a: []u8, count_: usize, lba_: u64) Error!isize {
    const c: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));
    const d = c.drive[u.subno].?;
    if (d.portm.sfis.feat & Datapi != 0)
        return sdscsi.scsibio(u, lun, write, a, count_, lba_);

    var max: usize = 128;
    if (d.portm.sfis.feat & Dllba != 0) {
        max = 8192; // ahci maximum
        if (c.typ == Tsb600)
            max = 255; // errata
    }
    const rw = if (write) SDwrite else devsd.SDread;
    var data = a.ptr;
    var count = count_;
    var lba = lba_;
    if (debug) print("%s: bio: %llud %c %lud %p\n", .{ dnam(d), lba, "rw"[@intFromBool(rw)], count, @intFromPtr(data) });

    var try_: u32 = 0;
    while (try_ < 10) {
        var n = count;
        if (n > max)
            n = max;
        qlock(&d.portm.qlock);
        _ = ahcibuild(d, rw, data, n, lba);
        const status = io(d, Pdma, 5000, false);
        qunlock(&d.portm.qlock);
        switch (status) {
            SDeio, SDcheck => return -1, // DIFF: SDcheck; see the top of the file
            SDretry => {
                try_ += 1;
                continue;
            },
            else => {},
        }
        try_ = 0;
        count -= n;
        lba += n;
        data += n * u.secsize;
        if (count == 0)
            return @intCast(@intFromPtr(data) - @intFromPtr(a.ptr));
    }
    print("%s: bad disk\n", .{dnam(d)});
    return -1;
}

fn iario(r: *SDreq) i32 {
    const u = r.unit;
    const c: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));
    const d = c.drive[u.subno].?;
    if (d.portm.sfis.feat & Datapi != 0)
        return iariopkt(r, d);
    const cmd = &r.cmd;

    if (cmd[0] == 0x35 or cmd[0] == 0x91) {
        if (flushcache(d) == 0)
            return devsd.sdsetsense(r, SDok, 0, 0, 0);
        return devsd.sdsetsense(r, SDcheck, 3, 0xc, 2);
    }

    var i = devsd.sdfakescsi(r);
    if (i != SDnostatus) {
        r.status = i;
        return i;
    }

    var lba: u64 = undefined;
    var count: u32 = undefined;
    var rw: bool = undefined;
    i = devsd.sdfakescsirw(r, &lba, &count, &rw);
    if (i != SDnostatus)
        return i;
    // sdfakescsirw has answered already if there is no data.
    const data = r.data.?[0 .. @as(usize, count) * u.secsize];
    const n = ahcibio(u, r.lun, r.write, data, count, lba) catch -1;
    if (n == -1)
        return SDeio;
    r.rlen = @intCast(n);
    return SDok;
}

const bogusrfis = blk: {
    var t: [16]u8 = @splat(0);
    t[fis.Ftype] = 0x34;
    t[fis.Fioport] = 0x40;
    t[fis.Fstatus] = 0x50;
    t[fis.Fdev] = 0xa0;
    break :blk t;
};

fn sdr0(d: *Drive) void {
    const c = d.portm.fis.r.?;
    for (bogusrfis, 0..) |b, i| c[i] = b;
    arch.coherence();
}

fn sdr(r: *SDreq, d: *Drive, st_: i32) i32 {
    var st = st_;

    if ((r.ataproto & Pprotom) == Ppkt) {
        const t = d.port.?.task;
        if (t & ASerr != 0)
            st = @intCast(t >> (8 + 4) & 0xf);
    }
    const c = d.portm.fis.r.?;
    for (r.cmd[0..16], 0..) |*b, i| b.* = c[i];
    r.status = st;
    if (st == SDcheck)
        st = SDok;
    return st;
}

fn fisreqchk(f: *Sfis, r: *SDreq) i32 {
    if ((r.ataproto & Pprotom) == Ppkt)
        return SDnostatus;
    // handle oob requests;
    //    restrict & sanitize commands
    if (r.clen != 16)
        return SDeio; // DIFF: error(Eio)
    if (r.cmd[0] == 0xf0) {
        fis.sigtofis(f, &r.cmd);
        r.status = SDok;
        return SDok;
    }
    r.cmd[0] = 0x27;
    r.cmd[1] = 0x80;
    r.cmd[7] |= 0xa0;
    return SDnostatus;
}

fn iaataio(r: *SDreq) i32 {
    const u = r.unit;
    const c: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));
    const d = c.drive[u.subno].?;

    r.status = fisreqchk(&d.portm.sfis, r);
    if (r.status != SDnostatus)
        return r.status;
    r.rlen = 0;
    sdr0(d);
    var try_: u32 = 0;
    while (try_ < 10) : (try_ += 1) {
        qlock(&d.portm.qlock);
        const l = ahcibuildfis(d, r, r.data, r.dlen);
        r.status = io(d, r.ataproto & Pprotom, -1, true);
        switch (r.status) {
            SDtimeout => {
                qunlock(&d.portm.qlock);
                return devsd.sdsetsense(r, SDcheck, 11, 0, 6);
            },
            SDeio => {
                qunlock(&d.portm.qlock);
                return SDeio;
            },
            SDretry => {
                qunlock(&d.portm.qlock);
                continue;
            },
            else => {},
        }
        r.rlen = if ((r.ataproto & Pprotom) == Ppkt) l.len else r.dlen;
        const st = sdr(r, d, r.status);
        qunlock(&d.portm.qlock);
        return st;
    }
    print("%s: bad disk\n", .{dnam(d)});
    r.status = SDeio;
    return SDeio;
}

// DIFF: iasetupahci, sbsetupahci (switching a controller into ahci
// mode) and esbenc, ahciencinit (no LEDs) are not here.

/// DIFF: any vendor will do if the class code says ahci; see the top
/// of the file for what the C does per vendor.
fn didtype(p: *Pcidev) ?u8 {
    var typ: u8 = Tahci;
    switch (p.vid) {
        0x1002 => typ = Tsb600,
        0x1106 => {
            // unconfirmed report that the programming
            // interface is set incorrectly.
            if (p.did == 0x3349)
                return Tahci;
        },
        0x197b, 0x10b9 => typ = Tjmicron,
        else => {},
    }
    if (p.ccrb == pci.Pcibcstore and p.ccru == 6 and p.ccrp == 1)
        return typ;
    return null;
}

/// The C's `static int done` in iapnp.
var iapnp_done: bool = false;

fn iapnp() ?*SDev {
    if (iapnp_done)
        return null;
    iapnp_done = true;

    if (arch.getconf("*noahci") != null)
        return null;

    if (arch.getconf("*ahcidebug") != null) {
        debug = true;
        datapi = true;
    }

    @memset(&olds, 0xffff);
    var pp: ?*Pcidev = null;
    while (true) {
        pp = pci.pcimatch(pp, 0, 0);
        const p = pp orelse break;
        const typ = didtype(p) orelse continue;
        var io_ = p.mem[Abar].bar;
        if (io_ == 0 or (io_ & 1) != 0 or p.mem[Abar].size < 0x180)
            continue;
        const size: usize = @intCast(p.mem[Abar].size);
        io_ &= ~@as(u64, 0xf);
        if (niactlr == NCtlr) {
            print("iapnp: %s: too many controllers\n", .{tname[typ]});
            break;
        }
        const c = &iactlr[niactlr];
        const s = alloc.new(SDev) orelse {
            print("iapnp: %s: can't allocate SDev\n", .{tname[typ]});
            break;
        };
        // DIFF: not `*c = zero`, which would go through the stack;
        // every field of a Ctlr starts as zero bits.
        @memset(std.mem.asBytes(c), 0);
        c.typ = typ;
        c.mmio = arch.vmap(io_, size) orelse {
            print("%s: can't map %llux\n", .{ Tname(c), io_ });
            alloc.free(s); // DIFF: the C leaks it
            continue;
        };
        c.pci = p;

        s.* = .{ .ifc = &sdiahciifc, .ctlr = c, .idno = 'E' };
        c.sdev = s;

        pci.pcienable(p);
        _ = ahcihandoff(@ptrFromInt(c.mmio));
        // DIFF: no iasetupahci for intel
        var nunit = ahciconf(c);
        if (nunit < 1) {
            arch.vunmap(c.mmio, size);
            pci.pcidisable(p);
            alloc.free(s); // DIFF: the C leaks it
            continue;
        }
        c.ndrive = nunit;
        s.nunit = nunit;
        const hba = c.hba.?;

        // map the drives -- they don't all need to be enabled.
        var n: u32 = 0;
        var i: usize = 0;
        while (i < NCtlrdrv) : (i += 1) {
            const d = &c.rawdrive[i];
            d.portno = @intCast(i);
            d.driveno = ~@as(u32, 0);
            d.sectors = 0;
            d.serial[0] = ' ';
            d.ctlr = c;
            if ((hba.pi & @as(u32, 1) << @intCast(i)) == 0)
                continue;
            const off = 0x100 + 0x80 * i;
            if ((off + 0x80) > size)
                continue;
            d.port = @ptrFromInt(c.mmio + off);
            d.driveno = n;
            n += 1;
            const nm = fmt.snprint(d.name[0 .. d.name.len - 1], "iahci%d.%d", .{ niactlr, i });
            d.name[nm.len] = 0;
            c.drive[d.driveno] = d;
            iadrive[niadrive + d.driveno] = d;
        }
        // DIFF: the ports that fit, which is what c.drive holds.
        if (n == 0) {
            arch.vunmap(c.mmio, size);
            pci.pcidisable(p);
            alloc.free(s);
            continue;
        }
        nunit = n;
        c.ndrive = nunit;
        s.nunit = nunit;
        pci.pcisetbme(p);
        i = 0;
        while (i < n) : (i += 1) {
            c.drive[i].?.mode = DMautoneg;
            configdrive(c.drive[i].?);
        }
        // DIFF: no LEDs: ahciencinit

        niadrive += n;
        niactlr += 1;
        devsd.sdadddevs(s);
        i = (hba.cap >> 21) & 1;
        print("#S/%s: %s: sata-%s with %d ports\n", .{
            s.namestr(),               Tname(c),
            if (i != 0) "II" else "I", nunit,
        });
    }
    return null;
}

const ctab = [_]Htab{
    .{ .bit = Aasp, .name = "asp" },
    .{ .bit = Aalpe, .name = "alpe " },
    .{ .bit = Adlae, .name = "dlae" },
    .{ .bit = Aatapi, .name = "atapi" },
    .{ .bit = Apste, .name = "pste" },
    .{ .bit = Afbsc, .name = "fbsc" },
    .{ .bit = Aesp, .name = "esp" },
    .{ .bit = Acpd, .name = "cpd" },
    .{ .bit = Ampsp, .name = "mpsp" },
    .{ .bit = Ahpcp, .name = "hpcp" },
    .{ .bit = Apma, .name = "pma" },
    .{ .bit = Acps, .name = "cps" },
    .{ .bit = Acr, .name = "cr" },
    .{ .bit = Afr, .name = "fr" },
    .{ .bit = Ampss, .name = "mpss" },
    .{ .bit = Apod, .name = "pod" },
    .{ .bit = Asud, .name = "sud" },
    .{ .bit = Ast, .name = "st" },
};

fn capfmt(s: *fmt.Fmt, t: []const Htab, cap: u32) void {
    for (t) |h| {
        if (cap & h.bit != 0)
            fmt.fmtprint(s, "%s ", .{h.name});
    }
}

fn iarctl(u: *SDunit, buf: []u8) usize {
    var ebuf: [32]u8 = undefined;
    var s: fmt.Fmt = .{ .buf = buf };

    const c: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr orelse return 0));
    const d = c.drive[u.subno].?;
    const o = d.port.?;

    if (d.state == Dready) {
        fmt.fmtprint(&s, "model\t%s\n", .{std.mem.sliceTo(&d.model, 0)});
        fmt.fmtprint(&s, "serial\t%s\n", .{std.mem.sliceTo(&d.serial, 0)});
        fmt.fmtprint(&s, "firm\t%s\n", .{std.mem.sliceTo(&d.firmware, 0)});
        if (d.wwn != 0)
            fmt.fmtprint(&s, "wwn\t%ullx\n", .{d.wwn});
        fmt.fmtprint(&s, "flag\t", .{});
        s.n += fis.pflag(buf[s.n..], &d.portm.sfis);
        fmt.fmtprint(&s, "udma\t%d\n", .{d.portm.sfis.udma});
    } else {
        fmt.fmtprint(&s, "no disk present [%s]\n", .{diskstates[d.state]});
    }
    const serr = serrstr(o.serror, ebuf[0 .. ebuf.len - 1]);
    fmt.fmtprint(&s, "reg\ttask %lux cmd %lux serr %lux %s ci %lux is %lux " ++
        "sig %lux sstatus %.3lux\n", .{
        o.task, o.cmd, o.serror, serr,
        o.ci,   o.isr, o.sig,    o.sstatus,
    });
    fmt.fmtprint(&s, "cmd\t", .{});
    capfmt(&s, &ctab, o.cmd);
    fmt.fmtprint(&s, "\n", .{});
    fmt.fmtprint(&s, "mode\t%s %s\n", .{ modename(d.mode), modename(maxmode(c)) });
    fmt.fmtprint(&s, "geometry %llud %d\n", .{ d.sectors, d.secsize });
    fmt.fmtprint(&s, "alignment %d %d\n", .{
        d.secsize << @truncate(d.portm.sfis.physshift), d.portm.sfis.physalign,
    });
    fmt.fmtprint(&s, "missirq\t%ud\n", .{c.missirq});
    return s.n;
}

fn forcemode(d: *Drive, mode: []const u8) void {
    var i: u8 = 0;
    while (i < modes.len) : (i += 1) {
        if (std.mem.eql(u8, mode, modes[i]))
            break;
    }
    if (i == modes.len)
        i = 0;
    ilock(&d.lock);
    d.mode = i;
    iunlock(&d.lock);
}

fn forcestate(d: *Drive, state: []const u8) Error!void {
    var i: u8 = 0;
    while (i < diskstates.len) : (i += 1) {
        if (std.mem.eql(u8, state, diskstates[i]))
            break;
    }
    if (i == diskstates.len)
        return error.Ebadctl;
    dstatus(d, i);
}

fn runsettxmode(d: *Drive, s: []const u8) bool {
    const c = d.portc();
    const m = &d.portm;

    var i = true;
    if (lockready(d) == 0) {
        m.sfis.udma = @truncate(@as(u32, @bitCast(netif.atoi(s))));
        if (settxmode(c, m.sfis.udma) == 0)
            i = false;
    }
    qunlock(&m.qlock);
    return i;
}

fn iawctl(u: *SDunit, cmd: *Cmdbuf) Error!i32 {
    const c: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));
    const d = c.drive[u.subno].?;
    const f = cmd.f;

    if (cmd.nf < 1)
        return parse.cmderror(cmd, errmod.errstr(error.Ebadctl));
    if (std.mem.eql(u8, f[0], "mode")) {
        forcemode(d, if (cmd.nf > 1) f[1] else "satai");
    } else if (std.mem.eql(u8, f[0], "state")) {
        try forcestate(d, if (cmd.nf > 1) f[1] else "null");
    } else if (std.mem.eql(u8, f[0], "txmode")) {
        if (runsettxmode(d, if (cmd.nf > 1) f[1] else "0"))
            return parse.cmderror(cmd, "bad txmode / stuck port");
    } else {
        return parse.cmderror(cmd, errmod.errstr(error.Ebadctl));
    }
    return 0;
}

/// Writes the set bits of x as a list of ranges at the start of buf
/// and returns that part of it.
fn portr(buf: []u8, x: u32) []u8 {
    var s: fmt.Fmt = .{ .buf = buf };

    var a: i32 = -1;
    var i: i32 = 0;
    while (i < 32) : (i += 1) {
        if ((x & (@as(u32, 1) << @intCast(i))) == 0) {
            if (a != -1 and i - 1 != a)
                fmt.fmtprint(&s, "-%d", .{i - 1});
            a = -1;
            continue;
        }
        if (a == -1) {
            if (i > 0)
                fmt.fmtprint(&s, ", ", .{});
            a = i;
            fmt.fmtprint(&s, "%d", .{a});
        }
    }
    if (a != -1 and i - 1 != a)
        fmt.fmtprint(&s, "-%d", .{i - 1});
    return buf[0..s.n];
}

const htab = [_]Htab{
    .{ .bit = H64a, .name = "64a" },
    .{ .bit = Hncq, .name = "ncq" },
    .{ .bit = Hsntf, .name = "ntf" },
    .{ .bit = Hmps, .name = "mps" },
    .{ .bit = Hss, .name = "ss" },
    .{ .bit = Halp, .name = "alp" },
    .{ .bit = Hal, .name = "led" },
    .{ .bit = Hclo, .name = "clo" },
    .{ .bit = Ham, .name = "am" },
    .{ .bit = Hpm, .name = "pm" },
    .{ .bit = Hfbs, .name = "fbs" },
    .{ .bit = Hpmb, .name = "pmb" },
    .{ .bit = Hssc, .name = "slum" },
    .{ .bit = Hpsc, .name = "pslum" },
    .{ .bit = Hcccs, .name = "coal" },
    .{ .bit = Hems, .name = "ems" },
    .{ .bit = Hxs, .name = "xs" },
};

const htab2 = [_]Htab{
    .{ .bit = Apts, .name = "apts" },
    .{ .bit = Nvmp, .name = "nvmp" },
    .{ .bit = Boh, .name = "boh" },
};

const emtab = [_]Htab{
    .{ .bit = Pm, .name = "pm" },
    .{ .bit = Alhd, .name = "alhd" },
    .{ .bit = Xonly, .name = "xonly" },
    .{ .bit = Smb, .name = "smb" },
    .{ .bit = Esgpio, .name = "esgpio" },
    .{ .bit = Eses2, .name = "eses2" },
    .{ .bit = Esafte, .name = "esafte" },
    .{ .bit = Elmt, .name = "elmt" },
};

fn iartopctl(sdev: *SDev, buf: []u8) usize {
    var pr: [25]u8 = undefined;
    var s: fmt.Fmt = .{ .buf = buf };

    const c: *Ctlr = @ptrCast(@alignCast(sdev.ctlr.?));
    const h = c.hba.?;
    const cap = h.cap;
    fmt.fmtprint(&s, "sd%c ahci %s port %#p: ", .{ sdev.idno, Tname(c), @intFromPtr(h) });
    capfmt(&s, &htab, cap);
    capfmt(&s, &htab2, h.cap2);
    capfmt(&s, &emtab, h.emctl);
    const ports = portr(&pr, h.pi);
    fmt.fmtprint(&s, "iss %ld ncs %ld np %ld ghc %lux isr %lux pi %lux %s ver %lux\n", .{
        (cap >> 20) & 0xf, (cap >> 8) & 0x1f, 1 + (cap & 0x1f),
        h.ghc,             h.isr,             h.pi,
        ports,             h.ver,
    });
    return s.n;
}

fn iawtopctl(_: ?*SDev, cmd: *Cmdbuf) Error!i32 {
    const f = cmd.f;

    if (cmd.nf < 1)
        return parse.cmderror(cmd, errmod.errstr(error.Ebadctl));
    // DIFF: no LEDs: no "ledprint"
    const v: *bool = if (std.mem.eql(u8, f[0], "debug"))
        &debug
    else if (std.mem.eql(u8, f[0], "idprint"))
        &prid
    else if (std.mem.eql(u8, f[0], "aprint"))
        &datapi
    else
        return parse.cmderror(cmd, errmod.errstr(error.Ebadctl));

    switch (cmd.nf) {
        1 => v.* = !v.*,
        2 => v.* = std.mem.eql(u8, f[1], "on"),
        else => return parse.cmderror(cmd, errmod.errstr(error.Ebadarg)),
    }
    return 0;
}

// Functions the C has and nothing calls; keep the compiler reading them.
comptime {
    _ = &preg;
    _ = &nop;
    _ = &ahcihbareset;
}

pub const sdiahciifc: SDifc = .{
    .name = "ahci",

    .pnp = iapnp,
    .enable = iaenable,
    .disable = iadisable,

    .verify = iaverify,
    .online = iaonline,
    .rio = iario,
    .rctl = iarctl,
    .wctl = iawctl,

    .bio = ahcibio,
    .rtopctl = iartopctl,
    .wtopctl = iawtopctl,
    .ataio = iaataio,
};
