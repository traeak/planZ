//! Host tests of the pool allocator, port/pool.zig (`zig build test`).
//! Not from a C file; tools/poolref/main.c is its twin on the C side.
//!
//! 1. A stress test against a model.  Random poolalloc, poolallocalign
//!    (align, offset, span), poolrealloc, poolmsize, poolfree and
//!    poolcompact on a table of slots.  Every live block is filled with
//!    a pattern that is checked before the block is freed or
//!    reallocated and after it was reallocated or moved; no two live
//!    blocks overlap; what poolallocalign returns has the alignment,
//!    offset and span asked for; poolmsize is at least the request and
//!    all of it can be written; what poolalloc and poolrealloc return
//!    is 8 past a multiple of 16 (which is what makes the kernel's
//!    malloc return multiples of 16, see port/alloc.zig) unless the
//!    pool compacts, when it is a multiple of 8.  Every
//!    `checkevery` operations poolcheck runs and the arenas are walked
//!    to see that curfree and curalloc are the sums of the blocks.
//!    The arenas come from an allocator shaped like the kernel's
//!    xalloc that, depending on the configuration, leaves gaps (so
//!    that some arenas merge and some do not), fails now and then, and
//!    runs into the pool's maxsize.
//!
//! 2. The same operations on the C.  tools/poolref builds 9front's
//!    pool.c for the host with the type sizes of amd64 and replays
//!    them; `want` below is its output: a hash over the result of
//!    every operation (the address, relative to the arena memory) and
//!    over cursize and curfree after each.  Both sides map the arena
//!    memory at the same fixed address, because alignment and span
//!    decisions depend on addresses.  The debugging flags do not
//!    change where blocks go, so the runs with POOL_ANTAGONISM,
//!    POOL_PARANOIA and POOL_SCRUB must give the same lines.  What is
//!    left out of the comparison is listed at the top of
//!    tools/poolref/main.c.
//!
//! 3. Single tests: free neighbours merge, a large request takes its
//!    size and not the next power of two, arenas merge, the entry
//!    points nothing in the kernel calls, the kernel's malloc
//!    arithmetic, and the bugs of the C that pool.zig fixes.
//!
//! Linux on a 64-bit machine only (a fixed mapping); elsewhere the
//! tests are skipped.  There, they fail if the mapping cannot be had.
//!
//! The run is deterministic.  The environment sets more:
//!     POOLTEST_OPS=n     operations per run (default: per configuration)
//!     POOLTEST_SEEDS=n   seeds 1..n for each configuration (default 3)
//!     POOLTEST_FLAGSEEDS=n  also run seeds 1..n of each configuration
//!                        with the debugging flags (default 1)
//!     POOLTEST_CHECK=n   poolcheck and the walk every n operations
//!                        (default 64; 1 is the slow mode)
//!     POOLTEST_TRACE=A:1 print every operation of configuration A,
//!                        seed 1, as `tools/poolref/pref -t A 1` does,
//!                        for diff
//! With OPS or SEEDS set the lines `want` does not have are printed
//! instead of compared: compare them with tools/poolref/pref run with
//! the same environment.  The build system does not run a test again
//! because the environment changed, so run the test itself:
//!     POOLTEST_SEEDS=200 POOLTEST_CHECK=1 zig test -OReleaseSafe \
//!         --dep fmt -Mroot=src/kernel/pooltest.zig -Mfmt=src/lib/fmt.zig

const std = @import("std");
const builtin = @import("builtin");
const pool = @import("port/pool.zig");

const Pool = pool.Pool;
const linux = std.os.linux;

// tools/poolref/pref
const want =
    \\A 1 20000 5cab0bbd28f34602 3409920 2787456
    \\A 2 20000 33d1a1610f80b486 2692320 1645840
    \\A 3 20000 cfdce6b409c35256 2653568 2086008
    \\B 1 20000 c72fdeb21262e82d 1026112 344760
    \\B 2 20000 94875bfa45cad675 1039296 585568
    \\B 3 20000 29e76e1828ba3b54 1047392 595256
    \\C 1 4000 1f282fdb23957f0b 9898496 224544
    \\C 2 4000 36569dfa929aa09c 9369824 65104
    \\C 3 4000 7038364fd1228d19 10708096 47328
    \\D 1 20000 263ab740a30c220d 774944 114584
    \\D 2 20000 2bbd5bbcb900a23c 780704 99896
    \\D 3 20000 bc6bce62ea245507 784000 151600
    \\E 1 20000 eb594de6fd9fcb3d 1984192 1462200
    \\E 2 20000 77ae986e4c26f3bd 2060736 1275776
    \\E 3 20000 5429b7b676c3b030 2095744 1397784
    \\F 1 20000 c2e229840a306a7c 3044768 2284680
    \\F 2 20000 1703a67902fa5a65 2862464 1835632
    \\F 3 20000 858ffee0ba726c81 2443840 2180960
    \\G 1 20000 325a1a4df1a3e568 1047936 406200
    \\G 2 20000 0d2fcee919c07075 1048320 342936
    \\G 3 20000 131c0e950dec5c20 1047232 282808
    \\
;

const Nslot = 256;
const Base = 0x20000000;
const Regsize = 96 * 1024 * 1024;
/// what xalloc.zig puts in front of an allocation
const Xhdr = 16;
/// and what it adds behind
const Xslack = 16;
const Nchunk = 8192;

const Slot = struct {
    p: ?[*]u8 = null,
    n: usize = 0,
    /// from poolallocalign, and not through poolrealloc since
    aligned: bool = false,
    /// by poolcompact: where it is no longer says anything
    moved: bool = false,
    /// the model's: what the block is filled with
    seed: u8 = 0,
};

