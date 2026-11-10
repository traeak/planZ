//! The kernel's general allocator: malloc, free and friends.
//! Interface from 9/port/alloc.c.
//!
//! DIFF: the C kernel uses libc's pool allocator (three pools: main,
//! image, secret).  This is a small replacement behind the same names:
//! power-of-two size classes with a free list each, refilled from
//! xalloc.  Freed blocks go back on their list and are never merged or
//! returned.  It wastes up to half of a block and can fragment under
//! churn of mixed sizes, which is acceptable until something measures
//! otherwise.

const std = @import("std");
const arch = @import("../arch.zig");
const taslock = @import("taslock.zig");
const xalloc = @import("xalloc.zig");
const p9 = @import("print.zig");
const panic = p9.panic;

/// In front of every block.
const Hdr = extern struct {
    magic: u32,
    /// Size class of the block this header starts.
    bin: u32,
    /// Bytes the caller asked for; msize reports this.
    size: usize,
};

/// In front of the pointer mallocalign returns, when that is not the
/// start of the block.
const Ahdr = extern struct {
    magic: u32,
    _pad: u32 = 0,
    /// The block's own user pointer.
    base: usize,
};

const Magic = 0x6d616c6c; // "mall": allocated
const Freed = 0x66726565; // "free"
const Aligned = 0x616c6967; // "alig"

const hdrsize = @sizeOf(Hdr);
const minshift = 5; // smallest block is 32 bytes, header included
const nbin = 40;
/// Blocks up to this size are cut from chunks; larger ones come
/// straight from xalloc.
const chunk = 64 * 1024;

/// A free block: overlays Hdr so the magic keeps saying Freed, which
/// is how a second free of the same block is caught.
const Free = extern struct {
    magic: u32 = Freed,
    _pad: u32 = 0,
    next: ?*Free,
};

var arena: struct {
    lock: taslock.Lock = .{},
    bins: [nbin]?*Free = @splat(null),
    /// Bytes taken from xalloc.
    cursize: usize = 0,
    /// Bytes in blocks currently allocated.
    curalloc: usize = 0,
} = .{};

comptime {
    if (hdrsize != 16 or @sizeOf(Ahdr) != 16) @compileError("alloc header size");
}

fn binof(total: usize) u32 {
    const sz = @max(total, 1 << minshift);
    return std.math.log2_int_ceil(usize, sz) - minshift;
}

fn binsize(bin: u32) usize {
    return @as(usize, 1) << @intCast(bin + minshift);
}

/// Called with the lock held.
fn push(bin: u32, f: *Free) void {
    f.* = .{ .next = arena.bins[bin] };
    arena.bins[bin] = f;
}

/// Put more blocks on an empty bin.  Called with the lock held.
fn refill(bin: u32) bool {
    const bs = binsize(bin);
    if (bs > chunk / 4) {
        const p = xalloc.xallocz(bs, false) orelse return false;
        arena.cursize += bs;
        push(bin, @ptrFromInt(p));
        return true;
    }
    const p = xalloc.xallocz(chunk, false) orelse return false;
    arena.cursize += chunk;
    var off: usize = 0;
    while (off + bs <= chunk) : (off += bs)
        push(bin, @ptrFromInt(p + off));
    return true;
}

fn alloc(size: usize) ?usize {
    if (size > std.math.maxInt(usize) / 2) return null;
    const bin = binof(size + hdrsize);
    if (bin >= nbin) return null;

    taslock.ilock(&arena.lock);
    if (arena.bins[bin] == null and !refill(bin)) {
        taslock.iunlock(&arena.lock);
        return null;
    }
    const f = arena.bins[bin].?;
    arena.bins[bin] = f.next;
    arena.curalloc += binsize(bin);
    taslock.iunlock(&arena.lock);

    const h: *Hdr = @ptrCast(f);
    h.* = .{ .magic = Magic, .bin = bin, .size = size };
    return @intFromPtr(h) + hdrsize;
}

/// The header of the block `v` points into, checking that `v` is
/// something malloc returned and has not been freed.
fn hdrof(v: usize, pc: usize) *Hdr {
    var p = v;
    const a: *Ahdr = @ptrFromInt(p - @sizeOf(Ahdr));
    if (a.magic == Aligned) p = a.base;
    const h: *Hdr = @ptrFromInt(p - hdrsize);
    if (h.magic != Magic) {
        if (h.magic == Freed)
            panic("malloc: block %#p already freed, pc %#p", .{ v, pc });
        panic("malloc: corrupt block %#p magic %#ux, pc %#p", .{ v, h.magic, pc });
    }
    return h;
}

