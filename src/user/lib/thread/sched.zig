//! The scheduler: each proc's loop, and the switch between it and its
//! threads.
//! from libthread/sched.c
//!
//! DIFF:
//!   - The C's _sched is both halves of a switch, told apart by
//!     whether the proc has a running thread; and _schedinit, on the
//!     proc's own stack, is entered again at its setjmp each time a
//!     thread gives up the processor.  Here sched is the thread's
//!     half and schedproc the proc's, around amd64.zig's swtch, and
//!     schedinit is a loop: schedproc returns into it when the thread
//!     it ran switches back.  A thread found moribund when it is
//!     picked goes back to the loop without being entered, as in C.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const impl = @import("impl.zig");
const amd64 = @import("amd64.zig");
const create = @import("create.zig");
const main = @import("main.zig");
const rendez = @import("rendez.zig");

const Proc = impl.Proc;
const Thread = impl.Thread;
const lock = impl.lock;
const unlock = impl.unlock;
const get = impl.get;
const set = impl.set;

fn unlinkproc(p: *Proc) void {
    lock(&create.threadpq.lock);
    var l: *?*Proc = &create.threadpq.head;
    while (l.*) |q| : (l = &q.next) {
        if (q == p) {
            l.* = p.next;
            if (l.* == null)
                create.threadpq.tail = l;
            break;
        }
    }
    unlock(&create.threadpq.lock);
}

pub fn schedinit() callconv(.c) noreturn {
    const p = impl.getproc();
    p.pid = @intCast(libc.getpid());
    while (true) {
        if (impl.exitsall()) |s|
            libc.exits(s);
        lock(&p.lock);
        if (p.thread) |t| {
            p.thread = null;
            if (get(&t.moribund)) {
                set(&t.state, .Dead);
                var l: *?*Thread = &p.threads.head;
                while (l.*) |x| : (l = &x.nextt) {
                    if (x == t) {
                        l.* = t.nextt;
                        if (l.* == null)
                            p.threads.tail = l;
                        p.nthreads -= 1;
                        break;
                    }
                }
                unlock(&p.lock);
                if (t.inrendez) {
                    rendez.threadflagrendez(t);
                    rendez.threadbreakrendez();
                }
                libc.allocator.free(t.stk);
                if (t.cmdname) |n|
                    libc.allocator.free(n);
                libc.allocator.destroy(t); // XXX how do we know there are no references?
                schedproc(p);
                continue;
            }
            if (p.needexec) {
                t.ret = main.schedexec(&p.exec);
                p.needexec = false;
            }
            if (p.newproc) |np| {
                const x = np.threads.head.?;
                if (get(&x.moribund)) {
                    x.proc = p;
                    threadready(x);
                    unlinkproc(np);
                    libc.allocator.destroy(np);
                    p.newproc = null;
                } else if (main.schedfork(np) != -1)
                    p.newproc = null;
            }
            const ns = t.nextstate;
            set(&t.state, ns);
            if (ns == .Ready)
                threadready(t);
        }
        unlock(&p.lock);
        schedproc(p);
    }
}

/// Fail if the running thread has fewer than n bytes of stack left.
pub fn needstack(n: usize) void {
    var x: u8 = 0;
    const p = impl.getproc();
    const t = p.thread.?;

    if (@intFromPtr(&x) -% n < @intFromPtr(t.stk.ptr)) {
        libc.fprint(2, "%s %ud: &x=%p n=%d t->stk=%p\n", .{ libc.argv0, @as(u32, @bitCast(p.pid)), @intFromPtr(&x), n, @intFromPtr(t.stk.ptr) });
        libc.fprint(2, "%s %ud: stack overflow\n", .{ libc.argv0, @as(u32, @bitCast(p.pid)) });
        sys.exits("abort");
    }
}

fn runthread(p: *Proc) ?*Thread {
    if (p.nthreads == 0)
        return null;
    const q = &p.ready;
    lock(&p.readylock);
    if (q.head == null) {
        q.asleep = true;
        unlock(&p.readylock);
        while (sys.rendezvous(@intFromPtr(q), 0) == ~@as(usize, 0)) {
            if (impl.exitsall()) |s|
                libc.exits(s);
        }
        // lock picked up from threadready
    }
    const t = q.head.?;
    q.head = t.next;
    unlock(&p.readylock);
    return t;
}

/// Give up the processor: the running thread's half of the C's _sched.
/// Returns when the thread is run again.
pub fn sched() void {
    const p = impl.getproc();
    const t = p.thread.?;
    needstack(128);
    amd64.swtch(&t.sched, &p.sched);
}

/// The proc's half: run the next ready thread until it gives up the
/// processor.  With no thread left the proc exits.
fn schedproc(p: *Proc) void {
    const t = runthread(p) orelse {
        unlinkproc(p);
        main.schedexit(p); // frees proc
    };
    p.thread = t;
    if (get(&t.moribund))
        return;
    set(&t.state, .Running);
    t.nextstate = .Ready;
    amd64.swtch(&p.sched, &t.sched);
}

pub fn threadready(t: *Thread) void {
    std.debug.assert(get(&t.state) == .Ready);
    const q = &t.proc.ready;
    lock(&t.proc.readylock);
    t.next = null;
    if (q.head == null)
        q.head = t
    else
        q.tail.* = t;
    q.tail = &t.next;
    if (q.asleep) {
        q.asleep = false;
        // lock passes to runthread
        while (sys.rendezvous(@intFromPtr(q), 0) == ~@as(usize, 0)) {
            if (impl.exitsall()) |s|
                libc.exits(s);
        }
    } else unlock(&t.proc.readylock);
}

pub fn yield() void {
    sched();
}
