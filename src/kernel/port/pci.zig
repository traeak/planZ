//! PCI support code: the Pcidev structure, access to configuration
//! space, enumeration of the buses, base address registers, bridge
//! windows, capabilities, MSI and power management.
//! from 9/port/pci.c and pci.h; pcireserve and pciscaninit are the
//! portable part of pcicfginit in 9/pc/pcipc.c.
//!
//! DIFF:
//!   - Configuration access is the platform's.  In C each architecture
//!     defines pcicfgrw8, pcicfgrw16 and pcicfgrw32 (on the PC they are
//!     function pointers set to the static pcicfgrw*raw of pcipc.c).
//!     Here they are the public function pointers pcicfgrw8raw,
//!     pcicfgrw16raw and pcicfgrw32raw, which the platform sets before
//!     it scans.  Until then they read as all ones, which is what an
//!     empty slot reads as, so a scan finds nothing.  The register
//!     number is passed through unchecked, as in C (neither pci.c nor
//!     pcipc.c checks it), so the extended registers 256-4095 of ECAM
//!     can be reached; the platform's accessor rejects what it cannot
//!     address.
//!   - pcicfgr32 returns u32 and pcicfgw32 takes u32, where the C has
//!     int.  The C uses the value as a bit pattern everywhere (casts
//!     to ulong, comparison with 0xFFFFFFFF).  The 8 and 16 bit
//!     accessors keep int.  The raw accessors keep int for all three:
//!     a 32 bit read comes back as the bit pattern.
//!   - pcimaxbno lives here and is public; in C it is static in
//!     pcipc.c.  pcimaxdno starts at 31 (0 in C, where pcicfginit sets
//!     it): 31 is right for every configuration mechanism planZ has.
//!   - pcireserve and pciscaninit come from pcipc.c, because with
//!     memory-mapped configuration space nothing in them is specific
//!     to the PC.  pciscaninit is pcicfginit without finding the
//!     configuration mechanism, the PCI BIOS, the `nobios` resource
//!     assignment and interrupt routing.  pciroot is public.
//!   - no I/O port map: there is no ioalloc/ioreserve.  I/O port BARs
//!     and bridge I/O windows are read into the Pcidev as in C, but
//!     pcireserve does not reserve them and cannot assign one that
//!     the firmware left unassigned.
//!   - pcireserve cannot assign an unassigned memory BAR of a device
//!     behind a bridge: that needs upaallocwin, which arch does not
//!     have.  Marked M7.  UEFI firmware assigns them.
//!   - MSI only: nothing here routes or fixes up the INTx lines
//!     (pcirouting and the per-chipset tables of pcipc.c are not
//!     ported).  intl is still read into the Pcidev and pciipin still
//!     looks it up, since both only read.
//!   - %T: there is no fmtinstall.  tbdf(v) wraps a tbdf in a type that
//!     formats itself; print("%T", .{pci.tbdf(p.tbdf)}).  A tbdf with a
//!     negative bus type other than BUSUNKNOWN prints the type as a
//!     number; the C indexes bustypes[] out of range with it.
//!   - The anonymous structs of Pcidev (mem[], rom, ioa, mema, prefa)
//!     are one named type, Bar.
//!   - pcibusmap sorts with std.mem.sort, which is stable; qsort is
//!     not.  Its size table is a bounds-checked slice: a bus whose
//!     devices have more than six memory resources each on average
//!     (six 32 bit BARs and a ROM) overruns the table in C and
//!     panics here.
//!   - pcidevalloc initialises the Pcidev with its field defaults
//!     (all zero) instead of relying on xalloc clearing it.

const std = @import("std");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const taslock = @import("taslock.zig");
const alloc = @import("alloc.zig");
const xalloc = @import("xalloc.zig");
const p9 = @import("print.zig");

const Lock = taslock.Lock;
const print = p9.print;

// from 9/port/pci.h

// type 0 & type 1 pre-defined header
pub const PciVID = 0x00; // vendor ID
pub const PciDID = 0x02; // device ID
pub const PciPCR = 0x04; // command
pub const PciPSR = 0x06; // status
pub const PciRID = 0x08; // revision ID
pub const PciCCRp = 0x09; // programming interface class code
pub const PciCCRu = 0x0A; // sub-class code
pub const PciCCRb = 0x0B; // base class code
pub const PciCLS = 0x0C; // cache line size
pub const PciLTR = 0x0D; // latency timer
pub const PciHDT = 0x0E; // header type
pub const PciBST = 0x0F; // BIST

pub const PciBAR0 = 0x10; // base address
pub const PciBAR1 = 0x14;

pub const PciCAP = 0x34; // capabilities pointer
pub const PciINTL = 0x3C; // interrupt line
pub const PciINTP = 0x3D; // interrupt pin

// ccrb (base class code) values; controller types
pub const Pcibcpci1 = 0; // pci 1.0; no class codes defined
pub const Pcibcstore = 1; // mass storage
pub const Pcibcnet = 2; // network
pub const Pcibcdisp = 3; // display
pub const Pcibcmmedia = 4; // multimedia
pub const Pcibcmem = 5; // memory
pub const Pcibcbridge = 6; // bridge
pub const Pcibccomm = 7; // simple comms (e.g., serial)
pub const Pcibcbasesys = 8; // base system
pub const Pcibcinput = 9; // input
pub const Pcibcdock = 0xa; // docking stations
pub const Pcibcproc = 0xb; // processors
pub const Pcibcserial = 0xc; // serial bus (e.g., USB)
pub const Pcibcwireless = 0xd; // wireless
pub const Pcibcintell = 0xe; // intelligent i/o
pub const Pcibcsatcom = 0xf; // satellite comms
pub const Pcibccrypto = 0x10; // encryption/decryption
pub const Pcibcdacq = 0x11; // data acquisition & signal proc.

// ccru (sub-class code) values; common cases only
// mass storage
pub const Pciscscsi = 0; // SCSI
pub const Pciscide = 1; // IDE (ATA)

// network
pub const Pciscether = 0; // Ethernet

// display
pub const Pciscvga = 0; // VGA
pub const Pciscxga = 1; // XGA
pub const Pcisc3d = 2; // 3D

// bridges
pub const Pcischostpci = 0; // host/pci
pub const Pciscpcicpci = 1; // pci/pci

// simple comms
pub const Pciscserial = 0; // 16450, etc.
pub const Pciscmultiser = 1; // multiport serial

// serial bus
pub const Pciscusb = 3; // USB

// type 0 pre-defined header
pub const PciCIS = 0x28; // cardbus CIS pointer
pub const PciSVID = 0x2C; // subsystem vendor ID
pub const PciSID = 0x2E; // subsystem ID
pub const PciEBAR0 = 0x30; // expansion ROM base address
pub const PciMGNT = 0x3E; // burst period length
pub const PciMLT = 0x3F; // maximum latency between bursts

// type 1 pre-defined header
pub const PciPBN = 0x18; // primary bus number
pub const PciSBN = 0x19; // secondary bus number
pub const PciUBN = 0x1A; // subordinate bus number
pub const PciSLTR = 0x1B; // secondary latency timer
pub const PciIBR = 0x1C; // I/O base
pub const PciILR = 0x1D; // I/O limit
pub const PciSPSR = 0x1E; // secondary status
pub const PciMBR = 0x20; // memory base
pub const PciMLR = 0x22; // memory limit
pub const PciPMBR = 0x24; // prefetchable memory base
pub const PciPMLR = 0x26; // prefetchable memory limit
pub const PciPUBR = 0x28; // prefetchable base upper 32 bits
pub const PciPULR = 0x2C; // prefetchable limit upper 32 bits
pub const PciIUBR = 0x30; // I/O base upper 16 bits
pub const PciIULR = 0x32; // I/O limit upper 16 bits
pub const PciEBAR1 = 0x38; // expansion ROM base address
pub const PciBCR = 0x3E; // bridge control register

