//! The kernel's general allocator: malloc, free and friends, on three
//! pools (pool.zig) whose arenas come from xalloc.
//! from 9/port/alloc.c
//!
//! DIFF:
//!   - Alignment.  malloc, mallocz, smalloc, realloc and secalloc
//!     return memory aligned to 16; in C on amd64 it is 8.  `new` and
//!     the std.mem.Allocator interface below rely on it.  It takes no
//!     change to the pool: a block is 8 bytes of header (Bhdr), then
//!     the data; the kernel puts its Npadlong = 2 tag words of 4 bytes
//!     in front of what the caller gets, so the caller's pointer is 16
//!     bytes past the start of the block, and blocks start on
//!     multiples of 16 when (1) arenas do, which xalloc.zig now
//!     guarantees, (2) the arena header is a multiple of 16 (it is
//!     32), (3) the quantum is (it is 32) and (4) the pool never
//!     compacts, that is, has no move hook.  The last block of an
//!     arena is 24 bytes more than a multiple of the quantum, because
//!     the arena's tail takes 8; nothing follows it until arenamerge
//!     joins the next arena on, and that grows the block to a
//!     multiple of 16.  Compaction would pack blocks behind it.  The
//!     comptime check below and poolxalloc hold the first three
//!     conditions, malloc0 checks what comes of them, and pooltest.zig
//!     checks the result on every block of its runs.  What poolalloc
//!     itself returns (image memory, which has no tag words) is 8
//!     past a multiple of 16, exactly as much aligned as in C.
//!     mallocalign(size, align, offset, span) gives what it is asked
//!     for, as in C: with an align below 16 no more than that.
//!   - The tag words hold the low 32 bits of the caller's pc as in C;
//!     getmalloctag and getrealloctag sign-extend them, which is right
//!     for kernel text (it is in the top 2GiB).
//!   - A bug of the C fixed: realloc(nil, 0).  The C adds the room for
//!     the tag words only when the size is not 0, because for a block
//!     that means free; with no block it means malloc(0), poolrealloc
//!     returns a block of no bytes, and the two tags are written over
//!     its end-of-data marks: the free of it panics with "mem user
//!     overflow".  Here the room is added whenever a block is made.
//!   - free takes any pointer, a slice or null.
//!   - new, snew, newslice and snewslice are new: typed, zeroed
//!     memory.  The pc they record is their caller's.
//!   - `allocator`, the std.mem.Allocator at the end, is new.
//!   - mallocstats is new: the two figures of the main pool that the
//!     self-test prints.
//!   - pool.zig has the print and panic hooks take finished text, and
//!     a werrstr hook; see there.
//!   - sizes are usize; pool.zig refuses 2GiB and more, as the C does
//!     for what is left of the size after its ulong parameter.

const std = @import("std");
const arch = @import("../arch.zig");
const taslock = @import("taslock.zig");
const xalloc = @import("xalloc.zig");
const pool = @import("pool.zig");
const pgrp = @import("pgrp.zig");
const proc = @import("proc.zig");
const p9 = @import("print.zig");
const print = p9.print;
const iprint = p9.iprint;
const panic = p9.panic;

pub const Pool = pool.Pool;

/// DIFF: the pools' quantum has a name, for the check below.
const Quantum = 32;

const Private = struct {
    lk: taslock.Lock = .{},
    /// a rock for messages to be printed at unlock
    msg: [256]u8 = @splat(0),
};

var pmainpriv: Private = .{};
var pmainmem: Pool = .{
    .name = "Main",
    .maxsize = 4 * 1024 * 1024,
    .minarena = 128 * 1024,
    .quantum = Quantum,
    .alloc = poolxalloc,
    .merge = poolxmerge,
    .flags = pool.POOL_TOLERANCE,

    .lock = plock,
    .unlock = punlock,
    .print = poolprint,
    .panic = ppanic,
    .werrstr = pwerrstr,

    .private = &pmainpriv,
};

var pimagpriv: Private = .{};
var pimagmem: Pool = .{
    .name = "Image",
    .maxsize = 16 * 1024 * 1024,
    .minarena = 2 * 1024 * 1024,
    .quantum = Quantum,
    .alloc = poolxalloc,
    .merge = poolxmerge,
    .flags = 0,

    .lock = plock,
    .unlock = punlock,
    .print = poolprint,
    .panic = ppanic,
    .werrstr = pwerrstr,

    .private = &pimagpriv,
};

var psecrpriv: Private = .{};
var psecrmem: Pool = .{
    .name = "Secrets",
    .maxsize = 16 * 1024 * 1024,
    .minarena = 64 * 1024,
    .quantum = Quantum,
    .alloc = poolxalloc,
    .merge = poolxmerge,
    .flags = pool.POOL_SCRUB,

    .lock = plock,
    .unlock = punlock,
    .print = poolprint,
    .panic = ppanic,
    .werrstr = pwerrstr,

    .private = &psecrpriv,
};

