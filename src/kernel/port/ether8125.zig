//! Realtek RTL8125B 2.5 Gigabit Ethernet Controller.
//! Not a port of one C file: 9front has no driver for the RTL8125
//! (9/pc/ether8169.c stops at the RTL8168 family, whose registers the
//! RTL8125 only partly shares).  The structure is 9/pc/ether8169.c's:
//! Ctlr, the two descriptor rings, replenish, init, the reseter kproc,
//! attach, link, transmit, receive, interrupt, ifstat, promiscuous,
//! multicast, pci and pnp, each under its 8169 name with 8125 in it.
//! The registers, bits, descriptor formats and the bring-up sequence of
//! the RTL8125B are those of OpenBSD's rge(4), sys/dev/pci/if_rge.c
//! 1.49 and if_rgereg.h (Kevin Lo, ISC licence), for its MAC_R25B; the
//! comment before each function names the rge function it follows.
//!
//! Only the RTL8125B (hardware revision 0x641 in Tcr; PCI revision 5
//! on the board this was written for) is driven.  The RTL8125A, 8125D,
//! 8126 and 8127 differ in the steps rge marks with their types; they
//! are refused with a message.
//!
//! Left out of what rge does:
//!   - Microcode.  rge loads a MAC MCU patch and a PHY "ram code" from
//!     a firmware file (rge_mac_config_mcu, rge_phy_config_mcu).  Here
//!     the MAC MCU break points are cleared, as rge clears them before
//!     loading, and stay cleared; the PHY keeps the code it has, from
//!     its ROM or from whoever loaded one since power on.  ifstat says
//!     which version it found.
//!   - Checksum offload, TSO, VLAN tag insertion and stripping, jumbo
//!     frames, RSS and more than one queue, wake on lan, the simulated
//!     interrupt moderation with the chip's timer, media selection
//!     other than autonegotiation of everything.
//!   - Frames spanning several descriptors: Rms is the size of one
//!     buffer, and anything that still arrives in pieces is dropped
//!     and counted (frag), as in ether8169.c.
//!
//! DIFF from ether8169.c, besides the chip:
//!   - Registers are in memory (BAR 2); the C uses the I/O ports.
//!   - Transmit and receive descriptors are different structures, 32
//!     bytes each (Td, Rd).  They are reached through volatile
//!     pointers.
//!   - No Mii: the PHY is inside the chip and reached through the PHY
//!     OCP register; link state comes from Phystatus alone.
//!   - rtl8125init is in three parts.  The chip is stopped under the
//!     locks, brought up without them (rtl8125start: it takes
//!     milliseconds, and a second when the PHY is slow, where the C
//!     holds its ilock through all of its init) with `running` false,
//!     which keeps transmit and the interrupt routine away, and
//!     switched on under the locks again.
//!   - The interrupt routine masks the chip's interrupts while it
//!     works and unmasks them when done, as rge_intr does: with MSI
//!     that is what produces a new message for an event that arrived
//!     meanwhile.  Its loop is bounded.  It runs under a lock of its
//!     own (ilock), because rtl8125watch may call it too.
//!   - rtl8125watch, a kproc that is not in the C: once a second it
//!     reads the link state (rge_tick), and if events are waiting in
//!     Isr that no interrupt came for, it handles them; if no
//!     interrupt has ever come it says "no interrupts; polling" once
//!     and from then on polls every 10ms.
//!   - Only Serr restarts the chip; the C restarts on Fovw as well,
//!     which is a receive event here.
//!   - The multicast hash survives a restart; the C clears it.
//!   - Short frames are padded to 60 bytes, and frames that would hang
//!     the chip are padded as rge does (txpadlen).
//!   - ifstat prints the registers and counters wanted for finding
//!     out from a text file why a card does not work; the tally
//!     counters failing is a line in it, not an error.
//!   - rtl8125halt masks and acknowledges interrupts and leaves Cr
//!     alone; what stops the chip is rtl8125reset (rge_reset).
//!     rtl8125pnp and rtl8125shutdown reset it and turn bus mastering
//!     off, so that a chip the firmware left receiving, or one being
//!     left for the next kernel, writes to no memory.
//!   - `*rtl8125nophy=1` in plan9.ini leaves out the PHY parameter
//!     settings of rge_phy_config_mac_r25b, for a link that does not
//!     come up.
//!   - ifstat formats into a slice and returns the length; promiscuous
//!     and multicast return error unions (see netif).  An Ether's
//!     port, irq, mbps and arg are ether.isa.port, ether.isa.irq,
//!     ether.netif.mbps and ether.netif.arg (see devether).

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch.zig");
const fmt = @import("fmt");
const portdat = @import("portdat.zig");
const alloc = @import("alloc.zig");
const ab = @import("allocb.zig");
const qio = @import("qio.zig");
const proc = @import("proc.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const pci = @import("pci.zig");
const netif = @import("netif.zig");
const devether = @import("devether.zig");
const p9 = @import("print.zig");

const print = p9.print;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const tsleep = proc.tsleep;
const wakeup = proc.wakeup;
const kproc = proc.kproc;
const freeb = ab.freeb;
const BLEN = ab.BLEN;
const NEXT = devether.NEXT;
const ethersetspeed = devether.ethersetspeed;
const ethersetlink = devether.ethersetlink;

const Error = proc.Error;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Rendez = portdat.Rendez;
const Block = ab.Block;
const Bpool = ab.Bpool;
const Pcidev = pci.Pcidev;
const Ether = devether.Ether;
const Eaddrlen = devether.Eaddrlen;
const ETHERMAXTU = devether.ETHERMAXTU;

// registers (rge's name)
const Idr0 = 0x00; // MAC address (MAC0, MAC4)
const Mar0 = 0x08; // Multicast address (MAR0, MAR4)
const Dtccr = 0x10; // Dump Tally Counter Command (DTCCR_LO, DTCCR_HI)
const Tnpds = 0x20; // Transmit Normal Priority Descriptors (TXDESC_ADDR_LO, _HI)
const Intcfg0 = 0x34; // (INT_CFG0)
const Cr = 0x37; // Command Register (CMD)
const Imr = 0x38; // Interrupt Mask, 32 bits (IMR)
const Isr = 0x3C; // Interrupt Status, 32 bits (ISR)
const Tcr = 0x40; // Transmit Configuration (TXCFG)
const Rcr = 0x44; // Receive Configuration (RXCFG)
const Cr9346 = 0x50; // 9346 Command Register (EECMD)
const Config1 = 0x52; // Configuration Register 1 (CFG1)
const Config2 = 0x53; // Configuration Register 2 (CFG2)
const Config5 = 0x56; // Configuration Register 5 (CFG5)
const Tdfnr = 0x57; // (TDFNR)
const Timerint0 = 0x58; // Timer Interrupt (TIMERINT0)
const Timerint1 = 0x5C; // (TIMERINT1)
const Csidr = 0x64; // PCI configuration space data (CSIDR)
const Csiar = 0x68; // PCI configuration space address (CSIAR)
const Phystatus = 0x6C; // PHY Status, 16 bits (PHYSTAT)
const Pmch = 0x6F; // power management (PMCH)
const Ephyar = 0x80; // PCIe PHY access (EPHYAR)
const Timerint2 = 0x8C; // (TIMERINT2)
const Tppoll = 0x90; // Transmit Priority Polling, 16 bits (TXSTART)
const Macocp = 0xB0; // MAC OCP access (MACOCP)
const Phyocp = 0xB8; // PHY OCP access (PHYOCP)
const Dllpr = 0xD0; // (DLLPR)
const Twicmd = 0xD2; // (TWICMD)
const Mcucmd = 0xD3; // (MCUCMD)
const Rms = 0xDA; // Receive Packet Maximum Size (RXMAXSIZE)
const Cplusc = 0xE0; // C+ Command (CPLUSCMD)
const Coal = 0xE2; // Interrupt Mitigation (IM)
const Rdsar = 0xE4; // Receive Descriptor Start Address (RXDESC_ADDR_LO, _HI)
const Reg_f1 = 0xF1; // rge has no name for it
const Ppsw = 0xF2; // (PPSW)
const Timerint3 = 0xF4; // (TIMERINT3)
const Reg_382 = 0x0382; // rge has no name for it
const Intmiti = 0x0A00; // interrupt moderation timers (INTMITI(i))
const Reg_1880 = 0x1880; // rge has no name for it
const Addr0 = 0x19E0; // the address the chip was made with (ADDR0)
const Addr1 = 0x19E4; // (ADDR1)
const Rssctrl = 0x4500; // (RSS_CTRL)
const Rxqctrl = 0x4800; // (RXQUEUE_CTRL)
const Eeetxidle = 0x6048; // (EEE_TXIDLE_TIMER)

const Regsize = 0x7000; // how much of BAR 2 is used

// Dtccr
const Dump = 0x00000008;

// Intcfg0
const Intcfgen = 0x01; // the newer interrupt registers (INT_CFG0_EN)

// Cr
const Te = 0x04; // Transmitter Enable
const Re = 0x08; // Receiver Enable
const Rst = 0x10; // Software Reset
const Stopreq = 0x80;

// Imr/Isr
const Rok = 0x00000001; // Receive OK
const Rer = 0x00000002; // Receive Error
const Tok = 0x00000004; // Transmit OK
const Ter = 0x00000008; // Transmit Error
const Rdu = 0x00000010; // Receive Descriptor Unavailable
const Punlc = 0x00000020; // Packet Underrun or Link Change
const Fovw = 0x00000040; // Receive FIFO Overflow
const Tdu = 0x00000080; // Transmit Descriptor Unavailable
const Swint = 0x00000100; // Software Interrupt
const Timeout = 0x00004000; // Timer
const Serr = 0x00008000; // System Error

// Tcr
const TxcfgConfig = 0x03000700; // (RGE_TXCFG_CONFIG)
const HwveridMASK = 0x7CF00000; // (RGE_TXCFG_HWREV)

const Macv8125a = 0x60900000; // RTL8125A; not driven
const Macv8125b = 0x64100000; // RTL8125B

// Rcr
const Aap = 0x00000001; // Accept All Packets
const Apm = 0x00000002; // Accept Physical Match
const Am = 0x00000004; // Accept Multicast
const Ab = 0x00000008; // Accept Broadcast
const Ar = 0x00000010; // Accept Runt
const Aer = 0x00000020; // Accept Error
const RxcfgConfig8125b = 0x41000C00; // (RGE_RXCFG_CONFIG_8125B)

// Cr9346
const Eem0 = 0x40; // Operating Mode
const Eem1 = 0x80;

// Config1
const Speeddown = 0x10;

// Config2
const Clkreqen = 0x80;

// Config5
const Pmests = 0x01;

// Csiar
const CsiaddrMASK = 0x00000FFF;
const Csibyteen = 0x0000F000;

// Ephyar
const EphyaddrMASK = 0x7F;
const EphyaddrSHIFT = 16;

// Macocp, Phyocp, Ephyar, Csiar
const DataMASK = 0x0000FFFF;
const Flag = 0x80000000;

// Phystatus
const Fd = 0x0001; // Full Duplex
const Linksts = 0x0002; // Link Status
const Speed10 = 0x0004;
const Speed100 = 0x0008;
const Speed1000 = 0x0010;
const Rxflow = 0x0020;
const Txflow = 0x0040;
const Speed2500 = 0x0400;

// Tppoll
const Npq = 0x0001; // Normal Priority Queue polling

// Dllpr
const Pfmen = 0x40;
const Tx10mpsen = 0x80;

// Mcucmd
const Rxfifoempty = 0x10;
const Txfifoempty = 0x20;
const Isoob = 0x80;

// Cplusc
const Rxchksum = 0x0020; // Receive Checksum Offload Enable

// the PHY's MII registers, and the bits used
const Bmcr = 0x00;
const Bmsr = 0x01;
const Anar = 0x04;
const Anlpar = 0x05;
const Mscr = 0x09; // 1000BASE-T control
const Mssr = 0x0A; // 1000BASE-T status

const BmcrR = 0x8000; // Reset
const BmcrAne = 0x1000; // Auto-Negotiation Enable
const BmcrAnr = 0x0200; // Restart Auto-Negotiation

const Ana10HD = 0x0020;
const Ana10FD = 0x0040;
const AnaTXHD = 0x0080;
const AnaTXFD = 0x0100;
const AnaP = 0x0400; // Pause
const AnaAP = 0x0800; // Asymmetrical Pause
const AnaCsma = 0x0001; // selector: IEEE 802.3

const Mscr1000THD = 0x0100;
const Mscr1000TFD = 0x0200;

const Adv2500TFD = 0x0080; // in PHY OCP 0xa5d4 (RGE_ADV_2500TFDX)

const Ramcode8125b = 0x0B99; // the PHY code rge loads (RGE_MAC_R25B_RCODE_VER)

/// Transmit descriptor (struct rge_tx_desc).  The 32 byte form goes
/// with bit 0 of MAC OCP 0xeb58, which rtl8125start sets as rge does.
const Td = extern struct {
    control: u32,
    vlan: u32,
    addrlo: u32,
    addrhi: u32,
    reserved: [4]u32,
};

/// Receive descriptor (struct rge_rx_desc).  This form goes with bit
/// 24 of Rcr, which is in RxcfgConfig8125b.
const Rd = extern struct {
    rsvd0: u32,
    rsvd1: u32,
    rss: u32,
    length: u16,
    hdrinfo: u16,
    addrlo: u32,
    addrhi: u32,
    vlan: u32,
    control: u32,
};

comptime {
    std.debug.assert(@sizeOf(Td) == 32);
    std.debug.assert(@offsetOf(Td, "addrlo") == 8);
    std.debug.assert(@sizeOf(Rd) == 32);
    std.debug.assert(@offsetOf(Rd, "addrlo") == 16);
    std.debug.assert(@offsetOf(Rd, "vlan") == 24);
    std.debug.assert(@offsetOf(Rd, "control") == 28);
}

// General Descriptor control
const Eor = 0x40000000; // End of Descriptor Ring
const Own = 0x80000000; // Ownership

// Transmit Descriptor control
const TxflMASK = 0x0000FFFF; // Transmit Frame Length
const Txer = 0x00800000; // (RGE_TDCMDSTS_TXERR)
const Ls = 0x10000000; // Last Segment Descriptor
const Fs = 0x20000000; // First Segment Descriptor

// Receive Descriptor control
const RxflMASK = 0x00003FFF; // Receive Frame Length, buffer size
const Res = 0x00100000; // Receive Error Summary
const Rls = 0x01000000; // Last Segment Descriptor
const Rfs = 0x02000000; // First Segment Descriptor

// Ring sizes  (<= 1024)
const Ntd = 64; // Transmit Ring
const Nrd = 256; // Receive Ring

const Mtu = ETHERMAXTU;
const Mps = devether.ROUNDUP(ETHERMAXTU + 4, 128);

const Minframe = 60; // without the CRC (RGE_MIN_FRAMELEN)
const Minpatch = 47; // (RGE_MIN_PATCHLEN)

const Pollms = 10; // rtl8125watch's period once it polls
const Nservice = 32; // turns of the interrupt routine's loop

const Dtcc = extern struct {
    txok: u64 align(1),
    rxok: u64 align(1),
    txer: u64 align(1),
    rxer: u32 align(1),
    misspkt: u16 align(1),
    fae: u16 align(1),
    tx1col: u32 align(1),
    txmcol: u32 align(1),
    rxokph: u64 align(1),
    rxokbrd: u64 align(1),
    rxokmu: u32 align(1),
    txabt: u16 align(1),
    txundrn: u16 align(1),
};

comptime {
    std.debug.assert(@sizeOf(Dtcc) == 64);
}

const Ctlr = struct {
    lock: Lock = .{}, // transmit ring, rcr, mchash, running

    reg: usize = 0, // registers, mapped
    port: u64 = 0, // and where they are
    pcidev: *Pcidev = undefined,
    next: ?*Ctlr = null,
    active: bool = false,

    alock: QLock = .{}, // attach
    init: bool = false,
    reset: Rendez = .{},
    pause: Rendez = .{}, // the reseter's rest between restarts
    needreset: bool = false,

    olock: QLock = .{}, // the OCP, EPHY and CSI registers; rtl8125start
    ilock: Lock = .{}, // rtl8125service: receive ring, Imr
    running: bool = false, // the chip is up; under lock and ilock

    macv: u32 = 0, // MAC version
    ramcode: u16 = 0, // the PHY's code version, as found
    nophy: bool = false, // *rtl8125nophy

    mchash: u64 = 0, // multicast hash

    td: [*]volatile Td = undefined, // descriptor ring
    tb: [*]?*Block = undefined, // transmit buffers
    ntd: usize = 0,

    tdh: usize = 0, // head - producer index (host)
    tdt: usize = 0, // tail - consumer index (NIC)
    ntq: usize = 0,

    rd: [*]volatile Rd = undefined, // descriptor ring
    rb: [*]?*Block = undefined, // receive buffers
    nrd: usize = 0,

    rdh: usize = 0, // head - producer index (NIC)
    rdt: usize = 0, // tail - consumer index (host)
    nrq: usize = 0,

    pool: Bpool = .{},

    tcr: u32 = 0, // transmit configuration register
    rcr: u32 = 0, // receive configuration register
    imr: u32 = 0,

    watch: Rendez = .{},
    polling: bool = false, // no interrupts: rtl8125watch does their work
    lastnintr: u32 = 0,
    lastphy: u32 = 0xFFFFFFFF, // Phystatus when rtl8125link last looked

    slock: QLock = .{}, // statistics
    dtcc: *align(1) volatile Dtcc = undefined,
    nintr: u32 = 0, // interrupts
    nlost: u32 = 0, // times rtl8125watch found work no interrupt came for
    npoll: u32 = 0, // times rtl8125watch polled
    nspin: u32 = 0, // times the interrupt routine gave up on Isr
    nreset: u32 = 0, // times rtl8125init ran
    nlink: u32 = 0, // link changes seen
    nocp: u32 = 0, // PHY OCP, EPHY and CSI accesses that timed out
    txpkt: u32 = 0, // frames given to the chip
    txdone: u32 = 0, // frames it gave back
    txerr: u32 = 0, // of those, with Txer
    txpad: u32 = 0, // frames padded
    txdrop: u32 = 0, // frames dropped for want of a block to pad into
    rxpkt: u32 = 0, // frames received
    rok: u32 = 0,
    tok: u32 = 0,
    ter: u32 = 0,
    tdu: u32 = 0,
    txdu: u32 = 0,
    rer: u32 = 0,
    rdu: u32 = 0,
    punlc: u32 = 0,
    serr: u32 = 0,
    fovw: u32 = 0,
    res: u32 = 0, // frames with Res
    frag: u32 = 0, // partial packets; rb was too small
    badlen: u32 = 0, // frames with an impossible length
};

var rtl8125ctlrhead: ?*Ctlr = null;
var rtl8125ctlrtail: ?*Ctlr = null;

fn ctlrof(edev: *Ether) *Ctlr {
    return @ptrCast(@alignCast(edev.ctlr.?));
}

fn csr8r(c: *Ctlr, r: usize) u8 {
    if (builtin.is_test) return @truncate(Sim.rd(r, 1));
    return @as(*volatile u8, @ptrFromInt(c.reg + r)).*;
}

fn csr16r(c: *Ctlr, r: usize) u16 {
    if (builtin.is_test) return @truncate(Sim.rd(r, 2));
    return @as(*volatile u16, @ptrFromInt(c.reg + r)).*;
}

fn csr32r(c: *Ctlr, r: usize) u32 {
    if (builtin.is_test) return Sim.rd(r, 4);
    return @as(*volatile u32, @ptrFromInt(c.reg + r)).*;
}

fn csr8w(c: *Ctlr, r: usize, b: u8) void {
    if (builtin.is_test) return Sim.wr(r, 1, b);
    @as(*volatile u8, @ptrFromInt(c.reg + r)).* = b;
}

fn csr16w(c: *Ctlr, r: usize, w: u16) void {
    if (builtin.is_test) return Sim.wr(r, 2, w);
    @as(*volatile u16, @ptrFromInt(c.reg + r)).* = w;
}

fn csr32w(c: *Ctlr, r: usize, l: u32) void {
    if (builtin.is_test) return Sim.wr(r, 4, l);
    @as(*volatile u32, @ptrFromInt(c.reg + r)).* = l;
}

fn microdelay(us: u64) void {
    if (builtin.is_test) return;
    arch.microdelay(us);
}

fn coherence() void {
    if (builtin.is_test) return;
    arch.coherence();
}

/// PCIWADDR
fn pciwaddr(va: usize) u64 {
    if (builtin.is_test) return va;
    return arch.paddr(va);
}

/// What to write to Macocp to write val to MAC OCP register reg, or
/// with read set to ask for it.  The registers are 16 bits wide at
/// even addresses.
fn macocpcmd(reg: u16, val: u16, read: bool) u32 {
    var r = @as(u32, reg >> 1) << 16;
    if (!read)
        r = (r + val) | Flag;
    return r;
}

/// rge_write_mac_ocp
fn macocpw(ctlr: *Ctlr, reg: u16, val: u16) void {
    csr32w(ctlr, Macocp, macocpcmd(reg, val, false));
}

/// rge_read_mac_ocp
fn macocpr(ctlr: *Ctlr, reg: u16) u16 {
    csr32w(ctlr, Macocp, macocpcmd(reg, 0, true));
    return @truncate(csr32r(ctlr, Macocp) & DataMASK);
}

/// RGE_MAC_SETBIT
fn macocpset(ctlr: *Ctlr, reg: u16, bits: u16) void {
    macocpw(ctlr, reg, macocpr(ctlr, reg) | bits);
}

/// RGE_MAC_CLRBIT
fn macocpclr(ctlr: *Ctlr, reg: u16, bits: u16) void {
    macocpw(ctlr, reg, macocpr(ctlr, reg) & ~bits);
}

/// val = rge_read_mac_ocp(sc, reg) & ~clr;
/// rge_write_mac_ocp(sc, reg, val | set);
fn macocpmod(ctlr: *Ctlr, reg: u16, clr: u16, set: u16) void {
    const val = macocpr(ctlr, reg) & ~clr;
    macocpw(ctlr, reg, val | set);
}

/// What to write to Phyocp, as macocpcmd.
fn phyocpcmd(reg: u16, val: u16, read: bool) u32 {
    var r = @as(u32, reg >> 1) << 16;
    if (!read)
        r |= Flag | @as(u32, val);
    return r;
}

/// rge_write_phy_ocp
fn phyocpw(ctlr: *Ctlr, reg: u16, val: u16) void {
    csr32w(ctlr, Phyocp, phyocpcmd(reg, val, false));
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        microdelay(1);
        if (csr32r(ctlr, Phyocp) & Flag == 0)
            break;
    }
    if (i == 20000)
        ctlr.nocp +%= 1;
}

