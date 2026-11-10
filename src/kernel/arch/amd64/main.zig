//! from 9/pc64/main.c

const std = @import("std");
const bootinfo = @import("bootinfo");
const acpi = @import("../../plat/acpi.zig");
const mem = @import("mem.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const bootargs = @import("bootargs.zig");
const cpu = @import("cpu.zig");
const memory = @import("memory.zig");
const mmu = @import("mmu.zig");
const trap = @import("trap.zig");
const apic = @import("apic.zig");
const clock = @import("clock.zig");
const alloc = @import("../../port/alloc.zig");
const xalloc = @import("../../port/xalloc.zig");
const p9 = @import("../../port/print.zig");
const screen = @import("../../port/screen.zig");
const Uart16550 = @import("../../drv/uart16550.zig").Uart16550;

const print = p9.print;
const panic = p9.panic;
const getconf = bootargs.getconf;
const BootInfo = bootinfo.BootInfo;
const m = dat.m;
const conf = &dat.conf;

/// Register access for a UART on the ISA I/O ports.
const PortIo = struct {
    base: u16,

    pub fn read(self: PortIo, reg: u3) u8 {
        return l.inb(self.base + reg);
    }

    pub fn write(self: PortIo, reg: u3, v: u8) void {
        l.outb(self.base + reg, v);
    }
};

const uart0: Uart16550(PortIo) = .{ .io = .{ .base = 0x3f8 } };

fn uartputs(s: []const u8) void {
    uart0.puts(s);
}

/// DIFF: the serial console is always on, at 115200 baud; the C waits
/// for console= in plan9.ini.
fn i8250console() void {
    uart0.init(115200);
    p9.addconsole(uartputs);
}

fn confinit() void {
    if (getconf("service")) |p| {
        if (std.mem.eql(u8, p, "cpu"))
            dat.cpuserver = true
        else if (std.mem.eql(u8, p, "terminal"))
            dat.cpuserver = false;
    }

    var userpcnt: usize = 0;
    if (getconf("*kernelpercent")) |p| {
        const k = std.fmt.parseInt(usize, p, 0) catch 0;
        userpcnt = 100 -| k;
    }

    conf.npage = 0;
    for (conf.mem) |cm| conf.npage += cm.npage;

    conf.nproc = @intCast(@min(4000, (100 + (conf.npage * mem.BY2PG / mem.MiB) * 5) * @as(usize, if (dat.cpuserver) 3 else 1)));
    conf.nimage = 200;
    conf.nswap = conf.nproc * 80;
    conf.nswppo = 4096;

    var kpages: usize = undefined;
    if (dat.cpuserver) {
        if (userpcnt < 10) userpcnt = 70;
        kpages = conf.npage - (conf.npage * userpcnt) / 100;
        conf.nimage = conf.nproc;
    } else {
        if (userpcnt < 10)
            userpcnt = if (conf.npage * mem.BY2PG < 16 * mem.MiB) 50 else 60;
        kpages = conf.npage - (conf.npage * userpcnt) / 100;
    }

    conf.upages = conf.npage - kpages;
    conf.ialloc = (kpages / 2) * mem.BY2PG;

    // DIFF: the C goes on to size the main and image pools; the
    // allocator here has no limits to set.
}

/// Initialise the Mach of the processor this runs on.
fn machinit() void {
    const mach = m();
    const machno = mach.machno;
    const pml4 = mach.pml4;
    const gdt = mach.gdt;
    mach.* = .{};
    mach.machno = machno;
    mach.pml4 = pml4;
    mach.gdt = gdt;
    mach.perf.period = 1;
}

fn mach0init() void {
    conf.nmach = 1;

    const mach: *dat.Mach = @ptrCast(&l.mach0);
    dat.machp[0] = mach;
    // From here m() works.
    mmu.gdtinit(0, &mmu.gdt0);

    mach.machno = 0;
    mach.pml4 = @ptrFromInt(mmu.kaddr(l.getcr3() & ~@as(u64, mem.BY2PG - 1)));
    mach.gdt = &mmu.gdt0;

    machinit();

    dat.active.machs[0] = true;
    dat.active.exiting = false;
}

/// Put the console on the framebuffer the firmware left us, if any.
/// DIFF: later than in the C, which draws on the VGA text screen from
/// the start; mapping the framebuffer needs the allocators.  What was
/// printed before this is replayed from the kernel message buffer.
fn screeninit() void {
    const fb = bootargs.bootinfop.framebuffer;
    if (fb.format == .none or fb.base == 0) return;
    const size = @as(usize, fb.stride) * fb.height * 4;
    const va = mmu.vmap(fb.base, size) orelse return;
    mmu.patwc(va, size);
    screen.screeninit(va, fb.width, fb.height, fb.stride);
}

/// Find the machine's description of itself.
fn archinit() void {
    acpi.kaddr = mmu.kaddr;
    if (!acpi.init(bootargs.bootinfop.acpi_rsdp))
        panic("no ACPI tables", .{});
}

pub fn main(bipa: u64) callconv(.c) noreturn {
    const bi: *const BootInfo = @ptrFromInt(mem.DMAP + bipa);
    bootargs.bootargsinit(bi);
    mach0init();
    trap.trapinit0();
    i8250console();
    print("\nPlan 9\n", .{});
    if (bi.magic != bootinfo.magic or bi.version != bootinfo.version)
        panic("boot information is not what this kernel expects", .{});
    cpu.cpuidentify();
    memory.meminit0(bi);
    archinit();
    clock.clockinit();
    memory.meminit();
    confinit();
    xalloc.xinit();
    screeninit();
    trap.trapinit();
    cpu.cpuidprint();
    mmu.mmuinit();
    apic.intrinit();
    apic.clockenable();

    // DIFF: this is as far as the kernel goes for now; procinit0,
    // chandevreset, pageinit, userinit and schedinit follow in later
    // milestones.
    selftest();
    l.idle();
}

/// Exercise what M1 built.  `*selftest=fault` in plan9.ini ends with a
/// deliberate kernel fault instead of a clean report.
fn selftest() void {
    print("%lludM memory: %lludM kernel data, %lludM user\n", .{
        conf.npage * mem.BY2PG / mem.MiB,
        (conf.npage - conf.upages) * mem.BY2PG / mem.MiB,
        conf.upages * mem.BY2PG / mem.MiB,
    });

    malloctest();

    _ = l.spllo();
    const t0 = m().ticks;
    const start = l.cycles();
    while (m().ticks -% t0 < mem.HZ / 4) {
        if (l.cycles() - start > 5 * m().cpuhz)
            panic("selftest: clock is not ticking", .{});
        l.halt();
    }
    const us = (l.cycles() - start) * 1000000 / m().cpuhz;
    print("selftest: %d ticks in %lludms\n", .{ mem.HZ / 4, us / 1000 });
    if (us < 200000 or us > 300000)
        panic("selftest: clock rate is wrong", .{});

    if (getconf("*selftest")) |t| {
        if (std.mem.eql(u8, t, "fault")) {
            print("selftest: faulting on purpose\n", .{});
            const p: *volatile u32 = @ptrFromInt(0x1234);
            p.* = 1;
        }
    }
    print("selftest ok\n", .{});
}

fn malloctest() void {
    const before = alloc.mallocstats().curalloc;
    var slots: [128]?[]u8 = @splat(null);
    var seed: u32 = 1;
    var rounds: usize = 0;
    while (rounds < 20000) : (rounds += 1) {
        seed = seed *% 1103515245 +% 12345;
        const i = (seed >> 16) % slots.len;
        if (slots[i]) |s| {
            for (s) |c| {
                if (c != @as(u8, @truncate(i)))
                    panic("selftest: malloc block %d damaged", .{i});
            }
            alloc.free(s.ptr);
            slots[i] = null;
            continue;
        }
        // Mostly small, now and then large.
        const n: usize = if (seed & 0xff == 0) 100000 + (seed >> 8) % 400000 else 1 + (seed >> 8) % 3000;
        const p = alloc.malloc(n) orelse panic("selftest: malloc(%lud) failed", .{n});
        for (p[0..n]) |c| {
            if (c != 0) panic("selftest: malloc memory not zeroed", .{});
        }
        @memset(p[0..n], @truncate(i));
        slots[i] = p[0..n];
    }
    for (slots) |s| {
        if (s) |b| alloc.free(b.ptr);
    }

    const a = alloc.mallocalign(3 * mem.BY2PG, mem.BY2PG, 0, 0) orelse panic("selftest: mallocalign failed", .{});
    if (@intFromPtr(a) % mem.BY2PG != 0) panic("selftest: mallocalign not aligned", .{});
    if (alloc.msize(a) < 3 * mem.BY2PG) panic("selftest: msize of aligned block", .{});
    alloc.free(a);

    var r = alloc.malloc(10).?;
    @memcpy(r[0..10], "0123456789");
    r = alloc.realloc(r, 5000).?;
    if (!std.mem.eql(u8, r[0..10], "0123456789")) panic("selftest: realloc lost data", .{});
    alloc.free(r);

    if (alloc.mallocstats().curalloc != before)
        panic("selftest: malloc leaked %lud bytes", .{alloc.mallocstats().curalloc - before});
    print("selftest: malloc ok, %lludK in the arena\n", .{alloc.mallocstats().cursize / mem.KiB});
}