// type 2 pre-defined header
pub const PciCBExCA = 0x10;
pub const PciCBSPSR = 0x16;
pub const PciCBPBN = 0x18; // primary bus number
pub const PciCBSBN = 0x19; // secondary bus number
pub const PciCBUBN = 0x1A; // subordinate bus number
pub const PciCBSLTR = 0x1B; // secondary latency timer
pub const PciCBMBR0 = 0x1C;
pub const PciCBMLR0 = 0x20;
pub const PciCBMBR1 = 0x24;
pub const PciCBMLR1 = 0x28;
pub const PciCBIBR0 = 0x2C; // I/O base
pub const PciCBILR0 = 0x30; // I/O limit
pub const PciCBIBR1 = 0x34; // I/O base
pub const PciCBILR1 = 0x38; // I/O limit
pub const PciCBSVID = 0x40; // subsystem vendor ID
pub const PciCBSID = 0x42; // subsystem ID
pub const PciCBLMBAR = 0x44; // legacy mode base address

// capabilities
pub const PciCapPMG = 0x01; // power management
pub const PciCapAGP = 0x02;
pub const PciCapVPD = 0x03; // vital product data
pub const PciCapSID = 0x04; // slot id
pub const PciCapMSI = 0x05;
pub const PciCapCHS = 0x06; // compact pci hot swap
pub const PciCapPCIX = 0x07;
pub const PciCapHTC = 0x08; // hypertransport irq conf
pub const PciCapVND = 0x09; // vendor specific information
pub const PciCapPCIe = 0x10;
pub const PciCapMSIX = 0x11;
pub const PciCapSATA = 0x12;
pub const PciCapHSW = 0x0c; // hot swap

// bar bits
pub const Barioaddr = 1 << 0; // vs. memory addr
pub const Barwidthshift = 1;
pub const Barwidthmask = 3;
pub const Barwidth32 = 0;
pub const Barwidth64 = 2;
pub const Barprefetch = 1 << 3;

// command register
pub const IOen = 1 << 0;
pub const MEMen = 1 << 1;
pub const MASen = 1 << 2;
pub const MemWrInv = 1 << 4;
pub const PErrEn = 1 << 6;
pub const SErrEn = 1 << 8;

/// A base address register, an expansion ROM register or a bridge
/// window, as read from the device.
pub const Bar = struct {
    bar: u64 = 0, // base address
    size: i64 = 0,
};

pub const Pcidev = struct {
    tbdf: i32 = 0, // type+bus+device+function
    vid: u16 = 0, // vendor ID
    did: u16 = 0, // device ID

    pcr: u16 = 0,

    rid: u8 = 0,
    ccrp: u8 = 0,
    ccru: u8 = 0,
    ccrb: u8 = 0,
    cls: u8 = 0,
    ltr: u8 = 0,

    intl: u8 = 0, // interrupt line

    mem: [6]Bar = @splat(.{}),

    rom: Bar = .{}, // expansion rom bar

    ioa: Bar = .{}, // 32-bit io and memory windows
    mema: Bar = .{},

    prefa: Bar = .{}, // 64-bit prefechable memory window

    list: ?*Pcidev = null,
    link: ?*Pcidev = null, // next device on this bno

    parent: ?*Pcidev = null, // up a bus
    bridge: ?*Pcidev = null, // down a bus

    pmrb: i32 = 0, // power management register block
    msi: i32 = 0, // MSI capability register block
};

// vendor ids
pub const Vintel = 0x8086;
pub const Vmyricom = 0x14c1;
pub const Vatiamd = 0x1002;
pub const Vjmicron = 0x197b;
pub const Vmarvell = 0x1b4b;
pub const Vnvidia = 0x10de;
pub const Vrealtek = 0x10ec;

pub const MaxFNO = 7;
pub const MaxUBN = 255;

pub const BusCBUS = 0; // Corollary CBUS
pub const BusCBUSII = 1; // Corollary CBUS II
pub const BusEISA = 2; // Extended ISA
pub const BusFUTURE = 3; // IEEE Futurebus
pub const BusINTERN = 4; // Internal bus
pub const BusISA = 5; // Industry Standard Architecture
pub const BusMBI = 6; // Multibus I
pub const BusMBII = 7; // Multibus II
pub const BusMCA = 8; // Micro Channel Architecture
pub const BusMPI = 9; // MPI
pub const BusMPSA = 10; // MPSA
pub const BusNUBUS = 11; // Apple Macintosh NuBus
pub const BusPCI = 12; // Peripheral Component Interconnect
pub const BusPCMCIA = 13; // PC Memory Card International Association
pub const BusTC = 14; // DEC TurboChannel
pub const BusVL = 15; // VESA Local bus
pub const BusVME = 16; // VMEbus
pub const BusXPRESS = 17; // Express System Bus

pub fn MKBUS(t: i32, b: i32, d: i32, f: i32) i32 {
    return (t << 24) | ((b & 0xFF) << 16) | ((d & 0x1F) << 11) | ((f & 0x07) << 8);
}
pub fn BUSFNO(v: i32) i32 {
    return (v >> 8) & 0x07;
}
pub fn BUSDNO(v: i32) i32 {
    return (v >> 11) & 0x1F;
}
pub fn BUSBNO(v: i32) i32 {
    return (v >> 16) & 0xFF;
}
pub fn BUSTYPE(v: i32) i32 {
    return v >> 24;
}
pub fn BUSBDF(v: i32) i32 {
    return v & 0x00FFFF00;
}

// from 9/port/pci.c

const Pcisiz = struct {
    dev: *Pcidev,
    siz: i64,
    bar: i32,
    typ: i32,
};

/// Highest bus and device numbers to scan; the platform sets them.
pub var pcimaxbno: i32 = 255;
pub var pcimaxdno: i32 = 31;
/// The bridge above the device being accessed, for platforms whose
/// configuration access depends on it.  Valid inside the raw accessors.
pub var pciparentdev: ?*Pcidev = null;

/// Raw access to configuration space: register rno of the device tbdf,
/// read, or written with data.  A 32 bit read returns the bit pattern.
/// The platform sets these before scanning.
pub var pcicfgrw8raw: *const fn (tbdf: i32, rno: i32, data: i32, read: bool) i32 = nocfg;
pub var pcicfgrw16raw: *const fn (tbdf: i32, rno: i32, data: i32, read: bool) i32 = nocfg;
pub var pcicfgrw32raw: *const fn (tbdf: i32, rno: i32, data: i32, read: bool) i32 = nocfg;

fn nocfg(_: i32, _: i32, _: i32, _: bool) i32 {
    return -1;
}

var pcicfglock: Lock = .{};
var pcilist: ?*Pcidev = null;
var pcitail: *?*Pcidev = &pcilist;

const bustypes = [_][]const u8{
    "CBUSI",
    "CBUSII",
    "EISA",
    "FUTURE",
    "INTERN",
    "ISA",
    "MBI",
    "MBII",
    "MCA",
    "MPI",
    "MPSA",
    "NUBUS",
    "PCI",
    "PCMCIA",
    "TC",
    "VL",
    "VME",
    "XPRESS",
};

/// A tbdf that prints itself with %T (tbdffmt in C).
pub const Tbdf = struct {
    v: i32,

    pub fn fmt9(self: Tbdf, f: *fmt.Fmt) void {
        switch (f.r) {
            else => f.pad("(tbdffmt)"),

            'T' => {
                const v = self.v;
                if (v == arch.BUSUNKNOWN) {
                    f.pad("unknown");
                } else {
                    const typ = BUSTYPE(v);
                    if (typ >= 0 and typ < bustypes.len) {
                        f.print("%s.%d.%d.%d", .{ bustypes[@intCast(typ)], BUSBNO(v), BUSDNO(v), BUSFNO(v) });
                    } else {
                        f.print("%d.%d.%d.%d", .{ typ, BUSBNO(v), BUSDNO(v), BUSFNO(v) });
                    }
                }
            },
        }
    }
};

