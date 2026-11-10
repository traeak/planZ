//! Starting the other processors.
//! from 9/pc/mp.c (mpinit, the part that starts the application
//! processors) and 9/pc64/squidboy.c
//!
//! DIFF:
//!   - The processors come from the ACPI MADT (see apic.zig); there are
//!     no MP tables and no Apic structures.
//!   - The application processors are started last, just before the
//!     bootstrap processor enters the scheduler, where the C starts them
//!     from the interrupt set-up.  By then everything they share exists.
//!   - An AP begins on a page table kept in low memory beside the
//!     bootstrap code and switches to its own in squidboy.  The C loads
//!     the AP's own table with a 32-bit move, which needs it below 4GiB;
//!     here kernel memory can be anywhere.
//!   - The time stamp counters are not synchronised (syncclock): the CPU
//!     baseline requires an invariant TSC, which runs in step on every
//!     processor.

const std = @import("std");
const bootinfo = @import("bootinfo");
const mem = @import("mem.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const mmu = @import("mmu.zig");
const trap = @import("trap.zig");
const cpu = @import("cpu.zig");
const fpu = @import("fpu.zig");
const apic = @import("apic.zig");
const clock = @import("clock.zig");
const devrtc = @import("devrtc.zig");
const bootargs = @import("bootargs.zig");
const mainmod = @import("main.zig");
const xalloc = @import("../../port/xalloc.zig");
const proc = @import("../../port/proc.zig");
const portclock = @import("../../port/portclock.zig");
const p9 = @import("../../port/print.zig");

const print = p9.print;
const m = dat.m;

/// The page table the APs start on, next to the bootstrap code.
const APPML4 = l.APBOOTSTRAP + mem.BY2PG;

/// Set by each AP when it is running; what the C keeps in Apic.online.
var online: [mem.MAXMACH]bool = @splat(false);

/// An application processor starts here, from the bootstrap code, on
/// its own Mach's stack, with the start-up page table and segments.
fn squidboy(mach: *dat.Mach) callconv(.c) noreturn {
    const machno: usize = @intCast(mach.machno);

    // The kernel's own segment tables, GS for m(), then this
    // processor's page table and the common interrupt table.
    mmu.gdtinit(machno, mach.gdt);
    l.putcr3(mmu.paddr(@intFromPtr(mach.pml4)));
    trap.idtload();

    mainmod.machinit();
    mmu.mmuinit();
    cpu.cpuidentify();
    clock.clockinitap();
    cpu.cpuidprint();
    fpu.mathinit();

    dat.active.machs[machno] = true;
    @atomicStore(bool, &online[machno], true, .seq_cst);

    apic.lapicinit();
    portclock.timersinit();
    apic.clockenable();

    proc.schedinit();
}

/// Is the page at physical address pa ordinary memory that nothing
/// from the firmware lives in?
fn usablepage(pa: u64) bool {
    const bi = bootargs.bootinfop;
    const regions = @as([*]const bootinfo.MemRegion, @ptrFromInt(mmu.kaddr(bi.memmap)))[0..bi.memmap_len];
    for (regions) |r| {
        if (pa >= r.base and pa + mem.BY2PG <= r.base + r.pages * mem.BY2PG)
            return r.kind == .usable;
    }
    return false;
}

fn mpstartap(apicid: u32, machno: usize) void {
    const cur = m();

    // Initialise the AP page-tables and Mach structure.
    // Xspanalloc will panic if an allocation can't be made.
    const p = xalloc.xspanalloc(mem.PTSZ + mem.BY2PG + mem.MACHSIZE, mem.BY2PG, 0);
    const pml4: [*]u64 = @ptrFromInt(p);
    const gdt: [*]dat.Segdesc = @ptrFromInt(p + mem.PTSZ);
    const mach: *dat.Mach = @ptrFromInt(p + mem.PTSZ + mem.BY2PG);
    @memset(@as([*]u8, @ptrFromInt(p))[0 .. mem.PTSZ + mem.BY2PG + mem.MACHSIZE], 0);

    mach.* = .{};
    mach.machno = @intCast(machno);
    mach.pml4 = pml4;
    mach.gdt = gdt;
    @memcpy(gdt[0..mmu.gdt.len], &mmu.gdt);

    dat.machp[machno] = mach;

    // The kernel half is the same on every processor: the tables
    // below the top level are shared.
    @memcpy(pml4[256..512], cur.pml4[256..512]);

    // Tell the AP where its kernel vector and page tables are.
    // The offsets are known in the AP bootstrap code.
    const ap: [*]u8 = @ptrFromInt(mmu.kaddr(l.APBOOTSTRAP));
    @as(*align(1) u64, @ptrCast(ap + l.ApVector)).* = @intFromPtr(&squidboy);
    @as(*align(1) u64, @ptrCast(ap + l.ApPml4)).* = APPML4;
    @as(*align(1) u64, @ptrCast(ap + l.ApMach)).* = @intFromPtr(mach);
    @as(*align(1) u64, @ptrCast(ap + l.ApEfer)).* = 0x100 | @as(u64, @intFromBool(cur.havenx)) << 11;

    // Universal Startup Algorithm.
    const warm: [*]u8 = @ptrFromInt(mmu.kaddr(0x467)); // warm-reset vector
    warm[0] = @truncate(l.APBOOTSTRAP);
    warm[1] = @truncate(l.APBOOTSTRAP >> 8);
    warm[2] = 0;
    warm[3] = 0;
    l.coherence();

    devrtc.nvramwrite(0x0F, 0x0A); // shutdown code: warm reset upon init ipi
    apic.lapicstartap(apicid, l.APBOOTSTRAP);
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        if (@atomicLoad(bool, &online[machno], .seq_cst))
            break;
        clock.delay(1);
    }
    devrtc.nvramwrite(0x0F, 0x00);
}

