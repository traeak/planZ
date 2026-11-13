//! rc's system interface for Plan 9.
//! from cmd/rc/plan9.c
//!
//! In progress: so far the I/O and the prompt.

const std = @import("std");
const rc = @import("rc.zig");
const io = @import("io.zig");
const exec = @import("exec.zig");
const libc = rc.libc;

pub fn Write(fd: i32, buf: []const u8) i64 {
    const n = libc.write(fd, buf) catch return -1;
    return @intCast(n);
}

pub fn Read(fd: i32, buf: []u8) i64 {
    const n = libc.read(fd, buf) catch return -1;
    return @intCast(n);
}

pub fn Close(fd: i32) void {
    libc.close(fd) catch {};
}

/// abort: fault, as 9front's abort does by reading address 0.
pub fn Abort() noreturn {
    const p: *allowzero volatile i32 = @ptrFromInt(0);
    while (p.* != 0) {}
    unreachable;
}

var newwdir = false;

pub fn Prompt(s: []const u8) void {
    io.pstr(exec.err, s);
    io.flushio(exec.err);

    if (newwdir) {
        // the working directory goes to /dev/wdir: with Chdir, later
        newwdir = false;
    }
}