/// rge_read_phy_ocp
fn phyocpr(ctlr: *Ctlr, reg: u16) u16 {
    var val: u32 = phyocpcmd(reg, 0, true);
    csr32w(ctlr, Phyocp, val);
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        microdelay(1);
        val = csr32r(ctlr, Phyocp);
        if (val & Flag != 0)
            break;
    }
    if (i == 20000)
        ctlr.nocp +%= 1;
    return @truncate(val & DataMASK);
}

/// RGE_PHY_SETBIT
fn phyocpset(ctlr: *Ctlr, reg: u16, bits: u16) void {
    phyocpw(ctlr, reg, phyocpr(ctlr, reg) | bits);
}

/// RGE_PHY_CLRBIT
fn phyocpclr(ctlr: *Ctlr, reg: u16, bits: u16) void {
    phyocpw(ctlr, reg, phyocpr(ctlr, reg) & ~bits);
}

/// val = rge_read_phy_ocp(sc, reg) & ~clr;
/// rge_write_phy_ocp(sc, reg, val | set);
fn phyocpmod(ctlr: *Ctlr, reg: u16, clr: u16, set: u16) void {
    const val = phyocpr(ctlr, reg) & ~clr;
    phyocpw(ctlr, reg, val | set);
}

/// The PHY OCP register that is MII register ra: what rge_read_phy and
/// rge_write_phy work out when their addr is 0.
fn miiocp(ra: u16) u16 {
    return 0xA400 + ra * 2;
}

