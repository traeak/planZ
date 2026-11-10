//! UEFI boot loader for planZ.
//!
//! Reads the kernel ELF from the volume the loader was started from,
//! places it in memory, builds the first page tables, leaves boot
//! services and jumps to the kernel with a `BootInfo`.
//!
//! This replaces the 32-bit multiboot entry of 9/pc64/l.s (_protected,
//! _warp64, _lme) and the BIOS e820 scan of 9/pc/memory.c.

const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const bootinfo = @import("bootinfo");

const BootInfo = bootinfo.BootInfo;
const MemRegion = bootinfo.MemRegion;

const kernel_path = std.unicode.utf8ToUtf16LeStringLiteral("planz");
const ini_path = std.unicode.utf8ToUtf16LeStringLiteral("plan9.ini");

const page_size = 4096;
const MiB = 1 << 20;
const GiB = 1 << 30;

// x86-64 page table entry bits.
const PTEVALID: u64 = 1 << 0;
const PTEWRITE: u64 = 1 << 1;
const PTESIZE: u64 = 1 << 7;
const PTEGLOBAL: u64 = 1 << 8;
const PTENOEXEC: u64 = 1 << 63;

const Elf64Ehdr = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

const Elf64Phdr = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    @"align": u64,
};

const PT_LOAD = 1;
const PF_X = 1;
const PF_W = 2;
const EM_X86_64 = 62;

const LoadError = error{
    NoBootServices,
    NoFileSystem,
    NoKernel,
    BadKernel,
    ExitFailed,
    FiveLevelPaging,
} || uefi.Error;

var bs: *uefi.tables.BootServices = undefined;

pub fn main() uefi.Status {
    boot() catch |err| {
        puts("planz loader: ");
        puts(@errorName(err));
        puts("\r\n");
        return .load_error;
    };
    unreachable;
}

fn boot() !noreturn {
    bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    puts("planz loader\r\n");

    if (builtin.cpu.arch == .x86_64 and fiveLevelPaging())
        return error.FiveLevelPaging;

    const root = try openVolume();
    const file = (try readFile(root, kernel_path)) orelse return error.NoKernel;
    const image = try loadElf(file);
    // Optional: name=value lines for the kernel.
    const ini: []const u8 = (try readFile(root, ini_path)) orelse "";

    const info_pages = try allocPages(1);
    const info: *BootInfo = @ptrCast(@alignCast(info_pages.ptr));
    info.* = .{
        .kernel_phys = image.phys,
        .kernel_virt = image.virt,
        .kernel_size = image.size,
        .framebuffer = findFramebuffer(),
        .acpi_rsdp = findRsdp(),
        .cmdline = if (ini.len != 0) @intFromPtr(ini.ptr) else 0,
        .cmdline_len = ini.len,
    };

    // Size the direct map: all of the memory map, and at least the low
    // 4GiB so the usual device registers are reachable before the kernel
    // builds its own tables.
    const top = @max(4 * GiB, std.mem.alignForward(u64, try memoryTop(), GiB));
    info.dmap_size = top;

    const pml4 = try buildPageTables(image, file, top);

    // Buffers for the final memory map.  Nothing may be allocated after
    // it has been fetched, so leave room for the map to grow by the
    // allocations made here.
    const probe = try bs.getMemoryMapInfo();
    const slots = probe.len + 16;
    const raw_bytes = slots * probe.descriptor_size;
    const raw_pages = try allocPages(pagesFor(raw_bytes));
    const raw: []align(8) u8 = @alignCast(std.mem.sliceAsBytes(raw_pages)[0..raw_bytes]);
    const region_pages = try allocPages(pagesFor(slots * @sizeOf(MemRegion)));
    const regions: [*]MemRegion = @ptrCast(@alignCast(region_pages.ptr));

    // The first exitBootServices may fail if the map changed under us;
    // the specification allows exactly one more try with a fresh map.
    var map = try bs.getMemoryMap(raw);
    bs.exitBootServices(uefi.handle, map.info.key) catch {
        map = try bs.getMemoryMap(raw);
        bs.exitBootServices(uefi.handle, map.info.key) catch return error.ExitFailed;
    };

    // No firmware calls from here on.
    var n: usize = 0;
    var it = map.iterator();
    while (it.next()) |d| : (n += 1) {
        regions[n] = .{
            .base = d.physical_start,
            .pages = d.number_of_pages,
            .kind = memKind(d.type),
        };
    }
    info.memmap = @intFromPtr(regions);
    info.memmap_len = n;

    enter(@intFromPtr(pml4), image.entry, @intFromPtr(info));
}

