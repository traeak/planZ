//! ACPI static tables: just enough to find the processors, interrupt
//! controllers and timers.  No AML interpreter.
//!
//! The tables are read in place through `kaddr`, which must turn a
//! physical address into a readable kernel address.

const std = @import("std");

/// Supplied by the architecture.
pub var kaddr: *const fn (u64) usize = undefined;

const hdrlen = 36;

var rsdt: []const u8 = &.{};
/// Bytes per entry in the root table: 8 for an XSDT, 4 for an RSDT.
var entsize: usize = 0;

fn mem(pa: u64, len: usize) []const u8 {
    return @as([*]const u8, @ptrFromInt(kaddr(pa)))[0..len];
}

fn le32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn le64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

fn le16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn checksum(b: []const u8) bool {
    var sum: u8 = 0;
    for (b) |c| sum +%= c;
    return sum == 0;
}

/// A whole table at `pa`, or null if it does not check out.
fn table(pa: u64) ?[]const u8 {
    if (pa == 0) return null;
    const len = le32(mem(pa, hdrlen), 4);
    if (len < hdrlen) return null;
    const t = mem(pa, len);
    return if (checksum(t)) t else null;
}

/// Locate the root table from the RSDP the firmware handed over.
pub fn init(rsdp_pa: u64) bool {
    if (rsdp_pa == 0) return false;
    const rsdp = mem(rsdp_pa, 36);
    if (!std.mem.eql(u8, rsdp[0..8], "RSD PTR ") or !checksum(rsdp[0..20]))
        return false;
    if (rsdp[15] >= 2) {
        if (table(le64(rsdp, 24))) |t| {
            rsdt = t;
            entsize = 8;
            return true;
        }
    }
    if (table(le32(rsdp, 16))) |t| {
        rsdt = t;
        entsize = 4;
        return true;
    }
    return false;
}

/// The first table with the given signature.
pub fn find(sig: *const [4]u8) ?[]const u8 {
    if (entsize == 0) return null;
    var off: usize = hdrlen;
    while (off + entsize <= rsdt.len) : (off += entsize) {
        const pa = if (entsize == 8) le64(rsdt, off) else le32(rsdt, off);
        const t = table(pa) orelse continue;
        if (std.mem.eql(u8, t[0..4], sig)) return t;
    }
    return null;
}

/// Each table's signature, for the boot log.
pub fn each(f: *const fn (sig: []const u8, len: usize) void) void {
    if (entsize == 0) return;
    var off: usize = hdrlen;
    while (off + entsize <= rsdt.len) : (off += entsize) {
        const pa = if (entsize == 8) le64(rsdt, off) else le32(rsdt, off);
        const t = table(pa) orelse continue;
        f(t[0..4], t.len);
    }
}

pub const Cpu = struct {
    apicid: u32,
    /// Usable now; otherwise the firmware says it may come online later.
    enabled: bool,
};

pub const Ioapic = struct {
    id: u8,
    pa: u64,
    /// First global system interrupt this I/O APIC handles.
    gsibase: u32,
};

/// An ISA interrupt wired to a different global system interrupt, or
/// with other than the ISA default polarity and trigger mode.
pub const Override = struct {
    irq: u8,
    gsi: u32,
    /// MPS INTI flags: bits 0-1 polarity, bits 2-3 trigger mode.
    flags: u16,
};

/// The Multiple APIC Description Table.
pub const Madt = struct {
    lapic_pa: u64 = 0,
    /// The machine also has a pair of 8259 PICs that must be masked.
    pcat: bool = false,
    cpu: [256]Cpu = undefined,
    ncpu: usize = 0,
    ioapic: [8]Ioapic = undefined,
    nioapic: usize = 0,
    override: [32]Override = undefined,
    noverride: usize = 0,
};

pub fn madt(out: *Madt) bool {
    const t = find("APIC") orelse return false;
    if (t.len < 44) return false;
    out.* = .{};
    out.lapic_pa = le32(t, 36);
    out.pcat = le32(t, 40) & 1 != 0;

    var off: usize = 44;
    while (off + 2 <= t.len) {
        const typ = t[off];
        const len = t[off + 1];
        if (len < 2 or off + len > t.len) break;
        const e = t[off..][0..len];
        off += len;
        switch (typ) {
            0 => if (len >= 8) { // processor local APIC
                const fl = le32(e, 4);
                if (fl & 3 != 0 and out.ncpu < out.cpu.len) {
                    out.cpu[out.ncpu] = .{ .apicid = e[3], .enabled = fl & 1 != 0 };
                    out.ncpu += 1;
                }
            },
            1 => if (len >= 12 and out.nioapic < out.ioapic.len) { // I/O APIC
                out.ioapic[out.nioapic] = .{ .id = e[2], .pa = le32(e, 4), .gsibase = le32(e, 8) };
                out.nioapic += 1;
            },
            2 => if (len >= 10 and out.noverride < out.override.len) { // interrupt source override
                out.override[out.noverride] = .{ .irq = e[3], .gsi = le32(e, 4), .flags = le16(e, 8) };
                out.noverride += 1;
            },
            5 => if (len >= 12) { // local APIC address override
                out.lapic_pa = le64(e, 4);
            },
            9 => if (len >= 16) { // processor local x2APIC
                const fl = le32(e, 8);
                if (fl & 3 != 0 and out.ncpu < out.cpu.len) {
                    out.cpu[out.ncpu] = .{ .apicid = le32(e, 4), .enabled = fl & 1 != 0 };
                    out.ncpu += 1;
                }
            },
            else => {},
        }
    }
    return true;
}

/// Physical address of the HPET's registers.
pub fn hpet() ?u64 {
    const t = find("HPET") orelse return null;
    if (t.len < 52) return null;
    // Generic Address Structure at 40: space id 0 is memory.
    if (t[40] != 0) return null;
    const pa = le64(t, 44);
    return if (pa != 0) pa else null;
}
