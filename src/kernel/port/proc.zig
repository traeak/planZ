//! Processes and the scheduler.
//! from 9/port/proc.c
//!
//! DIFF, structural:
//!   - Context switch.  The C saves and resumes contexts with
//!     setlabel/gotolabel, which return twice.  Zig cannot express that
//!     safely, so there is one primitive, arch.swtch(from, to), that
//!     returns once, later, in the context it was called from.  sched()
//!     is therefore split: the half that runs in a process switches to
//!     the scheduler; the half that picks the next process is the loop
//!     in schedinit(), which runs on the processor's own stack.
//!   - `up` is not a register.  Code that the C runs with `up` still set
//!     after m->proc was cleared (schedinit) passes that fact explicitly.
//!     Nothing may hold arch.m() across a switch: a process can resume
//!     on another processor.
//!   - Errors are Zig error returns; sleep and friends return
//!     error.Eintr where the C calls error(Eintr).
//!   - edf: the real-time scheduler is not ported.  Every place it hooks
//!     in is marked `DIFF: edf`.
//!   - proctrace (the scheduler event trace) is not ported.
//!
//! Not here yet because what they touch does not exist: the namespace
//! and file groups in pexit and kproc (M3), segments, popnote and
//! rendezvous (M4), procflushmmu (M4).

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const xalloc = @import("xalloc.zig");
const portclock = @import("portclock.zig");
const errmod = @import("error.zig");
const fmt = @import("fmt");
const p9 = @import("print.zig");

const print = p9.print;
const iprint = p9.iprint;
const panic = p9.panic;
const lock = taslock.lock;
const unlock = taslock.unlock;
const canlock = taslock.canlock;
const mem = arch.mem;

pub const Error = errmod.Error;
pub const Proc = portdat.Proc;
const Rendez = portdat.Rendez;
const Schedq = portdat.Schedq;
const Note = portdat.Note;
const Waitq = portdat.Waitq;
const Timer = portdat.Timer;
const Ureg = arch.Ureg;
const HZ = mem.HZ;
const Nrq = portdat.Nrq;
const Npriq = portdat.Npriq;

const Scaling = 2;

pub var schedgain: u32 = 30; // units in seconds
pub var nrdy: i32 = 0;

pub var delayedscheds: u32 = 0; // statistics
pub var skipscheds: u32 = 0;
pub var preempts: u32 = 0;
var load: u32 = 0;

var procalloc: struct {
    lock: taslock.Lock = .{},
    tab: [*]?*Proc = undefined,
    free: ?*Proc = null,
    nextindex: u32 = 0,
} = .{};

var runq: [Nrq]Schedq = @splat(.{});
var runvec: u32 = 0;

/// The owner of the machine; set when the first user logs in.
pub var eve: []const u8 = "";

pub fn statename(s: portdat.State) []const u8 {
    return switch (s) {
        .Dead => "Dead",
        .Moribund => "Moribund",
        .New => "New",
        .Ready => "Ready",
        .Scheding => "Scheding",
        .Running => "Running",
        .Queueing => "Queueing",
        .QueueingR => "QueueingR",
        .QueueingW => "QueueingW",
        .Wakeme => "Wakeme",
        .Broken => "Broken",
        .Stopped => "Stopped",
        .Rendezvous => "Rendez",
        .Waitrelease => "Waitrelease",
    };
}

/// The current process, where there must be one.
fn cur() *Proc {
    return arch.up() orelse panic("no current process, pc %#p", .{@returnAddress()});
}

/// The scheduler.  Each processor ends its start-up here and never
/// returns; processes switch back into this loop when they give up the
/// processor.
/// Always splhi()'ed.
pub fn schedinit() noreturn {
    while (true) {
        const mach = arch.m();
        if (mach.proc) |p| {
            // DIFF: edf — edfrecord(up) for an admitted process.
            mach.proc = null;
            switch (p.state) {
                .Running => {
                    p.state = .Scheding;
                    ready0(p, true);
                    arch.coherence();
                    p.mach = null;
                },
                .Moribund => {
                    arch.mmurelease(p);
                    lock(&procalloc.lock);
                    p.state = .Dead;
                    p.mach = null;
                    p.qnext = procalloc.free;
                    procalloc.free = p;
                    // proc is free now
                    unlock(&procalloc.lock);
                },
                else => {
                    updatecpu(p, true);
                    arch.coherence();
                    p.mach = null;
                },
            }
        }

        // The half of the C sched() that runs with no process.
        const p = runproc();
        if (p != mach.readied)
            mach.schedticks = mach.ticks +% HZ / 10;
        mach.readied = null;
        mach.proc = p;
        p.mach = mach;
        p.affinity = mach.machno;
        p.state = .Running;
        if (p.newtlb) {
            mach.tlbflush +%= 1;
            p.tlbflush +%= 1;
            p.newtlb = false;
            arch.mmuswitch(p, true);
        } else {
            arch.mmuswitch(p, false);
        }
        arch.swtch(&mach.sched, &p.sched);
    }
}

/// Entering the kernel through a trap.  Returns whether it came from
/// user mode.
pub fn kenter(ureg: *Ureg) bool {
    const user = arch.userureg(ureg);
    if (user) {
        const p = cur();
        p.dbgreg = ureg;
        p.kentry = arch.cycles();
    } else {
        // stack grows down
        const base = if (arch.up()) |p| @intFromPtr(p) - mem.KSTACK else @intFromPtr(arch.m()) + @sizeOf(arch.Mach);
        const rem = @as(isize, @bitCast(@intFromPtr(ureg) -% base));
        if (rem < 256)
            panic("kenter: %d stack bytes left, up %#p ureg %#p at pc %#p", .{ rem, arch.up(), ureg, ureg.pc });
    }
    return user;
}

fn procswitch() void {
    const p = cur();

    // statistics
    arch.m().cs +%= 1;

    var t = arch.cycles();
    p.kentry -%= t;
    p.pcycles +%= @bitCast(t);
    arch.procsave(p);

    arch.swtch(&p.sched, &arch.m().sched);

    arch.procrestore(p);
    t = arch.cycles();
    p.kentry +%= t;
    p.pcycles -%= @bitCast(t);
}

