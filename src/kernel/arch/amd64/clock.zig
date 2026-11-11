//! Time: the fast clock, delays, and the clock interrupt.
//! from 9/pc/devarch.c (fastticks, delay) and 9/pc/archacpi.c (clock
//! selection)
//!
//! DIFF: the fast clock is always the time stamp counter, which the CPU
//! baseline requires to be invariant; its rate is measured against the
//! HPET, or against the ACPI power management timer on a machine whose
//! firmware has no HPET or has switched it off (the C falls back to the
//! i8253, which is not used here).

const acpi = @import("../../plat/acpi.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const hpet = @import("hpet.zig");
const mem = @import("mem.zig");
const bootargs = @import("bootargs.zig");
const p9 = @import("../../port/print.zig");
const print = p9.print;
const panic = p9.panic;

const m = dat.m;

/// The ACPI power management timer: 3.579545MHz, 24 or 32 bits.
const PmHz = 3579545;
var pmport: u16 = 0;
var pmmask: u32 = 0;

fn pmread() u32 {
    return l.inl(pmport) & pmmask;
}

fn pmprobe(t: acpi.Pmtimer) bool {
    if (t.port == 0 or t.port > 0xFFFC)
        return false;
    pmport = @intCast(t.port);
    pmmask = if (t.wide) 0xFFFFFFFF else 0x00FFFFFF;
    print("ACPI timer: port %#ux %d bits\n", .{ t.port, @as(u32, if (t.wide) 32 else 24) });
    // Nothing behind the port reads as all ones or as a constant.
    const x = pmread();
    var i: usize = 0;
    while (pmread() == x) : (i += 1) {
        if (i > 100000) {
            print("ACPI timer: counter does not advance\n", .{});
            return false;
        }
    }
    return true;
}

/// Count time stamp counter cycles over one clock tick of the ACPI
/// timer; 0 if it stops counting.
fn pmcpufreq() u64 {
    const s = l.splhi();
    defer l.splx(s);
    const want: u32 = PmHz / mem.HZ;
    const a = l.cycles();
    const x = pmread();
    var y: u32 = 0;
    while (y < want) {
        y = (pmread() -% x) & pmmask;
        if (l.cycles() -% a > 1 << 34) return 0;
    }
    const b = l.cycles();
    return (b - a) * PmHz / y;
}

/// Measure until two results in a row agree to one part in a thousand.
/// One measurement is spoiled if the firmware's system management
/// interrupt (it emulates a PS/2 keyboard from a USB one, among other
/// things) lands between the reading of the two counters.
fn measure(f: *const fn () u64) u64 {
    var last: u64 = 0;
    for (0..8) |_| {
        const hz = f();
        if (hz == 0) return 0;
        const d = if (hz > last) hz - last else last - hz;
        if (d < hz / 1000) return hz;
        last = hz;
    }
    return last;
}

fn plausible(hz: u64) bool {
    return hz >= 100_000_000 and hz <= 20_000_000_000;
}

/// Find a reference timer and measure the processor against it.
pub fn clockinit() void {
    const mach = m();
    var cpufreq: u64 = 0;
    var by: []const u8 = "";

    // *nohpet= is for trying the other timer.
    if (bootargs.getconf("*nohpet") == null) {
        if (acpi.hpet()) |pa| {
            if (hpet.hpetprobe(pa)) {
                cpufreq = measure(hpet.hpetcpufreq);
                by = "HPET";
                if (!plausible(cpufreq)) {
                    print("HPET: implausible processor clock %llud Hz\n", .{cpufreq});
                    cpufreq = 0;
                }
            } else print("HPET at %#llux does not work\n", .{pa});
        } else print("no HPET\n", .{});
    }
    if (cpufreq == 0) {
        if (acpi.pmtimer()) |t| {
            if (pmprobe(t)) {
                cpufreq = measure(pmcpufreq);
                by = "ACPI timer";
                if (!plausible(cpufreq)) {
                    print("ACPI timer: implausible processor clock %llud Hz\n", .{cpufreq});
                    cpufreq = 0;
                }
            }
        } else print("no ACPI timer\n", .{});
    }
    if (cpufreq == 0)
        panic("no working HPET or ACPI timer: cannot measure the processor clock", .{});

    mach.cyclefreq = cpufreq;
    mach.cpuhz = cpufreq;
    // round to the nearest megahz
    mach.cpumhz = @intCast(@max(1, (cpufreq + 500000) / 1000000));
    print("cpu0: tsc %llud Hz by %s\n", .{ cpufreq, by });
}

/// An application processor takes the bootstrap processor's measurement.
pub fn clockinitap() void {
    const mach = m();
    const m0 = dat.MACHP(0);
    mach.cpuhz = m0.cpuhz;
    mach.cpumhz = m0.cpumhz;
    mach.cyclefreq = m0.cyclefreq;
}

/// Cycles since boot, and optionally how many there are per second.
pub fn fastticks(hz: ?*u64) u64 {
    if (hz) |h| h.* = m().cpuhz;
    return l.cycles();
}

/// Busy wait.  Before the clock has been measured this assumes a fast
/// processor, which only makes the wait longer than asked.
pub fn microdelay(us: u64) void {
    const hz = if (m().cpuhz != 0) m().cpuhz else 4_000_000_000;
    const end = l.cycles() + us * hz / 1000000;
    while (l.cycles() < end) asm volatile ("pause");
}

pub fn delay(ms: u64) void {
    microdelay(ms * 1000);
}