pub fn tbdf(v: i32) Tbdf {
    return .{ .v = v };
}

fn pcidevalloc() *Pcidev {
    const p: *Pcidev = @ptrFromInt(xalloc.xalloc(@sizeOf(Pcidev)) orelse
        p9.panic("pci: no memory for Pcidev", .{}));
    p.* = .{};
    return p;
}

pub fn pcidevfree(p_: ?*Pcidev) void {
    const p = p_ orelse return;

    while (p.bridge) |b|
        pcidevfree(b);

    if (p.parent) |parent| {
        var l: *?*Pcidev = &parent.bridge;
        while (l.*) |x| : (l = &x.link) {
            if (x == p) {
                l.* = p.link;
                break;
            }
        }
    }
    var l: *?*Pcidev = &pcilist;
    while (l.*) |x| : (l = &x.list) {
        if (x == p) {
            l.* = p.list;
            if (l.* == null)
                pcitail = l;
            break;
        }
    }
    // leaked
}

pub fn pcicfgr8(p: *Pcidev, rno: i32) i32 {
    taslock.ilock(&pcicfglock);
    pciparentdev = p.parent;

    const data = pcicfgrw8raw(p.tbdf, rno, 0, true);
    taslock.iunlock(&pcicfglock);

    return data;
}
pub fn pcicfgw8(p: *Pcidev, rno: i32, data: i32) void {
    taslock.ilock(&pcicfglock);
    pciparentdev = p.parent;

    _ = pcicfgrw8raw(p.tbdf, rno, data, false);
    taslock.iunlock(&pcicfglock);
}
pub fn pcicfgr16(p: *Pcidev, rno: i32) i32 {
    taslock.ilock(&pcicfglock);
    pciparentdev = p.parent;

    const data = pcicfgrw16raw(p.tbdf, rno, 0, true);
    taslock.iunlock(&pcicfglock);

    return data;
}
pub fn pcicfgw16(p: *Pcidev, rno: i32, data: i32) void {
    taslock.ilock(&pcicfglock);
    pciparentdev = p.parent;

    _ = pcicfgrw16raw(p.tbdf, rno, data, false);
    taslock.iunlock(&pcicfglock);
}
// DIFF: u32 where the C has int; see the top of the file.
pub fn pcicfgr32(p: *Pcidev, rno: i32) u32 {
    taslock.ilock(&pcicfglock);
    pciparentdev = p.parent;

    const data = pcicfgrw32raw(p.tbdf, rno, 0, true);
    taslock.iunlock(&pcicfglock);

    return @bitCast(data);
}
pub fn pcicfgw32(p: *Pcidev, rno: i32, data: u32) void {
    taslock.ilock(&pcicfglock);
    pciparentdev = p.parent;

    _ = pcicfgrw32raw(p.tbdf, rno, @bitCast(data), false);
    taslock.iunlock(&pcicfglock);
}

/// The low 32 bits of v, as the int the raw accessors take.
fn lo32(v: u64) i32 {
    return @bitCast(@as(u32, @truncate(v)));
}

/// What a register that was written with all ones reads back (size,
/// sign extended from 32 bits), with the bits that are not address
/// bits cleared; v is what the register held.  The negation of the
/// result is the size.
fn barmask(rno: i32, v: i32, size: i64) i64 {
    if (rno == PciEBAR0 or rno == PciEBAR1)
        return size & ~@as(i64, 0x7FF)
    else if (v & 1 != 0)
        return @as(i16, @truncate(size)) & ~@as(i64, 0x3)
    else
        return size & ~@as(i64, 0xF);
}

pub fn pcibarsize(p: *Pcidev, rno_: i32) i64 {
    var rno = rno_;

    taslock.ilock(&pcicfglock);
    pciparentdev = p.parent;

    var v = pcicfgrw32raw(p.tbdf, rno, 0, true);
    _ = pcicfgrw32raw(p.tbdf, rno, -1, false);
    var size: i64 = pcicfgrw32raw(p.tbdf, rno, 0, true);
    _ = pcicfgrw32raw(p.tbdf, rno, v, false);

    const io = v & 1 != 0;
    const is64 = v & 7 == 4;
    size = barmask(rno, v, size);
    if (rno != PciEBAR0 and rno != PciEBAR1 and !io) {
        if (size >= 0 and is64 and rno < PciBAR0 + 4 * (@as(i32, p.mem.len) - 1)) {
            rno += 4;
            v = pcicfgrw32raw(p.tbdf, rno, 0, true);
            _ = pcicfgrw32raw(p.tbdf, rno, -1, false);
            size |= @as(i64, pcicfgrw32raw(p.tbdf, rno, 0, true)) << 32;
            _ = pcicfgrw32raw(p.tbdf, rno, v, false);
        }
    }
    size = -%size;

    taslock.iunlock(&pcicfglock);

    if (size < 0 or (size & (size - 1)) != 0) {
        print("pcibarsize: %T invalid bar rno %#x size %#llux mask %#llux\n", .{ tbdf(p.tbdf), rno, size, -%size });
        return 0;
    }
    return size;
}

pub fn pcisetbar(p: *Pcidev, rno: i32, bar: u64) void {
    taslock.ilock(&pcicfglock);
    pciparentdev = p.parent;

    _ = pcicfgrw32raw(p.tbdf, rno, lo32(bar), false);
    if ((bar & 7) == 4 and rno >= PciBAR0 and rno < PciBAR0 + 4 * (@as(i32, p.mem.len) - 1))
        _ = pcicfgrw32raw(p.tbdf, rno + 4, lo32(bar >> 32), false);
    taslock.iunlock(&pcicfglock);
}

pub fn pcisetwin(p: *Pcidev, base: u64, limit: u64) void {
    taslock.ilock(&pcicfglock);
    pciparentdev = p.parent;

    if (base & 1 != 0) {
        _ = pcicfgrw16raw(p.tbdf, PciIBR, lo32((limit & 0xF000) | ((base & 0xF000) >> 8)), false);
        _ = pcicfgrw32raw(p.tbdf, PciIUBR, lo32((limit & 0xFFFF0000) | (base >> 16)), false);
    } else if (base & 8 != 0) {
        _ = pcicfgrw32raw(p.tbdf, PciPMBR, lo32((limit & 0xFFF00000) | ((base & 0xFFF00000) >> 16)), false);
        _ = pcicfgrw32raw(p.tbdf, PciPUBR, lo32(base >> 32), false);
        _ = pcicfgrw32raw(p.tbdf, PciPULR, lo32(limit >> 32), false);
    } else {
        _ = pcicfgrw32raw(p.tbdf, PciMBR, lo32((limit & 0xFFF00000) | ((base & 0xFFF00000) >> 16)), false);
    }
    taslock.iunlock(&pcicfglock);
}

fn pcisizcmp(_: void, aa: Pcisiz, bb: Pcisiz) bool {
    return aa.siz < bb.siz;
}

fn pcimask(v_: i64) i64 {
    var v = v_;
    var m: u64 = 1 << 63;

    while (m != 0) : (m >>= 1) {
        if (m & @as(u64, @bitCast(v)) != 0)
            break;
    }

    m -%= 1;
    if (@as(u64, @bitCast(v)) & m != 0) {
        v |= @bitCast(m);
        v +%= 1;
    }
    return v;
}

