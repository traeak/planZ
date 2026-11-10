//! Memory management unit: page tables, segment tables, address
//! conversion.
//! from 9/pc64/mmu.c
//!
//! DIFF: physical memory is reached through the loader's direct map at
//! DMAP, so kaddr is an offset, kmap is kaddr, and there is no KMAP
//! window or per-process kmap list.  For the same reason preallocpages
//! is gone: the kernel's own memory is not confined to 2GiB, so the
//! page array and the MMU pool come from the ordinary allocators.
//! kernelro is gone: the loader maps the kernel segments with the
//! permissions the ELF asks for.

const bootinfo = @import("bootinfo");
const mem = @import("mem.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const memory = @import("memory.zig");
const bootargs = @import("bootargs.zig");
const alloc = @import("../../port/alloc.zig");
const taslock = @import("../../port/taslock.zig");
const portdat = @import("../../port/portdat.zig");
const p9 = @import("../../port/print.zig");
const print = p9.print;
const panic = p9.panic;

const Segdesc = dat.Segdesc;
const MMU = dat.MMU;
const m = dat.m;

fn EXECSEGM(p: u32) Segdesc {
    return .{ .d0 = 0, .d1 = mem.SEGL | mem.SEGP | mem.SEGPL(p) | mem.SEGEXEC };
}
fn DATASEGM(p: u32) Segdesc {
    return .{ .d0 = 0, .d1 = mem.SEGB | mem.SEGG | mem.SEGP | mem.SEGPL(p) | mem.SEGDATA | mem.SEGW };
}
fn EXEC32SEGM(p: u32) Segdesc {
    return .{ .d0 = 0xFFFF, .d1 = mem.SEGG | mem.SEGD | (0xF << 16) | mem.SEGP | mem.SEGPL(p) | mem.SEGEXEC | mem.SEGR };
}
fn DATA32SEGM(p: u32) Segdesc {
    return .{ .d0 = 0xFFFF, .d1 = mem.SEGB | mem.SEGG | (0xF << 16) | mem.SEGP | mem.SEGPL(p) | mem.SEGDATA | mem.SEGW };
}

pub const gdt: [mem.NGDT]Segdesc = blk: {
    var g: [mem.NGDT]Segdesc = @splat(.{});
    g[mem.KESEG] = EXECSEGM(0); // kernel code
    g[mem.KDSEG] = DATASEGM(0); // kernel data
    g[mem.UE32SEG] = EXEC32SEGM(3); // user code 32 bit
    g[mem.UDSEG] = DATA32SEGM(3); // user data/stack
    g[mem.UESEG] = EXECSEGM(3); // user code
    break :blk g;
};

/// GDT of the bootstrap processor.
pub var gdt0: [mem.NGDT]Segdesc align(16) = gdt;

pub fn PTENOEXEC() u64 {
    return @as(u64, @intFromBool(m().havenx)) << 63;
}

/// Switch from the firmware's segment tables to the kernel's, so that
/// CS is KESEL (the trap entry tells kernel from user by it), and point
/// GS at this processor's Mach.  What _start64v does in l.s.
pub fn gdtinit(machno: usize, g: [*]Segdesc) void {
    l.lgdt(@sizeOf(@TypeOf(gdt)) - 1, @intFromPtr(g));
    l.setsegs(mem.KESEL);
    l.wrmsr(dat.FSbase, 0);
    l.wrmsr(dat.GSbase, @intFromPtr(&dat.machp[machno]));
    l.wrmsr(dat.KernelGSbase, 0);
}

fn taskswitch(stack: usize) void {
    const tss = m().tss.?;
    tss.rsp0 = .{ @truncate(stack), @truncate(stack >> 32) };
    tss.rsp1 = tss.rsp0;
    tss.rsp2 = tss.rsp0;
    mmuflushtlb();
}

/// Reload CR3: drops every TLB entry that is not global.
pub fn mmuflushtlb() void {
    m().tlbflush +%= 1;
    l.putcr3(paddr(@intFromPtr(m().pml4)));
}

var mmupool: struct {
    lock: taslock.Lock = .{},
    free: ?*MMU = null,
    nalloc: u32 = 0,
    nfree: u32 = 0,
} = .{};

// MMU.level: which table an MMU's page is entered in.
const PML4E = 2;
const PDPE = 1;
const PDE = 0;

const MAPBITS = 64;

/// A page-table page for the current process, with its MMU record.
fn mmualloc() ?*MMU {
    const mach = m();
    var p: *MMU = undefined;
    if (mach.mmufree) |f| {
        p = f;
        mach.mmufree = p.next;
        mach.mmucount -= 1;
    } else {
        taslock.lock(&mmupool.lock);
        if (mmupool.free) |f| {
            p = f;
            mmupool.free = p.next;
            mmupool.nfree -= 1;
        } else {
            taslock.unlock(&mmupool.lock);
            const n = 256;
            const a = alloc.newslice(MMU, n) orelse return null;
            const pages = alloc.mallocalign(n * mem.PTSZ, mem.BY2PG, 0, 0) orelse {
                alloc.free(a);
                return null;
            };
            for (a, 0..) |*x, i| {
                x.* = .{ .page = @ptrCast(@alignCast(pages + i * mem.PTSZ)) };
                if (i > 0) a[i - 1].next = x;
            }
            p = &a[0];
            taslock.lock(&mmupool.lock);
            a[n - 1].next = mmupool.free;
            mmupool.free = p.next;
            mmupool.nalloc += n;
            mmupool.nfree += n - 1;
        }
        taslock.unlock(&mmupool.lock);
    }
    p.next = null;
    return p;
}

/// Drop every user entry from this processor's top-level table.
fn mmuzap() void {
    const mach = m();
    const pte = mach.pml4;

    // common case
    pte[mem.PTLX(mem.UTZERO, 3)] = 0;
    pte[mem.PTLX(mem.USTKTOP - 1, 3)] = 0;
    mach.mmumap[mem.PTLX(mem.UTZERO, 3) / MAPBITS] &= ~(@as(u64, 1) << @intCast(mem.PTLX(mem.UTZERO, 3) % MAPBITS));
    mach.mmumap[mem.PTLX(mem.USTKTOP - 1, 3) / MAPBITS] &= ~(@as(u64, 1) << @intCast(mem.PTLX(mem.USTKTOP - 1, 3) % MAPBITS));

    for (&mach.mmumap, 0..) |*wp, i| {
        var w = wp.*;
        if (w == 0) continue;
        wp.* = 0;
        var x: usize = 0;
        while (w != 0) : ({
            w >>= 1;
            x += 1;
        }) {
            if (w & 1 != 0)
                pte[i * MAPBITS + x] = 0;
        }
    }
}

fn mmufree(p: *dat.Proc) void {
    const mach = m();
    const tail = p.mmu.mmutail orelse return;
    if (mach.mmucount + p.mmu.mmucount < 256) {
        tail.next = mach.mmufree;
        mach.mmufree = p.mmu.mmuhead;
        mach.mmucount += p.mmu.mmucount;
    } else {
        taslock.lock(&mmupool.lock);
        tail.next = mmupool.free;
        mmupool.free = p.mmu.mmuhead;
        mmupool.nfree += p.mmu.mmucount;
        taslock.unlock(&mmupool.lock);
    }
    p.mmu.mmuhead = null;
    p.mmu.mmutail = null;
    p.mmu.mmucount = 0;
}

/// Make `p`'s address space the current one; with `newtlb`, throw its
/// page tables away first so they are rebuilt by faults.
pub fn mmuswitch(p: *dat.Proc, newtlb: bool) void {
    const mach = m();
    mmuzap();
    if (newtlb)
        mmufree(p);
    var it = p.mmu.mmuhead;
    while (it) |x| : (it = x.next) {
        if (x.level != PML4E) break;
        mach.mmumap[x.index / MAPBITS] |= @as(u64, 1) << @intCast(x.index % MAPBITS);
        mach.pml4[x.index] = paddr(@intFromPtr(x.page)) | mem.PTEUSER | mem.PTEWRITE | mem.PTEVALID;
    }
    taskswitch(@intFromPtr(p));
}

/// Free the page tables of a dead process.
pub fn mmurelease(p: *dat.Proc) void {
    mmuzap();
    mmufree(p);
    taskswitch(@intFromPtr(m()) + mem.MACHSIZE);
}

/// The page table entry for user address va in the current process,
/// waiting for memory if it must.
fn getpte(va: usize) *u64 {
    if (mmuwalk(m().pml4, va, 0, true)) |pte| return pte;
    flushmmu();
    while (true) {
        if (mmuwalk(m().pml4, va, 0, true)) |pte| return pte;
        const x = l.spllo();
        @import("../../port/pgrp.zig").resrcwait("out of MMU pages") catch {};
        l.splx(x);
    }
}

/// Enter the mapping va -> pa for the current process.  The low bits
/// of `pa` are the PTE flags.
pub fn putmmu(va: usize, pa: u64, _: *portdat.Page) void {
    const x = l.splhi();
    const pte = getpte(va);
    const old = pte.*;
    pte.* = pa | mem.PTEACCESSED | mem.PTEDIRTY | mem.PTEUSER;
    l.splx(x);
    if (old & mem.PTEVALID != 0)
        l.invlpg(va);
}

/// Throw away the current process's page tables; faults rebuild them.
/// from flushmmu in 9/port/proc.c
pub fn flushmmu() void {
    const x = l.splhi();
    const p = dat.up().?;
    m().tlbflush +%= 1;
    p.tlbflush +%= 1;
    p.newtlb = false;
    mmuswitch(p, true);
    l.splx(x);
}

/// Double-check the user MMU.
/// Error checking only.
pub fn checkmmu(va: usize, pa: u64) void {
    const x = l.splhi();
    const pte = mmuwalk(m().pml4, va, 0, false);
    if (pte == null or pte.?.* & mem.PTEVALID == 0 or mem.PPN(pte.?.*) == pa) {
        l.splx(x);
        return;
    }
    const old = pte.?.*;
    l.splx(x);
    const p = dat.up().?;
    print("%ld %s: va=%#p pa=%#p pte=%#p\n", .{ p.pid, p.text, va, pa, old });
}

/// A kernel address for the contents of a page.
/// DIFF: always the direct map; the C needs a per-process window (KMAP)
/// for pages outside the 2GiB it maps at KZERO.
pub fn kmap(page: *portdat.Page) usize {
    return kaddr(page.pa);
}

pub fn kunmap(_: usize) void {}

pub fn mmuinit() void {
    const mach = m();

    // zap double map done by the loader
    mach.pml4[0] = 0;

    if (mach.machno == 0) dmapnoexec();

    const tss: *dat.Tss = @ptrCast(@alignCast(alloc.mallocz(@sizeOf(dat.Tss), true) orelse
        panic("mmuinit: no memory for Tss", .{})));
    mach.tss = tss;
    tss.iomap = 0xDFFF;
    const x = @intFromPtr(mach) + mem.MACHSIZE;
    var i: usize = 0;
    while (i < 14) : (i += 2) {
        tss.ist[i] = @truncate(x);
        tss.ist[i + 1] = @truncate(x >> 32);
    }

    // We used to keep the GDT in the Mach structure, but it turns out
    // that that slows down access to the rest of the page.
    @memcpy(mach.gdt[0..gdt.len], &gdt);
    const t = @intFromPtr(tss);
    mach.gdt[mem.TSSSEG + 0].d0 = @truncate((t << 16) | (@sizeOf(dat.Tss) - 1));
    mach.gdt[mem.TSSSEG + 0].d1 = @truncate((t & 0xFF000000) | ((t >> 16) & 0xFF) | mem.SEGTSS | mem.SEGPL(0) | mem.SEGP);
    mach.gdt[mem.TSSSEG + 1].d0 = @truncate(t >> 32);
    mach.gdt[mem.TSSSEG + 1].d1 = 0;

    l.lgdt(@sizeOf(@TypeOf(gdt)) - 1, @intFromPtr(mach.gdt));
    taskswitch(x);
    l.ltr(mem.TSSSEL);

    l.wrmsr(dat.FSbase, 0);
    l.wrmsr(dat.GSbase, @intFromPtr(&dat.machp[@intCast(mach.machno)]));
    l.wrmsr(dat.KernelGSbase, 0);

    // enable syscall extension
    l.wrmsr(dat.Efer, l.rdmsr(dat.Efer) | 1);
    l.wrmsr(dat.Star, (@as(u64, mem.UE32SEL) << 48) | (@as(u64, mem.KESEL) << 32));
    l.wrmsr(dat.Lstar, @intFromPtr(&l.syscallentry));
    l.wrmsr(dat.Sfmask, 0x200);
}

/// The loader maps the direct map executable; nothing in it should be.
fn dmapnoexec() void {
    const nx = PTENOEXEC();
    if (nx == 0) return;
    const pdp = table(m().pml4[mem.PTLX(mem.DMAP, 3)]);
    for (pdp) |pdpe| {
        if (pdpe & mem.PTEVALID == 0) continue;
        if (pdpe & mem.PTESIZE != 0) continue;
        for (table(pdpe)) |*pde| {
            if (pde.* & mem.PTEVALID != 0) pde.* |= nx;
        }
    }
    // The first 2MiB stay executable: an application processor starts
    // in the AP bootstrap code there (see mp.zig).  Nothing else in
    // that range is used.
    const lo = mmuwalk(m().pml4, mem.DMAP, 1, false).?;
    lo.* &= ~nx;
}

/// The page-table page a valid entry points to.
fn table(pte: u64) *[512]u64 {
    return @ptrFromInt(kaddr(mem.PPN(pte)));
}

/// Kernel address of physical address `pa`, through the direct map.
pub fn kaddr(pa: u64) usize {
    if (pa >= bootargs.bootinfop.dmap_size)
        panic("kaddr: pa=%#p pc=%#p", .{ pa, @returnAddress() });
    return mem.DMAP + pa;
}

/// Physical address of kernel address `va`.
pub fn paddr(va: usize) u64 {
    if (va >= mem.KZERO) {
        // The kernel image is wherever the loader found room for it.
        const bi = bootargs.bootinfop;
        if (va - bi.kernel_virt < bi.kernel_size)
            return va - bi.kernel_virt + bi.kernel_phys;
    } else if (va >= mem.VMAP) {
        return va - mem.VMAP;
    } else if (va >= mem.DMAP) {
        return va - mem.DMAP;
    }
    panic("paddr: va=%#p pc=%#p", .{ va, @returnAddress() });
}

fn mmucreate(tab: [*]u64, va: usize, level: u6, index: usize) ?[*]u64 {
    var flags: u64 = mem.PTEWRITE | mem.PTEVALID;
    var page: [*]u64 = undefined;
    if (va < mem.DMAP) {
        // A user address: the table belongs to the current process.
        const up = dat.up() orelse panic("mmucreate: user va=%#p with no process", .{va});
        if (va >= mem.USTKTOP) panic("mmucreate: va=%#p", .{va});
        const p = mmualloc() orelse return null;
        p.index = index;
        p.level = level;
        flags |= mem.PTEUSER;
        if (level == PML4E) {
            p.next = up.mmu.mmuhead;
            if (p.next == null)
                up.mmu.mmutail = p;
            up.mmu.mmuhead = p;
            m().mmumap[index / MAPBITS] |= @as(u64, 1) << @intCast(index % MAPBITS);
        } else {
            up.mmu.mmutail.?.next = p;
            up.mmu.mmutail = p;
        }
        up.mmu.mmucount += 1;
        page = p.page;
        @memset(page[0..512], 0);
    } else {
        page = @ptrFromInt(memory.rampage());
    }
    tab[index] = paddr(@intFromPtr(page)) | flags;
    return page;
}

/// The entry for `va` at `level` (0 is the page table, 3 the PML4) in
/// the tree rooted at `tab`, making the tables on the way if `create`.
/// Null if a table is missing, or the address is covered by a larger
/// page than the level asked for.
pub fn mmuwalk(tab_: [*]u64, va: usize, level: u6, create: bool) ?*u64 {
    var tab = tab_;
    var x = mem.PTLX(va, 3);
    var i: u6 = 3;
    while (i > level) {
        i -= 1;
        const pte = tab[x];
        if (pte & mem.PTEVALID != 0) {
            if (pte & mem.PTESIZE != 0) return null;
            tab = table(pte);
        } else {
            if (!create) return null;
            tab = mmucreate(tab, va, i, x) orelse return null;
        }
        x = mem.PTLX(va, i);
    }
    return &tab[x];
}

fn ptecount(va: usize, level: u6) usize {
    return (1 << mem.PTSHIFT) - (va & (mem.PGLSZ(level + 1) - 1)) / mem.PGLSZ(level);
}

/// Replace the 2MiB page covering `va` with a table of 4KiB pages.
fn ptesplit(tab: [*]u64, va_: usize) void {
    const pte = mmuwalk(tab, va_, 1, false) orelse return;
    if (pte.* & mem.PTESIZE == 0 or va_ & (mem.PGLSZ(1) - 1) == 0) return;
    const new: [*]u64 = @ptrFromInt(memory.rampage());
    const va = va_ & ~(mem.PGLSZ(1) - 1);
    const pa = pte.* & ~mem.PTESIZE;
    var off: usize = 0;
    while (off < mem.PGLSZ(1)) : (off += mem.PGLSZ(0))
        new[mem.PTLX(va + off, 0)] = pa + off;
    pte.* = paddr(@intFromPtr(new)) | mem.PTEVALID | mem.PTEWRITE;
    l.invlpg(va);
}

/// Map `size` bytes at kernel address `va` to the physical address in
/// `pa_`, whose low bits and top bit carry the PTE flags to use.
pub fn pmap(pa_: u64, va_: usize, size_: usize) void {
    var va = va_;
    var size: isize = @intCast(size_);
    if (size <= 0 or va < mem.VMAP or va % mem.BY2PG != 0)
        panic("pmap: pa=%#p va=%#p size=%lld", .{ pa_, va, size });
    var pa = mem.PPN(pa_);
    var flags = (pa_ - pa) | mem.PTEACCESSED | mem.PTEDIRTY;
    if (va >= mem.KZERO)
        flags |= mem.PTEGLOBAL;
    const pml4 = m().pml4;
    while (size > 0) {
        var lvl: u6 = 0;
        var pte: ?*u64 = null;
        if (size >= mem.PGLSZ(1) and (va | pa) % mem.PGLSZ(1) == 0) {
            pte = mmuwalk(pml4, va, 0, false);
            if (pte == null) lvl = 1;
        }
        if (pte == null)
            pte = mmuwalk(pml4, va, lvl, true);
        if (pte == null) {
            // In the way is a 2MiB page mapping the same memory: extend
            // the request to cover it whole.
            var ok = false;
            if (lvl == 0 and (va ^ pa) % mem.PGLSZ(1) == 0) {
                lvl = 1;
                pte = mmuwalk(pml4, va, lvl, false);
                if (pte != null and pte.?.* & mem.PTESIZE != 0) {
                    const z = va & (mem.PGLSZ(1) - 1);
                    va -= z;
                    pa -= z;
                    size += @intCast(z);
                    ok = true;
                }
            }
            if (!ok) panic("pmap: pa=%#p va=%#p size=%lld", .{ pa, va, size });
        }
        const z = mem.PGLSZ(lvl);
        if (lvl == 0) flags &= ~mem.PTESIZE else flags |= mem.PTESIZE;
        var p: [*]u64 = @ptrCast(pte.?);
        var n = ptecount(va, lvl);
        while (size > 0 and n > 0) : (n -= 1) {
            p[0] = pa | flags;
            p += 1;
            pa += z;
            va += z;
            size -= @intCast(z);
        }
    }
}

pub fn punmap(va_: usize, size_: usize) void {
    var va = va_ & ~(mem.PGLSZ(0) - 1);
    var size: isize = @intCast(size_);
    const pml4 = m().pml4;
    while (size > 0) {
        if (va % mem.PGLSZ(1) != 0 or size < mem.PGLSZ(1))
            ptesplit(pml4, va);
        var lvl: u6 = 0;
        var pte = mmuwalk(pml4, va, lvl, false);
        if (pte == null and va % mem.PGLSZ(1) == 0 and size >= mem.PGLSZ(1)) {
            lvl = 1;
            pte = mmuwalk(pml4, va, lvl, false);
        }
        if (pte) |p| {
            p.* = 0;
            l.invlpg(va);
        }
        va += mem.PGLSZ(lvl);
        size -= @intCast(mem.PGLSZ(lvl));
    }
}

/// Map device memory at `pa`; returns its kernel address, or null.
/// The mapping is uncached and not executable.
pub fn vmap(pa_: u64, size_: usize) ?usize {
    if (pa_ < mem.BY2PG or size_ == 0 or pa_ +% size_ < pa_ or pa_ + size_ > mem.VMAPSIZE) {
        print("vmap pa=%llux size=%lld pc=%#p\n", .{ pa_, size_, @returnAddress() });
        return null;
    }
    // might be asking for less than a page.
    const o = pa_ & (mem.BY2PG - 1);
    const pa = pa_ - o;
    const size = mem.PGROUND(size_ + o);
    const va = mem.VMAP + pa;
    pmap(pa | mem.PTEUNCACHED | mem.PTEWRITE | PTENOEXEC() | mem.PTEVALID, va, size);
    return va + o;
}

pub fn vunmap(va: usize, _: usize) void {
    _ = paddr(va); // will panic on error
}

/// mark pages as write combining (used for framebuffer)
pub fn patwc(a: usize, n_: usize) void {
    // check if pat is usable
    if (dat.MACHP(0).cpuiddx & dat.Pat == 0 or (l.rdmsr(0x277) >> (mem.PATWC * 8)) & 7 != 1)
        return;

    // set the bits for all pages in range
    const pml4 = m().pml4;
    var va = a;
    var n: isize = @intCast(n_);
    while (n > 0) {
        var lvl: u6 = 0;
        var pte = mmuwalk(pml4, va, lvl, false);
        if (pte == null) {
            lvl = 1;
            pte = mmuwalk(pml4, va, lvl, false);
        }
        if (pte == null or pte.?.* & mem.PTEVALID == 0)
            panic("patwc: va=%#p", .{va});
        var z = mem.PGLSZ(lvl);
        z -= va & (z - 1);
        const mask: u64 = if (lvl == 0) 3 << 3 | 1 << 7 else 3 << 3 | 1 << 12;
        const attr: u64 = ((mem.PATWC & 3) << 3) | ((mem.PATWC & 4) << 5) | ((mem.PATWC & 4) << 10);
        pte.?.* = (pte.?.* & ~mask) | (attr & mask);
        l.invlpg(va);
        n -= @intCast(z);
        va += z;
    }
}
