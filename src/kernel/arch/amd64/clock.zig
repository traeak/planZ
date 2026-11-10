//! Time: the fast clock, delays, and the clock interrupt.
//! from 9/pc/devarch.c (fastticks, delay) and 9/pc/archacpi.c (clock
//! selection)
//!
//! DIFF: the fast clock is always the time stamp counter, which the CPU
//! baseline requires to be invariant; its rate is measured against the
//! HPET.

const acpi = @import("../../plat/acpi.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const hpet = @import("hpet.zig");
const p9 = @import("../../port/print.zig");
const panic = p9.panic;

const m = dat.m;

/// Find a reference timer and measure the processor against it.
pub fn clockinit() void {
    const pa = acpi.hpet() orelse
        panic("no HPET: cannot measure the processor clock", .{});
    if (!hpet.hpetprobe(pa))
        panic("HPET at %#llux does not work", .{pa});
    hpet.hpetinit();
}

/// An application processor takes the bootstrap processor's measurement.
pub fn clockinitap() void {
    hpet.hpetinit();
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
