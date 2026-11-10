//! Portable kernel data structures.
//! from 9/port/portdat.h
//!
//! What has been ported so far; the structures of later milestones are
//! opaque placeholders so Proc can already point at them.

const std = @import("std");
const arch = @import("../arch.zig");
const fcall = @import("fcall");

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

// Page.modref
pub const PG_MOD = 0x01; // software modified bit
pub const PG_REF = 0x02; // software referenced bit
pub const PG_PRIV = 0x04; // private page

pub const Page = struct {
    ref: Ref = .{},
    next: ?*Page = null, // Free list or Hash chains
    pa: usize = 0, // Physical address in memory
    va: usize = 0, // Virtual address for user
    daddr: usize = 0, // Offset in the image the page caches
    image: ?*Image = null, // Associated text image
    modref: u8 = 0, // Simulated modify/reference bits
    // DIFF: no refage (swap) and no color (page colouring).
    /// Flush icache bitmap for putmmu(); empty where the processor
    /// keeps its caches coherent.
    txtflush: arch.Txtflush = .{},
};

pub const Pte = struct {
    pages: [arch.mem.PTEPERTAB]?*Page = @splat(null), // Page map for this chunk of pte
    /// Indices of the first and last used entries.  An empty Pte has
    /// first = PTEPERTAB and last = 0.  DIFF: the C keeps pointers.
    first: usize = arch.mem.PTEPERTAB,
    last: usize = 0,
};

// Segment types
pub const SG_TYPE = 0o7; // Mask type of segment
pub const SG_TEXT = 0o0;
pub const SG_DATA = 0o1;
pub const SG_BSS = 0o2;
pub const SG_STACK = 0o3;
pub const SG_SHARED = 0o4;
pub const SG_PHYSICAL = 0o5;
pub const SG_FIXED = 0o6;
pub const SG_STICKY = 0o7;

pub const SG_RONLY = 0o040; // Segment is read only
pub const SG_CEXEC = 0o100; // Detach at exec
pub const SG_FAULT = 0o200; // Fault on access
pub const SG_CACHED = 0o400; // Normal cached memory
pub const SG_DEVICE = 0o1000; // Memory mapped device
pub const SG_NOEXEC = 0o2000; // No execute

pub const Physseg = struct {
    attr: u32 = 0, // Segment attributes
    name: []const u8 = "", // Attach name
    pa: usize = 0, // Physical address
    size: usize = 0, // Maximum segment size in bytes
};

pub const Sema = struct {
    r: Rendez = .{},
    addr: ?*i32 = null,
    waiting: bool = false,
    next: ?*Sema = null,
    prev: ?*Sema = null,
};

pub const Segment = struct {
    ref: Ref = .{},
    qlock: QLock = .{},
    type: u32 = 0, // segment type
    size: usize = 0, // size in pages

    base: usize = 0, // virtual base
    top: usize = 0, // virtual top
    fstart: usize = 0, // start address in file for demand load
    flen: usize = 0, // length of segment in file

    flushme: bool = false, // maintain icache for this segment
    image: ?*Image = null, // text in file attached to this segment
    pseg: ?*Physseg = null,
    profile: ?[]u32 = null, // Tick profile area

    /// effective map array; map.len is mapsize in the C
    map: []?*Pte = &.{},

    // pre-allocated Pte and (small-) map array as part of this Segment's allocation
    freepte: ?*Pte = null,
    ssegmap: [arch.mem.SSEGMAPSIZE]?*Pte = @splat(null),

    used: usize = 0, // pages used
    // DIFF: no swapped count.

    sema: Sema = .{},

    firstproc: i32 = 0, // lowest proc->index having segment attached
    lastproc: i32 = 0, // highest proc->index having segment attached
    segno: i32 = 0, // last attached proc->seg[segno] number
};

pub const Image = struct {
    ref: Ref = .{},
    lock: Lock = .{},

    pgref: i32 = 0, // number of cached pages (pgref <= ref)

    nattach: u32 = 0, // usage frequency

    link: ?*?*Image = null, // idle list
    next: ?*Image = null, // idle list

    hash: ?*Image = null, // Qid hash chains

    s: ?*Segment = null, // TEXT segment for image if running

    c: ?*Chan = null, // channel to text file, nil when not used
    qid: Qid = .{}, // Qid for page cache coherence
    dev: u32 = 0, // Device id of owning channel
    type: u16 = 0, // Device type of owning channel
    notext: bool = false, // no file associated

    /// page cache; pghash.len is pghsize in the C.  Stored after the
    /// Image in the same allocation.
    pghash: []?*Page = &.{},

    /// PGHASH in the C: the hash chain for a file offset.
    pub fn pghashp(i: *Image, daddr: usize) *?*Page {
        return &i.pghash[(daddr >> arch.mem.PGSHIFT) & (i.pghash.len - 1)];
    }
};