/// Give up the processor.  The caller has already changed up.state if it
/// is going to wait for something; otherwise the process stays runnable.
pub fn sched() void {
    const mach = arch.m();
    if (mach.ilockdepth != 0) {
        const il = if (arch.up()) |p| p.lastilock else null;
        panic("cpu%d: ilockdepth %d, last lock %#p at %#p", .{
            mach.machno,
            mach.ilockdepth,
            il,
            if (il) |x| x.pc else 0,
        });
    }
    const p = mach.proc orelse panic("sched: no process, pc %#p", .{@returnAddress()});

    // Delay the sched until the process gives up the locks
    // it is holding.  This avoids dumb lock loops.
    // But do sched eventually.  This avoids a missing unlock
    // from hanging the entire kernel.
    // But don't reschedule procs holding palloc or procalloc.
    // Those are far too important to be holding while asleep.
    //
    // This test is not exact.  There can still be a few instructions
    // in the middle of taslock when a process holds a lock
    // but Lock.p has not yet been initialized.
    if (p.nlocks != 0 and p.state == .Running) {
        // M4: also palloc.Lock.p == up
        if (p.delaysched < 20 or procalloc.lock.p == p) {
            p.delaysched += 1;
            delayedscheds +%= 1;
            return;
        }
    }

    const s = arch.splhi();
    p.delaysched = 0;
    procswitch();
    arch.splx(s);
}

pub fn anyready() bool {
    return runvec != 0;
}

pub fn anyhigher() bool {
    const pri: u5 = @intCast(cur().priority + 1);
    return runvec & ~((@as(u32, 1) << pri) - 1) != 0;
}

/// here once per clock tick to see if we should resched
pub fn hzsched() void {
    const mach = arch.m();
    const p = cur();

    // once a second, rebalance will reprioritize ready procs
    if (mach.machno == 0)
        rebalance();

    // unless preempted, get to run for at least 100ms
    if (anyhigher() or (!p.fixedpri and @as(i32, @bitCast(mach.ticks -% mach.schedticks)) > 0 and anyready())) {
        mach.readied = null; // avoid cooperative scheduling
        p.delaysched += 1;
    }
}

/// here at the end of interrupts to see if we should preempt the
/// current process.
pub fn preempted(clockintr: bool) void {
    const p = arch.up() orelse return;
    if (p.state != .Running or arch.active.exiting)
        return;
    if (!clockintr) {
        if (!anyhigher())
            return;
        arch.m().readied = null; // avoid cooperative scheduling
        sched();
    } else if (p.delaysched != 0)
        sched(); // quantum ended or we held a lock
}

/// Update the cpu time average for this particular process,
/// which is about to change from up -> not up or vice versa.
/// p.lastupdate is the last time an updatecpu happened.
///
/// The cpu time average is a decaying average that lasts
/// about D clock ticks.  D is chosen to be approximately
/// the cpu time of a cpu-intensive "quick job".  A job has to run
/// for approximately D clock ticks before we home in on its
/// actual cpu usage.  Thus if you manage to get in and get out
/// quickly, you won't be penalized during your burst.  Once you
/// start using your share of the cpu for more than about D
/// clock ticks though, your p.cpu hits 1000 (1.0) and you end up
/// below all the other quick jobs.  Interactive tasks, because
/// they basically always use less than their fair share of cpu,
/// will be rewarded.
///
/// If the process has not been running, then we want to
/// apply the filter
///
///    cpu = cpu * (D-1)/D
///
/// n times, yielding
///
///    cpu = cpu * ((D-1)/D)^n
///
/// but D is big enough that this is approximately
///
///    cpu = cpu * (D-n)/D
///
/// so we use that instead.
///
/// If the process has been running, we apply the filter to
/// 1 - cpu, yielding a similar equation.  Note that cpu is
/// stored in fixed point (* 1000).
///
/// Updatecpu must be called before changing up, in order
/// to maintain accurate cpu usage statistics.  It can be called
/// at any time to bring the stats for a given proc up-to-date.
///
/// DIFF: `running` is the C's test p == up, which here cannot be made
/// once m.proc has been cleared.
fn updatecpu(p: *Proc, running: bool) void {
    // DIFF: edf — real-time processes are not averaged.
    const t = arch.MACHP(0).ticks *% Scaling +% Scaling / 2;
    var n = t -% p.lastupdate;
    if (n == 0)
        return;
    p.lastupdate = t;

    const D: u32 = schedgain * HZ * Scaling;
    if (n > D)
        n = D;

    const ocpu = p.cpu;
    if (!running)
        p.cpu = (ocpu * (D - n)) / D
    else {
        const u = ((1000 - ocpu) * (D - n)) / D;
        p.cpu = 1000 - u;
    }
}

/// On average, p has used p.cpu of a cpu recently.
/// Its fair share is conf.nmach/m.load of a cpu.  If it has been getting
/// too much, penalize it.  If it has been getting not enough, reward it.
/// I don't think you can get much more than your fair share that
/// often, so most of the queues are for using less.  Having a priority
/// of 3 means you're just right.  Having a higher priority (up to p.basepri)
/// means you're not using as much as you could.
fn reprioritize(p: *Proc, running: bool) u32 {
    updatecpu(p, running);
    if (p.fixedpri)
        return p.basepri;

    const ld: u32 = @intCast(arch.MACHP(0).load);
    if (ld == 0)
        return p.basepri;

    // fairshare = 1.000 * conf.nmach * 1.000/load,
    // except the decimal point is moved three places
    // on both load and fairshare.
    const fairshare = (arch.conf.nmach * 1000 * 1000) / ld;
    const n = @max(p.cpu, 1);
    return @min((fairshare + n / 2) / n, p.basepri);
}

/// add a process to a scheduling queue
fn queueproc(pri: u32, p: *Proc) bool {
    const rq = &runq[pri];
    lock(&runq[0].lock);
    switch (p.state) {
        .New, .Queueing, .QueueingR, .QueueingW, .Wakeme, .Broken, .Stopped, .Rendezvous => {
            if (p == arch.up()) {
                // wet floor
                unlock(&runq[0].lock);
                return false;
            }
        },
        .Dead, .Moribund, .Ready, .Running, .Waitrelease => {
            unlock(&runq[0].lock);
            return false;
        },
        .Scheding => {},
    }
    p.state = .Ready;

    // When the priority is very low (process is using
    // more than its fair share) or when it has changed,
    // reset processor affinity.
    //
    // Long running processes would otherwise be stuck
    // on the same cpu preventing sharing the load.
    // When the priority changes, we want to give
    // every cpu a chance to pick up the load.
    if (!p.wired and (pri < 3 or pri != p.priority))
        p.affinity = -1;

    p.priority = pri;
    // DIFF: edf — the PriEdf queue is kept in deadline order.
    p.rnext = null;
    if (rq.tail) |t| t.rnext = p else rq.head = p;
    rq.tail = p;
    rq.n += 1;
    nrdy += 1;
    runvec |= @as(u32, 1) << @intCast(pri);
    unlock(&runq[0].lock);
    return true;
}

/// ready(p) picks a new priority for a process and sticks it in the
/// runq for that priority.
pub fn ready(p: *Proc) void {
    ready0(p, p == arch.up());
}

/// `isup`: p is the process this processor is running or has just
/// stopped running.
fn ready0(p: *Proc, isup: bool) void {
    const s = arch.splhi();
    // DIFF: edf — edfready(p) decides whether p is a real-time process.
    const mach = arch.m();
    if (!isup and (!p.wired or p.affinity == mach.machno))
        mach.readied = p; // group scheduling
    const pri = reprioritize(p, isup);
    if (!queueproc(pri, p))
        iprint("ready %s %lud %s pc %p\n", .{ p.text, p.pid, statename(p.state), @returnAddress() });
    arch.splx(s);
}

/// try to remove a process from a scheduling queue (called splhi)
fn dequeueproc(rq: *Schedq, tp: *Proc) ?*Proc {
    if (!canlock(&runq[0].lock))
        return null;

    // the queue may have changed before we locked runq,
    // refind the target process.
    var l: ?*Proc = null;
    var it = rq.head;
    while (it) |x| : (it = x.rnext) {
        if (x == tp) break;
        l = x;
    }

    // p.mach==0 only when process state is saved
    const p = it orelse {
        unlock(&runq[0].lock);
        return null;
    };
    if (p.mach != null) {
        unlock(&runq[0].lock);
        return null;
    }
    if (p.rnext == null)
        rq.tail = l;
    if (l) |x| x.rnext = p.rnext else rq.head = p.rnext;
    if (rq.head == null) {
        const pri = (@intFromPtr(rq) - @intFromPtr(&runq)) / @sizeOf(Schedq);
        runvec &= ~(@as(u32, 1) << @intCast(pri));
    }
    rq.n -= 1;
    nrdy -= 1;
    var res: ?*Proc = p;
    if (p.state != .Ready) {
        iprint("dequeueproc %s %lud %s pc %p\n", .{ p.text, p.pid, statename(p.state), @returnAddress() });
        res = null;
    }

    unlock(&runq[0].lock);
    return res;
}

/// yield the processor and drop our priority
pub fn yield() void {
    if (anyready()) {
        // pretend we just used 1/2 tick
        cur().lastupdate -%= Scaling / 2;
        sched();
    }
}

var rebalance_lasttime: u32 = 0;

/// recalculate priorities once a second.  We need to do this
/// since priorities will otherwise only be recalculated when
/// the running process blocks.
fn rebalance() void {
    const t = arch.m().ticks;
    if (t -% rebalance_lasttime < HZ)
        return;
    rebalance_lasttime = t;

    if (arch.islo()) panic("rebalance: islo", .{});
    var pri: u32 = 0;
    while (pri < Npriq) : (pri += 1) {
        const rq = &runq[pri];
        while (true) {
            const head = rq.head orelse break;
            if (pri == head.basepri) break;
            const npri = reprioritize(head, false);
            if (npri == pri) break;
            const p = dequeueproc(rq, head) orelse break;
            p.state = .Scheding;
            if (!queueproc(npri, p))
                iprint("rebalance: queueproc %lud %s %s\n", .{ p.pid, p.text, statename(p.state) });
        }
    }
}

/// pick a process to run
fn runproc() *Proc {
    const mach = arch.m();
    var start = arch.perfticks();

    // cooperative scheduling until the clock ticks
    if (mach.readied) |p| {
        if (p.mach == null and p.state == .Ready and
            (!p.wired or p.affinity == mach.machno) and
            runq[Nrq - 1].head == null and runq[Nrq - 2].head == null)
        {
            skipscheds +%= 1;
            if (dequeueproc(&runq[p.priority], p)) |x| {
                x.priority = reprioritize(x, false);
                return x;
            }
        }
    }

    preempts +%= 1;

    while (true) {
        // find a process that last ran on this processor (affinity),
        // or one that can be moved to this processor.
        _ = arch.spllo();
        var found: ?*Proc = null;
        var frq: *Schedq = undefined;
        var i: usize = 0;
        search: while (true) : (i += 1) {
            // find the highest priority target process that this
            // processor can run given affinity constraints.
            var q: usize = Nrq;
            while (q > 0) {
                q -= 1;
                const rq = &runq[q];
                var it = rq.head;
                while (it) |p| : (it = p.rnext) {
                    if (p.affinity < 0 or p.affinity == mach.machno or (!p.wired and i > 0)) {
                        found = p;
                        frq = rq;
                        break :search;
                    }
                }
            }

            // waste time or halt the CPU
            arch.idlehands(&nrdy);

            // remember how much time we're here
            const now = arch.perfticks();
            mach.perf.inidle +%= now -% start;
            start = now;
        }

        _ = arch.splhi();
        const p = dequeueproc(frq, found.?) orelse continue;
        // DIFF: edf — edfrun(p) starts the deadline timer here.
        p.priority = reprioritize(p, false);
        return p;
    }
}

pub fn canpage(p: *Proc) bool {
    var ok = false;
    _ = arch.splhi();
    lock(&runq[0].lock);
    // Only reliable way to see if we are Running
    if (p.mach == null) {
        p.newtlb = true;
        ok = true;
    }
    unlock(&runq[0].lock);
    _ = arch.spllo();
    return ok;
}

