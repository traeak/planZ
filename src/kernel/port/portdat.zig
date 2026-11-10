//! Portable kernel data structures.
//! from 9/port/portdat.h
//!
//! What has been ported so far; the structures of later milestones are
//! opaque placeholders so Proc can already point at them.

const std = @import("std");
const arch = @import("../arch.zig");

const Mach = arch.Mach;
const Label = arch.Label;
const Ureg = arch.Ureg;

pub const ERRMAX = 128; // max length of error string
pub const KNAMELEN = 28; // max length of name held in kernel

pub const Lock = struct {
    key: u32 = 0,
    sr: usize = 0,
    pc: usize = 0,
    p: ?*Proc = null,
    m: ?*Mach = null,
    isilock: bool = false,
    lockcycles: i64 = 0,
};

pub const Ref = struct {
    ref: i32 = 0,
};

/// from 9/port/chan.c
pub fn incref(r: *Ref) i32 {
    return @atomicRmw(i32, &r.ref, .Add, 1, .seq_cst) + 1;
}

/// from 9/port/chan.c
pub fn decref(r: *Ref) i32 {
    const new = @atomicRmw(i32, &r.ref, .Sub, 1, .seq_cst) - 1;
    if (new < 0)
        @import("print.zig").panic("decref pc=%#p", .{@returnAddress()});
    return new;
}

pub const QLock = struct {
    use: Lock = .{}, // to access Qlock structure
    head: ?*Proc = null, // next process waiting for object
    tail: ?*Proc = null, // last process waiting for object
    pc: usize = 0, // pc of owner
    locked: bool = false, // flag
};

pub const RWLock = struct {
    use: Lock = .{},
    head: ?*Proc = null, // list of waiting processes
    tail: ?*Proc = null,
    wpc: usize = 0, // pc of writer
    writer: i32 = 0, // number of writers
    readers: i32 = 0, // number of readers
};

pub const Rendez = struct {
    lock: Lock = .{},
    p: ?*Proc = null,
};

pub const Alarms = struct {
    qlock: QLock = .{},
    head: ?*Proc = null,
};

// Note.flag
pub const NUser = 0; // note provided externally
pub const NExit = 1; // deliver note quietly
pub const NDebug = 2; // print debug message

pub const Note = struct {
    msg: [ERRMAX]u8 = @splat(0),
    flag: i32 = 0, // whether system posted it
    ref: Ref = .{},
};

pub const Waitmsg = struct {
    pid: u32 = 0, // of loved one
    time: [3]u32 = .{ 0, 0, 0 }, // of loved one and descendants
    msg: [ERRMAX]u8 = @splat(0),
};

pub const Waitq = struct {
    w: Waitmsg = .{},
    next: ?*Waitq = null,
};

// fasttick timer interrupts

// Timer.tmode
pub const Trelative = 0; // timer programmed in ns from now
pub const Tperiodic = 1; // periodic timer, period in ns

pub const Timers = struct {
    lock: Lock = .{},
    head: ?*Timer = null,
};

pub const Timer = struct {
    // Public interface
    tmode: i32 = Trelative, // See above
    tns: i64 = 0, // meaning defined by mode
    tf: ?*const fn (?*Ureg, *Timer) void = null,
    ta: ?*anyopaque = null,
    // Internal
    lock: Lock = .{},
    tactive: ?*Mach = null, // The cpu that tf is active on
    tt: ?*Timers = null, // Timers queue this timer runs on
    tticks: i64 = 0, // tns converted to ticks
    twhen: u64 = 0, // ns represented in fastticks
    tnext: ?*Timer = null,
};

// process memory segments - NSEG always last !
pub const SSEG = 0;
pub const TSEG = 1;
pub const DSEG = 2;
pub const BSEG = 3;
pub const ESEG = 4;
pub const LSEG = 5;
pub const SEG1 = 6;
pub const SEG2 = 7;
pub const SEG3 = 8;
pub const SEG4 = 9;
pub const NSEG = 10;

