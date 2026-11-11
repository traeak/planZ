//! Blocks: the buffers that queues, network stacks and drivers pass
//! around, and their allocation.
//! from 9/port/allocb.c; Block, Bpool, BLEN and BALLOC from 9/port/portdat.h
//!
//! DIFF:
//!   - allocb waits for memory with a plain tsleep until resrcwait
//!     exists (M3, pgrp.c); an interrupting note is ignored there as in
//!     the C.
//!   - The poison freeb leaves in a dead block is Bdead ("QIOB") for the
//!     byte pointers, but Bdeadp (Bdead rounded down to the alignment
//!     of a Block) for next, list and pool: a Zig pointer to a struct
//!     must be aligned, and a misaligned one could be optimised away in
//!     checkb.
//!   - Sizes and counts are usize where the C has int or ulong; BLEN and
//!     BALLOC are functions.  BLEN of a block whose wp is below its rp is
//!     a safety panic rather than a negative number.
//!   - BLOCKALIGN comes from the architecture's mem if it has one,
//!     otherwise it is 8.
//!   - _allocb also clears Block.checksum, which the C leaves as
//!     malloc returned it.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const proc = @import("proc.zig");
const alloc = @import("alloc.zig");
const xalloc = @import("xalloc.zig");
const p9 = @import("print.zig");

const print = p9.print;
const iprint = p9.iprint;
const panic = p9.panic;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const mem = arch.mem;

const Lock = portdat.Lock;

// flag values
pub const BINTR: u16 = 1 << 0;
pub const BFREE: u16 = 1 << 1;
pub const Bipck: u16 = 1 << 2; // ip checksum
pub const Budpck: u16 = 1 << 3; // udp checksum
pub const Btcpck: u16 = 1 << 4; // tcp checksum
pub const Bpktck: u16 = 1 << 5; // packet checksum

pub const Block = struct {
    next: ?*Block = null,
    list: ?*Block = null,
    rp: [*]u8, // first unconsumed byte
    wp: [*]u8, // first empty byte
    lim: [*]u8, // 1 past the end of the buffer
    base: [*]u8, // start of the buffer
    pool: ?*Bpool = null,
    flag: u16 = 0,
    checksum: u16 = 0, // IP checksum of complete packet (minus media header)
};

/// Bytes of data in a block.
pub fn BLEN(s: *const Block) usize {
    return @intFromPtr(s.wp) - @intFromPtr(s.rp);
}

/// Size of a block's buffer.
pub fn BALLOC(s: *const Block) usize {
    return @intFromPtr(s.lim) - @intFromPtr(s.base);
}

pub const Bpool = struct {
    size: usize = 0, // block size
    @"align": usize = 0, // block alignment

    lock: Lock = .{},
    head: ?*Block = null, // freelist head
};

pub const BLOCKALIGN: usize = if (@hasDecl(mem, "BLOCKALIGN")) mem.BLOCKALIGN else 8;

const Hdrspc = 64; // leave room for high-level headers
const Tlrspc = 16; // extra room at the end for pad/crc/mac
const Bdead = 0x51494F42; // "QIOB"
const Bdeadp = Bdead & ~@as(usize, @alignOf(Block) - 1);

fn ROUND(s: usize, sz: usize) usize {
    return (s + (sz - 1)) & ~(sz - 1);
}

fn _allocb(size_: usize, alignment: usize) ?*Block {
    const size = ROUND(size_ + Tlrspc, alignment);
    const p = alloc.mallocz(@sizeOf(Block) + Hdrspc + size + alignment - 1, false) orelse
        return null;
    const b: *Block = @ptrCast(@alignCast(p));

    // align start of data portion by rounding up
    const base: [*]u8 = @ptrFromInt(ROUND(@intFromPtr(b) + @sizeOf(Block), alignment));

    // align end of data portion by rounding down
    const lim: [*]u8 = @ptrFromInt((@intFromPtr(b) + alloc.msize(b)) & ~(alignment - 1));

    b.* = .{
        .next = null,
        .list = null,
        .pool = null,
        .flag = 0,
        .base = base,
        .lim = lim,
        // leave room at beginning for added headers
        .rp = lim - size,
        .wp = lim - size,
    };

    return b;
}

pub fn allocb(size: usize) *Block {
    // Check in a process and wait until successful.
    const up = arch.up() orelse
        panic("allocb without up: %#p", .{@returnAddress()});
    while (true) {
        if (_allocb(size, BLOCKALIGN)) |b| {
            alloc.setmalloctag(b, @returnAddress());
            return b;
        }
        if (up.nlocks != 0 or arch.m().ilockdepth != 0 or !arch.islo()) {
            xalloc.xsummary();
            alloc.mallocsummary();
            panic("allocb: no memory for %lud bytes", .{size});
        }
        // M3: resrcwait("no memory for allocb"), once pgrp.c is ported.
        // A note that interrupts the wait is ignored, as the C does
        // with its waserror.
        proc.tsleep(&up.sleep, proc.return0, null, 100) catch {};
    }
}