comptime {
    // A Proc sits at the top of its kernel stack, whose base comes from
    // malloc.
    if (@alignOf(Proc) > 16 or mem.KSTACK % 16 != 0) @compileError("Proc alignment");
}

pub fn newproc() ?*Proc {
    lock(&procalloc.lock);
    var p: *Proc = undefined;
    if (procalloc.free) |f| {
        p = f;
    } else {
        if (procalloc.nextindex >= arch.conf.nproc) {
            unlock(&procalloc.lock);
            return null;
        }
        const b = alloc.malloc(mem.KSTACK + @sizeOf(Proc)) orelse {
            unlock(&procalloc.lock);
            return null;
        };
        p = @ptrCast(@alignCast(b + mem.KSTACK));
        p.* = .{};
        p.index = procalloc.nextindex;
        procalloc.nextindex += 1;
        procalloc.tab[p.index] = p;
        procalloc.free = p; // unlinked just below, like one from the list
    }
    if (p.state != .Dead) panic("newproc: %s", .{statename(p.state)});
    procalloc.free = p.qnext;
    p.qnext = null;
    unlock(&procalloc.lock);

    p.psstate = null;
    p.state = .New;
    arch.procnew(p);
    p.procctl = 0;
    p.noteureg = null;
    p.dbgreg = null;
    p.errstr = &p.errbuf0;
    p.syserrstr = &p.errbuf1;
    p.errbuf0[0] = 0;
    p.errbuf1[0] = 0;
    p.lastlock = null;
    p.lastilock = null;
    p.nlocks = 0;
    p.trace = false;
    p.delaysched = 0;
    p.newtlb = false;
    p.tlbflush = 0;

    // sched params
    p.wired = false;
    p.affinity = -1;
    procpriority(p, portdat.PriNormal, false);
    p.cpu = 0;
    p.lastupdate = arch.MACHP(0).ticks *% Scaling;
    // DIFF: edf — p.edf = nil

    return p;
}

/// wire this proc to a machine
pub fn procwired(p: *Proc, a_: i32) void {
    var a = a_;
    const nmach: i32 = @intCast(arch.conf.nmach);
    if (a < 0) {
        // pick a machine to wire to
        var nwired: [mem.MAXMACH]u16 = @splat(0);
        p.wired = false;
        var i: usize = 0;
        while (proctab(i)) |pp| : (i += 1) {
            const aff = pp.affinity;
            if (aff >= 0 and pp.wired and pp.pid != 0)
                nwired[@intCast(aff)] += 1;
        }
        a = 0;
        var j: i32 = 0;
        while (j < nmach) : (j += 1) {
            if (nwired[@intCast(j)] < nwired[@intCast(a)])
                a = j;
        }
    } else {
        // use the virtual machine requested
        a = @mod(a, nmach);
    }

    p.affinity = a;
    p.wired = true;
}

pub fn procpriority(p: *Proc, pri_: i32, fixed: bool) void {
    const pri: u32 = @intCast(std.math.clamp(pri_, 0, Npriq - 1));
    p.basepri = pri;
    p.priority = pri;
    p.fixedpri = fixed;
}

pub fn procinit0() void {
    procalloc.free = null;
    // allocate 1 extra for a nil terminator
    const tab = xalloc.xalloc((arch.conf.nproc + 1) * @sizeOf(?*Proc)) orelse {
        xalloc.xsummary();
        panic("cannot allocate proctab for %lud procs", .{arch.conf.nproc});
    };
    procalloc.tab = @ptrFromInt(tab);
    pidinit();
}

/// For sleeps that only a wakeup, a timeout or a note ends.
pub fn return0(_: ?*anyopaque) bool {
    return false;
}

/// sleep if a condition is not true.  Another process will
/// awaken us after it sets the condition.  When we awaken
/// the condition may no longer be true.
///
/// we lock both the process and the rendezvous to keep r.p
/// and p.r synchronized.
///
/// Fails with Eintr if a note arrived for the process.
pub fn sleep(r: *Rendez, f: *const fn (?*anyopaque) bool, arg: ?*anyopaque) Error!void {
    const p = cur();
    if (p.nlocks != 0) {
        const ll = p.lastlock;
        print("process %s %lud sleeps with %d locks held, last lock %#p locked at pc %#p, sleep called from %#p\n", .{
            p.text, p.pid,                   p.nlocks,
            ll,     if (ll) |x| x.pc else 0, @returnAddress(),
        });
    }

    const s = arch.splhi();
    lock(&r.lock);
    lock(&p.rlock);
    if (r.p) |other| {
        iprint("double sleep called from %#p, %s %lud -> %s %lud\n", .{ @returnAddress(), other.text, other.pid, p.text, p.pid });
        arch.dumpstack();
    }

    // Wakeup only knows there may be something to do by testing
    // r.p in order to get something to lock on.
    // Flush that information out to memory in case the sleep is
    // committed.
    r.p = p;

    if (f(arg) or p.notepending) {
        // if condition happened or a note is pending
        // never mind
        r.p = null;
        unlock(&p.rlock);
        unlock(&r.lock);
    } else {
        // now we are committed to
        // change state and call scheduler
        p.state = .Wakeme;
        p.r = r;
        unlock(&p.rlock);
        unlock(&r.lock);
        procswitch();
    }

    if (p.notepending) {
        p.notepending = false;
        arch.splx(s);
        return interrupted();
    }
    arch.splx(s);
}

/// What the C does by calling error(Eintr): returns the error for the
/// caller to return.
pub fn interrupted() Error {
    // M3: if(up->procctl == Proc_exitme && up->closingfgrp != nil) forceclosefgrp();
    return error.Eintr;
}

fn twakeup(_: ?*Ureg, t: *Timer) void {
    const p: *Proc = @ptrCast(@alignCast(t.ta.?));
    if (p.trend) |trend| {
        p.trend = null;
        _ = wakeup(trend);
    }
}

fn tfn(arg: ?*anyopaque) bool {
    const p = cur();
    return p.trend == null or p.tfn.?(arg);
}