/// rge_read_phy(sc, 0, ra)
fn rtl8125miimir(ctlr: *Ctlr, ra: u16) u16 {
    return phyocpr(ctlr, miiocp(ra));
}

/// rge_write_phy(sc, 0, ra, data)
fn rtl8125miimiw(ctlr: *Ctlr, ra: u16, data: u16) void {
    phyocpw(ctlr, miiocp(ra), data);
}

/// rge_write_ephy: a register of the PCIe PHY
fn ephyw(ctlr: *Ctlr, reg: u16, val: u16) void {
    csr32w(ctlr, Ephyar, (@as(u32, reg & EphyaddrMASK) << EphyaddrSHIFT) | Flag | val);
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        microdelay(1);
        if (csr32r(ctlr, Ephyar) & Flag == 0)
            break;
    }
    if (i == 20000)
        ctlr.nocp +%= 1;
    microdelay(20);
}

/// rge_write_csi: the chip's own PCI configuration space
fn csiw(ctlr: *Ctlr, reg: u32, val: u32) void {
    csr32w(ctlr, Csidr, val);
    csr32w(ctlr, Csiar, (reg & CsiaddrMASK) | Csibyteen | Flag);
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        microdelay(1);
        if (csr32r(ctlr, Csiar) & Flag == 0)
            break;
    }
    if (i == 20000)
        ctlr.nocp +%= 1;
    microdelay(20);
}

/// rge_read_csi
fn csir(ctlr: *Ctlr, reg: u32) u32 {
    csr32w(ctlr, Csiar, (reg & CsiaddrMASK) | Csibyteen);
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        microdelay(1);
        if (csr32r(ctlr, Csiar) & Flag != 0)
            break;
    }
    if (i == 20000)
        ctlr.nocp +%= 1;
    microdelay(20);
    return csr32r(ctlr, Csidr);
}

/// Write the receive filter: ctlr.rcr and the multicast hash.
/// The byte order is rge_iff's, and ether8169.c's for its pci-e
/// variants.
fn rtl8125filter(ctlr: *Ctlr) void {
    csr32w(ctlr, Rcr, ctlr.rcr);
    csr32w(ctlr, Mar0, swabl(@truncate(ctlr.mchash >> 32)));
    csr32w(ctlr, Mar0 + 4, swabl(@truncate(ctlr.mchash)));
}

fn rtl8125promiscuous(arg: ?*anyopaque, on: bool) Error!void {
    const edev: *Ether = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(edev);
    ilock(&ctlr.lock);
    if (on)
        ctlr.rcr |= Aap
    else
        ctlr.rcr &= ~@as(u32, Aap);
    // DIFF: a chip being restarted gets it from rtl8125init
    if (ctlr.running)
        csr32w(ctlr, Rcr, ctlr.rcr);
    iunlock(&ctlr.lock);
}

// everyone else uses 0x04c11db7, but they both produce the same crc
const Etherpolybe = 0x04c11db6;

fn ethercrcbe(addr: []const u8) u32 {
    var crc: u32 = ~@as(u32, 0);
    for (addr) |b| {
        var c: u32 = b;
        for (0..8) |_| {
            const carry: u32 = (if (crc & (1 << 31) != 0) @as(u32, 1) else 0) ^ (c & 1);
            crc <<= 1;
            c >>= 1;
            if (carry != 0)
                crc = (crc ^ Etherpolybe) | carry;
        }
    }
    return crc;
}

fn swabl(l: u32) u32 {
    return @byteSwap(l);
}

fn rtl8125multicast(arg: ?*anyopaque, eaddr: []const u8, add: bool) Error!void {
    if (!add)
        return; // ok to keep receiving on old mcast addrs

    const edev: *Ether = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(edev);
    ilock(&ctlr.lock);

    ctlr.mchash |= @as(u64, 1) << @intCast(ethercrcbe(eaddr[0..Eaddrlen]) >> 26);

    ctlr.rcr |= Am;
    // DIFF: a chip being restarted gets it from rtl8125init
    if (ctlr.running)
        rtl8125filter(ctlr);

    iunlock(&ctlr.lock);
}

/// Have the chip write its tally counters to ctlr.dtcc.
/// rge_kstat_read
fn rtl8125dtcc(ctlr: *Ctlr) bool {
    const command = csr8r(ctlr, Cr);
    if (command & Re == 0 or command == 0xFF)
        return false;

    const pa = pciwaddr(@intFromPtr(ctlr.dtcc));
    csr32w(ctlr, Dtccr + 4, @truncate(pa >> 32));
    _ = csr8r(ctlr, Cr);
    csr32w(ctlr, Dtccr, @truncate(pa));
    csr32w(ctlr, Dtccr, @as(u32, @truncate(pa)) | Dump);
    for (0..1000) |_| {
        if (csr32r(ctlr, Dtccr) & Dump == 0)
            return true;
        microdelay(10);
    }
    return false;
}

fn rtl8125ifstat(arg: ?*anyopaque, buf: []u8) Error!usize {
    const edev: *Ether = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(edev);
    qlock(&ctlr.slock);
    defer qunlock(&ctlr.slock);

    const dtcc = ctlr.dtcc;
    const tallied = ctlr.init and ctlr.running and rtl8125dtcc(ctlr);
    if (tallied) {
        edev.netif.oerrs = @truncate(@as(i64, @bitCast(dtcc.txer)));
        edev.netif.crcs = @bitCast(dtcc.rxer);
        edev.netif.frames = dtcc.fae;
        edev.netif.buffs = dtcc.misspkt;
    }
    edev.netif.overflows = @bitCast(ctlr.txdu +% ctlr.rdu);

    if (buf.len == 0)
        return 0;

    var s: fmt.Fmt = .{ .buf = buf };
    const p = ctlr.pcidev;

    // what the chip is, and the state of the driver
    fmt.fmtprint(&s, "rtl8125: macv %#8.8ux pci rev %#2.2ux ramcode %#4.4ux%s\n", .{
        ctlr.macv,                        p.rid, ctlr.ramcode,
        if (ctlr.nophy) " nophy" else "",
    });
    fmt.fmtprint(&s, "init %d running %d polling %d resets %ud ocptimeouts %ud\n", .{
        @intFromBool(ctlr.init), @intFromBool(ctlr.running), @intFromBool(ctlr.polling), ctlr.nreset, ctlr.nocp,
    });

    // interrupts
    fmt.fmtprint(&s, "isr %#8.8ux imr %#8.8ux want %#8.8ux intcfg0 %#2.2ux\n", .{
        csr32r(ctlr, Isr), csr32r(ctlr, Imr), ctlr.imr, csr8r(ctlr, Intcfg0),
    });
    fmt.fmtprint(&s, "intr %ud lost %ud polls %ud spin %ud\n", .{ ctlr.nintr, ctlr.nlost, ctlr.npoll, ctlr.nspin });
    fmt.fmtprint(&s, "rok %ud rer %ud tok %ud ter %ud rdu %ud punlc %ud fovw %ud tdu %ud serr %ud\n", .{
        ctlr.rok, ctlr.rer, ctlr.tok, ctlr.ter, ctlr.rdu, ctlr.punlc, ctlr.fovw, ctlr.tdu, ctlr.serr,
    });
    const msi = pci.pcicap(p, pci.PciCapMSI);
    const msix = pci.pcicap(p, pci.PciCapMSIX);
    fmt.fmtprint(&s, "pci: pcr %#4.4ux psr %#4.4ux msi %#4.4ux msix %#4.4ux\n", .{
        pci.pcicfgr16(p, pci.PciPCR),                   pci.pcicfgr16(p, pci.PciPSR),
        if (msi > 0) pci.pcicfgr16(p, msi + 2) else -1, if (msix > 0) pci.pcicfgr16(p, msix + 2) else -1,
    });

    // link
    const phystatus = csr16r(ctlr, Phystatus);
    fmt.fmtprint(&s, "phystatus %#4.4ux link %d mbps %d changes %ud\n", .{
        phystatus, edev.netif.link, edev.netif.mbps, ctlr.nlink,
    });

    // configuration
    fmt.fmtprint(&s, "cr %#2.2ux tcr %#8.8ux rcr %#8.8ux want %#8.8ux cplusc %#4.4ux rms %ud\n", .{
        csr8r(ctlr, Cr), csr32r(ctlr, Tcr), csr32r(ctlr, Rcr), ctlr.rcr, csr16r(ctlr, Cplusc), csr16r(ctlr, Rms),
    });
    fmt.fmtprint(&s, "mcucmd %#2.2ux ppsw %#2.2ux config1 %#2.2ux config2 %#2.2ux config5 %#2.2ux\n", .{
        csr8r(ctlr, Mcucmd), csr8r(ctlr, Ppsw), csr8r(ctlr, Config1), csr8r(ctlr, Config2), csr8r(ctlr, Config5),
    });
    fmt.fmtprint(&s, "ea %E idr %#8.8ux %#4.4ux made %#8.8ux %#4.4ux\n", .{
        devether.ea(edev.ea), csr32r(ctlr, Idr0), csr16r(ctlr, Idr0 + 4), csr32r(ctlr, Addr0), csr16r(ctlr, Addr1),
    });

    // rings
    if (ctlr.init) {
        fmt.fmtprint(&s, "tx: tdh %ud tdt %ud ntq %ud td[tdh] %#8.8ux given %ud done %ud err %ud pad %ud drop %ud txdu %ud\n", .{
            ctlr.tdh,    ctlr.tdt,    ctlr.ntq,   ctlr.td[ctlr.tdh].control,
            ctlr.txpkt,  ctlr.txdone, ctlr.txerr, ctlr.txpad,
            ctlr.txdrop, ctlr.txdu,
        });
        fmt.fmtprint(&s, "rx: rdh %ud rdt %ud nrq %ud rd[rdh] %#8.8ux got %ud res %ud frag %ud badlen %ud\n", .{
            ctlr.rdh,   ctlr.rdt, ctlr.nrq,  ctlr.rd[ctlr.rdh].control,
            ctlr.rxpkt, ctlr.res, ctlr.frag, ctlr.badlen,
        });
        fmt.fmtprint(&s, "td %#llux rd %#llux tnpds %#8.8ux%8.8ux rdsar %#8.8ux%8.8ux\n", .{
            pciwaddr(@intFromPtr(ctlr.td)), pciwaddr(@intFromPtr(ctlr.rd)),
            csr32r(ctlr, Tnpds + 4),        csr32r(ctlr, Tnpds),
            csr32r(ctlr, Rdsar + 4),        csr32r(ctlr, Rdsar),
        });
    }

    // the chip's own counters
    if (tallied) {
        fmt.fmtprint(&s, "TxOk: %llud\n", .{dtcc.txok});
        fmt.fmtprint(&s, "RxOk: %llud\n", .{dtcc.rxok});
        fmt.fmtprint(&s, "TxEr: %llud\n", .{dtcc.txer});
        fmt.fmtprint(&s, "RxEr: %ud\n", .{dtcc.rxer});
        fmt.fmtprint(&s, "MissPkt: %ud\n", .{dtcc.misspkt});
        fmt.fmtprint(&s, "FAE: %ud\n", .{dtcc.fae});
        fmt.fmtprint(&s, "Tx1Col: %ud\n", .{dtcc.tx1col});
        fmt.fmtprint(&s, "TxMCol: %ud\n", .{dtcc.txmcol});
        fmt.fmtprint(&s, "RxOkPh: %llud\n", .{dtcc.rxokph});
        fmt.fmtprint(&s, "RxOkBrd: %llud\n", .{dtcc.rxokbrd});
        fmt.fmtprint(&s, "RxOkMu: %ud\n", .{dtcc.rxokmu});
        fmt.fmtprint(&s, "TxAbt: %ud\n", .{dtcc.txabt});
        fmt.fmtprint(&s, "TxUndrn: %ud\n", .{dtcc.txundrn});
    } else {
        fmt.fmtprint(&s, "tally counters: not read\n", .{});
    }

    // the PHY and the MAC's OCP registers, unless rtl8125start has them
    if (ql.canqlock(&ctlr.olock)) {
        fmt.fmtprint(&s, "phy: bmcr %#4.4ux bmsr %#4.4ux anar %#4.4ux anlpar %#4.4ux mscr %#4.4ux mssr %#4.4ux a5d4 %#4.4ux a5d6 %#4.4ux\n", .{
            rtl8125miimir(ctlr, Bmcr),   rtl8125miimir(ctlr, Bmsr), rtl8125miimir(ctlr, Anar),
            rtl8125miimir(ctlr, Anlpar), rtl8125miimir(ctlr, Mscr), rtl8125miimir(ctlr, Mssr),
            phyocpr(ctlr, 0xA5D4),       phyocpr(ctlr, 0xA5D6),
        });
        fmt.fmtprint(&s, "macocp: eb58 %#4.4ux e614 %#4.4ux c0ac %#4.4ux fc26 %#4.4ux fc48 %#4.4ux\n", .{
            macocpr(ctlr, 0xEB58), macocpr(ctlr, 0xE614), macocpr(ctlr, 0xC0AC), macocpr(ctlr, 0xFC26), macocpr(ctlr, 0xFC48),
        });
        qunlock(&ctlr.olock);
    } else {
        fmt.fmtprint(&s, "phy: busy\n", .{});
    }

    return s.n;
}