/// Switch to the new page tables and jump to the kernel.
fn enter(pml4: u64, entry: u64, info: u64) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            if (haveNx()) {
                // Extended Feature Enable Register: set No-Execute Enable.
                asm volatile (
                    \\ rdmsr
                    \\ orl $0x800, %%eax
                    \\ wrmsr
                    :
                    : [msr] "{ecx}" (@as(u32, 0xc0000080)),
                    : .{ .rax = true, .rdx = true });
            }
            asm volatile (
                \\ cli
                \\ movq %[pml4], %%cr3
                \\ jmpq *%[entry]
                :
                : [pml4] "r" (pml4),
                  [entry] "r" (entry),
                  [info] "{rdi}" (info),
            );
            unreachable;
        },
        else => @compileError("loader: unsupported architecture"),
    }
}

/// True if the firmware runs with 5-level paging (CR4.LA57).  The
/// tables built here are 4-level and the mode cannot be changed while
/// paging is on, so that is refused rather than crashing on entry.
fn fiveLevelPaging() bool {
    const cr4 = asm volatile ("movq %%cr4, %[ret]"
        : [ret] "=r" (-> u64),
    );
    return cr4 & (1 << 12) != 0;
}

fn haveNx() bool {
    var eax: u32 = 0x80000001;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (eax),
          [d] "={edx}" (edx),
        : [f] "{eax}" (eax),
          [z] "{ecx}" (@as(u32, 0)),
        : .{ .rbx = true, .rcx = true });
    return edx & (1 << 20) != 0;
}

/// The volume the loader itself was read from.
fn openVolume() !*uefi.protocol.File {
    const LoadedImage = uefi.protocol.LoadedImage;
    const SimpleFileSystem = uefi.protocol.SimpleFileSystem;

    const li = (try bs.handleProtocol(LoadedImage, uefi.handle)) orelse return error.NoFileSystem;
    const dev = li.device_handle orelse return error.NoFileSystem;
    const fs = (try bs.handleProtocol(SimpleFileSystem, dev)) orelse return error.NoFileSystem;
    return fs.openVolume();
}

/// The contents of a file in the volume's root directory, or null if
/// there is no such file.
fn readFile(root: *uefi.protocol.File, name: [*:0]const u16) !?[]u8 {
    const f = root.open(name, .read, .{}) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };

    // Seeking to the all-ones position means "end of file".
    try f.setPosition(0xffff_ffff_ffff_ffff);
    const size: usize = @intCast(try f.getPosition());
    try f.setPosition(0);

    const buf = std.mem.sliceAsBytes(try allocPages(pagesFor(size)))[0..size];
    var got: usize = 0;
    while (got < size) {
        const k = try f.read(buf[got..]);
        if (k == 0) return error.BadKernel;
        got += k;
    }
    try f.close();
    return buf;
}

const Image = struct {
    /// Lowest virtual address of the image, page aligned.
    virt: u64,
    /// Physical address `virt` is loaded at.
    phys: u64,
    /// Span of the image in bytes, page aligned.
    size: u64,
    entry: u64,
};

