//! Spin locks.
//! from 9/port/taslock.c
//!
//! M1 has no scheduler, so lock() only spins; the priority handling and
//! the lock statistics arrive with proc.zig.

const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const print = @import("print.zig").print;

pub const Lock = portdat.Lock;

pub fn lock(l: *Lock) void {
    const pc = @returnAddress();
    while (arch.tas(&l.key) != 0) {
        while (@atomicLoad(u32, &l.key, .monotonic) != 0) {}
    }
    l.pc = pc;
    l.p = arch.up();
    l.m = arch.m();
    l.isilock = false;
}

pub fn canlock(l: *Lock) bool {
    if (arch.tas(&l.key) != 0) return false;
    l.pc = @returnAddress();
    l.p = arch.up();
    l.m = arch.m();
    l.isilock = false;
    return true;
}

pub fn unlock(l: *Lock) void {
    if (l.key == 0)
        print("unlock(%#p): not locked: pc %#p\n", .{ l, @returnAddress() });
    if (l.isilock)
        print("unlock(%#p) of ilock: pc %#p, held by %#p\n", .{ l, @returnAddress(), l.pc });
    l.m = null;
    arch.coherence();
    @atomicStore(u32, &l.key, 0, .release);
}

/// Lock with interrupts off; the lock an interrupt handler may take.
pub fn ilock(l: *Lock) void {
    const pc = @returnAddress();
    var x = arch.splhi();
    while (arch.tas(&l.key) != 0) {
        // Cannot also check l.pc, l.m, or l.isilock here because they
        // might just not be set yet, or (for pc and m) the lock might
        // have just been unlocked.
        arch.splx(x);
        while (@atomicLoad(u32, &l.key, .monotonic) != 0) {}
        x = arch.splhi();
    }
    const m = arch.m();
    m.ilockdepth += 1;
    l.sr = x;
    l.pc = pc;
    l.p = arch.up();
    l.m = m;
    l.isilock = true;
}

pub fn iunlock(l: *Lock) void {
    if (l.key == 0)
        print("iunlock(%#p): not locked: pc %#p\n", .{ l, @returnAddress() });
    if (!l.isilock)
        print("iunlock(%#p) of lock: pc %#p, held by %#p\n", .{ l, @returnAddress(), l.pc });
    if (arch.islo())
        print("iunlock(%#p) while lo: pc %#p, held by %#p\n", .{ l, @returnAddress(), l.pc });

    const sr = l.sr;
    l.m = null;
    arch.coherence();
    @atomicStore(u32, &l.key, 0, .release);
    arch.m().ilockdepth -= 1;
    arch.splx(sr);
}