const Conf = struct {
    name: []const u8,
    flags: u32,
    quantum: u32,
    minarena: u32,
    minblock: u32,
    maxsize: usize,
    /// every nth request for an arena fails
    failevery: u32,
    /// every nth arena is not adjacent to the one before
    gapevery: u32,
    /// use poolallocalign
    @"align": bool,
    /// set Pool.move and call poolcompact
    compact: bool,
    nops: u32,
    /// not in tools/poolref: the alignments the C cannot do
    zigonly: bool = false,
};

const conf = [_]Conf{
    .{ .name = "A", .flags = 0, .quantum = 32, .minarena = 32 * 1024, .minblock = 0, .maxsize = 4 * 1024 * 1024, .failevery = 0, .gapevery = 3, .@"align" = true, .compact = false, .nops = 20000 },
    .{ .name = "B", .flags = 0, .quantum = 32, .minarena = 32 * 1024, .minblock = 0, .maxsize = 1 * 1024 * 1024, .failevery = 5, .gapevery = 0, .@"align" = true, .compact = false, .nops = 20000 },
    .{ .name = "C", .flags = pool.POOL_NOREUSE, .quantum = 32, .minarena = 64 * 1024, .minblock = 0, .maxsize = 64 * 1024 * 1024, .failevery = 0, .gapevery = 2, .@"align" = false, .compact = false, .nops = 4000 },
    .{ .name = "D", .flags = 0, .quantum = 32, .minarena = 16 * 1024, .minblock = 0, .maxsize = 768 * 1024, .failevery = 0, .gapevery = 4, .@"align" = true, .compact = true, .nops = 20000 },
    .{ .name = "E", .flags = 0, .quantum = 64, .minarena = 4 * 1024, .minblock = 128, .maxsize = 2 * 1024 * 1024, .failevery = 7, .gapevery = 2, .@"align" = true, .compact = false, .nops = 20000 },
    .{ .name = "F", .flags = pool.POOL_TOLERANCE, .quantum = 32, .minarena = 128 * 1024, .minblock = 0, .maxsize = 8 * 1024 * 1024, .failevery = 0, .gapevery = 4, .@"align" = true, .compact = false, .nops = 20000 },
    .{ .name = "G", .flags = 0, .quantum = 32, .minarena = 2 * 1024, .minblock = 0, .maxsize = 1 * 1024 * 1024, .failevery = 0, .gapevery = 0, .@"align" = false, .compact = true, .nops = 20000 },
};

/// Configurations with no twin: what the C gets wrong.
const zigconf = [_]Conf{
    // POOL_NOREUSE with aligned blocks
    .{ .name = "N", .flags = pool.POOL_NOREUSE, .quantum = 32, .minarena = 64 * 1024, .minblock = 0, .maxsize = 64 * 1024 * 1024, .failevery = 0, .gapevery = 2, .@"align" = true, .compact = false, .nops = 4000, .zigonly = true },
    // alignments that are not multiples of the quantum
    .{ .name = "Z", .flags = pool.POOL_PARANOIA | pool.POOL_ANTAGONISM, .quantum = 32, .minarena = 32 * 1024, .minblock = 0, .maxsize = 2 * 1024 * 1024, .failevery = 9, .gapevery = 3, .@"align" = true, .compact = false, .nops = 6000, .zigonly = true },
};

// no alignment that is not a multiple of the quantum and is large
// enough for freefromfront to act on: the C corrupts the pool then
const aligns = [_]usize{ 0, 1, 8, 16, 32, 64, 256, 4096, 12, 96 };
const zigaligns = [_]usize{ 0, 1, 100, 16, 48, 72, 200, 4096, 12, 1000 };
const offs = [_]i32{ 0, 0, 0, 4, 8, -8, -4, 20, 3 };
const spans = [_]usize{ 0, 0, 0, 4096, 65536, 256 };

const Chunk = struct { a: usize = 0, n: usize = 0 };

var cf: *const Conf = undefined;
var slot: [Nslot]Slot = @splat(.{});
var chunk: [Nchunk]Chunk = @splat(.{});
var nchunk: usize = 0;
var brk: usize = 0;
var ncall: u32 = 0;
var rndx: u32 = 0;
var hash: u64 = 0;
var trace = false;
var thepool: Pool = undefined;

// the model's
var locked = false;
var printed: usize = 0;
var printbuf: [4096]u8 = undefined;
var nprintbuf: usize = 0;
var stacks: usize = 0;
var freed: usize = 0;
var nmoved: usize = 0;
/// every block of thepool is in `slot`
var modelled = false;

fn rnd() u32 {
    rndx ^= rndx << 13;
    rndx ^= rndx >> 17;
    rndx ^= rndx << 5;
    return rndx;
}

fn mix(v: u64) void {
    for (0..8) |i| {
        hash ^= (v >> @intCast(8 * i)) & 0xFF;
        hash *%= 0x100000001b3;
    }
}

//
// The coarse allocator, shaped like xalloc: a header in front, a
// little slack behind, one allocation after the other unless a gap is
// asked for, addresses that are multiples of 16, memory that is zero.
//
fn balloc(n: usize) ?*anyopaque {
    ncall += 1;
    if (cf.failevery != 0 and ncall % cf.failevery == 0)
        return null;
    if (cf.gapevery != 0 and ncall % cf.gapevery == 0)
        brk += 4096;
    const a = brk + Xhdr;
    if (a + n + Xslack > Base + Regsize or nchunk == Nchunk)
        return null;
    brk = a + ((n + 15) & ~@as(usize, 15)) + Xslack;
    chunk[nchunk] = .{ .a = a, .n = brk - a };
    nchunk += 1;
    return @ptrFromInt(a);
}

