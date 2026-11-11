//! What libmemdraw and libmemlayer need from their surroundings: memory
//! and werrstr.  Not from a C file.
//!
//! In the kernel these are port/alloc.zig and up.errstr (the kernel's
//! werrstr, 9/port/sysproc.c).  In a host test build (`zig test`) they
//! are a small allocator over std.testing.allocator, which also checks
//! for leaks and puts guard bytes around every block (checkguards), and
//! nothing.  The choice is made at compile time so that
//! the libraries' own test blocks run on the host without the kernel.

const std = @import("std");
const builtin = @import("builtin");

pub const hosted = builtin.is_test;

const impl = if (hosted) host else @import("../port/alloc.zig");

/// Zeroed memory, or null.
pub const malloc = impl.malloc;
/// Takes any pointer to what malloc returned, a slice of it, or null.
pub const free = impl.free;
/// Zeroed memory for one T, or null.
pub const new = impl.new;
/// Zeroed memory for n Ts, or null.
pub const newslice = impl.newslice;

/// Host tests only: is every live block's surrounding guard intact,
/// and how many blocks are live.
pub const checkguards = if (hosted) host.checkguards else {};
pub const livecount = if (hosted) host.count else {};
/// Host tests only, and only while nothing is allocated: see host.
pub fn setpageguard(on: bool) void {
    if (hosted and builtin.os.tag == .linux)
        host.pageguard = on;
}

/// Set the error string of the current process.
pub fn werrstr(comptime format: []const u8, args: anytype) void {
    if (hosted) return;
    if (@import("../arch.zig").up() == null) return;
    _ = @import("../port/proc.zig").errorf(format, args) catch {};
}

const host = struct {
    // Every block has guard bytes before and after it, and the live
    // blocks are on a list, so that a test can ask at any moment
    // whether something wrote outside its memory (checkguards); free
    // checks the block it is given.
    const guard = 64;
    const gbyte = 0xA5;
    const Hdr = struct {
        size: usize, // of the whole allocation
        user: usize, // bytes the caller asked for
        prev: ?*Hdr,
        next: ?*Hdr,
    };
    const hdr = @sizeOf(Hdr) + guard;
    var live: ?*Hdr = null;
    var nlive: usize = 0;

    comptime {
        if (hdr % 16 != 0) @compileError("host.hdr must keep the alignment");
    }

    fn intact(h: *Hdr) bool {
        const b: [*]u8 = @ptrCast(h);
        for (b[@sizeOf(Hdr)..hdr]) |c| {
            if (c != gbyte) return false;
        }
        for (b[hdr + h.user .. h.size]) |c| {
            if (c != gbyte) return false;
        }
        return true;
    }

    /// True when no live block has been written outside its bounds.
    pub fn checkguards() bool {
        var h = live;
        while (h) |x| : (h = x.next) {
            if (!intact(x)) return false;
        }
        return true;
    }

    /// Number of live blocks.
    pub fn count() usize {
        return nlive;
    }

    /// When set (Linux only; the fuzz test's FUZZ_PAGEGUARD), every
    /// block gets pages of its own with an inaccessible page on either
    /// side, and sits against one of them: its end, or with every
    /// other block its start.  Reading a single byte past that end of
    /// a block then faults, as does any use of a freed block.  Only
    /// the count of live blocks is kept in this mode.
    pub var pageguard = false;
    const page = 4096;
    var flip = false;

    const Pagehdr = struct { base: usize, len: usize };

    fn pagemalloc(size: usize) ?[*]u8 {
        const linux = std.os.linux;
        const size16 = (size + 15) & ~@as(usize, 15);
        const data = @max(page, (size16 + 16 + page - 1) & ~@as(usize, page - 1));
        const len = page + page + data + page; // header, guard, data, guard
        const rc = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (linux.errno(rc) != .SUCCESS)
            return null;
        const base: [*]u8 = @ptrFromInt(rc);
        _ = linux.mprotect(base + page, page, .{});
        _ = linux.mprotect(base + 2 * page + data, page, .{});
        @as(*Pagehdr, @ptrCast(@alignCast(base))).* = .{ .base = rc, .len = len };
        flip = !flip;
        var p = base + 2 * page;
        if (flip and size16 % page != 0) {
            p += data - size16;
            @as(*usize, @ptrCast(@alignCast(p - 8))).* = rc;
        }
        nlive += 1;
        return p;
    }

    fn pagefree(addr: usize) void {
        const linux = std.os.linux;
        const base: usize = if (addr % page == 0)
            addr - 2 * page
        else
            @as(*usize, @ptrFromInt(addr - 8)).*;
        const h: *Pagehdr = @ptrFromInt(base);
        if (h.base != base)
            @panic("libmemdraw host allocator: bad free");
        nlive -= 1;
        _ = linux.munmap(@ptrFromInt(base), h.len);
    }

    pub fn malloc(size: usize) ?[*]u8 {
        if (pageguard)
            return pagemalloc(size);
        const b = std.testing.allocator.alignedAlloc(u8, .@"16", size + hdr + guard) catch return null;
        @memset(b[0..hdr], gbyte);
        @memset(b[hdr..][0..size], 0);
        @memset(b[hdr + size ..], gbyte);
        const h: *Hdr = @ptrCast(b.ptr);
        h.* = .{ .size = b.len, .user = size, .prev = null, .next = live };
        if (live) |l| l.prev = h;
        live = h;
        nlive += 1;
        return b.ptr + hdr;
    }

    pub fn free(v: anytype) void {
        const T = @TypeOf(v);
        const addr: usize = switch (@typeInfo(T)) {
            .pointer => |pi| if (pi.size == .slice) @intFromPtr(v.ptr) else @intFromPtr(v),
            .optional => if (v) |x| @intFromPtr(x) else 0,
            .null => 0,
            else => @compileError("free: not a pointer: " ++ @typeName(T)),
        };
        if (addr == 0) return;
        if (pageguard)
            return pagefree(addr);
        const p: [*]align(16) u8 = @ptrFromInt(addr - hdr);
        const h: *Hdr = @ptrCast(p);
        if (!intact(h))
            @panic("libmemdraw host allocator: write outside a block");
        if (h.prev) |x| x.next = h.next else live = h.next;
        if (h.next) |x| x.prev = h.prev;
        nlive -= 1;
        std.testing.allocator.free(p[0..h.size]);
    }

    pub fn new(comptime T: type) ?*T {
        return @ptrCast(@alignCast(host.malloc(@sizeOf(T)) orelse return null));
    }

    pub fn newslice(comptime T: type, n: usize) ?[]T {
        const p: [*]T = @ptrCast(@alignCast(host.malloc(n * @sizeOf(T)) orelse return null));
        return p[0..n];
    }
};
