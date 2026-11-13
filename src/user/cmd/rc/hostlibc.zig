//! What rc takes from libc, for its tests on the host.  Not part of rc.
//! The tests run rc's parser, compiler and the instructions that need
//! no system: these give an allocator and refuse the rest (no file
//! opens, no process forks), and the tests never reach them.

const std = @import("std");

pub const allocator = std.heap.smp_allocator;

pub const Error = error{Plan9};

pub const ERRMAX = 128;
pub const OREAD = 0;
pub const OWRITE = 1;
pub const ORDWR = 2;
pub const ORCLOSE = 64;
pub const DMDIR: u32 = 0x80000000;

pub const sys = struct {
    pub const RFNAMEG = 1 << 0;
    pub const RFENVG = 1 << 1;
    pub const RFFDG = 1 << 2;
    pub const RFNOTEG = 1 << 3;
    pub const RFPROC = 1 << 4;
    pub const RFCNAMEG = 1 << 10;
    pub const RFCENVG = 1 << 11;
    pub const RFCFDG = 1 << 12;
    pub const RFREND = 1 << 13;
    pub const RFNOMNT = 1 << 14;
};

pub const Dir = struct { name: []const u8 = "", mode: u32 = 0, length: i64 = 0 };
pub const Dirs = struct {
    dirs: []Dir,
    pub fn deinit(_: *Dirs, _: std.mem.Allocator) void {}
};
pub const Stat = struct {
    dir: Dir,
    pub fn deinit(_: *Stat, _: std.mem.Allocator) void {}
};
pub const Waitmsg = struct {
    pid: i32,
    pub fn msg(_: *const Waitmsg) []const u8 {
        return "";
    }
};

/// What rc wrote to fd 2, for the tests to read.
pub var fd2: std.ArrayList(u8) = .empty;

pub fn write(fd: i32, buf: []const u8) Error!usize {
    if (fd == 2)
        fd2.appendSlice(allocator, buf) catch return error.Plan9;
    return buf.len;
}
pub fn read(_: i32, _: []u8) Error!usize {
    return error.Plan9;
}
pub fn close(_: i32) Error!void {}
pub fn open(_: []const u8, _: u32) Error!i32 {
    return error.Plan9;
}
pub fn create(_: []const u8, _: u32, _: u32) Error!i32 {
    return error.Plan9;
}
pub fn seek(_: i32, _: i64, _: u32) Error!i64 {
    return error.Plan9;
}
pub fn dup(_: i32, _: i32) Error!i32 {
    return error.Plan9;
}
pub fn pipe() Error![2]i32 {
    return error.Plan9;
}
pub fn rfork(_: u32) Error!i32 {
    return error.Plan9;
}
pub fn exec(_: []const u8, _: []const []const u8) Error!void {
    return error.Plan9;
}
pub fn wait() Error!Waitmsg {
    return error.Plan9;
}
pub fn exits(_: ?[]const u8) noreturn {
    @panic("rc exits in a host test");
}
pub fn access(_: []const u8, _: u32) bool {
    return false;
}
pub fn chdir(_: []const u8) Error!void {
    return error.Plan9;
}
pub fn getwd(_: []u8) Error![]const u8 {
    return error.Plan9;
}
pub fn getpid() u32 {
    return 1;
}
pub fn fd2path(_: i32, _: []u8) Error![]const u8 {
    return error.Plan9;
}
pub fn rerrstr(_: []u8) []const u8 {
    return "host test";
}
pub fn dirread(_: std.mem.Allocator, _: i32) Error!Dirs {
    return error.Plan9;
}
pub fn dirstat(_: std.mem.Allocator, _: []const u8) Error!Stat {
    return error.Plan9;
}
pub fn atnotify(_: *const fn (*anyopaque, []const u8) bool, _: bool) bool {
    return true;
}
pub fn strtol32(s: []const u8, base: u32) struct { v: i32, n: usize } {
    _ = base;
    const v = std.fmt.parseInt(i32, s, 10) catch 0;
    return .{ .v = v, .n = s.len };
}