/// Process states
pub const State = enum(u8) {
    Dead = 0,
    Moribund,
    New,
    Ready,
    Scheding,
    Running,
    Queueing,
    QueueingR,
    QueueingW,
    Wakeme,
    Broken,
    Stopped,
    Rendezvous,
    Waitrelease,
};

// devproc requests
pub const Proc_stopme = 1;
pub const Proc_exitme = 2;
pub const Proc_traceme = 3;
pub const Proc_exitbig = 4;
pub const Proc_tracesyscall = 5;

// Proc.time
pub const TUser = 0;
pub const TSys = 1;
pub const TReal = 2;
pub const TCUser = 3;
pub const TCSys = 4;
pub const TCReal = 5;

pub const NERR = 32;
pub const NNOTE = 5;

pub const Npriq = 20; // number of scheduler priority levels
pub const Nrq = Npriq + 2; // number of priority levels including real time
pub const PriRelease = Npriq; // released edf processes
pub const PriEdf = Npriq + 1; // active edf processes
pub const PriNormal = 10; // base priority for normal processes
pub const PriExtra = Npriq - 1; // edf processes at high best-effort pri
pub const PriKproc = 13; // base priority for kernel processes
pub const PriRoot = 13; // base priority for root processes

pub const Schedq = struct {
    lock: Lock = .{},
    head: ?*Proc = null,
    tail: ?*Proc = null,
    n: i32 = 0,
};

var nostrbuf: [1]u8 = .{0};
/// The empty string that kstrdup'ed fields start out as; it marks a
/// field that owns no memory.
pub const nostr: []u8 = nostrbuf[0..0];

// Not ported yet.
pub const Segment = opaque {};
pub const Pgrp = opaque {};
pub const Egrp = opaque {};
pub const Fgrp = opaque {};
pub const Rgrp = opaque {};
pub const Chan = opaque {};
pub const Watchpt = opaque {};