/// xmerge
fn bmerge(vp: *anyopaque, vq: *anyopaque) bool {
    const p = @intFromPtr(vp);
    const q = @intFromPtr(vq);
    var i: usize = 0;
    while (i < nchunk and chunk[i].a != p) i += 1;
    var j: usize = 0;
    while (j < nchunk and chunk[j].a != q) j += 1;
    if (i == nchunk or j == nchunk)
        @panic("bmerge: not mine");
    if (chunk[i].a + chunk[i].n + Xhdr == chunk[j].a) {
        chunk[i].n += Xhdr + chunk[j].n;
        nchunk -= 1;
        chunk[j] = chunk[nchunk];
        return true;
    }
    return false;
}

/// Pool.move: the block whose data was at from is now at to
fn moved(from: *anyopaque, to: *anyopaque) void {
    const f = @intFromPtr(from);
    const t = @intFromPtr(to);
    const bsize: usize = @as(*const u32, @ptrFromInt(t - 4)).*;
    var found: usize = 0;
    for (&slot) |*s| {
        const p = @intFromPtr(s.p orelse continue);
        if (p >= f and p <= f + bsize - 16) {
            s.p = @ptrFromInt(p - f + t);
            s.moved = true;
            found += 1;
        }
    }
    if (found != 1)
        std.debug.panic("moved: {d} slots in one block", .{found});
    nmoved += 1;
}

fn plock(p: *Pool) void {
    if (p == &thepool) {
        if (locked) @panic("pool locked twice");
        locked = true;
    }
}

fn punlock(p: *Pool) void {
    if (p == &thepool) {
        if (!locked) @panic("pool unlocked twice");
        locked = false;
    }
}

fn pprint(_: *Pool, s: []const u8) void {
    printed += 1;
    const n = @min(s.len, printbuf.len - nprintbuf);
    @memcpy(printbuf[nprintbuf..][0..n], s[0..n]);
    nprintbuf += n;
}

fn ppanic(p: *Pool, s: []const u8) noreturn {
    std.debug.panic("pool {s}: {s}{s}", .{ p.name, printbuf[0..nprintbuf], s });
}

fn plogstack(_: *Pool) void {
    stacks += 1;
}

fn pfree(_: *anyopaque, n: usize) void {
    freed += n;
}

fn pick() usize {
    const k = rnd() % 100;
    if (k < 2)
        return 0;
    if (k < 70)
        return 1 + rnd() % 256;
    if (k < 95)
        return 1 + rnd() % 4096;
    return 1 + rnd() % (200 * 1024);
}

fn off(v: ?[*]u8) u64 {
    return if (v) |x| @intFromPtr(x) - Base else ~@as(u64, 0);
}

fn out(op: []const u8, i: usize, a: u64, b: u64, c: u64, d: u64, r: u64) void {
    mix(op[0]);
    mix(i);
    mix(a);
    mix(b);
    mix(c);
    mix(d);
    mix(r);
    mix(thepool.cursize);
    mix(thepool.curfree);
    if (trace)
        std.debug.print("{s} {d} {d} {d} {d} {d} = {x}; {d} {d}\n", .{
            op, i, @as(i64, @bitCast(a)), @as(i64, @bitCast(b)), @as(i64, @bitCast(c)), @as(i64, @bitCast(d)), r, thepool.cursize, thepool.curfree,
        });
}

//
// The model.
//

/// The start and the end of a block depend on the position, so that a
/// copy that is off by a few bytes shows; the middle is cheap.
const Edge = 256;

fn patbyte(seed: u8, j: usize) u8 {
    return seed +% @as(u8, @truncate(j *% 37));
}

fn fill(s: *Slot) void {
    const b = s.p.?[0..s.n];
    if (b.len <= 2 * Edge) {
        for (b, 0..) |*c, j| c.* = patbyte(s.seed, j);
        return;
    }
    for (b[0..Edge], 0..) |*c, j| c.* = patbyte(s.seed, j);
    @memset(b[Edge .. b.len - Edge], s.seed);
    for (b[b.len - Edge ..], b.len - Edge..) |*c, j| c.* = patbyte(s.seed, j);
}

/// Are the first `n` bytes at `p` those of a block of s.n bytes filled by fill?
fn intact(s: *const Slot, p: [*]const u8, n: usize) bool {
    for (p[0..n], 0..) |c, j| {
        const w = if (s.n <= 2 * Edge or j < Edge or j >= s.n - Edge) patbyte(s.seed, j) else s.seed;
        if (c != w) return false;
    }
    return true;
}

fn check(s: *const Slot, what: []const u8) !void {
    if (!intact(s, s.p.?, s.n)) {
        std.debug.print("pooltest: block {x} of {d} bytes damaged ({s})\n", .{ @intFromPtr(s.p.?), s.n, what });
        return error.Damaged;
    }
}

fn nooverlap(i: usize) !void {
    const s = &slot[i];
    const a = @intFromPtr(s.p.?);
    for (&slot, 0..) |*o, j| {
        if (j == i) continue;
        const b = @intFromPtr(o.p orelse continue);
        if (a < b + o.n and b < a + s.n) {
            std.debug.print("pooltest: blocks {x}+{d} and {x}+{d} overlap\n", .{ a, s.n, b, o.n });
            return error.Overlap;
        }
    }
}

// pool.zig's, which keeps them to itself
const FREE_MAGIC = 0xBA5EBA11;
const ALLOC_MAGIC = 0x0A110C09;
const DEAD_MAGIC = 0xdeaddead;
const ARENA_MAGIC = 0xC0A1E5CE + 1;
const ARENATAIL_MAGIC = 0xEC5E1A0C + 1;

const Sums = struct { free: usize = 0, alloc: usize = 0, nalloc: usize = 0, narena: usize = 0, largestfree: usize = 0, asize: usize = 0 };

