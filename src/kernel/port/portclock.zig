//! Timers and the clock tick.
//! from 9/port/portclock.c
//!
//! Each processor keeps its timers sorted by when they are due and
//! programs its interrupt for the first one.  The HZ clock tick is one
//! of those timers.
//!
//! DIFF: hzclock leaves out what is not ported yet (flushmmu for a
//! process whose page tables changed, dtracy, kmap invalidation, the
//! profiler, the user-mode profiling clock, shutdown).

const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const tod = @import("tod.zig");
const alarm = @import("alarm.zig");
const p9 = @import("print.zig");

const panic = p9.panic;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const Timer = portdat.Timer;
const Timers = portdat.Timers;
const Ureg = arch.Ureg;
const HZ = arch.mem.HZ;
const MAXMACH = arch.mem.MAXMACH;

var timers: [MAXMACH]Timers = @splat(.{});

pub var intrcount: [MAXMACH]u32 = @splat(0);
pub var fcallcount: [MAXMACH]u32 = @splat(0);

pub fn MS2NS(ms: u32) i64 {
    return @as(i64, ms) * 1000000;
}

/// Called with tt locked.  Returns when the timer is due if it is now
/// the first on the queue, otherwise 0.
fn tadd(tt: *Timers, nt: *Timer) u64 {
    if (nt.tt != null) panic("tadd: timer already queued", .{});
    switch (nt.tmode) {
        portdat.Trelative => {
            if (nt.tns <= 0)
                nt.tns = 1;
            nt.twhen = arch.fastticks(null) + tod.ns2fastticks(@intCast(nt.tns));
        },
        portdat.Tperiodic => {
            if (nt.tns < 100000) panic("tadd: period too short", .{}); // At least 100 µs period
            if (nt.twhen == 0) {
                // look for another timer at same frequency for combining
                var t = tt.head;
                while (t) |x| : (t = x.tnext) {
                    if (x.tmode == portdat.Tperiodic and x.tns == nt.tns)
                        break;
                }
                nt.twhen = if (t) |x| x.twhen else arch.fastticks(null);
            }
            nt.twhen += tod.ns2fastticks(@intCast(nt.tns));
        },
        else => panic("timer", .{}),
    }

    var last: *?*Timer = &tt.head;
    while (last.*) |t| : (last = &t.tnext) {
        if (t.twhen > nt.twhen)
            break;
    }
    nt.tnext = last.*;
    last.* = nt;
    nt.tt = tt;
    if (last == &tt.head)
        return nt.twhen;
    return 0;
}

/// Called with dt's queue locked.  Returns when the new first timer is
/// due if dt was the first, otherwise 0.
fn tdel(dt: *Timer) u64 {
    const tt = dt.tt orelse return 0;

    var last: *?*Timer = &tt.head;
    while (last.*) |t| : (last = &t.tnext) {
        if (t == dt) {
            dt.tt = null;
            last.* = t.tnext;
            break;
        }
    }
    if (last == &tt.head) {
        if (tt.head) |h| return h.twhen;
    }
    return 0;
}

/// add or modify a timer
pub fn timeradd(nt: *Timer) void {
    // Must lock Timer struct before Timers struct
    ilock(&nt.lock);
    if (nt.tt) |tt| {
        ilock(&tt.lock);
        _ = tdel(nt);
        iunlock(&tt.lock);
    }
    const tt = &timers[@intCast(arch.m().machno)];
    ilock(&tt.lock);
    const when = tadd(tt, nt);
    if (when != 0)
        arch.timerset(when);
    iunlock(&tt.lock);
    iunlock(&nt.lock);
}

pub fn timerdel(dt: *Timer) void {
    // avoid Tperiodic getting re-added
    dt.tmode = portdat.Trelative;

    ilock(&dt.lock);
    if (dt.tt) |tt| {
        ilock(&tt.lock);
        const when = tdel(dt);
        if (when != 0 and tt == &timers[@intCast(arch.m().machno)])
            arch.timerset(tt.head.?.twhen);
        iunlock(&tt.lock);
    }
    const mp = dt.tactive;
    if (mp == null or mp.?.machno == arch.m().machno) {
        iunlock(&dt.lock);
        return;
    }
    iunlock(&dt.lock);

    // rare, but tf can still be active on another cpu
    while (@atomicLoad(?*arch.Mach, &dt.tactive, .seq_cst) == mp and dt.tt == null) {
        if (arch.up()) |up| {
            if (up.state == .Running and up.nlocks == 0 and arch.islo())
                proc.sched();
        }
    }
}