pub const mainmem: *Pool = &pmainmem;
pub const imagmem: *Pool = &pimagmem;
pub const secrmem: *Pool = &psecrmem;

/// DIFF: the C's pools call xalloc and xmerge themselves.  Here is
/// also where an arena is checked to start on a multiple of 16, see
/// the header.
fn poolxalloc(size: usize) ?*anyopaque {
    const a = xalloc.xalloc(size) orelse return null;
    if (a % Malign != 0)
        panic("alloc: xalloc(%lud) returned %#p, not aligned to %d", .{ size, a, @as(usize, Malign) });
    return @ptrFromInt(a);
}

fn poolxmerge(vp: *anyopaque, vq: *anyopaque) bool {
    return xalloc.xmerge(@intFromPtr(vp), @intFromPtr(vq));
}

fn private(p: *Pool) *Private {
    return @ptrCast(@alignCast(p.private.?));
}

fn msglen(pv: *Private) usize {
    return std.mem.findScalar(u8, &pv.msg, 0) orelse pv.msg.len;
}

/// Add to the message; it stays NUL-terminated.
fn msgadd(pv: *Private, s: []const u8) void {
    const have = msglen(pv);
    if (have >= pv.msg.len - 1) return;
    const n = @min(s.len, pv.msg.len - 1 - have);
    @memcpy(pv.msg[have..][0..n], s[0..n]);
    pv.msg[have + n] = 0;
}

//
// because we can't print while we're holding the locks,
// we have the save the message and print it once we let go.
//
fn poolprint(p: *Pool, s: []const u8) void {
    msgadd(private(p), s);
}

fn ppanic(p: *Pool, s: []const u8) noreturn {
    const pv = private(p);
    msgadd(pv, s);
    var msg: [@sizeOf(@FieldType(Private, "msg"))]u8 = undefined;
    @memcpy(&msg, &pv.msg);
    taslock.iunlock(&pv.lk);
    panic("%s", .{msg[0 .. std.mem.findScalar(u8, &msg, 0) orelse msg.len]});
}

fn plock(p: *Pool) void {
    const pv = private(p);
    taslock.ilock(&pv.lk);
    pv.lk.pc = @returnAddress();
    pv.msg[0] = 0;
}

fn punlock(p: *Pool) void {
    const pv = private(p);
    if (pv.msg[0] == 0) {
        taslock.iunlock(&pv.lk);
        return;
    }

    var msg: [@sizeOf(@FieldType(Private, "msg"))]u8 = undefined;
    @memcpy(&msg, &pv.msg);
    taslock.iunlock(&pv.lk);
    iprint("%s", .{msg[0 .. std.mem.findScalar(u8, &msg, 0) orelse msg.len]});
}

/// DIFF: the kernel's werrstr (9/port/sysproc.c), for pool.zig.
fn pwerrstr(s: []const u8) void {
    if (arch.up() == null) return;
    _ = proc.errorf("%s", .{s}) catch {};
}

pub fn poolsummary(p: *Pool) void {
    print("%s max %llud cur %llud free %llud alloc %llud\n", .{
        p.name,
        @as(u64, p.maxsize),
        @as(u64, p.cursize),
        @as(u64, p.curfree),
        @as(u64, p.curalloc),
    });
}

pub fn mallocsummary() void {
    poolsummary(mainmem);
    poolsummary(imagmem);
    poolsummary(secrmem);
}

// everything from here down should be the same in libc, libdebugmalloc, and the kernel
// - except the code for malloc(), which alternately doesn't clear or does.
// - except the code for smalloc(), which lives only in the kernel.

//
// Npadlong is the number of ulong's to leave at the beginning of
// each allocated buffer for our own bookkeeping.  We return to the callers
// a pointer that points immediately after our bookkeeping area.  Incoming pointers
// must be decremented by that much, and outgoing pointers incremented.
// The malloc tag is stored at MallocOffset from the beginning of the block,
// and the realloc tag at ReallocOffset.  The offsets are from the true beginning
// of the block, not the beginning the caller sees.
//
// The extra if(Npadlong != 0) in various places is a hint for the compiler to
// compile out function calls that would otherwise be no-ops.
//

//  non tracing
//
// const Npadlong = 0;
// const MallocOffset = 0;
// const ReallocOffset = 0;
//

// tracing
const Npadlong = 2;
const MallocOffset = 0;
const ReallocOffset = 1;

/// The C's ulong.
const Ulong = u32;
const Npad = Npadlong * @sizeOf(Ulong);

/// DIFF: what malloc's result is aligned to, see the header.
pub const Malign = 16;