/// sleep, but for no longer than `ms` milliseconds.
pub fn tsleep(r: *Rendez, f: *const fn (?*anyopaque) bool, arg: ?*anyopaque, ms: u32) Error!void {
    const p = cur();
    if (p.timer.tt != null) {
        print("%s %lud: tsleep timer active: mode %d, tf %#p, pc %#p\n", .{ p.text, p.pid, p.timer.tmode, p.timer.tf, @returnAddress() });
        portclock.timerdel(&p.timer);
    }
    p.timer.tns = portclock.MS2NS(ms);
    p.timer.tmode = portdat.Trelative;
    p.timer.tf = twakeup;
    p.timer.ta = p;
    p.trend = r;
    p.tfn = f;
    portclock.timeradd(&p.timer);

    defer {
        p.trend = null;
        portclock.timerdel(&p.timer);
    }
    try sleep(r, tfn, arg);
}

/// Expects that only one process can call wakeup for any given Rendez.
/// We hold both locks to ensure that r.p and p.r remain consistent.
/// Richard Miller has a better solution that doesn't require both to
/// be held simultaneously, but I'm a paranoid - presotto.
pub fn wakeup(r: *Rendez) ?*Proc {
    const s = arch.splhi();

    lock(&r.lock);
    const p = r.p;
    if (p) |x| {
        lock(&x.rlock);
        if (x.state != .Wakeme or x.r != r) {
            iprint("%p %p %d\n", .{ x.r, r, x.state });
            panic("wakeup: state", .{});
        }
        r.p = null;
        x.r = null;
        unlock(&x.rlock);
        unlock(&r.lock);
        // hands off r
        ready(x);
    } else unlock(&r.lock);

    arch.splx(s);
    return p;
}

/// if waking a sleeping process, this routine must hold both
/// p.rlock and r.lock.  However, it can't know them in
/// the same order as wakeup causing a possible lock ordering
/// deadlock.  We break the deadlock by giving up the p.rlock
/// lock if we can't get the r.lock and retrying.
pub fn procinterrupt(p: *Proc) void {
    p.notepending = true;

    // this loop is to avoid lock ordering problems.
    var s: usize = undefined;
    while (true) {
        s = arch.splhi();
        lock(&p.rlock);
        const r = p.r orelse break; // not waiting for a wakeup

        // try for the second lock
        if (canlock(&r.lock)) {
            if (p.state != .Wakeme or r.p != p)
                panic("procinterrupt: state %d %d %d", .{ r.p != p, p.r != r, p.state });
            p.r = null;
            r.p = null;
            unlock(&p.rlock);
            unlock(&r.lock);
            // hands off r
            ready(p);
            arch.splx(s);
            return;
        }

        // give other process time to get out of critical section and try again
        unlock(&p.rlock);
        arch.splx(s);
        sched();
    }
    unlock(&p.rlock);
    arch.splx(s);

    switch (p.state) {
        .Queueing => {
            // Try and pull out of a eqlock
            const q = p.eql orelse return;
            lock(&q.use);
            if (p.state == .Queueing and p.eql == q) {
                var l: ?*Proc = null;
                var d = q.head;
                while (d) |x| : ({
                    l = x;
                    d = x.qnext;
                }) {
                    if (x != p) continue;
                    if (l) |pl| pl.qnext = p.qnext else q.head = p.qnext;
                    if (p.qnext == null)
                        q.tail = l;
                    p.qnext = null;
                    p.eql = null; // not taken
                    unlock(&q.use);
                    // hands off q
                    ready(p);
                    return;
                }
            }
            unlock(&q.use);
        },
        .Rendezvous => {
            // M4: Try and pull out of a rendezvous (needs Rgrp).
        },
        else => {},
    }
}

fn mknote(msg: []const u8, flag: i32) *Note {
    const n: *Note = @ptrCast(@alignCast(alloc.smalloc(@sizeOf(Note))));
    n.* = .{ .flag = flag };
    kstrcpy(&n.msg, msg);
    n.ref.ref = 1;
    return n;
}

pub fn pushnote(p: *Proc, n: *Note) bool {
    if (@backingInt(p.state) <= @backingInt(portdat.State.New) or p.state == .Broken or p.pid == 0) {
        freenote(n);
        return false;
    }
    if (n.ref.ref <= 0) panic("pushnote: ref", .{});
    if (n.flag != portdat.NUser and (p.notify == 0 or p.notified))
        freenotes(p);
    if (p.nnote < portdat.NNOTE) {
        p.note[@intCast(p.nnote)] = n;
        p.nnote += 1;
        procinterrupt(p);
        return true;
    }
    freenote(n);
    return false;
}

pub fn postnote(p_: ?*Proc, dolock: bool, msg: []const u8, flag: i32) bool {
    const p = p_ orelse return false;
    const n = mknote(msg, flag);
    if (dolock)
        ql.qlock(&p.debug);
    const ret = pushnote(p, n);
    if (dolock)
        ql.qunlock(&p.debug);
    return ret;
}

pub fn postnotepg(noteid: u32, msg: []const u8, flag: i32) void {
    const n = mknote(msg, flag);
    var i: usize = 0;
    while (proctab(i)) |p| : (i += 1) {
        if (p == arch.up() or p.noteid != noteid or p.kp)
            continue;
        ql.qlock(&p.debug);
        if (p.noteid == noteid and !p.kp) {
            _ = portdat.incref(&n.ref);
            _ = pushnote(p, n);
        }
        ql.qunlock(&p.debug);
    }
    freenote(n);
}

// keep some broken processes around
var broken: struct {
    lock: taslock.Lock = .{},
    n: usize = 0,
    p: [4]?*Proc = @splat(null),
} = .{};

fn addbroken() void {
    const p = cur();
    lock(&broken.lock);
    if (broken.n == broken.p.len) {
        ready(broken.p[0].?);
        broken.n -= 1;
        std.mem.copyForwards(?*Proc, broken.p[0..broken.n], broken.p[1..]);
    }
    broken.p[broken.n] = p;
    broken.n += 1;
    p.state = .Broken;
    p.psstate = null;
    unlock(&broken.lock);
    sched();
}

pub fn unbreak(p: *Proc) void {
    lock(&broken.lock);
    for (0..broken.n) |i| {
        if (broken.p[i] == p) {
            std.mem.copyForwards(?*Proc, broken.p[i .. broken.n - 1], broken.p[i + 1 .. broken.n]);
            broken.n -= 1;
            broken.p[broken.n] = null;
            ready(p);
            break;
        }
    }
    unlock(&broken.lock);
}

