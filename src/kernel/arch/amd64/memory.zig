//! Size memory and create the kernel's view of it.
//! from 9/pc/memory.c
//!
//! DIFF: the C probes the BIOS (e820, CMOS, the low megabyte) and maps
//! what it finds at KZERO.  Here the loader supplies the firmware's
//! memory map and has already mapped all of it at DMAP, so this only
//! records the ranges and hands RAM to conf.mem.

const std = @import("std");
const bootinfo = @import("bootinfo");
const mem = @import("mem.zig");
const dat = @import("dat.zig");
const mmu = @import("mmu.zig");
const bootargs = @import("bootargs.zig");
const memmap = @import("../../port/memmap.zig");
const xalloc = @import("../../port/xalloc.zig");
const p9 = @import("../../port/print.zig");
const print = p9.print;
const panic = p9.panic;

// Memory map types; when ranges overlap the higher type wins.
pub const MemUPA: u32 = 0; // unbacked physical address
pub const MemUMB: u32 = 1; // upper memory block (<16MB)
pub const MemRAM: u32 = 2; // physical memory
pub const MemACPI: u32 = 3; // ACPI tables
pub const MemReserved: u32 = 4; // don't allocate

/// Set once conf.mem owns the RAM; from then on rampage uses xalloc.
var meminitdone = false;

/// A zeroed page for page tables and the like.
pub fn rampage() usize {
    if (meminitdone)
        return xalloc.xspanalloc(mem.BY2PG, mem.BY2PG, 0);
    const pa = memmap.memmapalloc(memmap.none, mem.BY2PG, mem.BY2PG, MemRAM);
    if (pa == memmap.none)
        panic("rampage: out of memory", .{});
    const va = mmu.kaddr(pa);
    @memset(@as([*]u8, @ptrFromInt(va))[0..mem.BY2PG], 0);
    return va;
}

/// Record the loader's memory map.
pub fn meminit0(bi: *const bootinfo.BootInfo) void {
    const regions = @as([*]const bootinfo.MemRegion, @ptrFromInt(mmu.kaddr(bi.memmap)))[0..bi.memmap_len];
    var ram: u64 = 0;
    var top: u64 = 0;
    for (regions) |r| {
        const size = r.pages * mem.BY2PG;
        switch (r.kind) {
            .usable => {
                // RAM the loader did not map cannot be used.
                if (r.base + size > bi.dmap_size) {
                    print("meminit0: %#llux %#llux beyond the direct map\n", .{ r.base, size });
                    continue;
                }
                memmap.memmapadd(r.base, size, MemRAM);
                ram += size;
                top = @max(top, r.base + size);
            },
            .acpi_reclaim, .acpi_nvs => memmap.memmapadd(r.base, size, MemACPI),
            // Everything else stays untouched, including what the
            // loader allocated (the kernel image, the page tables in
            // use, the boot information).
            // DIFF: the firmware's memory-mapped I/O ranges too.  They
            // are devices' registers in use (the flash, the APICs),
            // not free address space, so they are not MemUPA and
            // upaalloc has nothing to hand out: a PCI resource the
            // firmware left unassigned stays unassigned.  The C learns
            // what is free from the gaps of the BIOS's E820 map.
            else => memmap.memmapadd(r.base, size, MemReserved),
        }
    }
    // The low megabyte is full of firmware leftovers, and the AP
    // bootstrap code will need a page of it.
    memmap.memmapadd(0, mem.MiB, MemReserved);

    print("mem: %llud firmware ranges, %lludM free below %#llux, direct map %lludG\n", .{
        bi.memmap_len, ram / mem.MiB, top, bi.dmap_size / mem.GiB,
    });
    // *memmap= in plan9.ini: the firmware's map, range by range.
    if (bootargs.getconf("*memmap") != null) {
        for (regions) |r|
            print("mem: %.12llux %.12llux %s\n", .{ r.base, r.base + r.pages * mem.BY2PG, kindname(r.kind) });
    }
}

fn kindname(k: bootinfo.MemKind) []const u8 {
    return switch (k) {
        .usable => "free",
        .loader => "loader",
        .acpi_reclaim => "acpi",
        .acpi_nvs => "acpi nvs",
        .runtime => "runtime",
        .mmio => "mmio",
        .bad => "bad",
        .reserved => "reserved",
        _ => "unknown",
    };
}

/// Hand the RAM to conf.mem.
pub fn meminit() void {
    const conf = &dat.conf;
    var n: usize = 0;
    var base = memmap.memmapnext(memmap.none, MemRAM);
    while (base != memmap.none) : (base = memmap.memmapnext(base, MemRAM)) {
        const size = memmap.memmapsize(base, mem.BY2PG) & ~@as(u64, mem.BY2PG - 1);
        if (size == 0) continue;
        const a = memmap.memmapalloc(base, size, mem.BY2PG, MemRAM);
        if (a == memmap.none) continue;
        if (n >= conf.mem.len) {
            // DIFF: the C loses whatever comes after the table is
            // full.  Real firmware cuts low memory into many small
            // pieces and the bulk of a large machine's memory comes
            // last, above 4GiB, so lose the smallest piece instead.
            var small: usize = 0;
            for (conf.mem[0..n], 0..) |cm, i| {
                if (cm.npage < conf.mem[small].npage) small = i;
            }
            if (conf.mem[small].npage >= size / mem.BY2PG) {
                print("meminit: out of entries, loosing: %#p (%llud)\n", .{ base, size });
                base = a;
                continue;
            }
            print("meminit: out of entries, loosing: %#p (%llud)\n", .{ conf.mem[small].base, conf.mem[small].npage * mem.BY2PG });
            std.mem.copyForwards(dat.Confmem, conf.mem[small .. n - 1], conf.mem[small + 1 .. n]);
            n -= 1;
        }
        conf.mem[n] = .{ .base = a, .npage = size / mem.BY2PG };
        n += 1;
        base = a;
    }
    meminitdone = true;
}

/// Reserve a range of physical address space for a device.
pub fn upaalloc(pa: u64, size: u64, alignment: u64) u64 {
    return memmap.memmapalloc(pa, size, alignment, MemUPA);
}

pub fn upafree(pa: u64, size: u64) void {
    memmap.memmapfree(pa, size, MemUPA);
}