fn ehdrOf(file: []const u8) !*align(1) const Elf64Ehdr {
    if (file.len < @sizeOf(Elf64Ehdr)) return error.BadKernel;
    const eh: *align(1) const Elf64Ehdr = @ptrCast(file.ptr);
    if (!std.mem.eql(u8, eh.ident[0..4], "\x7fELF")) return error.BadKernel;
    if (eh.ident[4] != 2 or eh.ident[5] != 1) return error.BadKernel; // 64-bit, little-endian
    if (eh.machine != EM_X86_64) return error.BadKernel;
    if (eh.phentsize != @sizeOf(Elf64Phdr)) return error.BadKernel;
    if (eh.phoff + @as(u64, eh.phnum) * @sizeOf(Elf64Phdr) > file.len) return error.BadKernel;
    return eh;
}

fn phdrsOf(file: []const u8, eh: *align(1) const Elf64Ehdr) []align(1) const Elf64Phdr {
    const p: [*]align(1) const Elf64Phdr = @ptrCast(file.ptr + eh.phoff);
    return p[0..eh.phnum];
}

/// Copy the loadable segments into one contiguous block of physical memory.
fn loadElf(file: []const u8) !Image {
    const eh = try ehdrOf(file);
    const phdrs = phdrsOf(file, eh);

    var lo: u64 = std.math.maxInt(u64);
    var hi: u64 = 0;
    for (phdrs) |ph| {
        if (ph.type != PT_LOAD) continue;
        if (ph.vaddr % page_size != 0) return error.BadKernel;
        if (ph.filesz > ph.memsz or ph.offset + ph.filesz > file.len) return error.BadKernel;
        lo = @min(lo, ph.vaddr);
        hi = @max(hi, std.mem.alignForward(u64, ph.vaddr + ph.memsz, page_size));
    }
    if (lo >= hi) return error.BadKernel;

    const size = hi - lo;
    const mem = std.mem.sliceAsBytes(try allocPages(@intCast(size / page_size)));
    @memset(mem, 0);
    for (phdrs) |ph| {
        if (ph.type != PT_LOAD) continue;
        const off: usize = @intCast(ph.vaddr - lo);
        const n: usize = @intCast(ph.filesz);
        @memcpy(mem[off..][0..n], file[@intCast(ph.offset)..][0..n]);
    }
    return .{ .virt = lo, .phys = @intFromPtr(mem.ptr), .size = size, .entry = eh.entry };
}

const Table = *[512]u64;

fn newTable() !Table {
    const p = try allocPages(1);
    const t: Table = @ptrCast(@alignCast(p.ptr));
    @memset(t, 0);
    return t;
}

/// Index into the page table page at level `l` for address `va`;
/// PTLX in 9/pc64/mem.h.
fn ptlx(va: u64, l: u6) usize {
    return @intCast((va >> (l * 9 + 12)) & 0x1ff);
}

/// Find, creating if needed, the table that entry `i` of `t` points to.
fn descend(t: Table, i: usize) !Table {
    if (t[i] & PTEVALID == 0) {
        const n = try newTable();
        t[i] = @intFromPtr(n) | PTEVALID | PTEWRITE;
    }
    return @ptrFromInt(t[i] & 0x000f_ffff_ffff_f000);
}

fn buildPageTables(image: Image, file: []const u8, top: u64) !Table {
    const nx: u64 = if (haveNx()) PTENOEXEC else 0;
    const pml4 = try newTable();

    // Direct map of [0, top) with 2MiB pages.  The same tables serve as
    // the identity map the loader itself keeps running on.
    const pdp = try newTable();
    pml4[0] = @intFromPtr(pdp) | PTEVALID | PTEWRITE;
    pml4[ptlx(bootinfo.dmap_base, 3)] = pml4[0];
    var pa: u64 = 0;
    while (pa < top) : (pa += 2 * MiB) {
        const pd = try descend(pdp, ptlx(pa, 2));
        pd[ptlx(pa, 1)] = pa | PTESIZE | PTEVALID | PTEWRITE;
    }

    // The kernel, with 4KiB pages and the permissions the ELF asks for.
    const eh = try ehdrOf(file);
    for (phdrsOf(file, eh)) |ph| {
        if (ph.type != PT_LOAD) continue;
        var flags: u64 = PTEVALID | PTEGLOBAL;
        if (ph.flags & PF_W != 0) flags |= PTEWRITE;
        if (ph.flags & PF_X == 0) flags |= nx;
        var va = ph.vaddr;
        const end = std.mem.alignForward(u64, ph.vaddr + ph.memsz, page_size);
        while (va < end) : (va += page_size) {
            const l2 = try descend(pml4, ptlx(va, 3));
            const l1 = try descend(l2, ptlx(va, 2));
            const l0 = try descend(l1, ptlx(va, 1));
            l0[ptlx(va, 0)] = (va - image.virt + image.phys) | flags;
        }
    }
    return pml4;
}

