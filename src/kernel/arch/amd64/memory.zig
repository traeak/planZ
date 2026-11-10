//! Size memory and create the kernel's view of it.
//! from 9/pc/memory.c
//!
//! DIFF: the C probes the BIOS (e820, CMOS, the low megabyte) and maps
//! what it finds at KZERO.  Here the loader supplies the firmware's
//! memory map and has already mapped all of it at DMAP, so this only
//! records the ranges and hands RAM to conf.mem.

const bootinfo = @import("bootinfo");
const mem = @import("mem.zig");
const dat = @import("dat.zig");
const mmu = @import("mmu.zig");
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
            },
            .acpi_reclaim, .acpi_nvs => memmap.memmapadd(r.base, size, MemACPI),
            // Device memory is address space, not storage: it is what
            // upaalloc hands out.  Everything else stays untouched,
            // including what the loader allocated (the kernel image, the
            // page tables in use, the boot information).
            .mmio => memmap.memmapadd(r.base, size, MemUPA),
            else => memmap.memmapadd(r.base, size, MemReserved),
        }
    }
    // The low megabyte is full of firmware leftovers, and the AP
    // bootstrap code will need a page of it.
    memmap.memmapadd(0, mem.MiB, MemReserved);
}

/// Hand the RAM to conf.mem.
pub fn meminit() void {
    const conf = &dat.conf;
    var n: usize = 0;
    var base = memmap.memmapnext(memmap.none, MemRAM);
    while (base != memmap.none) : (base = memmap.memmapnext(base, MemRAM)) {
        const size = memmap.memmapsize(base, mem.BY2PG) & ~@as(u64, mem.BY2PG - 1);
        if (size == 0) continue;
        if (n >= conf.mem.len) {
            print("meminit: out of entries, loosing: %#p (%llud)\n", .{ base, size });
            continue;
        }
        const a = memmap.memmapalloc(base, size, mem.BY2PG, MemRAM);
        if (a == memmap.none) continue;
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
