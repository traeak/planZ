//! from libthread/lib.c
//!
//! DIFF:
//!   - _threadmalloc is create and alloc, which end the program when
//!     there is no memory; no malloc tags and no count of the total.
//!   - _threadsysfatal is given the message already printed (libc's
//!     fatalhook), and a Zig panic goes the same way.

const std = @import("std");
const libc = @import("libc");
const exit = @import("exit.zig");

pub fn create(comptime T: type) *T {
    const p = libc.allocator.create(T) catch libc.sysfatal("Malloc of size %d failed: %r", .{@sizeOf(T)});
    p.* = .{};
    return p;
}

/// A copy of v from the allocator.
pub fn create1(comptime T: type, v: T) *T {
    const p = libc.allocator.create(T) catch libc.sysfatal("Malloc of size %d failed: %r", .{@sizeOf(T)});
    p.* = v;
    return p;
}

pub fn alloc(comptime T: type, n: usize) []T {
    return libc.allocator.alloc(T, n) catch libc.sysfatal("Malloc of size %d failed: %r", .{n * @sizeOf(T)});
}

pub fn threadsysfatal(msg: []const u8) noreturn {
    exit.threadexitsall(msg);
}