pub const Proc = struct {
    sched: Label = .{}, // known to the context switch

    mach: ?*Mach = null, // machine running this proc
    text: []u8 = nostr,
    user: []u8 = nostr,

    args: []u8 = nostr,
    nargs: i32 = 0, // number of bytes of args
    setargs: bool = false, // process changed its args

    rnext: ?*Proc = null, // next process in run queue
    qnext: ?*Proc = null, // next process on queue for a QLock

    psstate: ?[]const u8 = null, // What /proc/#/status reports
    state: State = .Dead,

    pid: u32 = 0,
    noteid: u32 = 0, // Equivalent of note group
    parentpid: u32 = 0,
    index: u32 = 0,

    parent: ?*Proc = null, // Process to send wait record on exit
    exl: Lock = .{}, // Lock count and waitq
    waitq: ?*Waitq = null, // Exited processes wait children
    nchild: i32 = 0, // Number of living children
    nwait: i32 = 0, // Number of uncollected wait records
    qwaitr: QLock = .{},
    waitr: Rendez = .{}, // Place to hang out in wait

    seglock: QLock = .{}, // locked whenever seg[] changes
    seg: [NSEG]?*Segment = @splat(null),

    pgrp: ?*Pgrp = null, // Process group for namespace
    egrp: ?*Egrp = null, // Environment group
    fgrp: ?*Fgrp = null, // File descriptor group
    rgrp: ?*Rgrp = null, // Rendez group

    closingfgrp: ?*Fgrp = null, // used during teardown

    insyscall: u32 = 0,
    time: [6]u32 = @splat(0), // User, Sys, Real; child U, S, R

    kentry: u64 = 0, // Kernel entry time stamp (for profiling)
    // pcycles: cycles spent in this process (updated on procswitch)
    // when this is the current proc and we're in the kernel
    // (procrestores outnumber procsaves by one)
    // the number of cycles spent in the proc is pcycles + cycles()
    // when this is not the current process or we're in user mode
    // (procrestores and procsaves balance), it is pcycles.
    pcycles: i64 = 0,

    debug: QLock = .{}, // to access debugging elements of User
    pdbg: ?*Proc = null, // the debugging process
    procmode: u32 = 0, // proc device default file mode
    privatemem: bool = false, // proc does not let anyone read mem
    noswap: bool = false, // process is not swappable
    hang: bool = false, // hang at next exec for debug
    procctl: i32 = 0, // Control for /proc debugging

    rlock: Lock = .{}, // sync sleep/wakeup with procinterrupt
    r: ?*Rendez = null, // rendezvous point slept on
    sleep: Rendez = .{}, // place for syssleep/debug
    notepending: bool = false, // note issued but not acted on
    kp: bool = false, // true if a kernel process
    palarm: ?*Proc = null, // Next alarm time
    alarm: u32 = 0, // Time of call

    rendtag: usize = 0, // Tag for rendezvous
    rendval: usize = 0, // Value for rendezvous
    rendhash: ?*Proc = null, // Hash list for tag values

    timer: Timer = .{}, // For tsleep and real-time
    trend: ?*Rendez = null,
    tfn: ?*const fn (?*anyopaque) bool = null,
    kpfun: ?*const fn (?*anyopaque) void = null,
    kparg: ?*anyopaque = null,

    scallnr: i32 = 0, // sys call number
    // DIFF: no errlab/nerrlab; errors are Zig error returns.
    syserrstr: *[ERRMAX]u8 = undefined, // last error from a system call, errbuf0 or 1
    errstr: *[ERRMAX]u8 = undefined, // reason we're unwinding the error stack, errbuf1 or 0
    errbuf0: [ERRMAX]u8 = @splat(0),
    errbuf1: [ERRMAX]u8 = @splat(0),
    genbuf: [128]u8 = @splat(0), // buffer used e.g. for last name element from namec
    slash: ?*Chan = null,
    dot: ?*Chan = null,

    lastnote: ?*Note = null,
    note: [NNOTE]?*Note = @splat(null),
    nnote: i16 = 0,
    notified: bool = false, // sysnoted is due
    notify: usize = 0, // user address of the note handler

    lastlock: ?*Lock = null, // debugging
    lastilock: ?*Lock = null, // debugging

    nlocks: i32 = 0, // number of locks held by proc

    delaysched: u32 = 0,
    priority: u32 = 0, // priority level
    basepri: u32 = 0, // base priority level
    fixedpri: bool = false, // priority level doesn't change
    wired: bool = false,
    affinity: i32 = 0, // machno this process last ran on
    cpu: u32 = 0, // cpu average
    lastupdate: u32 = 0,

    // DIFF: edf — no Edf pointer; see PLAN.md "Future additions".
    trace: bool = false, // process being traced?

    qpc: usize = 0, // pc calling last blocking qlock
    eql: ?*QLock = null, // interruptable eqlock

    noteureg: ?*Ureg = null, // User registers for notes
    dbgreg: ?*Ureg = null, // User registers for devproc

    fpu: arch.PFPU = .{}, // machine specific fpu state

    newtlb: bool = false, // someone has changed my pte's, I must flush
    tlbflush: u32 = 0, // incremented on tlb flush

    mmu: arch.PMMU = .{}, // machine specific mmu state

    syscalltrace: ?[]u8 = null, // syscall trace

    watchpt: ?*Watchpt = null, // watchpoints
    nwatchpt: i32 = 0,

    /// Saved pc at the last clock tick, for the process dump.
    pc: usize = 0,
};

pub const PRINTSIZE = 256;
pub const NUMSIZE = 12; // size of formatted number
pub const MB = 1024 * 1024;
// READSTR was 1000, which is way too small for usb's ctl file
pub const READSTR = 8000; // temporary buffer size for device reads
