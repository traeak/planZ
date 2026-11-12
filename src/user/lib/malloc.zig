//! Memory: 9front's pool allocator over brk, and a std.mem.Allocator
//! on top of it.
//! from libc/port/malloc.c and libc/9sys/sbrk.c
//!
//! The pool is the kernel's (src/kernel/port/pool.zig, a port of
//! libc/port/pool.c), given to user programs as the module "pool".
//!
//! DIFF:
//!   - No malloc tags (the C's two extra words per block, Npadlong) and
//!     no setmalloctag/getmalloctag.
//!   - The lock is a spin lock that sleeps after spinning a while, as
//!     libc's lock does, but without its pid checks in plock/punlock.
//!   - pprint writes to standard error; MALLOCFD is not looked at.
//!   - ppanic prints and exits; the C aborts (a fault).
//!   - The pool's 8-byte alignment is enough for malloc; allocator asks
//!     poolallocalign for larger alignments.

const std = @import("std");
const pool = @import("pool");
const sys = @import("sys.zig");

extern var end: u8;
var bloc: usize = 0;

const Round = 7;

/// Set the end of the data segment.
pub fn brk(p: usize) bool {
    const bl = (p + Round) & ~@as(usize, Round);
    if (sys.brk_(bl) < 0)
        return false;
    bloc = bl;
    return true;
}

/// Grow the data segment by n bytes; returns the old end, or null.
pub fn sbrk(n: usize) ?[*]u8 {
    if (bloc == 0)
        bloc = @intFromPtr(&end);
    const bl = (bloc + Round) & ~@as(usize, Round);
    if (sys.brk_(bl + n) < 0)
        return null;
    bloc = bl + n;
    return @ptrFromInt(bl);
}

const Lock = struct {
    val: u32 = 0,
};

fn lock(l: *Lock) void {
    var i: u32 = 0;
    while (@atomicRmw(u32, &l.val, .Xchg, 1, .acquire) != 0) {
        i += 1;
        if (i < 1000)
            std.atomic.spinLoopHint()
        else
            _ = sys.sleep(0);
    }
}

fn unlock(l: *Lock) void {
    @atomicStore(u32, &l.val, 0, .release);
}

var sbrklock: Lock = .{};

var sbrkmem: pool.Pool = .{
    .name = "sbrkmem",
    .maxsize = std.math.maxInt(isize), // maximum signed size we can address
    .minarena = 4 * 1024,
    .quantum = 32,
    .alloc = sbrkalloc,
    .merge = sbrkmerge,
    .flags = 0,

    .lock = plock,
    .unlock = punlock,
    .print = pprint,
    .panic = ppanic,
};

pub const mainmem = &sbrkmem;

/// we do minimal bookkeeping so we can tell pool
/// whether two blocks are adjacent and thus mergeable.
fn sbrkalloc(n_: usize) ?*anyopaque {
    const n = n_ + 2 * @sizeOf(u32); // two longs for us
    if (n > std.math.maxInt(u32))
        return null;
    const x: [*]u32 = @ptrCast(@alignCast(sbrk(n) orelse return null));
    x[0] = @intCast((n + 7) & ~@as(usize, 7)); // sbrk rounds size up to mult. of 8
    x[1] = 0xDeadBeef;
    return x + 2;
}

fn sbrkmerge(x: *anyopaque, y: *anyopaque) bool {
    const lx: [*]u32 = @ptrCast(@alignCast(x));
    const ly: [*]u32 = @ptrCast(@alignCast(y));
    const hx = lx - 2;
    if (hx[1] != 0xDeadBeef)
        sys.exits("sbrkmerge: bad block");

    if (@intFromPtr(x) + hx[0] == @intFromPtr(y)) {
        hx[0] += (ly - 2)[0];
        return true;
    }
    return false;
}

fn plock(_: *pool.Pool) void {
    lock(&sbrklock);
}

fn punlock(_: *pool.Pool) void {
    unlock(&sbrklock);
}

fn pprint(_: *pool.Pool, s: []const u8) void {
    _ = sys.write(2, s);
}

fn ppanic(_: *pool.Pool, s: []const u8) noreturn {
    _ = sys.write(2, s);
    _ = sys.write(2, "\n");
    sys.exits("pool panic");
}

pub fn malloc(size: usize) ?[*]u8 {
    return pool.poolalloc(mainmem, size);
}

pub fn mallocz(size: usize, clr: bool) ?[*]u8 {
    const v = malloc(size) orelse return null;
    if (clr)
        @memset(v[0..size], 0);
    return v;
}

pub fn realloc(v: ?*anyopaque, size: usize) ?[*]u8 {
    return pool.poolrealloc(mainmem, v, size);
}

pub fn free(v: ?*anyopaque) void {
    pool.poolfree(mainmem, v);
}

pub fn msize(v: *anyopaque) usize {
    return pool.poolmsize(mainmem, v);
}

const Alignment = std.mem.Alignment;

fn zalloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const a = alignment.toByteUnits();
    if (a <= 8)
        return pool.poolalloc(mainmem, len);
    return pool.poolallocalign(mainmem, len, a, 0, 0);
}

fn zresize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    return new_len <= pool.poolmsize(mainmem, memory.ptr);
}

fn zremap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (new_len <= pool.poolmsize(mainmem, memory.ptr))
        return memory.ptr;
    // poolrealloc would lose a larger alignment
    if (alignment.toByteUnits() > 8)
        return null;
    return pool.poolrealloc(mainmem, memory.ptr, new_len);
}

fn zfree(_: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    pool.poolfree(mainmem, memory.ptr);
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = zalloc,
    .resize = zresize,
    .remap = zremap,
    .free = zfree,
};

/// The program's memory, for std's containers and for the library's
/// own allocations.
pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };
