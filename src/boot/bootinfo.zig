//! The contract between a boot loader and the kernel.
//!
//! The loader puts the machine into this state and jumps to the kernel's
//! ELF entry point with the physical address of a `BootInfo` as the first
//! argument (C calling convention of the target):
//!
//!   - interrupts off, firmware boot services gone;
//!   - the kernel image mapped at its link address, contiguous in
//!     physical memory starting at `kernel_phys`;
//!   - physical memory [0, dmap_size) mapped at `dmap_base` (the direct
//!     map) and also at address 0 (identity, to be dropped by the kernel);
//!   - the framebuffer, if there is one and it ends below `dmap_span`,
//!     mapped at `dmap_base` plus its address as well, even when it is
//!     outside [0, dmap_size).  The mapping is an ordinary cached one,
//!     for marks on the screen before the kernel can map anything; the
//!     kernel makes its own for real use.
//!
//! Every address inside BootInfo is physical.  Nothing here is specific
//! to UEFI or to one architecture.

pub const magic: u64 = 0x6f666e497a6e6c50; // "PlnzInfo", little-endian
pub const version: u32 = 1;

/// Base of the direct map of physical memory.
pub const dmap_base: u64 = 0xffff_8000_0000_0000;

/// The loader's direct map is made under one top-level page table
/// entry, so it can reach this far and no further.
pub const dmap_span: u64 = 512 << 30;

pub const BootInfo = extern struct {
    magic: u64 = magic,
    version: u32 = version,
    _pad: u32 = 0,

    dmap_base: u64 = dmap_base,
    dmap_size: u64 = 0,

    kernel_phys: u64 = 0,
    kernel_virt: u64 = 0,
    kernel_size: u64 = 0,

    /// Array of `MemRegion`, sorted by base as the firmware gave it.
    memmap: u64 = 0,
    memmap_len: u64 = 0,

    framebuffer: Framebuffer = .{},

    /// ACPI root pointer, or 0.
    acpi_rsdp: u64 = 0,
    /// Flattened device tree, or 0.
    dtb: u64 = 0,

    /// Kernel command line / plan9.ini text, not NUL terminated.
    cmdline: u64 = 0,
    cmdline_len: u64 = 0,

    /// Array of `BootFile`: files the loader read for the kernel (#/boot).
    files: u64 = 0,
    files_len: u64 = 0,
};

pub const MemKind = enum(u32) {
    /// Free for the kernel to use.
    usable,
    /// Allocated by the loader: kernel image, page tables, BootInfo, boot files.
    loader,
    /// ACPI tables; usable once the tables have been read.
    acpi_reclaim,
    /// ACPI non-volatile storage; never usable.
    acpi_nvs,
    /// Firmware runtime code and data; never usable.
    runtime,
    /// Memory-mapped I/O.
    mmio,
    /// Defective memory.
    bad,
    /// Anything else the firmware wants left alone.
    reserved,
    _,
};

pub const MemRegion = extern struct {
    base: u64,
    pages: u64,
    kind: MemKind,
    _pad: u32 = 0,
};

pub const PixelFormat = enum(u32) {
    none,
    /// Byte order in memory: red, green, blue, unused.
    rgbx8,
    /// Byte order in memory: blue, green, red, unused.
    bgrx8,
    _,
};

pub const Framebuffer = extern struct {
    base: u64 = 0,
    size: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Pixels per scan line; may exceed `width`.
    stride: u32 = 0,
    format: PixelFormat = .none,
};

pub const BootFile = extern struct {
    name: [32]u8,
    base: u64,
    len: u64,
};
