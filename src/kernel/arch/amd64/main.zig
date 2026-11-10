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
const xalloc = @import("../../port/xalloc.zig");
const p9 = @import("../../port/print.zig");
const screen = @import("../../port/screen.zig");
const proc = @import("../../port/proc.zig");
const portclock = @import("../../port/portclock.zig");
const alarm = @import("../../port/alarm.zig");
const selftest = @import("../../port/selftest.zig");
const devmod = @import("../../port/dev.zig");
const chan = @import("../../port/chan.zig");
const conf_pc64 = @import("../../conf/pc64.zig");
const fpu = @import("fpu.zig");
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
    fpu.mathinit();
    portclock.timersinit();
    apic.clockenable();

    proc.procinit0();
    devmod.devtab = &conf_pc64.devtab;
    chan.chandevreset();

    // DIFF: this is as far as the kernel goes for now; pageinit and
    // userinit follow in later milestones.  In their place
    // the first processes are the alarm process, which userinit's init0
    // starts in the C, and the self-test.
    proc.kproc("alarm", alarm.alarmkproc, null);
    proc.kproc("selftest", selftest.selftest, null);
    proc.schedinit();
}