pub fn freebroken() usize {
    lock(&broken.lock);
    const n = broken.n;
    broken.n = 0;
    for (0..n) |i| {
        const p = broken.p[i].?;
        broken.p[i] = null;
        ready(p);
    }
    unlock(&broken.lock);
    return n;
}

pub fn freenote(n_: ?*Note) void {
    const n = n_ orelse return;
    if (portdat.decref(&n.ref) != 0)
        return;
    alloc.free(n);
}

pub fn freenotes(p: *Proc) void {
    while (p.nnote > 0) {
        p.nnote -= 1;
        freenote(p.note[@intCast(p.nnote)]);
        p.note[@intCast(p.nnote)] = null;
    }
}

pub fn pexit(exitstr_: ?[]const u8, freemem: bool) noreturn {
    const up = cur();
    var exitstr = exitstr_;

    up.alarm = 0;
    portclock.timerdel(&up.timer);

    // nil out all the resources under lock (free later)
    ql.qlock(&up.debug);
    const fgrp = up.fgrp;
    up.fgrp = null;
    const egrp = up.egrp;
    up.egrp = null;
    const rgrp = up.rgrp;
    up.rgrp = null;
    const pgrp = up.pgrp;
    up.pgrp = null;
    const dot = up.dot;
    up.dot = null;
    ql.qunlock(&up.debug);

    // M3: closefgrp, closeegrp, closergrp, cclose(dot), closepgrp.
    if (fgrp != null or egrp != null or rgrp != null or dot != null or pgrp != null)
        panic("pexit: process has resources this kernel cannot release yet", .{});

    if (up.parentpid == 0) {
        if (exitstr == null)
            exitstr = "unknown";
        panic("boot process died: %s", .{exitstr.?});
    }

    if (up.parent) |p| {
        if (p.pid == up.parentpid and p.state != .Broken) {
            var wq: ?*Waitq = @ptrCast(@alignCast(alloc.smalloc(@sizeOf(Waitq))));
            const w = wq.?;
            w.* = .{};
            w.w.pid = up.pid;
            const utime = up.time[portdat.TUser] +% up.time[portdat.TCUser];
            const stime = up.time[portdat.TSys] +% up.time[portdat.TCSys];
            w.w.time[portdat.TUser] = portclock.tk2ms(utime);
            w.w.time[portdat.TSys] = portclock.tk2ms(stime);
            w.w.time[portdat.TReal] = portclock.tk2ms(arch.MACHP(0).ticks -% up.time[portdat.TReal]);
            if (exitstr != null and exitstr.?.len != 0) {
                const s = fmt.snprint(w.w.msg[0 .. w.w.msg.len - 1], "%s %lud: %s", .{ up.text, up.pid, exitstr.? });
                w.w.msg[s.len] = 0;
            } else w.w.msg[0] = 0;

            lock(&p.exl);
            // Check that parent is still alive.
            if (p.pid == up.parentpid and p.state != .Broken) {
                p.nchild -= 1;
                p.time[portdat.TCUser] +%= utime;
                p.time[portdat.TCSys] +%= stime;
                // If there would be more than 128 wait records
                // processes for my parent, then don't leave a wait
                // record behind.  This helps prevent badly written
                // daemon processes from accumulating lots of wait
                // records.
                if (p.nwait < 128) {
                    w.next = p.waitq;
                    p.waitq = w;
                    p.nwait += 1;
                    wq = null;
                    _ = wakeup(&p.waitr);
                }
            }
            unlock(&p.exl);
            if (wq) |x| alloc.free(x);
        }
    }

    if (!freemem) {
        // DIFF: edf — edfstop(up)
        addbroken();
    }

    ql.qlock(&up.seglock);
    // M4: putseg(detachseg(up, i)) for every segment.
    ql.qunlock(&up.seglock);

    ql.qlock(&up.debug);
    lock(&up.exl); // Prevent my children from leaving waits
    pidfree(up);
    up.parent = null;
    up.nchild = 0;
    up.nwait = 0;
    _ = wakeup(&up.waitr);
    unlock(&up.exl);

    while (up.waitq) |wq| {
        up.waitq = wq.next;
        alloc.free(wq);
    }

    freenotes(up);
    freenote(up.lastnote);
    up.lastnote = null;
    up.notified = false;
    up.noteureg = null;
    up.dbgreg = null;

    // release debuggers
    if (up.pdbg) |d| {
        _ = wakeup(&d.sleep);
        up.pdbg = null;
    }
    if (up.syscalltrace) |t| {
        alloc.free(t.ptr);
        up.syscalltrace = null;
    }
    if (up.watchpt) |w| {
        alloc.free(w);
        up.watchpt = null;
    }
    up.nwatchpt = 0;
    ql.qunlock(&up.debug);

    // DIFF: edf — edfstop(up) and free(up->edf)

    up.state = .Moribund;
    sched();
    panic("pexit", .{});
}

fn haswaitq(x: ?*anyopaque) bool {
    const p: *Proc = @ptrCast(@alignCast(x.?));
    return p.waitq != null;
}

/// Wait for a child to exit; returns its pid and, in `w`, its wait record.
pub fn pwait(w: ?*portdat.Waitmsg) Error!u32 {
    const up = cur();
    if (!ql.canqlock(&up.qwaitr))
        return error.Einuse;
    defer ql.qunlock(&up.qwaitr);

    lock(&up.exl);
    while (up.waitq == null) {
        if (up.nchild == 0) {
            unlock(&up.exl);
            return error.Enochild;
        }
        unlock(&up.exl);
        try sleep(&up.waitr, haswaitq, up);
        lock(&up.exl);
    }
    const wq = up.waitq.?;
    up.waitq = wq.next;
    up.nwait -= 1;
    unlock(&up.exl);

    if (w) |out| out.* = wq.w;
    const cpid = wq.w.pid;
    alloc.free(wq);
    return cpid;
}

/// The i'th process slot, or null past the last one allocated.
pub fn proctab(i: usize) ?*Proc {
    return procalloc.tab[i];
}