fn hzclock(ur: *Ureg) void {
    const mach = arch.m();
    mach.ticks +%= 1;
    if (mach.proc) |p|
        p.pc = ur.pc;

    proc.accounttime();

    if (!arch.active.machs[@intCast(mach.machno)])
        return;

    if (mach.machno == 0)
        alarm.checkalarms();

    if (arch.up()) |up| {
        if (up.state == .Running)
            proc.hzsched(); // in proc.c
    }
}

/// The processor's timer interrupt: run the timers that are due.
pub fn timerintr(u: *Ureg, _: u64) void {
    const machno: usize = @intCast(arch.m().machno);
    intrcount[machno] +%= 1;
    var callhzclock = false;
    const tt = &timers[machno];
    const now = arch.fastticks(null);
    ilock(&tt.lock);
    while (tt.head) |t| {
        // No need to ilock t here: any manipulation of t
        // requires tdel(t) and this must be done with a
        // lock to tt held.  We have tt, so the tdel will
        // wait until we're done
        const when = t.twhen;
        if (when > now) {
            arch.timerset(when);
            iunlock(&tt.lock);
            if (callhzclock)
                hzclock(u);
            return;
        }
        tt.head = t.tnext;
        if (t.tt != tt) panic("timerintr: timer on the wrong queue", .{});
        t.tt = null;
        t.tactive = arch.m();
        fcallcount[machno] +%= 1;
        iunlock(&tt.lock);
        if (t.tf) |f| f(u, t) else callhzclock = true;
        @atomicStore(?*arch.Mach, &t.tactive, null, .seq_cst);
        ilock(&tt.lock);
        if (t.tmode == portdat.Tperiodic)
            _ = tadd(tt, t);
    }
    iunlock(&tt.lock);
}

fn newtimer(what: []const u8) *Timer {
    const t: *Timer = @ptrCast(@alignCast(alloc.malloc(@sizeOf(Timer)) orelse
        panic("%s: no memory for Timer", .{what})));
    t.* = .{};
    return t;
}

/// Start this processor's HZ clock.
pub fn timersinit() void {
    // T.tf == nil means the HZ clock for this processor.
    tod.todinit();
    const t = newtimer("timersinit");
    t.tmode = portdat.Tperiodic;
    t.tns = 1000000000 / HZ;
    t.tf = null;
    timeradd(t);
}

fn clock0tramp(_: ?*Ureg, t: *Timer) void {
    const f: *const fn () void = @ptrCast(@alignCast(t.ta.?));
    f();
}

/// Call f every `ms` milliseconds on processor 0, at interrupt level.
pub fn addclock0link(f: *const fn () void, ms_: u32) *Timer {
    // Synchronize to hztimer if ms is 0
    const nt = newtimer("addclock0link");
    const ms = if (ms_ == 0) 1000 / HZ else ms_;
    nt.tns = @as(i64, ms) * 1000000;
    nt.tmode = portdat.Tperiodic;
    nt.tf = clock0tramp;
    nt.ta = @ptrCast(@constCast(f));

    ilock(&timers[0].lock);
    const when = tadd(&timers[0], nt);
    if (when != 0)
        arch.timerset(when);
    iunlock(&timers[0].lock);
    return nt;
}

/// This tk2ms avoids overflows that the macro version is prone to.
/// It is a LOT slower so shouldn't be used if you're just converting
/// a delta.
pub fn tk2ms(ticks: u32) u32 {
    return @truncate(@as(u64, ticks) * 1000 / HZ);
}

pub fn ms2tk(ms: u32) u32 {
    // avoid overflows at the cost of precision
    if (ms >= 1000000000 / HZ)
        return (ms / 1000) * HZ;
    return (ms * HZ + 500) / 1000;
}
