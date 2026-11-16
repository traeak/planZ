//! The library's own types and what its files share.
//! from libthread/threadimpl.h
//!
//! Some notes on locking:
//!
//!     All the locking woes come from implementing
//!     threadinterrupt (and threadkill).
//!
//!     getproc().thread is always a live pointer.
//!     p.threads, p.ready, and threadrgrp also contain
//!     live thread pointers.  These may only be consulted
//!     while holding p.lock or threadrgrp.lock; in procs
//!     other than p, the pointers are only guaranteed to be live
//!     while the lock is still being held.
//!
//!     Thread structures can only be freed by the proc
//!     they belong to.  Threads marked with t.inrendez
//!     need to be extracted from the threadrgrp before
//!     being freed.
//!
//!     threadrgrp.lock cannot be acquired while holding p.lock.
//!
//! DIFF:
//!   - A context (the C's jmp_buf) is amd64.zig's Ctx.
//!   - The words another process or a note handler changes under a
//!     running thread (a thread's state and moribund, a proc's splhi
//!     and pending, the exit status of threadexitsall) are read and
//!     written through get and set, the atomic builtins; the C has
//!     plain or volatile ints.
//!   - _threadexitsallstatus, a pointer in C, is the text copied into
//!     a buffer of the library's: the first status given stays.
//!   - No _threaddebug: the debugging prints are left out (debug.c).

const std = @import("std");
const libc = @import("libc");
const amd64 = @import("amd64.zig");
const channel = @import("channel.zig");

pub const Lock = libc.Lock;
pub const lock = libc.lock;
pub const unlock = libc.unlock;
pub const ERRMAX = libc.ERRMAX;

/// A word that another process may change: read it.
pub inline fn get(p: anytype) @typeInfo(@TypeOf(p)).pointer.child {
    return @atomicLoad(@typeInfo(@TypeOf(p)).pointer.child, p, .seq_cst);
}

/// A word that another process may read: write it.
pub inline fn set(p: anytype, v: @typeInfo(@TypeOf(p)).pointer.child) void {
    @atomicStore(@typeInfo(@TypeOf(p)).pointer.child, p, v, .seq_cst);
}

// must match list in sched.c
pub const State = enum(u32) {
    Dead,
    Running,
    Ready,
    Rendezvous,
};

pub const Chanstate = enum(u32) {
    Channone,
    Chanalt,
    Chansend,
    Chanrecv,
};

pub const RENDHASH = 13;

pub const Rgrp = struct {
    lock: Lock = .{},
    hash: [RENDHASH]?*Thread = @splat(null),
};

/// Thread queue
pub const Tqueue = struct {
    asleep: bool = false,
    head: ?*Thread = null,
    tail: *?*Thread = undefined,
};

pub const Thread = struct {
    lock: Lock = .{}, // protects thread data structure
    sched: amd64.Ctx = .{}, // for context switches
    id: i32 = 0, // thread id
    grp: i32 = 0, // thread group
    moribund: bool = false, // thread needs to die
    state: State = .Dead, // run state
    nextstate: State = .Dead, // next run state
    stk: []u8 = &.{}, // the stack, lowest address first
    next: ?*Thread = null, // next on ready queue

    proc: *Proc = undefined, // proc of this thread
    nextt: ?*Thread = null, // next on list of threads in this proc
    ret: i32 = 0, // return value for Exec, Fork

    cmdname: ?[]u8 = null, // name of thread

    inrendez: bool = false,
    rendhash: ?*Thread = null, // Trgrp linked list
    rendtag: usize = 0, // rendezvous tag
    rendval: usize = 0, // rendezvous value
    rendbreak: bool = false, // rendezvous has been taken

    chan: Chanstate = .Channone, // which channel operation is current
    alt: ?[*]channel.Alt = null, // pointer to current alt structure (debugging)

    udata: usize = 0, // User per-thread data pointer
};

pub const Execargs = struct {
    prog: []const u8 = "",
    args: []const []const u8 = &.{},
    fd: [2]i32 = .{ -1, -1 },
};

pub const Proc = struct {
    lock: Lock = .{},
    sched: amd64.Ctx = .{}, // for context switches
    pid: i32 = -1, // process id
    splhi: bool = false, // delay notes
    thread: ?*Thread = null, // running thread

    needexec: bool = false,
    exec: Execargs = .{}, // exec argument
    newproc: ?*Proc = null, // fork argument
    exitstr: [ERRMAX]u8 = @splat(0), // exit status, up to a 0

    rforkflag: u32 = 0,
    nthreads: i32 = 0,
    threads: Tqueue = .{}, // All threads of this proc
    ready: Tqueue = .{}, // Runnable threads
    readylock: Lock = .{},

    pending: bool = false, // delayed note pending
    next: ?*Proc = null, // linked list of Procs

    udata: usize = 0, // User per-proc data pointer
    threadint: bool = false, // tag for threadexitsall()

    pub fn exitmsg(p: *Proc) []u8 {
        return p.exitstr[0 .. std.mem.indexOfScalar(u8, &p.exitstr, 0) orelse ERRMAX - 1];
    }

    pub fn setexitmsg(p: *Proc, s: []const u8) void {
        const n = @min(s.len, ERRMAX - 1);
        std.mem.copyForwards(u8, p.exitstr[0..n], s[0..n]);
        p.exitstr[n] = 0;
    }
};

/// Proc queue
pub const Pqueue = struct {
    lock: Lock = .{},
    head: ?*Proc = null,
    tail: *?*Proc = undefined,
};

/// The word privalloc gave: each process's own Proc.
pub var threadprocp: *usize = undefined;

pub fn getproc() *Proc {
    return @ptrFromInt(threadprocp.*);
}

/// As getproc, where there may be none yet (a note in a new process).
pub fn getprocornull() ?*Proc {
    return @ptrFromInt(threadprocp.*);
}

pub fn setproc(p: *Proc) void {
    threadprocp.* = @intFromPtr(p);
}

// The status threadexitsall was given: 0 none, 1 being written, 2 set.
var exitsallstate: u32 = 0;
var exitsallbuf: [ERRMAX]u8 = undefined;
var exitsalllen: usize = 0;

/// The C's _threadexitsallstatus = s.
pub fn setexitsall(s: []const u8) void {
    if (@cmpxchgStrong(u32, &exitsallstate, 0, 1, .seq_cst, .seq_cst) != null)
        return;
    const n = @min(s.len, ERRMAX - 1);
    std.mem.copyForwards(u8, exitsallbuf[0..n], s[0..n]);
    exitsalllen = n;
    set(&exitsallstate, 2);
}

/// The C's _threadexitsallstatus: null until threadexitsall is called.
pub fn exitsall() ?[]const u8 {
    if (get(&exitsallstate) != 2)
        return null;
    return exitsallbuf[0..exitsalllen];
}