/// Mask and acknowledge the chip's interrupts.
/// DIFF: the C's also clears Cr, which rge never does; the RTL8125
/// is stopped with rtl8125reset.
fn rtl8125halt(ctlr: *Ctlr) void {
    csr32w(ctlr, Imr, 0);
    csr32w(ctlr, Isr, csr32r(ctlr, Isr));
}

/// rge_reset
fn rtl8125reset(ctlr: *Ctlr) i32 {
    csr32w(ctlr, Rcr, csr32r(ctlr, Rcr) & ~@as(u32, Aap | Apm | Am | Ab | Ar | Aer));

    // Enable RXDV gate.
    csr8w(ctlr, Ppsw, csr8r(ctlr, Ppsw) | 0x08);

    csr8w(ctlr, Cr, csr8r(ctlr, Cr) | Stopreq);
    microdelay(200);

    for (0..3000) |_| {
        microdelay(50);
        if (csr8r(ctlr, Mcucmd) & (Rxfifoempty | Txfifoempty) == (Rxfifoempty | Txfifoempty))
            break;
    }
    for (0..3000) |_| {
        microdelay(50);
        if (csr16r(ctlr, Coal) & 0x0103 == 0x0103)
            break;
    }

    csr8w(ctlr, Cr, csr8r(ctlr, Cr) & (Te | Re));

    // Soft reset.
    csr8w(ctlr, Cr, Rst);

    for (0..100) |_| {
        microdelay(100);
        if (csr8r(ctlr, Cr) & Rst == 0)
            return 0;
    }
    return -1;
}

/// rge_hw_reset
fn rtl8125hwreset(ctlr: *Ctlr) i32 {
    // Disable interrupts
    rtl8125halt(ctlr);

    // Clear timer interrupts.
    csr32w(ctlr, Timerint0, 0);
    csr32w(ctlr, Timerint1, 0);
    csr32w(ctlr, Timerint2, 0);
    csr32w(ctlr, Timerint3, 0);

    return rtl8125reset(ctlr);
}

/// rge_disable_aspm_clkreq
fn rtl8125noaspm(ctlr: *Ctlr) void {
    const unlock = csr8r(ctlr, Cr9346) & (Eem1 | Eem0) != (Eem1 | Eem0);

    if (unlock)
        csr8w(ctlr, Cr9346, csr8r(ctlr, Cr9346) | (Eem1 | Eem0));

    csr8w(ctlr, Config2, csr8r(ctlr, Config2) & ~@as(u8, Clkreqen));
    csr8w(ctlr, Config5, csr8r(ctlr, Config5) & ~@as(u8, Pmests));

    if (unlock)
        csr8w(ctlr, Cr9346, csr8r(ctlr, Cr9346) & ~@as(u8, Eem1 | Eem0));
}

/// Wait for the chip to say its FIFOs are shared out (the two loops
/// of rge_exit_oob).
fn rtl8125waitll(ctlr: *Ctlr) void {
    for (0..10) |_| {
        microdelay(100);
        if (csr16r(ctlr, Twicmd) & 0x0200 != 0)
            break;
    }
}

/// Take the chip from whoever ran it while the machine was off or in
/// its firmware.
/// rge_exit_oob
fn rtl8125exitoob(ctlr: *Ctlr) i32 {
    // Disable RealWoW.
    macocpw(ctlr, 0xC0BC, 0x00FF);

    if (rtl8125reset(ctlr) < 0)
        return -1;

    // Disable OOB.
    csr8w(ctlr, Mcucmd, csr8r(ctlr, Mcucmd) & ~@as(u8, Isoob));

    macocpclr(ctlr, 0xE8DE, 0x4000);

    rtl8125waitll(ctlr);

    macocpw(ctlr, 0xC0AA, 0x07D0);
    macocpw(ctlr, 0xC0A6, 0x01B5);
    macocpw(ctlr, 0xC01E, 0x5555);

    rtl8125waitll(ctlr);

    if (macocpr(ctlr, 0xD42C) & 0x0100 != 0) {
        for (0..100) |_| {
            if (phyocpr(ctlr, 0xA420) & 0x0007 == 2)
                break;
            microdelay(1000);
        }
        macocpclr(ctlr, 0xD42C, 0x0100);
        phyocpclr(ctlr, 0xA466, 0x0001);
        phyocpclr(ctlr, 0xA468, 0x000A);
    }

    return 0;
}

/// rge_set_phy_power(sc, 1)
fn rtl8125phypower(ctlr: *Ctlr) void {
    csr8w(ctlr, Pmch, csr8r(ctlr, Pmch) | 0xC0);

    rtl8125miimiw(ctlr, Bmcr, BmcrAne);

    for (0..100) |_| {
        if (phyocpr(ctlr, 0xA420) & 0x0007 == 3)
            break;
        microdelay(1000);
    }
}

/// rge_hw_init, without the microcode
fn rtl8125hwinit(ctlr: *Ctlr) void {
    rtl8125noaspm(ctlr);
    csr8w(ctlr, Reg_f1, csr8r(ctlr, Reg_f1) & ~@as(u8, 0x80));

    // Disable UPS.
    macocpclr(ctlr, 0xD40A, 0x0010);

    // Disable MAC MCU.
    rtl8125noaspm(ctlr);
    macocpw(ctlr, 0xFC48, 0);
    var reg: u16 = 0xFC28;
    while (reg < 0xFC48) : (reg += 2)
        macocpw(ctlr, reg, 0);
    microdelay(3000);
    macocpw(ctlr, 0xFC26, 0);

    // rge_mac_config_mcu: rge_switch_mcu_ram_page(sc, 0), and then
    // the patch that is not loaded here
    macocpmod(ctlr, 0xE446, 0x0003, 0);

    // Set PCIe uncorrectable error status.
    csiw(ctlr, 0x108, csir(ctlr, 0x108) | 0x00100000);
}

/// rge_chipinit
fn rtl8125chipinit(ctlr: *Ctlr) i32 {
    if (rtl8125exitoob(ctlr) < 0)
        return -1;
    rtl8125phypower(ctlr);
    rtl8125hwinit(ctlr);
    return rtl8125hwreset(ctlr);
}

/// mac_r25b_ephy
const ephy8125b = [_][2]u16{
    .{ 0x000B, 0xA908 }, .{ 0x001E, 0x20EB }, .{ 0x0022, 0x0023 },
    .{ 0x0002, 0x60C2 }, .{ 0x0029, 0xFF00 }, .{ 0x004B, 0xA908 },
    .{ 0x005E, 0x28EB }, .{ 0x0062, 0x0023 }, .{ 0x0042, 0x60C2 },
    .{ 0x0069, 0xFF00 },
};

/// rge_phy_config_mac_r25b, after the rge_phy_config_mcu that is
/// not done here
fn rtl8125phyconfig8125b(ctlr: *Ctlr) void {
    phyocpset(ctlr, 0xA442, 0x0800);
    phyocpmod(ctlr, 0xAC46, 0x00F0, 0x0090);
    phyocpmod(ctlr, 0xAD30, 0x0003, 0x0001);
    phyocpw(ctlr, 0xB87C, 0x80F5);
    phyocpw(ctlr, 0xB87E, 0x760E);
    phyocpw(ctlr, 0xB87C, 0x8107);
    phyocpw(ctlr, 0xB87E, 0x360E);
    phyocpw(ctlr, 0xB87C, 0x8551);
    phyocpmod(ctlr, 0xB87E, 0xFF00, 0x0800);
    phyocpmod(ctlr, 0xBF00, 0xE000, 0xA000);
    phyocpmod(ctlr, 0xBF46, 0x0F00, 0x0300);
    for (0..10) |i| {
        phyocpw(ctlr, 0xA436, @intCast(0x8044 + i * 6));
        phyocpw(ctlr, 0xA438, 0x2417);
    }
    phyocpset(ctlr, 0xA4CA, 0x0040);
    phyocpmod(ctlr, 0xBF84, 0xE000, 0xA000);
    phyocpw(ctlr, 0xA436, 0x8170);
    phyocpmod(ctlr, 0xA438, 0x2700, 0xD800);
    phyocpset(ctlr, 0xA424, 0x0008);
}

/// rge_phy_config
fn rtl8125phyconfig(ctlr: *Ctlr) i32 {
    // rge_ephy_config_mac_r25b
    for (ephy8125b) |e|
        ephyw(ctlr, e[0], e[1]);

    // PHY reset.
    rtl8125miimiw(ctlr, Anar, rtl8125miimir(ctlr, Anar) & ~@as(u16, AnaTXFD | AnaTXHD | Ana10FD | Ana10HD));
    rtl8125miimiw(ctlr, Mscr, rtl8125miimir(ctlr, Mscr) & ~@as(u16, Mscr1000TFD | Mscr1000THD));
    phyocpclr(ctlr, 0xA5D4, Adv2500TFD);
    rtl8125miimiw(ctlr, Bmcr, BmcrR | BmcrAne | BmcrAnr);
    var i: usize = 0;
    while (i < 2500) : (i += 1) {
        if (rtl8125miimir(ctlr, Bmcr) & BmcrR == 0)
            break;
        microdelay(1000);
    }
    if (i == 2500)
        return -1;

    // Read ram code version.
    phyocpw(ctlr, 0xA436, 0x801E);
    ctlr.ramcode = phyocpr(ctlr, 0xA438);

    if (!ctlr.nophy)
        rtl8125phyconfig8125b(ctlr);

    phyocpclr(ctlr, 0xA5B4, 0x8000);

    // Disable EEE.
    macocpclr(ctlr, 0xE040, 0x0003);
    phyocpset(ctlr, 0xA432, 0x0010);

    phyocpclr(ctlr, 0xA5D0, 0x0006);
    phyocpclr(ctlr, 0xA6D4, 0x0001);
    phyocpclr(ctlr, 0xA6D8, 0x0010);
    phyocpclr(ctlr, 0xA428, 0x0080);
    phyocpclr(ctlr, 0xA4A2, 0x0200);

    // Disable advanced EEE.
    macocpclr(ctlr, 0xE052, 0x0001);
    phyocpclr(ctlr, 0xA442, 0x3000);
    phyocpclr(ctlr, 0xA430, 0x8000);

    return 0;
}

/// Advertise everything from 10Mbps half duplex to 2.5Gbps and start
/// autonegotiation.
/// rge_ifmedia_upd, for IFM_AUTO
fn rtl8125mediaupd(ctlr: *Ctlr) void {
    // Disable Gigabit Lite.
    phyocpclr(ctlr, 0xA428, 0x0200);
    phyocpclr(ctlr, 0xA5EA, 0x0001);

    var val = phyocpr(ctlr, 0xA5D4);
    val &= ~@as(u16, Adv2500TFD);
    val |= Adv2500TFD;

    // DIFF: rge leaves the selector field (AnaCsma) zero
    rtl8125miimiw(ctlr, Anar, AnaTXFD | AnaTXHD | Ana10FD | Ana10HD | AnaAP | AnaP | AnaCsma);
    rtl8125miimiw(ctlr, Mscr, Mscr1000TFD | Mscr1000THD);
    phyocpw(ctlr, 0xA5D4, val);
    rtl8125miimiw(ctlr, Bmcr, BmcrR | BmcrAne | BmcrAnr);
}

