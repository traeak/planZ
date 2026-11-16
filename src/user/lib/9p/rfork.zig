//! from lib9p/rfork.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const p9 = @import("lib9p.zig");

/// The forker of a program without threads: a process that shares
/// memory.  Not to be called from a thread of the thread library,
/// whose stack the two processes would share (threadsrvforker is for
/// those programs).
pub fn srvforker(f: *const fn (*p9.Srv) void, arg: *p9.Srv, flag: u32) void {
    const pid = sys.rfork(sys.RFPROC | sys.RFMEM | sys.RFNOWAIT | flag);
    if (pid < 0)
        libc.sysfatal("rfork: %r", .{});
    if (pid == 0) {
        f(arg);
        sys.exits(null);
    }
}