/// Walk every block of every arena.
fn walk(p: *Pool) !Sums {
    var sums: Sums = .{};
    var last: usize = std.math.maxInt(usize);
    var a = p.arenalist;
    while (a) |x| : (a = x.down) {
        // sorted by descending address
        try std.testing.expect(@intFromPtr(x) < last);
        last = @intFromPtr(x);
        try std.testing.expectEqual(@as(u32, ARENA_MAGIC), x.magic);
        sums.narena += 1;
        sums.asize += x.asize;
        const end = @intFromPtr(x) + x.asize - @sizeOf(pool.Bhdr);
        var b: *pool.Bhdr = @ptrFromInt(@intFromPtr(x) + x.size);
        while (@intFromPtr(b) < end) : (b = @ptrFromInt(@intFromPtr(b) + b.size)) {
            try std.testing.expect(b.size >= 32 and b.size % 8 == 0);
            // the kernel's alignment, see port/alloc.zig
            if (p.move == null)
                try std.testing.expect(@intFromPtr(b) % 16 == 0);
            switch (b.magic) {
                FREE_MAGIC => {
                    sums.free += b.size;
                    sums.largestfree = @max(sums.largestfree, b.size);
                },
                ALLOC_MAGIC => {
                    sums.alloc += b.size;
                    sums.nalloc += 1;
                },
                DEAD_MAGIC => sums.alloc += b.size,
                else => return error.BadMagic,
            }
        }
        try std.testing.expectEqual(end, @intFromPtr(b));
        try std.testing.expectEqual(@as(u32, ARENATAIL_MAGIC), b.magic);
    }
    return sums;
}

fn consistent(p: *Pool) !void {
    pool.poolcheck(p);
    const sums = try walk(p);
    try std.testing.expectEqual(p.curfree, sums.free);
    try std.testing.expectEqual(p.curalloc, sums.alloc);
    try std.testing.expect(p.cursize <= p.maxsize);
    try std.testing.expect(p.cursize <= sums.asize);
    if (modelled and p.flags & pool.POOL_NOREUSE == 0) {
        var live: usize = 0;
        for (&slot) |*s| {
            if (s.p != null) live += 1;
        }
        try std.testing.expectEqual(live, sums.nalloc);
    }
}

fn step() !void {
    const p = &thepool;
    const i = rnd() % Nslot;
    const s = &slot[i];
    const k = rnd() % 100;
    if (s.p == null) {
        const n = pick();
        var v: ?[*]u8 = undefined;
        if (cf.@"align" and k < 25) {
            const al = (if (cf.zigonly) zigaligns else aligns)[rnd() % aligns.len];
            const o = offs[rnd() % offs.len];
            var span = spans[rnd() % spans.len];
            if (n == 0 and !cf.zigonly)
                span = 0; // the C corrupts the pool, see pool.zig
            v = pool.poolallocalign(p, n, al, o, span);
            out("align", i, n, al, @bitCast(@as(i64, o)), span, off(v));
            s.aligned = true;
            if (v) |x| {
                const a: i64 = @intCast(@intFromPtr(x));
                if (al != 0)
                    try std.testing.expectEqual(@as(i64, 0), @mod(a - o, @as(i64, @intCast(al))));
                if (span != 0 and n != 0)
                    try std.testing.expectEqual(@intFromPtr(x) / span, (@intFromPtr(x) + n - 1) / span);
                if (p.flags & pool.POOL_ANTAGONISM != 0)
                    try std.testing.expect(std.mem.allEqual(u8, x[0..n], 0xDD));
            }
        } else {
            v = pool.poolalloc(p, n);
            out("malloc", i, n, 0, 0, 0, off(v));
            s.aligned = false;
            if (v) |x| {
                if (!cf.compact)
                    try std.testing.expectEqual(@as(usize, 8), @intFromPtr(x) % 16);
                if (p.flags & pool.POOL_ANTAGONISM != 0)
                    try std.testing.expect(std.mem.allEqual(u8, x[0..n], 0xDF));
            }
        }
        s.p = v;
        s.n = n;
        s.moved = false;
        if (v != null) {
            s.seed = @truncate(rndx >> 8);
            try nooverlap(i);
            fill(s);
        }
        return;
    }
    if (k < 50) {
        try freeslot(i);
    } else if (k < 80 and !cf.compact) {
        // not with a move hook: when poolrealloc has to allocate and
        // that compacts the pool, the block it is reallocating moves
        // under it (in the C and in pool.zig alike)
        const n = pick();
        try check(s, "before realloc");
        const v = pool.poolrealloc(p, s.p, n);
        out("realloc", i, n, 0, 0, 0, off(v));
        if (v) |x| {
            try std.testing.expectEqual(@as(usize, 8), @intFromPtr(x) % 16);
            if (!intact(s, x, @min(s.n, n))) {
                std.debug.print("pooltest: realloc of {d} bytes to {d} lost data\n", .{ s.n, n });
                return error.Damaged;
            }
            s.p = x;
            s.n = n;
            s.aligned = false;
            s.moved = false;
            try nooverlap(i);
            fill(s);
        } else if (n == 0) {
            s.p = null;
        } else {
            // it failed: the block is as it was
            try check(s, "after a failed realloc");
        }
    } else if (k < 90 and !s.aligned) {
        const n = pool.poolmsize(p, s.p);
        out("size", i, n, 0, 0, 0, 0);
        try std.testing.expect(n >= s.n);
        try check(s, "after msize");
        // let the user use it
        s.n = n;
        try nooverlap(i);
        fill(s);
    } else if (k < 93 and cf.compact) {
        const n = pool.poolcompact(p);
        out("compact", i, n, 0, 0, 0, 0);
        for (&slot) |*o| {
            if (o.p != null) try check(o, "after compaction");
        }
    } else {
        try freeslot(i);
    }
}