/// Work out the sizes of everything on the bus whose first device is
/// root, lay it out from *pmema and *pioa upwards and leave the ends
/// there; with wrreg, also write the addresses to the devices and
/// bridges and enable them.  Only for buses the firmware did not set
/// up: the caller must own the address space it passes in.
pub fn pcibusmap(root: ?*Pcidev, pmema: *u64, pioa: *u32, wrreg: bool) void {
    var ioa = pioa.*;
    var mema = pmema.*;

    var ntb: usize = 0;
    var pp = root;
    while (pp) |p| : (pp = p.link)
        ntb += 1;

    ntb *= (PciCIS - PciBAR0) / 4;
    const table = alloc.newslice(Pcisiz, 2 * ntb + 1) orelse
        p9.panic("pcibusmap: can't allocate memory", .{});
    var itb: usize = 0;
    var mtb: usize = ntb;

    //
    // Build a table of sizes
    //
    pp = root;
    while (pp) |p| : (pp = p.link) {
        if (p.ccrb == 0x06) {
            // carbus bridge?
            if (p.ccru == 0x07) {
                if (pcicfgr32(p, PciBAR0) & 1 != 0)
                    continue;
                const size = pcibarsize(p, PciBAR0);
                if (size == 0)
                    continue;
                table[mtb] = .{ .dev = p, .bar = 0, .siz = size, .typ = 0 };
                mtb += 1;
                continue;
            }

            // pci bridge?
            if (p.ccru != 0x04 or p.bridge == null)
                continue;

            var sioa = ioa;
            var smema = mema;
            pcibusmap(p.bridge, &smema, &sioa, false);

            var hole = pcimask(sioa -% ioa);
            if (hole < (1 << 12))
                hole = 1 << 12;
            table[itb] = .{ .dev = p, .bar = -1, .siz = hole, .typ = 0 };
            itb += 1;

            hole = pcimask(@bitCast(smema -% mema));
            if (hole < (1 << 20))
                hole = 1 << 20;
            table[mtb] = .{ .dev = p, .bar = -1, .siz = hole, .typ = 0 };
            mtb += 1;

            const size = pcibarsize(p, PciEBAR1);
            if (size != 0) {
                table[mtb] = .{ .dev = p, .bar = -3, .siz = size, .typ = 0 };
                mtb += 1;
            }
            continue;
        }

        const romsize = pcibarsize(p, PciEBAR0);
        if (romsize != 0) {
            table[mtb] = .{ .dev = p, .bar = -2, .siz = romsize, .typ = 0 };
            mtb += 1;
        }

        var i: i32 = 0;
        while (i < p.mem.len) : (i += 1) {
            const rno = PciBAR0 + i * 4;
            const v = pcicfgr32(p, rno);
            const size = pcibarsize(p, rno);
            if (size == 0)
                continue;
            if (v & 1 != 0) {
                table[itb] = .{ .dev = p, .bar = i, .siz = size, .typ = 1 };
                itb += 1;
            } else {
                const typ: i32 = @intCast(v & 7);
                table[mtb] = .{ .dev = p, .bar = i, .siz = size, .typ = typ };
                if (typ == 4)
                    i += 1;
                mtb += 1;
            }
        }
    }

    //
    // Sort both tables IO smallest first, Memory largest
    //
    std.mem.sort(Pcisiz, table[0..itb], {}, pcisizcmp);
    std.mem.sort(Pcisiz, table[ntb..mtb], {}, pcisizcmp);

    //
    // Allocate IO address space on this bus
    //
    for (table[0..itb]) |*tptr| {
        var hole = tptr.siz;
        if (tptr.bar == -1)
            hole = 1 << 12;
        ioa = @truncate(@as(u64, @bitCast((@as(i64, ioa) + hole - 1) & ~(hole - 1))));
        if (wrreg) {
            const p = tptr.dev;
            if (tptr.bar == -1) {
                p.ioa.bar = ioa;
                p.ioa.size = tptr.siz;
            } else {
                const b: usize = @intCast(tptr.bar);
                p.mem[b].size = tptr.siz;
                p.mem[b].bar = ioa | 1;
                pcisetbar(p, PciBAR0 + tptr.bar * 4, p.mem[b].bar);
            }
        }
        ioa +%= @truncate(@as(u64, @bitCast(tptr.siz)));
    }

    //
    // Allocate Memory address space on this bus
    //
    for (table[ntb..mtb]) |*tptr| {
        var hole = tptr.siz;
        if (tptr.bar == -1)
            hole = 1 << 20;
        const uhole: u64 = @bitCast(hole);
        mema = (mema +% uhole -% 1) & ~(uhole -% 1);
        if (wrreg) {
            const p = tptr.dev;
            if (tptr.bar == -1) {
                p.mema.bar = mema;
                p.mema.size = tptr.siz;
            } else if (tptr.bar == -2) {
                p.rom.bar = mema | 1;
                p.rom.size = tptr.siz;
                pcisetbar(p, PciEBAR0, p.rom.bar);
            } else if (tptr.bar == -3) {
                p.rom.bar = mema | 1;
                p.rom.size = tptr.siz;
                pcisetbar(p, PciEBAR1, p.rom.bar);
            } else {
                const b: usize = @intCast(tptr.bar);
                p.mem[b].size = tptr.siz;
                p.mem[b].bar = mema | @as(u64, @intCast(tptr.typ));
                pcisetbar(p, PciBAR0 + tptr.bar * 4, p.mem[b].bar);
            }
        }
        mema +%= @bitCast(tptr.siz);
    }

    pmema.* = mema;
    pioa.* = ioa;
    alloc.free(table);

    if (!wrreg)
        return;

    //
    // Finally set all the bridge addresses & registers
    //
    pp = root;
    while (pp) |p| : (pp = p.link) {
        if (p.bridge == null) {
            pcienable(p);
            continue;
        }

        // Set I/O and Mem windows
        pcisetwin(p, p.ioa.bar | 1, p.ioa.bar +% @as(u64, @bitCast(p.ioa.size)) -% 1);
        pcisetwin(p, p.mema.bar | 0, p.mema.bar +% @as(u64, @bitCast(p.mema.size)) -% 1);

        // Disable prefetch
        pcisetwin(p, 0xFFF00000 | 8, 0);

        // Enable the bridge
        pcienable(p);

        var sioa: u32 = @truncate(p.ioa.bar);
        var smema = p.mema.bar;
        pcibusmap(p.bridge, &smema, &sioa, true);
    }
}

fn pcivalidwin(p: *Pcidev, base_: u64, limit: u64) bool {
    var base = base_;
    const bridge = p.parent;
    var typ: []const u8 = undefined;

    if (base & 1 != 0) {
        typ = "io";
        base &= ~@as(u64, 3);
        if (base > limit)
            return false;
        const b = bridge orelse return true;
        if (base >= b.ioa.bar and limit < (b.ioa.bar +% @as(u64, @bitCast(b.ioa.size))))
            return true;
    } else {
        typ = "mem";
        base &= ~@as(u64, 0xF);
        if (base > limit)
            return false;
        const b = bridge orelse return true;
        if (base >= b.mema.bar and limit < (b.mema.bar +% @as(u64, @bitCast(b.mema.size))))
            return true;
        if (base >= b.prefa.bar and limit < (b.prefa.bar +% @as(u64, @bitCast(b.prefa.size))))
            return true;
    }
    print("%T: %.2uX invalid %s-window: %.8llux-%.8llux\n", .{ tbdf(p.tbdf), p.ccrb, typ, base, limit });
    return false;
}

fn pcivalidbar(p: *Pcidev, bar_: u64, size: i64) bool {
    var bar = bar_;
    const usize_: u64 = @bitCast(size);
    if (bar & 1 != 0) {
        bar &= ~@as(u64, 3);
        if (bar == 0 or size < 4 or (bar & (usize_ - 1)) != 0)
            return false;
        return pcivalidwin(p, bar | 1, bar +% usize_ -% 1);
    } else {
        bar &= ~@as(u64, 0xF);
        if (bar == 0 or size < 16 or (bar & (usize_ - 1)) != 0)
            return false;
        return pcivalidwin(p, bar | 0, bar +% usize_ -% 1);
    }
}

/// Find the devices on bus bno, put them on *list (linked by .link)
/// and on the list of all devices, and descend through the bridges.
/// Returns the highest bus number found.
pub fn pciscan(bno: i32, list: *?*Pcidev, parent: ?*Pcidev) i32 {
    var maxubn = bno;
    var head: ?*Pcidev = null;
    var tail: *?*Pcidev = undefined;
    var dno: i32 = 0;
    while (dno <= pcimaxdno) : (dno += 1) {
        var maxfno: i32 = 0;
        var fno: i32 = 0;
        while (fno <= maxfno) : (fno += 1) {
            //
            // For this possible device, form the
            // bus+device+function triplet needed to address it
            // and try to read the vendor and device ID.
            // If successful, allocate a device struct and
            // start to fill it in with some useful information
            // from the device's configuration space.
            //
            const bdf = MKBUS(BusPCI, bno, dno, fno);

            taslock.lock(&pcicfglock);
            pciparentdev = parent;

            const l: u32 = @bitCast(pcicfgrw32raw(bdf, PciVID, 0, true));
            taslock.unlock(&pcicfglock);

            if (l == 0xFFFFFFFF or l == 0)
                continue;
            const p = pcidevalloc();
            p.parent = parent;
            p.tbdf = bdf;
            p.vid = @truncate(l);
            p.did = @truncate(l >> 16);

            p.pcr = @truncate(@as(u32, @bitCast(pcicfgr16(p, PciPCR))));
            p.rid = r8(p, PciRID);
            p.ccrp = r8(p, PciCCRp);
            p.ccru = r8(p, PciCCRu);
            p.ccrb = r8(p, PciCCRb);
            p.cls = r8(p, PciCLS);
            p.ltr = r8(p, PciLTR);
            p.intl = r8(p, PciINTL);

            //
            // If the device is a multi-function device adjust the
            // loop count so all possible functions are checked.
            //
            const hdt = pcicfgr8(p, PciHDT);
            if (hdt & 0x80 != 0)
                maxfno = MaxFNO;

            //
            // If appropriate, read the base address registers
            // and work out the sizes.
            //
            switch (p.ccrb) {
                0x00, // prehistoric
                0x01, // mass storage controller
                0x02, // network controller
                0x03, // display controller
                0x04, // multimedia device
                0x07, // simple comm. controllers
                0x08, // base system peripherals
                0x09, // input devices
                0x0A, // docking stations
                0x0B, // processors
                0x0C, // serial bus controllers
                0x0D, // wireless controllers
                0x0E, // intelligent I/O controllers
                0x0F, // sattelite communication controllers
                0x10, // encryption/decryption controllers
                0x11, // signal processing controllers
                => if ((hdt & 0x7F) == 0) {
                    var rno: i32 = PciBAR0;
                    var i: usize = 0;
                    while (i < p.mem.len) : (i += 1) {
                        p.mem[i].bar = pcicfgr32(p, rno);
                        p.mem[i].size = pcibarsize(p, rno);
                        if ((p.mem[i].bar & 7) == 4 and i < p.mem.len - 1) {
                            rno += 4;
                            p.mem[i].bar |= @as(u64, pcicfgr32(p, rno)) << 32;
                            i += 1;
                            p.mem[i].bar = 0;
                            p.mem[i].size = 0;
                        }
                        rno += 4;
                    }

                    p.rom.bar = pcicfgr32(p, PciEBAR0);
                    p.rom.size = pcibarsize(p, PciEBAR0);
                },

                0x06 => { // bridge device
                    // cardbus bridge?
                    if (p.ccru == 0x07) {
                        p.mem[0].bar = pcicfgr32(p, PciBAR0);
                        p.mem[0].size = pcibarsize(p, PciBAR0);
                    } else if (p.ccru == 0x04) {
                        // pci bridge?
                        p.rom.bar = pcicfgr32(p, PciEBAR1);
                        p.rom.size = pcibarsize(p, PciEBAR1);
                    }
                },
                0x05 => {}, // memory controller
                else => {},
            }

            if (head != null)
                tail.* = p
            else
                head = p;
            tail = &p.link;

            if (pcilist != null)
                pcitail.* = p
            else
                pcilist = p;
            pcitail = &p.list;
        }
    }

    list.* = head;
    var pp = head;
    while (pp) |p| : (pp = p.link) {
        //
        // Find PCI-PCI bridges and recursively descend the tree.
        //
        if (!(p.ccrb == 0x06 and p.ccru == 0x04)) {
            // check and clear invalid membars for non bridges
            for (&p.mem, 0..) |*mem, i| {
                if (mem.size == 0)
                    continue;
                if (!pcivalidbar(p, mem.bar, mem.size)) {
                    if (mem.bar & 1 != 0)
                        mem.bar &= 3
                    else
                        mem.bar &= 0xF;
                    pcisetbar(p, PciBAR0 + @as(i32, @intCast(i)) * 4, mem.bar);
                }
            }
            if (p.rom.size != 0) {
                if ((p.rom.bar & 1) == 0 or
                    !pcivalidbar(p, p.rom.bar & ~@as(u64, 0x7FF), p.rom.size))
                {
                    p.rom.bar = 0;
                    pcisetbar(p, PciEBAR0, p.rom.bar);
                }
            }
            continue;
        }

        if (p.rom.size != 0) {
            if ((p.rom.bar & 1) == 0 or
                !pcivalidbar(p, p.rom.bar & ~@as(u64, 0x7FF), p.rom.size))
            {
                p.rom.bar = 0;
                pcisetbar(p, PciEBAR1, p.rom.bar);
            }
        }

        //
        // If the secondary or subordinate bus number is not
        // initialised try to do what the PCI BIOS should have
        // done and fill in the numbers as the tree is descended.
        // On the way down the subordinate bus number is set to
        // the maximum as it's not known how many buses are behind
        // this one; the final value is set on the way back up.
        //
        var sbn = pcicfgr8(p, PciSBN);
        const ubn = pcicfgr8(p, PciUBN);

        if (sbn == 0 or ubn == 0) {
            sbn = maxubn + 1;
            //
            // Make sure memory, I/O and master enables are
            // off, set the primary, secondary and subordinate
            // bus numbers and clear the secondary status before
            // attempting to scan the secondary bus.
            //
            // Initialisation of the bridge should be done here.
            //
            p.pcr = 0;
            pcicfgw32(p, PciPCR, 0xFFFF0000);
            var l: u32 = @bitCast((MaxUBN << 16) | (sbn << 8) | bno);
            pcicfgw32(p, PciPBN, l);
            pcicfgw16(p, PciSPSR, 0xFFFF);

            p.ioa.bar = 0;
            p.ioa.size = 0;
            p.mema.bar = 0;
            p.mema.size = 0;
            p.prefa.bar = 0;
            p.prefa.size = 0;

            pcisetwin(p, 0xFFFFF000 | 1, 0);
            pcisetwin(p, 0xFFF00000 | 0, 0);
            pcisetwin(p, 0xFFF00000 | 8, 0);

            maxubn = pciscan(sbn, &p.bridge, p);
            l = @bitCast((maxubn << 16) | (sbn << 8) | bno);

            pcicfgw32(p, PciPBN, l);
        } else {
            var base: u64 = undefined;
            var limit: u64 = undefined;
            var v: u32 = undefined;

            v = @bitCast(pcicfgr16(p, PciIBR));
            limit = (v & 0xF000) | 0x0FFF;
            base = @as(u64, v & 0x00F0) << 8;
            if ((v & 0x0F) == 0x01) {
                v = pcicfgr32(p, PciIUBR);
                limit |= (v & 0xFFFF0000);
                base |= @as(u64, v & 0x0000FFFF) << 16;
            }
            if (pcivalidwin(p, base | 1, limit)) {
                p.ioa.bar = base;
                p.ioa.size = @bitCast((limit - base) + 1);
            } else {
                pcisetwin(p, 0xFFFFF000 | 1, 0);
                p.ioa.bar = 0;
                p.ioa.size = 0;
            }

            v = pcicfgr32(p, PciMBR);
            limit = (v & 0xFFF00000) | 0x000FFFFF;
            base = @as(u64, v & 0x0000FFF0) << 16;
            if (pcivalidwin(p, base | 0, limit)) {
                p.mema.bar = base;
                p.mema.size = @bitCast((limit - base) + 1);
            } else {
                pcisetwin(p, 0xFFF00000 | 0, 0);
                p.mema.bar = 0;
                p.mema.size = 0;
            }

            v = pcicfgr32(p, PciPMBR);
            limit = (v & 0xFFF00000) | 0x000FFFFF;
            limit |= @as(u64, pcicfgr32(p, PciPULR)) << 32;
            base = @as(u64, v & 0x0000FFF0) << 16;
            base |= @as(u64, pcicfgr32(p, PciPUBR)) << 32;
            if (pcivalidwin(p, base | 8, limit)) {
                p.prefa.bar = base;
                p.prefa.size = @bitCast((limit -% base) +% 1);
            } else {
                pcisetwin(p, 0xFFF00000 | 8, 0);
                p.prefa.bar = 0;
                p.prefa.size = 0;
            }

            if (ubn > maxubn)
                maxubn = ubn;
            _ = pciscan(sbn, &p.bridge, p);
        }
    }

    return maxubn;
}

/// pcicfgr8 as the byte it is.
fn r8(p: *Pcidev, rno: i32) u8 {
    return @truncate(@as(u32, @bitCast(pcicfgr8(p, rno))));
}

pub fn pcibussize(root: ?*Pcidev, msize: *u64, iosize: *u32) void {
    msize.* = 0;
    iosize.* = 0;
    pcibusmap(root, msize, iosize, false);
}

/// The next device after prev (the first if prev is null) with the
/// given vendor and device ID; 0 matches any.
pub fn pcimatch(prev_: ?*Pcidev, vid: i32, did: i32) ?*Pcidev {
    var prev = if (prev_) |p| p.list else pcilist;

    while (prev) |p| {
        if ((vid == 0 or p.vid == vid) and
            (did == 0 or p.did == did))
            break;
        prev = p.list;
    }
    return prev;
}

pub fn pcimatchtbdf(bdf: i32) ?*Pcidev {
    var pcidev = pcilist;
    while (pcidev) |p| : (pcidev = p.list) {
        if (p.tbdf == bdf)
            break;
    }
    return pcidev;
}

// DIFF: MSI only.  Kept because it only reads: nothing in planZ
// routes the line it returns.
pub fn pciipin(pci_: ?*Pcidev, pin: u8) u8 {
    var pci = pci_ orelse pcilist;

    while (pci) |p| {
        if (pcicfgr8(p, PciINTP) == pin and p.intl != 0 and p.intl != 0xff)
            return p.intl;

        if (p.bridge != null) {
            const intl = pciipin(p.bridge, pin);
            if (intl != 0)
                return intl;
        }

        pci = p.list;
    }
    return 0;
}

fn pcilhinv(p_: ?*Pcidev) void {
    var tt = p_;
    while (tt) |t| : (tt = t.link) {
        print("%d  %2d/%d %.2ux %.2ux %.2ux %.4ux %.4ux %3d  ", .{
            BUSBNO(t.tbdf), BUSDNO(t.tbdf), BUSFNO(t.tbdf),
            t.ccrb,         t.ccru,         t.ccrp,
            t.vid,          t.did,          t.intl,
        });
        for (t.mem, 0..) |mem, i| {
            if (mem.size == 0)
                continue;
            print("%d:%.8llux %lld ", .{ i, mem.bar, mem.size });
        }
        if (t.rom.bar != 0 or t.rom.size != 0)
            print("rom:%.8llux %lld ", .{ t.rom.bar, t.rom.size });
        if (t.ioa.bar != 0 or t.ioa.size != 0)
            print("ioa:%.8llux-%.8llux %lld ", .{ t.ioa.bar, t.ioa.bar +% @as(u64, @bitCast(t.ioa.size)), t.ioa.size });
        if (t.mema.bar != 0 or t.mema.size != 0)
            print("mema:%.8llux-%.8llux %lld ", .{ t.mema.bar, t.mema.bar +% @as(u64, @bitCast(t.mema.size)), t.mema.size });
        if (t.prefa.bar != 0 or t.prefa.size != 0)
            print("prefa:%.8llux-%.8llux %lld ", .{ t.prefa.bar, t.prefa.bar +% @as(u64, @bitCast(t.prefa.size)), t.prefa.size });
        if (t.bridge) |b|
            print("->%d", .{BUSBNO(b.tbdf)});
        print("\n", .{});
    }
    var pp = p_;
    while (pp) |p| {
        if (p.bridge != null)
            pcilhinv(p.bridge);
        pp = p.link;
    }
}

pub fn pcihinv(p: ?*Pcidev) void {
    print("bus dev type     vid  did  intl memory\n", .{});
    pcilhinv(p);
}

pub fn pcireset() void {
    var pp = pcilist;
    while (pp) |p| : (pp = p.list) {
        // don't mess with the bridges
        if (p.ccrb == 0x06)
            continue;
        pcidisable(p);
    }
}

pub fn pcisetioe(p: *Pcidev) void {
    p.pcr |= IOen;
    pcicfgw16(p, PciPCR, p.pcr);
}

pub fn pciclrioe(p: *Pcidev) void {
    p.pcr &= ~@as(u16, IOen);
    pcicfgw16(p, PciPCR, p.pcr);
}

pub fn pcisetbme(p: *Pcidev) void {
    p.pcr |= MASen;
    pcicfgw16(p, PciPCR, p.pcr);
}

pub fn pciclrbme(p: *Pcidev) void {
    p.pcr &= ~@as(u16, MASen);
    pcicfgw16(p, PciPCR, p.pcr);
}

pub fn pcisetmwi(p: *Pcidev) void {
    p.pcr |= MemWrInv;
    pcicfgw16(p, PciPCR, p.pcr);
}

pub fn pciclrmwi(p: *Pcidev) void {
    p.pcr &= ~@as(u16, MemWrInv);
    pcicfgw16(p, PciPCR, p.pcr);
}

/// Call fmatch(p, cap, off, arg) for each capability of the device:
/// it returns 0 to stop there (the offset is returned), negative to
/// give up, positive to go on.  Returns -1 if nothing matched.
pub fn pcienumcaps(p: *Pcidev, fmatch: *const fn (*Pcidev, i32, i32, i32) i32, arg: i32) i32 {
    var off: i32 = undefined;

    // status register bit 4 has capabilities
    if ((pcicfgr16(p, PciPSR) & 1 << 4) == 0)
        return -1;
    switch (pcicfgr8(p, PciHDT) & 0x7F) {
        else => return -1,
        0, // etc
        1, // pci to pci bridge
        => off = 0x34,
        2 => off = 0x14, // cardbus bridge
    }
    var i: i32 = 48;
    while (i != 0) : (i -= 1) {
        off = pcicfgr8(p, off);
        if (off < 0x40 or (off & 3) != 0)
            break;
        off &= ~@as(i32, 3);
        const cap = pcicfgr8(p, off);
        if (cap == 0xff)
            break;
        const r = fmatch(p, cap, off, arg);
        if (r < 0)
            break;
        if (r == 0)
            return off;
        off += 1;
    }
    return -1;
}

fn matchcap(_: *Pcidev, cap: i32, _: i32, arg: i32) i32 {
    return @intFromBool(cap != arg);
}

fn matchhtcap(p: *Pcidev, cap_: i32, off: i32, arg: i32) i32 {
    var mask: i32 = undefined;

    if (cap_ != PciCapHTC)
        return 1;
    if (arg == 0x00 or arg == 0x20)
        mask = 0xE0
    else
        mask = 0xF8;
    const cap = pcicfgr8(p, off + 3);
    return @intFromBool((cap & mask) != arg);
}

/// The offset of capability cap in the device's configuration space,
/// or -1.
pub fn pcicap(p: *Pcidev, cap: i32) i32 {
    return pcienumcaps(p, matchcap, cap);
}

pub fn pcihtcap(p: *Pcidev, cap: i32) i32 {
    return pcienumcaps(p, matchhtcap, cap);
}

const MSIXCtrl = 0x02;

fn pcimsixdisable(p: *Pcidev) i32 {
    const off = pcicap(p, PciCapMSIX);
    if (off < 0)
        return -1;
    pcicfgw16(p, off + MSIXCtrl, 0);
    return 0;
}

const MSIXTable = 0x04; // table offset and BAR indicator (32 bit)
const MSIXEnable = 1 << 15;
const MSIXMaskAll = 1 << 14;

/// Deliver the device's MSI-X interrupts as the message (addr, data).
/// DIFF: not in the C, which has MSI only and falls back to the
/// interrupt pins for a device with just MSI-X; there is no pin routing
/// here, and virtio and NVMe devices offer MSI-X alone.  Every entry of
/// the device's table is given the same message, so whichever entries
/// a driver uses arrive at the one handler.
fn pcimsixenable(p: *Pcidev, addr: u64, data: u32) i32 {
    const off = pcicap(p, PciCapMSIX);
    if (off < 0)
        return -1;
    const ctl: u32 = @intCast(pcicfgr16(p, off + MSIXCtrl));
    const n: usize = (ctl & 0x7FF) + 1;
    const t = pcicfgr32(p, off + MSIXTable);
    const bir: usize = t & 7;
    if (bir >= p.mem.len or p.mem[bir].bar & 1 != 0 or p.mem[bir].size <= 0)
        return -1;
    const pa = (p.mem[bir].bar & ~@as(u64, 0xF)) + (t & ~@as(u32, 7));
    if (pa == 0 or (t & ~@as(u32, 7)) + n * 16 > @as(u64, @intCast(p.mem[bir].size)))
        return -1;
    // The table stays mapped: it is needed again to change or mask
    // an entry.
    const va = arch.vmap(pa, n * 16) orelse return -1;
    const tab: [*]volatile u32 = @ptrFromInt(va);

    pcicfgw16(p, PciPCR, pcicfgr16(p, PciPCR) | MEMen);
    pcicfgw16(p, off + MSIXCtrl, MSIXEnable | MSIXMaskAll);
    for (0..n) |i| {
        tab[i * 4 + 0] = @truncate(addr);
        tab[i * 4 + 1] = @truncate(addr >> 32);
        tab[i * 4 + 2] = data;
        tab[i * 4 + 3] = 0; // not masked
    }
    pcicfgw16(p, off + MSIXCtrl, MSIXEnable);
    return 0;
}

fn pcigetmsi(p: *Pcidev) i32 {
    if (p.msi != 0)
        return p.msi;
    p.msi = pcicap(p, PciCapMSI);
    return p.msi;
}

const MSICtrl = 0x02; // message control register (16 bit)
const MSIAddr = 0x04; // message address register (64 bit)
const MSIData32 = 0x08; // message data register for 32 bit MSI (16 bit)
const MSIData64 = 0x0C; // message data register for 64 bit MSI (16 bit)

pub fn pcimsienable(p: *Pcidev, addr: u64, data: u32) i32 {
    const off = pcigetmsi(p);
    if (off < 0)
        return pcimsixenable(p, addr, data); // DIFF: see pcimsixenable
    _ = pcimsixdisable(p); // make sure MSI-X is off
    const ok64 = (pcicfgr16(p, off + MSICtrl) & (1 << 7)) != 0;
    pcicfgw32(p, off + MSIAddr, @truncate(addr));
    if (ok64) pcicfgw32(p, off + MSIAddr + 4, @truncate(addr >> 32));
    pcicfgw16(p, off + @as(i32, if (ok64) MSIData64 else MSIData32), lo32(data));
    pcicfgw16(p, off + MSICtrl, 1);
    return 0;
}

pub fn pcimsidisable(p: *Pcidev) i32 {
    const x = pcimsixdisable(p); // also disable MSI-X
    const off = pcigetmsi(p);
    if (off < 0)
        return x;
    pcicfgw16(p, off + MSICtrl, 0);
    return 0;
}

fn pcigetpmrb(p: *Pcidev) i32 {
    if (p.pmrb != 0)
        return p.pmrb;
    p.pmrb = pcicap(p, PciCapPMG);
    return p.pmrb;
}

pub fn pcigetpms(p: *Pcidev) i32 {
    const ptr = pcigetpmrb(p);
    if (ptr == -1)
        return -1;

    //
    // Power Management Register Block:
    //  offset 0:  Capability ID
    //         1:  next item pointer
    //         2:  capabilities
    //         4:  control/status
    //         6:  bridge support extensions
    //         7:  data
    //
    const pmcsr = pcicfgr16(p, ptr + 4);

    return pmcsr & 0x0003;
}

/// Put the device in power state D0-D3; returns the state it was in,
/// or -1.
pub fn pcisetpms(p: *Pcidev, state: i32) i32 {
    const ptr = pcigetpmrb(p);
    if (ptr == -1)
        return -1;

    const pmc = pcicfgr16(p, ptr + 2);
    var pmcsr = pcicfgr16(p, ptr + 4);
    const ostate = pmcsr & 0x0003;
    pmcsr &= ~@as(i32, 0x0003);

    switch (state) {
        else => return -1,
        0 => {},
        1 => if (pmc & 0x0200 == 0)
            return -1,
        2 => if (pmc & 0x0400 == 0)
            return -1,
        3 => {},
    }
    pmcsr |= state;
    pcicfgw16(p, ptr + 4, pmcsr);

    return ostate;
}

pub fn pcienable(p_: ?*Pcidev) void {
    const p = p_ orelse return;
    var pcr: u16 = undefined;

    pcienable(p.parent);

    switch (pcisetpms(p, 0)) {
        1 => print("pcienable %T: wakeup from D1\n", .{tbdf(p.tbdf)}),
        2 => {
            print("pcienable %T: wakeup from D2\n", .{tbdf(p.tbdf)});
            if (p.bridge != null)
                arch.delay(100) // B2: minimum delay 50ms
            else
                arch.delay(1); // D2: minimum delay 200µs
        },
        3 => {
            print("pcienable %T: wakeup from D3\n", .{tbdf(p.tbdf)});
            arch.delay(100); // D3: minimum delay 50ms

            // restore registers
            for (p.mem, 0..) |mem, i| {
                if (mem.size == 0)
                    continue;
                pcisetbar(p, PciBAR0 + @as(i32, @intCast(i)) * 4, mem.bar);
            }

            pcicfgw8(p, PciINTL, p.intl);
            pcicfgw8(p, PciLTR, p.ltr);
            pcicfgw8(p, PciCLS, p.cls);
            pcicfgw16(p, PciPCR, p.pcr);
        },
        else => {},
    }

    if (p.ltr == 0 or p.ltr == 0xFF) {
        p.ltr = 64;
        pcicfgw8(p, PciLTR, p.ltr);
    }
    if (p.cls == 0 or p.cls == 0xFF) {
        p.cls = 64 / 4;
        pcicfgw8(p, PciCLS, p.cls);
    }

    if (p.bridge != null)
        pcr = IOen | MEMen | MASen
    else {
        pcr = 0;
        for (p.mem) |mem| {
            if (mem.size == 0)
                continue;
            if (mem.bar & 1 != 0)
                pcr |= IOen
            else
                pcr |= MEMen;
        }
    }

    if ((p.pcr & pcr) != pcr) {
        print("pcienable %T: pcr %ux->%ux\n", .{ tbdf(p.tbdf), p.pcr, p.pcr | pcr });
        p.pcr |= pcr;
        pcicfgw32(p, PciPCR, 0xFFFF0000 | @as(u32, p.pcr));
    }
}

