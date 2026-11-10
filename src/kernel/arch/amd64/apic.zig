//! Local and I/O APICs: interrupt delivery and the clock interrupt.
//! from 9/pc/apic.c (local APIC) and the routing in 9/pc/mp.c
//!
//! DIFF: processors and I/O APICs come from the ACPI MADT only (no MP
//! tables), the 8259 PICs are masked and never used, and routing is
//! reduced to what a 2011-or-later machine needs: ISA interrupts go
//! through the I/O APIC as the MADT overrides say, and PCI devices will
//! use MSI (added with the PCI code).  There is no ACPI _PRT lookup.

const std = @import("std");
const acpi = @import("../../plat/acpi.zig");
const mem = @import("mem.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const mmu = @import("mmu.zig");
const irq = @import("irq.zig");
const clock = @import("clock.zig");
const taslock = @import("../../port/taslock.zig");
const portclock = @import("../../port/portclock.zig");
const p9 = @import("../../port/print.zig");
const print = p9.print;
const panic = p9.panic;

const Ureg = dat.Ureg;
const Vctl = dat.Vctl;
const m = dat.m;

// Local APIC registers
const LapicID = 0x0020; // ID
const LapicVER = 0x0030; // Version
const LapicTPR = 0x0080; // Task Priority
const LapicEOI = 0x00B0; // EOI
const LapicLDR = 0x00D0; // Logical Destination
const LapicDFR = 0x00E0; // Destination Format
const LapicSVR = 0x00F0; // Spurious Interrupt Vector
const LapicISR = 0x0100; // Interrupt Status (8 registers)
const LapicESR = 0x0280; // Error Status
const LapicICRLO = 0x0300; // Interrupt Command
const LapicICRHI = 0x0310; // Interrupt Command [63:32]
const LapicTIMER = 0x0320; // Local Vector Table 0 (TIMER)
const LapicPCINT = 0x0340; // Performance Counter LVT
const LapicLINT0 = 0x0350; // Local Vector Table 1 (LINT0)
const LapicLINT1 = 0x0360; // Local Vector Table 2 (LINT1)
const LapicERROR = 0x0370; // Local Vector Table 3 (ERROR)
const LapicTICR = 0x0380; // Timer Initial Count
const LapicTCCR = 0x0390; // Timer Current Count
const LapicTDCR = 0x03E0; // Timer Divide Configuration

const LapicENABLE = 0x00000100; // SVR: Unit Enable

const LapicONESHOT = 0x00000000; // TIMER: One-shot
const LapicPERIODIC = 0x00020000; // TIMER: Periodic
const LapicCLKIN = 0x00000000; // TIMER: use CLKIN as input

// Bits shared by the local vector table and I/O APIC redirection entries.
const ApicFIXED = 0x00000000; // [10:8] Delivery Mode: Fixed
const ApicNMI = 0x00000400; // Non-maskable Interrupt
const ApicINIT = 0x00000500; // INIT/RESET
const ApicExtINT = 0x00000700; // External Interrupt
const ApicDELIVS = 0x00001000; // [12] Delivery Status (RO)
const ApicLOW = 0x00002000; // [13] Interrupt Input Pin Polarity: active low
const ApicLEVEL = 0x00008000; // [15] Trigger Mode: level
const ApicIMASK = 0x00010000; // [16] Interrupt Mask

const LapicALLINC = 0x00080000; // ICR: All including self

const lapictdxtab = [_]u8{ // LapicTDCR
    0x0B, // divide by 1
    0x00, // divide by 2
    0x01, // divide by 4
    0x02, // divide by 8
    0x03, // divide by 16
    0x08, // divide by 32
    0x09, // divide by 64
    0x0A, // divide by 128
};

/// Null when in x2APIC mode, where the registers are MSRs.
var lapicbase: ?[*]volatile u32 = null;

const Apictimer = struct {
    hz: u64 = 0,
    max: u32 = 0,
    min: u32 = 0,
    div: u32 = 0,
    tdx: usize = 0,
};

var lapictimer: [mem.MAXMACH]Apictimer = @splat(.{});

var madt: acpi.Madt = .{};

fn lapicr(r: u32) u32 {
    if (lapicbase) |b| return b[r / 4];
    return @truncate(l.rdmsr(0x800 + (r >> 4)));
}

fn lapicw(r: u32, v: u32) void {
    if (lapicbase) |b| b[r / 4] = v else l.wrmsr(0x800 + (r >> 4), v);
}

fn lapicid() u32 {
    const id = lapicr(LapicID);
    return if (lapicbase != null) id >> 24 else id;
}

/// Measure the local APIC timer against the cycle counter.
fn lapictimerinit() void {
    const mach = m();
    const machno: usize = @intCast(mach.machno);
    if (machno != 0) {
        lapictimer[machno] = lapictimer[0];
        return;
    }

    const s = l.splhi();
    const a = &lapictimer[machno];
    a.tdx = 0;
    var hz: u64 = undefined;
    var v: u64 = undefined;
    while (true) {
        lapicw(LapicTIMER, ApicIMASK | LapicCLKIN | LapicONESHOT | (dat.VectorPIC + dat.IrqTIMER));
        lapicw(LapicTDCR, lapictdxtab[a.tdx]);

        const x = clock.fastticks(&hz) + hz / 10;
        lapicw(LapicTICR, 0xffffffff);
        while (clock.fastticks(null) < x) {}

        v = @as(u64, 0xffffffff - lapicr(LapicTCCR)) * 10;
        if (v > hz - (hz / 10)) {
            if (v > hz + (hz / 10) and a.tdx < lapictdxtab.len - 1) {
                a.tdx += 1;
                continue;
            }
            v = hz;
        }
        break;
    }
    if (v < 100 * mem.HZ) panic("lapictimerinit: timer too slow: %lludHz", .{v});
    a.hz = v;
    a.div = @intCast(hz / a.hz);
    a.max = @intCast(a.hz / mem.HZ);
    a.min = @intCast(a.hz / (100 * mem.HZ));
    l.splx(s);

    print("cpu%d: lapic clock at %lludMHz\n", .{ mach.machno, (v + 500000) / 1000000 });
}

/// Set up this processor's local APIC.
pub fn lapicinit() void {
    const mach = m();

    if (lapicbase == null) {
        // use x2APIC when supported (cpuid cx bit 21) and
        //   cpu0 already uses it (lapicbase == nil && machno != 0),
        //   or already enabled (on cpu0)
        const base = l.rdmsr(0x1B);
        if (mach.cpuidcx & dat.X2apic != 0 and (mach.machno != 0 or base & (3 << 10) == (3 << 10))) {
            // enable x2APIC mode
            if (base & (3 << 10) != (3 << 10))
                l.wrmsr(0x1B, base | (3 << 10));
        } else {
            const va = mmu.vmap(madt.lapic_pa, 1024) orelse
                panic("lapicinit: vmap %llux", .{madt.lapic_pa});
            lapicbase = @ptrFromInt(va);
            print("LAPIC: %llux %#p\n", .{ madt.lapic_pa, va });
        }
    }

    lapicintroff();

    // DFR and LDR are read-only in x2APIC mode
    if (lapicbase != null) {
        // These don't really matter in Physical mode;
        // set the defaults anyway.
        const amd = std.mem.eql(u8, mach.cpuidid[0..12], "AuthenticAMD");
        lapicw(LapicDFR, if (amd) 0xf0000000 else 0xffffffff);
        lapicw(LapicLDR, 0x00000000);
    }

    lapicw(LapicSVR, LapicENABLE | (dat.VectorPIC + dat.IrqSPURIOUS));

    // Set the local interrupts.  LINT0 would carry the 8259's
    // interrupts, which are not used; LINT1 is the NMI.
    lapicw(LapicLINT0, ApicIMASK);
    lapicw(LapicLINT1, if (mach.machno == 0) ApicNMI else ApicIMASK);
    if (((lapicr(LapicVER) >> 16) & 0xFF) >= 4)
        lapicw(LapicPCINT, ApicIMASK);

    lapicw(LapicERROR, dat.VectorPIC + dat.IrqERROR);

    lapictimerinit();

    // Acknowledge any outstanding interrupts.
    _ = lapiceoi(0);

    // Clear error status register
    _ = lapicesr();

    // Issue an INIT Level De-Assert to synchronise arbitration ID's.
    if (lapicbase != null) {
        lapicw(LapicICRHI, 0);
        lapicw(LapicICRLO, LapicALLINC | ApicLEVEL | ApicINIT);
        while (lapicr(LapicICRLO) & ApicDELIVS != 0) {}
    }

    // Do not allow acceptance of interrupts until all initialisation
    // for this processor is done: see lapicintron.
}

fn lapicesr() u32 {
    lapicw(LapicESR, 0);
    return lapicr(LapicESR);
}

fn lapicerror(_: *Ureg, _: ?*anyopaque) void {
    const esr = lapicesr();
    print("cpu%d: lapicerror: 0x%8.8uX\n", .{ m().machno, esr });
}

fn lapicspurious(_: *Ureg, _: ?*anyopaque) void {
    print("cpu%d: lapicspurious\n", .{m().machno});
}

fn lapiceoi(_: i32) i32 {
    l.coherence();
    lapicw(LapicEOI, 0);
    return 0;
}

/// Arrange for the clock interrupt at cycle count `next`.
pub fn lapictimerset(next: u64) void {
    const a = &lapictimer[@intCast(m().machno)];
    const now = clock.fastticks(null);
    var period: u64 = if (next > now) (next - now) / a.div else 0;
    if (period < a.min)
        period = a.min
    else if (period > a.max - a.min)
        period = a.max;
    lapicw(LapicTICR, @intCast(period));
}

fn lapicclock(ureg: *Ureg, _: ?*anyopaque) void {
    portclock.timerintr(ureg, 0);
}

pub fn lapicintron() void {
    lapicw(LapicTPR, 0);
}

pub fn lapicintroff() void {
    lapicw(LapicTPR, 0xFF);
}

// I/O APICs

const IoapicID = 0x00; // ID
const IoapicVER = 0x01; // Version
const IoapicRDT = 0x10; // Redirection Table

const Ioapic = struct {
    addr: [*]volatile u32,
    gsibase: u32,
    /// Number of redirection entries.
    nrdt: u32,
    lock: taslock.Lock = .{},
};

var ioapics: [8]Ioapic = undefined;
var nioapic: usize = 0;

fn ioapicread(a: *Ioapic, reg: u32) u32 {
    a.addr[0] = reg; // I/O register select
    return a.addr[4]; // I/O window
}

fn ioapicwrite(a: *Ioapic, reg: u32, v: u32) void {
    a.addr[0] = reg;
    a.addr[4] = v;
}

fn rdtwrite(a: *Ioapic, pin: u32, hi: u32, lo: u32) void {
    taslock.ilock(&a.lock);
    ioapicwrite(a, IoapicRDT + 2 * pin + 1, hi);
    ioapicwrite(a, IoapicRDT + 2 * pin, lo);
    taslock.iunlock(&a.lock);
}

/// The I/O APIC and pin that global system interrupt `gsi` arrives on.
fn gsipin(gsi: u32) ?struct { *Ioapic, u32 } {
    for (ioapics[0..nioapic]) |*a| {
        if (gsi >= a.gsibase and gsi - a.gsibase < a.nrdt)
            return .{ a, gsi - a.gsibase };
    }
    return null;
}

/// Mask and silence the 8259 pair; with APICs in use nothing arrives
/// through it, except that it can still raise a spurious IRQ7 or IRQ15,
/// so it is given vectors where those are recognised.
fn i8259off() void {
    l.outb(0x20, 0x11); // ICW1: edge triggered, cascade, ICW4 follows
    l.outb(0x21, dat.VectorPIC); // ICW2: vector base
    l.outb(0x21, 0x04); // ICW3: slave on IRQ2
    l.outb(0x21, 0x01); // ICW4: 8086 mode
    l.outb(0xA0, 0x11);
    l.outb(0xA1, dat.VectorPIC + 8);
    l.outb(0xA1, 0x02);
    l.outb(0xA1, 0x01);
    l.outb(0x21, 0xFF); // mask everything
    l.outb(0xA1, 0xFF);
}

/// False alarm from the masked 8259s?
pub fn intrspurious(vno: usize) bool {
    return vno == dat.VectorPIC + 7 or vno == dat.VectorPIC + 15;
}

/// Find the interrupt controllers and start the bootstrap processor's.
pub fn intrinit() void {
    if (!acpi.madt(&madt))
        panic("no ACPI MADT: cannot find the interrupt controllers", .{});
    if (madt.nioapic == 0)
        panic("no I/O APIC", .{});
    dat.conf.nmach = @intCast(@max(1, @min(madt.ncpu, mem.MAXMACH)));

    i8259off();

    for (madt.ioapic[0..madt.nioapic]) |ia| {
        const va = mmu.vmap(ia.pa, 1024) orelse panic("ioapic: vmap %llux", .{ia.pa});
        const a = &ioapics[nioapic];
        a.* = .{ .addr = @ptrFromInt(va), .gsibase = ia.gsibase, .nrdt = 0 };
        a.nrdt = ((ioapicread(a, IoapicVER) >> 16) & 0xFF) + 1;
        nioapic += 1;
        // Mask every pin until a driver asks for it.
        var pin: u32 = 0;
        while (pin < a.nrdt) : (pin += 1)
            rdtwrite(a, pin, 0, ApicIMASK);
        print("IOAPIC: %llux %#p gsi %ud-%ud\n", .{ ia.pa, va, a.gsibase, a.gsibase + a.nrdt - 1 });
    }

    lapicinit();

    irq.intrenable(dat.IrqSPURIOUS, lapicspurious, null, dat.BUSUNKNOWN, "lapicspurious");
    irq.intrenable(dat.IrqERROR, lapicerror, null, dat.BUSUNKNOWN, "lapicerror");
}

/// Start the clock interrupt and accept interrupts on this processor.
pub fn clockenable() void {
    if (m().machno == 0)
        irq.intrenable(dat.IrqTIMER, lapicclock, null, dat.BUSUNKNOWN, "clock");
    lapicw(LapicTIMER, LapicCLKIN | LapicONESHOT | (dat.VectorPIC + dat.IrqTIMER));
    lapictimerset(0);
    lapicintron();
}

/// Next vector to give to an external interrupt.  Vectors 16 apart are
/// in different priority classes, so spreading them out keeps one busy
/// device from holding off the rest.
var nextvec: u32 = dat.VectorAPIC;

fn allocvec() i32 {
    const v = nextvec;
    nextvec += 8;
    if (nextvec > dat.MaxVectorAPIC)
        nextvec = dat.VectorAPIC + 1 + (nextvec & 7);
    if (v > dat.MaxVectorAPIC) return -1;
    return @intCast(v);
}

fn ioapicenable(v: *Vctl, shared: bool) i32 {
    if (shared) return 0;
    const a, const pin = gsipin(@intCast(v.aux & 0xffffffff)) orelse return -1;
    const lo: u32 = @intCast(v.aux >> 32);
    rdtwrite(a, pin, lapicid() << 24, lo | @as(u32, @intCast(v.vno)));
    return 0;
}

fn ioapicdisable(v: *Vctl, shared: bool) i32 {
    if (shared) return 0;
    const a, const pin = gsipin(@intCast(v.aux & 0xffffffff)) orelse return -1;
    rdtwrite(a, pin, 0, ApicIMASK);
    return 0;
}

/// Choose the vector for v.irq and fill in how to acknowledge and
/// enable it.  Returns the vector, or -1.
pub fn intrassign(v: *Vctl) i32 {
    const irqno = v.irq;

    // Interrupts of the local APIC itself.
    if (irqno >= dat.IrqLINT0 and irqno <= dat.MaxIrqLAPIC) {
        v.local = true;
        if (irqno != dat.IrqSPURIOUS)
            v.eoi = lapiceoi;
        return dat.VectorPIC + irqno;
    }

    // ISA interrupts: identity mapped to global system interrupts, edge
    // triggered and active high, unless the MADT says otherwise.
    if (irqno < 0 or irqno > dat.MaxIrqPIC)
        return -1;
    var gsi: u32 = @intCast(irqno);
    var lo: u32 = ApicFIXED;
    for (madt.override[0..madt.noverride]) |o| {
        if (o.irq != irqno) continue;
        gsi = o.gsi;
        if (o.flags & 3 == 3) lo |= ApicLOW;
        if ((o.flags >> 2) & 3 == 3) lo |= ApicLEVEL;
    }
    if (gsipin(gsi) == null)
        return -1;

    v.aux = @as(usize, lo) << 32 | gsi;
    v.eoi = lapiceoi;
    v.enable = ioapicenable;
    v.disable = ioapicdisable;

    // A pin that already has a vector shares it.
    if (gsi >= gsivec.len) return -1;
    if (gsivec[gsi] == 0) {
        const vno = allocvec();
        if (vno < 0) return -1;
        gsivec[gsi] = @intCast(vno);
    }
    return gsivec[gsi];
}

/// Vector assigned to each global system interrupt in use, or 0.
var gsivec: [256]u8 = @splat(0);