fn freeslot(i: usize) !void {
    const p = &thepool;
    const s = &slot[i];
    try check(s, "before free");
    const x = s.p.?;
    pool.poolfree(p, x);
    out("free", i, 0, 0, 0, 0, 0);
    s.p = null;
    // the free tree's node is in the first bytes
    if (p.flags & pool.POOL_SCRUB != 0 and p.flags & (pool.POOL_ANTAGONISM | pool.POOL_NOREUSE) == 0 and s.n > 40)
        try std.testing.expect(std.mem.allEqual(u8, x[40..s.n], 0));
}

var region: ?[*]u8 = null;

fn mapregion() !void {
    if (builtin.os.tag != .linux or @sizeOf(usize) != 8)
        return error.SkipZigTest;
    const rc = linux.mmap(@ptrFromInt(Base), Regsize, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED_NOREPLACE = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS or rc != Base) {
        // not skipped: a run that tested nothing must not pass
        std.debug.print("pooltest: cannot map {d} bytes at {x}\n", .{ Regsize, Base });
        return error.CannotMap;
    }
    region = @ptrFromInt(rc);
}

fn unmapregion() void {
    _ = linux.munmap(@ptrCast(region.?), Regsize);
    region = null;
}

/// A pool on fresh arena memory.
fn newpool(c: *const Conf, flags: u32) !void {
    try mapregion();
    cf = c;
    slot = @splat(.{});
    nchunk = 0;
    brk = Base;
    ncall = 0;
    locked = false;
    nprintbuf = 0;
    thepool = .{
        .name = c.name,
        .maxsize = c.maxsize,
        .minarena = c.minarena,
        .quantum = c.quantum,
        .minblock = c.minblock,
        .alloc = balloc,
        .merge = bmerge,
        .move = if (c.compact) moved else null,
        .flags = flags,
        .lock = plock,
        .unlock = punlock,
        .print = pprint,
        .panic = ppanic,
    };
}

fn envnum(name: []const u8, default: usize) usize {
    const v = std.testing.environ.getPosix(name) orelse return default;
    return std.fmt.parseInt(usize, v, 0) catch default;
}

/// One run; the line tools/poolref/pref prints for it.
fn run(c: *const Conf, flags: u32, seed: u32, nops: usize, buf: []u8) ![]u8 {
    try newpool(c, flags);
    defer unmapregion();
    modelled = true;
    defer modelled = false;
    rndx = seed *% 2654435761 +% 1;
    hash = 0xcbf29ce484222325;
    const checkevery = @max(1, envnum("POOLTEST_CHECK", 64));

    for (0..nops) |op| {
        step() catch |e| {
            std.debug.print("pooltest: configuration {s} flags {x} seed {d} operation {d}\n", .{ c.name, flags, seed, op });
            return e;
        };
        if (locked) return error.StillLocked;
        if (op % checkevery == 0) {
            consistent(&thepool) catch |e| {
                std.debug.print("pooltest: configuration {s} flags {x} seed {d} after operation {d}\n", .{ c.name, flags, seed, op });
                return e;
            };
        }
    }
    try consistent(&thepool);
    for (&slot) |*s| {
        if (s.p != null) try check(s, "at the end");
    }
    return std.fmt.bufPrint(buf, "{s} {d} {d} {x:0>16} {d} {d}", .{ c.name, seed, nops, hash, thepool.cursize, thepool.curfree });
}

fn wanted(line: []const u8) bool {
    var it = std.mem.splitScalar(u8, want, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, l, line)) return true;
    }
    return false;
}

/// Is there a line for this run in `want`?
fn known(c: *const Conf, seed: u32, nops: usize) bool {
    var buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{s} {d} {d} ", .{ c.name, seed, nops }) catch return false;
    var it = std.mem.splitScalar(u8, want, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, prefix)) return true;
    }
    return false;
}

