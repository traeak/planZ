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
const draw = @import("../../libdraw/draw.zig");
const proc = @import("../../port/proc.zig");
const portclock = @import("../../port/portclock.zig");
const alarm = @import("../../port/alarm.zig");
const selftest = @import("../../port/selftest.zig");
const devmod = @import("../../port/dev.zig");
const chan = @import("../../port/chan.zig");
const conf_pc64 = @import("../../conf/pc64.zig");
const devroot = @import("../../port/devroot.zig");
const devenv = @import("../../port/devenv.zig");
const page = @import("../../port/page.zig");
const userinit = @import("../../port/userinit.zig");
const syscallmod = @import("../../port/syscall.zig");
const portdat = @import("../../port/portdat.zig");
const fmt = @import("fmt");
const fpu = @import("fpu.zig");
const uartpc = @import("uartpc.zig");
const mp = @import("mp.zig");
const pcipc = @import("pcipc.zig");
const Uart16550 = @import("../../drv/uart16550.zig").Uart16550;

const print = p9.print;
const panic = p9.panic;
const progress = p9.progress;
const chandevreset = chan.chandevreset;
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
/// for console= in plan9.ini.  Always, that is, if the machine has a
/// COM1: see Uart16550.probe.
fn i8250console() void {
    if (!uart0.probe())
        return;
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
    var asked = false;
    if (getconf("*kernelpercent")) |p| {
        const k = std.fmt.parseInt(usize, p, 0) catch 0;
        userpcnt = 100 -| k;
        asked = userpcnt >= 10;
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

    // DIFF: the C stops the kernel's share at the size of its part of
    // the address space, 2GiB ("can't go past the end of virtual
    // memory").  The direct map has no such end, and without a limit
    // the kernel would keep 40% of a large machine's memory that it
    // cannot give back.  The limit here is 4GiB, unless
    // *kernelpercent asks for a share.
    if (!asked and kpages > 4 * mem.GiB / mem.BY2PG)
        kpages = 4 * mem.GiB / mem.BY2PG;

    conf.upages = conf.npage - kpages;
    conf.ialloc = (kpages / 2) * mem.BY2PG;

    // DIFF: the C goes on to size the main and image pools; the
    // allocator here has no limits to set.
}

/// Initialise the Mach of the processor this runs on.
pub fn machinit() void {
    const mach = m();
    const machno = mach.machno;
    const pml4 = mach.pml4;
    const gdt = mach.gdt;
    const apstate = mach.apstate;
    mach.* = .{};
    mach.machno = machno;
    mach.pml4 = pml4;
    mach.gdt = gdt;
    mach.apstate = apstate;
    mach.perf.period = 1;
}

fn mach0init() void {
    conf.nmach = 1;

    const mach: *dat.Mach = @ptrCast(&l.mach0);
    dat.percpu.machp[0] = mach;
    // From here m() works.
    mmu.gdtinit(0, &mmu.gdt0);

    mach.machno = 0;
    mach.pml4 = @ptrFromInt(mmu.kaddr(l.getcr3() & ~@as(u64, mem.BY2PG - 1)));
    mach.gdt = &mmu.gdt0;

    machinit();

    dat.active.machs[0] = true;
    dat.active.exiting = false;
}

/// A white block on the top line of the screen, the nth from the left.
/// DIFF: not in 9front, whose first prints are on the VGA text screen.
/// Here the console needs the allocators before it can draw, and the
/// machine may have no serial port: without these marks a kernel that
/// dies before screeninit looks the same as one that never started.
/// The loader maps the framebuffer for this (see boot/bootinfo.zig).
/// main sets them: 0 on entry, 1 once the processor is identified, 2
/// when the memory map is recorded, 3 with the allocator ready; then
/// the console paints over them.
fn bootmark(n: usize) void {
    const fb = bootargs.bootinfop.framebuffer;
    if (fb.base == 0 or fb.format == .none or fb.base + fb.size > bootinfo.dmap_span)
        return;
    const side = 32;
    const x0 = 8 + n * (side + 8);
    if (fb.stride < fb.width or x0 + side > fb.width or 8 + side > fb.height or
        @as(u64, fb.stride) * (8 + side) * 4 > fb.size)
        return;
    const p: [*]volatile u32 = @ptrFromInt(mem.DMAP + fb.base);
    for (8..8 + side) |y| {
        for (x0..x0 + side) |x|
            p[y * fb.stride + x] = 0x00FFFFFF;
    }
}

/// Put the console on the framebuffer the firmware left us, if any.
/// DIFF: later than in the C, which draws on the VGA text screen from
/// the start; mapping the framebuffer needs the allocators.  What was
/// printed before this is replayed from the kernel message buffer.
fn screeninit() void {
    // /dev/mousectl's machine-dependent commands (the PS/2 mouse).
    screen.archmousectl = &@import("mouse.zig").mousectl;

    const fb = bootargs.bootinfop.framebuffer;
    if (fb.base == 0) {
        print("screen: no framebuffer from the loader\n", .{});
        return;
    }
    // The pixel's bytes in memory, low address first, are named last
    // to first in a channel descriptor.
    const fbchan = switch (fb.format) {
        .bgrx8 => draw.XRGB32,
        .rgbx8 => draw.XBGR32,
        else => return,
    };
    const size = @as(usize, fb.stride) * fb.height * 4;
    const va = mmu.vmap(fb.base, size) orelse return;
    const wc = mmu.patwc(va, size);
    screen.screeninit(va, fb.width, fb.height, fb.stride, fbchan);
    print("screen: %udx%ud stride %ud %s at %#llux %s\n", .{
        fb.width,                                            fb.height, fb.stride,
        if (fb.format == .bgrx8) "x8r8g8b8" else "x8b8g8r8", fb.base,   if (wc) "write-combining" else "uncached (slow: no PAT)",
    });
}

/// The signatures of the ACPI tables, for the boot log.
var acpisigs: struct {
    buf: [256]u8 = undefined,
    n: usize = 0,
} = .{};

fn acpisig(sig: []const u8, _: usize) void {
    const a = &acpisigs;
    if (a.n + sig.len + 1 > a.buf.len) return;
    a.buf[a.n] = ' ';
    @memcpy(a.buf[a.n + 1 ..][0..sig.len], sig);
    a.n += sig.len + 1;
}

/// Find the machine's description of itself.
fn archinit() void {
    acpi.kaddr = mmu.kaddr;
    if (!acpi.init(bootargs.bootinfop.acpi_rsdp))
        panic("no ACPI tables (rsdp %#llux)", .{bootargs.bootinfop.acpi_rsdp});
    acpi.each(acpisig);
    print("acpi: rsdp %#llux %s:%s\n", .{ bootargs.bootinfop.acpi_rsdp, acpi.rootname(), acpisigs.buf[0..acpisigs.n] });
}

/// *bootpause=seconds in plan9.ini: stop for that long at the points
/// of start-up where the screen is worth a photograph.
/// DIFF: not in 9front.
fn bootpause(what: []const u8) void {
    const s = getconf("*bootpause") orelse return;
    const secs = std.fmt.parseInt(u32, s, 0) catch return;
    if (secs == 0) return;
    print("bootpause: %ud seconds %s\n", .{ secs, what });
    clock.delay(@as(u64, secs) * 1000);
}

/// Fill /boot.  The loader may have brought files (a 9front boot, paqfs,
/// factotum and bootfs.paq); without a boot program from there the
/// kernel's own user-mode self-test is /boot/boot.
/// Stands in for the bootdir section of a 9front kernel configuration
/// and the bootlinks() that mkrootc generates from it.
fn bootfiles() void {
    const bi = bootargs.bootinfop;
    var haveboot = false;
    if (bi.files_len != 0) {
        const files = @as([*]const bootinfo.BootFile, @ptrFromInt(mmu.kaddr(bi.files)))[0..bi.files_len];
        for (files) |*f| {
            const name = std.mem.sliceTo(&f.name, 0);
            const data = @as([*]const u8, @ptrFromInt(mmu.kaddr(f.base)))[0..f.len];
            devroot.addbootfile(name, data);
            if (std.mem.eql(u8, name, "boot")) haveboot = true;
        }
    }
    if (!haveboot)
        devroot.addbootfile("boot", @embedFile("bootprog"));

    // Given with -Dstock: an unmodified 9front binary for the user test
    // to run.
    const stockecho = @embedFile("stockecho");
    if (stockecho.len != 0)
        devroot.addbootfile("echo", stockecho);
}

/// The first process, still in the kernel: finish what needs a process
/// to do it, then leave for user mode and initcode.
fn init0() noreturn {
    chan.chandevinit();

    var buf: [64]u8 = undefined;
    devenv.ksetenv("terminal", fmt.snprint(&buf, "%s %s", .{ "generic", "pc64" }), false) catch {};
    devenv.ksetenv("cputype", "amd64", false) catch {};
    devenv.ksetenv("service", if (dat.cpuserver) "cpu" else "terminal", false) catch {};
    bootargs.setconfenv();
    proc.kproc("alarm", alarm.alarmkproc, null);

    // DIFF: not in 9front; see port/selftest.zig.  *selftest=off in
    // plan9.ini leaves it out: its checks of timing panic when they
    // fail, which a new machine may not deserve.
    if (!std.mem.eql(u8, getconf("*selftest") orelse "", "off"))
        proc.kproc("selftest", selftest.selftest, null);

    // The stack initcode starts with: no return address, argv[0] "boot".
    const sp: [*]usize = @ptrFromInt(mem.USTKTOP - @sizeOf(portdat.Tos) - 8 - @sizeOf(usize) * 4);
    sp[3] = 0;
    sp[2] = 0;
    sp[1] = @intFromPtr(&sp[4]);
    @as(*[5]u8, @ptrCast(&sp[4])).* = "boot\x00".*;
    sp[0] = 0;

    _ = l.splhi();
    l.touser(@intFromPtr(sp));
}

pub fn main(bipa: u64) callconv(.c) noreturn {
    const bi: *const BootInfo = @ptrFromInt(mem.DMAP + bipa);
    bootargs.bootargsinit(bi);
    mach0init();
    trap.trapinit0();
    bootmark(0);
    i8250console();
    print("\nPlan 9\n", .{});
    if (bi.magic != bootinfo.magic or bi.version != bootinfo.version)
        panic("boot information is not what this kernel expects", .{});
    cpu.cpuidentify();
    bootmark(1);
    // DIFF: memory, the allocator and then the screen come before
    // everything that can find the machine wanting (cpucheck, the ACPI
    // tables, the timers), so that the complaint can be read.
    memory.meminit0(bi);
    memory.meminit();
    bootmark(2);
    confinit();
    xalloc.xinit();
    bootmark(3);
    screeninit();
    cpu.cpucheck();
    archinit();
    clock.clockinit();
    trap.trapinit();
    cpu.cpuidprint();
    progress("mmu");
    mmu.mmuinit();
    progress("apic");
    apic.intrinit();
    progress("fpu");
    fpu.mathinit();
    progress("timers");
    portclock.timersinit();
    apic.clockenable();

    progress("proc");
    proc.procinit0();
    devmod.devtab = &conf_pc64.devtab;
    progress("uart");
    uartpc.uartinit();
    bootfiles();
    progress("pci");
    pcipc.pcicfginit();
    bootpause("after the machine's description");
    progress("links");
    conf_pc64.links();
    chandevreset();
    syscallmod.systabinit();
    progress("page");
    page.pageinit();
    page.pagerinit();
    progress("user");
    userinit.init0 = init0;
    userinit.userinit();
    progress("mp");
    mp.mpinit();
    bootpause("before the first process");
    progress("sched");
    proc.schedinit();
}