comptime {
    // A caller's pointer is a block's address plus this.
    if ((@sizeOf(pool.Bhdr) + Npad) % Malign != 0 or @sizeOf(pool.Arena) % Malign != 0)
        @compileError("alloc: malloc would not return memory aligned to 16");
    if (Quantum % Malign != 0) @compileError("alloc: pool quantum");
}

fn bytes(p: [*]u8, n: usize) []u8 {
    return p[0..n];
}

/// DIFF: the part of smalloc and secalloc that waits, which the C
/// writes out twice.
fn waitalloc(p: *Pool, size: usize, comptime reason: []const u8) [*]u8 {
    while (true) {
        if (pool.poolalloc(p, size +| Npad)) |v|
            return v;
        // an interrupted wait just tries again, as in C
        pgrp.resrcwait(reason) catch {};
    }
}

/// malloc that does not fail: it waits for memory.
pub noinline fn smalloc(size: usize) [*]u8 {
    var v = waitalloc(mainmem, size, "no memory for smalloc");
    if (Npadlong != 0) {
        v += Npad;
        setmalloctag(v, @returnAddress());
    }
    @memset(bytes(v, size), 0);
    return v;
}

/// DIFF: malloc and mallocz with the caller's pc as an argument, for
/// the typed allocators below.
fn malloc0(size: usize, clr: bool, pc: usize) ?[*]u8 {
    var v = pool.poolalloc(mainmem, size +| Npad) orelse
        return null;
    if (Npadlong != 0) {
        v += Npad;
        setmalloctag(v, pc);
        setrealloctag(v, 0);
    }
    // DIFF: see the header
    if (@intFromPtr(v) % Malign != 0)
        panic("malloc: %#p is not aligned to %d: pc %#p", .{ @intFromPtr(v), @as(usize, Malign), pc });
    if (clr)
        @memset(bytes(v, size), 0);
    return v;
}

/// Zeroed memory, or null if there is none.
pub noinline fn malloc(size: usize) ?[*]u8 {
    return malloc0(size, true, @returnAddress());
}

/// As malloc, but zeroed only if `clr`.
pub noinline fn mallocz(size: usize, clr: bool) ?[*]u8 {
    return malloc0(size, clr, @returnAddress());
}

fn mallocalign0(size: usize, alignment: usize, offset: usize, span: usize, clr: bool, pc: usize) ?[*]u8 {
    const off: isize = @as(isize, @bitCast(offset)) -% Npad;
    var v = pool.poolallocalign(mainmem, size +| Npad, alignment, off, span) orelse
        return null;
    if (Npadlong != 0) {
        v += Npad;
        setmalloctag(v, pc);
        setrealloctag(v, 0);
    }
    if (clr)
        @memset(bytes(v, size), 0);
    return v;
}

/// Zeroed memory placed so that (address - offset) is a multiple of
/// `alignment` and, if `span` is not 0, so that it does not cross a
/// multiple of `span`.
pub noinline fn mallocalign(size: usize, alignment: usize, offset: usize, span: usize) ?[*]u8 {
    return mallocalign0(size, alignment, offset, span, true, @returnAddress());
}

/// Free what malloc returned.  Takes any pointer to it, a slice of it,
/// or null.
pub fn free(v: anytype) void {
    const T = @TypeOf(v);
    const addr: usize = switch (@typeInfo(T)) {
        .pointer => |pi| if (pi.size == .slice) @intFromPtr(v.ptr) else @intFromPtr(v),
        .optional => if (v) |x| @intFromPtr(x) else 0,
        .null => 0,
        else => @compileError("free: not a pointer: " ++ @typeName(T)),
    };
    if (addr != 0)
        pool.poolfree(mainmem, @ptrFromInt(addr - Npad));
}

pub noinline fn realloc(v: ?*anyopaque, size_: usize) ?[*]u8 {
    return realloc0(v, size_, @returnAddress());
}

fn realloc0(v_: ?*anyopaque, size_: usize, pc: usize) ?[*]u8 {
    var v = v_;
    var size = size_;
    if (v) |x|
        v = @ptrFromInt(@intFromPtr(x) - Npad);
    // DIFF: also when there is nothing to free, see the header
    if (Npadlong != 0 and (size != 0 or v == null))
        size +|= Npad;
    var nv = pool.poolrealloc(mainmem, v, size) orelse return null;
    nv += Npad;
    setrealloctag(nv, pc);
    if (v == null)
        setmalloctag(nv, pc);
    return nv;
}

/// Bytes usable at `v`.
pub fn msize(v: *anyopaque) usize {
    return pool.poolmsize(mainmem, @ptrFromInt(@intFromPtr(v) - Npad)) - Npad;
}