fn bytes(p: usize, n: usize) []u8 {
    return @as([*]u8, @ptrFromInt(p))[0..n];
}

/// Zeroed memory, or null if there is none.
pub fn malloc(size: usize) ?[*]u8 {
    const p = alloc(size) orelse return null;
    @memset(bytes(p, size), 0);
    return @ptrFromInt(p);
}

/// As malloc, but zeroed only if `clr`.
pub fn mallocz(size: usize, clr: bool) ?[*]u8 {
    const p = alloc(size) orelse return null;
    if (clr) @memset(bytes(p, size), 0);
    return @ptrFromInt(p);
}

/// Memory aligned so that (address + offset) is a multiple of
/// `alignment`.  DIFF: `span`, which keeps a block from crossing a
/// boundary, is not implemented; nothing ported so far passes it.
pub fn mallocalign(size: usize, alignment: usize, offset: usize, span: usize) ?[*]u8 {
    if (span != 0) panic("mallocalign: span not supported, pc %#p", .{@returnAddress()});
    if (alignment <= hdrsize and offset == 0)
        return malloc(size);

    const base = alloc(size + alignment + @sizeOf(Ahdr)) orelse return null;
    // First aligned address that leaves room for the Ahdr.
    const p = std.mem.alignForward(usize, base + @sizeOf(Ahdr) + offset, alignment) - offset;
    const a: *Ahdr = @ptrFromInt(p - @sizeOf(Ahdr));
    a.* = .{ .magic = Aligned, .base = base };
    @memset(bytes(p, size), 0);
    return @ptrFromInt(p);
}

/// malloc that does not fail.
/// DIFF: the C waits for memory to be freed; without a scheduler there
/// is nobody to free any, so for now running out is a panic.
pub fn smalloc(size: usize) [*]u8 {
    return malloc(size) orelse
        panic("smalloc: out of memory, %lud bytes, pc %#p", .{ size, @returnAddress() });
}

pub fn free(v: ?*anyopaque) void {
    const p = @intFromPtr(v orelse return);
    const h = hdrof(p, @returnAddress());
    const bin = h.bin;

    taslock.ilock(&arena.lock);
    arena.curalloc -= binsize(bin);
    push(bin, @ptrCast(h));
    taslock.iunlock(&arena.lock);
}

/// Bytes usable at `v`.
pub fn msize(v: *anyopaque) usize {
    const p = @intFromPtr(v);
    const h = hdrof(p, @returnAddress());
    const a: *Ahdr = @ptrFromInt(p - @sizeOf(Ahdr));
    if (a.magic == Aligned) return h.size - (p - a.base);
    return h.size;
}

pub fn realloc(v: ?*anyopaque, size: usize) ?[*]u8 {
    const old = v orelse return malloc(size);
    if (size == 0) {
        free(old);
        return null;
    }
    const p = @intFromPtr(old);
    const h = hdrof(p, @returnAddress());
    const a: *Ahdr = @ptrFromInt(p - @sizeOf(Ahdr));
    const have = msize(old);
    // Grow in place when the block's size class already has the room.
    if (a.magic != Aligned and size + hdrsize <= binsize(h.bin)) {
        if (size > have) @memset(bytes(p + have, size - have), 0);
        h.size = size;
        return @ptrFromInt(p);
    }
    const new = malloc(size) orelse return null;
    const n = @min(have, size);
    @memcpy(new[0..n], bytes(p, n));
    free(old);
    return new;
}

/// Memory for secrets: zeroed when freed.
/// DIFF: the C keeps these in a separate pool that is also excluded
/// from /proc and kernel dumps.
pub fn secalloc(size: usize) [*]u8 {
    return malloc(size) orelse
        panic("secalloc: out of memory, pc %#p", .{@returnAddress()});
}

pub fn secfree(v: ?*anyopaque) void {
    const p = v orelse return;
    @memset(@as([*]u8, @ptrCast(p))[0..msize(p)], 0);
    free(p);
}

/// Bytes obtained from xalloc and bytes in allocated blocks, for /dev/swap.
pub fn mallocstats() struct { cursize: usize, curalloc: usize } {
    return .{ .cursize = arena.cursize, .curalloc = arena.curalloc };
}