pub fn pcidisable(p_: ?*Pcidev) void {
    const p = p_ orelse return;
    _ = pcimsidisable(p);
    pciclrbme(p);
}

// from 9/pc/pcipc.c

/// The devices on the root buses, linked by .link.
pub var pciroot: ?*Pcidev = null;

fn pcireserve() void {
    //
    // mark all valid io/mem address space claimed by pci devices
    // so that ioreserve/upaalloc doesn't give it out.
    //
    var pp = pciroot;
    while (pp) |p| : (pp = p.list) {
        for (p.mem) |mem| {
            if (mem.size == 0)
                continue;
            if (mem.bar & 1 != 0) {
                // DIFF: no I/O port map
                continue;
            } else {
                const pa = mem.bar & ~@as(u64, 0xF);
                if (pa == 0)
                    continue;
                _ = arch.upaalloc(pa, @bitCast(mem.size), 0);
            }
        }
        if (p.rom.size != 0 and (p.rom.bar & 1) != 0) {
            const pa = p.rom.bar & ~@as(u64, 0x7FF);
            _ = arch.upaalloc(pa, @bitCast(p.rom.size), 0);
        }
    }

    //
    // allocate io/mem address space for unassigned membars.
    //
    pp = pciroot;
    while (pp) |p| : (pp = p.list) {
        for (&p.mem, 0..) |*mem, i| {
            if (mem.size == 0)
                continue;
            if (mem.bar & 1 != 0) {
                // DIFF: no I/O port map; an unassigned I/O port BAR
                // stays unassigned.
                continue;
            } else {
                if (mem.bar & ~@as(u64, 0xF) != 0)
                    continue;
                if (p.parent != null) {
                    // M7: needs upaallocwin, to allocate inside the
                    // parent bridge's prefa or mema window.
                    continue;
                }
                const pa = arch.upaalloc(~@as(u64, 0), @bitCast(mem.size), @bitCast(mem.size));
                if (pa == ~@as(u64, 0))
                    continue;
                mem.bar |= pa;
            }
            pcisetbar(p, PciBAR0 + @as(i32, @intCast(i)) * 4, mem.bar);
        }
    }
}

/// Find every device: the part of pcicfginit that follows working out
/// how to reach configuration space.  The platform calls this once,
/// after setting pcicfgrw8raw, pcicfgrw16raw, pcicfgrw32raw, pcimaxbno
/// and pcimaxdno.
pub fn pciscaninit() void {
    if (arch.getconf("*pcimaxbno")) |s|
        pcimaxbno = std.fmt.parseInt(i32, s, 0) catch pcimaxbno;
    if (arch.getconf("*pcimaxdno")) |s| {
        const n = std.fmt.parseInt(i32, s, 0) catch pcimaxdno;
        if (n < pcimaxdno)
            pcimaxdno = n;
    }

    var list: *?*Pcidev = &pciroot;
    var bno: i32 = 0;
    while (bno <= pcimaxbno) : (bno += 1) {
        const sbno = bno;
        bno = pciscan(bno, list, null);

        while (list.*) |x|
            list = &x.link;

        if (sbno == 0) {
            //
            // If we have found a PCI-to-Cardbus bridge, make sure
            // it has no valid mappings anymore.
            //
            var pp = pciroot;
            while (pp) |pci| : (pp = pci.link) {
                if (pci.ccrb == 6 and pci.ccru == 7) {
                    // reset the cardbus
                    const bcr = pcicfgr16(pci, PciBCR);
                    pcicfgw16(pci, PciBCR, 0x40 | bcr);
                    arch.delay(50);
                }
            }
        }
    }

    if (pciroot != null) {
        //
        // Disabling devices here (by clearing bus master enable)
        // causes problems with with some OHCI USB controllers.
        // I supected that this is due to legacy device emulation
        // and revoking bus master flag before executing the handoff
        // makes BIOS/SMM lock up the system.
        //
        // pcireset();
        //

        // DIFF: no `nobios` case (pcibussize, pcibusmap over a window
        // from upaalloc and ioreserve): the firmware has assigned
        // resources.

        pcireserve();

        // DIFF: MSI only; no pcirouting.
    }

    if (arch.getconf("*pcihinv") != null)
        pcihinv(pciroot);
}

test "MKBUS" {
    const eq = std.testing.expectEqual;
    const v = MKBUS(BusPCI, 0x12, 0x1f, 7);
    try eq(@as(i32, 0x0c12ff00), v);
    try eq(@as(i32, BusPCI), BUSTYPE(v));
    try eq(@as(i32, 0x12), BUSBNO(v));
    try eq(@as(i32, 0x1f), BUSDNO(v));
    try eq(@as(i32, 7), BUSFNO(v));
    try eq(@as(i32, 0x12ff00), BUSBDF(v));
    // out-of-range numbers are masked
    try eq(MKBUS(BusPCI, 1, 2, 3), MKBUS(BusPCI, 0x101, 0x22, 0xb));
    try eq(@as(i32, -1), BUSTYPE(-1));
}

test "%T" {
    var buf: [64]u8 = undefined;
    const eqs = std.testing.expectEqualStrings;
    try eqs("PCI.0.31.2", fmt.snprint(&buf, "%T", .{tbdf(MKBUS(BusPCI, 0, 31, 2))}));
    try eqs("ISA.0.0.0", fmt.snprint(&buf, "%T", .{tbdf(MKBUS(BusISA, 0, 0, 0))}));
    try eqs("<PCI.255.1.0>", fmt.snprint(&buf, "<%T>", .{tbdf(MKBUS(BusPCI, 255, 1, 0))}));
    try eqs("unknown", fmt.snprint(&buf, "%T", .{tbdf(-1)}));
    try eqs("18.1.2.3", fmt.snprint(&buf, "%T", .{tbdf(MKBUS(18, 1, 2, 3))}));
    try eqs("(tbdffmt)", fmt.snprint(&buf, "%d", .{tbdf(0)}));
}

test "bar sizes" {
    const eq = std.testing.expectEqual;
    const sx = struct {
        // What a register reads after all ones were written, as the
        // raw accessor returns it.
        fn f(v: u32) i64 {
            return @as(i32, @bitCast(v));
        }
    }.f;
    // 32 bit memory, 64K
    try eq(@as(i64, 0x10000), -barmask(PciBAR0, 0, sx(0xFFFF0000)));
    // prefetchable 64 bit memory, 1M, all in the low half
    try eq(@as(i64, 0x100000), -barmask(PciBAR0, 0xC, sx(0xFFF0000C)));
    // 64 bit memory of 4G and more: nothing in the low half
    try eq(@as(i64, 0), barmask(PciBAR0, 4, sx(0x00000004)));
    // I/O ports, 32 of them; the top half reads as zero
    try eq(@as(i64, 0x20), -barmask(PciBAR1, 1, sx(0x0000FFE1)));
    try eq(@as(i64, 0x100), -barmask(PciBAR1, 1, sx(0xFFFFFF01)));
    // expansion ROM, 128K, enable bit and reserved bits ignored
    try eq(@as(i64, 0x20000), -barmask(PciEBAR0, 0, sx(0xFFFE0001)));
    try eq(@as(i64, 0x20000), -barmask(PciEBAR1, 1, sx(0xFFFE07FF)));
    // not implemented
    try eq(@as(i64, 0), barmask(PciBAR0, 0, sx(0)));
}

test "pcimask" {
    const eq = std.testing.expectEqual;
    try eq(@as(i64, 0), pcimask(0));
    try eq(@as(i64, 1), pcimask(1));
    try eq(@as(i64, 0x1000), pcimask(0x1000));
    try eq(@as(i64, 0x2000), pcimask(0x1001));
    try eq(@as(i64, 0x200000), pcimask(0x180000));
}