/// secret memory, used to back cryptographic keys and cipher states
pub noinline fn secalloc(size: usize) [*]u8 {
    var v = waitalloc(secrmem, size, "no memory for secalloc");
    if (Npadlong != 0) {
        v += Npad;
        setmalloctag(v, @returnAddress());
        setrealloctag(v, 0);
    }
    @memset(bytes(v, size), 0);
    return v;
}

pub fn secfree(v: ?*anyopaque) void {
    if (v) |x|
        pool.poolfree(secrmem, @ptrFromInt(@intFromPtr(x) - Npad));
}

fn tagword(v: *anyopaque, off: usize) *Ulong {
    return @ptrFromInt(@intFromPtr(v) - Npad + off * @sizeOf(Ulong));
}

pub fn setmalloctag(v: ?*anyopaque, pc: usize) void {
    if (Npadlong <= MallocOffset or v == null)
        return;
    tagword(v.?, MallocOffset).* = @truncate(pc);
}

pub fn setrealloctag(v: ?*anyopaque, pc: usize) void {
    if (Npadlong <= ReallocOffset or v == null)
        return;
    tagword(v.?, ReallocOffset).* = @truncate(pc);
}

pub fn getmalloctag(v: *anyopaque) usize {
    if (Npadlong <= MallocOffset)
        return ~@as(usize, 0);
    return @bitCast(@as(isize, @as(i32, @bitCast(tagword(v, MallocOffset).*))));
}

pub fn getrealloctag(v: *anyopaque) usize {
    if (Npadlong <= ReallocOffset)
        return ~@as(usize, 0);
    return @bitCast(@as(isize, @as(i32, @bitCast(tagword(v, ReallocOffset).*))));
}

/// DIFF (new): bytes the main pool has from xalloc and bytes in its
/// allocated blocks.
pub fn mallocstats() struct { cursize: usize, curalloc: usize } {
    return .{ .cursize = mainmem.cursize, .curalloc = mainmem.curalloc };
}

// DIFF (new): typed memory.

/// Zeroed memory for one T, or null.  The caller initialises it:
/// zeroes are not necessarily T's defaults.
pub noinline fn new(comptime T: type) ?*T {
    comptime std.debug.assert(@alignOf(T) <= Malign);
    return @ptrCast(@alignCast(malloc0(@sizeOf(T), true, @returnAddress()) orelse return null));
}

/// As `new`, with smalloc.
pub noinline fn snew(comptime T: type) *T {
    comptime std.debug.assert(@alignOf(T) <= Malign);
    const v = smalloc(@sizeOf(T));
    setmalloctag(v, @returnAddress());
    return @ptrCast(@alignCast(v));
}

/// Zeroed memory for n Ts, or null.
pub noinline fn newslice(comptime T: type, n: usize) ?[]T {
    comptime std.debug.assert(@alignOf(T) <= Malign);
    const size = std.math.mul(usize, n, @sizeOf(T)) catch return null;
    const p: [*]T = @ptrCast(@alignCast(malloc0(size, true, @returnAddress()) orelse return null));
    return p[0..n];
}

/// As `newslice`, with smalloc.
pub noinline fn snewslice(comptime T: type, n: usize) []T {
    comptime std.debug.assert(@alignOf(T) <= Malign);
    const v = smalloc(n * @sizeOf(T));
    setmalloctag(v, @returnAddress());
    const p: [*]T = @ptrCast(@alignCast(v));
    return p[0..n];
}

// The kernel allocator as a std.mem.Allocator.
//
// DIFF (new): ported code calls malloc, smalloc and free by their Plan 9
// names and should go on doing so.  This is for new code that wants the
// standard library's containers (std.ArrayList, std.AutoHashMap ...):
//
//     var list: std.ArrayList(u32) = .empty;
//     defer list.deinit(alloc.allocator);
//     try list.append(alloc.allocator, 1);
//
// Allocation fails with error.OutOfMemory instead of waiting as smalloc
// does; a caller that returns a kernel Error maps it to error.Enomem.
// Memory is not zeroed, as the interface does not promise it.

fn stdAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const al = alignment.toByteUnits();
    if (al <= Malign)
        return malloc0(len, false, ret_addr);
    return mallocalign0(len, al, 0, 0, false, ret_addr);
}

/// In place: a block can hold what msize says, and msize makes all of
/// that the caller's.
fn stdResize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    if (new_len <= memory.len) return true;
    return new_len <= msize(memory.ptr);
}

fn stdRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    // realloc keeps no more alignment than malloc gives; a block with
    // more stays where it is or the caller allocates, copies and frees.
    if (alignment.toByteUnits() <= Malign and new_len != 0)
        return realloc0(memory.ptr, new_len, ret_addr);
    return if (stdResize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn stdFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    pool.poolfree(mainmem, memory.ptr - Npad);
}

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = stdAlloc,
        .resize = stdResize,
        .remap = stdRemap,
        .free = stdFree,
    },
};
