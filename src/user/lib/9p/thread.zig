//! The forms for programs of the thread library: the server's
//! processes are procs.
//! from lib9p/thread.c, threadsrv.c, threadpostsrv.c,
//! threadpostmountsrv.c, threadpostsharesrv.c
//! (threadlistensrv.c waits for listen.c)

const std = @import("std");
const libc = @import("libc");
const thread = @import("thread");
const p9 = @import("lib9p.zig");

const Srv = p9.Srv;

const Call = struct {
    f: *const fn (*Srv) void = undefined,
    arg: *Srv = undefined,
};

fn run(c: *Call) void {
    const call = c.*;
    libc.allocator.destroy(c);
    call.f(call.arg);
}

pub fn threadsrvforker(f: *const fn (*Srv) void, arg: *Srv, rflag: u32) void {
    // DIFF: the function and its argument go to the new proc in a
    // small block, since a proc's function is known when compiled
    const c = p9.create9p(Call);
    c.* = .{ .f = f, .arg = arg };
    _ = thread.procrfork(run, c, 32 * 1024, rflag);
}

pub fn threadsrv(s: *Srv) void {
    if (s.forker == null)
        s.forker = threadsrvforker;
    p9.srv(s);
}

pub fn threadpostsrv(s: *Srv, name: ?[]const u8) libc.Error!i32 {
    if (s.forker == null)
        s.forker = threadsrvforker;
    return p9.postsrv(s, name);
}

pub fn threadpostmountsrv(s: *Srv, name: ?[]const u8, mtpt: ?[]const u8, flag: u32) void {
    if (s.forker == null)
        s.forker = threadsrvforker;
    p9.postmountsrv(s, name, mtpt, flag);
}

pub fn threadpostsharesrv(s: *Srv, name: ?[]const u8, mtpt: ?[]const u8, desc: ?[]const u8) void {
    if (s.forker == null)
        s.forker = threadsrvforker;
    p9.postsharesrv(s, name, mtpt, desc);
}