test "pool: random operations, against a model and against the C" {
    if (std.testing.environ.getPosix("POOLTEST_TRACE")) |t| {
        // name:seed
        const colon = std.mem.findScalar(u8, t, ':') orelse return error.BadTrace;
        const seed = try std.fmt.parseInt(u32, t[colon + 1 ..], 0);
        for (&conf) |*c| {
            if (!std.mem.eql(u8, c.name, t[0..colon])) continue;
            trace = true;
            defer trace = false;
            var buf: [128]u8 = undefined;
            const line = try run(c, c.flags, seed, envnum("POOLTEST_OPS", c.nops), &buf);
            std.debug.print("{s}\n", .{line});
        }
        return;
    }

    const nseed: u32 = @intCast(envnum("POOLTEST_SEEDS", 3));
    var bad: usize = 0;
    for (&conf) |*c| {
        const nops = envnum("POOLTEST_OPS", c.nops);
        var seed: u32 = 1;
        while (seed <= nseed) : (seed += 1) {
            var buf: [128]u8 = undefined;
            const line = try run(c, c.flags, seed, nops, &buf);
            if (!known(c, seed, nops)) {
                std.debug.print("{s}\n", .{line});
            } else if (!wanted(line)) {
                std.debug.print("pooltest: got {s}, the C gives something else\n", .{line});
                bad += 1;
            }
            // The debugging flags must not change where anything goes.
            if (seed > envnum("POOLTEST_FLAGSEEDS", 1)) continue;
            const more = [_]u32{ pool.POOL_ANTAGONISM, pool.POOL_PARANOIA | pool.POOL_SCRUB };
            for (more) |f| {
                // paranoia reads every byte of every dead block at
                // every operation
                if (c.flags & pool.POOL_NOREUSE != 0 and f & pool.POOL_PARANOIA != 0) continue;
                var buf2: [128]u8 = undefined;
                const l2 = try run(c, c.flags | f, seed, nops, &buf2);
                if (!std.mem.eql(u8, line, l2)) {
                    std.debug.print("pooltest: flags {x}: got {s}, without them {s}\n", .{ f, l2, line });
                    bad += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "pool: what the C cannot do: NOREUSE with aligned blocks, odd alignments" {
    const nseed: u32 = @intCast(envnum("POOLTEST_SEEDS", 3));
    for (&zigconf) |*c| {
        var seed: u32 = 1;
        while (seed <= nseed) : (seed += 1) {
            var buf: [128]u8 = undefined;
            _ = try run(c, c.flags, seed, envnum("POOLTEST_OPS", c.nops), &buf);
        }
    }
}

const kernelmain: Conf = .{ .name = "Main", .flags = pool.POOL_TOLERANCE, .quantum = 32, .minarena = 128 * 1024, .minblock = 0, .maxsize = 64 * 1024 * 1024, .failevery = 0, .gapevery = 0, .@"align" = true, .compact = false, .nops = 0 };

test "pool: free neighbours merge" {
    // Fill one arena with small blocks, free them in random order:
    // what is left must be one free block, and a single allocation of
    // all of it must fit without the pool growing.
    var c = kernelmain;
    c.minarena = 1024 * 1024;
    try newpool(&c, c.flags);
    defer unmapregion();
    const p = &thepool;
    rndx = 12345;

    const N = 8000;
    const S = struct {
        var blocks: [N]?[*]u8 = @splat(null);
    };
    var n: usize = 0;
    var cursize: usize = 0;
    while (n < N) : (n += 1) {
        const size = 1 + rnd() % 600;
        const v = pool.poolalloc(p, size) orelse return error.OutOfMemory;
        if (n == 0) cursize = p.cursize;
        if (cursize != p.cursize or p.arenalist.?.down != null) return error.Grew;
        S.blocks[n] = v;
        // stop before the arena is full
        if (p.curfree < 4096) {
            n += 1;
            break;
        }
    }
    try std.testing.expect(n < N);
    var sums = try walk(p);
    try std.testing.expectEqual(@as(usize, 1), sums.narena);
    try std.testing.expectEqual(n, sums.nalloc);

    // free in random order
    var left = n;
    while (left > 0) {
        const i = rnd() % n;
        if (S.blocks[i]) |v| {
            pool.poolfree(p, v);
            S.blocks[i] = null;
            left -= 1;
        }
    }
    try consistent(p);
    sums = try walk(p);
    try std.testing.expectEqual(@as(usize, 0), sums.nalloc);
    try std.testing.expectEqual(p.curfree, sums.largestfree);
    try std.testing.expectEqual(@as(usize, 0), p.curalloc);
    // the arena but for its header and tail
    try std.testing.expectEqual(cursize - @sizeOf(pool.Arena) - @sizeOf(pool.Bhdr), p.curfree);

    // all of it but the block's own header and tail; the block is 24
    // bytes more than a multiple of the quantum (the arena's tail is
    // 8 bytes), and a request is rounded up to the quantum
    const big = pool.poolalloc(p, p.curfree - 16 - 24) orelse return error.DidNotMerge;
    try std.testing.expectEqual(cursize, p.cursize);
    try std.testing.expectEqual(@as(usize, 0), p.curfree);
    pool.poolfree(p, big);
    try consistent(p);
}

test "pool: a large request takes its size, not a power of two" {
    try newpool(&kernelmain, kernelmain.flags);
    defer unmapregion();
    const p = &thepool;
    const n = 4 * 1024 * 1024 + 20;
    const v = pool.poolalloc(p, n) orelse return error.OutOfMemory;
    // the arena is the block and a little more
    try std.testing.expect(p.cursize >= n and p.cursize < n + 256);
    try std.testing.expect(p.curalloc >= n and p.curalloc < n + 128);
    try std.testing.expect(pool.poolmsize(p, v) < n + 64);
    pool.poolfree(p, v);
    try consistent(p);
}

test "pool: adjacent arenas merge" {
    // Arenas of 128K one after the other, as xalloc gives them when
    // nothing else allocates in between, become one; then a block
    // larger than any of them fits in what they hold.
    try newpool(&kernelmain, kernelmain.flags);
    defer unmapregion();
    const p = &thepool;
    const S = struct {
        var blocks: [64]?[*]u8 = @splat(null);
    };
    for (&S.blocks) |*b|
        b.* = pool.poolalloc(p, 100 * 1024) orelse return error.OutOfMemory;
    var sums = try walk(p);
    try std.testing.expectEqual(@as(usize, 1), sums.narena);
    try consistent(p);
    const cursize = p.cursize;
    try std.testing.expect(cursize >= 64 * 100 * 1024 and cursize < 64 * 128 * 1024);
    for (&S.blocks) |*b| pool.poolfree(p, b.*);
    sums = try walk(p);
    try std.testing.expectEqual(p.curfree, sums.largestfree);
    const v = pool.poolalloc(p, 6 * 1024 * 1024) orelse return error.OutOfMemory;
    try std.testing.expectEqual(cursize, p.cursize);
    pool.poolfree(p, v);
    try consistent(p);

    // and with a gap after every arena none merge
    unmapregion();
    var c = kernelmain;
    c.gapevery = 1;
    try newpool(&c, c.flags);
    for (S.blocks[0..8]) |*b|
        b.* = pool.poolalloc(p, 100 * 1024) orelse return error.OutOfMemory;
    sums = try walk(p);
    try std.testing.expectEqual(@as(usize, 8), sums.narena);
    try consistent(p);
}

test "pool: the kernel's malloc is aligned to 16" {
    // What port/alloc.zig does: two 4-byte tag words in front of the
    // caller's memory, and mallocalign's offset moved by as much.
    try newpool(&kernelmain, kernelmain.flags);
    defer unmapregion();
    const p = &thepool;
    const Npad = 8;
    rndx = 99;
    for (0..2000) |_| {
        const size = pick() % 5000;
        const v = pool.poolalloc(p, size + Npad) orelse return error.OutOfMemory;
        try std.testing.expectEqual(@as(usize, 0), (@intFromPtr(v) + Npad) % 16);
        if (rnd() % 3 == 0) pool.poolfree(p, v);
    }
    const als = [_]usize{ 1, 2, 8, 16, 32, 64, 256, 4096, 65536 };
    for (0..2000) |_| {
        const size = pick() % 5000;
        const al = als[rnd() % als.len];
        // The span is the pool block's, tag words included: memory
        // aligned to a multiple of the span cannot be had, as in C.
        const span: usize = if (al < 65536 and rnd() % 4 == 0) 65536 else 0;
        const o: usize = if (span == 0 and rnd() % 4 == 0) rnd() % al else 0;
        const off8: isize = @as(isize, @intCast(o)) - Npad;
        const v = pool.poolallocalign(p, size + Npad, al, off8, span) orelse return error.OutOfMemory;
        const user = @intFromPtr(v) + Npad;
        try std.testing.expectEqual(o, user % al);
        if (span != 0 and size != 0)
            try std.testing.expectEqual(@intFromPtr(v) / span, (user + size - 1) / span);
        // msize and realloc, as alloc.zig calls them
        const m = pool.poolmsize(p, v) - Npad;
        try std.testing.expect(m >= size);
        @memset(@as([*]u8, @ptrFromInt(user))[0..m], 0xAB);
        pool.poolblockcheck(p, v);
        if (rnd() % 3 == 0) pool.poolfree(p, v);
    }
    try consistent(p);
}

test "pool: poolmsize and poolrealloc of an aligned block" {
    // DIFF: bugs of the C, see pool.zig's header.
    try newpool(&kernelmain, kernelmain.flags);
    defer unmapregion();
    const p = &thepool;
    _ = pool.poolalloc(p, 100);
    const v = pool.poolallocalign(p, 1000, 4096, 0, 0) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(v) % 4096);
    const guard = pool.poolalloc(p, 100) orelse return error.OutOfMemory;
    @memset(guard[0..100], 0x11);
    const m = pool.poolmsize(p, v);
    try std.testing.expect(m >= 1000);
    for (v[0..m], 0..) |*c, j| c.* = @truncate(j);
    try consistent(p);
    const w = pool.poolrealloc(p, v, 5000) orelse return error.OutOfMemory;
    for (w[0..m], 0..) |c, j| try std.testing.expectEqual(@as(u8, @truncate(j)), c);
    try std.testing.expect(std.mem.allEqual(u8, guard[0..100], 0x11));
    try consistent(p);
}

test "pool: a small block at an odd alignment" {
    // DIFF: freefromfront's bug in the C, see pool.zig's header.
    try newpool(&kernelmain, kernelmain.flags);
    defer unmapregion();
    const p = &thepool;
    rndx = 7;
    const S = struct {
        var blocks: [512]?[*]u8 = @splat(null);
    };
    for (0..20000) |_| {
        const i = rnd() % S.blocks.len;
        if (S.blocks[i]) |v| {
            pool.poolfree(p, v);
            S.blocks[i] = null;
        } else {
            const v = pool.poolallocalign(p, 1 + rnd() % 12, 100, 4, 0) orelse return error.OutOfMemory;
            try std.testing.expectEqual(@as(usize, 4), @intFromPtr(v) % 100);
            S.blocks[i] = v;
        }
    }
    try consistent(p);
}

test "pool: compaction" {
    // Blocks that each know their index; free every other one, compact,
    // and the rest must have moved together and still know it.
    var c = kernelmain;
    c.compact = true;
    c.minarena = 1024 * 1024;
    try newpool(&c, c.flags);
    defer unmapregion();
    const p = &thepool;
    for (slot[0..200], 0..) |*s, i| {
        s.n = 100 + i * 3;
        s.seed = @truncate(i);
        s.p = pool.poolalloc(p, s.n) orelse return error.OutOfMemory;
        fill(s);
    }
    for (slot[0..200], 0..) |*s, i| {
        if (i % 2 == 0) {
            pool.poolfree(p, s.p);
            s.p = null;
        }
    }
    var sums = try walk(p);
    try std.testing.expect(sums.largestfree < p.curfree);
    nmoved = 0;
    try std.testing.expectEqual(@as(u32, 1), pool.poolcompact(p));
    try std.testing.expectEqual(@as(usize, 100), nmoved);
    try consistent(p);
    sums = try walk(p);
    try std.testing.expectEqual(p.curfree, sums.largestfree);
    for (slot[0..200]) |*s| {
        if (s.p != null) try check(s, "after compaction");
    }
    // nothing was freed since: nothing to do
    try std.testing.expectEqual(@as(u32, 0), pool.poolcompact(p));

    // A full pool compacts itself to satisfy a request.
    for (slot[0..200], 0..) |*s, i| {
        if (i % 4 == 1) {
            pool.poolfree(p, s.p);
            s.p = null;
        }
    }
    p.maxsize = p.cursize;
    sums = try walk(p);
    nmoved = 0;
    const v = pool.poolalloc(p, sums.largestfree + 1000) orelse return error.DidNotCompact;
    try std.testing.expect(nmoved > 0);
    for (slot[0..200]) |*s| {
        if (s.p != null) try check(s, "after compaction");
    }
    pool.poolfree(p, v);
    try consistent(p);
}

test "pool: the other entry points" {
    try newpool(&kernelmain, kernelmain.flags);
    defer unmapregion();
    const p = &thepool;
    p.free = pfree;

    const a = pool.poolalloc(p, 100) orelse return error.OutOfMemory;
    const b = pool.poolallocalign(p, 100, 256, 0, 0) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), pool.poolmsize(p, null));
    pool.poolfree(p, null);
    pool.poolblockcheck(p, null);
    pool.poolblockcheck(p, a);
    pool.poolblockcheck(p, b);
    try std.testing.expect(pool.poolrealloc(p, null, 0) != null);
    try std.testing.expect(pool.poolrealloc(p, a, 0) == null);

    // sizes the C would have truncated
    try std.testing.expect(pool.poolalloc(p, 0x80000000) == null);
    try std.testing.expect(pool.poolalloc(p, 0x100000010) == null);
    try std.testing.expect(pool.poolrealloc(p, b, 0x100000010) == null);
    try std.testing.expect(pool.poolallocalign(p, 16, std.math.maxInt(usize), 0, 0) == null);
    // one that cannot be had: larger than the span it may not cross
    try std.testing.expect(pool.poolallocalign(p, 5000, 16, 0, 4096) == null);
    try consistent(p);

    try std.testing.expect(pool.poolisoverlap(p, @intFromPtr(b), 1));
    try std.testing.expect(pool.poolisoverlap(p, @intFromPtr(p.arenalist.?) - 10, 11));
    try std.testing.expect(!pool.poolisoverlap(p, @intFromPtr(p.arenalist.?) - 10, 10));
    try std.testing.expect(!pool.poolisoverlap(p, @intFromPtr(p.arenalist.?) + p.arenalist.?.asize, 100));

    // pooldump: a line for the pool and one for each arena
    nprintbuf = 0;
    pool.pooldump(p);
    try std.testing.expect(std.mem.startsWith(u8, printbuf[0..nprintbuf], "pool "));
    try std.testing.expect(std.mem.find(u8, printbuf[0..nprintbuf], " Main\n(") != null);

    // verbosity and logging print at every operation
    p.flags |= pool.POOL_VERBOSITY | pool.POOL_LOGGING | pool.POOL_PARANOIA;
    p.logstack = plogstack;
    printed = 0;
    stacks = 0;
    nprintbuf = 0;
    const c = pool.poolalloc(p, 300 * 1024) orelse return error.OutOfMemory;
    try std.testing.expect(std.mem.find(u8, printbuf[0..nprintbuf], "newarena ") != null);
    nprintbuf = 0;
    _ = pool.poolmsize(p, c);
    try std.testing.expect(std.mem.find(u8, printbuf[0..nprintbuf], "poolmsize ") != null);
    nprintbuf = 0;
    const d = pool.poolrealloc(p, c, 400 * 1024) orelse return error.OutOfMemory;
    try std.testing.expect(std.mem.find(u8, printbuf[0..nprintbuf], "poolrealloc ") != null);
    pool.poolfree(p, d);
    _ = pool.poolallocalign(p, 10, 64, 0, 0);
    _ = pool.poolcompact(p);
    try std.testing.expectEqual(@as(usize, 5), stacks);
    try std.testing.expect(printed > 20);
    p.flags &= ~@as(u32, pool.POOL_VERBOSITY | pool.POOL_LOGGING | pool.POOL_PARANOIA);

    // One NUL written past the end of a block that is full to its
    // tail is reported and tolerated (POOL_TOLERANCE).
    const e = pool.poolalloc(p, 48) orelse return error.OutOfMemory;
    const m = pool.poolmsize(p, e);
    e[m] = 0;
    nprintbuf = 0;
    pool.poolblockcheck(p, e);
    try std.testing.expect(std.mem.startsWith(u8, printbuf[0..nprintbuf], "mem user overflow (magic0)\npool Main block "));
    try std.testing.expect(std.mem.find(u8, printbuf[0..nprintbuf], "\nuser data ") != null);
    e[m] = 0xBE;
    // and one in the slack of a block that is not
    const f = pool.poolalloc(p, 10) orelse return error.OutOfMemory;
    const was = f[10];
    f[10] = 0;
    nprintbuf = 0;
    pool.poolblockcheck(p, f);
    try std.testing.expect(std.mem.startsWith(u8, printbuf[0..nprintbuf], "mem user overflow\n"));
    f[10] = was;
    nprintbuf = 0;
    pool.poolcheck(p);
    try std.testing.expectEqual(@as(usize, 0), nprintbuf);

    // poolreset gives the arenas back
    const cursize = p.cursize;
    var sums = try walk(p);
    try std.testing.expect(sums.narena >= 1);
    p.flags |= pool.POOL_SCRUB | pool.POOL_ANTAGONISM;
    freed = 0;
    pool.poolreset(p);
    try std.testing.expect(freed >= cursize);
    try std.testing.expectEqual(@as(usize, 0), p.cursize + p.curfree + p.curalloc);
    try std.testing.expect(p.arenalist == null and p.freeroot == null);
    pool.poolreset(null);
    sums = try walk(p);
    try std.testing.expectEqual(@as(usize, 0), sums.narena);
    // and works again
    try std.testing.expect(pool.poolalloc(p, 100) != null);
    try consistent(p);
}

test "pool: a deep free tree is checked without recursion" {
    // Freeing blocks of increasing size makes the splay tree a list.
    var c = kernelmain;
    c.minarena = 40 * 1024 * 1024;
    c.maxsize = 80 * 1024 * 1024;
    try newpool(&c, c.flags);
    defer unmapregion();
    const p = &thepool;
    const N = 1000;
    const S = struct {
        var blocks: [2 * N]?[*]u8 = @splat(null);
    };
    for (0..2 * N) |i|
        S.blocks[i] = pool.poolalloc(p, 32 + (i / 2) * 32) orelse return error.OutOfMemory;
    // every other one, so that none merge
    for (0..N) |i| pool.poolfree(p, S.blocks[2 * i]);
    try consistent(p);
    var depth: usize = 0;
    var t = p.freeroot;
    while (t) |x| : (t = x.left) depth += 1;
    try std.testing.expect(depth > N / 2);
}
