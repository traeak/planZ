//! from libthread/create.c
//!
//! DIFF:
//!   - A stack is at least Minstack bytes whatever is asked for.  The
//!     C's programs ask for 1K to 8K, which holds 6c's frames; Zig's
//!     are larger, a note is delivered on the stack of the thread it
//!     finds running (the kernel's frame for it alone is 0.5K), and a
//!     stack that overflows writes over the allocator's memory.  The C
//!     refuses less than 32 bytes.

const std = @import("std");
const libc = @import("libc");
const impl = @import("impl.zig");
const amd64 = @import("amd64.zig");
const sched = @import("sched.zig");
const lib = @import("lib.zig");
const id_ = @import("id.zig");

const Proc = impl.Proc;
const Thread = impl.Thread;
const lock = impl.lock;
const unlock = impl.unlock;

pub const Minstack = 16 * 1024;

pub var threadpq: impl.Pqueue = .{};

var idlock: impl.Lock = .{};
var lastid: i32 = 0;

fn nextID() i32 {
    lock(&idlock);
    lastid += 1;
    const i = lastid;
    unlock(&idlock);
    return i;
}

/// Create and initialize a new Thread structure attached to a given proc.
fn newthread(p: *Proc, f: amd64.Threadfn, arg: usize, stacksize: usize, name: ?[]const u8, grp: i32) i32 {
    const t = lib.create(Thread);
    t.stk = lib.alloc(u8, @max(stacksize, Minstack));
    @memset(t.stk, 0xFE);
    amd64.threadinitstack(t, f, arg);
    t.grp = grp;
    if (name) |n|
        t.cmdname = libc.allocator.dupe(u8, n) catch null;
    t.id = nextID();
    const id = t.id;
    t.next = null;
    t.proc = p;
    lock(&p.lock);
    p.nthreads += 1;
    if (p.threads.head == null)
        p.threads.head = t
    else
        p.threads.tail.* = t;
    p.threads.tail = &t.nextt;
    t.nextt = null;
    impl.set(&t.state, .Ready);
    sched.threadready(t);
    unlock(&p.lock);
    return id;
}

/// Create a new thread and schedule it to run.
/// The thread grp is inherited from the currently running thread.
pub fn threadcreate(f: amd64.Threadfn, arg: usize, stacksize: usize) i32 {
    return newthread(impl.getproc(), f, arg, stacksize, null, id_.threadgetgrp());
}

/// Create and initialize a new Proc structure with a single Thread
/// running inside it.  Add the Proc to the global process list.
pub fn newproc(f: amd64.Threadfn, arg: usize, stacksize: usize, name: ?[]const u8, grp: i32, rforkflag: u32) *Proc {
    const p = lib.create(Proc);
    p.pid = -1;
    p.rforkflag = rforkflag;
    _ = newthread(p, f, arg, stacksize, name, grp);

    lock(&threadpq.lock);
    if (threadpq.head == null)
        threadpq.head = p
    else
        threadpq.tail.* = p;
    threadpq.tail = &p.next;
    unlock(&threadpq.lock);
    return p;
}

pub fn procrfork(f: amd64.Threadfn, arg: usize, stacksize: usize, rforkflag: u32) i32 {
    const p = impl.getproc();
    while (p.newproc != null)
        sched.sched();
    const np = newproc(f, arg, stacksize, null, p.thread.?.grp, rforkflag);
    p.newproc = np;
    const id = np.threads.head.?.id;
    sched.sched();
    return id;
}

pub fn proccreate(f: amd64.Threadfn, arg: usize, stacksize: usize) i32 {
    return procrfork(f, arg, stacksize, 0);
}
