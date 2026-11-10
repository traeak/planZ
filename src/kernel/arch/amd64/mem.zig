//! Memory and machine-specific definitions.
//! from 9/pc64/mem.h
//!
//! DIFF: the fixed low-memory addresses (CONFADDR, IDTADDR, CPU0PML4,
//! CPU0GDT, CPU0MACH ...) are gone; the UEFI loader places the kernel
//! wherever the firmware has room and those structures live in the
//! kernel's own data.  DMAP is new: all of physical memory is mapped
//! there, which replaces KMAP and most uses of VMAP.

const bootinfo = @import("bootinfo");

pub const KiB = 1024;
pub const MiB = 1024 * KiB;
pub const GiB = 1024 * MiB;

// Sizes
pub const BI2BY = 8; // bits per byte
pub const BY2WD = 8; // bytes per word
pub const BY2V = 8; // bytes per double word
pub const BY2PG = 0x1000; // bytes per page
pub const WD2PG = BY2PG / BY2WD; // words per page
pub const PGSHIFT = 12; // log(BY2PG)
pub const BLOCKALIGN = 8;
pub const FPalign = 64;

pub fn ROUND(s: usize, sz: usize) usize {
    return (s + (sz - 1)) & ~(sz - 1);
}

pub fn PGROUND(s: usize) usize {
    return ROUND(s, BY2PG);
}

pub const MAXMACH = 128; // max # cpus system can run

// Size of Proc kernel stack.
// DIFF: unoptimised Zig code uses several times the stack, so Debug
// builds get more.
pub const KSTACK = if (@import("builtin").mode == .debug) 32 * KiB else 8 * KiB;
pub const MACHSIZE = 2 * KSTACK;

// Time
pub const HZ = 100; // clock frequency
pub const MS2HZ = 1000 / HZ; // millisec per clock tick

pub fn TK2SEC(t: usize) usize {
    return t / HZ;
}

// Address spaces. User:
pub const UTZERO: usize = 0x0000000000200000; // first address in user text
pub const UADDRMASK: usize = 0x00007fffffffffff; // canonical address mask
pub const USTKTOP: usize = 0x00007ffffffff000;
pub const USTKSIZE = 16 * MiB; // size of user stack

// Address spaces. Kernel, sorted by address.
pub const DMAP: usize = bootinfo.dmap_base; // direct map of physical memory
pub const VMAP: usize = 0xfffffe8000000000;
pub const VMAPSIZE = 1024 * GiB;
pub const KZERO: usize = 0xffffffff80000000;
pub const KTZERO: usize = KZERO + 1 * MiB + 64 * KiB; // must match kernel.ld

// known x86 segments (in GDT) and their selectors
pub const NULLSEG = 0; // null segment
pub const KESEG = 1; // kernel executable
pub const KDSEG = 2; // kernel data
pub const UE32SEG = 3; // user executable 32bit
pub const UDSEG = 4; // user data/stack
pub const UESEG = 5; // user executable 64bit
pub const TSSSEG = 8; // task segment (two descriptors)
pub const NGDT = 10; // number of GDT entries required

pub const SELGDT = 0 << 2; // selector is in gdt
pub const SELLDT = 1 << 2; // selector is in ldt

pub fn SELECTOR(i: u16, t: u16, p: u16) u16 {
    return (i << 3) | t | p;
}

pub const NULLSEL = SELECTOR(NULLSEG, SELGDT, 0);
pub const KDSEL = NULLSEL;
pub const KESEL = SELECTOR(KESEG, SELGDT, 0);
pub const UE32SEL = SELECTOR(UE32SEG, SELGDT, 3);
pub const UDSEL = SELECTOR(UDSEG, SELGDT, 3);
pub const UESEL = SELECTOR(UESEG, SELGDT, 3);
pub const TSSSEL = SELECTOR(TSSSEG, SELGDT, 0);

// fields in segment descriptors
pub const SEGDATA = 0x10 << 8; // data/stack segment
pub const SEGEXEC = 0x18 << 8; // executable segment
pub const SEGTSS = 0x9 << 8; // TSS segment
pub const SEGCG = 0x0C << 8; // call gate
pub const SEGIG = 0x0E << 8; // interrupt gate
pub const SEGTG = 0x0F << 8; // trap gate
pub const SEGLDT = 0x02 << 8; // local descriptor table
pub const SEGTYPE = 0x1F << 8;

pub const SEGP = 1 << 15; // segment present
pub fn SEGPL(x: u32) u32 {
    return x << 13; // priority level
}
pub const SEGB = 1 << 22; // granularity 1==4k (for expand-down)
pub const SEGD = 1 << 22; // default 1==32bit (for code)
pub const SEGE = 1 << 10; // expand down
pub const SEGW = 1 << 9; // writable (for data/stack)
pub const SEGR = 1 << 9; // readable (for code)
pub const SEGL = 1 << 21; // 64 bit
pub const SEGG = 1 << 23; // granularity 1==4k (for other)

// virtual MMU
pub const PTEMAPMEM = 1 * MiB;
pub const PTEPERTAB = PTEMAPMEM / BY2PG;
pub const SEGMAPSIZE = 65536;
pub const SSEGMAPSIZE = 16;

pub fn PPN(x: u64) u64 {
    return x & ~(@as(u64, 1) << 63 | (BY2PG - 1));
}

// physical MMU
pub const PTEVALID: u64 = 1 << 0;
pub const PTEWT: u64 = 1 << 3;
pub const PTEUNCACHED: u64 = 1 << 4;
pub const PTECACHED: u64 = 0 << 4;
pub const PTEWRITE: u64 = 1 << 1;
pub const PTERONLY: u64 = 0 << 1;
pub const PTEKERNEL: u64 = 0 << 2;
pub const PTEUSER: u64 = 1 << 2;
pub const PTEACCESSED: u64 = 1 << 5;
pub const PTEDIRTY: u64 = 1 << 6;
pub const PTESIZE: u64 = 1 << 7;
pub const PTEGLOBAL: u64 = 1 << 8;

// Hierarchical Page Tables.
// Level 3 is the PML4, level 2 the PDP, level 1 the PD, and level 0 the
// PT pages.  PTLX gives the index into the page-table page at level `l`
// for the virtual address `v`.
pub const PTSZ = 4 * KiB; // page table page size
pub const PTSHIFT = 9;

pub fn PTLX(v: usize, l: u6) usize {
    return (v >> (l * PTSHIFT + PGSHIFT)) & ((1 << PTSHIFT) - 1);
}

pub fn PGLSZ(l: u6) usize {
    return @as(usize, 1) << (l * PTSHIFT + PGSHIFT);
}

/// PAT entry used for write combining
pub const PATWC = 7;
