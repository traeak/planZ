//! Spin locks.
//! from 9/port/taslock.c
//!
//! DIFF: edf — the priority-inversion yield for real-time processes is
//! not here.  The LOCKCYCLES statistics are not kept.

const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const p9 = @import("print.zig");
const print = p9.print;

pub const Lock = portdat.Lock;

fn lockloop(l: *Lock, pc: usize) void {
    if (p9.panicking) return;

    const p = l.p;
    print("lock %#p loop key %#lux pc %#p held by pc %#p proc %lud\n", .{ l, l.key, pc, l.pc, if (p) |x| x.pid else 0 });
    proc.dumpaproc(arch.up());
    if (p != null)
        proc.dumpaproc(p);
}

fn acquired(l: *Lock, pc: usize) void {
    const up = arch.up();
    if (up) |p| p.lastlock = l;
    l.pc = pc;
    l.p = up;
    l.m = arch.m();
    l.isilock = false;
}

pub fn lock(l: *Lock) void {
    const pc = @returnAddress();
    const up = arch.up();

    if (up) |p| p.nlocks += 1; // prevent being scheded
    if (arch.tas(&l.key) == 0)
        return acquired(l, pc);
    if (up) |p| p.nlocks -= 1;

    while (true) {
        var i: u32 = 0;
        while (@atomicLoad(u32, &l.key, .monotonic) != 0) {
            // DIFF: edf — yield here on priority inversion.
            i += 1;
            if (i > 100000000) {
                i = 0;
                lockloop(l, pc);
            }
        }
        if (up) |p| p.nlocks += 1;
        if (arch.tas(&l.key) == 0)
            return acquired(l, pc);
        if (up) |p| p.nlocks -= 1;
    }
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
    const up = arch.up();
    if (up) |p| p.lastilock = l;
    l.sr = x;
    l.pc = pc;
    l.p = up;
    l.m = m;
    l.isilock = true;
}

pub fn canlock(l: *Lock) bool {
    const up = arch.up();
    if (up) |p| p.nlocks += 1;
    if (arch.tas(&l.key) != 0) {
        if (up) |p| p.nlocks -= 1;
        return false;
    }
    acquired(l, @returnAddress());
    return true;
}

pub fn unlock(l: *Lock) void {
    const up = arch.up();
    if (l.key == 0)
        print("unlock(%#p): not locked: pc %#p\n", .{ l, @returnAddress() });
    if (l.isilock)
        print("unlock(%#p) of ilock: pc %#p, held by %#p\n", .{ l, @returnAddress(), l.pc });
    if (l.p != up) {
        print("unlock(%#p): up changed: pc %#p, acquired at pc %#p, lock p %#p, unlock up %#p\n", .{ l, @returnAddress(), l.pc, l.p, up });
        proc.dumpaproc(l.p);
        proc.dumpaproc(up);
    }
    l.m = null;
    arch.coherence();
    @atomicStore(u32, &l.key, 0, .release);

    // Call sched if the need arose while locks were held
    // But, don't do it from interrupt routines, hence the islo() test
    if (up) |p| {
        p.nlocks -= 1;
        if (p.nlocks == 0 and p.state == .Running and p.delaysched != 0 and arch.islo())
            proc.sched();
    }
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
    if (arch.up()) |p| p.lastilock = null;
    arch.splx(sr);
}
