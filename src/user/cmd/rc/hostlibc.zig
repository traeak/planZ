//! What rc takes from libc, for its tests on the host: an allocator,
//! and I/O that the tests never reach (they read and write string ios).
//! Not part of rc.

const std = @import("std");

pub const allocator = std.heap.smp_allocator;

pub const Error = error{Plan9};

pub fn write(fd: i32, buf: []const u8) Error!usize {
    _ = fd;
    return buf.len;
}

pub fn read(fd: i32, buf: []u8) Error!usize {
    _ = fd;
    _ = buf;
    return error.Plan9;
}

pub fn close(fd: i32) Error!void {
    _ = fd;
}