pub fn dumpaproc(p_: ?*Proc) void {
    const p = p_ orelse return;
    // M4: bss is the top of the BSS segment.
    const bss: usize = 0;
    const s = p.psstate orelse statename(p.state);
    const ll = p.lastlock;
    print("%3lud:%10s pc %#p dbgpc %#p  %8s (%s) ut %ld st %ld bss %lux qpc %#p nl %d nd %lud lpc %#p pri %lud\n", .{
        p.pid,                   p.text,     p.pc, arch.dbgpc(p), s,        statename(p.state),
        p.time[0],               p.time[1],  bss,  p.qpc,         p.nlocks, p.delaysched,
        if (ll) |x| x.pc else 0, p.priority,
    });
}

/// Print every process: what the ^T^Tp console command shows.
pub fn procdump() void {
    var i: usize = 0;
    while (proctab(i)) |p| : (i += 1) {
        if (p.state != .Dead) dumpaproc(p);
    }
}

/// First code a kernel process runs.
fn linkproc() callconv(.c) noreturn {
    _ = arch.spllo();
    const up = cur();
    up.kpfun.?(up.kparg);
    pexit("kproc exiting", false);
}

/// Start a kernel process running func(arg).
pub fn kproc(name: []const u8, func: *const fn (?*anyopaque) void, arg: ?*anyopaque) void {
    // DIFF: the C frees broken processes and waits (resrcwait) when the
    // table is full; resrcwait arrives with pgrp.c.
    const p = newproc() orelse blk: {
        _ = freebroken();
        break :blk newproc() orelse panic("kproc: no procs for %s", .{name});
    };

    ql.qlock(&p.debug);
    // M3: inherit slash and dot from up, and share the kernel
    // processes' namespace (kpgrp).
    p.slash = null;
    p.dot = null;

    p.nnote = 0;
    p.notify = 0;
    p.notified = false;
    p.notepending = false;
    p.lastnote = null;

    p.procmode = 0o640;
    p.privatemem = true;
    p.noswap = true;
    p.hang = false;
    p.kp = true;

    p.kpfun = func;
    p.kparg = arg;
    arch.kprocchild(p, linkproc);

    kstrdup(&p.text, name);
    kstrdup(&p.user, eve);
    kstrdup(&p.args, "");
    p.nargs = 0;
    p.setargs = false;

    p.insyscall = 1;
    p.time = @splat(0);
    p.time[portdat.TReal] = arch.MACHP(0).ticks;
    p.kentry = arch.cycles();
    p.pcycles = -%@as(i64, @bitCast(p.kentry));

    _ = pidalloc(p);

    ql.qunlock(&p.debug);

    procpriority(p, portdat.PriKproc, false);

    ready(p);
}

/// Set up.errstr from a format and return the error that says to look
/// there; what error(buf) does in C after an snprint.
pub fn errorf(comptime format: []const u8, args: anytype) Error {
    const up = cur();
    const s = fmt.snprint(up.errstr[0 .. portdat.ERRMAX - 1], format, args);
    up.errstr[s.len] = 0;
    return error.Str;
}

/// called with p.debug locked.
pub fn killproc(p: *Proc, ctl: i32) void {
    const S = struct {
        var killnote: Note = blk: {
            var n: Note = .{ .flag = portdat.NExit, .ref = .{ .ref = 1 } };
            const msg = "sys: killed";
            @memcpy(n.msg[0..msg.len], msg);
            break :blk n;
        };
    };
    if (@backingInt(p.state) <= @backingInt(portdat.State.New) or p.pid == 0 or p.kp)
        return;
    if (p.state == .Broken) {
        unbreak(p);
        return;
    }
    if (ctl != 0)
        p.procctl = ctl;
    _ = portdat.incref(&S.killnote.ref);
    _ = pushnote(p, &S.killnote);
    if (p.state == .Stopped)
        ready(p);
}

/// change ownership to 'new' of all processes owned by 'old'.  Used when
/// eve changes.
pub fn renameuser(old: []const u8, new: []const u8) void {
    var i: usize = 0;
    while (proctab(i)) |p| : (i += 1) {
        ql.qlock(&p.debug);
        if (std.mem.eql(u8, old, p.user))
            kstrdup(&p.user, new);
        ql.qunlock(&p.debug);
    }
}

pub fn procsetuser(new: []const u8) void {
    const up = cur();
    ql.qlock(&up.debug);
    kstrdup(&up.user, new);
    ql.qunlock(&up.debug);
    procpriority(up, portdat.PriNormal, false);
}

var nrun: u32 = 0;

/// time accounting called by clock() splhi'd
pub fn accounttime() void {
    const mach = arch.m();
    if (mach.proc) |p| {
        nrun += 1;
        p.time[p.insyscall] +%= 1;
    }

    // calculate decaying duty cycles
    var n = arch.perfticks();
    var per: u64 = n -% mach.perf.last;
    mach.perf.last = n;
    per = (@as(u64, mach.perf.period) * (HZ - 1) + per) / HZ;
    if (per != 0)
        mach.perf.period = @truncate(per);

    mach.perf.avg_inidle = @truncate((@as(u64, mach.perf.avg_inidle) * (HZ - 1) + mach.perf.inidle) / HZ);
    mach.perf.inidle = 0;

    mach.perf.avg_inintr = @truncate((@as(u64, mach.perf.avg_inintr) * (HZ - 1) + mach.perf.inintr) / HZ);
    mach.perf.inintr = 0;

    // only one processor gets to compute system load averages
    if (mach.machno != 0)
        return;

    // calculate decaying load average.
    // if we decay by (n-1)/n then it takes
    // n clock ticks to go from load L to .36 L once
    // things quiet down.  it takes about 5 n clock
    // ticks to go to zero.  so using HZ means this is
    // approximately the load over the last second,
    // with a tail lasting about 5 seconds.
    n = nrun;
    nrun = 0;
    n = (@as(u32, @intCast(@max(nrdy, 0))) + n) * 1000 * 100;
    load = @truncate((@as(u64, load) * (HZ - 1) + n) / HZ);
    mach.load = @intCast(load / 100);
}

