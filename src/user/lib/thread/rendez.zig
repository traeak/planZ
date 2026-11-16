//! Rendezvous between threads, in this proc or another: what the
//! channels and, through qlockinit, libc's QLock and Rendez sleep in.
//! from libthread/rendez.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const impl = @import("impl.zig");
const sched = @import("sched.zig");

const Thread = impl.Thread;
const lock = impl.lock;
const unlock = impl.unlock;
const get = impl.get;
const set = impl.set;

pub var threadrgrp: impl.Rgrp = .{};
var isdirty: bool = false;

/// What a rendezvous returns when it was broken off (threadint).
pub const Intred = ~@as(usize, 0);

fn finish(t: *Thread, val: usize) usize {
    const ret = t.rendval;
    t.rendval = val;
    while (get(&t.state) == .Running)
        _ = sys.sleep(0);
    lock(&t.proc.lock);
    if (get(&t.state) == .Rendezvous) { // not always true: might be Dead
        set(&t.state, .Ready);
        sched.threadready(t);
    }
    unlock(&t.proc.lock);
    return ret;
}

pub fn threadrendezvous(tag: usize, val: usize) usize {
    lock(&threadrgrp.lock);
    var l: *?*Thread = &threadrgrp.hash[tag % impl.RENDHASH];
    while (l.*) |t| : (l = &t.rendhash) {
        if (t.rendtag == tag) {
            l.* = t.rendhash;
            const ret = finish(t, val);
            unlock(&threadrgrp.lock);
            return ret;
        }
    }

    // Going to sleep here.
    const t = impl.getproc().thread.?;
    t.rendbreak = false;
    t.inrendez = true;
    t.rendtag = tag;
    t.rendval = val;
    t.rendhash = l.*;
    l.* = t;
    t.nextstate = .Rendezvous;
    unlock(&threadrgrp.lock);
    sched.sched();
    t.inrendez = false;
    return t.rendval;
}

/// This is called while holding threadpq.lock and p.lock,
/// so we can't lock threadrgrp.lock.  Instead our caller has
/// to call threadbreakrendez after dropping those locks.
pub fn threadflagrendez(t: *Thread) void {
    t.rendbreak = true;
    set(&isdirty, true);
}

pub fn threadbreakrendez() void {
    if (!get(&isdirty))
        return;
    lock(&threadrgrp.lock);
    if (!get(&isdirty)) {
        unlock(&threadrgrp.lock);
        return;
    }
    set(&isdirty, false);
    for (&threadrgrp.hash) |*h| {
        var l: *?*Thread = h;
        while (l.*) |t| {
            if (t.rendbreak) {
                l.* = t.rendhash;
                _ = finish(t, Intred);
            } else l = &t.rendhash;
        }
    }
    unlock(&threadrgrp.lock);
}
