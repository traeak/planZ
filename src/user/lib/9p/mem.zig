//! from lib9p/mem.c
//!
//! DIFF:
//!   - emalloc9p and erealloc9p give and take slices of bytes; create9p
//!     is emalloc9p(sizeof *p) for a structure, set to its defaults.

const std = @import("std");
const libc = @import("libc");

pub fn emalloc9p(sz: usize) []u8 {
    const v = libc.allocator.alloc(u8, sz) catch
        libc.sysfatal("out of memory allocating %d", .{sz});
    @memset(v, 0);
    return v;
}

pub fn erealloc9p(v: anytype, n: usize) @TypeOf(v) {
    return libc.allocator.realloc(v, n) catch
        libc.sysfatal("out of memory allocating %d", .{n * @sizeOf(@typeInfo(@TypeOf(v)).pointer.child)});
}

pub fn estrdup9p(s: []const u8) []u8 {
    return libc.allocator.dupe(u8, s) catch
        libc.sysfatal("out of memory in strdup(%.10s)", .{s});
}

pub fn create9p(comptime T: type) *T {
    const p = libc.allocator.create(T) catch
        libc.sysfatal("out of memory allocating %d", .{@sizeOf(T)});
    p.* = .{};
    return p;
}