fn rtl8125replenish(ctlr: *Ctlr) void {
    var x = ctlr.rdt;
    while (NEXT(x, ctlr.nrd) != ctlr.rdh) {
        const bp = ab.iallocbp(&ctlr.pool) orelse
            break;
        ctlr.rb[x] = bp;
        ctlr.nrq += 1;
        const pa = pciwaddr(@intFromPtr(bp.rp));
        const d = &ctlr.rd[x];
        d.addrlo = @truncate(pa);
        d.addrhi = @truncate(pa >> 32);
        d.vlan = 0;
        coherence();
        // DIFF: the room after rp, which is what the chip may fill;
        // the C says BALLOC(bp).
        d.control = rdcontrol(d.control, @intFromPtr(bp.lim) - @intFromPtr(bp.rp));
        x = NEXT(x, ctlr.nrd);
        ctlr.rdt = x;
    }
}

/// The control word that gives the chip a receive descriptor with a
/// buffer of size bytes.
fn rdcontrol(old: u32, size: usize) u32 {
    return (old & Eor) | Own | @as(u32, @intCast(@min(size, RxflMASK)));
}

/// The control word that gives the chip a transmit descriptor with a
/// whole frame of len bytes.
fn tdcontrol(old: u32, len: usize) u32 {
    return (old & Eor) | Own | Fs | Ls | (@as(u32, @intCast(len)) & TxflMASK);
}

/// Bring a stopped chip to where only Cr and Imr are missing: all of
/// rge_init between its rge_stop and its "Enable transmit and
/// receive", for an RTL8125B with one queue.  The rings must be
/// ready.  Called with olock held and `running` false.
fn rtl8125start(ctlr: *Ctlr, ea: *const [Eaddrlen]u8) Error!void {
    // rge_stop
    csr32w(ctlr, Rcr, csr32r(ctlr, Rcr) & ~@as(u32, Aap | Apm | Am | Ab | Ar | Aer));
    if (rtl8125hwreset(ctlr) < 0)
        return proc.errorf("reset failed", .{});
    macocpclr(ctlr, 0xC0AC, 0x1F80);

    // Set MAC address.  (rge_set_macaddr)
    csr8w(ctlr, Cr9346, csr8r(ctlr, Cr9346) | (Eem1 | Eem0));
    csr32w(ctlr, Idr0, @as(u32, ea[3]) << 24 | @as(u32, ea[2]) << 16 | @as(u32, ea[1]) << 8 | ea[0]);
    csr32w(ctlr, Idr0 + 4, @as(u32, ea[5]) << 8 | ea[4]);
    csr8w(ctlr, Cr9346, csr8r(ctlr, Cr9346) & ~@as(u8, Eem1 | Eem0));

    if (rtl8125chipinit(ctlr) < 0)
        return proc.errorf("reset failed", .{});

    if (rtl8125phyconfig(ctlr) < 0)
        return proc.errorf("phy reset failed", .{});

    csr8w(ctlr, Cr9346, csr8r(ctlr, Cr9346) | (Eem1 | Eem0));

    csr8w(ctlr, Reg_f1, csr8r(ctlr, Reg_f1) & ~@as(u8, 0x80));
    rtl8125noaspm(ctlr);
    // DIFF: rge's is for its jumbo MTU
    csr16w(ctlr, Eeetxidle, Mtu + 32);

    // Load the addresses of the RX and TX lists into the chip.
    // DIFF: high half first, as ether8169.c has it; rge writes the
    // low half first.
    var pa = pciwaddr(@intFromPtr(ctlr.rd));
    csr32w(ctlr, Rdsar + 4, @truncate(pa >> 32));
    csr32w(ctlr, Rdsar, @truncate(pa));

    pa = pciwaddr(@intFromPtr(ctlr.td));
    csr32w(ctlr, Tnpds + 4, @truncate(pa >> 32));
    csr32w(ctlr, Tnpds, @truncate(pa));

    // Set the initial RX and TX configurations.
    csr32w(ctlr, Rcr, RxcfgConfig8125b);
    csr32w(ctlr, Tcr, TxcfgConfig);
    ctlr.tcr = csr32r(ctlr, Tcr);

    // DIFF: rge reaches register 0x70c of the configuration space
    // through its bus; the chip's own way to it does not need ECAM.
    csiw(ctlr, 0x70C, (csir(ctlr, 0x70C) & ~@as(u32, 0x3F000000)) | 0x27000000);

    csr16w(ctlr, Reg_382, 0x221B);

    csr32w(ctlr, Rssctrl, 0);

    // one receive queue
    csr16w(ctlr, Rxqctrl, csr16r(ctlr, Rxqctrl) & ~@as(u16, 0x001C));

    csr8w(ctlr, Config1, csr8r(ctlr, Config1) & ~@as(u8, Speeddown));

    macocpw(ctlr, 0xC140, 0xFFFF);
    macocpw(ctlr, 0xC142, 0xFFFF);

    // 32 byte transmit descriptors
    macocpset(ctlr, 0xEB58, 0x0001);

    macocpmod(ctlr, 0xE614, 0x0700, 0x0200);

    // one transmit queue
    macocpmod(ctlr, 0xE63E, 0x0C00, 0);

    macocpmod(ctlr, 0xE63E, 0x0030, 0x0020);

    macocpclr(ctlr, 0xC0B4, 0x0001);
    macocpset(ctlr, 0xC0B4, 0x0001);

    macocpset(ctlr, 0xC0B4, 0x000C);

    macocpmod(ctlr, 0xEB6A, 0x00FF, 0x0033);

    macocpmod(ctlr, 0xEB50, 0x03E0, 0x0040);

    macocpclr(ctlr, 0xE056, 0x00F0);

    csr8w(ctlr, Tdfnr, 0x10);

    macocpclr(ctlr, 0xE040, 0x1000);

    macocpmod(ctlr, 0xEA1C, 0x0003, 0x0001);

    macocpw(ctlr, 0xE0C0, 0x4000);

    macocpset(ctlr, 0xE052, 0x0060);
    macocpclr(ctlr, 0xE052, 0x0088);

    macocpmod(ctlr, 0xD430, 0x0FFF, 0x045F);

    csr8w(ctlr, Dllpr, csr8r(ctlr, Dllpr) | (Pfmen | Tx10mpsen));
    csr8w(ctlr, Ppsw, csr8r(ctlr, Ppsw) | 0x40);

    // Disable EEE plus.
    macocpclr(ctlr, 0xE080, 0x0002);

    macocpclr(ctlr, 0xEA1C, 0x0004);

    // Clear tcam entries.
    macocpset(ctlr, 0xEB54, 0x0001);
    microdelay(1);
    macocpclr(ctlr, 0xEB54, 0x0001);

    csr16w(ctlr, Reg_1880, csr16r(ctlr, Reg_1880) & ~@as(u16, 0x0030));

    // Config interrupt type: Imr and Isr, one vector, whether the
    // interrupt is a pin, MSI or MSI-X.
    csr8w(ctlr, Intcfg0, csr8r(ctlr, Intcfg0) & ~@as(u8, Intcfgen));

    // Clear timer interrupts.
    csr32w(ctlr, Timerint0, 0);
    csr32w(ctlr, Timerint1, 0);
    csr32w(ctlr, Timerint2, 0);
    csr32w(ctlr, Timerint3, 0);

    // Clear interrupt moderation timer.
    for (0..32) |i|
        csr32w(ctlr, Intmiti + i * 4, 0);

    macocpset(ctlr, 0xC0AC, 0x1F80);

    macocpw(ctlr, 0xE098, 0xC302);

    macocpclr(ctlr, 0xE032, 0x0003);
    csiw(ctlr, 0x98, csir(ctlr, 0x98) & ~@as(u32, 0x0000FF00));
    microdelay(20);

    macocpclr(ctlr, 0xE092, 0x00FF);

    // DIFF: rge sets Rxchksum; nothing here looks at the result.
    // Tags stay in the frames (no RXCFG_VLANSTRIP).
    csr16w(ctlr, Cplusc, csr16r(ctlr, Cplusc) & ~@as(u16, Rxchksum));
    _ = csr16r(ctlr, Cplusc);

    // Set Maximum frame size.
    // DIFF: one buffer's worth; rge's is for jumbo frames in pieces.
    csr16w(ctlr, Rms, Mps);

    // Disable RXDV gate.
    csr8w(ctlr, Ppsw, csr8r(ctlr, Ppsw) & ~@as(u8, 0x08));

    // Program promiscuous mode and multicast filters.  (rge_iff)
    rtl8125filter(ctlr);

    rtl8125noaspm(ctlr);

    csr8w(ctlr, Cr9346, csr8r(ctlr, Cr9346) & ~@as(u8, Eem1 | Eem0));
    microdelay(10);

    rtl8125mediaupd(ctlr);
}

/// The end of rge_init: enable transmit and receive, and interrupts
/// as rge_setup_intr does for RGE_IMTYPE_NONE.  Called with lock and
/// ilock held.
fn rtl8125enable(ctlr: *Ctlr) void {
    // DIFF: again, for what promiscuous and multicast changed since
    rtl8125filter(ctlr);

    // Enable transmit and receive.
    csr8w(ctlr, Cr, Te | Re);

    // DIFF: start with nothing waiting, so that the first event is
    // sure to make Isr&Imr go from zero to something.
    csr32w(ctlr, Isr, csr32r(ctlr, Isr));

    // Enable interrupts.
    csr32w(ctlr, Imr, ctlr.imr);
    csr32w(ctlr, Timerint0, 0);
    csr16w(ctlr, Coal, 0);
}

fn rtl8125init(edev: *Ether) Error!void {
    const ctlr = ctlrof(edev);

    // DIFF: see the head of the file
    ilock(&ctlr.ilock);
    ilock(&ctlr.lock);
    ctlr.running = false;
    rtl8125halt(ctlr);
    iunlock(&ctlr.lock);
    iunlock(&ctlr.ilock);

    ctlr.nreset +%= 1;

    @memset(@as([*]u8, @ptrCast(@volatileCast(ctlr.td)))[0 .. @sizeOf(Td) * ctlr.ntd], 0);
    ctlr.tdh = 0;
    ctlr.tdt = 0;
    ctlr.ntq = 0;
    ctlr.td[ctlr.ntd - 1].control = Eor;
    for (0..ctlr.ntd) |i| {
        if (ctlr.tb[i]) |bp| {
            ctlr.tb[i] = null;
            freeb(bp);
        }
    }

    @memset(@as([*]u8, @ptrCast(@volatileCast(ctlr.rd)))[0 .. @sizeOf(Rd) * ctlr.nrd], 0);
    ctlr.rdh = 0;
    ctlr.rdt = 0;
    ctlr.nrq = 0;
    ctlr.rd[ctlr.nrd - 1].control = Eor;
    for (0..ctlr.nrd) |i| {
        if (ctlr.rb[i]) |bp| {
            ctlr.rb[i] = null;
            freeb(bp);
        }
    }
    if (ctlr.pool.size == 0) {
        ctlr.pool.size = Mps;
        ab.growbp(&ctlr.pool, ctlr.nrd * 4);
    }
    rtl8125replenish(ctlr);
    coherence();

    ctlr.imr = Serr | Fovw | Punlc | Rdu | Ter | Tok | Rer | Rok | Tdu;
    ilock(&ctlr.lock);
    ctlr.rcr |= RxcfgConfig8125b | Ab | Am | Apm;
    iunlock(&ctlr.lock);

    qlock(&ctlr.olock);
    rtl8125start(ctlr, &edev.ea) catch |e| {
        qunlock(&ctlr.olock);
        return e;
    };
    qunlock(&ctlr.olock);

    ilock(&ctlr.ilock);
    ilock(&ctlr.lock);
    rtl8125enable(ctlr);
    ctlr.needreset = false;
    ctlr.running = true;
    iunlock(&ctlr.lock);
    iunlock(&ctlr.ilock);

    // what happened while the chip could not say
    ilock(&ctlr.ilock);
    ctlr.lastphy = 0xFFFFFFFF;
    rtl8125link(edev);
    iunlock(&ctlr.ilock);
    rtl8125transmit(edev);
}