pub const Rendezq = struct {
    qlock: QLock = .{},
    r: Rendez = .{},
};

pub const Palloc = struct {
    lock: Lock = .{},
    head: ?*Page = null, // freelist head
    freecount: usize = 0, // how many pages on free list now
    user: usize = 0, // how many user pages
    pages: []Page = &.{}, // array of all pages
    pwait: [2]Rendezq = .{ .{}, .{} }, // Queues of procs waiting for memory
};

pub const MAXSYSARG = 5; // for mount(fd, afd, mpt, flag, arg)

/// The arguments of a system call, as the words the user pushed.
/// DIFF: the C handlers take a va_list and va_arg each argument off it;
/// here they take *Sargs and call next(T).
pub const Sargs = struct {
    args: [MAXSYSARG]usize = @splat(0),
    i: usize = 0,

    /// The next argument, as T: an integer of any width (the low bits
    /// of the word, as va_arg(list, int) gives), a bool, or usize for a
    /// user address.
    pub fn next(a: *Sargs, comptime T: type) T {
        const v = a.args[a.i];
        a.i += 1;
        return switch (@typeInfo(T)) {
            .int => |info| if (info.signedness == .signed)
                @bitCast(@as(@Int(.unsigned, info.bits), @truncate(v)))
            else
                @truncate(v),
            .bool => v != 0,
            else => @compileError("Sargs.next: " ++ @typeName(T)),
        };
    }
};

/// The top of every user stack: data the kernel and the process share.
/// from /sys/include/tos.h; the layout is ABI.
pub const Tos = extern struct {
    // Per process profiling
    prof: extern struct {
        pp: usize = 0, // known to be 0(ptr)
        next: usize = 0, // known to be 4(ptr)
        last: usize = 0,
        first: usize = 0,
        pid: u32 = 0,
        what: u32 = 0,
    } = .{},
    cyclefreq: u64 = 0, // cycle clock frequency if there is one, 0 otherwise
    kcycles: i64 = 0, // cycles spent in kernel
    pcycles: i64 = 0, // cycles spent in process (kernel + user)
    pid: u32 = 0, // might as well put the pid here
    clock: u32 = 0,
    // top of stack is here
};

pub const Watchpt = opaque {};
pub const Mntcache = opaque {};
pub const Mnt = opaque {};

pub const Qid = fcall.Qid;
pub const Dir = fcall.Dir;

// Access types in namec
pub const Aaccess = 0; // as in stat, wstat
pub const Abind = 1; // for left-hand-side of bind
pub const Atodir = 2; // as in chdir
pub const Aopen = 3; // for i/o
pub const Amount = 4; // to be mounted or mounted upon
pub const Acreate = 5; // is to be created
pub const Aremove = 6; // will be removed by caller
pub const Aunmount = 7; // unmount arg[0]

// channel flags
pub const COPEN = 0x0001; // for i/o
pub const CMSG = 0x0002; // the message channel for a mount
pub const CCEXEC = 0x0008; // close on exec (per file descriptor)
pub const CFREE = 0x0010; // not in use
pub const CRCLOSE = 0x0020; // remove on close
pub const CCACHE = 0x0080; // client cache

pub const Chan = struct {
    ref: Ref = .{},
    lock: Lock = .{},
    next: ?*Chan = null, // allocation
    link: ?*Chan = null,
    offset: i64 = 0, // in fd
    devoffset: i64 = 0, // in underlying device; see read
    type: u16 = 0,
    dev: u32 = 0,
    mode: u16 = 0, // read/write
    flag: u16 = 0,
    qid: Qid = .{},
    fid: i32 = 0, // for devmnt
    iounit: u32 = 0, // chunk size for i/o; 0==default
    umh: ?*Mhead = null, // mount point that derived Chan; used in unionread
    umc: ?*Chan = null, // channel in union; held for union read
    umqlock: QLock = .{}, // serialize unionreads
    uri: i32 = 0, // union read index
    dri: i32 = 0, // devdirread index
    dirrock: ?[]u8 = null, // directory entry rock for translations
    nrock: usize = 0,
    rockqlock: QLock = .{},
    ismtpt: bool = false,
    mcp: ?*Mntcache = null, // Mount cache pointer
    mux: ?*Mnt = null, // Mnt for clients using me for messages
    aux: ?*anyopaque = null,
    mid: u32 = 0, // for ns in devproc (shares storage with aux in the C)
    mchan: ?*Chan = null, // channel to mounted server
    mqid: Qid = .{}, // qid of root of mount point
    path: ?*Path = null,
    srvname: ?[]u8 = null, // /srv/name when posted
};