// A Pid structure is a reference counted hashtable entry
// with "pid" being the key and "procindex" being the value.
// A entry is allocated atomically by changing the key from
// negative or zero to the positive process id number.
// Pid's outlive ther Proc's as long as other processes hold
// a reference to them such as noteid or parentpid.
// This prevents pid reuse when the pid generator wraps.
const Pid = struct {
    ref: portdat.Ref = .{},
    pid: i32 = 0,
    procindex: u32 = 0,
};

const PIDMASK = 0x7FFFFFFF;
const PIDSHIFT = 4; // log2 bucket size of the hash table

var pidhashtab: [*]Pid = undefined;
var pidhashmask: u32 = 0;
var pidgen: portdat.Ref = .{};

fn pidinit() void {
    // allocate 3 times conf.nproc Pid structures for the hash table
    // and round up to a power of two as each process can reference
    // up to 3 unique Pid structures:
    //    - pid
    //    - noteid
    //    - parentpid
    pidhashmask = 1 << PIDSHIFT;
    while (pidhashmask < arch.conf.nproc * 3)
        pidhashmask <<= 1;

    const t = xalloc.xalloc(pidhashmask * @sizeOf(Pid)) orelse {
        xalloc.xsummary();
        panic("cannot allocate pid hashtable of size %lud", .{pidhashmask});
    };
    pidhashtab = @ptrFromInt(t);

    // make it a mask
    pidhashmask -= 1;
}

fn bucket(pid: i32) []Pid {
    const i = (@as(u32, @bitCast(pid)) << PIDSHIFT) & pidhashmask;
    return pidhashtab[i..][0 .. 1 << PIDSHIFT];
}

fn pidlookup(pid: i32) ?*Pid {
    for (bucket(pid)) |*i| {
        const o = @atomicLoad(i32, &i.pid, .seq_cst);
        if (o == pid) return i;
        if (o == 0) break;
    }
    return null;
}

/// increment the reference count of a pid (pid>0)
/// or allocate a new one (pid<=0)
fn pidadd(pid_: i32) ?*Pid {
    if (pid_ > 0) {
        const i = pidlookup(pid_) orelse return null;
        _ = portdat.incref(&i.ref);
        return i;
    }
    while (true) {
        var pid: i32 = 0;
        while (pid == 0 or pidlookup(pid) != null)
            pid = portdat.incref(&pidgen) & PIDMASK;
        for (bucket(pid)) |*i| {
            while (true) {
                const o = @atomicLoad(i32, &i.pid, .seq_cst);
                if (o > 0) break;
                if (@cmpxchgStrong(i32, &i.pid, o, pid, .seq_cst, .seq_cst) == null) {
                    _ = portdat.incref(&i.ref);
                    return i;
                }
            }
        }
        // bucket full, try a different pid
    }
}

/// decrement reference count of a pid and free it
/// when no references are remaining
fn piddel(i: *Pid) void {
    if (portdat.decref(&i.ref) != 0)
        return;
    @atomicStore(i32, &i.pid, -1, .seq_cst); // freed
}

/// The slot in the process table of the process with this pid, or -1.
pub fn procindex(pid: u32) i32 {
    if (pidlookup(@bitCast(pid))) |i| {
        const x = i.procindex;
        if (proctab(x)) |p| {
            if (p.pid == pid) return @intCast(x);
        }
    }
    return -1;
}

// for the following functions:
//   setnoteid(), pidalloc() and pidfree()
//
// They need to be called with p.debug held
// to prevent devproc's changenoteid() from
// changing the noteid under us and make the
// update atomic.

/// change the noteid of a process
pub fn setnoteid(p: *Proc, noteid: u32) Error!u32 {
    // avoid allocating a new pid when we are the only
    // user of the noteid
    const o = pidlookup(@bitCast(p.noteid)).?;
    if (noteid == 0 and o.ref.ref == 1)
        return @bitCast(o.pid);

    const i = pidadd(@bitCast(noteid)) orelse return error.Ebadarg;
    piddel(o);
    p.noteid = @bitCast(i.pid);
    return p.noteid;
}

/// allocate pid, noteid and parentpid to a process
pub fn pidalloc(p: *Proc) u32 {
    // skip for the boot process
    if (arch.up()) |up| {
        const i = pidadd(@bitCast(up.pid)).?;
        p.parentpid = @bitCast(i.pid);
    } else p.parentpid = 0;

    const i = pidadd(0).?;
    i.procindex = p.index;

    if (p.noteid == 0) {
        _ = portdat.incref(&i.ref);
        p.noteid = @bitCast(i.pid);
    } else _ = pidadd(@bitCast(p.noteid));

    p.pid = @bitCast(i.pid);
    return p.pid;
}

/// release pid, noteid and parentpid from a process
fn pidfree(p: *Proc) void {
    var i = pidlookup(@bitCast(p.pid)).?;
    piddel(i);

    if (p.noteid != p.pid)
        i = pidlookup(@bitCast(p.noteid)).?;
    piddel(i);

    if (p.parentpid != 0)
        piddel(pidlookup(@bitCast(p.parentpid)).?);

    p.pid = 0;
    p.noteid = 0;
    p.parentpid = 0;
}

/// Copy `t` into `s` as a NUL-terminated string, truncating if it must.
/// from 9/port/chan.c
pub fn kstrcpy(s: []u8, t: []const u8) void {
    if (s.len == 0) return;
    if (t.len < s.len) {
        @memcpy(s[0..t.len], t);
        s[t.len] = 0;
        return;
    }
    // too long, truncate
    const nt = s.len - 1;
    @memcpy(s[0..nt], t[0..nt]);
    s[nt] = 0;
    // append ... if there is space
    if (nt >= 4) @memcpy(s[nt - 3 .. nt], "...");
}

/// Replace the string at `p` with a copy of `s`, freeing the old one.
/// from 9/port/chan.c
/// DIFF: strings are slices, not NUL-terminated.
pub fn kstrdup(p: *[]u8, s: []const u8) void {
    // if it's a user, we can wait for memory; if not, something's very wrong
    const t = if (arch.up() != null)
        alloc.smalloc(s.len + 1)
    else
        alloc.malloc(s.len + 1) orelse panic("kstrdup: no memory", .{});
    @memcpy(t[0..s.len], s);
    const prev = p.*;
    p.* = t[0..s.len];
    if (prev.ptr != portdat.nostr.ptr)
        alloc.free(prev.ptr);
}