fn needreset(arg: ?*anyopaque) bool {
    const ctlr: *Ctlr = @ptrCast(@alignCast(arg.?));
    return ctlr.needreset;
}

fn rtl8125reseter(arg: ?*anyopaque) void {
    const edev: *Ether = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(edev);

    // DIFF: while(waserror()) ; in the C
    while (true) {
        proc.sleep(&ctlr.reset, needreset, ctlr) catch continue;
        // DIFF: the C's rtl8169init raises its errors into the
        // waserror above and so tries again at the next wakeup; here
        // a chip that cannot be restarted is said to be dead.
        rtl8125init(edev) catch |e| {
            ctlr.needreset = false;
            print("#l%d: rtl8125: restart: %s; the interface is dead\n", .{ edev.ctlrno, proc.errtext(e) });
        };
        // DIFF: not faster than once a second, whatever the chip says
        tsleep(&ctlr.pause, proc.return0, null, 1000) catch {};
    }
}

fn rtl8125attach(edev: *Ether) Error!void {
    const ctlr = ctlrof(edev);
    qlock(&ctlr.alock);
    defer qunlock(&ctlr.alock);
    if (ctlr.init)
        return;
    rtl8125attach1(edev, ctlr) catch |e| {
        print("#l%d: rtl8125: %s\n", .{ edev.ctlrno, proc.errtext(e) });
        // DIFF: there is no ifstat to read after this
        print("#l%d: rtl8125: cr %#2.2ux mcucmd %#2.2ux tcr %#8.8ux phystatus %#4.4ux isr %#8.8ux ocptimeouts %ud\n", .{
            edev.ctlrno,             csr8r(ctlr, Cr),   csr8r(ctlr, Mcucmd), csr32r(ctlr, Tcr),
            csr16r(ctlr, Phystatus), csr32r(ctlr, Isr), ctlr.nocp,
        });
        return e;
    };

    print("#l%d: rtl8125: RTL8125B macv %#8.8ux pci rev %#2.2ux phy ramcode %#4.4ux%s\n", .{
        edev.ctlrno,                                              ctlr.macv, ctlr.pcidev.rid, ctlr.ramcode,
        if (ctlr.ramcode == Ramcode8125b) "" else " (not rge's)",
    });

    kproc("rtl8125", rtl8125reseter, edev);
    kproc("rtl8125watch", rtl8125watch, edev);
}

/// What rtl8169attach does between its two outer waserrors.
fn rtl8125attach1(edev: *Ether, ctlr: *Ctlr) Error!void {
    ctlr.ntd = Ntd;
    ctlr.nrd = Nrd;

    const tb = alloc.malloc(ctlr.ntd * @sizeOf(?*Block));
    const rb = alloc.malloc(ctlr.nrd * @sizeOf(?*Block));
    const td = alloc.mallocalign(@sizeOf(Td) * ctlr.ntd, 256, 0, 0);
    const rd = alloc.mallocalign(@sizeOf(Rd) * ctlr.nrd, 256, 0, 0);
    const dtcc = alloc.mallocalign(@sizeOf(Dtcc), 64, 0, 0);
    errdefer {
        if (tb) |p| alloc.free(p);
        if (rb) |p| alloc.free(p);
        if (td) |p| alloc.free(p);
        if (rd) |p| alloc.free(p);
        if (dtcc) |p| alloc.free(p);
    }

    if (tb == null or rb == null or td == null or rd == null or dtcc == null)
        return error.Enomem;

    ctlr.tb = @ptrCast(@alignCast(tb.?));
    ctlr.rb = @ptrCast(@alignCast(rb.?));
    ctlr.td = @ptrCast(@alignCast(td.?));
    ctlr.rd = @ptrCast(@alignCast(rd.?));
    ctlr.dtcc = @ptrCast(dtcc.?);
    @memset(ctlr.tb[0..ctlr.ntd], null);
    @memset(ctlr.rb[0..ctlr.nrd], null);

    pci.pcisetbme(ctlr.pcidev);
    arch.intrenable(edev.isa.irq, rtl8125interrupt, edev, edev.tbdf, netif.nifname(&edev.netif));
    errdefer {
        // DIFF: the blocks the rings hold go back before the rings do,
        // and the chip is reset so that it lets go of them.
        rtl8125halt(ctlr);
        _ = rtl8125reset(ctlr);
        pci.pciclrbme(ctlr.pcidev);
        arch.intrdisable(edev.isa.irq, rtl8125interrupt, edev, edev.tbdf, netif.nifname(&edev.netif));
        for (ctlr.tb[0..ctlr.ntd]) |b| freeb(b);
        for (ctlr.rb[0..ctlr.nrd]) |b| freeb(b);
    }

    try rtl8125init(edev);
    ctlr.init = true;
}

/// Called with ilock held, or before there are interrupts.
fn rtl8125link(edev: *Ether) void {
    const ctlr = ctlrof(edev);

    // Maybe the link changed - do we care very much?
    // Could stall transmits if no link, maybe?
    const r = csr16r(ctlr, Phystatus);
    if (r != ctlr.lastphy) {
        if (ctlr.lastphy != 0xFFFFFFFF)
            ctlr.nlink +%= 1;
        ctlr.lastphy = r;
    }
    if (r & Linksts != 0 and r != 0xFFFF) {
        ethersetspeed(edev, linkspeed(r));
        ethersetlink(edev, true);
    } else {
        ethersetlink(edev, false);
    }
}

/// The speed Phystatus reports, in Mbps.
fn linkspeed(r: u16) i32 {
    if (r & Speed10 != 0)
        return 10;
    if (r & Speed100 != 0)
        return 100;
    if (r & Speed1000 != 0)
        return 1000;
    if (r & Speed2500 != 0)
        return 2500;
    return 1000;
}

/// How many bytes of zeros to add to a frame before the chip gets it.
/// Short frames are filled to the minimum, and rge_tx_offload has
/// this:
///   Workaround for a bug in RTL8125/RTL8125B.
///   The chip hangs when a short UDP frame reads port 319 or 320
///   with fewer than 47 bytes of data.
/// (the data it counts starts at the UDP header).  A UDP header that
/// is cut short is filled up too, as there.
fn txpadlen(pkt: []const u8) usize {
    const totlen = pkt.len;
    var padlen: usize = 0;

    udp: {
        if (totlen >= 128 + Minpatch or totlen < 14)
            break :udp;
        var off: usize = 14;
        var etype = @as(u16, pkt[12]) << 8 | pkt[13];
        if (etype == 0x8100 and totlen >= 18) {
            etype = @as(u16, pkt[16]) << 8 | pkt[17];
            off = 18;
        }
        var proto: u8 = 0;
        var iphlen: usize = 0;
        if (etype == 0x0800 and totlen >= off + 20 and pkt[off] >> 4 == 4) {
            proto = pkt[off + 9];
            iphlen = @as(usize, pkt[off] & 0xF) * 4;
        } else if (etype == 0x86DD and totlen >= off + 40) {
            proto = pkt[off + 6];
            iphlen = 40;
        }
        const hdrlen = off + iphlen;
        if (proto != 17 or iphlen < 20 or hdrlen > totlen)
            break :udp;
        const udplen = totlen - hdrlen;
        if (udplen > 3 and udplen < Minpatch) {
            const port = @as(u16, pkt[hdrlen + 2]) << 8 | pkt[hdrlen + 3];
            if (port == 319 or port == 320)
                padlen = Minpatch - udplen;
        }
        if (udplen < 8)
            padlen = @max(padlen, 8 - udplen);
    }

    if (totlen + padlen < Minframe)
        padlen = Minframe - totlen;
    return padlen;
}

/// Add n bytes of zeros to a frame, in place if there is room.
fn txpadblock(bp: *Block, n: usize) ?*Block {
    if (@intFromPtr(bp.lim) - @intFromPtr(bp.wp) >= n) {
        @memset(bp.wp[0..n], 0);
        bp.wp += n;
        return bp;
    }
    const len = BLEN(bp);
    const nbp = ab.iallocb(len + n) orelse {
        freeb(bp);
        return null;
    };
    @memcpy(nbp.wp[0..len], bp.rp[0..len]);
    @memset(nbp.wp[len .. len + n], 0);
    nbp.wp += len + n;
    freeb(bp);
    return nbp;
}

fn rtl8125transmit(edev: *Ether) void {
    const ctlr = ctlrof(edev);

    ilock(&ctlr.lock);
    // DIFF: see the head of the file
    if (!ctlr.running) {
        iunlock(&ctlr.lock);
        return;
    }
    var x = ctlr.tdh;
    while (ctlr.ntq > 0) : (x = NEXT(x, ctlr.ntd)) {
        const d = &ctlr.td[x];
        const control = d.control;
        if (control & Own != 0)
            break;

        // Free it up.
        // Need to clean the descriptor here? Not really.
        // Simple freeb for now (no chain and freeblist).
        // Use ntq count for now.
        freeb(ctlr.tb[x]);
        ctlr.tb[x] = null;
        ctlr.ntq -= 1;
        ctlr.txdone +%= 1;
        if (control & Txer != 0)
            ctlr.txerr +%= 1;
    }
    ctlr.tdh = x;

    x = ctlr.tdt;
    while (ctlr.ntq < (ctlr.ntd - 1)) {
        var bp = qio.qget(edev.oq.?) orelse
            break;

        // DIFF: not in the C; see txpadlen
        const pad = txpadlen(bp.rp[0..BLEN(bp)]);
        if (pad != 0) {
            bp = txpadblock(bp, pad) orelse {
                ctlr.txdrop +%= 1;
                continue;
            };
            ctlr.txpad +%= 1;
        }

        const pa = pciwaddr(@intFromPtr(bp.rp));
        const d = &ctlr.td[x];
        d.addrlo = @truncate(pa);
        d.addrhi = @truncate(pa >> 32);
        d.vlan = 0;
        coherence();
        d.control = tdcontrol(d.control, BLEN(bp));

        ctlr.tb[x] = bp;
        ctlr.ntq += 1;
        ctlr.txpkt +%= 1;

        x = NEXT(x, ctlr.ntd);
    }
    if (x != ctlr.tdt)
        ctlr.tdt = x
    else if (ctlr.ntq >= (ctlr.ntd - 1))
        ctlr.txdu +%= 1;

    if (ctlr.ntq > 0) {
        coherence();
        csr16w(ctlr, Tppoll, Npq);
    }
    iunlock(&ctlr.lock);
}

/// Called with ilock held.
fn rtl8125receive(edev: *Ether) void {
    const ctlr = ctlrof(edev);
    if (ctlr.nrq < ctlr.nrd / 2)
        rtl8125replenish(ctlr);

    var x = ctlr.rdh;
    while (x != ctlr.rdt) {
        const d = &ctlr.rd[x];
        const control = d.control;
        if (control & Own != 0)
            break;

        const bp = ctlr.rb[x].?;
        ctlr.rb[x] = null;
        ctlr.nrq -= 1;

        x = NEXT(x, ctlr.nrd);
        ctlr.rdh = x;

        if (ctlr.nrq < ctlr.nrd / 2)
            rtl8125replenish(ctlr);

        if ((control & (Rfs | Rls | Res)) == (Rfs | Rls)) {
            // DIFF: the C believes the length
            const len: usize = control & RxflMASK;
            if (len < 4 or len > @intFromPtr(bp.lim) - @intFromPtr(bp.rp)) {
                ctlr.badlen +%= 1;
                freeb(bp);
                continue;
            }
            bp.wp = bp.rp + len - 4;
            ctlr.rxpkt +%= 1;
            // DIFF: no checksum flags: Rxchksum is off
            devether.etheriq(edev, bp);
        } else {
            if (control & Res == 0)
                ctlr.frag +%= 1
            else
                ctlr.res +%= 1;
            freeb(bp);
        }
    }
}

/// Called with ilock held.
fn rtl8125restart(ctlr: *Ctlr) void {
    rtl8125halt(ctlr);
    ctlr.needreset = true;
    _ = wakeup(&ctlr.reset);
}

