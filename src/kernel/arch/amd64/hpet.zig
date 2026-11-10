//! HPET timer
//!
//! The HPET timer is memory mapped which allows faster access compared
//! to the classic i8253.  This timer is not used to generate interrupts
//! as we use the LAPIC timer for that.  Its purpose is to measure the
//! LAPIC timer and TSC frequencies.
//! from 9/pc/hpet.c
//!
//! DIFF: delay() counts cycles of the time stamp counter, so the
//! delayloop calibration (loopconst, delaylcycles) is not measured.

const mem = @import("mem.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const mmu = @import("mmu.zig");
const taslock = @import("../../port/taslock.zig");
const print = @import("../../port/print.zig").print;

const m = dat.m;

// Registers, as indices of 32-bit words.
const Cap = 0x00 / 4;
const Period = 0x04 / 4;
const Config = 0x10 / 4;
const Isr = 0x20 / 4;
const Ctrlo = 0xF0 / 4;
const Ctrhi = 0xF4 / 4;

var hpet: struct {
    lock: taslock.Lock = .{},
    mmio: [*]volatile u32 = undefined,
    last: u64 = 0,
    freq: u64 = 0,
} = .{};

pub fn hpetprobe(pa: u64) bool {
    const va = mmu.vmap(pa, 1024) orelse return false;
    hpet.mmio = @ptrFromInt(va);
    const cap = hpet.mmio[Cap];
    const period = hpet.mmio[Period]; // femtoseconds per tick
    if (period == 0 or period > 0x05F4E100)
        return false;
    hpet.freq = 1000000000000000 / @as(u64, period);
    print("HPET: %llux %.8ux %d MHz \n", .{ pa, cap, (hpet.freq + 500000) / 1000000 });
    return true;
}

/// Count time stamp counter cycles over one clock tick of the HPET.
fn hpetcpufreq() u64 {
    taslock.ilock(&hpet.lock);
    defer taslock.iunlock(&hpet.lock);
    const want: u32 = @intCast(hpet.freq / mem.HZ);
    const a = l.cycles();
    const x = hpet.mmio[Ctrlo];
    var y: u32 = 0;
    while (y < want) y = hpet.mmio[Ctrlo] -% x;
    const b = l.cycles();
    return (b - a) * hpet.freq / y;
}

pub fn hpetinit() void {
    const mach = m();
    if (mach.machno != 0) {
        const m0 = dat.MACHP(0);
        mach.cpuhz = m0.cpuhz;
        mach.cpumhz = m0.cpumhz;
        mach.cyclefreq = m0.cyclefreq;
        return;
    }

    // start counting
    hpet.mmio[Config] |= 1;

    const cpufreq = hpetcpufreq();
    mach.cyclefreq = cpufreq;
    mach.cpuhz = cpufreq;
    // round to the nearest megahz
    mach.cpumhz = @intCast(@max(1, (cpufreq + 500000) / 1000000));
}

pub fn hpetread(hz: ?*u64) u64 {
    if (hz) |h| h.* = hpet.freq;
    taslock.ilock(&hpet.lock);
    defer taslock.iunlock(&hpet.lock);
    var ticks = hpet.last;
    ticks += hpet.mmio[Ctrlo] -% @as(u32, @truncate(ticks));
    hpet.last = ticks;
    return ticks;
}