/// Start the application processors.
pub fn mpinit() void {
    const cur = m();
    const conf = &dat.conf;

    var ncpu: usize = mem.MAXMACH;
    if (bootargs.getconf("*ncpu")) |s| {
        ncpu = std.math.clamp(std.fmt.parseInt(usize, s, 0) catch 1, 1, mem.MAXMACH);
    }
    const cpus = apic.cpus();
    if (cpus.len <= 1 or ncpu == 1)
        return;

    if (!usablepage(l.APBOOTSTRAP) or !usablepage(APPML4)) {
        print("mp: no memory at %#ux for the AP bootstrap; running on one processor\n", .{@as(u32, l.APBOOTSTRAP)});
        return;
    }

    // The top-level entries for the kernel must all exist before they
    // are copied: a table made later would be seen by one processor
    // only.  KZERO and the direct map are there; make the two for VMAP.
    var v: usize = mem.VMAP;
    while (v < mem.VMAP +% mem.VMAPSIZE and v >= mem.VMAP) : (v +%= mem.PGLSZ(3))
        _ = mmu.mmuwalk(cur.pml4, v, 2, true);

    // The bootstrap code, and the page table it turns paging on with:
    // the kernel half, plus low memory mapped at its own address (the
    // direct map's tables serve for that).
    const n = @intFromPtr(&l.apbootstrapend) - @intFromPtr(&l.apbootstrap);
    const src: [*]const u8 = @ptrCast(&l.apbootstrap);
    @memcpy(@as([*]u8, @ptrFromInt(mmu.kaddr(l.APBOOTSTRAP)))[0..n], src[0..n]);
    const appml4: *[512]u64 = @ptrFromInt(mmu.kaddr(APPML4));
    @memset(appml4, 0);
    @memcpy(appml4[256..512], cur.pml4[256..512]);
    appml4[0] = cur.pml4[mem.PTLX(mem.DMAP, 3)];

    const me = apic.apicno();
    for (cpus) |c| {
        if (!c.enabled or c.apicid == me)
            continue;
        if (conf.nmach >= ncpu)
            break;
        const machno = conf.nmach;
        mpstartap(c.apicid, machno);
        if (!@atomicLoad(bool, &online[machno], .seq_cst)) {
            print("mp: cpu with apic id %ud did not start\n", .{c.apicid});
            dat.machp[machno] = null;
            continue;
        }
        conf.nmach += 1;
    }

    // we don't really know the number of processors till here.
    // set conf.copymode here if nmach > 1.
    if (conf.nmach > 1)
        conf.copymode = 1;
}