/// The body of rtl8169interrupt, with the masking of rge_intr around
/// it; see the head of the file.
fn rtl8125service(edev: *Ether) void {
    const ctlr = ctlrof(edev);

    ilock(&ctlr.ilock);
    if (!ctlr.running or ctlr.needreset) {
        iunlock(&ctlr.ilock);
        return;
    }

    // Disable interrupts.
    csr32w(ctlr, Imr, 0);

    var n: usize = 0;
    while (true) : (n += 1) {
        const isr = csr32r(ctlr, Isr);
        if (isr == 0 or isr == 0xFFFFFFFF)
            break;
        if (n == Nservice) {
            ctlr.nspin +%= 1;
            break;
        }
        csr32w(ctlr, Isr, isr);
        if ((isr & ctlr.imr) == 0)
            break;

        if (isr & Serr != 0)
            ctlr.serr +%= 1;
        if (isr & Fovw != 0)
            ctlr.fovw +%= 1;
        if (isr & Rer != 0)
            ctlr.rer +%= 1;
        if (isr & Rdu != 0)
            ctlr.rdu +%= 1;
        if (isr & Punlc != 0)
            ctlr.punlc +%= 1;
        if (isr & Rok != 0)
            ctlr.rok +%= 1;
        if (isr & Tok != 0)
            ctlr.tok +%= 1;
        if (isr & Ter != 0)
            ctlr.ter +%= 1;
        if (isr & Tdu != 0)
            ctlr.tdu +%= 1;

        if (isr & Serr != 0) {
            rtl8125restart(ctlr);
            iunlock(&ctlr.ilock);
            return;
        }

        if (isr & (Fovw | Punlc | Rdu | Rer | Rok) != 0)
            rtl8125receive(edev);

        if (isr & (Tdu | Ter | Tok) != 0)
            rtl8125transmit(edev);

        if (isr & Punlc != 0)
            rtl8125link(edev);
    }

    csr32w(ctlr, Imr, ctlr.imr);
    iunlock(&ctlr.ilock);
}

fn rtl8125interrupt(_: *arch.Ureg, arg: ?*anyopaque) void {
    const edev: *Ether = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(edev);

    ctlr.nintr +%= 1;
    rtl8125service(edev);
}

/// Is the chip showing an event that it should have interrupted for?
fn pending(ctlr: *Ctlr) bool {
    const isr = csr32r(ctlr, Isr);
    return isr != 0xFFFFFFFF and (isr & ctlr.imr) != 0;
}

/// DIFF: not in the C; see the head of the file.
fn rtl8125watch(arg: ?*anyopaque) void {
    const edev: *Ether = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(edev);
    var ms: u32 = 0;
    var said: i32 = 0; // the link state last printed

    while (true) {
        const period: u32 = if (ctlr.polling) Pollms else 1000;
        tsleep(&ctlr.watch, proc.return0, null, period) catch {};
        ms += period;
        if (!ctlr.running)
            continue;

        if (ctlr.polling) {
            ctlr.npoll +%= 1;
            rtl8125service(edev);
        } else if (ctlr.nintr == ctlr.lastnintr and pending(ctlr)) {
            // An interrupt may be on its way; one that has not come
            // after this long is not coming.
            tsleep(&ctlr.watch, proc.return0, null, 20) catch {};
            if (ctlr.running and ctlr.nintr == ctlr.lastnintr and pending(ctlr)) {
                ctlr.nlost +%= 1;
                rtl8125service(edev);
                if (ctlr.nintr == 0) {
                    ctlr.polling = true;
                    print("#l%d: rtl8125: no interrupts; polling\n", .{edev.ctlrno});
                }
            }
        }
        ctlr.lastnintr = ctlr.nintr;

        // rge_tick
        if (ms >= 1000) {
            ms = 0;
            ilock(&ctlr.ilock);
            if (ctlr.running)
                rtl8125link(edev);
            const link = edev.netif.link;
            const mbps = edev.netif.mbps;
            const r = ctlr.lastphy;
            iunlock(&ctlr.ilock);
            // ethersetlink does not print under a lock
            if (link != said) {
                said = link;
                if (link != 0)
                    print("#l%d: rtl8125: link up: %dMbps, phystatus %#4.4ux\n", .{ edev.ctlrno, mbps, r })
                else
                    print("#l%d: rtl8125: link down\n", .{edev.ctlrno});
            }
        }
    }
}

fn rtl8125shutdown(edev: *Ether) void {
    const ctlr = ctlrof(edev);

    rtl8125halt(ctlr);
    // DIFF: see the head of the file
    _ = rtl8125reset(ctlr);
    pci.pciclrbme(ctlr.pcidev);
}

fn vetmacv(ctlr: *Ctlr, macv: *u32) i32 {
    macv.* = csr32r(ctlr, Tcr) & HwveridMASK;
    return vetmacvalue(macv.*);
}

fn vetmacvalue(macv: u32) i32 {
    switch (macv) {
        Macv8125b => return 0,
        else => return -1,
    }
}

fn rtl8125pci() void {
    const Pcielcsr = 0x10; // link control and status
    const Aspm = 0x0003; // L0s and L1
    const Ecpm = 0x0100; // clock power management

    var prev: ?*Pcidev = null;
    while (pci.pcimatch(prev, pci.Vrealtek, 0x8125)) |p| {
        prev = p;
        if (p.ccrb != 0x02 or p.ccru != 0)
            continue;

        // DIFF: the registers in memory, BAR 2
        if (p.mem[2].size < Regsize or (p.mem[2].bar & 1) != 0) {
            print("rtl8125: %T: no memory registers\n", .{pci.tbdf(p.tbdf)});
            continue;
        }
        const port = p.mem[2].bar & ~@as(u64, 0xF);

        const ctlr = alloc.new(Ctlr) orelse {
            print("rtl8125: can't allocate memory\n", .{});
            continue;
        };
        ctlr.* = .{};
        ctlr.port = port;
        ctlr.pcidev = p;

        pci.pcienable(p);
        ctlr.reg = arch.vmap(port, Regsize) orelse {
            print("rtl8125: %T: can't map registers\n", .{pci.tbdf(p.tbdf)});
            pci.pcidisable(p);
            alloc.free(ctlr);
            continue;
        };
        var macv: u32 = 0;
        if (vetmacv(ctlr, &macv) == -1) {
            print("rtl8125: %T: unknown mac %.4ux %.8ux\n", .{ pci.tbdf(p.tbdf), p.did, macv });
            pci.pcidisable(p);
            arch.vunmap(ctlr.reg, Regsize);
            alloc.free(ctlr);
            continue;
        }
        rtl8125halt(ctlr);

        // Disable PCIe ASPM and ECPM.  (rge_attach)
        const off = pci.pcicap(p, pci.PciCapPCIe);
        if (off > 0) {
            const lcsr = pci.pcicfgr16(p, off + Pcielcsr);
            pci.pcicfgw16(p, off + Pcielcsr, lcsr & ~@as(i32, Aspm | Ecpm));
        }

        // Extract the chip hardware version,
        // needed to configure each properly.
        ctlr.macv = macv;
        ctlr.nophy = arch.getconf("*rtl8125nophy") != null;
        if (rtl8125ctlrhead != null)
            rtl8125ctlrtail.?.next = ctlr
        else
            rtl8125ctlrhead = ctlr;
        rtl8125ctlrtail = ctlr;
    }
}

/// Is this an address a card can have?
fn validea(ea: *const [Eaddrlen]u8) bool {
    const zeros: [Eaddrlen]u8 = @splat(0);
    const ones: [Eaddrlen]u8 = @splat(0xFF);
    return !std.mem.eql(u8, ea, &zeros) and !std.mem.eql(u8, ea, &ones) and ea[0] & 1 == 0;
}

var once: bool = false;

fn rtl8125pnp(edev: *Ether) i32 {
    if (!once) {
        once = true;
        rtl8125pci();
    }

    // Any adapter matches if no edev->port is supplied,
    // otherwise the ports must match.
    var cp = rtl8125ctlrhead;
    while (cp) |c| : (cp = c.next) {
        if (c.active)
            continue;
        if (edev.isa.port == 0 or edev.isa.port == c.port) {
            c.active = true;
            break;
        }
    }
    const ctlr = cp orelse
        return -1;

    edev.ctlr = ctlr;
    edev.isa.port = ctlr.port;
    edev.isa.irq = ctlr.pcidev.intl;
    edev.tbdf = ctlr.pcidev.tbdf;
    edev.netif.mbps = 100;
    edev.maxmtu = Mtu;

    // Check if the adapter's station address is to be overridden.
    // If not, read it from the device and set in edev->ea.
    const zeros: [Eaddrlen]u8 = @splat(0);
    if (std.mem.eql(u8, &edev.ea, &zeros)) {
        var r = csr32r(ctlr, Idr0);
        edev.ea[0] = @truncate(r);
        edev.ea[1] = @truncate(r >> 8);
        edev.ea[2] = @truncate(r >> 16);
        edev.ea[3] = @truncate(r >> 24);
        r = csr32r(ctlr, Idr0 + 4);
        edev.ea[4] = @truncate(r);
        edev.ea[5] = @truncate(r >> 8);
        // DIFF: if nothing has set Idr yet, the address the chip was
        // made with, which is where rge_get_macaddr always looks.
        if (!validea(&edev.ea)) {
            r = csr32r(ctlr, Addr0);
            edev.ea[0] = @truncate(r);
            edev.ea[1] = @truncate(r >> 8);
            edev.ea[2] = @truncate(r >> 16);
            edev.ea[3] = @truncate(r >> 24);
            r = csr16r(ctlr, Addr1);
            edev.ea[4] = @truncate(r);
            edev.ea[5] = @truncate(r >> 8);
        }
    }

    // DIFF: the C's halt, which clears Cr, stops a chip that the
    // firmware left receiving; this one needs the reset for that.  It
    // is not to write to memory again before rtl8125attach.
    if (rtl8125reset(ctlr) < 0)
        print("#l%d: rtl8125: %T: reset failed: cr %#2.2ux mcucmd %#2.2ux\n", .{
            edev.ctlrno, pci.tbdf(ctlr.pcidev.tbdf), csr8r(ctlr, Cr), csr8r(ctlr, Mcucmd),
        });
    pci.pciclrbme(ctlr.pcidev);

    edev.attach = rtl8125attach;
    edev.transmit = rtl8125transmit;
    edev.netif.ifstat = rtl8125ifstat;
    edev.shutdown = rtl8125shutdown;

    edev.netif.arg = edev;
    edev.netif.promiscuous = rtl8125promiscuous;
    edev.netif.multicast = rtl8125multicast;

    rtl8125link(edev);

    return 0;
}

pub fn ether8125link() void {
    devether.addethercard("rtl8125", rtl8125pnp);
}

