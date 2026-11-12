//! Directory entries: stat and wstat by name and by descriptor, and
//! reading a directory.
//! from libc/9sys/dirstat.c, dirfstat.c, dirwstat.c, dirfwstat.c,
//! dirread.c and nulldir.c
//!
//! DIFF:
//!   - Memory comes from the allocator passed in, and the results own
//!     it: dirstat returns a Stat (the Dir and the buffer its strings
//!     point into) and dirread a Dirs (the entries and their strings),
//!     each with a deinit.  The C returns one malloc'd block.
//!   - Errors are error.Plan9 (with the kernel's message in the error
//!     string) or error.OutOfMemory; a malformed reply from the kernel
//!     is error.Plan9 with "bad stat buffer" set.
//!   - dirread's return of 0 at the end of the directory is a Dirs
//!     with no entries.

const std = @import("std");
const fcall = @import("fcall");
const sys = @import("sys.zig");
const libc = @import("libc.zig");

const Allocator = std.mem.Allocator;
const Dir = fcall.Dir;
const BIT16SZ = fcall.BIT16SZ;
const STATFIXLEN = fcall.STATFIXLEN;

/// enough for encoded stat buf + some reasonable strings
const DIRSIZE = STATFIXLEN + 16 * 4;
/// max length of an entire directory read
const DIRMAX = @sizeOf(Dir) + fcall.STATMAX;

pub const Error = libc.Error || Allocator.Error;

/// One file's Dir and the memory its strings are in.
pub const Stat = struct {
    dir: Dir,
    buf: []u8,

    pub fn deinit(self: *Stat, a: Allocator) void {
        a.free(self.buf);
        self.* = undefined;
    }
};

/// A directory's entries and the memory their strings are in.
pub const Dirs = struct {
    dirs: []Dir,
    strs: []u8,

    pub fn deinit(self: *Dirs, a: Allocator) void {
        a.free(self.dirs);
        a.free(self.strs);
        self.* = undefined;
    }
};

fn gbit16(b: []const u8) usize {
    return std.mem.readInt(u16, b[0..2], .little);
}

fn badstat() Error {
    libc.werrstr("bad stat buffer", .{});
    return error.Plan9;
}

const Statfn = struct {
    ctx: union(enum) { name: []const u8, fd: i32 },

    fn call(self: Statfn, buf: []u8) Error!isize {
        return switch (self.ctx) {
            .name => |n| blk: {
                var c: libc.Cstr = .{};
                defer c.deinit();
                break :blk sys.stat(try c.z(n), buf);
            },
            .fd => |fd| sys.fstat(fd, buf),
        };
    }
};

fn statgen(a: Allocator, f: Statfn) Error!Stat {
    var nd: usize = DIRSIZE;
    for (0..2) |_| { // should work by the second try
        const buf = try a.alloc(u8, BIT16SZ + nd);
        const r = f.call(buf) catch |e| {
            a.free(buf);
            return e;
        };
        if (r < BIT16SZ) {
            a.free(buf);
            if (r < 0)
                return error.Plan9;
            return badstat();
        }
        const n: usize = @intCast(r);
        nd = gbit16(buf); // upper bound on size of Dir + strings
        if (nd <= n) {
            // The strings go in the same buffer, after the reply; a
            // stat's strings are shorter than the reply.
            var st: Stat = .{ .dir = .{}, .buf = buf };
            const strs = a.alloc(u8, n) catch |e| {
                a.free(buf);
                return e;
            };
            if (fcall.convM2D(buf[0..n], &st.dir, strs) == 0) {
                a.free(strs);
                a.free(buf);
                return badstat();
            }
            a.free(buf);
            st.buf = strs;
            return st;
        }
        // else BIT16SZ+nd is plenty
        a.free(buf);
    }
    return badstat();
}

pub fn dirstat(a: Allocator, name: []const u8) Error!Stat {
    return statgen(a, .{ .ctx = .{ .name = name } });
}

pub fn dirfstat(a: Allocator, fd: i32) Error!Stat {
    return statgen(a, .{ .ctx = .{ .fd = fd } });
}

fn wstatgen(d: *const Dir, name: ?[]const u8, fd: i32) Error!void {
    const a = libc.allocator;
    const buf = try a.alloc(u8, fcall.sizeD2M(d));
    defer a.free(buf);
    const r = fcall.convD2M(d, buf);
    if (r <= BIT16SZ)
        return badstat();
    var c: libc.Cstr = .{};
    defer c.deinit();
    const rv = if (name) |n| sys.wstat(try c.z(n), buf[0..r]) else sys.fwstat(fd, buf[0..r]);
    if (rv < 0)
        return error.Plan9;
}

pub fn dirwstat(name: []const u8, d: *const Dir) Error!void {
    return wstatgen(d, name, -1);
}

pub fn dirfwstat(fd: i32, d: *const Dir) Error!void {
    return wstatgen(d, null, fd);
}

/// A Dir that changes nothing when given to wstat.
pub fn nulldir() Dir {
    return .{
        .type = ~@as(u16, 0),
        .dev = ~@as(u32, 0),
        .qid = .{ .path = ~@as(u64, 0), .vers = ~@as(u32, 0), .type = ~@as(u8, 0) },
        .mode = ~@as(u32, 0),
        .atime = ~@as(u32, 0),
        .mtime = ~@as(u32, 0),
        .length = -1,
        .name = "",
        .uid = "",
        .gid = "",
        .muid = "",
    };
}

fn dirpackage(a: Allocator, buf: []const u8) Error!Dirs {
    // first find number of all stats, check they look like stats, & size all associated strings
    var n: usize = 0;
    var i: usize = 0;
    while (i < buf.len) {
        if (i + BIT16SZ >= buf.len)
            return badstat();
        const m = BIT16SZ + gbit16(buf[i..]);
        if (i + m > buf.len or fcall.statcheck(buf[i..][0..m]) < 0)
            return badstat();
        n += 1;
        i += m;
    }

    const dirs = try a.alloc(Dir, n);
    errdefer a.free(dirs);
    const strs = try a.alloc(u8, buf.len);
    errdefer a.free(strs);

    // then convert all buffers
    var s: usize = 0;
    var nn: usize = 0;
    i = 0;
    while (i < buf.len) {
        const m = BIT16SZ + gbit16(buf[i..]);
        if (i + m > buf.len or nn >= n or fcall.convM2D(buf[i..][0..m], &dirs[nn], strs[s..][0..m]) != m)
            return badstat();
        nn += 1;
        s += m;
        i += m;
    }

    return .{ .dirs = dirs, .strs = strs };
}

/// The entries one read of the directory gives; none at its end.
pub fn dirread(a: Allocator, fd: i32) Error!Dirs {
    const buf = try a.alloc(u8, DIRMAX);
    defer a.free(buf);
    const ts = sys.read(fd, buf);
    if (ts < 0)
        return error.Plan9;
    if (ts == 0)
        return .{ .dirs = &.{}, .strs = &.{} };
    return dirpackage(a, buf[0..@intCast(ts)]);
}

/// All the entries of the directory.
pub fn dirreadall(a: Allocator, fd: i32) Error!Dirs {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var n: isize = 0;
    while (true) {
        try buf.ensureUnusedCapacity(a, DIRMAX);
        n = sys.read(fd, buf.unusedCapacitySlice()[0..DIRMAX]);
        if (n <= 0)
            break;
        buf.items.len += @intCast(n);
    }
    if (buf.items.len == 0) {
        if (n < 0)
            return error.Plan9;
        return .{ .dirs = &.{}, .strs = &.{} };
    }
    return dirpackage(a, buf.items);
}