pub fn iallocb(size: usize) ?*Block {
    const S = struct {
        var nerr: u32 = 0;
    };

    const b = _allocb(size, BLOCKALIGN) orelse {
        const n = S.nerr;
        S.nerr +%= 1;
        if ((n % 10000) == 0) {
            if (S.nerr > 10000000) {
                xalloc.xsummary();
                alloc.mallocsummary();
                panic("iallocb: out of memory", .{});
            }
            iprint("iallocb: no memory for %lud bytes\n", .{size});
        }
        return null;
    };
    alloc.setmalloctag(b, @returnAddress());
    b.flag = BINTR;

    return b;
}

pub fn freeb(b_: ?*Block) void {
    const b = b_ orelse return;

    if (b.pool) |p| {
        b.next = null;
        b.rp = b.lim - ROUND(p.size + Tlrspc, p.@"align");
        b.wp = b.rp;
        b.flag = BINTR;
        ilock(&p.lock);
        b.list = p.head;
        p.head = b;
        iunlock(&p.lock);
        return;
    }

    // poison the block in case someone is still holding onto it
    b.next = @ptrFromInt(Bdeadp);
    b.list = @ptrFromInt(Bdeadp);
    b.rp = @ptrFromInt(Bdead);
    b.wp = @ptrFromInt(Bdead);
    b.lim = @ptrFromInt(Bdead);
    b.base = @ptrFromInt(Bdead);
    b.pool = @ptrFromInt(Bdeadp);

    alloc.free(b);
}

fn _alignment(align_: usize) usize {
    if (align_ <= BLOCKALIGN)
        return BLOCKALIGN;

    // make it a power of two
    var a = align_;
    a -= 1;
    a |= a >> 1;
    a |= a >> 2;
    a |= a >> 4;
    a |= a >> 8;
    a |= a >> 16;
    a += 1;

    return a;
}

pub fn iallocbp(p: *Bpool) ?*Block {
    ilock(&p.lock);
    if (p.head) |b| {
        p.head = b.list;
        b.list = null;
        iunlock(&p.lock);
        return b;
    } else {
        iunlock(&p.lock);
        p.@"align" = _alignment(p.@"align");
        const b = _allocb(p.size, p.@"align") orelse
            return null;
        alloc.setmalloctag(b, @returnAddress());
        b.pool = p;
        b.flag = BINTR;
        return b;
    }
}

pub fn growbp(p: *Bpool, n_: usize) void {
    var n = n_;
    if (n < 1)
        return;
    var b: [*]Block = @ptrCast(@alignCast(alloc.malloc(@sizeOf(Block) * n) orelse
        return));
    p.@"align" = _alignment(p.@"align");
    const size = ROUND(p.size + Hdrspc + Tlrspc, p.@"align");
    var a = alloc.mallocalign(size * n, p.@"align", 0, 0) orelse {
        alloc.free(b);
        return;
    };
    alloc.setmalloctag(b, @returnAddress());
    while (n > 0) {
        b[0] = .{
            .base = a,
            .lim = a + size,
            .rp = a,
            .wp = a,
            .pool = p,
        };
        a += size;
        freeb(&b[0]);
        b += 1;
        n -= 1;
    }
}

pub fn checkb(b: *Block, msg: []const u8) void {
    if (@intFromPtr(b) == Bdeadp)
        panic("checkb b %s %#p", .{ msg, b });
    if (@intFromPtr(b.base) == Bdead or @intFromPtr(b.lim) == Bdead or
        @intFromPtr(b.next) == Bdeadp or @intFromPtr(b.list) == Bdeadp or
        @intFromPtr(b.pool) == Bdeadp or
        @intFromPtr(b.rp) == Bdead or @intFromPtr(b.wp) == Bdead)
    {
        print("checkb: base %#p lim %#p next %#p list %#p pool %#p\n", .{ b.base, b.lim, b.next, b.list, b.pool });
        print("checkb: rp %#p wp %#p\n", .{ b.rp, b.wp });
        panic("checkb dead: %s", .{msg});
    }
    if (@intFromPtr(b.base) > @intFromPtr(b.lim))
        panic("checkb 0 %s %#p %#p", .{ msg, b.base, b.lim });
    if (@intFromPtr(b.rp) < @intFromPtr(b.base))
        panic("checkb 1 %s %#p %#p", .{ msg, b.base, b.rp });
    if (@intFromPtr(b.wp) < @intFromPtr(b.base))
        panic("checkb 2 %s %#p %#p", .{ msg, b.base, b.wp });
    if (@intFromPtr(b.rp) > @intFromPtr(b.lim))
        panic("checkb 3 %s %#p %#p", .{ msg, b.rp, b.lim });
    if (@intFromPtr(b.wp) > @intFromPtr(b.lim))
        panic("checkb 4 %s %#p %#p", .{ msg, b.wp, b.lim });
}
