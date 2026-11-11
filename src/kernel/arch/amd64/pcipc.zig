//! PCI on the PC: access to configuration space, and MSI interrupts.
//! Stands in for 9/pc/pcipc.c and the MSI code in 9/pc/mp.c.
//!
//! DIFF: almost all of pcipc.c is gone, because it deals with what a
//! 2011-or-later UEFI machine does not need: configuration mechanism
//! #2, the PCI BIOS, the BIOS interrupt routing tables and their
//! per-chipset fix-ups, and assigning resources the firmware left
//! unassigned.  What is here:
//!   - Configuration space is memory mapped (ECAM) where the ACPI MCFG
//!     table describes it, which also reaches the extended registers
//!     above 255.  Without an MCFG, configuration mechanism #1 (I/O
//!     ports 0xCF8/0xCFC) is used.
//!   - Devices interrupt by MSI or MSI-X only.  There is no routing of
//!     the INTx pins, which would need the ACPI AML interpreter.

const acpi = @import("../../plat/acpi.zig");
const mem = @import("mem.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const mmu = @import("mmu.zig");
const apic = @import("apic.zig");
const bootargs = @import("bootargs.zig");
const pci = @import("../../port/pci.zig");
const taslock = @import("../../port/taslock.zig");
const p9 = @import("../../port/print.zig");

const print = p9.print;
const Vctl = dat.Vctl;

const PciADDR = 0xCF8; // CONFIG_ADDRESS
const PciDATA = 0xCFC; // CONFIG_DATA

const Seg = struct {
    /// Kernel address of the configuration space of bus `startbus`.
    va: usize,
    startbus: u8,
    endbus: u8,
};

var segs: [8]Seg = undefined;
var nseg: usize = 0;

var pcicfglock: taslock.Lock = .{};

/// The address of register rno of the device, or null if no ECAM range
/// covers its bus.
fn ecam(tbdf: i32, rno: i32) ?usize {
    const bno: usize = @intCast(pci.BUSBNO(tbdf));
    for (segs[0..nseg]) |s| {
        if (bno < s.startbus or bno > s.endbus) continue;
        return s.va + ((bno - s.startbus) << 20 | @as(usize, @intCast(pci.BUSDNO(tbdf))) << 15 |
            @as(usize, @intCast(pci.BUSFNO(tbdf))) << 12 | @as(usize, @intCast(rno)));
    }
    return null;
}

/// Select a register through configuration mechanism #1.
fn mech1(tbdf: i32, rno: i32) bool {
    if (rno > 255 or pci.BUSDNO(tbdf) > 31) return false;
    const typ: u32 = if (pci.BUSBNO(tbdf) != 0) 0x01 else 0x00;
    l.outl(PciADDR, 0x80000000 | @as(u32, @intCast(pci.BUSBNO(tbdf))) << 16 |
        @as(u32, @intCast(pci.BUSDNO(tbdf))) << 11 | @as(u32, @intCast(pci.BUSFNO(tbdf))) << 8 |
        (@as(u32, @intCast(rno)) & ~@as(u32, 3)) | typ);
    return true;
}

fn rw(comptime T: type, tbdf: i32, rno: i32, data: i32, read: bool) i32 {
    if (rno < 0 or rno > 4095 or @as(u32, @intCast(rno)) & (@sizeOf(T) - 1) != 0)
        return -1;
    if (ecam(tbdf, rno)) |a| {
        const p: *volatile T = @ptrFromInt(a);
        if (read) return @bitCast(@as(u32, p.*));
        p.* = @truncate(@as(u32, @bitCast(data)));
        return 0;
    }
    if (nseg != 0) return -1;

    var x: i32 = -1;
    const port: u16 = PciDATA + @as(u16, @intCast(rno & 3));
    taslock.ilock(&pcicfglock);
    if (mech1(tbdf, rno)) {
        if (read) {
            x = switch (T) {
                u8 => l.inb(port),
                u16 => l.ins(port),
                else => @bitCast(l.inl(port)),
            };
        } else {
            switch (T) {
                u8 => l.outb(port, @truncate(@as(u32, @bitCast(data)))),
                u16 => l.outs(port, @truncate(@as(u32, @bitCast(data)))),
                else => l.outl(port, @bitCast(data)),
            }
            x = 0;
        }
        l.outl(PciADDR, 0);
    }
    taslock.iunlock(&pcicfglock);
    return x;
}

fn pcicfgrw8raw(tbdf: i32, rno: i32, data: i32, read: bool) i32 {
    return rw(u8, tbdf, rno, data, read);
}

fn pcicfgrw16raw(tbdf: i32, rno: i32, data: i32, read: bool) i32 {
    return rw(u16, tbdf, rno, data, read);
}

fn pcicfgrw32raw(tbdf: i32, rno: i32, data: i32, read: bool) i32 {
    return rw(u32, tbdf, rno, data, read);
}

/// Find configuration space and the devices in it.
pub fn pcicfginit() void {
    var e: [segs.len]acpi.Ecam = undefined;
    const n = acpi.mcfg(&e);
    var maxbno: i32 = 0;
    for (e[0..n]) |x| {
        // Only the first segment group: a bus number names a bus.
        if (x.segment != 0) continue;
        const nbus = @as(usize, x.endbus - x.startbus) + 1;
        const va = mmu.vmap(x.base + (@as(u64, x.startbus) << 20), nbus << 20) orelse {
            print("pci: cannot map configuration space at %#llux\n", .{x.base});
            continue;
        };
        print("pci: ecam %#llux bus %d-%d\n", .{ x.base, x.startbus, x.endbus });
        segs[nseg] = .{ .va = va, .startbus = x.startbus, .endbus = x.endbus };
        nseg += 1;
        maxbno = @max(maxbno, x.endbus);
    }
    if (nseg == 0) {
        print("pci: no MCFG table; using I/O ports for configuration\n", .{});
        maxbno = 255;
    }

    pci.pcicfgrw8raw = pcicfgrw8raw;
    pci.pcicfgrw16raw = pcicfgrw16raw;
    pci.pcicfgrw32raw = pcicfgrw32raw;
    pci.pcimaxbno = maxbno;
    pci.pcimaxdno = 31;

    apic.msiassign = msiintrenable;
    pci.pciscaninit();
    pcilist();
}

/// Every device found, four to a line: bus.device.function,
/// vendor/device, class.subclass.interface, and for a bridge the bus
/// behind it.  *pcihinv= in plan9.ini gives 9front's fuller listing
/// with the memory of each.
/// DIFF: not in 9front, where this is what pci(8) is for; on a
/// machine that does not get as far as a shell the list of what is
/// there is the first thing wanted.
fn pcilist() void {
    if (bootargs.getconf("*nopcilist") != null)
        return;
    var n: usize = 0;
    var pp: ?*pci.Pcidev = null;
    while (pci.pcimatch(pp, 0, 0)) |p| : (pp = p) {
        print("%s%d.%d.%d %.4ux/%.4ux %.2ux.%.2ux.%.2ux", .{
            if (n % 4 == 0) "pci: " else "  ",
            pci.BUSBNO(p.tbdf),
            pci.BUSDNO(p.tbdf),
            pci.BUSFNO(p.tbdf),
            p.vid,
            p.did,
            p.ccrb,
            p.ccru,
            p.ccrp,
        });
        if (p.bridge) |b|
            print(">%d", .{pci.BUSBNO(b.tbdf)});
        n += 1;
        if (n % 4 == 0)
            print("\n", .{});
    }
    if (n % 4 != 0)
        print("\n", .{});
    if (n == 0)
        print("pci: no devices\n", .{});
}

fn msiirqenable(v: *Vctl, _: bool) i32 {
    const p = pci.pcimatchtbdf(v.tbdf) orelse return -1;
    return pci.pcimsienable(p, 0xFEE00000 | (@as(u64, @intCast(v.dest)) & 0xFF) << 12, @as(u32, @intCast(v.vno)) | (1 << 14));
}

fn msiirqdisable(v: *Vctl, _: bool) i32 {
    const p = pci.pcimatchtbdf(v.tbdf) orelse return -1;
    return pci.pcimsidisable(p);
}

/// Give a PCI device's interrupt a vector of its own, delivered as a
/// message to this processor.  Returns the vector, or -1 if the device
/// cannot do that.
fn msiintrenable(v: *Vctl) i32 {
    if (bootargs.getconf("*nomsi") != null)
        return -1;
    const tbdf = v.tbdf;
    if (tbdf == dat.BUSUNKNOWN or pci.BUSTYPE(tbdf) != pci.BusPCI)
        return -1;
    const p = pci.pcimatchtbdf(tbdf) orelse {
        print("msiintrenable: could not find Pcidev for tbdf %T\n", .{pci.tbdf(tbdf)});
        return -1;
    };
    if (pci.pcicap(p, pci.PciCapMSI) < 0 and pci.pcicap(p, pci.PciCapMSIX) < 0)
        return -1;
    const vno = apic.allocvec();
    if (vno < 0) return -1;

    v.isr = null;
    v.eoi = apic.lapiceoi;
    v.vno = vno;
    v.dest = @intCast(apic.apicno());
    v.enable = msiirqenable;
    v.disable = msiirqdisable;
    return vno;
}