/// One past the highest address in the firmware memory map.
fn memoryTop() !u64 {
    const probe = try bs.getMemoryMapInfo();
    const bytes = (probe.len + 8) * probe.descriptor_size;
    const pages = try allocPages(pagesFor(bytes));
    defer bs.freePages(pages) catch {};
    const buf: []align(8) u8 = @alignCast(std.mem.sliceAsBytes(pages)[0..bytes]);
    const map = try bs.getMemoryMap(buf);

    var top: u64 = 0;
    var it = map.iterator();
    while (it.next()) |d| {
        // Device and reserved ranges can sit far above RAM (a 64-bit PCI
        // window near the top of the address space, say); mapping up to
        // them would take gigabytes of page tables.  The kernel maps
        // those itself.
        switch (memKind(d.type)) {
            .mmio, .reserved, .bad => continue,
            else => {},
        }
        top = @max(top, d.physical_start + d.number_of_pages * page_size);
    }
    return top;
}

fn memKind(t: uefi.tables.MemoryType) bootinfo.MemKind {
    return switch (t) {
        // Boot services memory is free once boot services are gone, and the
        // loader's own code is free once the kernel is running.
        .conventional_memory,
        .boot_services_code,
        .boot_services_data,
        .loader_code,
        => .usable,
        .loader_data => .loader,
        .acpi_reclaim_memory => .acpi_reclaim,
        .acpi_memory_nvs => .acpi_nvs,
        .runtime_services_code, .runtime_services_data => .runtime,
        .memory_mapped_io, .memory_mapped_io_port_space => .mmio,
        .unusable_memory => .bad,
        else => .reserved,
    };
}

fn findFramebuffer() bootinfo.Framebuffer {
    const gop = (bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch null) orelse return .{};
    const mode = gop.mode;
    const format: bootinfo.PixelFormat = switch (mode.info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => .rgbx8,
        .blue_green_red_reserved_8_bit_per_color => .bgrx8,
        else => return .{},
    };
    return .{
        .base = mode.frame_buffer_base,
        .size = mode.frame_buffer_size,
        .width = mode.info.horizontal_resolution,
        .height = mode.info.vertical_resolution,
        .stride = mode.info.pixels_per_scan_line,
        .format = format,
    };
}

fn findRsdp() u64 {
    const Ct = uefi.tables.ConfigurationTable;
    const st = uefi.system_table;
    const tables = st.configuration_table[0..st.number_of_table_entries];
    var rsdp: u64 = 0;
    for (tables) |t| {
        if (t.vendor_guid.eql(Ct.acpi_20_table_guid))
            return @intFromPtr(t.vendor_table);
        if (t.vendor_guid.eql(Ct.acpi_10_table_guid))
            rsdp = @intFromPtr(t.vendor_table);
    }
    return rsdp;
}

fn pagesFor(bytes: usize) usize {
    return @max(1, (bytes + page_size - 1) / page_size);
}

fn allocPages(n: usize) ![]align(4096) uefi.Page {
    return bs.allocatePages(.any, .loader_data, n);
}

fn puts(s: []const u8) void {
    const out = uefi.system_table.con_out orelse return;
    var buf: [2:0]u16 = .{ 0, 0 };
    for (s) |c| {
        buf[0] = c;
        _ = out.outputString(buf[0..1 :0]) catch return;
    }
}