pub const Path = struct {
    ref: Ref = .{},
    /// The name; `s[0..len]` is in use.  DIFF: not NUL-terminated.
    s: []u8 = &.{},
    mtpt: []?*Chan = &.{}, // mtpt history; mtpt[0..mlen] is in use
    len: usize = 0, // strlen(s)
    mlen: usize = 0, // number of path elements

    pub fn str(p: *const Path) []const u8 {
        return p.s[0..p.len];
    }
};

/// Result of a device walk.
/// DIFF: room for the most names one walk can carry, where the C
/// allocates exactly as many qids as names.
pub const Walkqid = struct {
    clone: ?*Chan = null,
    nqid: usize = 0,
    qid: [fcall.MAXWELEM]Qid = undefined,
};

pub const Mount = struct {
    order: ?*Mount = null, // Pgrp.mntorder chain
    norder: ?*Mount = null, // forward pointer for pgrpcpy()
    next: ?*Mount = null, // Mhead.mount chain
    umh: ?*Mhead = null, // the union we belong to
    to: *Chan, // channel replacing channel
    mflag: u32 = 0,
    /// Stored after the Mount in the same allocation.
    spec: []u8 = &.{},
};

pub const Mhead = struct {
    ref: Ref = .{},
    lock: RWLock = .{},
    from: *Chan, // channel mounted upon
    mount: ?*Mount = null, // what's mounted upon it
    hash: ?*Mhead = null, // Hash chain
};

pub const RENDLOG = 5;
pub const RENDHASH = 1 << RENDLOG; // Hash to lookup rendezvous tags
pub const MNTLOG = 5;
pub const MNTHASH = 1 << MNTLOG; // Hash to walk mount table

pub const Pgrp = struct {
    ref: Ref = .{},
    ns: RWLock = .{}, // Namespace n read/one write lock
    devmask: [256 / 8]u8 = @splat(0), // Room for 256 devices
    mntorder: ?*Mount = null, // Ordered list of mounts
    mntordertail: *?*Mount = undefined,
    mnthash: [MNTHASH]?*Mhead = @splat(null),

    /// MOUNTH in the C: the hash chain for a qid.
    pub fn mounth(pg: *Pgrp, qid: Qid) *?*Mhead {
        return &pg.mnthash[@intCast(qid.path & (MNTHASH - 1))];
    }
};

pub const Rgrp = struct {
    ref: Ref = .{},
    lock: Lock = .{},
    rendhash: [RENDHASH]?*Proc = @splat(null), // Rendezvous tag hash
};

pub const DELTAFD = 20; // incremental increase in Fgrp.fd's

pub const Fgrp = struct {
    ref: Ref = .{},
    lock: Lock = .{},
    /// fd.len is nfd in the C.
    fd: []?*Chan = &.{},
    flag: []u8 = &.{}, // per file-descriptor flags (CCEXEC)
    maxfd: i32 = 0, // highest fd in use
    exceed: i32 = 0, // debugging
};

pub const ENVLOG = 5;
pub const ENVHASH = 1 << ENVLOG; // Egrp hash for variable lookup

pub const Evalue = struct {
    value: []u8 = &.{},
    vers: u32 = 0,
    path: u64 = 0, // qid.path: Egrp.path << 32 | index (of Egrp.ent[])
    hash: ?*Evalue = null,
    /// Stored after the Evalue in the same allocation.
    name: []u8 = &.{},
};

pub const Egrp = struct {
    ref: Ref = .{},
    lock: RWLock = .{},
    ent: []?*Evalue = &.{}, // ent.len is the number of slots
    low: usize = 0, // lowest free index in ent[]
    alloc: usize = 0, // bytes allocated for env
    path: u32 = 0, // generator for qid path
    vers: u32 = 0, // of Egrp
    hash: [ENVHASH]?*Evalue = @splat(null), // hashtable for name lookup
};

pub const DEVDOTDOT = -1;

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

    s: Sargs = .{}, // syscall arguments
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