/// For the tests: the registers of an RTL8125B as far as the bring-up
/// sequence can tell, and a record of what was done to them.
const Sim = struct {
    const Op = struct { write: bool, width: u8, off: u16, val: u32 };

    var mem: [Regsize]u8 = @splat(0);
    var macocp: [0x8000]u16 = @splat(0);
    var phyocp: [0x8000]u16 = @splat(0);
    var ephy: [128]u16 = @splat(0);
    var csi: [0x400]u32 = @splat(0);
    var ops: [16384]Op = undefined;
    var nops: usize = 0;

    fn reset() void {
        @memset(&mem, 0);
        @memset(&macocp, 0);
        @memset(&phyocp, 0);
        @memset(&ephy, 0);
        @memset(&csi, 0);
        nops = 0;
        put(Tcr, 4, Macv8125b);
        phyocp[0xA420 >> 1] = 3; // the PHY is up
        phyocp[0xA438 >> 1] = Ramcode8125b; // and has rge's code
    }

    fn get(off: usize, width: usize) u32 {
        var v: u32 = 0;
        for (0..width) |i|
            v |= @as(u32, mem[off + i]) << @intCast(8 * i);
        return v;
    }

    fn put(off: usize, width: usize, val: u32) void {
        for (0..width) |i|
            mem[off + i] = @truncate(val >> @intCast(8 * i));
    }

    fn rd(off: usize, width: u8) u32 {
        var v = get(off, width);
        switch (off) {
            Mcucmd => v |= Rxfifoempty | Txfifoempty,
            Coal => v |= 0x0103,
            Twicmd => v |= 0x0200,
            else => {},
        }
        if (nops < ops.len)
            ops[nops] = .{ .write = false, .width = width, .off = @intCast(off), .val = v };
        nops += 1;
        return v;
    }

    fn wr(off: usize, width: u8, val_: u32) void {
        var val = val_;
        if (nops < ops.len)
            ops[nops] = .{ .write = true, .width = width, .off = @intCast(off), .val = val };
        nops += 1;
        const a = (val >> 16) & 0x7FFF;
        switch (off) {
            Cr => val &= ~@as(u32, Rst), // a reset is over at once
            Isr => val = get(Isr, 4) & ~val,
            Tcr => val = (val & ~@as(u32, HwveridMASK)) | Macv8125b,
            Macocp => {
                if (val & Flag != 0)
                    macocp[a] = @truncate(val)
                else
                    val = macocp[a];
            },
            Phyocp => {
                if (val & Flag != 0) {
                    phyocp[a] = @truncate(val);
                    if (a == 0xA400 >> 1)
                        phyocp[a] &= ~@as(u16, BmcrR); // as is a PHY's
                    val &= ~@as(u32, Flag);
                } else {
                    val = Flag | @as(u32, phyocp[a]);
                }
            },
            Ephyar => {
                if (val & Flag != 0) {
                    ephy[a & EphyaddrMASK] = @truncate(val);
                    val &= ~@as(u32, Flag);
                } else {
                    val = Flag | @as(u32, ephy[a & EphyaddrMASK]);
                }
            },
            Csiar => {
                const r = (val & CsiaddrMASK) >> 2;
                if (val & Flag != 0) {
                    csi[r] = get(Csidr, 4);
                    val &= ~@as(u32, Flag);
                } else {
                    put(Csidr, 4, csi[r]);
                    val |= Flag;
                }
            },
            else => {},
        }
        put(off, width, val);
    }

    /// FNV-1a of the record, one "W4 0037 00000010" line an access.
    fn hash(print_: bool) u64 {
        var h: u64 = 0xcbf29ce484222325;
        var line: [32]u8 = undefined;
        for (ops[0..@min(nops, ops.len)]) |op| {
            const s = std.fmt.bufPrint(&line, "{c}{d} {x:0>4} {x:0>8}\n", .{
                @as(u8, if (op.write) 'W' else 'R'), op.width, op.off, op.val,
            }) catch unreachable;
            if (print_)
                std.debug.print("{s}", .{s});
            for (s) |c| {
                h ^= c;
                h *%= 0x100000001b3;
            }
        }
        return h;
    }
};

test "descriptors" {
    const expect = std.testing.expect;

    // a frame of 60 bytes, in the middle and at the end of the ring
    try expect(tdcontrol(0, 60) == 0xB000003C);
    try expect(tdcontrol(Eor, 1514) == 0xF00005EA);
    // whatever the chip left in the word goes, except Eor
    try expect(tdcontrol(0x3FFFFFFF, 60) == 0xB000003C);
    try expect(tdcontrol(0x7FFFFFFF, 60) == 0xF000003C);

    try expect(rdcontrol(0, 1552) == 0x80000610);
    try expect(rdcontrol(Eor | Rfs | Rls | 64, 1552) == 0xC0000610);
    // the size has 14 bits
    try expect(rdcontrol(0, 0x10000) == 0x80003FFF);

    // a received frame
    const control: u32 = Rfs | Rls | 64;
    try expect(control & Own == 0);
    try expect((control & (Rfs | Rls | Res)) == (Rfs | Rls));
    try expect(control & RxflMASK == 64);
    try expect(Mps == 1536);
}

test "OCP and MII addresses" {
    const expect = std.testing.expect;

    // rge_write_mac_ocp(sc, 0xeb58, 1): ((0xeb58>>1)<<16) + 1, BUSY
    try expect(macocpcmd(0xEB58, 0x0001, false) == 0xF5AC0001);
    try expect(macocpcmd(0xEB58, 0, true) == 0x75AC0000);
    try expect(macocpcmd(0xFC26, 0x8000, false) == 0xFE138000);
    try expect(phyocpcmd(0xA436, 0x801E, false) == 0xD21B801E);
    try expect(phyocpcmd(0xA438, 0, true) == 0x521C0000);

    // rge_write_phy(sc, 0, reg, val): (0xa40 + reg/8)<<4, + (reg%8)<<1
    try expect(miiocp(Bmcr) == 0xA400);
    try expect(miiocp(Bmsr) == 0xA402);
    try expect(miiocp(Anar) == 0xA408);
    try expect(miiocp(Anlpar) == 0xA40A);
    try expect(miiocp(Mscr) == 0xA412);
    try expect(miiocp(Mssr) == 0xA414);
    for (0..32) |reg| {
        const want = ((0xA40 + reg / 8) << 4) + (((0x10 + reg % 8) - 16) << 1);
        try expect(miiocp(@intCast(reg)) == want);
    }
}

test "hardware revision and link speed" {
    const expect = std.testing.expect;

    // the test machine's chip: "RTL8125B, XID 641"
    try expect(vetmacvalue(0x64100F00 & HwveridMASK) == 0);
    try expect(vetmacvalue(0x64100000) == 0);
    try expect(vetmacvalue(Macv8125a) == -1);
    try expect(vetmacvalue(0x68800000) == -1); // RTL8125D
    try expect(vetmacvalue(0x64900000) == -1); // RTL8126
    try expect(vetmacvalue(0x7CF00000) == -1); // nothing there

    try expect(linkspeed(Linksts | Fd | Speed2500) == 2500);
    try expect(linkspeed(Linksts | Fd | Speed1000 | Rxflow | Txflow) == 1000);
    try expect(linkspeed(Linksts | Fd | Speed100) == 100);
    try expect(linkspeed(Linksts | Speed10) == 10);
}

test "multicast hash" {
    const expect = std.testing.expect;

    // the bit OpenBSD's ether_crc32_be(addr, 6) >> 26 chooses
    try expect(ethercrcbe(&.{ 0x01, 0x00, 0x5E, 0x00, 0x00, 0x01 }) >> 26 == 0x1F);
    try expect(ethercrcbe(&.{ 0x33, 0x33, 0x00, 0x00, 0x00, 0x01 }) >> 26 == 0x3E);
    try expect(ethercrcbe(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }) >> 26 == 0x3F);
    try expect(swabl(0x01020304) == 0x04030201);
}

test "txpadlen" {
    const expect = std.testing.expect;

    var pkt: [200]u8 = @splat(0);
    // nothing to parse: only the minimum
    try expect(txpadlen(pkt[0..14]) == 46);
    try expect(txpadlen(pkt[0..59]) == 1);
    try expect(txpadlen(pkt[0..60]) == 0);
    try expect(txpadlen(pkt[0..174]) == 0);

    // IPv4 UDP to port 319: Ethernet 14, IP 20, UDP header and data
    pkt[12] = 0x08;
    pkt[13] = 0x00;
    pkt[14] = 0x45;
    pkt[14 + 9] = 17;
    pkt[34 + 2] = 319 >> 8;
    pkt[34 + 3] = 319 & 0xFF;
    try expect(txpadlen(pkt[0 .. 34 + 46]) == 1);
    try expect(txpadlen(pkt[0 .. 34 + 47]) == 0);
    try expect(txpadlen(pkt[0 .. 34 + 8]) == 39);
    try expect(txpadlen(pkt[0 .. 34 + 30]) == 17);
    // port 320 too, and no other
    pkt[34 + 3] = 320 & 0xFF;
    try expect(txpadlen(pkt[0 .. 34 + 46]) == 1);
    pkt[34 + 3] = 321 & 0xFF;
    try expect(txpadlen(pkt[0 .. 34 + 46]) == 0);
    try expect(txpadlen(pkt[0 .. 34 + 8]) == 18); // to 60
    // a UDP header cut short is completed, and then the frame is
    try expect(txpadlen(pkt[0 .. 34 + 2]) == 24);
    // TCP is left alone
    pkt[34 + 3] = 319 & 0xFF;
    pkt[14 + 9] = 6;
    try expect(txpadlen(pkt[0 .. 34 + 46]) == 0);
    // IP options move the UDP header
    pkt[14 + 9] = 17;
    pkt[14] = 0x46;
    pkt[38 + 2] = 319 >> 8;
    pkt[38 + 3] = 319 & 0xFF;
    try expect(txpadlen(pkt[0 .. 38 + 46]) == 1);

    // IPv6 UDP to port 320
    @memset(&pkt, 0);
    pkt[12] = 0x86;
    pkt[13] = 0xDD;
    pkt[14] = 0x60;
    pkt[14 + 6] = 17;
    pkt[54 + 2] = 320 >> 8;
    pkt[54 + 3] = 320 & 0xFF;
    try expect(txpadlen(pkt[0 .. 54 + 40]) == 7);
    try expect(txpadlen(pkt[0 .. 54 + 47]) == 0);
    // long frames are not looked at
    try expect(txpadlen(pkt[0..175]) == 0);
}

test "bring-up sequence" {
    const expect = std.testing.expect;

    // The accesses rtl8125start and rtl8125enable make to an RTL8125B,
    // as compared, one by one, with those of rge_init for MAC_R25B.
    // If the sequence is changed on purpose, set dump, run the test,
    // compare the list it prints with rge again, and put the new
    // number here.
    const dump = false;
    const want: u64 = 0x5610feae58ec5b04;

    Sim.reset();
    var ctlr: Ctlr = .{};
    ctlr.macv = Macv8125b;
    ctlr.td = @ptrFromInt(0x1_2345_6000);
    ctlr.rd = @ptrFromInt(0x1_2345_7000);
    ctlr.imr = Serr | Fovw | Punlc | Rdu | Ter | Tok | Rer | Rok | Tdu;
    ctlr.rcr = RxcfgConfig8125b | Ab | Am | Apm;
    ctlr.mchash = 0x8000000000000001;
    const ea = [Eaddrlen]u8{ 0x00, 0xE0, 0x22, 0x11, 0x22, 0x33 };
    try rtl8125start(&ctlr, &ea);
    rtl8125enable(&ctlr);

    try expect(Sim.nops < Sim.ops.len);
    try expect(ctlr.nocp == 0);
    const h = Sim.hash(dump);
    if (h != want)
        std.debug.print("bring-up sequence: hash {x}, {d} accesses\n", .{ h, Sim.nops });
    try expect(h == want);

    // where it leaves the chip
    try expect(Sim.get(Cr, 1) == Te | Re);
    try expect(Sim.get(Imr, 4) == 0x80FF);
    try expect(Sim.get(Rcr, 4) == 0x41000C0E);
    try expect(Sim.get(Tcr, 4) == Macv8125b | TxcfgConfig);
    try expect(ctlr.tcr == Macv8125b | TxcfgConfig);
    try expect(Sim.get(Idr0, 4) == 0x1122E000);
    try expect(Sim.get(Idr0 + 4, 4) == 0x3322);
    try expect(Sim.get(Rdsar, 4) == 0x23457000 and Sim.get(Rdsar + 4, 4) == 1);
    try expect(Sim.get(Tnpds, 4) == 0x23456000 and Sim.get(Tnpds + 4, 4) == 1);
    try expect(Sim.get(Mar0, 4) == 0x00000080 and Sim.get(Mar0 + 4, 4) == 0x01000000);
    try expect(Sim.get(Rms, 2) == 1536);
    try expect(Sim.get(Cr9346, 1) == 0); // configuration locked again
    try expect(Sim.get(Ppsw, 1) & 0x08 == 0); // RXDV gate open
    try expect(Sim.get(Intcfg0, 1) & Intcfgen == 0);
    try expect(Sim.macocp[0xEB58 >> 1] & 1 == 1); // 32 byte Td
    try expect(Sim.macocp[0xFC26 >> 1] == 0 and Sim.macocp[0xFC48 >> 1] == 0); // no MCU patch
    try expect(Sim.phyocp[0xA5D4 >> 1] & Adv2500TFD != 0);
    try expect(Sim.phyocp[miiocp(Anar) >> 1] == 0x0DE1);
    try expect(Sim.phyocp[miiocp(Mscr) >> 1] == 0x0300);
    try expect(Sim.csi[0x70C >> 2] == 0x27000000);
    try expect(Sim.ephy[0x5E] == 0x28EB);
}
